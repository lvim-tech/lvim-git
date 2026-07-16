-- lvim-git.ui.submodule: the SUBMODULE panel (Magit `magit-list-submodules`) — every submodule with its
-- recorded short-sha, sync state and `describe`, a live recent-log preview, and the full submodule op set.
-- A decoupled COMPONENT over the shared core (backend / config), gated on `caps.submodule` (git only; jj
-- has no submodules — a colocated repo manages them via the git side). Standalone (`:LvimGit submodule`).
--
-- It is a `lvim-ui.tabs` MENU surface (the stash/refs chassis): one `ui.section` fold header with a row
-- per submodule; the focused submodule's `git -C <path> log` renders in the chassis PREVIEW. Row/panel
-- keys reuse the verb layer (`actions.submodule_*`) so the panel, the submodule transient, and the status
-- modules section share ONE implementation: `u` update, `i` init, `s` sync, `a` add, `x` deinit, `T`
-- transient, `<CR>` opens the submodule's own lvim-git status. Refreshes on `User LvimGitRepoChanged`.
--
-- PUBLIC: open / is_open / close / toggle + list (async). Internal otherwise.
--
---@module "lvim-git.ui.submodule"

local api = vim.api
local config = require("lvim-git.config")
local backend = require("lvim-git.backend")
local logpanel = require("lvim-git.ui.logpanel")
local actions = require("lvim-git.actions")
local ui = require("lvim-ui")
local hl = require("lvim-utils.highlight")

local M = {}

-- ── glyphs (verified single-width Nerd Font, + the `➤` pointer canon) ──────────
local GLYPH = {
    title = "\u{f0e8}", --  nf-fa-sitemap (submodule tree)
    fold = "\u{f0d7}", --  nf-fa-caret_down
    entry = "➤", -- the pointer canon (submodule row marker)
}

--- The state → { glyph-hl, badge } mapping for a submodule row.
---@type table<string, { hl: string, badge: string }>
local STATE_UI = {
    insync = { hl = "LvimUiPathDim", badge = "" },
    modified = { hl = "LvimGitTransientValue", badge = " (modified)" },
    uninitialized = { hl = "LvimGitBehind", badge = " (not initialized)" },
    conflict = { hl = "LvimGitBehind", badge = " (conflict)" },
}

---@class LvimGitSubmoduleState
---@field handle table?
---@field tabs table[]?
---@field root string?
---@field vcs string?
---@field subs table[]?
---@field registry table
---@field detail_cache table<string, { lines: string[], hls: table[] }>
---@field focused table?
---@field preview_pan table?
---@field augroup integer?
---@field layout string?
local state = { registry = {}, detail_cache = {} }

---@param msg string
---@param level? integer
local function notify(msg, level)
    vim.notify("lvim-git: " .. msg, level or vim.log.levels.INFO)
end

--- Whether the submodule panel is open.
---@return boolean
function M.is_open()
    return state.handle ~= nil and state.handle.valid ~= nil and state.handle.valid()
end

-- ── public read ────────────────────────────────────────────────────────────────

--- The submodule list (async) — the documented read.
---@param root? string
---@param cb fun(subs: table[]?)
function M.list(root, cb)
    backend.submodule_status(root, cb)
end

-- ── data load ────────────────────────────────────────────────────────────────────

---@param done fun()
local function load(done)
    backend.refresh(state.root, function()
        backend.submodule_status(state.root, function(subs)
            state.subs = subs or {}
            done()
        end)
    end)
end

-- ── rows ──────────────────────────────────────────────────────────────────────────

