-- lvim-git.backend.sync: ABSOLUTE bidirectional git↔jj sync for a COLOCATED repo (`.jj` + `.git`
-- sharing one working copy). A colocated repo is not "pick a backend" — it is BOTH, and the user
-- fluidly mixes git and jj operations (in the plugin, in a terminal, in other tools). This module
-- keeps the two views coherent, never letting them drift silently:
--
--   * git → jj  (`jj git import`) — after a git-side change (a plugin `git` verb OR an EXTERNAL git
--     command) the jj view (the op log, the `@`/change graph, bookmarks) is made to reflect the new
--     git refs at once, instead of waiting for the next incidental jj call.
--   * jj → git  (`jj git export`) — after a jj-side change jj's colocated auto-export has usually
--     already written the refs into `.git`; a cheap `jj git export` VERIFIES it (a no-op when clean)
--     so plain git tooling and the git lens see it immediately.
--   * external  — `uv.fs_event` watchers on the `.git` ref DIRECTORIES + `.jj/repo/op_heads` coalesce
--     a burst into ONE debounced reconcile; a `FocusGained` re-check is the safety net for anything
--     the watcher missed while nvim was unfocused. Every reconcile refreshes the Repo model and fires
--     `User LvimGitRepoChanged` so every open panel re-renders from the SAME model.
--
-- LOOP AVOIDANCE (the make-or-break correctness concern) — NOT a timing kludge, a real
-- change-detection mechanism. Two facts measured from jj 0.37:
--   1. `jj git import` / `jj git export` are IDEMPOTENT — a no-op prints "Nothing changed" and moves
--      nothing, so a redundant reconcile cannot cascade.
--   2. `jj op log --ignore-working-copy` reads the current op id with NO side effect (it does not
--      snapshot or auto-import), and a git commit does NOT advance the jj op head until an import.
-- So each reconcile: (a) reads a GIT signature (HEAD + refs/heads·tags·remotes, EXCLUDING the jj-owned
-- `refs/jj/keep/*` bookkeeping that export writes) and a JJ signature (the op-head id); (b) imports /
-- exports only when a signature actually differs from the stored baseline; (c) RE-READS both
-- signatures at the very end and stores them as the new baseline — so the op the import just created
-- and the keep-refs the export just wrote are recorded as "ours". The watcher events those self-writes
-- fire then find signatures EQUAL to the baseline → no-op → the import↔export cannot oscillate. An
-- in-flight `syncing` flag coalesces events arriving mid-reconcile into a single follow-up pass.
--
-- Inert on a NON-colocated repo (a pure-git or a jj-only repo): no watchers, no autocmds, no jj calls
-- — `M.attach`/`M.reconcile`/`M.sync` all early-return, gated on `repo.colocated`.
--
---@module "lvim-git.backend.sync"

local uv = vim.uv or vim.loop
local api = vim.api
local config = require("lvim-git.config")
local state = require("lvim-git.state")
local backend = require("lvim-git.backend")

local M = {}

local GROUP = "LvimGitSync"

---@param msg string
---@param level? integer
local function notify(msg, level)
    vim.notify("lvim-git: " .. msg, level or vim.log.levels.INFO)
end

--- The git argv prefix (matches backend/git.lua): repo-agnostic globals for safe concurrent parsing.
---@param sub string[]
---@return string[]
local function git_argv(sub)
    local a = { config.git.cmd, "--no-optional-locks", "-c", "color.ui=false" }
    vim.list_extend(a, sub)
    return a
end

--- The jj argv prefix (matches backend/jj.lua): `--color=never` for safe parsing.
---@param sub string[]
---@return string[]
local function jj_argv(sub)
    local a = { config.jj.cmd, "--color=never" }
    vim.list_extend(a, sub)
    return a
end

-- ── the per-root sync record ────────────────────────────────────────────────

---@class LvimGitSyncRecord
---@field root      string
---@field colocated boolean
---@field enabled   boolean               colocated.sync ~= "manual" AND colocated.watch (for watchers)
---@field git_dir?  string                absolute GIT_DIR (colocated: <root>/.git)
---@field git_sig?  string                last-reconciled git ref signature (the baseline)
---@field op_sig?   string                last-reconciled jj op-head id (the baseline)
---@field syncing   boolean               a reconcile is in flight
---@field pending   boolean               a reconcile was requested mid-flight (coalesced)
---@field pending_force? boolean          the coalesced request wants a forced (full) reconcile
---@field cbs       fun(res: table?)[]    completion callbacks queued while syncing
---@field watchers  uv.uv_fs_event_t[]    the fs_event handles (torn down on detach)
---@field timer?    uv.uv_timer_t         the debounce timer for coalescing a watcher burst
---@field drift     boolean               a conflicted bookmark exists (both sides moved a ref)
---@field imported  boolean               the last reconcile imported git → jj
---@field exported  boolean               the last reconcile exported jj → git
---@field last_reason? string             what triggered the last reconcile

