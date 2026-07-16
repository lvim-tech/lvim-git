-- lvim-git.ui.oplog: the OPERATION LOG panel — jj's killer undo surface (and git's reflog analogue).
--
-- Caps-aware, ONE panel over two backends (the refs/stash chassis: a `lvim-ui.tabs` MENU with a live
-- preview):
--   * jj  (`caps.oplog`) — `jj op log`: every operation (snapshot / describe / new / squash / rebase /
--     bookmark / push …) newest-first, the head op marked current. Per-op actions `u` OP UNDO (revert
--     the last operation) and `r` OP RESTORE (jump the whole repo to any operation) — jj lets you undo
--     ANYTHING, including the undo. The preview shows `jj op show <id>` (what that operation changed).
--   * git (`caps.reflog`) — `git reflog`: HEAD history, read-mostly. `<CR>`/`v` VISIT checks out the
--     entry's commit (git's reflog offers jump/checkout only — it is not an undoable op log). The
--     preview shows `git show <sha> --stat`.
--
-- Row actions reuse the verb layer (`actions.op_undo` / `op_restore` / `reflog_visit`) so the panel and
-- any future dispatch entry share ONE implementation. Refreshes on `User LvimGitRepoChanged`. Standalone
-- (`:LvimGit oplog`).
--
-- PUBLIC: open / is_open / close / toggle + entries (async). Internal otherwise.
--
---@module "lvim-git.ui.oplog"

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
    oplog = "\u{f1da}", --  nf-fa-history (title)
    git = "\u{e725}", --  nf-dev-git_branch (repo band)
    entry = "➤", -- the pointer canon (op row marker)
    fold = "\u{f0d7}", --  nf-fa-caret_down
}

---@class LvimGitOplogState
---@field handle table?
---@field tabs table[]?
---@field root string?
---@field vcs string?
---@field is_jj boolean?          the backend is jj (op log) vs git (reflog)
---@field ops table[]?            { id, time, description, tags, current }[]
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

--- Whether the oplog panel is open.
---@return boolean
function M.is_open()
    return state.handle ~= nil and state.handle.valid ~= nil and state.handle.valid()
end

-- ── public reads ────────────────────────────────────────────────────────────────

--- The operation entries (async) — the jj op log or the git reflog, whichever the repo supports.
---@param root? string
---@param cb fun(ops: table[]?)
function M.entries(root, cb)
    local repo = backend.repo(root)
    if repo and repo.caps and repo.caps.oplog then
        backend.op_log(root, cb)
    else
        backend.reflog(root, cb)
    end
end

-- ── data load ────────────────────────────────────────────────────────────────────

--- Load the operation log / reflog, then `done()`.
---@param done fun()
local function load(done)
    backend.refresh(state.root, function()
        M.entries(state.root, function(ops)
            state.ops = ops or {}
            done()
        end)
    end)
end

-- ── rows ──────────────────────────────────────────────────────────────────────────