---@param sub table
---@return table
local function sub_row(sub)
    local name = "sub:" .. sub.path
    state.registry[name] = { kind = "submodule", sub = sub }
    local sui = STATE_UI[sub.state] or STATE_UI.insync
    local label, spans = "", {}
    local function seg(text, group)
        local s = #label
        label = label .. text
        if group then
            spans[#spans + 1] = { s, #label, group }
        end
    end
    seg(sub.path, "LvimGitRefBranch")
    seg("  " .. sub.sha, "LvimGitLogId")
    if sub.describe and sub.describe ~= "" then
        seg("  " .. sub.describe, "LvimUiPathDim")
    end
    if sui.badge ~= "" then
        seg(sui.badge, sui.hl)
    end
    return {
        type = "action",
        name = name,
        flat = true,
        tight = true,
        icon = " " .. GLYPH.entry .. " ",
        icon_hl = sui.hl,
        label = label,
        label_spans = spans,
        _item = { kind = "submodule", sub = sub },
        run = function()
            M.open_current()
        end,
    }
end

---@return table[]
local function build_rows()
    state.registry = {}
    local list = state.subs or {}
    if #list == 0 then
        return { { type = "spacer", name = "empty", label = "  No submodules", hl = { inactive = "LvimUiPathDim" } } }
    end
    local children = {}
    for _, s in ipairs(list) do
        children[#children + 1] = sub_row(s)
    end
    local sa = hl.section_accent("green")
    state.registry["submodules"] = { kind = "section" }
    return {
        ui.section({
            name = "submodules",
            icon = " " .. GLYPH.fold .. " ",
            box_hl = sa.text,
            label = "Submodules",
            count = #children,
            accent = "green",
            expanded = true,
            children = children,
        }),
    }
end

-- ── the preview (a submodule's recent log) ──────────────────────────────────────

---@param sub table
local function load_detail(sub)
    local key = sub.path
    if state.detail_cache[key] then
        if state.preview_pan and state.preview_pan.refresh then
            state.preview_pan.refresh()
        end
        return
    end
    local abs = state.root .. "/" .. sub.path
    backend.output(
        state.root,
        { config.git.cmd, "--no-optional-locks", "-c", "color.ui=false", "-C", abs, "log", "--oneline", "-15" },
        function(out)
            local lines, hls = {}, {}
            lines[#lines + 1] = sub.path .. "  " .. sub.sha
            hls[#hls + 1] = { 0, 0, -1, "LvimGitRefBranch" }
            lines[#lines + 1] = ""
            if out and vim.trim(out) ~= "" then
                for line in (out .. "\n"):gmatch("(.-)\n") do
                    if line ~= "" then
                        lines[#lines + 1] = line
                        local h = line:match("^(%x+)")
                        if h then
                            hls[#hls + 1] = { #lines - 1, 0, #h, "LvimGitLogId" }
                        end
                    end
                end
            else
                lines[#lines + 1] = "  (not initialized — run `i` init / `u` update)"
                hls[#hls + 1] = { 2, 0, -1, "LvimUiPathDim" }
            end
            state.detail_cache[key] = { lines = lines, hls = hls }
            if M.is_open() and state.focused and state.focused.sub and state.focused.sub.path == key then
                if state.preview_pan and state.preview_pan.refresh then
                    state.preview_pan.refresh()
                end
            end
        end
    )
end

---@return string[] lines, table[] hls
local function preview_content()
    local item = state.focused
    if not item or item.kind ~= "submodule" then
        return { "", "  " .. GLYPH.entry .. " select a submodule" }, { { 1, 0, -1, "LvimUiPathDim" } }
    end
    local d = state.detail_cache[item.sub.path]
    if d then
        return d.lines, d.hls
    end
    return { "", "  loading …" }, { { 1, 0, -1, "LvimUiPathDim" } }
end

---@return table
local function build_preview()
    return {
        hide_cursor = true,
        filetype = "lvim-git-submodule-detail",
        size = function()
            return math.max(50, math.floor(vim.o.columns * 0.55)), 20
        end,
        render = preview_content,
        keys = function(_, pan)
            state.preview_pan = pan
        end,
        on_close = function()
            state.preview_pan = nil
        end,
    }
end

local function update_preview()
    local pan = state.preview_pan
    if pan and pan.win and api.nvim_win_is_valid(pan.win) and api.nvim_get_current_win() ~= pan.win then
        if pan.refresh then
            pan.refresh()
        end
    end
end

-- ── rebuild / refresh ──────────────────────────────────────────────────────────────

local function rebuild()
    if not M.is_open() then
        return
    end
    state.tabs[1].rows = build_rows()
    local idx = state.handle.cursor_index()
    state.handle.recalc()
    state.handle.focus_index(idx)
    update_preview()
end

--- Reload the submodule list + rebuild (repo events + post-mutation).
function M.refresh()
    if not M.is_open() then
        return
    end
    state.detail_cache = {}
    load(function()
        rebuild()
    end)
end

-- ── the cursor submodule ────────────────────────────────────────────────────────────

---@return table?
local function cur_item()
    local name = state.handle and state.handle.cursor_name and state.handle.cursor_name()
    return name and state.registry[name] or nil
end

---@return table? sub
local function cur_sub()
    local item = cur_item()
    return item and item.kind == "submodule" and item.sub or nil
end

-- ── submodule actions (reuse the verb layer) ─────────────────────────────────────

--- Change the tab's cwd into the submodule under the cursor and open its lvim-git status.
function M.open_current()
    local sub = cur_sub()
    if not sub then
        return
    end
    local path = state.root .. "/" .. sub.path
    if vim.fn.isdirectory(path) ~= 1 then
        notify("submodule not initialized: " .. sub.path, vim.log.levels.WARN)
        return
    end
    vim.cmd("tcd " .. vim.fn.fnameescape(path))
    require("lvim-git").status()
end

local function update_current()
    local sub = cur_sub()
    if sub then
        actions.submodule_update(state.root, state.vcs, {}, sub.path)
    end
end
local function init_current()
    local sub = cur_sub()
    if sub then
        actions.submodule_init(state.root, state.vcs, sub.path)
    end
end
local function sync_current()
    local sub = cur_sub()
    if sub then
        actions.submodule_sync(state.root, state.vcs, {}, sub.path)
    end
end
local function deinit_current()
    local sub = cur_sub()
    if sub then
        actions.submodule_deinit(state.root, state.vcs, sub.path)
    end
end

-- ── help ────────────────────────────────────────────────────────────────────────────

local function show_help()
    ui.help({
        title = "Git Submodule keymaps",
        items = {
            { "j / k", "next / previous submodule" },
            { "<CR>", "open the submodule's own status" },
            { "u", "update the submodule" },
            { "i", "register (init) the submodule" },
            { "s", "synchronize the submodule URL" },
            { "a", "add a new submodule" },
            { "x", "unpopulate (deinit, confirm)" },
            { "T", "the full submodule transient" },
            { "<Tab>", "toggle the preview" },
            { "?", "dispatch (all commands)" },
            { "q / <Esc>", "close" },
        },
        close_keys = { "q", "<Esc>" },
    })
end

-- ── keymaps ──────────────────────────────────────────────────────────────────────────

---@return table[]
local function build_keymaps()
    return {
        { key = "u", run = update_current },
        { key = "i", run = init_current },
        { key = "s", run = sync_current },
        {
            key = "a",
            run = function()
                actions.submodule_add(state.root, state.vcs)
            end,
        },
        { key = "x", run = deinit_current },
        {
            key = "T",
            run = function()
                actions.register()
                require("lvim-git.transient").open("submodule", { root = state.root, lens = state.vcs })
            end,
        },
        { key = "g?", run = show_help },
        {
            key = "?",
            run = function()
                require("lvim-git.ui.dispatch").open()
            end,
        },
    }
end

-- ── autocmds ──────────────────────────────────────────────────────────────────────────

local function setup_autocmds()
    if state.augroup then
        pcall(api.nvim_del_augroup_by_id, state.augroup)
    end
    state.augroup = api.nvim_create_augroup("lvim-git.submodule", { clear = true })
    api.nvim_create_autocmd("User", {
        group = state.augroup,
        pattern = "LvimGitRepoChanged",
        callback = function()
            M.refresh()
        end,
    })
end

-- ── open / close ────────────────────────────────────────────────────────────────────

local function teardown()
    if state.augroup then
        pcall(api.nvim_del_augroup_by_id, state.augroup)
        state.augroup = nil
    end
    state.handle = nil
    state.tabs = nil
    state.preview_pan = nil
    state.registry = {}
    state.focused = nil
end

local function open_frame()
    state.tabs = { { label = "Submodules", icon = GLYPH.title, menu = true, rows = build_rows() } }
    state.handle = ui.tabs({
        title = { icon = GLYPH.title, text = "Git Submodules" },
        title_pos = "center",
        subtitle = logpanel.repo_band(state.root),
        tabs = state.tabs,
        layout = state.layout == "tab" and "float" or state.layout,
        pad = 0,
        cursorline_hl = "LvimUiCursorLine",
        content_width = 0.4,
        preview = build_preview(),
        preview_side = "right",
        keymaps = build_keymaps(),
        on_item_change = function(item)
            state.focused = item
            if item and item.kind == "submodule" then
                load_detail(item.sub)
            end
            update_preview()
        end,
        on_open = function()
            setup_autocmds()
        end,
        callback = function()
            teardown()
        end,
    })
end

--- Open the submodule panel. `opts = { layout?, lens? }`.
---@param opts? table
function M.open(opts)
    opts = opts or {}
    if not config.submodule.enabled then
        notify("the submodule component is disabled (submodule.enabled = false)", vim.log.levels.WARN)
        return
    end
    local root, vcs = backend.detect(api.nvim_get_current_buf())
    if not root then
        notify("not inside a git repository", vim.log.levels.WARN)
        return
    end
    local repo = backend.repo(root)
    if repo and repo.caps and not repo.caps.submodule then
        notify("this repo's backend has no submodules", vim.log.levels.WARN)
        return
    end
    if M.is_open() then
        state.handle.close()
    end
    actions.register()
    state.root, state.vcs = root, opts.lens or vcs
    state.detail_cache = {}
    state.layout = logpanel.layout_for("submodule", opts.layout)
    load(function()
        open_frame()
    end)
end

--- Close the panel.
function M.close()
    if M.is_open() then
        state.handle.close()
    end
end

--- Toggle the panel.
---@param opts? table
function M.toggle(opts)
    if M.is_open() then
        M.close()
    else
        M.open(opts)
    end
end

return M
