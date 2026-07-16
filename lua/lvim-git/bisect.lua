-- lvim-git.bisect: the git BISECT role — a standalone COMPONENT over the shared core, git-only
-- (`caps.bisect`; jj has no bisect, so the jj lens omits it). It has TWO faces that share ONE backend
-- read (`backend.bisect_state`, itself driven by git's own `rev-list --bisect-vars` — never a scrape of
-- human output):
--   * the bisect TRANSIENT (`:LvimGit bisect`) — start (good..bad) / mark good / bad / skip / run a test
--     command / reset — whose actions live in `actions.lua` (the verb layer, so the panel and the status
--     section share one implementation), and
--   * the render-safe STATE read (`state(root)`) the status surface uses to draw its "Bisecting: N
--     revisions left, testing <sha>" section with good/bad/skip/reset controls.
--
-- `open` registers the verb defs + opens the transient; `load` refreshes the cached state (the status
-- surface calls it in its parallel data load); `state` is the O(1) render-safe read. No panel window of
-- its own — the transient is the modal surface (`layouts.bisect = "float"`), the status section is where
-- the ongoing session shows.
--
-- PUBLIC: open / load / state.
--
---@module "lvim-git.bisect"

local backend = require("lvim-git.backend")

local M = {}

---@class LvimGitBisectState
---@field active    boolean
---@field term_bad?  string
---@field term_good? string
---@field bad?      string       the bad ref (refs/bisect/<term_bad>)
---@field goods?    string[]     the good refs
---@field testing?  string       short sha of the commit currently checked out for testing
---@field remaining? integer     revisions still to test (git's `bisect_nr`)
---@field steps?    integer      estimated remaining steps (git's `bisect_steps`)

---@param msg string
---@param level? integer
local function notify(msg, level)
    vim.notify("lvim-git: " .. msg, level or vim.log.levels.INFO)
end

-- ── state ─────────────────────────────────────────────────────────────────────

--- Refresh the cached bisect state for `root` (via the backend read), then `cb(state)`. The status
--- surface calls this in its parallel data load; the cache backs `M.state`.
---@param root string
---@param cb? fun(state: LvimGitBisectState)
function M.load(root, cb)
    backend.bisect_state(root, function(st)
        local s = st or { active = false }
        require("lvim-git.state").bisect[root] = s
        if cb then
            cb(s)
        end
    end)
end

--- The cached bisect state for `root` (render-safe, O(1)). `{ active = false }` when idle / not loaded.
--- Public: a statusline / custom renderer surfaces the session without shelling.
---@param root? string
---@return LvimGitBisectState
function M.state(root)
    if not root then
        return { active = false }
    end
    return require("lvim-git.state").bisect[root] or { active = false }
end

-- ── open ──────────────────────────────────────────────────────────────────────

--- Open the bisect transient. git-only (`caps.bisect`); a jj repo reports the gap. `opts = { layout? }`.
---@param opts? table
function M.open(opts) ---@diagnostic disable-line: unused-local
    local config = require("lvim-git.config")
    if not config.bisect.enabled then
        notify("the bisect component is disabled (bisect.enabled = false)", vim.log.levels.WARN)
        return
    end
    local root, vcs = backend.detect(vim.api.nvim_get_current_buf())
    if not root then
        notify("not inside a git repository", vim.log.levels.WARN)
        return
    end
    local repo = backend.repo(root)
    if repo and repo.caps and not repo.caps.bisect then
        notify("this repo's backend has no bisect", vim.log.levels.WARN)
        return
    end
    require("lvim-git.actions").register()
    -- Prime the state so the transient's title reflects an in-progress session on next status refresh.
    M.load(root)
    require("lvim-git.transient").open("bisect", { root = root, lens = vcs })
end

return M
