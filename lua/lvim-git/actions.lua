-- lvim-git.actions: the VERB LAYER — every core Magit transient DEFINITION (commit / push / pull /
-- fetch / branch / remote / merge / reset / tag / revert / cherry-pick / rebase / stash) plus the ONE seam the
-- verbs run through. A verb is DATA (switches + options + actions) registered with the transient engine
-- via `transient.define`; its actions ASSEMBLE the real git argv (the engine hands each action the
-- assembled infix args) and run it through `M.execute`, which streams progress for long ops, fires the
-- reactive `User LvimGit*` events on success (so the status surface + signs + any consumer refresh), and
-- surfaces failures. Editor-spawning invocations (annotated tag, `--edit` revert/cherry-pick, instant
-- squash) route through `backend/editor.lua` — git's own `GIT_EDITOR` seam — never a PTY.
--
-- `M.execute` is the caps-aware seam: it runs `config.git.cmd` today; the Phase-13 jj lens swaps the
-- argv/impl behind the same call, so the verb defs never string-check `vcs`. Pickers (`pick_ref` /
-- `pick_commit` / `pick_remote`) and the name input go through the canonical lvim-ui `select`/`input`
-- — the "operate on the thing you choose" half of Magit's `ctx` model, for verbs invoked without a
-- selection under the cursor.
--
---@module "lvim-git.actions"

local api = vim.api
local config = require("lvim-git.config")
local backend = require("lvim-git.backend")
local transient = require("lvim-git.transient")
local ui = require("lvim-ui")

local M = {}

---@param msg string
---@param level? integer
local function notify(msg, level)
    vim.notify("lvim-git: " .. msg, level or vim.log.levels.INFO)
end

--- The git argv prefix (matching backend/git.lua): repo-agnostic globals for safe, concurrent parsing.
---@param sub string[]
---@return string[]
local function git_argv(sub)
    local a = { config.git.cmd, "--no-optional-locks", "-c", "color.ui=false" }
    vim.list_extend(a, sub)
    return a
end

--- The jj argv prefix (matching backend/jj.lua): `--color=never` for safe parsing. jj snapshots the
--- working copy before every command, so no lock flag is needed.
---@param sub string[]
---@return string[]
local function jj_argv(sub)
    local a = { config.jj.cmd, "--color=never" }
    vim.list_extend(a, sub)
    return a
end

-- ── the execution seam ─────────────────────────────────────────────────────────

--- Fire a `User` event (main loop) with a data payload — the reactive surface every panel binds to.
---@param pattern string
---@param data table
local function fire(pattern, data)
    api.nvim_exec_autocmds("User", { pattern = pattern, data = data })
end

--- A streaming stderr/stdout reader for a long op: split incremental chunks on CR/LF and emit each
--- complete segment as a `User LvimGitProgress` event (the documented progress surface). Runs in the
--- libuv callback, so it does pure string work and schedules the event emit onto the main loop.
---@param root string
---@param op string
---@return fun(err: string?, chunk: string?)
local function progress_reader(root, op)
    local partial = ""
    return function(_, chunk)
        if not chunk then
            return
        end
        partial = partial .. chunk
        while true do
            local nl = partial:find("[\r\n]")
            if not nl then
                break
            end
            local line = vim.trim(partial:sub(1, nl - 1))
            partial = partial:sub(nl + 1)
            if line ~= "" then
                vim.schedule(function()
                    fire("LvimGitProgress", { root = root, op = op, line = line })
                end)
            end
        end
    end
end

--- Run a git verb under `root`. `subargv` is the git subcommand + args (WITHOUT the executable/global
--- prefix). On success fires `LvimGitRepoChanged` (+ `LvimGitHeadChanged` when `head_changed`); on
--- failure notifies the stderr. Long ops (`progress`) stream stderr into `LvimGitProgress`. Editor-
--- spawning ops (`editor`) run through the with-editor bridge. `cb(ok, res)` fires on completion.
---@param root string
---@param subargv string[]
---@param opts? { op?: string, vcs?: string, progress?: boolean, head_changed?: boolean, stdin?: string, env?: table<string,string>, editor?: boolean, quiet?: boolean }
---@param cb? fun(ok: boolean, res: vim.SystemCompleted)
function M.execute(root, subargv, opts, cb)
    opts = opts or {}
    local op = opts.op or subargv[1] or "git"
    -- The caps-aware seam: a jj-lens verb assembles jj subcommands and runs through the SAME handler
    -- (events, progress, editor bridge) — the verb defs never string-check `vcs`, they pass `opts.vcs`.
    local argv = opts.vcs == "jj" and jj_argv(subargv) or git_argv(subargv)

    ---@param res vim.SystemCompleted
    local function handle(res)
        if res.code ~= 0 then
            local msg = vim.trim((res.stderr ~= nil and res.stderr ~= "") and res.stderr or (res.stdout or ""))
            notify(op .. " failed: " .. (msg ~= "" and msg or ("exit " .. tostring(res.code))), vim.log.levels.ERROR)
            if cb then
                cb(false, res)
            end
            return
        end
        vim.cmd("checktime") -- a worktree-editing verb (checkout/reset/merge) → reload open buffers
        fire("LvimGitRepoChanged", { root = root, vcs = opts.vcs, reason = op })
        if opts.head_changed then
            fire("LvimGitHeadChanged", { root = root })
        end
        if not opts.quiet then
            local tail = vim.trim(res.stderr or "")
            notify(op .. (tail ~= "" and (": " .. tail:gsub("%s+", " ")) or " done"))
        end
        if cb then
            cb(true, res)
        end
    end

    if opts.editor then
        require("lvim-git.backend.editor").run(root, argv, { stdin = opts.stdin, extra_env = opts.env }, handle)
        return
    end
    local sysopts = { stdin = opts.stdin, env = opts.env }
    if opts.progress then
        sysopts.stderr = progress_reader(root, op)
        notify(op .. "…")
    end
    backend.system(root, argv, sysopts, handle)
end

-- ── selection helpers (the ctx "thing you choose") ─────────────────────────────

