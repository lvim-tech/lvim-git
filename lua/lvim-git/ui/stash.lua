-- lvim-git.ui.stash: the STASH panel (Magit `magit-stash-list`) — the stash entries with a live diff
-- preview and the full stash op set. A decoupled COMPONENT over the shared core (backend / config), gated
-- on `caps.stash` (git only; jj sidesteps stash with `jj new`). Standalone (`:LvimGit stash`). It is a
-- `lvim-ui.tabs` MENU surface (the status/refs chassis): one `ui.section` fold header with a row per stash
-- (ref + message), and a live PREVIEW of that stash's diff (`git stash show -p`). Row actions reuse the
-- verb layer (`actions.stash_*`) so the panel, the stash transient, and the status stashes section share
-- ONE implementation: `<CR>`/`v` show, `a` apply, `p` pop, `k` drop, `b` branch, `z` save, `K` clear;
-- `Z` opens the full stash transient. Refreshes on `User LvimGitRepoChanged`.
--
-- PUBLIC: open / is_open / close / toggle + list (async). Internal otherwise.
--
---@module "lvim-git.ui.stash"

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
    stash = "\u{f01c}", --  nf-fa-inbox (title)
    git = "\u{e725}", --  nf-dev-git_branch (repo band)
    entry = "➤", -- the pointer canon (stash row marker)
    fold = "\u{f0d7}", --  nf-fa-caret_down
}

---@class LvimGitStashState
---@field handle table?
---@field tabs table[]?
---@field root string?
---@field vcs string?
---@field stashes { ref: string, message: string }[]?
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

--- Whether the stash panel is open.
---@return boolean
function M.is_open()
    return state.handle ~= nil and state.handle.valid ~= nil and state.handle.valid()
end

-- ── public reads ────────────────────────────────────────────────────────────────

--- The stash list (async) — the documented read.
---@param root? string
---@param cb fun(stashes: { ref: string, message: string }[]?)
function M.list(root, cb)
    backend.stash_list(root, cb)
end

-- ── data load ────────────────────────────────────────────────────────────────────

--- Load the stash list, then `done()`.
---@param done fun()
local function load(done)
    backend.refresh(state.root, function()
        backend.stash_list(state.root, function(list)
            state.stashes = list or {}
            done()
        end)
    end)
end

-- ── rows ──────────────────────────────────────────────────────────────────────────

