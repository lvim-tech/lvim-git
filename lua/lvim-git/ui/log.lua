-- lvim-git.ui.log: the LOG / GRAPH panel (neogit/vgit/diffview log role) — a decoupled COMPONENT over
-- the shared core (backend / model.graph / config), standalone (`:LvimGit log [revset]`). It composes
-- the shared `ui/logpanel` chassis (the coloured graph column + subject + ref badges + commit-detail
-- preview) and adds the LOG-specific behaviour: a preset filter band (current / all / branches), a
-- log-FILTER transient (max-count / author / grep / since / until / path / --first-parent) whose apply
-- re-renders live, a lazy-extend "load more", and the per-commit ACTION popup (checkout / branch-here /
-- tag-here / cherry-pick / revert / reset-here / rebase-onto / copy-hash / view-diff) via `actions.lua`.
--
-- PUBLIC: open / is_open / close / toggle + commits (async read for custom renderers).
--
---@module "lvim-git.ui.log"

local config = require("lvim-git.config")
local backend = require("lvim-git.backend")
local transient = require("lvim-git.transient")
local logpanel = require("lvim-git.ui.logpanel")

local M = {}

-- ── glyphs ──────────────────────────────────────────────────────────────────
local GLYPH = { log = "\u{f1da}" } --  nf-fa-history

---@class LvimGitLogState
---@field handle table?      the logpanel handle
---@field root string?       the repo root
---@field vcs string?        the repo lens
---@field revset string?     an explicit revset from the command line
---@field preset string      the active preset filter id (current/all/branches)
---@field preset_args string[]  the preset's raw log args (--all / --branches)
---@field filter_args string[]  the log-filter transient's assembled args (author/grep/max-count/…)
---@field paths string[]?    the transient's path filter
---@field limit integer      the current fetch limit (bumped by load-more)
local state = { preset = "current", preset_args = {}, filter_args = {}, limit = 0 }

---@param msg string
---@param level? integer
local function notify(msg, level)
    vim.notify("lvim-git: " .. msg, level or vim.log.levels.INFO)
end

--- Whether the log panel is open.
---@return boolean
function M.is_open()
    return state.handle ~= nil and state.handle.is_open and state.handle.is_open()
end

-- ── the commit loader ────────────────────────────────────────────────────────

--- Assemble the effective raw log args (preset + filter transient) and fetch the commit list.
---@param cb fun(commits: Commit[])
local function load_commits(cb)
    local extra = {}
    vim.list_extend(extra, state.preset_args or {})
    vim.list_extend(extra, state.filter_args or {})
    backend.log({
        root_or_buf = state.root,
        revset = state.revset,
        extra = extra,
        paths = state.paths,
        limit = state.limit,
    }, function(commits)
        cb(commits or {})
    end)
end

-- ── the log-filter transient ──────────────────────────────────────────────────

--- Register the `log-args` transient once (the log-filter popup): switches (--all/--branches/
--- --first-parent) + options (max-count/author/grep/since/until/path). The path option carries no
--- argv `arg`, so it never assembles into the raw args — its value is read from the live ui-row and
--- applied as a `paths` filter. Apply re-renders the log live.
local function ensure_filter_transient()
    if transient.has("log-args") then
        return
    end
    transient.define({
        id = "log-args",
        title = "Log options",
        groups = {
            {
                title = "Refs",
                infix = {
                    { kind = "switch", key = "-a", label = "All refs", flag = "--all", level = 1 },
                    { kind = "switch", key = "-b", label = "All branches", flag = "--branches", level = 2 },
                    { kind = "switch", key = "-m", label = "First parent only", flag = "--first-parent", level = 2 },
                },
            },
            {
                title = "Filter",
                infix = {
                    { kind = "option", key = "=n", label = "Max count", arg = "--max-count", level = 1 },
                    { kind = "option", key = "=A", label = "Author", arg = "--author", level = 1 },
                    { kind = "option", key = "=g", label = "Grep message", arg = "--grep", level = 1 },
                    { kind = "option", key = "=s", label = "Since (date)", arg = "--since", level = 3 },
                    { kind = "option", key = "=u", label = "Until (date)", arg = "--until", level = 3 },
                    { kind = "option", key = "=p", label = "Path filter", level = 2 },
                },
                actions = {
                    {
                        key = "g",
                        label = "Apply / refresh",
                        run = function(args, ctx)
                            state.filter_args = args
                            local prow = ctx.rows and ctx.rows["=p"]
                            local pval = prow and prow.value
                            state.paths = (pval and vim.trim(tostring(pval)) ~= "") and { vim.trim(tostring(pval)) }
                                or nil
                            M.reload()
                        end,
                    },
                },
            },
        },
    })
