-- lvim-git.transient: the declarative TRANSIENT command engine — Magit's signature and the spine every
-- verb hangs off. A transient is DATA: a prefix (id + title) with grouped INFIXES (switches `-x` and
-- options `=val`) and ACTIONS (the suffix commands). Invoking a prefix pops a popup (the lvim-ui
-- `transient` preset) that shows every infix with its current value, lets you toggle/set them with direct
-- single keys, and fires an action — passing the assembled argv to the backend.
--
-- This module owns the DATA + the arg math + the persistence; the lvim-ui preset owns the rendering
-- (the clean data-vs-render split the select/tabs presets use). Per-prefix arg state lives in state.lua,
-- keyed by "<id>@<root>": the SESSION default a fresh open starts from (Magit's `set`). `save` writes the
-- same snapshot to a small per-plugin json store (the plugin's ONLY persisted store; the repo is the
-- database for everything else). Visibility LEVELS 1-7 hide advanced infixes/actions like Magit.
--
-- A def registers via `M.define`; each COMPONENT registers its own verb defs lazily (actions.lua, later
-- phases), so the engine is a shared FACILITY, not a component others depend on for existence.
--
---@module "lvim-git.transient"

local state = require("lvim-git.state")

local M = {}

-- ── types ───────────────────────────────────────────────────────────────────

---@class LvimGitInfix
---@field kind    "switch"|"option"
---@field key     string        the direct hotkey (also the state key)
---@field label   string        the human description
---@field flag?   string        switch: the argv flag it toggles (e.g. "--force-with-lease")
---@field arg?    string        option: the argv name it sets (e.g. "--max-count")
---@field choices? string[]     option: a fixed value set (cycled instead of typed)
---@field default? any          the initial value (switch: boolean; option: string)
---@field level?  integer       visibility level (default 1)

---@class LvimGitTransientAction
---@field key    string
---@field label  string
---@field level? integer
---@field run    fun(args: string[], ctx: LvimGitTransientCtx)  execute with the assembled argv + scope

---@class LvimGitTransientGroup
---@field title? string
---@field infix?   LvimGitInfix[]
---@field actions? LvimGitTransientAction[]

---@class LvimGitTransientDef
---@field id     string
---@field title  string
---@field groups LvimGitTransientGroup[]

---@class LvimGitTransientSnap
---@field switches table<string, boolean>  key → on/off
---@field options  table<string, any>      key → value (nil/"" = unset)
---@field level?   integer                 the remembered visible level for this prefix

---@class LvimGitTransientCtx
---@field id     string                 the prefix id
---@field root   string?                the repo root (nil outside a repo)
---@field lens   "git"|"jj"|nil         a one-off lens override for this invocation
---@field args?  string[]               extra positional args from the command line
---@field rows   table<string, table>   key → the live infix ui-row spec (its `.value` is the working copy)

-- ── registry ─────────────────────────────────────────────────────────────────

---@type table<string, LvimGitTransientDef>  the registered transient defs, keyed by id
local defs = {}

--- Register (or replace) a transient definition. Components call this from their own module load.
---@param def LvimGitTransientDef
function M.define(def)
    defs[def.id] = def
end

--- Whether a transient id is registered.
---@param id string
---@return boolean
function M.has(id)
    return defs[id] ~= nil
end

-- ── persistence (the ONE json store: saved per-prefix defaults) ───────────────

---@type table?  the lazily-opened lvim-utils.store handle (nil until first use / disabled)
local store

--- The saved-defaults store, opened lazily on first save/read. Nil when `save_defaults` is off — then
--- nothing is ever persisted (the store file is never created).
---@return table?
local function saved_store()
    local config = require("lvim-git.config")
    if not config.transient.save_defaults then
        return nil
    end
    if not store then
        store = require("lvim-utils.store").new({ backend = "json", name = "lvim-git" })
    end
    return store
end

-- ── state helpers ────────────────────────────────────────────────────────────

--- The state key for a prefix in a repo.
---@param id string
---@param root string?
---@return string
local function skey(id, root)
    return id .. "@" .. (root or "GLOBAL")
end

--- Resolve the repo root for an invocation (nil outside a repo → the "GLOBAL" bucket).
---@param ctx? { root?: string, buf?: integer }
---@return string?
local function resolve_root(ctx)
    if ctx and ctx.root then
        return ctx.root
    end
    local root = require("lvim-git.backend").detect((ctx and ctx.buf) or nil)
    return root
end

--- The built-in default snapshot for a def (from each infix's `default`).
---@param def LvimGitTransientDef
---@return LvimGitTransientSnap
local function defaults_of(def)
    local snap = { switches = {}, options = {} }
    for _, g in ipairs(def.groups or {}) do
        for _, ix in ipairs(g.infix or {}) do
            if ix.kind == "switch" then
                snap.switches[ix.key] = ix.default == true
            else
                snap.options[ix.key] = ix.default
            end
        end
    end
    return snap
end

--- The SESSION default snapshot for a prefix — the committed args a fresh open starts from. Lazily
--- seeded from the on-disk store (if any) else the built-in defaults, then cached in state.transient.
---@param def LvimGitTransientDef
---@param root string?
---@return LvimGitTransientSnap
local function session_snapshot(def, root)
    local key = skey(def.id, root)
    local snap = state.transient[key]
    if snap then
        return snap
    end
    local s = saved_store()
    local persisted = s and s[key] or nil
    snap = persisted and vim.deepcopy(persisted) or defaults_of(def)
    state.transient[key] = snap
    return snap
end

-- ── argv assembly ────────────────────────────────────────────────────────────

--- Assemble the argv list from a snapshot: each ON switch → its flag; each set option → `--arg=value`
--- (a `--long` name) or `arg value` (anything else).
---@param def LvimGitTransientDef
---@param snap { switches: table<string, boolean>, options: table<string, any> }
---@return string[]
local function assemble(def, snap)
    local out = {}
    for _, g in ipairs(def.groups or {}) do
        for _, ix in ipairs(g.infix or {}) do
            if ix.kind == "switch" then
                if snap.switches[ix.key] and ix.flag then
                    out[#out + 1] = ix.flag
                end
            else
                local v = snap.options[ix.key]
                if v ~= nil and v ~= "" and ix.arg then
                    if ix.arg:sub(1, 2) == "--" then
                        out[#out + 1] = ix.arg .. "=" .. tostring(v)
                    else
                        out[#out + 1] = ix.arg
                        out[#out + 1] = tostring(v)
                    end
                end
            end
        end
    end
    return out
end

--- The assembled argv for a prefix's SESSION default (for callers invoking a verb WITHOUT opening the
--- popup). Public: part of the engine facility surface.
---@param id string
---@param root? string
---@return string[]
function M.args(id, root)
    local def = defs[id]
    if not def then
        return {}
    end
    return assemble(def, session_snapshot(def, root))
end

-- ── snapshot ⇄ live ui rows ──────────────────────────────────────────────────

--- Snapshot the live ui-row values (the working copy) back into a plain `{ switches, options }` table.
---@param ctx LvimGitTransientCtx
---@return LvimGitTransientSnap
local function snapshot_rows(ctx)
    local snap = { switches = {}, options = {} }
    for key, row in pairs(ctx.rows) do
        if row.kind == "switch" then
            snap.switches[key] = row.value == true
        else
            snap.options[key] = row.value
        end
    end
    return snap
end

-- ── open ─────────────────────────────────────────────────────────────────────

--- Open a transient prefix's popup. `ctx` carries the invoking scope (lens override, extra args, the
--- selection the actions operate on — "the thing at point"). Unknown / unbuilt ids report the gap
--- (a verb whose real def lands in a later phase).
---@param id string
---@param ctx? { root?: string, buf?: integer, lens?: "git"|"jj", args?: string[], selection?: any }
function M.open(id, ctx)
    ctx = ctx or {}
    local config = require("lvim-git.config")
    if not config.transient.enabled then
        return
    end
    local def = defs[id]
    if not def then
        vim.notify("lvim-git: transient `" .. tostring(id) .. "` is not available yet", vim.log.levels.WARN)
        return
    end

    local root = resolve_root(ctx)
    local snap = session_snapshot(def, root)

    ---@type LvimGitTransientCtx
    local tctx = {
        id = id,
        root = root,
        lens = ctx.lens,
        args = ctx.args,
        selection = ctx.selection,
        rows = {},
    }

    -- Build the lvim-ui transient groups from the def, seeding each infix's value from the session
    -- snapshot. Keep a reference to every infix ui-row in `tctx.rows` so `set`/`save`/`reset`/`args`
    -- read the working values and `reset` can rewrite them in place.
    local ui_groups = {}
    for _, g in ipairs(def.groups or {}) do
        local ui_rows = {}
        for _, ix in ipairs(g.infix or {}) do
            local value
            if ix.kind == "switch" then
                value = snap.switches[ix.key]
                if value == nil then
                    value = ix.default == true
                end
            else
                value = snap.options[ix.key]
                if value == nil then
                    value = ix.default
                end
            end
            local row = {
                kind = ix.kind,
                key = ix.key,
                label = ix.label,
                flag = ix.flag,
                arg = ix.arg,
                choices = ix.choices,
                value = value,
                level = ix.level or 1,
            }
            tctx.rows[ix.key] = row
            ui_rows[#ui_rows + 1] = row
        end
        for _, ac in ipairs(g.actions or {}) do
            ui_rows[#ui_rows + 1] = {
                kind = "action",
                key = ac.key,
                label = ac.label,
                level = ac.level or 1,
                run = function()
                    ac.run(assemble(def, snapshot_rows(tctx)), tctx)
                end,
            }
        end
        ui_groups[#ui_groups + 1] = { title = g.title, rows = ui_rows }
    end

    require("lvim-ui").transient({
        title = def.title,
        groups = ui_groups,
        level = snap.level or config.transient.level,
        min_level = 1,
        max_level = 7,
        layout = config.transient.layout,
        -- live edits mutate the ui-row `.value` (the working copy) — nothing to persist until set/save.
        on_toggle = function() end,
        on_option = function() end,
        on_level = function(lvl)
            snap.level = lvl -- remember the level per prefix for this session
        end,
        -- set: promote the working copy to the session default (Magit's `C-x s`).
        on_set = function()
            local s = snapshot_rows(tctx)
            s.level = snap.level
            state.transient[skey(id, root)] = s
            snap = s
            vim.notify("lvim-git: " .. def.title .. " args set for this session", vim.log.levels.INFO)
        end,
        -- save: write the working copy to the on-disk store AND the session default (Magit's `C-x C-s`).
        on_save = function()
            local s = snapshot_rows(tctx)
            s.level = snap.level
            state.transient[skey(id, root)] = s
            snap = s
            local st = saved_store()
            if st then
                st[skey(id, root)] = vim.deepcopy(s)
                vim.notify("lvim-git: " .. def.title .. " args saved", vim.log.levels.INFO)
            else
                vim.notify("lvim-git: saving defaults is disabled (transient.save_defaults)", vim.log.levels.WARN)
            end
        end,
        -- reset: drop the working copy back to the saved (store) or built-in defaults, rewriting each
        -- live ui-row's value in place so the popup re-renders from them.
        on_reset = function()
            local base
            local st = saved_store()
            local persisted = st and st[skey(id, root)] or nil
            base = persisted and vim.deepcopy(persisted) or defaults_of(def)
            for key, row in pairs(tctx.rows) do
                if row.kind == "switch" then
                    row.value = base.switches[key] == true
                else
                    row.value = base.options[key]
                end
            end
        end,
    })
end

return M