--- One stash row: the ref + its message, `_item` carrying the ref for the row actions.
---@param stash { ref: string, message: string }
---@return table
local function stash_row(stash)
    local name = "stash:" .. stash.ref
    state.registry[name] = { kind = "stash", ref = stash.ref, message = stash.message }
    local label, spans = "", {}
    local function seg(text, group)
        local s = #label
        label = label .. text
        if group then
            spans[#spans + 1] = { s, #label, group }
        end
    end
    seg(stash.ref, "LvimGitRefBookmark")
    seg("  " .. (stash.message or ""), "LvimUiPathName")
    return {
        type = "action",
        name = name,
        flat = true,
        tight = true,
        icon = " " .. GLYPH.entry .. " ",
        icon_hl = "LvimGitRefBookmark",
        label = label,
        label_spans = spans,
        _item = { kind = "stash", ref = stash.ref, message = stash.message },
        run = function()
            M.show_current()
        end,
    }
end

---@return table[]
local function build_rows()
    state.registry = {}
    local list = state.stashes or {}
    if #list == 0 then
        return { { type = "spacer", name = "empty", label = "  No stashes", hl = { inactive = "LvimUiPathDim" } } }
    end
    local children = {}
    for _, s in ipairs(list) do
        children[#children + 1] = stash_row(s)
    end
    local sa = hl.section_accent("cyan")
    state.registry["stashes"] = { kind = "section" }
    return {
        ui.section({
            name = "stashes",
            icon = " " .. GLYPH.fold .. " ",
            box_hl = sa.text,
            label = "Stashes",
            count = #children,
            accent = "cyan",
            expanded = true,
            children = children,
        }),
    }
end

-- ── the preview (a stash's diff) ──────────────────────────────────────────────────

---@param ref string
local function load_detail(ref)
    if state.detail_cache[ref] then
        if state.preview_pan and state.preview_pan.refresh then
            state.preview_pan.refresh()
        end
        return
    end
    backend.output(
        state.root,
        { config.git.cmd, "--no-optional-locks", "-c", "color.ui=false", "stash", "show", "-p", ref },
        function(out)
            local lines, hls = {}, {}
            lines[#lines + 1] = ref
            hls[#hls + 1] = { 0, 0, -1, "LvimGitRefBookmark" }
            lines[#lines + 1] = ""
            for line in ((out or "") .. "\n"):gmatch("(.-)\n") do
                local first = line:sub(1, 1)
                lines[#lines + 1] = line
                if line:match("^@@") then
                    hls[#hls + 1] = { #lines - 1, 0, -1, "LvimGitLogId" }
                elseif first == "+" and not line:match("^%+%+%+") then
                    hls[#hls + 1] = { #lines - 1, 0, -1, "LvimGitDiffAdd" }
                elseif first == "-" and not line:match("^%-%-%-") then
                    hls[#hls + 1] = { #lines - 1, 0, -1, "LvimGitDiffDelete" }
                end
            end
            if #lines == 2 then
                lines[#lines + 1] = "  (no changes)"
            end
            state.detail_cache[ref] = { lines = lines, hls = hls }
            if M.is_open() and state.focused and state.focused.ref == ref then
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
    if not item or item.kind ~= "stash" then
        return { "", "  " .. GLYPH.entry .. " select a stash" }, { { 1, 0, -1, "LvimUiPathDim" } }
    end
    local d = state.detail_cache[item.ref]
    if d then
        return d.lines, d.hls
    end
    return { "", "  loading …" }, { { 1, 0, -1, "LvimUiPathDim" } }
end

---@return table
local function build_preview()
    return {
        hide_cursor = true,
        filetype = "lvim-git-stash-detail",
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

--- Reload the stash list + rebuild (repo events + post-mutation).
function M.refresh()
    if not M.is_open() then
        return
    end
    state.detail_cache = {}
    load(function()
        rebuild()
    end)
end

-- ── the cursor stash ────────────────────────────────────────────────────────────────

---@return table?
local function cur_item()
    local name = state.handle and state.handle.cursor_name and state.handle.cursor_name()
    return name and state.registry[name] or nil
end

--- The ctx a row action passes so `actions.stash_*` operates on THIS stash (no re-pick).
---@return string? ref
local function cur_ref()
    local item = cur_item()
    return item and item.kind == "stash" and item.ref or nil
end

-- ── stash actions (reuse the verb layer) ──────────────────────────────────────────

--- Show the stash under the cursor in the diffview.
function M.show_current()
    local ref = cur_ref()
    if ref then
        actions.stash_show(ref)
    end
end

local function apply_current()
    local ref = cur_ref()
    if ref then
        actions.stash_apply(state.root, state.vcs, ref)
    end
end
local function pop_current()
    local ref = cur_ref()
    if ref then
        actions.stash_pop(state.root, state.vcs, ref)
    end
end
local function drop_current()
    local ref = cur_ref()
    if ref then
        actions.stash_drop(state.root, state.vcs, ref)
    end
end
local function branch_current()
    local ref = cur_ref()
    if ref then
        actions.stash_branch(state.root, state.vcs, ref)
    end
end

-- ── help ────────────────────────────────────────────────────────────────────────────

local function show_help()
    ui.help({
        title = "Git Stash keymaps",
        items = {
            { "j / k", "next / previous stash" },
            { "<CR> / v", "show the stash diff" },
            { "a", "apply the stash" },
            { "p", "pop the stash (apply + drop)" },
            { "k", "drop the stash (confirm)" },
            { "b", "branch from the stash" },
            { "z", "save a new stash (push)" },
            { "K", "clear ALL stashes (confirm)" },
            { "Z", "the full stash transient" },
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
        { key = "v", run = M.show_current },
        { key = "a", run = apply_current },
        { key = "p", run = pop_current },
        { key = "k", run = drop_current },
        { key = "b", run = branch_current },
        {
            key = "z",
            run = function()
                actions.stash_push(state.root, state.vcs, {})
            end,
        },
        {
            key = "K",
            run = function()
                actions.stash_clear(state.root, state.vcs)
            end,
        },
        {
            key = "Z",
            run = function()
                actions.register()
                require("lvim-git.transient").open("stash", { root = state.root, lens = state.vcs })
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
    state.augroup = api.nvim_create_augroup("lvim-git.stash", { clear = true })
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
    state.tabs = { { label = "Stashes", icon = GLYPH.stash, menu = true, rows = build_rows() } }
    state.handle = ui.tabs({
        title = { icon = GLYPH.stash, text = "Git Stashes" },
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
            if item and item.kind == "stash" then
                load_detail(item.ref)
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

--- Open the stash panel. `opts = { layout?, lens? }`.
---@param opts? table
function M.open(opts)
    opts = opts or {}
    if not config.stash.enabled then
        notify("the stash component is disabled (stash.enabled = false)", vim.log.levels.WARN)
        return
    end
    local root, vcs = backend.detect(api.nvim_get_current_buf())
    if not root then
        notify("not inside a git repository", vim.log.levels.WARN)
        return
    end
    local repo = backend.repo(root)
    if repo and repo.caps and not repo.caps.stash then
        notify("this repo's backend has no stash (use a new change instead)", vim.log.levels.WARN)
        return
    end
    if M.is_open() then
        state.handle.close()
    end
    actions.register()
    state.root, state.vcs = root, opts.lens or vcs
    state.detail_cache = {}
    state.layout = logpanel.layout_for("stash", opts.layout)
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