end

--- Open the log-filter transient (its apply action re-renders the log).
local function open_filter_transient()
    ensure_filter_transient()
    transient.open("log-args", { root = state.root, lens = state.vcs })
end

-- ── reload / presets ──────────────────────────────────────────────────────────

--- Reload the panel from the current query.
function M.reload()
    if M.is_open() then
        state.handle.reload()
    end
end

--- The preset-filter buttons (a header bar sector): current HEAD / all refs / all branches.
---@type table[]
local PRESETS = {
    { id = "current", label = "Current" },
    { id = "all", label = "All" },
    { id = "branches", label = "Branches" },
}

--- Apply a preset filter (sets the raw preset args and reloads).
---@param id string
local function apply_preset(id)
    state.preset = id
    state.preset_args = (id == "all" and { "--all" }) or (id == "branches" and { "--branches" }) or {}
    M.reload()
end

-- ── public read ──────────────────────────────────────────────────────────────

--- Fetch the commit list for a query (async) — the documented read for custom renderers.
---@param opts { root_or_buf?: string|integer, revset?: string, range?: string, paths?: string[], limit?: integer, extra?: string[] }
---@param cb fun(commits: Commit[]?)
function M.commits(opts, cb)
    backend.log(opts, cb)
end

-- ── open / close ───────────────────────────────────────────────────────────────

--- Open the log panel. `opts = { revset?, args?, layout?, lens? }`.
---@param opts? table
function M.open(opts)
    opts = opts or {}
    if not config.log.enabled then
        notify("the log component is disabled (log.enabled = false)", vim.log.levels.WARN)
        return
    end
    local root, vcs = backend.detect(vim.api.nvim_get_current_buf())
    if not root then
        notify("not inside a git repository", vim.log.levels.WARN)
        return
    end
    if M.is_open() then
        state.handle.close()
    end
    require("lvim-git.actions").register()
    ensure_filter_transient()
    state.root = root
    state.vcs = opts.lens or vcs
    state.revset = opts.revset or (opts.args and opts.args[1]) or nil
    state.preset = "current"
    state.preset_args = {}
    state.filter_args = {}
    state.paths = nil
    state.limit = config.log.limit or 256
    local layout = logpanel.layout_for("log", opts.layout)

    state.handle = logpanel.open({
        view = "log",
        root = root,
        vcs = state.vcs,
        title = { icon = GLYPH.log, text = "Git Log" },
        subtitle = logpanel.repo_band(root, state.revset),
        layout = layout,
        graph = config.log.graph ~= false,
        filters = {
            active = state.preset,
            buttons = PRESETS,
            on_select = apply_preset,
        },
        load = load_commits,
        on_action = function(commit)
            require("lvim-git.actions").commit_actions(commit, root, state.vcs)
        end,
        on_view_diff = function(commit)
            require("lvim-git.actions").view_commit_diff(commit)
        end,
        on_options = open_filter_transient,
        on_more = function()
            state.limit = state.limit + (config.log.limit or 256)
            M.reload()
            notify("loading up to " .. state.limit .. " commits")
        end,
    })
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