--- One operation row: id + time + description, plus the tags/args (jj) or the selector (git) dimmed.
---@param op table
---@return table
local function op_row(op)
    local name = "op:" .. op.id
    state.registry[name] = { kind = "op", id = op.id, current = op.current, op = op }
    local label, spans = "", {}
    local function seg(text, group)
        local s = #label
        label = label .. text
        if group then
            spans[#spans + 1] = { s, #label, group }
        end
    end
    seg(op.id, "LvimGitLogId")
    if op.time and op.time ~= "" then
        seg("  " .. op.time, "LvimUiPathDim")
    end
    seg("  " .. (op.description or ""), "LvimUiPathName")
    local extra = op.tags and op.tags ~= "" and op.tags or op.selector
    if extra and extra ~= "" then
        seg("  " .. extra, "LvimUiPathDim")
    end
    return {
        type = "action",
        name = name,
        flat = true,
        tight = true,
        icon = " " .. (op.current and GLYPH.entry or " ") .. " ",
        icon_hl = op.current and "LvimGitRefHead" or "LvimGitLogId",
        label = label,
        label_spans = spans,
        _item = state.registry[name],
        run = function()
            -- default activation: git = visit the entry; jj = a no-op (undo/restore are explicit keys).
            if not state.is_jj then
                M.visit_current()
            end
        end,
    }
end

---@return table[]
local function build_rows()
    state.registry = {}
    local list = state.ops or {}
    if #list == 0 then
        return { { type = "spacer", name = "empty", label = "  No operations", hl = { inactive = "LvimUiPathDim" } } }
    end
    local children = {}
    for _, op in ipairs(list) do
        children[#children + 1] = op_row(op)
    end
    local accent = state.is_jj and "magenta" or "blue"
    local sa = hl.section_accent(accent)
    state.registry["ops"] = { kind = "section" }
    return {
        ui.section({
            name = "ops",
            icon = " " .. GLYPH.fold .. " ",
            box_hl = sa.text,
            label = state.is_jj and "Operations" or "Reflog",
            count = #children,
            accent = accent,
            expanded = true,
            children = children,
        }),
    }
end

-- ── the preview (an operation's diff) ──────────────────────────────────────────────

--- Build the argv for the preview of one operation: jj → `jj op show <id>`; git → `git show <sha> --stat`.
---@param id string
---@return string[]
local function detail_argv(id)
    if state.is_jj then
        return { config.jj.cmd, "--color=never", "op", "show", id, "--no-graph" }
    end
    return { config.git.cmd, "--no-optional-locks", "-c", "color.ui=false", "show", "--stat", id }
end

---@param id string
local function load_detail(id)
    if state.detail_cache[id] then
        if state.preview_pan and state.preview_pan.refresh then
            state.preview_pan.refresh()
        end
        return
    end
    backend.output(state.root, detail_argv(id), function(out)
        local lines, hls = {}, {}
        lines[#lines + 1] = id
        hls[#hls + 1] = { 0, 0, -1, "LvimGitLogId" }
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
            lines[#lines + 1] = "  (no detail)"
        end
        state.detail_cache[id] = { lines = lines, hls = hls }
        if M.is_open() and state.focused and state.focused.id == id then
            if state.preview_pan and state.preview_pan.refresh then
                state.preview_pan.refresh()
            end
        end
    end)
end

---@return string[] lines, table[] hls
local function preview_content()
    local item = state.focused
    if not item or item.kind ~= "op" then
        return { "", "  " .. GLYPH.entry .. " select an operation" }, { { 1, 0, -1, "LvimUiPathDim" } }
    end
    local d = state.detail_cache[item.id]
    if d then
        return d.lines, d.hls
    end
    return { "", "  loading …" }, { { 1, 0, -1, "LvimUiPathDim" } }
end

---@return table
local function build_preview()
    return {
        hide_cursor = true,
        filetype = "lvim-git-oplog-detail",
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

--- Reload the operation log + rebuild (repo events + post-mutation).
function M.refresh()
    if not M.is_open() then
        return
    end
    state.detail_cache = {}
    load(function()
        rebuild()
    end)
end

-- ── the cursor operation ────────────────────────────────────────────────────────────

---@return table?
local function cur_item()
    local name = state.handle and state.handle.cursor_name and state.handle.cursor_name()
    return name and state.registry[name] or nil
end

---@return string? id
local function cur_id()
    local item = cur_item()
    return item and item.kind == "op" and item.id or nil
end

-- ── operation actions (reuse the verb layer) ───────────────────────────────────────

--- Undo the LAST jj operation (`jj op revert`). jj-only.
function M.undo_last()
    if not state.is_jj then
        notify("git reflog has no undo (use reset / checkout)", vim.log.levels.WARN)
        return
    end
    actions.op_undo(state.root, state.vcs, function()
        M.refresh()
    end)
end

--- Restore the repo to the operation under the cursor (`jj op restore <id>`). jj-only.
function M.restore_current()
    if not state.is_jj then
        notify("git reflog has no restore (use reset / checkout)", vim.log.levels.WARN)
        return
    end
    local id = cur_id()
    if id then
        actions.op_restore(state.root, state.vcs, id, function()
            M.refresh()
        end)
    end
end

--- Visit (checkout) the reflog entry under the cursor. git-only.
function M.visit_current()
    if state.is_jj then
        return
    end
    local id = cur_id()
    if id then
        actions.reflog_visit(state.root, id)
    end
end

-- ── help ────────────────────────────────────────────────────────────────────────────

local function show_help()
    local items
    if state.is_jj then
        items = {
            { "j / k", "next / previous operation" },
            { "u", "op undo (revert the LAST operation)" },
            { "r", "op restore (jump the repo to this operation)" },
            { "<Tab>", "toggle the preview (jj op show)" },
            { "?", "dispatch (all commands)" },
            { "q / <Esc>", "close" },
        }
    else
        items = {
            { "j / k", "next / previous reflog entry" },
            { "<CR> / v", "checkout this entry's commit (detaches HEAD)" },
            { "<Tab>", "toggle the preview (git show --stat)" },
            { "?", "dispatch (all commands)" },
            { "q / <Esc>", "close" },
        }
    end
    ui.help({
        title = state.is_jj and "jj Operation Log keymaps" or "git Reflog keymaps",
        items = items,
        close_keys = { "q", "<Esc>" },
    })
end

-- ── keymaps ──────────────────────────────────────────────────────────────────────────

---@return table[]
local function build_keymaps()
    local maps = {
        { key = "g?", run = show_help },
        {
            key = "?",
            run = function()
                require("lvim-git.ui.dispatch").open()
            end,
        },
    }
    if state.is_jj then
        maps[#maps + 1] = { key = "u", run = M.undo_last }
        maps[#maps + 1] = { key = "r", run = M.restore_current }
    else
        maps[#maps + 1] = { key = "v", run = M.visit_current }
    end
    return maps
end

-- ── autocmds ──────────────────────────────────────────────────────────────────────────

local function setup_autocmds()
    if state.augroup then
        pcall(api.nvim_del_augroup_by_id, state.augroup)
    end
    state.augroup = api.nvim_create_augroup("lvim-git.oplog", { clear = true })
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
    local tab_label = state.is_jj and "Operations" or "Reflog"
    state.tabs = { { label = tab_label, icon = GLYPH.oplog, menu = true, rows = build_rows() } }
    state.handle = ui.tabs({
        title = { icon = GLYPH.oplog, text = state.is_jj and "jj Operation Log" or "git Reflog" },
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
            if item and item.kind == "op" then
                load_detail(item.id)
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

--- Open the operation-log / reflog panel. `opts = { layout?, lens? }`.
---@param opts? table
function M.open(opts)
    opts = opts or {}
    if not config.oplog.enabled then
        notify("the oplog component is disabled (oplog.enabled = false)", vim.log.levels.WARN)
        return
    end
    local root, vcs = backend.detect(api.nvim_get_current_buf())
    if not root then
        notify("not inside a repository", vim.log.levels.WARN)
        return
    end
    local repo = backend.repo(root)
    local caps = (repo and repo.caps) or {}
    if not caps.oplog and not caps.reflog then
        notify("this repo's backend has neither an operation log nor a reflog", vim.log.levels.WARN)
        return
    end
    if M.is_open() then
        state.handle.close()
    end
    actions.register()
    state.root, state.vcs = root, opts.lens or vcs
    state.is_jj = caps.oplog == true
    state.detail_cache = {}
    state.layout = logpanel.layout_for("oplog", opts.layout)
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
