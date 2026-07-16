-- lvim-git.ui.worktree: the WORKTREE panel (Magit `magit-worktree`) — every linked worktree with its
-- path, branch/HEAD and lock state, a live recent-log preview, and the full worktree op set. A decoupled
-- COMPONENT over the shared core (backend / config), gated on `caps.worktree` (git worktrees; on the jj
-- lens the same verbs map to `jj workspace` in a later phase). Standalone (`:LvimGit worktree`).
--
-- It is a `lvim-ui.tabs` MENU surface (the stash/refs chassis): one `ui.section` fold header with a row
-- per worktree; the focused worktree's `git -C <path> log` renders in the chassis PREVIEW. Row/panel keys
-- reuse the verb layer (`actions.worktree_*`) so the panel and the worktree transient share ONE
-- implementation: `<CR>`/`o` switch into it, `a` add, `m` move, `x` remove, `l` lock, `L` unlock, `p`
-- prune, `T` transient. Refreshes on `User LvimGitRepoChanged`.
--
-- PUBLIC: open / is_open / close / toggle + list (async). Internal otherwise.
--
---@module "lvim-git.ui.worktree"

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
    title = "\u{f4d4}", --  nf-oct-file_directory_symlink (linked worktrees)
    fold = "\u{f0d7}", --  nf-fa-caret_down
    entry = "➤", -- the pointer canon (worktree row marker)
    lock = "\u{f023}", --  nf-fa-lock
    here = "\u{f00c}", --  nf-fa-check (the main / current worktree)
}

---@class LvimGitWorktreeState
---@field handle table?
---@field tabs table[]?
---@field root string?
---@field vcs string?
---@field worktrees table[]?
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

--- Whether the worktree panel is open.
---@return boolean
function M.is_open()
    return state.handle ~= nil and state.handle.valid ~= nil and state.handle.valid()
end

-- ── public read ────────────────────────────────────────────────────────────────

--- The worktree list (async) — the documented read.
---@param root? string
---@param cb fun(worktrees: table[]?)
function M.list(root, cb)
    backend.worktree_list(root, cb)
end

-- ── data load ────────────────────────────────────────────────────────────────────

---@param done fun()
local function load(done)
    backend.refresh(state.root, function()
        backend.worktree_list(state.root, function(list)
            state.worktrees = list or {}
            done()
        end)
    end)
end

-- ── rows ──────────────────────────────────────────────────────────────────────────

