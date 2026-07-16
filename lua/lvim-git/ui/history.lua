-- lvim-git.ui.history: the FILE-HISTORY panel — the log chassis scoped to a PATH (or a line range). A
-- decoupled COMPONENT over the shared core (backend / model.graph / config), standalone
-- (`:LvimGit history [path]`, visual `:'<,'>LvimGit history` → `-L`). It composes the shared
-- `ui/logpanel` chassis, so it shares the commit rows + detail preview + per-commit action popup with
-- the log panel WITHOUT depending on it (both require only the shared logpanel infra).
--
-- Two modes: WHOLE-FILE history follows renames (`git log --follow -- <path>`); a VISUAL LINE RANGE
-- runs `git log -L<lo>,<hi>:<path>` (rename-aware line history). `<CR>`/`a` open the per-commit actions;
-- `d` (view-diff) opens that revision's change to THIS file in the diffview.
--
-- PUBLIC: open.
--
---@module "lvim-git.ui.history"

local config = require("lvim-git.config")
local backend = require("lvim-git.backend")
local logpanel = require("lvim-git.ui.logpanel")

local M = {}

local GLYPH = { history = "\u{f1da}" } --  nf-fa-history
local EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

---@class LvimGitHistoryState
---@field handle table?  the logpanel handle
---@field root string?
---@field vcs string?
---@field path string?   the repo-relative file path
---@field L table?       { lo, hi } line range (nil = whole-file history)
local state = {}

---@param msg string
---@param level? integer
local function notify(msg, level)
    vim.notify("lvim-git: " .. msg, level or vim.log.levels.INFO)
end

--- Whether the history panel is open.
---@return boolean
function M.is_open()
    return state.handle ~= nil and state.handle.is_open and state.handle.is_open()
end

--- Resolve the target file to a repo-relative path (from an explicit arg, `%`, or the current buffer).
---@param root string
---@param arg? string
---@return string?
local function resolve_path(root, arg)
    local abs
    if arg and arg ~= "" and arg ~= "%" then
        abs = vim.fn.fnamemodify(arg, ":p")
    else
        local name = vim.api.nvim_buf_get_name(0)
        if name == "" then
            return nil
        end
        abs = vim.fn.fnamemodify(name, ":p")
    end
    abs = vim.fs.normalize(abs)
    local rel = abs:gsub("^" .. vim.pesc(vim.fs.normalize(root)) .. "/", "")
    return rel
end

--- Fetch the commit list for the history scope (whole-file `--follow` or a `-L` line range).
---@param cb fun(commits: Commit[])
local function load_commits(cb)
    local opts = { root_or_buf = state.root, limit = config.history.limit or 256 }
    if state.L then
        opts.L = { lo = state.L.lo, hi = state.L.hi, path = state.path }
    else
        opts.paths = { state.path }
        opts.follow = config.history.follow ~= false
    end
    backend.log(opts, function(commits)
        cb(commits or {})
    end)
end

--- Open this commit's change to the tracked file in the diffview (first parent → the commit, path-scoped).
---@param commit Commit
local function view_diff(commit)
    local base = (commit.parents and commit.parents[1]) or EMPTY_TREE
    local ok = pcall(function()
        require("lvim-git").diffview({ range = base .. ".." .. commit.id, paths = { state.path } })
    end)
    if not ok then
        notify("the diffview component is not available", vim.log.levels.WARN)
    end
end

--- Open the file-history panel. `opts = { path?, args?, line1?, line2?, layout?, lens? }`.
---@param opts? table
function M.open(opts)
    opts = opts or {}
    if not config.history.enabled then
        notify("the history component is disabled (history.enabled = false)", vim.log.levels.WARN)
        return
    end
    local root, vcs = backend.detect(vim.api.nvim_get_current_buf())
    if not root then
        notify("not inside a git repository", vim.log.levels.WARN)
        return
    end
    local path = resolve_path(root, opts.path or (opts.args and opts.args[1]))
    if not path then
        notify("no file to show history for (open a file or pass a path)", vim.log.levels.WARN)
        return
    end
    if M.is_open() then
        state.handle.close()
    end
    require("lvim-git.actions").register()
    state.root, state.vcs, state.path = root, opts.lens or vcs, path
    state.L = nil
    if opts.line1 and opts.line2 then
        local lo, hi = math.min(opts.line1, opts.line2), math.max(opts.line1, opts.line2)
        state.L = { lo = lo, hi = hi }
    end
    local layout = logpanel.layout_for("history", opts.layout)
    local scope = state.L and (("%s -L%d,%d"):format(path, state.L.lo, state.L.hi)) or path

    state.handle = logpanel.open({
        view = "history",
        root = root,
        vcs = state.vcs,
        title = { icon = GLYPH.history, text = "Git History" },
        subtitle = logpanel.repo_band(root, scope),
        layout = layout,
        graph = false, -- a path-filtered history is inherently linear; no full DAG to lay out
        load = load_commits,
        on_action = function(commit)
            require("lvim-git.actions").commit_actions(commit, root, state.vcs)
        end,
        on_view_diff = view_diff,
        help_items = { { "d", "view this revision's change to the file" } },
    })
end

--- Close the panel.
function M.close()
    if M.is_open() then
        state.handle.close()
    end
end

return M
