-- lvim-git.wip: Magit's WORK-IN-PROGRESS refs mode — a standalone, opt-in COMPONENT (`config.wip.enabled`
-- defaults false, like Magit). It snapshots the working tree into a `refs/wip/wtree/<ref>` ref WITHOUT
-- touching the worktree or index, using git's OWN non-destructive seam (`git stash create` builds a
-- stash-format commit capturing worktree + index; `git update-ref` records it under the wip ref) — no
-- re-apply, no worktree mutation. Three ops, a tiny transient:
--   * save    — snapshot the current state to `refs/wip/wtree/<branch>` (nothing lost, worktree intact),
--   * log     — browse the wip ref's snapshots in the log panel,
--   * restore — bring a wip snapshot back into the working tree (`git stash apply <wip-ref>`, guarded).
--
-- git-only (`caps.wip`); the jj lens omits it (jj's op log already gives working-copy history). The
-- interactive auto-save-on-every-command Magit does is a follow-up; v1 is explicit save/log/restore.
--
-- PUBLIC: open / save / restore.
--
---@module "lvim-git.wip"

local backend = require("lvim-git.backend")
local actions = require("lvim-git.actions")
local transient = require("lvim-git.transient")

local M = {}

---@param msg string
---@param level? integer
local function notify(msg, level)
    vim.notify("lvim-git: " .. msg, level or vim.log.levels.INFO)
end

--- The git argv prefix (matching the backend): repo-agnostic globals for safe parsing.
---@param sub string[]
---@return string[]
local function git_argv(sub)
    local config = require("lvim-git.config")
    local a = { config.git.cmd, "--no-optional-locks", "-c", "color.ui=false" }
    vim.list_extend(a, sub)
    return a
end

--- The wip ref for the current branch (or a `detached` bucket): `refs/wip/wtree/<name>`.
---@param root string
---@return string
local function wip_ref(root)
    local repo = backend.repo(root)
    local name = (repo and repo.branch) or "detached"
    return "refs/wip/wtree/" .. name
end

-- ── ops ───────────────────────────────────────────────────────────────────────

--- Snapshot the working tree + index into the branch's wip ref, non-destructively. Public.
---@param root string
---@param vcs string?
function M.save(root, vcs)
    backend.output(root, git_argv({ "stash", "create", "wip" }), function(out)
        local sha = out and vim.trim(out) or ""
        if sha == "" then
            notify("nothing to save (working tree clean)")
            return
        end
        local ref = wip_ref(root)
        actions.execute(root, { "update-ref", "-m", "lvim-git wip", ref, sha }, {
            op = "wip",
            vcs = vcs,
            quiet = true,
        }, function(ok)
            if ok then
                notify("wip saved to " .. ref .. " (" .. sha:sub(1, 8) .. ")")
            end
        end)
    end)
end

--- Restore the branch's wip snapshot into the working tree (`git stash apply <wip-ref>`, guarded — it
--- overlays the recorded state onto the current worktree). Public.
---@param root string
---@param vcs string?
function M.restore(root, vcs)
    local config = require("lvim-git.config")
    local ref = wip_ref(root)
    backend.output(root, git_argv({ "rev-parse", "--verify", "--quiet", ref }), function(out)
        if not out or vim.trim(out) == "" then
            notify("no wip snapshot for this branch (" .. ref .. ")", vim.log.levels.WARN)
            return
        end
        local function run()
            actions.execute(root, { "stash", "apply", ref }, { op = "wip", vcs = vcs })
        end
        if config.confirm_destructive then
            require("lvim-ui").confirm({
                prompt = "Restore wip snapshot onto the working tree?",
                callback = function(yes)
                    if yes then
                        run()
                    end
                end,
            })
        else
            run()
        end
    end)
end

--- Browse the branch's wip snapshots in the log panel (the wip ref's ancestry). Public via `open`.
---@param root string
local function log(root)
    local ok = pcall(function()
        require("lvim-git").log({ revset = wip_ref(root) })
    end)
    if not ok then
        notify("the log component is not available", vim.log.levels.WARN)
    end
end

-- ── transient ──────────────────────────────────────────────────────────────────

---@type boolean
local registered = false

--- Register the wip transient def (once).
local function register()
    if registered then
        return
    end
    registered = true
    transient.define({
        id = "wip",
        title = "Work-in-progress",
        groups = {
            {
                title = "Actions",
                actions = {
                    {
                        key = "s",
                        label = "Save (snapshot worktree)",
                        run = function(_, ctx)
                            local root = ctx.root or backend.detect(vim.api.nvim_get_current_buf())
                            if root then
                                M.save(root, ctx.lens)
                            end
                        end,
                    },
                    {
                        key = "l",
                        label = "Log (browse snapshots)",
                        run = function(_, ctx)
                            local root = ctx.root or backend.detect(vim.api.nvim_get_current_buf())
                            if root then
                                log(root)
                            end
                        end,
                    },
                    {
                        key = "r",
                        label = "Restore (apply snapshot)",
                        run = function(_, ctx)
                            local root = ctx.root or backend.detect(vim.api.nvim_get_current_buf())
                            if root then
                                M.restore(root, ctx.lens)
                            end
                        end,
                    },
                },
            },
        },
    })
end

--- Open the wip transient. Opt-in (`config.wip.enabled`); git-only (`caps.wip`). `opts = { layout?, lens? }`.
---@param opts? table
function M.open(opts) ---@diagnostic disable-line: unused-local
    local config = require("lvim-git.config")
    if not config.wip.enabled then
        notify("wip mode is disabled (wip.enabled = false)", vim.log.levels.WARN)
        return
    end
    local root, vcs = backend.detect(vim.api.nvim_get_current_buf())
    if not root then
        notify("not inside a git repository", vim.log.levels.WARN)
        return
    end
    local repo = backend.repo(root)
    if repo and repo.caps and not repo.caps.wip then
        notify("this repo's backend has no wip mode", vim.log.levels.WARN)
        return
    end
    register()
    transient.open("wip", { root = root, lens = (opts and opts.lens) or vcs })
end

return M