--- Ensure (and return) the sync record for a root, or nil when the root is not a COLOCATED repo.
--- The record is created lazily the first time a colocated root is touched.
---@param root string
---@return LvimGitSyncRecord?
local function ensure(root)
    if not root then
        return nil
    end
    local rec = state.sync[root]
    if rec then
        return rec
    end
    local repo = state.repos[root]
    if not repo or not repo.colocated then
        return nil
    end
    ---@type LvimGitSyncRecord
    rec = {
        root = root,
        colocated = true,
        enabled = config.colocated.sync ~= "manual",
        syncing = false,
        pending = false,
        cbs = {},
        watchers = {},
        drift = false,
        imported = false,
        exported = false,
    }
    state.sync[root] = rec
    return rec
end

-- ── signatures (the change-detection substrate) ─────────────────────────────

--- The GIT ref signature: `.git/HEAD` (branch identity / detached sha) + every branch/tag/remote ref
--- with its target — but NOT `refs/jj/keep/*` (jj's export bookkeeping), so a `jj git export` writing
--- keep-refs does not look like an external git change. Read async; `cb(sig)`.
---@param rec LvimGitSyncRecord
---@param cb fun(sig: string)
local function read_git_sig(rec, cb)
    -- HEAD is a tiny file; read it directly (captures a branch switch that leaves ref shas unchanged).
    local head = ""
    local fd = uv.fs_open((rec.git_dir or (rec.root .. "/.git")) .. "/HEAD", "r", 292)
    if fd then
        local stat = uv.fs_fstat(fd)
        if stat then
            head = uv.fs_read(fd, stat.size, 0) or ""
        end
        uv.fs_close(fd)
    end
    backend.output(
        rec.root,
        git_argv({ "for-each-ref", "--format=%(objectname) %(refname)", "refs/heads", "refs/tags", "refs/remotes" }),
        function(out)
            cb(vim.trim(head) .. "\30" .. (out or ""))
        end
    )
end

--- The JJ op-head id (the current operation) via `--ignore-working-copy` so the READ has NO side
--- effect (no snapshot, no auto-import). `cb(sig)`.
---@param rec LvimGitSyncRecord
---@param cb fun(sig: string)
local function read_op_sig(rec, cb)
    backend.output(
        rec.root,
        jj_argv({ "op", "log", "--ignore-working-copy", "-n", "1", "--no-graph", "-T", "id.short(32)" }),
        function(out)
            cb(vim.trim(out or ""))
        end
    )
end

--- Read BOTH signatures (git refs + jj op head) and join. `cb(git_sig, op_sig)`.
---@param rec LvimGitSyncRecord
---@param cb fun(git_sig: string, op_sig: string)
local function read_sigs(rec, cb)
    read_git_sig(rec, function(git_sig)
        read_op_sig(rec, function(op_sig)
            cb(git_sig, op_sig)
        end)
    end)
end

-- ── the reconcile ───────────────────────────────────────────────────────────

--- Run a jj sub-command for sync; `cb(text)` with combined stdout+stderr (jj prints its "Done
--- importing/exporting" / "Nothing changed" notices to stderr).
---@param rec LvimGitSyncRecord
---@param sub string[]
---@param cb fun(text: string)
local function run_jj(rec, sub, cb)
    backend.system(rec.root, jj_argv(sub), {}, function(res)
        cb((res.stdout or "") .. "\n" .. (res.stderr or ""))
    end)
end

--- Detect divergence: a bookmark jj marks CONFLICTED because both git and jj moved the same ref. Read
--- with `--ignore-working-copy` so the check itself creates NO op (no working-copy snapshot) — it must
--- not add its own op-log churn on top of the import's one op. Only run after an import (else the
--- previous value passes through). `cb(drift)`.
---@param rec LvimGitSyncRecord
---@param run boolean
---@param cb fun(drift: boolean)
local function detect_drift(rec, run, cb)
    if not run then
        cb(rec.drift)
        return
    end
    backend.output(
        rec.root,
        jj_argv({ "bookmark", "list", "--ignore-working-copy", "-a", "-T", 'if(conflict,"C","") ++ "\\n"' }),
        function(out)
            cb((out or ""):find("C", 1, true) ~= nil)
        end
    )
end

--- Flush queued callbacks, fire the refresh, clear the in-flight flag, and run a coalesced follow-up.
---@param rec LvimGitSyncRecord
---@param result table  { imported, exported, changed, force }
local function settle(rec, result)
    rec.imported = result.imported or false
    rec.exported = result.exported or false
    local cbs = rec.cbs
    rec.cbs = {}
    -- A real state move OR a forced/manual sync repaints every panel from the one refreshed model.
    if result.changed or result.force then
        backend.refresh(rec.root, function()
            api.nvim_exec_autocmds("User", {
                pattern = "LvimGitRepoChanged",
                data = { root = rec.root, vcs = "jj", colocated = true, reason = "sync" },
            })
        end)
    end
    rec.syncing = false
    for _, cb in ipairs(cbs) do
        cb(result)
    end
    if rec.pending then
        rec.pending = false
        local force = rec.pending_force
        rec.pending_force = false
        vim.schedule(function()
            M.reconcile(rec.root, { force = force, reason = "coalesced" })
        end)
    end
end

--- Reconcile a colocated repo: import git → jj and export jj → git as needed, then re-baseline the
--- signatures (so our own writes do not re-trigger). Idempotent, coalesced, change-detected. Inert on
--- a non-colocated / disabled root. `opts.force` reconciles even when signatures are unchanged (a
--- manual `:LvimGit sync`); `cb(result)` reports `{ imported, exported, changed, drift, colocated }`.
---@param root string
---@param opts? { force?: boolean, reason?: string }
---@param cb? fun(result: table?)
function M.reconcile(root, opts, cb)
    opts = opts or {}
    local rec = ensure(root)
    if not rec or not rec.colocated then
        if cb then
            cb({ colocated = false })
        end
        return
    end
    rec.last_reason = opts.reason
    if rec.syncing then
        rec.pending = true
        if opts.force then
            rec.pending_force = true
        end
        if cb then
            rec.cbs[#rec.cbs + 1] = cb
        end
        return
    end
    rec.syncing = true
    local force = opts.force == true
    if cb then
        rec.cbs[#rec.cbs + 1] = cb
    end

    local old_git, old_op = rec.git_sig, rec.op_sig
    read_sigs(rec, function(git_sig, op_sig)
        local need_import = force or git_sig ~= old_git
        local need_export = force or op_sig ~= old_op
        if not need_import and not need_export then
            rec.git_sig, rec.op_sig = git_sig, op_sig
            settle(rec, { imported = false, exported = false, changed = false, force = force })
            return
        end
        -- import (git → jj) first, then export (jj → git); both are idempotent no-ops when clean.
        local function after_export(exported)
            detect_drift(rec, need_import or force, function(drift)
                rec.drift = drift
                -- Re-baseline LAST, so the import's new op, the export's keep-refs, and the drift
                -- check's own jj call are all absorbed as "ours" — no self-triggered oscillation.
                read_sigs(rec, function(g2, o2)
                    rec.git_sig, rec.op_sig = g2, o2
                    local changed = g2 ~= old_git or o2 ~= old_op or drift
                    settle(rec, {
                        imported = rec.imported,
                        exported = exported,
                        changed = changed,
                        force = force,
                    })
                end)
            end)
        end
        local function do_export()
            if not (need_export or need_import or force) then
                after_export(false)
                return
            end
            run_jj(rec, { "git", "export" }, function(text)
                after_export(text:match("Done exporting") ~= nil)
            end)
        end
        if need_import or force then
            run_jj(rec, { "git", "import" }, function(text)
                rec.imported = text:match("Done importing") ~= nil or text:match("Reset the working copy") ~= nil
                do_export()
            end)
        else
            rec.imported = false
            do_export()
        end
    end)
end

-- ── watchers ────────────────────────────────────────────────────────────────

--- Schedule a debounced reconcile (coalesces a burst of fs_event notifications into ONE).
---@param rec LvimGitSyncRecord
---@param reason string
local function schedule_reconcile(rec, reason)
    if not rec.timer then
        rec.timer = uv.new_timer()
    end
    local delay = config.colocated.debounce or 200
    rec.timer:stop()
    rec.timer:start(delay, 0, function()
        vim.schedule(function()
            M.reconcile(rec.root, { reason = reason })
        end)
    end)
end

--- The directories to watch for a colocated repo. Watching DIRECTORIES (not the ref files) survives
--- git's atomic write-and-rename of a ref (which would orphan an fs_event bound to the file inode),
--- and covers the common flat branch/tag/bookmark layout. `.jj/repo/op_heads/heads` holds one file
--- named by the current op id — any jj operation rewrites it.
---@param rec LvimGitSyncRecord
---@return string[]
local function watch_dirs(rec)
    local gd = rec.git_dir or (rec.root .. "/.git")
    return {
        gd, -- HEAD, packed-refs, ORIG_HEAD, MERGE_HEAD (immediate children)
        gd .. "/refs/heads",
        gd .. "/refs/tags",
        gd .. "/refs/remotes",
        rec.root .. "/.jj/repo/op_heads/heads",
    }
end

--- Attach fs_event watchers + seed the baseline signatures for a colocated root. Idempotent (a second
--- call is a no-op while watchers are live). Inert on a non-colocated root or when `colocated.watch`
--- is off. `M.reconcile` still works without watchers (manual `:LvimGit sync`, plugin-op hook, focus).
---@param root_or_buf? string|integer
function M.attach(root_or_buf)
    local root, _, colocated = backend.detect(root_or_buf)
    if not root or not colocated then
        return
    end
    local rec = ensure(root)
    if not rec then
        return
    end
    if #rec.watchers > 0 then
        return -- already watching
    end
    rec.git_dir = rec.root .. "/.git"
    -- Seed the baseline signatures so the FIRST real change is detected (not treated as new state).
    read_sigs(rec, function(git_sig, op_sig)
        rec.git_sig, rec.op_sig = git_sig, op_sig
    end)
    if not (config.colocated.watch and rec.enabled) then
        return -- reconcile-on-demand only (no fs_event watchers)
    end
    for _, dir in ipairs(watch_dirs(rec)) do
        if uv.fs_stat(dir) then
            local handle = uv.new_fs_event()
            if handle then
                local ok = pcall(function()
                    handle:start(dir, {}, function(err)
                        if not err then
                            schedule_reconcile(rec, "watch")
                        end
                    end)
                end)
                if ok then
                    rec.watchers[#rec.watchers + 1] = handle
                else
                    pcall(function()
                        handle:close()
                    end)
                end
            end
        end
    end
end

--- Stop and release a root's watchers + debounce timer (repo close / plugin teardown). The record is
--- kept (its signatures stay a valid baseline for a later re-attach); only the OS handles are freed.
---@param root string
function M.detach(root)
    local rec = state.sync[root]
    if not rec then
        return
    end
    for _, h in ipairs(rec.watchers) do
        pcall(function()
            h:stop()
        end)
        pcall(function()
            h:close()
        end)
    end
    rec.watchers = {}
    if rec.timer then
        pcall(function()
            rec.timer:stop()
        end)
        pcall(function()
            rec.timer:close()
        end)
        rec.timer = nil
    end
end

--- Tear down every watcher (VimLeavePre / a hard reset).
function M.detach_all()
    for root in pairs(state.sync) do
        M.detach(root)
    end
end

-- ── public reads ────────────────────────────────────────────────────────────

--- True when the path/buffer is inside a COLOCATED repo (a `.jj` + `.git` sharing one working copy).
---@param root_or_buf? string|integer
---@return boolean
function M.is_colocated(root_or_buf)
    local _, _, colocated = backend.detect(root_or_buf)
    return colocated == true
end

--- The render-safe sync state for a repo (nil when not colocated). Feeds `health.lua`, the status
--- header " git+jj" / drift indicator, and any consumer.
---@param root_or_buf? string|integer
---@return { colocated: boolean, mode: string, watching: boolean, syncing: boolean, drift: boolean, imported: boolean, exported: boolean }?
function M.sync_state(root_or_buf)
    local root, _, colocated = backend.detect(root_or_buf)
    if not root or not colocated then
        return nil
    end
    local rec = state.sync[root]
    return {
        colocated = true,
        mode = config.colocated.sync,
        watching = rec ~= nil and #rec.watchers > 0,
        syncing = rec ~= nil and rec.syncing or false,
        drift = rec ~= nil and rec.drift or false,
        imported = rec ~= nil and rec.imported or false,
        exported = rec ~= nil and rec.exported or false,
    }
end

--- Force a reconcile of the repo containing `root_or_buf` (the `:LvimGit sync` command). Reports what
--- was imported/exported. `manual` (the command) always notifies; a non-colocated repo is a clean
--- "nothing to sync". `direction` optionally restricts to "import" or "export" (else both).
---@param root_or_buf? string|integer
---@param manual? boolean
---@param direction? "import"|"export"
function M.sync(root_or_buf, manual, direction)
    local root, _, colocated = backend.detect(root_or_buf)
    if not root then
        if manual then
            notify("not inside a repo", vim.log.levels.WARN)
        end
        return
    end
    if not colocated then
        if manual then
            notify("not a colocated git+jj repo — nothing to sync", vim.log.levels.INFO)
        end
        return
    end
    -- A directed sync is a single explicit import/export (still baseline-safe: reconcile re-reads sigs
    -- after any jj write). We route it through reconcile(force) so the change-detection + refresh are
    -- shared; `direction` only tweaks the notice wording (import and export are each idempotent).
    M.reconcile(root, { force = true, reason = manual and "manual" or "sync" }, function(result)
        if not manual then
            return
        end
        result = result or {}
        if result.imported and result.exported then
            notify("synced: imported git → jj and exported jj → git")
        elseif result.imported then
            notify("synced: imported git → jj")
        elseif result.exported then
            notify("synced: exported jj → git")
        elseif result.drift then
            notify(
                "sync: a bookmark is conflicted (git and jj both moved it) — resolve in the refs panel",
                vim.log.levels.WARN
            )
        else
            notify("already in sync (git and jj agree)")
        end
    end)
    -- `direction` is accepted for the `:LvimGit sync import|export` grammar; both halves run either way
    -- (they are idempotent no-ops when the other side is already consistent), so it never desyncs.
    local _ = direction
end

-- ── setup / wiring ──────────────────────────────────────────────────────────

--- Wire the colocated sync: attach watchers when a colocated repo's buffer is entered, reconcile after
--- every plugin mutation (the `User LvimGitRepoChanged` hook, guarded against its OWN "sync" event so
--- it can never recurse), reconcile every watched root on `FocusGained` (the external-change safety
--- net), and tear the watchers down on exit. All gated on `colocated.sync ~= "manual"` for the
--- automatic paths; the `:LvimGit sync` command works regardless of mode.
function M.setup()
    local group = api.nvim_create_augroup(GROUP, { clear = true })
    local auto = config.colocated.sync ~= "manual"

    -- Ensure the current buffer's colocated repo is watched (idempotent). Cheap: detection is cached.
    if auto then
        api.nvim_create_autocmd({ "BufReadPost", "BufEnter", "DirChanged" }, {
            group = group,
            callback = function(ev)
                if M.is_colocated(ev.buf) then
                    M.attach(ev.buf)
                end
            end,
        })
        -- Attach for the cwd at startup (a repo opened directly, no file buffer yet).
        vim.schedule(function()
            if M.is_colocated(nil) then
                M.attach(nil)
            end
        end)

        -- After ANY plugin mutation fires LvimGitRepoChanged, reconcile immediately (promptness beyond
        -- the debounced watcher). Guarded: the reconcile's OWN event carries reason == "sync", so this
        -- hook skips it — no recursion. A staging op (index-only, no ref move) reconciles to a no-op.
        api.nvim_create_autocmd("User", {
            group = group,
            pattern = "LvimGitRepoChanged",
            callback = function(ev)
                local data = ev.data or {}
                if data.reason == "sync" then
                    return
                end
                local root = data.root
                if not root then
                    root = backend.detect(api.nvim_get_current_buf())
                end
                if root and M.is_colocated(root) then
                    M.reconcile(root, { reason = "op:" .. tostring(data.reason or "?") })
                end
            end,
        })

        -- The external-change safety net: re-check every watched root when nvim regains focus (an
        -- fs_event can be missed while unfocused / for a change under a dir we do not watch).
        api.nvim_create_autocmd("FocusGained", {
            group = group,
            callback = function()
                for root in pairs(state.sync) do
                    M.reconcile(root, { reason = "focus" })
                end
            end,
        })
    end

    api.nvim_create_autocmd("VimLeavePre", {
        group = group,
        callback = function()
            M.detach_all()
        end,
    })
end

return M