--- Resolve the repo root/vcs for a verb ctx (falls back to the current buffer's repo).
---@param ctx? LvimGitTransientCtx
---@return string? root, string? vcs
local function resolve(ctx)
    if ctx and ctx.root then
        return ctx.root, ctx.lens
    end
    local root, vcs = backend.detect(api.nvim_get_current_buf())
    return root, (ctx and ctx.lens) or vcs
end

--- Pick a ref from the repo (filtered by `kinds`) through the canonical lvim-ui select. `cb(name, ref)`.
---@param root string
---@param kinds? string[]  restrict to these Ref.kind values (nil = all)
---@param prompt string
---@param cb fun(name: string, ref: Ref)
local function pick_ref(root, kinds, prompt, cb)
    backend.refs(root, function(refs)
        local items = {}
        for _, r in ipairs(refs or {}) do
            if not kinds or vim.tbl_contains(kinds, r.kind) then
                items[#items + 1] = { label = r.name, _ref = r }
            end
        end
        if #items == 0 then
            notify("no matching refs", vim.log.levels.WARN)
            return
        end
        ui.select({
            title = prompt,
            items = items,
            callback = function(ok, idx)
                if ok and items[idx] then
                    cb(items[idx]._ref.name, items[idx]._ref)
                end
            end,
        })
    end)
end

--- Pick a commit from recent history. `cb(id, abbrev)`.
---@param root string
---@param prompt string
---@param cb fun(id: string, abbrev: string)
local function pick_commit(root, prompt, cb)
    backend.log({ root_or_buf = root, limit = 100 }, function(commits)
        local items = {}
        for _, c in ipairs(commits or {}) do
            items[#items + 1] = { label = c.abbrev .. "  " .. (c.subject or ""), _id = c.id, _ab = c.abbrev }
        end
        if #items == 0 then
            notify("no commits", vim.log.levels.WARN)
            return
        end
        ui.select({
            title = prompt,
            items = items,
            callback = function(ok, idx)
                if ok and items[idx] then
                    cb(items[idx]._id, items[idx]._ab)
                end
            end,
        })
    end)
end

--- Pick a remote (auto-selects when there is exactly one). `cb(name)`.
---@param root string
---@param prompt string
---@param cb fun(name: string)
local function pick_remote(root, prompt, cb)
    backend.output(root, git_argv({ "remote" }), function(out)
        local items = {}
        for line in ((out or "") .. "\n"):gmatch("(.-)\n") do
            if line ~= "" then
                items[#items + 1] = { label = line }
            end
        end
        if #items == 0 then
            notify("no remotes configured", vim.log.levels.WARN)
            return
        end
        if #items == 1 then
            cb(items[1].label)
            return
        end
        ui.select({
            title = prompt,
            items = items,
            callback = function(ok, idx)
                if ok and items[idx] then
                    cb(items[idx].label)
                end
            end,
        })
    end)
end

--- Free-text input through the canonical lvim-ui input; fires `cb(value)` only on a non-empty confirm.
---@param prompt string
---@param default? string
---@param cb fun(value: string)
local function input(prompt, default, cb)
    ui.input({
        title = prompt,
        default = default,
        callback = function(ok, val)
            if ok and val and vim.trim(val) ~= "" then
                cb(vim.trim(val))
            end
        end,
    })
end

--- Confirm a destructive op when `confirm_destructive`, else run straight away.
---@param prompt string
---@param run fun()
local function guard(prompt, run)
    if config.confirm_destructive then
        ui.confirm({
            prompt = prompt,
            callback = function(yes)
                if yes then
                    run()
                end
            end,
        })
    else
        run()
    end
end

--- The current branch name (for set-upstream / rename defaults).
---@param root string
---@return string?
local function current_branch(root)
    local repo = backend.repo(root)
    return repo and repo.branch or nil
end

-- ── commit ─────────────────────────────────────────────────────────────────────

--- Open the commit message panel for a normal / amend / reword commit.
---@param root string
---@param vcs string?
---@param args string[]        the assembled infix argv
---@param mode "commit"|"amend"|"reword"
local function commit_panel(root, vcs, args, mode)
    require("lvim-git.ui.commit").open({ root = root, vcs = vcs, args = args, mode = mode })
end

--- Create a fixup / squash marker commit against `target`; when `instant`, immediately autosquash it via
--- a non-interactive rebase (git's own `--autosquash`, the sequence editor accepted unchanged). A squash
--- needs the combined message edited, so the instant-squash rebase routes GIT_EDITOR through the bridge.
---@param root string
---@param vcs string?
---@param target string       the commit the fixup/squash targets
---@param kind "fixup"|"squash"
---@param instant boolean
local function fixup_squash(root, vcs, target, kind, instant)
    M.execute(
        root,
        { "commit", "--" .. kind .. "=" .. target },
        { op = "commit", vcs = vcs, quiet = true },
        function(ok)
            if not ok then
                return
            end
            if not instant then
                notify(kind .. "! commit created")
                return
            end
            guard(("Autosquash %s! onto %s?"):format(kind, target:sub(1, 8)), function()
                M.execute(root, { "rebase", "-i", "--autosquash", "--autostash", target .. "^" }, {
                    op = "rebase",
                    vcs = vcs,
                    head_changed = true,
                    editor = kind == "squash", -- squash needs the combined message edited via the bridge
                    env = { GIT_SEQUENCE_EDITOR = "true" }, -- accept the reordered todo unchanged
                })
            end)
        end
    )
end

--- Absorb: shell out to the external `git-absorb` (github.com/tummychow/git-absorb) — exactly like Magit's
--- `commit-absorb`. It auto-creates `fixup!` commits for the STAGED changes against whichever commit last
--- touched each line and, with `--and-rebase`, folds them in via an autosquash rebase. Needs the `git-absorb`
--- binary on PATH; git-only (jj has no absorb). Both conditions are reported cleanly rather than failing.
---@param root string
---@param vcs string?
---@return nil
local function absorb(root, vcs)
    if vcs and vcs ~= "git" then
        notify("absorb is a git-only operation", vim.log.levels.WARN)
        return
    end
    if vim.fn.executable("git-absorb") ~= 1 then
        notify("git-absorb is not installed — see github.com/tummychow/git-absorb", vim.log.levels.WARN)
        return
    end
    -- No `--base`: git-absorb defaults to the mutable range (commits not yet pushed/merged), the common case.
    M.execute(root, { "absorb", "--and-rebase" }, { op = "commit", vcs = vcs, head_changed = true })
end

--- Autofixup: shell out to the external `git-autofixup` (github.com/torbiak/git-autofixup) — Magit's
--- `commit-autofixup`. It is absorb's more HEURISTIC cousin: it attributes each UNSTAGED hunk to a commit in
--- `base..HEAD` using the changed lines AND the surrounding CONTEXT (tunable `--strict`), so it catches added
--- lines / ambiguous hunks that git-absorb skips. It only CREATES `fixup!` commits, so we fold them in with a
--- non-interactive autosquash rebase afterwards. Run through `backend.system` (not `M.execute`) because its `-e`
--- exit codes (1 = only some hunks assigned, 2/3 = none) are normal outcomes, not failures. Git-only + gated
--- on the binary; both reported cleanly.
---@param root string
---@param vcs string?
---@param base string   the boundary: only commits AFTER it are fixup targets
---@param strict integer  0 (most aggressive) … 3 (most conservative)
---@return nil
local function autofixup(root, vcs, base, strict)
    if vcs and vcs ~= "git" then
        notify("autofixup is a git-only operation", vim.log.levels.WARN)
        return
    end
    if vim.fn.executable("git-autofixup") ~= 1 then
        notify("git-autofixup is not installed — see github.com/torbiak/git-autofixup", vim.log.levels.WARN)
        return
    end
    local argv = git_argv({ "autofixup", "--exit-code", "--strict", tostring(strict or 0), base })
    backend.system(root, argv, {}, function(res)
        local code = res.code
        if code == 2 or code == 3 then
            notify("autofixup: nothing to fold in")
            return
        end
        if code ~= 0 and code ~= 1 then
            notify(
                "autofixup failed: " .. vim.trim((res.stderr or "") ~= "" and res.stderr or ("exit " .. tostring(code))),
                vim.log.levels.ERROR
            )
            return
        end
        notify(
            code == 1 and "autofixup: some hunks assigned — folding in"
                or "autofixup: all hunks assigned — folding in"
        )
        -- `fixup!` commits only (no message edit) → non-interactive autosquash (GIT_SEQUENCE_EDITOR accepts the
        -- reordered todo unchanged; `editor` omitted so the sequencer panel never opens).
        M.execute(root, { "rebase", "-i", "--autosquash", "--autostash", base }, {
            op = "commit",
            vcs = vcs,
            head_changed = true,
        })
    end)
end

--- The commit transient.
---@return LvimGitTransientDef
local function commit_def()
    return {
        id = "commit",
        title = "Commit",
        groups = {
            {
                title = "Arguments",
                infix = {
                    { kind = "switch", key = "-a", flag = "--all", label = "Stage all modified", level = 1 },
                    { kind = "switch", key = "-e", flag = "--allow-empty", label = "Allow empty", level = 3 },
                    { kind = "switch", key = "-s", flag = "--signoff", label = "Add Signed-off-by", level = 1 },
                    { kind = "switch", key = "-n", flag = "--no-verify", label = "Disable hooks", level = 2 },
                    { kind = "switch", key = "-R", flag = "--reset-author", label = "Reset author", level = 4 },
                    { kind = "option", key = "=A", arg = "--author", label = "Override author", level = 4 },
                    { kind = "option", key = "=S", arg = "--gpg-sign", label = "Sign (gpg keyid)", level = 5 },
                    { kind = "option", key = "=D", arg = "--date", label = "Override date", level = 5 },
                },
            },
            {
                title = "Create",
                actions = {
                    {
                        key = "c",
                        label = "Commit",
                        run = function(args, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                commit_panel(root, vcs, args, "commit")
                            end
                        end,
                    },
                    {
                        key = "e",
                        label = "Extend (amend, keep message)",
                        run = function(args, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                M.execute(
                                    root,
                                    vim.list_extend({ "commit", "--amend", "--no-edit" }, args),
                                    { op = "commit", vcs = vcs, head_changed = true }
                                )
                            end
                        end,
                    },
                    {
                        key = "w",
                        label = "Reword (message only)",
                        run = function(args, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                commit_panel(root, vcs, args, "reword")
                            end
                        end,
                    },
                    {
                        key = "a",
                        label = "Amend",
                        run = function(args, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                commit_panel(root, vcs, args, "amend")
                            end
                        end,
                    },
                },
            },
            {
                title = "Fixup / squash",
                actions = {
                    {
                        key = "f",
                        label = "Fixup",
                        level = 2,
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                pick_commit(root, "Fixup which commit?", function(id)
                                    fixup_squash(root, vcs, id, "fixup", false)
                                end)
                            end
                        end,
                    },
                    {
                        key = "F",
                        label = "Instant fixup",
                        level = 3,
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                pick_commit(root, "Instant-fixup which commit?", function(id)
                                    fixup_squash(root, vcs, id, "fixup", true)
                                end)
                            end
                        end,
                    },
                    {
                        key = "s",
                        label = "Squash",
                        level = 3,
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                pick_commit(root, "Squash into which commit?", function(id)
                                    fixup_squash(root, vcs, id, "squash", false)
                                end)
                            end
                        end,
                    },
                    {
                        key = "S",
                        label = "Instant squash",
                        level = 4,
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                pick_commit(root, "Instant-squash into which commit?", function(id)
                                    fixup_squash(root, vcs, id, "squash", true)
                                end)
                            end
                        end,
                    },
                    {
                        key = "b",
                        label = "Absorb (git-absorb) staged into their commits",
                        level = 3,
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                guard("Absorb staged changes into their commits (autosquash rebase)?", function()
                                    absorb(root, vcs)
                                end)
                            end
                        end,
                    },
                    {
                        key = "u",
                        label = "Autofixup (git-autofixup) unstaged into their commits",
                        level = 4,
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                pick_commit(root, "Autofixup: base (fold into commits after it)?", function(id)
                                    guard(
                                        "Autofixup unstaged changes into their commits (autosquash rebase)?",
                                        function()
                                            autofixup(root, vcs, id, 0)
                                        end
                                    )
                                end)
                            end
                        end,
                    },
                },
            },
        },
    }
end

-- ── push ─────────────────────────────────────────────────────────────────────

---@return LvimGitTransientDef
local function push_def()
    return {
        id = "push",
        title = "Push",
        groups = {
            {
                title = "Arguments",
                infix = {
                    { kind = "switch", key = "-f", flag = "--force-with-lease", label = "Force with lease", level = 1 },
                    { kind = "switch", key = "-F", flag = "--force", label = "Force", level = 4 },
                    { kind = "switch", key = "-d", flag = "--dry-run", label = "Dry run", level = 2 },
                    { kind = "switch", key = "-t", flag = "--tags", label = "Push tags", level = 2 },
                    { kind = "switch", key = "-T", flag = "--follow-tags", label = "Follow tags", level = 3 },
                    { kind = "switch", key = "-n", flag = "--no-verify", label = "Disable hooks", level = 3 },
                },
            },
            {
                title = "Push to",
                actions = {
                    {
                        key = "p",
                        label = "Push (upstream)",
                        run = function(args, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                M.execute(
                                    root,
                                    vim.list_extend({ "push" }, args),
                                    { op = "push", vcs = vcs, progress = true }
                                )
                            end
                        end,
                    },
                    {
                        key = "u",
                        label = "Push & set upstream",
                        run = function(args, ctx)
                            local root, vcs = resolve(ctx)
                            local br = root and current_branch(root)
                            if root and br then
                                pick_remote(root, "Set upstream on which remote?", function(remote)
                                    M.execute(
                                        root,
                                        vim.list_extend({ "push", "--set-upstream", remote, br }, args),
                                        { op = "push", vcs = vcs, progress = true }
                                    )
                                end)
                            end
                        end,
                    },
                    {
                        key = "e",
                        label = "Push to remote…",
                        run = function(args, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                pick_remote(root, "Push to which remote?", function(remote)
                                    M.execute(
                                        root,
                                        vim.list_extend({ "push", remote }, args),
                                        { op = "push", vcs = vcs, progress = true }
                                    )
                                end)
                            end
                        end,
                    },
                    {
                        key = "T",
                        label = "Push tags",
                        level = 2,
                        run = function(args, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                M.execute(
                                    root,
                                    vim.list_extend({ "push", "--tags" }, args),
                                    { op = "push", vcs = vcs, progress = true }
                                )
                            end
                        end,
                    },
                },
            },
        },
    }
end

-- ── pull ─────────────────────────────────────────────────────────────────────

---@return LvimGitTransientDef
local function pull_def()
    return {
        id = "pull",
        title = "Pull",
        groups = {
            {
                title = "Arguments",
                infix = {
                    { kind = "switch", key = "-r", flag = "--rebase", label = "Rebase", level = 1 },
                    { kind = "switch", key = "-f", flag = "--ff-only", label = "Fast-forward only", level = 2 },
                    { kind = "switch", key = "-a", flag = "--autostash", label = "Autostash", level = 2 },
                    { kind = "switch", key = "-t", flag = "--tags", label = "Fetch tags", level = 3 },
                    { kind = "switch", key = "-n", flag = "--no-commit", label = "No commit", level = 4 },
                },
            },
            {
                title = "Pull from",
                actions = {
                    {
                        key = "p",
                        label = "Pull (upstream)",
                        run = function(args, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                M.execute(
                                    root,
                                    vim.list_extend({ "pull" }, args),
                                    { op = "pull", vcs = vcs, progress = true, head_changed = true }
                                )
                            end
                        end,
                    },
                    {
                        key = "e",
                        label = "Pull from remote…",
                        run = function(args, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                pick_remote(root, "Pull from which remote?", function(remote)
                                    M.execute(
                                        root,
                                        vim.list_extend({ "pull", remote }, args),
                                        { op = "pull", vcs = vcs, progress = true, head_changed = true }
                                    )
                                end)
                            end
                        end,
                    },
                },
            },
        },
    }
end

-- ── fetch ────────────────────────────────────────────────────────────────────

---@return LvimGitTransientDef
local function fetch_def()
    return {
        id = "fetch",
        title = "Fetch",
        groups = {
            {
                title = "Arguments",
                infix = {
                    { kind = "switch", key = "-p", flag = "--prune", label = "Prune deleted refs", level = 1 },
                    { kind = "switch", key = "-t", flag = "--tags", label = "Fetch all tags", level = 2 },
                    { kind = "switch", key = "-f", flag = "--force", label = "Force", level = 3 },
                    { kind = "switch", key = "-u", flag = "--unshallow", label = "Unshallow", level = 5 },
                },
            },
            {
                title = "Fetch from",
                actions = {
                    {
                        key = "f",
                        label = "Fetch (upstream)",
                        run = function(args, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                M.execute(
                                    root,
                                    vim.list_extend({ "fetch" }, args),
                                    { op = "fetch", vcs = vcs, progress = true }
                                )
                            end
                        end,
                    },
                    {
                        key = "a",
                        label = "Fetch all remotes",
                        run = function(args, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                M.execute(
                                    root,
                                    vim.list_extend({ "fetch", "--all" }, args),
                                    { op = "fetch", vcs = vcs, progress = true }
                                )
                            end
                        end,
                    },
                    {
                        key = "e",
                        label = "Fetch from remote…",
                        run = function(args, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                pick_remote(root, "Fetch from which remote?", function(remote)
                                    M.execute(
                                        root,
                                        vim.list_extend({ "fetch", remote }, args),
                                        { op = "fetch", vcs = vcs, progress = true }
                                    )
                                end)
                            end
                        end,
                    },
                },
            },
        },
    }
end

-- ── branch ───────────────────────────────────────────────────────────────────

---@return LvimGitTransientDef
local function branch_def()
    return {
        id = "branch",
        title = "Branch",
        groups = {
            {
                title = "Arguments",
                infix = {
                    { kind = "switch", key = "-f", flag = "--force", label = "Force", level = 3 },
                },
            },
            {
                title = "Actions",
                actions = {
                    {
                        key = "b",
                        label = "Create & checkout",
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                input("New branch name", nil, function(name)
                                    M.execute(
                                        root,
                                        { "checkout", "-b", name },
                                        { op = "branch", vcs = vcs, head_changed = true }
                                    )
                                end)
                            end
                        end,
                    },
                    {
                        key = "n",
                        label = "Create (no checkout)",
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                input("New branch name", nil, function(name)
                                    M.execute(root, { "branch", name }, { op = "branch", vcs = vcs })
                                end)
                            end
                        end,
                    },
                    {
                        key = "o",
                        label = "Checkout",
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                pick_ref(root, { "local", "remote" }, "Checkout which ref?", function(name)
                                    M.execute(
                                        root,
                                        { "checkout", name },
                                        { op = "checkout", vcs = vcs, head_changed = true }
                                    )
                                end)
                            end
                        end,
                    },
                    {
                        key = "m",
                        label = "Rename current",
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                input("Rename branch to", current_branch(root), function(name)
                                    M.execute(
                                        root,
                                        { "branch", "-m", name },
                                        { op = "branch", vcs = vcs, head_changed = true }
                                    )
                                end)
                            end
                        end,
                    },
                    {
                        key = "x",
                        label = "Delete",
                        run = function(args, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                pick_ref(root, { "local" }, "Delete which branch?", function(name)
                                    local flag = vim.tbl_contains(args, "--force") and "-D" or "-d"
                                    guard(("Delete branch %s?"):format(name), function()
                                        M.execute(root, { "branch", flag, name }, { op = "branch", vcs = vcs })
                                    end)
                                end)
                            end
                        end,
                    },
                },
            },
        },
    }
end

-- ── remote ───────────────────────────────────────────────────────────────────

---@return LvimGitTransientDef
local function remote_def()
    return {
        id = "remote",
        title = "Remote",
        groups = {
            {
                title = "Actions",
                actions = {
                    {
                        key = "a",
                        label = "Add",
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                input("Remote name", "origin", function(name)
                                    input("Remote URL", nil, function(url)
                                        M.execute(root, { "remote", "add", name, url }, { op = "remote", vcs = vcs })
                                    end)
                                end)
                            end
                        end,
                    },
                    {
                        key = "r",
                        label = "Rename",
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                pick_remote(root, "Rename which remote?", function(old)
                                    input("Rename " .. old .. " to", nil, function(new)
                                        M.execute(root, { "remote", "rename", old, new }, { op = "remote", vcs = vcs })
                                    end)
                                end)
                            end
                        end,
                    },
                    {
                        key = "x",
                        label = "Remove",
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                pick_remote(root, "Remove which remote?", function(name)
                                    guard(("Remove remote %s?"):format(name), function()
                                        M.execute(root, { "remote", "remove", name }, { op = "remote", vcs = vcs })
                                    end)
                                end)
                            end
                        end,
                    },
                },
            },
        },
    }
end

-- ── merge ────────────────────────────────────────────────────────────────────

---@return LvimGitTransientDef
local function merge_def()
    return {
        id = "merge",
        title = "Merge",
        groups = {
            {
                title = "Arguments",
                infix = {
                    { kind = "switch", key = "-n", flag = "--no-ff", label = "No fast-forward", level = 1 },
                    { kind = "switch", key = "-f", flag = "--ff-only", label = "Fast-forward only", level = 2 },
                    { kind = "switch", key = "-s", flag = "--squash", label = "Squash", level = 2 },
                    { kind = "switch", key = "-c", flag = "--no-commit", label = "No commit", level = 3 },
                },
            },
            {
                title = "Actions",
                actions = {
                    {
                        key = "m",
                        label = "Merge",
                        run = function(args, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                pick_ref(root, { "local", "remote" }, "Merge which ref?", function(name)
                                    M.execute(
                                        root,
                                        vim.list_extend({ "merge", name }, args),
                                        { op = "merge", vcs = vcs, head_changed = true }
                                    )
                                end)
                            end
                        end,
                    },
                    {
                        key = "a",
                        label = "Abort",
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                M.execute(
                                    root,
                                    { "merge", "--abort" },
                                    { op = "merge", vcs = vcs, head_changed = true }
                                )
                            end
                        end,
                    },
                },
            },
        },
    }
end

-- ── reset ────────────────────────────────────────────────────────────────────

---@param root string
---@param vcs string?
---@param mode string
---@param destructive boolean
---@param prompt string
local function reset_pick(root, vcs, mode, destructive, prompt)
    pick_commit(root, prompt, function(id, ab)
        local function run()
            M.execute(root, { "reset", mode, id }, { op = "reset", vcs = vcs, head_changed = true })
        end
        if destructive then
            guard(("%s reset to %s (discards changes)?"):format(mode, ab), run)
        else
            run()
        end
    end)
end

---@return LvimGitTransientDef
local function reset_def()
    return {
        id = "reset",
        title = "Reset",
        groups = {
            {
                title = "Actions",
                actions = {
                    {
                        key = "m",
                        label = "Mixed (keep worktree, reset index)",
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                reset_pick(root, vcs, "--mixed", false, "Mixed-reset to?")
                            end
                        end,
                    },
                    {
                        key = "s",
                        label = "Soft (keep index & worktree)",
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                reset_pick(root, vcs, "--soft", false, "Soft-reset to?")
                            end
                        end,
                    },
                    {
                        key = "h",
                        label = "Hard (discard everything)",
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                reset_pick(root, vcs, "--hard", true, "Hard-reset to?")
                            end
                        end,
                    },
                    {
                        key = "K",
                        label = "Keep (reset, keep local changes)",
                        level = 3,
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                reset_pick(root, vcs, "--keep", false, "Keep-reset to?")
                            end
                        end,
                    },
                },
            },
        },
    }
end

-- ── tag ──────────────────────────────────────────────────────────────────────

---@return LvimGitTransientDef
local function tag_def()
    return {
        id = "tag",
        title = "Tag",
        groups = {
            {
                title = "Arguments",
                infix = {
                    { kind = "switch", key = "-f", flag = "--force", label = "Force (replace)", level = 1 },
                    { kind = "switch", key = "-s", flag = "--sign", label = "GPG-sign", level = 3 },
                },
            },
            {
                title = "Actions",
                actions = {
                    {
                        key = "t",
                        label = "Create (lightweight, at HEAD)",
                        run = function(args, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                input("Tag name", nil, function(name)
                                    M.execute(root, vim.list_extend({ "tag", name }, args), { op = "tag", vcs = vcs })
                                end)
                            end
                        end,
                    },
                    {
                        key = "a",
                        label = "Create annotated (opens editor)",
                        run = function(args, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                input("Annotated tag name", nil, function(name)
                                    -- `git tag -a <name>` spawns the editor for the message → the with-editor bridge.
                                    M.execute(
                                        root,
                                        vim.list_extend({ "tag", "-a", name }, args),
                                        { op = "tag", vcs = vcs, editor = true }
                                    )
                                end)
                            end
                        end,
                    },
                    {
                        key = "x",
                        label = "Delete",
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                pick_ref(root, { "tag" }, "Delete which tag?", function(name)
                                    guard(("Delete tag %s?"):format(name), function()
                                        M.execute(root, { "tag", "-d", name }, { op = "tag", vcs = vcs })
                                    end)
                                end)
                            end
                        end,
                    },
                },
            },
        },
    }
end

-- ── revert ───────────────────────────────────────────────────────────────────

---@return LvimGitTransientDef
local function revert_def()
    return {
        id = "revert",
        title = "Revert",
        groups = {
            {
                title = "Arguments",
                infix = {
                    { kind = "switch", key = "-e", flag = "--edit", label = "Edit message", level = 3 },
                    { kind = "switch", key = "-n", flag = "--no-commit", label = "No commit", level = 2 },
                    { kind = "switch", key = "-s", flag = "--signoff", label = "Add Signed-off-by", level = 3 },
                },
            },
            {
                title = "Actions",
                actions = {
                    {
                        key = "v",
                        label = "Revert commit",
                        run = function(args, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                local edit = vim.tbl_contains(args, "--edit")
                                pick_commit(root, "Revert which commit?", function(id)
                                    local a = vim.list_extend({ "revert" }, args)
                                    if not edit then
                                        a[#a + 1] = "--no-edit"
                                    end
                                    a[#a + 1] = id
                                    M.execute(root, a, { op = "revert", vcs = vcs, head_changed = true, editor = edit })
                                end)
                            end
                        end,
                    },
                    {
                        key = "c",
                        label = "Continue",
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                M.execute(
                                    root,
                                    { "revert", "--continue" },
                                    { op = "revert", vcs = vcs, head_changed = true, editor = true }
                                )
                            end
                        end,
                    },
                    {
                        key = "s",
                        label = "Skip",
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                M.execute(
                                    root,
                                    { "revert", "--skip" },
                                    { op = "revert", vcs = vcs, head_changed = true }
                                )
                            end
                        end,
                    },
                    {
                        key = "a",
                        label = "Abort",
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                M.execute(
                                    root,
                                    { "revert", "--abort" },
                                    { op = "revert", vcs = vcs, head_changed = true }
                                )
                            end
                        end,
                    },
                },
            },
        },
    }
end

-- ── cherry-pick ──────────────────────────────────────────────────────────────

---@return LvimGitTransientDef
local function cherry_pick_def()
    return {
        id = "cherry-pick",
        title = "Cherry-pick",
        groups = {
            {
                title = "Arguments",
                infix = {
                    { kind = "switch", key = "-e", flag = "--edit", label = "Edit message", level = 3 },
                    { kind = "switch", key = "-n", flag = "--no-commit", label = "No commit", level = 2 },
                    { kind = "switch", key = "-x", flag = "-x", label = "Reference source", level = 3 },
                    { kind = "switch", key = "-s", flag = "--signoff", label = "Add Signed-off-by", level = 3 },
                },
            },
            {
                title = "Actions",
                actions = {
                    {
                        key = "A",
                        label = "Pick commit",
                        run = function(args, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                local edit = vim.tbl_contains(args, "--edit")
                                pick_commit(root, "Cherry-pick which commit?", function(id)
                                    local a = vim.list_extend({ "cherry-pick" }, args)
                                    a[#a + 1] = id
                                    M.execute(
                                        root,
                                        a,
                                        { op = "cherry-pick", vcs = vcs, head_changed = true, editor = edit }
                                    )
                                end)
                            end
                        end,
                    },
                    {
                        key = "c",
                        label = "Continue",
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                M.execute(
                                    root,
                                    { "cherry-pick", "--continue" },
                                    { op = "cherry-pick", vcs = vcs, head_changed = true, editor = true }
                                )
                            end
                        end,
                    },
                    {
                        key = "s",
                        label = "Skip",
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                M.execute(
                                    root,
                                    { "cherry-pick", "--skip" },
                                    { op = "cherry-pick", vcs = vcs, head_changed = true }
                                )
                            end
                        end,
                    },
                    {
                        key = "a",
                        label = "Abort",
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                M.execute(
                                    root,
                                    { "cherry-pick", "--abort" },
                                    { op = "cherry-pick", vcs = vcs, head_changed = true }
                                )
                            end
                        end,
                    },
                },
            },
        },
    }
end

-- ── rebase + the sequencer (continue / skip / abort / edit-todo) ────────────────

--- Drive the shared git SEQUENCER for the in-progress operation. rebase / cherry-pick / revert all share
--- git's sequencer state, so the op verb is derived from the repo's live `state`. `continue`/`edit-todo`
--- route through the with-editor bridge (git may re-open a message editor / the todo). `edit-todo` is
--- rebase-only. Public: the status sequencer section + the rebase transient's Sequence group call here.
---@param root string
---@param vcs string?
---@param op "continue"|"skip"|"abort"|"edit-todo"
function M.sequence(root, vcs, op)
    local repo = backend.repo(root)
    local st = repo and repo.state or nil
    local cmd = (st == "cherry-pick" and "cherry-pick") or (st == "revert" and "revert") or "rebase"
    if op == "edit-todo" and cmd ~= "rebase" then
        notify("edit-todo is only available during a rebase", vim.log.levels.WARN)
        return
    end
    local editor = op == "continue" or op == "edit-todo"
    M.execute(root, { cmd, "--" .. op }, { op = cmd .. " " .. op, vcs = vcs, head_changed = true, editor = editor })
end

--- Start an INTERACTIVE rebase that replays `commit` and every descendant — i.e. rebase from `commit`'s
--- parent — so the user can reword / edit / drop it in the todo panel (opened via the editor bridge). A
--- root commit (no parent) uses `--root`. Public: the log/refs/blame per-commit "rebase from here".
---@param root string
---@param vcs string?
---@param commit { id: string, parents?: string[] }
function M.rebase_interactive(root, vcs, commit)
    local base = commit.parents and commit.parents[1] or nil
    local argv = { "rebase", "-i", "--autostash" }
    argv[#argv + 1] = base or "--root"
    M.execute(root, argv, { op = "rebase", vcs = vcs, head_changed = true, editor = true })
end

--- Assemble + run a rebase from the transient args. `--autosquash` implies an interactive rebase, so we
--- force `--interactive` when either it or autosquash is set; an interactive rebase routes the todo (and
--- any reword/squash message) through the with-editor bridge.
---@param root string
---@param vcs string?
---@param args string[]  the assembled infix argv
---@param tail string[]  the positional target (`<upstream>` / `--onto <newbase> <upstream>`)
local function run_rebase(root, vcs, args, tail)
    local interactive = vim.tbl_contains(args, "--interactive") or vim.tbl_contains(args, "--autosquash")
    local a = { "rebase" }
    if interactive and not vim.tbl_contains(args, "--interactive") then
        a[#a + 1] = "--interactive"
    end
    vim.list_extend(a, args)
    vim.list_extend(a, tail or {})
    M.execute(root, a, { op = "rebase", vcs = vcs, head_changed = true, editor = interactive })
end

--- The rebase transient — onto / subset / --onto / interactive (+ autosquash) + the shared sequencer
--- controls (continue / skip / abort / edit-todo). Interactive variants open the todo panel via the
--- editor bridge; the sequencer controls resume/abort an in-progress rebase or cherry-pick/revert.
---@return LvimGitTransientDef
local function rebase_def()
    return {
        id = "rebase",
        title = "Rebase",
        groups = {
            {
                title = "Arguments",
                infix = {
                    {
                        kind = "switch",
                        key = "-i",
                        flag = "--interactive",
                        label = "Interactive (edit todo)",
                        level = 1,
                    },
                    {
                        kind = "switch",
                        key = "-a",
                        flag = "--autosquash",
                        label = "Autosquash fixup!/squash!",
                        level = 1,
                    },
                    { kind = "switch", key = "-A", flag = "--autostash", label = "Autostash", level = 1 },
                    { kind = "switch", key = "-k", flag = "--keep-empty", label = "Keep empty commits", level = 3 },
                    { kind = "switch", key = "-m", flag = "--rebase-merges", label = "Rebase merges", level = 4 },
                    {
                        kind = "switch",
                        key = "-d",
                        flag = "--committer-date-is-author-date",
                        label = "Keep author dates",
                        level = 5,
                    },
                },
            },
            {
                title = "Rebase",
                actions = {
                    {
                        key = "e",
                        label = "Onto a branch / ref…",
                        run = function(args, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                pick_ref(root, { "local", "remote", "tag" }, "Rebase onto which ref?", function(name)
                                    run_rebase(root, vcs, args, { name })
                                end)
                            end
                        end,
                    },
                    {
                        key = "s",
                        label = "Onto a subset (upstream commit)…",
                        run = function(args, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                pick_commit(root, "Rebase onto which commit?", function(id)
                                    run_rebase(root, vcs, args, { id })
                                end)
                            end
                        end,
                    },
                    {
                        key = "o",
                        label = "Onto (--onto newbase upstream)…",
                        level = 2,
                        run = function(args, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                pick_commit(root, "New base (--onto)?", function(newbase)
                                    pick_commit(root, "Upstream (replay commits after)?", function(upstream)
                                        run_rebase(root, vcs, args, { "--onto", newbase, upstream })
                                    end)
                                end)
                            end
                        end,
                    },
                    {
                        key = "i",
                        label = "Interactively (pick a base)…",
                        run = function(args, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                pick_commit(root, "Interactive rebase onto which commit?", function(id)
                                    local a = vim.list_extend({}, args)
                                    if not vim.tbl_contains(a, "--interactive") then
                                        a[#a + 1] = "--interactive"
                                    end
                                    run_rebase(root, vcs, a, { id })
                                end)
                            end
                        end,
                    },
                    {
                        key = "m",
                        label = "Modify a commit (reword / edit / drop)…",
                        level = 2,
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                pick_commit(root, "Modify which commit?", function(id)
                                    M.rebase_interactive(root, vcs, { id = id, parents = { id .. "^" } })
                                end)
                            end
                        end,
                    },
                },
            },
            {
                title = "Sequence",
                actions = {
                    {
                        key = "r",
                        label = "Continue",
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                M.sequence(root, vcs, "continue")
                            end
                        end,
                    },
                    {
                        key = "S",
                        label = "Skip",
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                M.sequence(root, vcs, "skip")
                            end
                        end,
                    },
                    {
                        key = "a",
                        label = "Abort",
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                M.sequence(root, vcs, "abort")
                            end
                        end,
                    },
                    {
                        key = "t",
                        label = "Edit todo",
                        level = 2,
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                M.sequence(root, vcs, "edit-todo")
                            end
                        end,
                    },
                },
            },
        },
    }
end

-- ── stash ────────────────────────────────────────────────────────────────────

--- Resolve the stash a stash-verb operates on: a pre-selected ref on `ctx.selection` (the status
--- stashes section / the stash panel pass the row's ref) wins, else pick one through the canonical
--- lvim-ui select over `git stash list`. `cb(ref)`.
---@param root string
---@param ctx? LvimGitTransientCtx
---@param prompt string
---@param cb fun(ref: string)
local function stash_target(root, ctx, prompt, cb)
    local sel = ctx and ctx.selection --[[@as { ref?: string }?]]
    if sel and sel.ref then
        cb(sel.ref)
        return
    end
    backend.stash_list(root, function(list)
        if not list or #list == 0 then
            notify("no stashes", vim.log.levels.WARN)
            return
        end
        local items = {}
        for _, s in ipairs(list) do
            items[#items + 1] = { label = s.ref .. "  " .. (s.message or ""), _ref = s.ref }
        end
        ui.select({
            title = prompt,
            items = items,
            callback = function(ok, idx)
                if ok and items[idx] then
                    cb(items[idx]._ref)
                end
            end,
        })
    end)
end

--- Push the working tree onto the stash (honouring the transient switches: --keep-index /
--- --include-untracked / --all / --staged). Prompts for an optional message (empty = none). Public: the
--- stash transient `z` and the stash panel `z`.
---@param root string
---@param vcs string?
---@param args? string[]  the assembled infix argv
function M.stash_push(root, vcs, args)
    ui.input({
        title = "Stash message (empty = none)",
        callback = function(ok, msg)
            if not ok then
                return
            end
            local a = { "stash", "push" }
            vim.list_extend(a, args or {})
            msg = msg and vim.trim(msg) or ""
            if msg ~= "" then
                a[#a + 1] = "-m"
                a[#a + 1] = msg
            end
            M.execute(root, a, { op = "stash", vcs = vcs })
        end,
    })
end

--- Snapshot: record a WIP stash commit that KEEPS the working tree intact. Root-cause mechanism —
--- `git stash create` builds the stash commit WITHOUT touching the worktree or the index, and
--- `git stash store` records it in the stash reflog; no re-apply, no worktree mutation (git's own
--- snapshot seam). Tracked modifications only (create has no untracked capture). Public.
---@param root string
---@param vcs string?
function M.stash_snapshot(root, vcs)
    backend.output(root, git_argv({ "stash", "create" }), function(out)
        local sha = out and vim.trim(out) or ""
        if sha == "" then
            notify("nothing to snapshot (working tree clean)")
            return
        end
        local branch = current_branch(root) or "HEAD"
        M.execute(root, { "stash", "store", "-m", "WIP on " .. branch .. " (snapshot)", sha }, {
            op = "stash",
            vcs = vcs,
        })
    end)
end

--- Apply a stash without dropping it. Public.
---@param root string
---@param vcs string?
---@param ref string
function M.stash_apply(root, vcs, ref)
    M.execute(root, { "stash", "apply", ref }, { op = "stash", vcs = vcs })
end

--- Pop a stash (apply then drop). Public.
---@param root string
---@param vcs string?
---@param ref string
function M.stash_pop(root, vcs, ref)
    M.execute(root, { "stash", "pop", ref }, { op = "stash", vcs = vcs })
end

--- Drop a stash (guarded — dropping loses the stash). Public.
---@param root string
---@param vcs string?
---@param ref string
function M.stash_drop(root, vcs, ref)
    guard(("Drop %s?"):format(ref), function()
        M.execute(root, { "stash", "drop", ref }, { op = "stash", vcs = vcs })
    end)
end

--- Create a branch from a stash and drop it (`git stash branch`). Public.
---@param root string
---@param vcs string?
---@param ref string
function M.stash_branch(root, vcs, ref)
    input("New branch from " .. ref, nil, function(name)
        M.execute(root, { "stash", "branch", name, ref }, { op = "stash", vcs = vcs, head_changed = true })
    end)
end

--- Clear ALL stashes (guarded — irreversible). Public.
---@param root string
---@param vcs string?
function M.stash_clear(root, vcs)
    guard("Clear ALL stashes? (irreversible)", function()
        M.execute(root, { "stash", "clear" }, { op = "stash", vcs = vcs })
    end)
end

--- Show a stash's diff in the diffview (its base `^1` → the stash commit — the `git stash show` range).
--- Public: the stash transient `v` and the stash panel `<CR>`.
---@param ref string
function M.stash_show(ref)
    local ok = pcall(function()
        require("lvim-git").diffview({ range = ref .. "^1.." .. ref })
    end)
    if not ok then
        notify("the diffview component is not available", vim.log.levels.WARN)
    end
end

--- The stash transient (Magit `magit-stash`) — save / snapshot / apply / pop / drop / branch / show /
--- clear. Save honours the switches; the apply/pop/drop/branch/show actions operate on `ctx.selection`
--- (a stash row passed by the status section or the stash panel) or pick one via the lvim-ui select.
---@return LvimGitTransientDef
local function stash_def()
    return {
        id = "stash",
        title = "Stash",
        groups = {
            {
                title = "Arguments",
                infix = {
                    { kind = "switch", key = "-k", flag = "--keep-index", label = "Keep index", level = 1 },
                    {
                        kind = "switch",
                        key = "-u",
                        flag = "--include-untracked",
                        label = "Include untracked",
                        level = 1,
                    },
                    { kind = "switch", key = "-a", flag = "--all", label = "Include ignored & untracked", level = 3 },
                    { kind = "switch", key = "-S", flag = "--staged", label = "Only staged changes", level = 2 },
                },
            },
            {
                title = "Save",
                actions = {
                    {
                        key = "z",
                        label = "Save (push, message)",
                        run = function(args, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                M.stash_push(root, vcs, args)
                            end
                        end,
                    },
                    {
                        key = "i",
                        label = "Snapshot (keep worktree)",
                        level = 2,
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                M.stash_snapshot(root, vcs)
                            end
                        end,
                    },
                },
            },
            {
                title = "Use",
                actions = {
                    {
                        key = "a",
                        label = "Apply",
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                stash_target(root, ctx, "Apply which stash?", function(ref)
                                    M.stash_apply(root, vcs, ref)
                                end)
                            end
                        end,
                    },
                    {
                        key = "p",
                        label = "Pop",
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                stash_target(root, ctx, "Pop which stash?", function(ref)
                                    M.stash_pop(root, vcs, ref)
                                end)
                            end
                        end,
                    },
                    {
                        key = "d",
                        label = "Drop",
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                stash_target(root, ctx, "Drop which stash?", function(ref)
                                    M.stash_drop(root, vcs, ref)
                                end)
                            end
                        end,
                    },
                    {
                        key = "b",
                        label = "Branch from stash",
                        level = 2,
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                stash_target(root, ctx, "Branch from which stash?", function(ref)
                                    M.stash_branch(root, vcs, ref)
                                end)
                            end
                        end,
                    },
                },
            },
            {
                title = "Inspect",
                actions = {
                    {
                        key = "v",
                        label = "Show diff",
                        run = function(_, ctx)
                            local root = resolve(ctx)
                            if root then
                                stash_target(root, ctx, "Show which stash?", function(ref)
                                    M.stash_show(ref)
                                end)
                            end
                        end,
                    },
                    {
                        key = "l",
                        label = "List stashes",
                        run = function()
                            local ok = pcall(function()
                                require("lvim-git.ui.stash").open()
                            end)
                            if not ok then
                                notify("the stash panel is not available", vim.log.levels.WARN)
                            end
                        end,
                    },
                    {
                        key = "K",
                        label = "Clear all",
                        level = 3,
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                M.stash_clear(root, vcs)
                            end
                        end,
                    },
                },
            },
        },
    }
end

-- ── per-commit actions (the log/history/refs "thing at point") ──────────────────

-- The all-zeros empty-tree object, so a ROOT commit (no parent) still has a diff base.
local EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

--- Open the diffview on a commit's OWN diff (its first parent → the commit; empty tree for a root).
--- Public: the log/history "view this commit's diff" action routes here.
---@param commit Commit
function M.view_commit_diff(commit)
    local base = (commit.parents and commit.parents[1]) or EMPTY_TREE
    local range = base .. ".." .. commit.id
    local ok = pcall(function()
        require("lvim-git").diffview({ range = range })
    end)
    if not ok then
        notify("the diffview component is not available", vim.log.levels.WARN)
    end
end

--- The per-commit action transient — Magit's "the thing at point" for a log/history row. The commit is
--- carried on `ctx.selection`; each action dispatches to a verb on THAT commit (no re-pick). Git-lens
--- actions; jj-lens variants (squash/abandon/duplicate) land in phase 13.
---@return LvimGitTransientDef
local function commit_actions_def()
    ---@param ctx LvimGitTransientCtx
    ---@return string? root, string? vcs, Commit? commit
    local function target(ctx)
        local root, vcs = resolve(ctx)
        return root, vcs, ctx and ctx.selection --[[@as Commit?]]
    end
    return {
        id = "commit-actions",
        title = "Commit actions",
        groups = {
            {
                title = "Apply",
                actions = {
                    {
                        key = "b",
                        label = "Branch & checkout here",
                        run = function(_, ctx)
                            local root, vcs, c = target(ctx)
                            if root and c then
                                input("New branch at " .. c.abbrev, nil, function(name)
                                    M.execute(
                                        root,
                                        { "checkout", "-b", name, c.id },
                                        { op = "branch", vcs = vcs, head_changed = true }
                                    )
                                end)
                            end
                        end,
                    },
                    {
                        key = "o",
                        label = "Checkout (detach here)",
                        run = function(_, ctx)
                            local root, vcs, c = target(ctx)
                            if root and c then
                                M.execute(
                                    root,
                                    { "checkout", c.id },
                                    { op = "checkout", vcs = vcs, head_changed = true }
                                )
                            end
                        end,
                    },
                    {
                        key = "t",
                        label = "Tag here",
                        run = function(_, ctx)
                            local root, vcs, c = target(ctx)
                            if root and c then
                                input("Tag name at " .. c.abbrev, nil, function(name)
                                    M.execute(root, { "tag", name, c.id }, { op = "tag", vcs = vcs })
                                end)
                            end
                        end,
                    },
                    {
                        key = "A",
                        label = "Cherry-pick onto HEAD",
                        run = function(_, ctx)
                            local root, vcs, c = target(ctx)
                            if root and c then
                                M.execute(
                                    root,
                                    { "cherry-pick", c.id },
                                    { op = "cherry-pick", vcs = vcs, head_changed = true }
                                )
                            end
                        end,
                    },
                    {
                        key = "V",
                        label = "Revert",
                        run = function(_, ctx)
                            local root, vcs, c = target(ctx)
                            if root and c then
                                M.execute(
                                    root,
                                    { "revert", "--no-edit", c.id },
                                    { op = "revert", vcs = vcs, head_changed = true }
                                )
                            end
                        end,
                    },
                    {
                        key = "X",
                        label = "Reset HEAD here (mixed)",
                        run = function(_, ctx)
                            local root, vcs, c = target(ctx)
                            if root and c then
                                guard(("Reset --mixed to %s?"):format(c.abbrev), function()
                                    M.execute(
                                        root,
                                        { "reset", "--mixed", c.id },
                                        { op = "reset", vcs = vcs, head_changed = true }
                                    )
                                end)
                            end
                        end,
                    },
                    {
                        key = "r",
                        label = "Rebase interactively from here",
                        run = function(_, ctx)
                            local root, vcs, c = target(ctx)
                            if root and c then
                                M.rebase_interactive(root, vcs, c)
                            end
                        end,
                    },
                },
            },
            {
                title = "Inspect",
                actions = {
                    {
                        key = "d",
                        label = "View diff",
                        run = function(_, ctx)
                            local _, _, c = target(ctx)
                            if c then
                                M.view_commit_diff(c)
                            end
                        end,
                    },
                    {
                        key = "y",
                        label = "Copy hash",
                        run = function(_, ctx)
                            local _, _, c = target(ctx)
                            if c then
                                vim.fn.setreg("+", c.id)
                                vim.fn.setreg('"', c.id)
                                notify("yanked " .. c.abbrev)
                            end
                        end,
                    },
                },
            },
        },
    }
end

--- Open the per-commit action popup for `commit` (used by ui/log, ui/history, ui/refs cherry).
---@param commit Commit
---@param root string
---@param vcs? string
function M.commit_actions(commit, root, vcs)
    M.register()
    transient.open("commit-actions", { root = root, lens = vcs, selection = commit })
end

-- ── phase-11 pickers (submodule / worktree / patch file) ──────────────────────

--- Pick a submodule path from the repo's submodule list through the canonical select. `cb(path)`.
---@param root string
---@param prompt string
---@param cb fun(path: string)
local function pick_submodule(root, prompt, cb)
    backend.submodule_status(root, function(subs)
        if not subs or #subs == 0 then
            notify("no submodules", vim.log.levels.WARN)
            return
        end
        local items = {}
        for _, s in ipairs(subs) do
            items[#items + 1] = { label = s.path .. "  " .. s.sha, _path = s.path }
        end
        ui.select({
            title = prompt,
            items = items,
            callback = function(ok, idx)
                if ok and items[idx] then
                    cb(items[idx]._path)
                end
            end,
        })
    end)
end

--- Pick a worktree from `git worktree list` through the canonical select. `cb(worktree)`.
---@param root string
---@param prompt string
---@param cb fun(wt: table)
local function pick_worktree(root, prompt, cb)
    backend.worktree_list(root, function(list)
        if not list or #list == 0 then
            notify("no worktrees", vim.log.levels.WARN)
            return
        end
        local items = {}
        for _, w in ipairs(list) do
            local desc = w.branch and ("[" .. w.branch .. "]") or (w.detached and "(detached)" or "")
            items[#items + 1] = { label = w.path .. "  " .. desc, _wt = w }
        end
        ui.select({
            title = prompt,
            items = items,
            callback = function(ok, idx)
                if ok and items[idx] then
                    cb(items[idx]._wt)
                end
            end,
        })
    end)
end

--- Pick a patch/mbox file for `am`/`apply` — globs the common patch extensions under the repo root and
--- offers the canonical select; when none are found, falls back to typing a path. `cb(path)`.
---@param root string
---@param prompt string
---@param cb fun(path: string)
local function pick_patch_file(root, prompt, cb)
    local items = {}
    local seen = {}
    for _, pat in ipairs({ "*.patch", "*.diff", "*.mbox", "*.eml", "*/*.patch" }) do
        for _, f in ipairs(vim.fn.globpath(root, pat, false, true)) do
            if not seen[f] then
                seen[f] = true
                items[#items + 1] = { label = vim.fn.fnamemodify(f, ":."), _path = f }
            end
        end
    end
    if #items == 0 then
        input("Patch file path", nil, cb)
        return
    end
    ui.select({
        title = prompt,
        items = items,
        callback = function(ok, idx)
            if ok and items[idx] then
                cb(items[idx]._path)
            end
        end,
    })
end

-- ── submodule ──────────────────────────────────────────────────────────────

--- Update (`--init`/`--recursive`/`--remote` per the transient) one or all submodules. Public: the
--- submodule panel `u` and the submodule transient. When `path` is nil, updates every submodule.
---@param root string
---@param vcs string?
---@param args? string[]  the assembled infix argv
---@param path? string
function M.submodule_update(root, vcs, args, path)
    local a = { "submodule", "update" }
    vim.list_extend(a, args or {})
    if path then
        a[#a + 1] = "--"
        a[#a + 1] = path
    end
    M.execute(root, a, { op = "submodule", vcs = vcs, progress = true })
end

--- Register (init) one or all submodules. Public: the submodule panel `i`.
---@param root string
---@param vcs string?
---@param path? string
function M.submodule_init(root, vcs, path)
    local a = { "submodule", "init" }
    if path then
        a[#a + 1] = "--"
        a[#a + 1] = path
    end
    M.execute(root, a, { op = "submodule", vcs = vcs })
end

--- Synchronize a submodule's remote URL from `.gitmodules`. Public: the submodule panel `s`.
---@param root string
---@param vcs string?
---@param args? string[]
---@param path? string
function M.submodule_sync(root, vcs, args, path)
    local a = { "submodule", "sync" }
    vim.list_extend(a, args or {})
    if path then
        a[#a + 1] = "--"
        a[#a + 1] = path
    end
    M.execute(root, a, { op = "submodule", vcs = vcs })
end

--- Add a new submodule (`git submodule add <url> <path>`). Public: the submodule panel `a`.
---@param root string
---@param vcs string?
function M.submodule_add(root, vcs)
    input("Submodule repository URL", nil, function(url)
        input("Path (where to clone it)", nil, function(path)
            M.execute(root, { "submodule", "add", url, path }, { op = "submodule", vcs = vcs, progress = true })
        end)
    end)
end

--- Unpopulate (deinit) a submodule. Guarded (drops the working tree of the submodule). Public: `x`.
---@param root string
---@param vcs string?
---@param path string
function M.submodule_deinit(root, vcs, path)
    guard(("Deinit submodule %s? (removes its working tree)"):format(path), function()
        M.execute(root, { "submodule", "deinit", "-f", "--", path }, { op = "submodule", vcs = vcs })
    end)
end

--- The submodule transient (Magit `magit-submodule`) — add / register / populate / update / synchronize
--- / unpopulate. The panel row keys reuse the same public helpers, so one implementation drives both.
---@return LvimGitTransientDef
local function submodule_def()
    return {
        id = "submodule",
        title = "Submodule",
        groups = {
            {
                title = "Arguments",
                infix = {
                    { kind = "switch", key = "-i", flag = "--init", label = "Init missing", level = 1 },
                    { kind = "switch", key = "-r", flag = "--recursive", label = "Recursive", level = 1 },
                    { kind = "switch", key = "-R", flag = "--remote", label = "Track remote branch", level = 2 },
                },
            },
            {
                title = "Actions",
                actions = {
                    {
                        key = "a",
                        label = "Add",
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                M.submodule_add(root, vcs)
                            end
                        end,
                    },
                    {
                        key = "u",
                        label = "Update (all)",
                        run = function(args, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                M.submodule_update(root, vcs, args)
                            end
                        end,
                    },
                    {
                        key = "p",
                        label = "Populate (update --init)",
                        run = function(args, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                local a = vim.list_extend({ "--init" }, args)
                                M.submodule_update(root, vcs, a)
                            end
                        end,
                    },
                    {
                        key = "i",
                        label = "Register (init, all)",
                        level = 2,
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                M.submodule_init(root, vcs)
                            end
                        end,
                    },
                    {
                        key = "s",
                        label = "Synchronize (all)",
                        level = 2,
                        run = function(args, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                M.submodule_sync(root, vcs, args)
                            end
                        end,
                    },
                    {
                        key = "x",
                        label = "Unpopulate (deinit)",
                        level = 3,
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                pick_submodule(root, "Deinit which submodule?", function(path)
                                    M.submodule_deinit(root, vcs, path)
                                end)
                            end
                        end,
                    },
                },
            },
        },
    }
end

-- ── worktree ───────────────────────────────────────────────────────────────

--- Add a worktree (`git worktree add [-b <branch>] <path> [<commit-ish>]`). Prompts for the path and an
--- optional new branch. Public: the worktree panel `a`.
---@param root string
---@param vcs string?
---@param args? string[]  the assembled infix argv (--detach / --force / --lock)
function M.worktree_add(root, vcs, args)
    if vcs == "jj" then
        -- jj: worktree ⇒ `jj workspace add <path>` (a new working copy sharing the repo).
        input("New workspace path", nil, function(path)
            M.execute(root, { "workspace", "add", path }, { op = "workspace", vcs = "jj" })
        end)
        return
    end
    input("New worktree path", nil, function(path)
        ui.input({
            title = "New branch name (empty = checkout HEAD / detach)",
            callback = function(ok, branch)
                local a = { "worktree", "add" }
                vim.list_extend(a, args or {})
                branch = branch and vim.trim(branch) or ""
                if not ok then
                    return
                end
                if branch ~= "" then
                    a[#a + 1] = "-b"
                    a[#a + 1] = branch
                end
                a[#a + 1] = path
                M.execute(root, a, { op = "worktree", vcs = vcs })
            end,
        })
    end)
end

--- Move a worktree to a new path (`git worktree move <src> <dst>`). Public: the worktree panel `m`.
---@param root string
---@param vcs string?
---@param path string  the source worktree path
function M.worktree_move(root, vcs, path)
    input("Move to path", path, function(dst)
        M.execute(root, { "worktree", "move", path, dst }, { op = "worktree", vcs = vcs })
    end)
end

--- Remove a worktree (guarded; `-f` when it has changes). Public: the worktree panel `x`.
---@param root string
---@param vcs string?
---@param path string
function M.worktree_remove(root, vcs, path)
    if vcs == "jj" then
        -- jj: `jj workspace forget <name>` (stop tracking a workspace; `path` carries the workspace name).
        guard(("Forget workspace %s?"):format(path), function()
            M.execute(root, { "workspace", "forget", path }, { op = "workspace", vcs = "jj" })
        end)
        return
    end
    guard(("Remove worktree %s?"):format(path), function()
        M.execute(root, { "worktree", "remove", "-f", path }, { op = "worktree", vcs = vcs })
    end)
end

--- Lock a worktree so it is not pruned. Public: the worktree panel `l`.
---@param root string
---@param vcs string?
---@param path string
function M.worktree_lock(root, vcs, path)
    M.execute(root, { "worktree", "lock", path }, { op = "worktree", vcs = vcs })
end

--- Unlock a worktree. Public: the worktree panel `L`.
---@param root string
---@param vcs string?
---@param path string
function M.worktree_unlock(root, vcs, path)
    M.execute(root, { "worktree", "unlock", path }, { op = "worktree", vcs = vcs })
end

--- Prune stale worktree administrative entries. Public: the worktree panel `p`.
---@param root string
---@param vcs string?
function M.worktree_prune(root, vcs)
    M.execute(root, { "worktree", "prune" }, { op = "worktree", vcs = vcs })
end

--- Switch the current tab's working directory into a worktree and open its status. Public: `<CR>`/`o`.
---@param path string
function M.worktree_open(path)
    if vim.fn.isdirectory(path) ~= 1 then
        notify("worktree path is gone: " .. path, vim.log.levels.WARN)
        return
    end
    vim.cmd("tcd " .. vim.fn.fnameescape(path))
    notify("switched to worktree " .. vim.fn.fnamemodify(path, ":~"))
    local ok = pcall(function()
        require("lvim-git").status()
    end)
    if not ok then
        notify("status view is not available", vim.log.levels.WARN)
    end
end

--- The worktree transient (Magit `magit-worktree`) — add / move / remove / lock / unlock / prune. On the
--- jj lens the same verbs map to `jj workspace` (a later phase); today it is git-only via `caps.worktree`.
---@return LvimGitTransientDef
local function worktree_def()
    return {
        id = "worktree",
        title = "Worktree",
        groups = {
            {
                title = "Arguments",
                infix = {
                    { kind = "switch", key = "-d", flag = "--detach", label = "Detach HEAD", level = 1 },
                    { kind = "switch", key = "-f", flag = "--force", label = "Force", level = 2 },
                    { kind = "switch", key = "-l", flag = "--lock", label = "Lock new worktree", level = 3 },
                },
            },
            {
                title = "Actions",
                actions = {
                    {
                        key = "a",
                        label = "Add",
                        run = function(args, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                M.worktree_add(root, vcs, args)
                            end
                        end,
                    },
                    {
                        key = "m",
                        label = "Move",
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                pick_worktree(root, "Move which worktree?", function(wt)
                                    M.worktree_move(root, vcs, wt.path)
                                end)
                            end
                        end,
                    },
                    {
                        key = "x",
                        label = "Remove",
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                pick_worktree(root, "Remove which worktree?", function(wt)
                                    M.worktree_remove(root, vcs, wt.path)
                                end)
                            end
                        end,
                    },
                    {
                        key = "p",
                        label = "Prune stale entries",
                        level = 2,
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                M.worktree_prune(root, vcs)
                            end
                        end,
                    },
                },
            },
        },
    }
end

-- ── subtree ────────────────────────────────────────────────────────────────

--- Resolve the `--prefix` for a subtree op — the `=p` option value, else prompt. `cb(prefix)`.
---@param ctx LvimGitTransientCtx
---@param cb fun(prefix: string)
local function subtree_prefix(ctx, cb)
    local row = ctx.rows and ctx.rows["=p"]
    local pfx = row and row.value and vim.trim(tostring(row.value)) or ""
    if pfx ~= "" then
        cb(pfx)
        return
    end
    input("Subtree prefix (directory)", nil, cb)
end

--- Run a subtree transfer op (add/pull/push) after resolving prefix + repository + ref. `--squash` from
--- the transient is honoured. These shell out to git's `subtree` contrib command (progress-streamed).
---@param root string
---@param vcs string?
---@param sub "add"|"pull"|"push"
---@param prefix string
---@param args string[]  the assembled infix argv (--squash)
local function subtree_transfer(root, vcs, sub, prefix, args)
    input("Repository (remote name or URL)", nil, function(repo)
        input("Ref (branch / tag)", sub == "push" and "HEAD" or nil, function(ref)
            local a = { "subtree", sub, "--prefix=" .. prefix }
            vim.list_extend(a, args or {})
            a[#a + 1] = repo
            a[#a + 1] = ref
            M.execute(root, a, { op = "subtree", vcs = vcs, progress = true })
        end)
    end)
end

--- The subtree transient (Magit `magit-subtree`) — add / pull / push / split, all `--prefix`-scoped.
--- git subtree is a contrib command; a repo without it fails cleanly with git's own message.
---@return LvimGitTransientDef
local function subtree_def()
    return {
        id = "subtree",
        title = "Subtree",
        groups = {
            {
                title = "Arguments",
                infix = {
                    { kind = "switch", key = "-s", flag = "--squash", label = "Squash history", level = 1 },
                    { kind = "option", key = "=p", arg = "--prefix", label = "Prefix (dir)", level = 1 },
                },
            },
            {
                title = "Actions",
                actions = {
                    {
                        key = "a",
                        label = "Add",
                        run = function(args, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                subtree_prefix(ctx, function(p)
                                    subtree_transfer(root, vcs, "add", p, args)
                                end)
                            end
                        end,
                    },
                    {
                        key = "f",
                        label = "Pull",
                        run = function(args, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                subtree_prefix(ctx, function(p)
                                    subtree_transfer(root, vcs, "pull", p, args)
                                end)
                            end
                        end,
                    },
                    {
                        key = "p",
                        label = "Push",
                        run = function(args, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                subtree_prefix(ctx, function(p)
                                    subtree_transfer(root, vcs, "push", p, args)
                                end)
                            end
                        end,
                    },
                    {
                        key = "s",
                        label = "Split",
                        level = 2,
                        run = function(args, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                subtree_prefix(ctx, function(p)
                                    ui.input({
                                        title = "Split into branch (empty = none)",
                                        callback = function(ok, branch)
                                            if not ok then
                                                return
                                            end
                                            local a = { "subtree", "split", "--prefix=" .. p }
                                            vim.list_extend(a, args or {})
                                            branch = branch and vim.trim(branch) or ""
                                            if branch ~= "" then
                                                a[#a + 1] = "-b"
                                                a[#a + 1] = branch
                                            end
                                            M.execute(root, a, { op = "subtree", vcs = vcs, progress = true })
                                        end,
                                    })
                                end)
                            end
                        end,
                    },
                },
            },
        },
    }
end

-- ── patch (format-patch / am / apply) ────────────────────────────────────────

--- Create patch files from a commit range (`git format-patch <range> -o <dir>`). Public.
---@param root string
---@param vcs string?
---@param args string[]  the assembled infix argv (--numbered / --signoff)
function M.patch_create(root, vcs, args)
    input("Range / rev to format (e.g. -1, main..HEAD)", "-1", function(range)
        ui.input({
            title = "Output directory",
            default = root,
            callback = function(ok, dir)
                if not ok then
                    return
                end
                dir = dir and vim.trim(dir) or root
                local a = { "format-patch" }
                vim.list_extend(a, args or {})
                vim.list_extend(a, vim.split(range, "%s+", { trimempty = true }))
                a[#a + 1] = "-o"
                a[#a + 1] = dir ~= "" and dir or root
                M.execute(root, a, { op = "format-patch", vcs = vcs })
            end,
        })
    end)
end

--- Apply a mailbox patch with `git am` (creates commits; may stop on conflict → the am sequence). Public.
---@param root string
---@param vcs string?
---@param args string[]  the assembled infix argv (--3way / --signoff / --keep)
function M.patch_am(root, vcs, args)
    pick_patch_file(root, "Apply which mbox/patch (am)?", function(file)
        local a = { "am" }
        vim.list_extend(a, args or {})
        a[#a + 1] = file
        M.execute(root, a, { op = "am", vcs = vcs })
    end)
end

--- Apply a diff to the working tree with `git apply`. Public.
---@param root string
---@param vcs string?
---@param cached boolean  also stage (`--index`)
function M.patch_apply(root, vcs, cached)
    pick_patch_file(root, "Apply which diff?", function(file)
        local a = { "apply", "--whitespace=nowarn" }
        if cached then
            a[#a + 1] = "--index"
        end
        a[#a + 1] = file
        M.execute(root, a, { op = "apply", vcs = vcs })
    end)
end

--- The patch transient (Magit `magit-patch`/`magit-am`) — create with format-patch, apply an mbox with
--- `am` (+ continue/skip/abort of a stopped am), apply a plain diff.
---@return LvimGitTransientDef
local function patch_def()
    return {
        id = "patch",
        title = "Patch",
        groups = {
            {
                title = "Arguments",
                infix = {
                    { kind = "switch", key = "-n", flag = "--numbered", label = "Numbered subjects", level = 1 },
                    { kind = "switch", key = "-s", flag = "--signoff", label = "Add Signed-off-by", level = 1 },
                    { kind = "switch", key = "-3", flag = "--3way", label = "am: fall back to 3-way", level = 2 },
                    { kind = "switch", key = "-k", flag = "--keep", label = "am: keep subject", level = 3 },
                },
            },
            {
                title = "Create",
                actions = {
                    {
                        key = "c",
                        label = "Create (format-patch a range)",
                        run = function(args, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                -- only the format-patch switches (--numbered/--signoff) apply here
                                local fa = {}
                                for _, f in ipairs(args) do
                                    if f == "--numbered" or f == "--signoff" then
                                        fa[#fa + 1] = f
                                    end
                                end
                                M.patch_create(root, vcs, fa)
                            end
                        end,
                    },
                },
            },
            {
                title = "Apply",
                actions = {
                    {
                        key = "a",
                        label = "Apply mailbox (am)",
                        run = function(args, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                local aa = {}
                                for _, f in ipairs(args) do
                                    if f == "--3way" or f == "--signoff" or f == "--keep" then
                                        aa[#aa + 1] = f
                                    end
                                end
                                M.patch_am(root, vcs, aa)
                            end
                        end,
                    },
                    {
                        key = "w",
                        label = "Apply diff to worktree",
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                M.patch_apply(root, vcs, false)
                            end
                        end,
                    },
                    {
                        key = "W",
                        label = "Apply diff + stage (--index)",
                        level = 2,
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                M.patch_apply(root, vcs, true)
                            end
                        end,
                    },
                },
            },
            {
                title = "am sequence",
                actions = {
                    {
                        key = "r",
                        label = "Continue (am --continue)",
                        level = 2,
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                M.execute(root, { "am", "--continue" }, { op = "am", vcs = vcs, editor = true })
                            end
                        end,
                    },
                    {
                        key = "s",
                        label = "Skip (am --skip)",
                        level = 2,
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                M.execute(root, { "am", "--skip" }, { op = "am", vcs = vcs })
                            end
                        end,
                    },
                    {
                        key = "A",
                        label = "Abort (am --abort)",
                        level = 2,
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                M.execute(root, { "am", "--abort" }, { op = "am", vcs = vcs, head_changed = true })
                            end
                        end,
                    },
                },
            },
        },
    }
end

-- ── sparse checkout ──────────────────────────────────────────────────────────

--- Show the current sparse-checkout pattern list in a read-only select (the `l` action). Public.
---@param root string
function M.sparse_show(root)
    backend.sparse_state(root, function(st)
        if not st or not st.enabled then
            notify("sparse checkout is disabled")
            return
        end
        local items = {}
        for _, p in ipairs(st.patterns) do
            items[#items + 1] = { label = p }
        end
        if #items == 0 then
            notify("sparse checkout is enabled with no patterns")
            return
        end
        ui.select({
            title = "Sparse patterns (" .. (st.cone and "cone" or "pattern") .. " mode)",
            items = items,
            callback = function() end,
        })
    end)
end

--- The sparse-checkout transient (Magit `magit-sparse-checkout`) — init / set / add / reapply / disable /
--- list. `--cone` seeds init/set. Patterns are typed space-separated (cone mode = directories).
---@return LvimGitTransientDef
local function sparse_def()
    return {
        id = "sparse",
        title = "Sparse checkout",
        groups = {
            {
                title = "Arguments",
                infix = {
                    { kind = "switch", key = "-c", flag = "--cone", label = "Cone mode", level = 1, default = true },
                },
            },
            {
                title = "Actions",
                actions = {
                    {
                        key = "i",
                        label = "Init",
                        run = function(args, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                M.execute(
                                    root,
                                    vim.list_extend({ "sparse-checkout", "init" }, args),
                                    { op = "sparse-checkout", vcs = vcs }
                                )
                            end
                        end,
                    },
                    {
                        key = "s",
                        label = "Set (replace patterns)",
                        run = function(args, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                input("Patterns / directories (space-separated)", nil, function(pats)
                                    local a = vim.list_extend({ "sparse-checkout", "set" }, args)
                                    vim.list_extend(a, vim.split(pats, "%s+", { trimempty = true }))
                                    M.execute(root, a, { op = "sparse-checkout", vcs = vcs })
                                end)
                            end
                        end,
                    },
                    {
                        key = "a",
                        label = "Add patterns",
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                input("Patterns / directories to add", nil, function(pats)
                                    local a = { "sparse-checkout", "add" }
                                    vim.list_extend(a, vim.split(pats, "%s+", { trimempty = true }))
                                    M.execute(root, a, { op = "sparse-checkout", vcs = vcs })
                                end)
                            end
                        end,
                    },
                    {
                        key = "r",
                        label = "Reapply",
                        level = 2,
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                M.execute(root, { "sparse-checkout", "reapply" }, { op = "sparse-checkout", vcs = vcs })
                            end
                        end,
                    },
                    {
                        key = "l",
                        label = "List patterns",
                        run = function(_, ctx)
                            local root = resolve(ctx)
                            if root then
                                M.sparse_show(root)
                            end
                        end,
                    },
                    {
                        key = "d",
                        label = "Disable",
                        level = 2,
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                guard("Disable sparse checkout? (restores the full working tree)", function()
                                    M.execute(
                                        root,
                                        { "sparse-checkout", "disable" },
                                        { op = "sparse-checkout", vcs = vcs }
                                    )
                                end)
                            end
                        end,
                    },
                },
            },
        },
    }
end

-- ── bisect ───────────────────────────────────────────────────────────────────

--- Start a bisect session (`git bisect start <bad> <good>`). Prompts for the bad rev (default HEAD) and
--- the good rev, then checks out the midpoint. Public.
---@param root string
---@param vcs string?
function M.bisect_start(root, vcs)
    input("Bad commit", "HEAD", function(bad)
        input("Good commit", nil, function(good)
            M.execute(root, { "bisect", "start", bad, good }, { op = "bisect", vcs = vcs, head_changed = true })
        end)
    end)
end

--- Mark the current bisect commit good / bad / skip (`git bisect <mark>`). Public: the bisect status
--- section controls + the transient.
---@param root string
---@param vcs string?
---@param mark "good"|"bad"|"skip"
function M.bisect_mark(root, vcs, mark)
    M.execute(root, { "bisect", mark }, { op = "bisect", vcs = vcs, head_changed = true })
end

--- End the bisect session and return to the original HEAD (`git bisect reset`). Public.
---@param root string
---@param vcs string?
function M.bisect_reset(root, vcs)
    M.execute(root, { "bisect", "reset" }, { op = "bisect", vcs = vcs, head_changed = true })
end

--- Automate a bisect with a test command (`git bisect run <cmd…>`; exit 0 = good, non-zero = bad). Public.
---@param root string
---@param vcs string?
function M.bisect_run(root, vcs)
    input("Test command (exit 0 = good, non-zero = bad)", nil, function(cmd)
        local a = { "bisect", "run" }
        vim.list_extend(a, vim.split(cmd, "%s+", { trimempty = true }))
        M.execute(root, a, { op = "bisect", vcs = vcs, head_changed = true, progress = true })
    end)
end

--- The bisect transient (Magit `magit-bisect`) — start / good / bad / skip / run / reset. git-only
--- (`caps.bisect`). The status bisect section shares the good/bad/skip/reset helpers above.
---@return LvimGitTransientDef
local function bisect_def()
    return {
        id = "bisect",
        title = "Bisect",
        groups = {
            {
                title = "Start",
                actions = {
                    {
                        key = "B",
                        label = "Start (good..bad)",
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                M.bisect_start(root, vcs)
                            end
                        end,
                    },
                    {
                        key = "r",
                        label = "Run automated (test command)",
                        level = 2,
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                M.bisect_run(root, vcs)
                            end
                        end,
                    },
                },
            },
            {
                title = "Mark current",
                actions = {
                    {
                        key = "g",
                        label = "Good",
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                M.bisect_mark(root, vcs, "good")
                            end
                        end,
                    },
                    {
                        key = "b",
                        label = "Bad",
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                M.bisect_mark(root, vcs, "bad")
                            end
                        end,
                    },
                    {
                        key = "s",
                        label = "Skip",
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                M.bisect_mark(root, vcs, "skip")
                            end
                        end,
                    },
                    {
                        key = "R",
                        label = "Reset (end bisect)",
                        run = function(_, ctx)
                            local root, vcs = resolve(ctx)
                            if root then
                                M.bisect_reset(root, vcs)
                            end
                        end,
                    },
                },
            },
        },
    }
end

-- ── jj (Jujutsu) verb layer ────────────────────────────────────────────────────
--
-- jj has NO staging index and NO continue/abort sequencer — rewrites are direct commands. These helpers
-- assemble jj subcommands and run them through the SAME `M.execute` seam (with `vcs = "jj"`), so events /
-- progress / the with-editor bridge all work uniformly. They are reached from the jj transient (below),
-- the oplog panel, and the caps-aware refs/worktree panels — never string-checking `vcs` in the UI.

--- `jj describe` — set/amend the working-copy change's description in place (jj's amend-in-place). A
--- non-empty message is prompted through the canonical lvim-ui input.
---@param root string
---@param vcs? string
function M.jj_describe(root, vcs)
    input("Describe @ (change message)", nil, function(msg)
        M.execute(root, { "describe", "-m", msg }, { op = "describe", vcs = vcs or "jj", head_changed = true })
    end)
end

--- `jj new` — start a new empty change on top of `@` (jj's "commit" = finalize `@`, move on).
---@param root string
---@param vcs? string
function M.jj_new(root, vcs)
    M.execute(root, { "new" }, { op = "new", vcs = vcs or "jj", head_changed = true })
end

--- `jj commit` — describe the working-copy change AND start a new one on top (git-`commit` analogue).
---@param root string
---@param vcs? string
function M.jj_commit(root, vcs)
    input("Commit message (describe @ + new)", nil, function(msg)
        M.execute(root, { "commit", "-m", msg }, { op = "commit", vcs = vcs or "jj", head_changed = true })
    end)
end

--- `jj squash` — move the working-copy change into its parent `@-` (jj's "stage-all"/fold analogue).
---@param root string
---@param vcs? string
function M.jj_squash(root, vcs)
    M.execute(root, { "squash" }, { op = "squash", vcs = vcs or "jj", head_changed = true })
end

--- `jj split` is INTERACTIVE (a diff editor); it is deferred (hunk-level split is a v2 phase, see the
--- plan's open question 6). Notify cleanly rather than spawn a diff editor we cannot yet drive.
---@param _root string
function M.jj_split(_root)
    notify("jj split is interactive (diff-editor) — not yet supported; use squash / new", vim.log.levels.WARN)
end

--- `jj abandon <rev>` — drop a change; descendants auto-rebase onto its parent. Picks the change (guarded).
---@param root string
---@param vcs? string
function M.jj_abandon(root, vcs)
    pick_commit(root, "Abandon change", function(id)
        guard("Abandon change " .. id:sub(1, 8) .. "?", function()
            M.execute(root, { "abandon", id }, { op = "abandon", vcs = vcs or "jj", head_changed = true })
        end)
    end)
end

--- `jj edit <rev>` — move `@` onto an existing change (jj's "checkout" of a commit for editing).
---@param root string
---@param vcs? string
function M.jj_edit(root, vcs)
    pick_commit(root, "Edit change (move @ onto)", function(id)
        M.execute(root, { "edit", id }, { op = "edit", vcs = vcs or "jj", head_changed = true })
    end)
end

--- `jj rebase -r|-s|-d` — rewrite a change/branch onto a destination. Prompts source + destination
--- revsets (jj rebase is NON-interactive — descendants auto-rebase, no todo/continue/abort dance).
---@param root string
---@param vcs? string
---@param mode "r"|"s"  `-r` (this change only) | `-s` (this change + descendants)
function M.jj_rebase(root, vcs, mode)
    input("Source revset (" .. (mode == "s" and "-s" or "-r") .. ")", "@", function(src)
        input("Destination revset (-d)", "@-", function(dest)
            M.execute(
                root,
                { "rebase", "-" .. mode, src, "-d", dest },
                { op = "rebase", vcs = vcs or "jj", head_changed = true }
            )
        end)
    end)
end

--- `jj bookmark create <name> -r <rev>` — create a bookmark at a rev (default `@`).
---@param root string
---@param vcs? string
---@param rev? string
function M.jj_bookmark_create(root, vcs, rev)
    input("New bookmark name", nil, function(name)
        M.execute(
            root,
            { "bookmark", "create", name, "-r", rev or "@" },
            { op = "bookmark", vcs = vcs or "jj", head_changed = true }
        )
    end)
end

--- `jj bookmark set <name> -r <rev>` — move an existing bookmark to a rev (default `@`), `--allow-backwards`.
---@param root string
---@param vcs? string
---@param name? string  the bookmark (picked when nil)
---@param rev? string
function M.jj_bookmark_set(root, vcs, name, rev)
    local function do_set(bm)
        M.execute(
            root,
            { "bookmark", "set", bm, "-r", rev or "@", "--allow-backwards" },
            { op = "bookmark", vcs = vcs or "jj", head_changed = true }
        )
    end
    if name then
        do_set(name)
    else
        pick_ref(root, { "bookmark" }, "Move bookmark to " .. (rev or "@"), function(n)
            do_set(n)
        end)
    end
end

--- `jj bookmark delete <name>` — delete a bookmark (guarded, picked when nil).
---@param root string
---@param vcs? string
---@param name? string
function M.jj_bookmark_delete(root, vcs, name)
    local function do_del(bm)
        guard("Delete bookmark " .. bm .. "?", function()
            M.execute(root, { "bookmark", "delete", bm }, { op = "bookmark", vcs = vcs or "jj" })
        end)
    end
    if name then
        do_del(name)
    else
        pick_ref(root, { "bookmark" }, "Delete bookmark", function(n)
            do_del(n)
        end)
    end
end

--- `jj git push` — push bookmarks to a remote (the jj analogue of `git push`), streamed progress.
---@param root string
---@param vcs? string
function M.jj_git_push(root, vcs)
    M.execute(root, { "git", "push" }, { op = "git push", vcs = vcs or "jj", progress = true })
end

--- `jj git fetch` — fetch from a remote (the jj analogue of `git fetch`), streamed progress.
---@param root string
---@param vcs? string
function M.jj_git_fetch(root, vcs)
    M.execute(root, { "git", "fetch" }, { op = "git fetch", vcs = vcs or "jj", progress = true, head_changed = true })
end

-- ── operation log (jj) / reflog (git) ─────────────────────────────────────────

--- `jj op revert` (the current, non-deprecated form of `jj op undo`) — undo the LAST operation. jj's
--- killer feature: any operation can be reverted (and the revert itself reverted). Guarded when
--- `confirm_destructive`. `cb()` on success.
---@param root string
---@param vcs? string
---@param cb? fun()
function M.op_undo(root, vcs, cb)
    guard("Undo the last jj operation?", function()
        M.execute(root, { "op", "revert" }, { op = "op undo", vcs = vcs or "jj", head_changed = true }, function(ok)
            if ok and cb then
                cb()
            end
        end)
    end)
end

--- `jj op restore <op>` — restore the whole repo to the state after operation `op` (jump anywhere in
--- history). Guarded when `confirm_destructive`. `cb()` on success.
---@param root string
---@param vcs? string
---@param op_id string
---@param cb? fun()
function M.op_restore(root, vcs, op_id, cb)
    guard("Restore repo to operation " .. op_id .. "?", function()
        M.execute(
            root,
            { "op", "restore", op_id },
            { op = "op restore", vcs = vcs or "jj", head_changed = true },
            function(ok)
                if ok and cb then
                    cb()
                end
            end
        )
    end)
end

--- Visit a git reflog entry — checkout the commit it points at (git's reflog is read-mostly; the oplog
--- panel offers jump/checkout only, never an undo). Guarded (detaches HEAD).
---@param root string
---@param id string  the reflog entry's commit id
function M.reflog_visit(root, id)
    guard("Checkout reflog entry " .. id .. " (detaches HEAD)?", function()
        M.execute(root, { "checkout", id }, { op = "checkout", head_changed = true })
    end)
end

-- ── the jj transient (Magit-style jj verb menu) ───────────────────────────────

--- The jj verb menu — the jj-lens analogue of the git verb transients, reached via `:LvimGit jj`, the
--- status footer (on a jj repo), and the dispatch popup. Action rows only (jj rewrites take no git-style
--- infixes); each runs a helper above. Registered unconditionally but only meaningful on a jj repo.
---@return LvimGitTransientDef
local function jj_def()
    ---@param fn fun(root: string, vcs?: string)
    local function act(fn)
        return function(_, ctx)
            local root, vcs = resolve(ctx)
            if root then
                fn(root, vcs)
            end
        end
    end
    return {
        id = "jj",
        title = "Jujutsu",
        groups = {
            {
                title = "Working copy",
                actions = {
                    { key = "c", label = "Commit (describe @ + new)", run = act(M.jj_commit) },
                    { key = "d", label = "Describe @", run = act(M.jj_describe) },
                    { key = "n", label = "New change on @", run = act(M.jj_new) },
                    { key = "e", label = "Edit (move @ onto)", run = act(M.jj_edit) },
                },
            },
            {
                title = "Rewrite",
                actions = {
                    { key = "s", label = "Squash into @-", run = act(M.jj_squash) },
                    { key = "S", label = "Split (interactive)", level = 5, run = act(M.jj_split) },
                    { key = "a", label = "Abandon change", run = act(M.jj_abandon) },
                    {
                        key = "r",
                        label = "Rebase -r (this change)",
                        run = act(function(root, vcs)
                            M.jj_rebase(root, vcs, "r")
                        end),
                    },
                    {
                        key = "R",
                        label = "Rebase -s (change + descendants)",
                        run = act(function(root, vcs)
                            M.jj_rebase(root, vcs, "s")
                        end),
                    },
                },
            },
            {
                title = "Bookmark",
                actions = {
                    { key = "b", label = "Create bookmark", run = act(M.jj_bookmark_create) },
                    {
                        key = "m",
                        label = "Move bookmark to @",
                        run = act(function(root, vcs)
                            M.jj_bookmark_set(root, vcs, nil, "@")
                        end),
                    },
                    {
                        key = "x",
                        label = "Delete bookmark",
                        run = act(function(root, vcs)
                            M.jj_bookmark_delete(root, vcs, nil)
                        end),
                    },
                },
            },
            {
                title = "Transfer / undo",
                actions = {
                    { key = "P", label = "git push", run = act(M.jj_git_push) },
                    { key = "F", label = "git fetch", run = act(M.jj_git_fetch) },
                    {
                        key = "u",
                        label = "Op undo (revert last operation)",
                        run = act(function(root, vcs)
                            M.op_undo(root, vcs)
                        end),
                    },
                    {
                        key = "o",
                        label = "Operation log",
                        run = function()
                            require("lvim-git.ui.oplog").open()
                        end,
                    },
                },
            },
        },
    }
end

-- ── registration ─────────────────────────────────────────────────────────────

---@type boolean  guards the one-time verb-def registration
local registered = false

--- Register every core verb transient with the engine (idempotent). Called from `setup()` so the status
--- footer verbs + the dispatch popup resolve. Each def is DATA; the engine owns the popup + arg math.
function M.register()
    if registered then
        return
    end
    registered = true
    for _, def in ipairs({
        commit_def(),
        push_def(),
        pull_def(),
        fetch_def(),
        branch_def(),
        remote_def(),
        merge_def(),
        reset_def(),
        tag_def(),
        revert_def(),
        cherry_pick_def(),
        rebase_def(),
        stash_def(),
        commit_actions_def(),
        submodule_def(),
        worktree_def(),
        subtree_def(),
        patch_def(),
        sparse_def(),
        bisect_def(),
        jj_def(),
    }) do
        transient.define(def)
    end
end

return M
