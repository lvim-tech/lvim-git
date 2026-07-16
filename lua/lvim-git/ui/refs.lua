-- lvim-git.ui.refs: the REFS panel (Magit `magit-show-refs`) — branches / remote branches / tags with
-- their tracking + ahead/behind, plus the `magit-cherry` view (commits not yet in the upstream). A
-- decoupled COMPONENT over the shared core (backend / config), standalone (`:LvimGit refs`). It is a
-- `lvim-ui.tabs` MENU surface (the status chassis): one `ui.section` fold header per ref kind (local /
-- remote / tags), each ref a row showing its tracking + ahead/behind badges, with a live PREVIEW of the
-- ref's recent commits. Ref-context actions: checkout/edit (`<CR>`/`k`), create (`a`), delete (`d`,
-- confirmed), rename (`r`); `Y` opens the cherry view. Refreshes on `User LvimGitRepoChanged`.
--
-- PUBLIC: open / is_open / close / toggle + list (async) / current (render-safe) / cherry.
--
---@module "lvim-git.ui.refs"

local api = vim.api
local config = require("lvim-git.config")
local backend = require("lvim-git.backend")
local logpanel = require("lvim-git.ui.logpanel")
local ui = require("lvim-ui")
local hl = require("lvim-utils.highlight")

local M = {}

-- ── glyphs (verified single-width Nerd Font, + the `➤` pointer canon) ──────────
local GLYPH = {
    git = "\u{e725}", --  nf-dev-git_branch (title + repo band)
    branch = "\u{e725}", --  nf-dev-git_branch
    remote = "\u{f0c2}", --  nf-fa-cloud
    tag = "\u{f02b}", --  nf-fa-tag
    ahead = "\u{f062}", --  nf-fa-arrow_up
    behind = "\u{f063}", --  nf-fa-arrow_down
    arrow = "➤", -- the pointer canon (tracking + current marker)
}

--- The ref-kind sections in render order.
---@type { id: string, title: string, accent: string, kind: string, icon: string, hl: string }[]
local SECTIONS = {
    {
        id = "local",
        title = "Branches",
        accent = "green",
        kind = "local",
        icon = GLYPH.branch,
        hl = "LvimGitRefBranch",
    },
    -- jj bookmarks (kind "bookmark"): the git-branch analogue. Empty on a git repo → the section
    -- auto-hides; populated on a jj repo. Delete/rename/checkout are caps-mapped to `jj bookmark`/`jj edit`.
    {
        id = "bookmark",
        title = "Bookmarks",
        accent = "green",
        kind = "bookmark",
        icon = GLYPH.branch,
        hl = "LvimGitRefBookmark",
    },
    {
        id = "remote",
        title = "Remotes",
        accent = "magenta",
        kind = "remote",
        icon = GLYPH.remote,
        hl = "LvimGitRefRemote",
    },
    { id = "tag", title = "Tags", accent = "yellow", kind = "tag", icon = GLYPH.tag, hl = "LvimGitRefTag" },
}

---@class LvimGitRefsState
---@field handle table?
---@field tabs table[]?
---@field root string?
---@field vcs string?
---@field refs Ref[]?
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

--- Whether the refs panel is open.
---@return boolean
function M.is_open()
    return state.handle ~= nil and state.handle.valid ~= nil and state.handle.valid()
end

-- ── public reads ────────────────────────────────────────────────────────────────

--- Branches/remotes/tags (async) — the documented read.
---@param root? string
---@param cb fun(refs: Ref[]?)
function M.list(root, cb)
    backend.refs(root, cb)
end

--- The current local branch (render-safe cached).
---@param root? string
---@return string?
function M.current(root)
    return backend.branch(root)
end

-- ── data load ────────────────────────────────────────────────────────────────

--- Load the ref list, then `done()`.
---@param done fun()
local function load(done)
    backend.refresh(state.root, function()
        backend.refs(state.root, function(refs)
            state.refs = refs or {}
            done()
        end)
    end)
end