---@param wt table
---@return table
local function wt_row(wt)
    local name = "wt:" .. wt.path
    state.registry[name] = { kind = "worktree", wt = wt }
    local label, spans = "", {}
    local function seg(text, group)
        local s = #label
        label = label .. text
        if group then
            spans[#spans + 1] = { s, #label, group }
        end
    end
    seg(vim.fn.fnamemodify(wt.path, ":~"), "LvimGitRefBranch")
    if wt.bare then
        seg("  (bare)", "LvimUiPathDim")
    elseif wt.branch then
        seg("  [" .. wt.branch .. "]", "LvimGitRefHead")
    elseif wt.detached then
        seg("  (detached)", "LvimUiPathDim")
    end
    if wt.head then
        seg("  " .. wt.head, "LvimGitLogId")
    end
    if wt.locked then
        seg("  " .. GLYPH.lock, "LvimGitBehind")
    end
    return {
        type = "action",
        name = name,
        flat = true,
        tight = true,
        icon = " " .. (wt.main and GLYPH.here or GLYPH.entry) .. " ",
        icon_hl = wt.main and "LvimGitTransientOn" or "LvimGitRefHead",
        label = label,
        label_spans = spans,
        _item = { kind = "worktree", wt = wt },
        run = function()
            M.open_current()
        end,
    }
end

---@return table[]
local function build_rows()
    state.registry = {}
    local list = state.worktrees or {}
    if #list == 0 then
        return { { type = "spacer", name = "empty", label = "  No worktrees", hl = { inactive = "LvimUiPathDim" } } }
    end
    local children = {}
    for _, w in ipairs(list) do
        children[#children + 1] = wt_row(w)
    end
    local sa = hl.section_accent("blue")
    state.registry["worktrees"] = { kind = "section" }
    return {
        ui.section({
            name = "worktrees",
            icon = " " .. GLYPH.fold .. " ",
            box_hl = sa.text,
            label = "Worktrees",
            count = #children,
            accent = "blue",
            expanded = true,
            children = children,
        }),
    }
end

-- ── the preview (a worktree's recent log) ────────────────────────────────────────

---@param wt table
local function load_detail(wt)
    local key = wt.path
    if state.detail_cache[key] then
        if state.preview_pan and state.preview_pan.refresh then
            state.preview_pan.refresh()
        end
        return
    end
    backend.output(
        state.root,
        { config.git.cmd, "--no-optional-locks", "-c", "color.ui=false", "-C", wt.path, "log", "--oneline", "-15" },
        function(out)
            local lines, hls = {}, {}
            local head = wt.branch and ("[" .. wt.branch .. "]") or (wt.detached and "(detached)" or "")
            lines[#lines + 1] = vim.fn.fnamemodify(wt.path, ":~") .. "  " .. head
            hls[#hls + 1] = { 0, 0, -1, "LvimGitRefBranch" }
            if wt.locked then
                lines[#lines + 1] = "locked" .. (wt.lock_reason and (": " .. wt.lock_reason) or "")
                hls[#hls + 1] = { 1, 0, -1, "LvimGitBehind" }
            end
            lines[#lines + 1] = ""
            if out and vim.trim(out) ~= "" then
                for line in (out .. "\n"):gmatch("(.-)\n") do
                    if line ~= "" then
                        lines[#lines + 1] = line
                        local h = line:match("^(%x+)")
                        if h then
                            local n = #lines - 1
                            hls[#hls + 1] = { n, 0, #h, hl.section_accent("green").text } -- short id
                            hls[#hls + 1] = { n, #h + 1, -1, hl.section_accent("yellow").text } -- subject
                        end
                    end
                end
            end
            state.detail_cache[key] = { lines = lines, hls = hls }
            if M.is_open() and state.focused and state.focused.wt and state.focused.wt.path == key then
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
    if not item or item.kind ~= "worktree" then
        return { "", "  " .. GLYPH.entry .. " select a worktree" }, { { 1, 0, -1, "LvimUiPathDim" } }
    end
    local d = state.detail_cache[item.wt.path]
    if d then
        return d.lines, d.hls
    end
    return { "", "  loading …" }, { { 1, 0, -1, "LvimUiPathDim" } }
end

---@return table
local function build_preview()
    return {
        hide_cursor = true,
        filetype = "lvim-git-worktree-detail",
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

--- Reload the worktree list + rebuild (repo events + post-mutation).
function M.refresh()
    if not M.is_open() then
        return
    end
    state.detail_cache = {}
    load(function()
        rebuild()
    end)
end

-- ── the cursor worktree ────────────────────────────────────────────────────────────

---@return table?
local function cur_item()
    local name = state.handle and state.handle.cursor_name and state.handle.cursor_name()
    return name and state.registry[name] or nil
end

---@return table? wt
local function cur_wt()
    local item = cur_item()
    return item and item.kind == "worktree" and item.wt or nil
end

-- ── worktree actions (reuse the verb layer) ──────────────────────────────────────

--- Switch the current tab into the worktree under the cursor and open its status.
function M.open_current()
    local wt = cur_wt()
    if wt then
        actions.worktree_open(wt.path)
    end
end

local function move_current()
    local wt = cur_wt()
    if wt then
        actions.worktree_move(state.root, state.vcs, wt.path)
    end
end
local function remove_current()
    local wt = cur_wt()
    if wt then
        actions.worktree_remove(state.root, state.vcs, wt.path)
    end
end
local function lock_current()
    local wt = cur_wt()
    if wt then
        actions.worktree_lock(state.root, state.vcs, wt.path)
    end
end
local function unlock_current()
    local wt = cur_wt()
    if wt then
        actions.worktree_unlock(state.root, state.vcs, wt.path)
    end
end

-- ── help ────────────────────────────────────────────────────────────────────────────

local function show_help()
    ui.help({
        title = "Git Worktree keymaps",
        items = {
            { "j / k", "next / previous worktree" },
            { "<CR> / o", "switch into the worktree (open its status)" },
            { "a", "add a new worktree" },
            { "m", "move the worktree" },
            { "x", "remove the worktree (confirm)" },
            { "l", "lock the worktree" },
            { "L", "unlock the worktree" },
            { "p", "prune stale worktree entries" },
            { "T", "the full worktree transient" },
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
        { key = "o", run = M.open_current },
        {
            key = "a",
            run = function()
                actions.worktree_add(state.root, state.vcs, {})
            end,
        },
        { key = "m", run = move_current },
        { key = "x", run = remove_current },
        { key = "l", run = lock_current },
        { key = "L", run = unlock_current },
        {
            key = "p",
            run = function()
                actions.worktree_prune(state.root, state.vcs)
            end,
        },
        {
            key = "T",
            run = function()
                actions.register()
                require("lvim-git.transient").open("worktree", { root = state.root, lens = state.vcs })
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
    state.augroup = api.nvim_create_augroup("lvim-git.worktree", { clear = true })
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
    state.tabs = { { label = "Worktrees", icon = GLYPH.title, menu = true, rows = build_rows() } }
    state.handle = ui.tabs({
        title = { icon = GLYPH.title, text = "Git Worktrees" },
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
            if item and item.kind == "worktree" then
                load_detail(item.wt)
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

--- Open the worktree panel. `opts = { layout?, lens? }`.
---@param opts? table
function M.open(opts)
    opts = opts or {}
    if not config.worktree.enabled then
        notify("the worktree component is disabled (worktree.enabled = false)", vim.log.levels.WARN)
        return
    end
    local root, vcs = backend.detect(api.nvim_get_current_buf())
    if not root then
        notify("not inside a git repository", vim.log.levels.WARN)
        return
    end
    local repo = backend.repo(root)
    if repo and repo.caps and not repo.caps.worktree then
        notify("this repo's backend has no worktrees", vim.log.levels.WARN)
        return
    end
    if M.is_open() then
        state.handle.close()
    end
    actions.register()
    state.root, state.vcs = root, opts.lens or vcs
    state.detail_cache = {}
    state.layout = logpanel.layout_for("worktree", opts.layout)
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