--- The refs of a given kind.
---@param kind string
---@return Ref[]
local function refs_of(kind)
    local out = {}
    for _, r in ipairs(state.refs or {}) do
        if r.kind == kind then
            out[#out + 1] = r
        end
    end
    return out
end

-- ── rows ────────────────────────────────────────────────────────────────────────

--- One ref row: name + tracking + ahead/behind, marking the current branch.
---@param sec { id: string, kind: string, icon: string, hl: string }
---@param ref Ref
---@return table
local function ref_row(sec, ref)
    local name = sec.id .. ":" .. ref.name
    state.registry[name] = { kind = "ref", ref = ref, section = sec.id }
    local is_current = (sec.kind == "local" or sec.kind == "bookmark") and ref.name == backend.branch(state.root)
    local label, spans = "", {}
    local function seg(text, group)
        local s = #label
        label = label .. text
        if group then
            spans[#spans + 1] = { s, #label, group }
        end
    end
    seg(ref.name, is_current and "LvimGitRefHead" or sec.hl)
    if ref.tracking and ref.tracking ~= "" then
        seg("  " .. GLYPH.arrow .. " " .. ref.tracking, "LvimGitRefRemote")
    end
    if (ref.ahead or 0) > 0 then
        seg("  " .. GLYPH.ahead .. tostring(ref.ahead), "LvimGitAhead")
    end
    if (ref.behind or 0) > 0 then
        seg("  " .. GLYPH.behind .. tostring(ref.behind), "LvimGitBehind")
    end
    if ref.conflicted then
        seg("  " .. GLYPH.arrow .. " conflicted", "LvimGitConflictMarker")
    end
    return {
        type = "action",
        name = name,
        flat = true,
        tight = true,
        icon = " " .. ((is_current and GLYPH.arrow) or sec.icon) .. " ",
        icon_hl = is_current and "LvimGitRefHead" or sec.hl,
        label = label,
        label_spans = spans,
        _item = { kind = "ref", ref = ref },
        run = function()
            M.checkout_current()
        end,
    }
end

---@return table[]
local function build_rows()
    state.registry = {}
    local rows = {}
    for _, sec in ipairs(SECTIONS) do
        local list = refs_of(sec.kind)
        if #list > 0 then
            local children = {}
            for _, r in ipairs(list) do
                children[#children + 1] = ref_row(sec, r)
            end
            local sa = hl.section_accent(sec.accent)
            rows[#rows + 1] = ui.section({
                name = sec.id,
                icon = " " .. "\u{f0d7}" .. " ",
                box_hl = sa.text,
                label = sec.title,
                count = #children,
                accent = sec.accent,
                expanded = true,
                children = children,
            })
            state.registry[sec.id] = { kind = "section", id = sec.id }
        end
    end
    if #rows == 0 then
        rows[#rows + 1] = { type = "spacer", name = "empty", label = "  No refs", hl = { inactive = "LvimUiPathDim" } }
    end
    return rows
end

-- ── the preview (a ref's recent commits) ────────────────────────────────────────

---@param ref Ref
local function load_detail(ref)
    local key = ref.kind .. ":" .. ref.name
    if state.detail_cache[key] then
        if state.preview_pan and state.preview_pan.refresh then
            state.preview_pan.refresh()
        end
        return
    end
    backend.log({ root_or_buf = state.root, revset = ref.name, limit = 20 }, function(commits)
        local lines, hls = {}, {}
        lines[#lines + 1] = ref.name .. "  (" .. (ref.target or "") .. ")"
        hls[#hls + 1] = { 0, 0, -1, "LvimGitRefHead" }
        lines[#lines + 1] = ""
        for _, c in ipairs(commits or {}) do
            lines[#lines + 1] = (c.abbrev or "") .. "  " .. (c.subject or "")
            hls[#hls + 1] = { #lines - 1, 0, 8, "LvimGitLogId" }
        end
        if #lines == 2 then
            lines[#lines + 1] = "  (no commits)"
        end
        state.detail_cache[key] = { lines = lines, hls = hls }
        if M.is_open() and state.focused and state.focused.ref and state.focused.ref.name == ref.name then
            if state.preview_pan and state.preview_pan.refresh then
                state.preview_pan.refresh()
            end
        end
    end)
end

---@return string[] lines, table[] hls
local function preview_content()
    local item = state.focused
    if not item or item.kind ~= "ref" then
        return { "", "  " .. GLYPH.arrow .. " select a ref" }, { { 1, 0, -1, "LvimUiPathDim" } }
    end
    local key = item.ref.kind .. ":" .. item.ref.name
    local d = state.detail_cache[key]
    if d then
        return d.lines, d.hls
    end
    return { "", "  loading …" }, { { 1, 0, -1, "LvimUiPathDim" } }
end

---@return table
local function build_preview()
    return {
        hide_cursor = true,
        filetype = "lvim-git-refs-detail",
        size = function()
            return math.max(48, math.floor(vim.o.columns * 0.5)), 20
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

-- ── rebuild / refresh ────────────────────────────────────────────────────────────

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

--- Reload the ref list + rebuild (repo events + post-mutation).
function M.refresh()
    if not M.is_open() then
        return
    end
    state.detail_cache = {}
    load(function()
        rebuild()
    end)
end

-- ── the cursor ref ────────────────────────────────────────────────────────────────

---@return table?
local function cur_item()
    local name = state.handle and state.handle.cursor_name and state.handle.cursor_name()
    return name and state.registry[name] or nil
end

-- ── ref actions ────────────────────────────────────────────────────────────────

--- True when the panel's lens is jj (bookmarks, not git branches).
---@return boolean
local function is_jj()
    return state.vcs == "jj"
end

--- Checkout / edit the ref under the cursor. git → `git checkout <name>`; jj → `jj edit <bookmark>`
--- (move `@` onto the bookmark's change).
function M.checkout_current()
    local item = cur_item()
    if not item or item.kind ~= "ref" then
        return
    end
    if is_jj() then
        require("lvim-git.actions").execute(
            state.root,
            { "edit", item.ref.name },
            { op = "edit", vcs = "jj", head_changed = true }
        )
        return
    end
    require("lvim-git.actions").execute(
        state.root,
        { "checkout", item.ref.name },
        { op = "checkout", vcs = state.vcs, head_changed = true }
    )
end

--- Create a new branch (git) / bookmark (jj) at HEAD/`@`.
local function create_branch()
    ui.input({
        title = is_jj() and "New bookmark name" or "New branch name",
        callback = function(ok, name)
            if ok and name and vim.trim(name) ~= "" then
                local argv = is_jj() and { "bookmark", "create", vim.trim(name), "-r", "@" }
                    or { "checkout", "-b", vim.trim(name) }
                require("lvim-git.actions").execute(
                    state.root,
                    argv,
                    { op = is_jj() and "bookmark" or "branch", vcs = state.vcs, head_changed = true }
                )
            end
        end,
    })
end

--- Delete the ref under the cursor (branch/tag; confirmed when `confirm_destructive`).
local function delete_current()
    local item = cur_item()
    if not item or item.kind ~= "ref" then
        return
    end
    local ref = item.ref
    local argv
    if is_jj() then
        if item.section == "bookmark" then
            argv = { "bookmark", "delete", ref.name }
        else
            notify("delete a remote bookmark via git push", vim.log.levels.WARN)
            return
        end
    elseif item.section == "local" then
        argv = { "branch", "-D", ref.name }
    elseif item.section == "tag" then
        argv = { "tag", "-d", ref.name }
    else
        notify("delete a remote branch via push --delete", vim.log.levels.WARN)
        return
    end
    local function go()
        require("lvim-git.actions").execute(state.root, argv, { op = "delete", vcs = state.vcs })
    end
    if config.confirm_destructive then
        ui.confirm({
            prompt = ("Delete %s %s?"):format(item.section, ref.name),
            callback = function(yes)
                if yes then
                    go()
                end
            end,
        })
    else
        go()
    end
end

--- Rename the local branch (git) / bookmark (jj) under the cursor.
local function rename_current()
    local item = cur_item()
    if not item or item.kind ~= "ref" or not (item.section == "local" or item.section == "bookmark") then
        notify("rename applies to a local branch / bookmark", vim.log.levels.WARN)
        return
    end
    ui.input({
        title = "Rename " .. item.ref.name .. " to",
        default = item.ref.name,
        callback = function(ok, name)
            if ok and name and vim.trim(name) ~= "" then
                local argv = is_jj() and { "bookmark", "rename", item.ref.name, vim.trim(name) }
                    or { "branch", "-m", item.ref.name, vim.trim(name) }
                require("lvim-git.actions").execute(
                    state.root,
                    argv,
                    { op = is_jj() and "bookmark" or "branch", vcs = state.vcs, head_changed = true }
                )
            end
        end,
    })
end

-- ── cherry view (magit-cherry) ──────────────────────────────────────────────────

--- Open the cherry view: commits on the current branch not yet in the upstream (`git cherry`). Reuses
--- the shared logpanel; `<CR>`/`a` open the per-commit actions.
---@param root? string
function M.cherry(root)
    root = root or state.root or backend.detect(api.nvim_get_current_buf())
    if not root then
        notify("not inside a git repository", vim.log.levels.WARN)
        return
    end
    local repo = backend.repo(root)
    local upstream = repo and repo.upstream
    if not upstream or upstream == "" then
        notify("no upstream configured for the current branch", vim.log.levels.WARN)
        return
    end
    require("lvim-git.actions").register()
    local vcs = state.vcs or (repo and repo.vcs)
    logpanel.open({
        view = "refs",
        root = root,
        vcs = vcs,
        title = { icon = GLYPH.git, text = "Cherry (not in " .. upstream .. ")" },
        subtitle = logpanel.repo_band(root, "cherry " .. GLYPH.arrow .. " " .. upstream),
        layout = logpanel.layout_for("refs", nil),
        graph = false,
        load = function(cb)
            backend.output(root, { config.git.cmd, "--no-optional-locks", "cherry", "-v", upstream }, function(out)
                ---@type Commit[]
                local commits = {}
                for line in ((out or "") .. "\n"):gmatch("(.-)\n") do
                    local sign, sha, subject = line:match("^([+%-])%s+(%x+)%s*(.*)$")
                    if sign == "+" then
                        commits[#commits + 1] = {
                            id = sha,
                            abbrev = sha:sub(1, 8),
                            parents = {},
                            author = "",
                            date = 0,
                            subject = subject or "",
                            refs = {},
                        }
                    end
                end
                cb(commits)
            end)
        end,
        on_action = function(commit)
            require("lvim-git.actions").commit_actions(commit, root, vcs)
        end,
        on_view_diff = function(commit)
            require("lvim-git.actions").view_commit_diff(commit)
        end,
    })
end

-- ── help ────────────────────────────────────────────────────────────────────────

local function show_help()
    ui.help({
        title = "Git Refs keymaps",
        items = {
            { "j / k", "next / previous ref" },
            { "<CR> / c", "checkout / edit the ref" },
            { "a", "create a new branch" },
            { "d", "delete the ref (confirm)" },
            { "r", "rename the local branch" },
            { "Y", "cherry (commits not in the upstream)" },
            { "<Tab>", "toggle the preview" },
            { "?", "dispatch (all commands)" },
            { "q / <Esc>", "close" },
        },
        close_keys = { "q", "<Esc>" },
    })
end

-- ── keymaps ──────────────────────────────────────────────────────────────────────

---@return table[]
local function build_keymaps()
    return {
        { key = "c", run = M.checkout_current },
        { key = "a", run = create_branch },
        { key = "d", run = delete_current },
        { key = "r", run = rename_current },
        {
            key = "Y",
            run = function()
                M.cherry(state.root)
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

-- ── autocmds ──────────────────────────────────────────────────────────────────────

local function setup_autocmds()
    if state.augroup then
        pcall(api.nvim_del_augroup_by_id, state.augroup)
    end
    state.augroup = api.nvim_create_augroup("lvim-git.refs", { clear = true })
    api.nvim_create_autocmd("User", {
        group = state.augroup,
        pattern = "LvimGitRepoChanged",
        callback = function()
            M.refresh()
        end,
    })
end

-- ── open / close ────────────────────────────────────────────────────────────────

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
    state.tabs = { { label = "Refs", icon = GLYPH.git, menu = true, rows = build_rows() } }
    state.handle = ui.tabs({
        title = { icon = GLYPH.git, text = "Git Refs" },
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
            if item and item.kind == "ref" then
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

--- Open the refs panel. `opts = { layout?, lens? }`.
---@param opts? table
function M.open(opts)
    opts = opts or {}
    if not config.refs.enabled then
        notify("the refs component is disabled (refs.enabled = false)", vim.log.levels.WARN)
        return
    end
    local root, vcs = backend.detect(api.nvim_get_current_buf())
    if not root then
        notify("not inside a git repository", vim.log.levels.WARN)
        return
    end
    if M.is_open() then
        state.handle.close()
    end
    require("lvim-git.actions").register()
    state.root, state.vcs = root, opts.lens or vcs
    state.detail_cache = {}
    state.layout = logpanel.layout_for("refs", opts.layout)
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
