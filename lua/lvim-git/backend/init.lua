-- lvim-git.backend: THE one seam the UI sees — the VCS abstraction over git AND jj.
--
-- The UI never touches a CLI directly: it asks the backend, which detects the repo per buffer/cwd
-- (walk up: a `.jj` dir → jj, else `.git` → git; a COLOCATED repo has both → jj wins under
-- `vcs = "auto"`, overridable), caches one Repo handle per root, and dispatches every operation to
-- the matching implementation (`backend/git.lua` / `backend/jj.lua`) — both of which implement the
-- SAME function table. This file owns:
--   * detection + the per-root handle cache + the capabilities table,
--   * the common model types (Repo / StatusEntry / Hunk / Commit / BlameLine / Ref),
--   * the async runner (`vim.system`, cwd = root, callback marshalled to the main loop),
--   * the parsers both implementations share (unified diff → Hunk[], porcelain helpers).
--
-- Capabilities, NOT string checks: the UI gates features on `repo.caps.<x>`, never on
-- `vcs == "git"`, so a capability reads the same everywhere and a third backend stays possible.
--
-- PUBLIC (stability contract): repo / head / ahead_behind / branch / is_repo / file_status /
-- status (cached, render-safe) + refs / log (async, take a callback). Everything else is internal.
--
---@module "lvim-git.backend"

local uv = vim.uv or vim.loop
local config = require("lvim-git.config")
local state = require("lvim-git.state")

local M = {}

-- ── model types ───────────────────────────────────────────────────────────

---@alias LvimGitVcs "git"|"jj"
---@alias LvimGitStatusKind "staged"|"unstaged"|"untracked"|"conflicted"
---@alias LvimGitRepoState "clean"|"merge"|"rebase"|"cherry-pick"|"revert"|"bisect"|"am"

---@class LvimGitCaps
---@field index       boolean  a staging area (stage/unstage file/hunk/line)
---@field stash       boolean
---@field reflog      boolean
---@field oplog       boolean  jj operation log (undo/restore)
---@field bookmarks   boolean  jj bookmarks (vs git branches)
---@field undo_op     boolean  jj undo / op restore
---@field absorb      boolean  jj absorb (auto-fixup into ancestors)
---@field rebase_todo boolean  an interactive-rebase todo file (git only)
---@field sequencer   boolean  cherry-pick/revert/rebase sequences with continue/abort
---@field worktree    boolean  git worktree / jj workspace
---@field submodule   boolean
---@field bisect      boolean
---@field notes       boolean
---@field subtree     boolean
---@field patch       boolean  format-patch / am
---@field wip         boolean  work-in-progress refs mode
---@field sparse      boolean  sparse checkout / jj sparse

---@class Repo
---@field root      string             absolute repo root
---@field vcs       LvimGitVcs
---@field colocated boolean            a `.jj` + `.git` colocated repo
---@field caps      LvimGitCaps
---@field head?     string             short HEAD commit id / jj change-id
---@field branch?   string             current branch name (git) / active bookmark (jj)
---@field bookmark? string             jj bookmark at `@` (jj lens)
---@field upstream? string             tracking ref (git) / remote bookmark (jj)
---@field ahead     integer            commits ahead of upstream
---@field behind    integer            commits behind upstream
---@field dirty     boolean            working tree has changes
---@field state     LvimGitRepoState   in-progress operation state
---@field detached? boolean            git detached HEAD
---@field _git_dir? string             cached absolute GIT_DIR (internal)
---@field _status?  StatusModel        cached last status model (internal; feeds file_status)

---@class StatusEntry
---@field path       string             repo-relative path
---@field orig_path? string             the source path for a rename/copy
---@field kind       LvimGitStatusKind
---@field staged?    boolean            has staged (index) changes
---@field unstaged?  boolean            has unstaged (worktree) changes
---@field code       string             the raw porcelain XY / status code
---@field renamed?   boolean

---@class StatusModel
---@field root       string
---@field vcs        LvimGitVcs
---@field staged     StatusEntry[]
---@field unstaged   StatusEntry[]
---@field untracked  StatusEntry[]
---@field conflicted StatusEntry[]

---@class DiffHunk
---@field old_start integer
---@field old_count integer
---@field new_start integer
---@field new_count integer
---@field header    string
---@field lines     { kind: "context"|"add"|"del", text: string }[]

---@class Commit
---@field id        string    commit id (git sha / jj commit id)
---@field change_id? string   jj change id (nil for git)
---@field abbrev    string    short id
---@field parents   string[]
---@field author    string
---@field author_mail? string
---@field date      integer   author time (unix)
---@field subject   string
---@field body?     string
---@field refs      string[]  decoration (branches/tags/bookmarks) on this commit

---@class BlameLine
---@field lnum        integer
---@field commit      string
---@field abbrev      string
---@field author      string
---@field author_mail? string
---@field author_time integer
---@field summary     string
---@field filename?   string   the path this line had AT `commit` (rename-aware)
---@field previous?   string   parent commit that last touched this line (for reblame-at-parent)
---@field previous_filename? string  the path in `previous` (follows a rename on the triage step)
---@field is_committed boolean

---@class Ref
---@field name      string
---@field kind      "local"|"remote"|"tag"|"bookmark"
---@field target    string   commit id it points at
---@field tracking? string   upstream it tracks
---@field ahead?    integer
---@field behind?   integer
---@field conflicted? boolean  jj conflicted bookmark

-- ── capabilities ──────────────────────────────────────────────────────────

---@type table<LvimGitVcs, LvimGitCaps>
local CAPS = {
    git = {
        index = true,
        stash = true,
        reflog = true,
        oplog = false,
        bookmarks = false,
        undo_op = false,
        absorb = false,
        rebase_todo = true,
        sequencer = true,
        worktree = true,
        submodule = true,
        bisect = true,
        notes = true,
        subtree = true,
        patch = true,
        wip = true,
        sparse = true,
    },
    jj = {
        index = false,
        stash = false,
        reflog = false,
        oplog = true,
        bookmarks = true,
        undo_op = true,
        absorb = true,
        rebase_todo = false,
        sequencer = false,
        worktree = true,
        submodule = false,
        bisect = false,
        notes = false,
        subtree = false,
        patch = false,
        wip = false,
        sparse = true,
    },
}

--- The capabilities table for a VCS.
---@param vcs LvimGitVcs
---@return LvimGitCaps
function M.caps(vcs)
    return CAPS[vcs]
end

-- ── the async runner ──────────────────────────────────────────────────────

--- Run a command under a repo root via `vim.system` (off the main thread) and marshal the result
--- back onto the main loop. The command NEVER blocks the UI. Streaming reads pass a `stdout`/`stderr`
--- reader in `opts` (consumed in the libuv callback — keep those handlers to pure string work); the
--- completion `cb(res)` always runs via `vim.schedule`. Returns the `vim.SystemObj` so a long op can
--- be cancelled.
---
---@param root string                     the cwd for the command
---@param argv string[]                    full argv (executable first)
---@param opts? { stdin?: string|string[], stdout?: function, stderr?: function, timeout?: integer, env?: table }
---@param cb? fun(res: vim.SystemCompleted)  completion callback (main loop)
---@return vim.SystemObj?
function M.system(root, argv, opts, cb)
    opts = opts or {}
    local sopts = {
        cwd = root,
        text = true,
        stdin = opts.stdin,
        stdout = opts.stdout,
        stderr = opts.stderr,
        timeout = opts.timeout,
        env = opts.env,
    }
    local ok, obj = pcall(vim.system, argv, sopts, function(res)
        if cb then
            vim.schedule(function()
                cb(res)
            end)
        end
    end)
    if not ok then
        if cb then
            vim.schedule(function()
                cb({ code = -1, signal = 0, stdout = "", stderr = tostring(obj) })
            end)
        end
        return nil
    end
    return obj
end

--- Convenience: run a command that produces text, invoke `cb(stdout, res)` with stdout (or nil on a
--- non-zero exit). Trailing newline is preserved so `-z`/`\0`-delimited output parses correctly.
---@param root string
---@param argv string[]
---@param cb fun(out: string?, res: vim.SystemCompleted)
---@param opts? table
---@return vim.SystemObj?
function M.output(root, argv, cb, opts)
    return M.system(root, argv, opts, function(res)
        if res.code == 0 then
            cb(res.stdout or "", res)
        else
            cb(nil, res)
        end
    end)
end

-- ── repo detection ────────────────────────────────────────────────────────

--- Normalize a buffer number / path / nil into an absolute directory to start the walk from.
---@param root_or_buf? string|integer
---@return string dir
local function start_dir(root_or_buf)
    if type(root_or_buf) == "number" then
        local name = vim.api.nvim_buf_get_name(root_or_buf)
        if name ~= "" and not name:match("^%w+://") then
            return vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(name, ":p")))
        end
        return vim.fn.getcwd()
    elseif type(root_or_buf) == "string" and root_or_buf ~= "" then
        local p = vim.fs.normalize(vim.fn.fnamemodify(root_or_buf, ":p"))
        if vim.fn.isdirectory(p) == 1 then
            return p
        end
        return vim.fs.dirname(p)
    end
    return vim.fn.getcwd()
end

--- Detect the repo containing `dir`: walk up to the first ancestor holding a `.jj` and/or `.git`.
--- A colocated repo has BOTH; under `vcs = "auto"` jj wins. `config.vcs` ("git"|"jj") forces a lens
--- when present. Returns the root, the resolved vcs, and the colocated flag — or nil for no repo.
---@param dir string
---@return string? root, LvimGitVcs? vcs, boolean colocated
local function detect_dir(dir)
    local git_dir = vim.fs.find(".git", { path = dir, upward = true, limit = 1 })[1]
    local jj_dir = vim.fs.find(".jj", { path = dir, upward = true, type = "directory", limit = 1 })[1]
    local git_root = git_dir and vim.fs.dirname(git_dir) or nil
    local jj_root = jj_dir and vim.fs.dirname(jj_dir) or nil
    if not git_root and not jj_root then
        return nil, nil, false
    end
    local colocated = git_root ~= nil and jj_root ~= nil and git_root == jj_root
    local root = jj_root or git_root
    ---@cast root string
    local vcs ---@type LvimGitVcs
    if config.vcs == "git" then
        vcs = git_root and "git" or "jj"
        root = git_root or jj_root --[[@as string]]
    elseif config.vcs == "jj" then
        vcs = jj_root and "jj" or "git"
        root = jj_root or git_root --[[@as string]]
    else -- "auto": jj wins in a colocated repo, else the one present
        vcs = jj_root and "jj" or "git"
    end
    return root, vcs, colocated
end

--- Resolve (and cache) the repo root + vcs for a buffer/path/cwd. Cheap: caches per start dir.
---@param root_or_buf? string|integer
---@return string? root, LvimGitVcs? vcs, boolean colocated
function M.detect(root_or_buf)
    local dir = start_dir(root_or_buf)
    local cached = state.root_of[dir]
    if cached ~= nil then
        if cached == false then
            return nil, nil, false
        end
        local repo = state.repos[cached]
        return cached, repo and repo.vcs, repo and repo.colocated or false
    end
    local root, vcs, colocated = detect_dir(dir)
    if not root or not vcs then
        state.root_of[dir] = false
        return nil, nil, false
    end
    ---@cast vcs LvimGitVcs
    state.root_of[dir] = root
    if not state.repos[root] then
        ---@type Repo
        state.repos[root] = {
            root = root,
            vcs = vcs,
            colocated = colocated,
            caps = CAPS[vcs],
            ahead = 0,
            behind = 0,
            dirty = false,
            state = "clean",
        }
    end
    return root, vcs, colocated
end

--- The implementation module for a vcs (lazy-required; `git.lua`/`jj.lua` share one function table).
---@param vcs LvimGitVcs
---@return table
local function impl(vcs)
    return require("lvim-git.backend." .. vcs)
end

--- Resolve a buffer/path/nil to its cached Repo handle (with the impl attached), or nil.
---@param root_or_buf? string|integer
---@return Repo?, table? impl
function M.resolve(root_or_buf)
    local root, vcs = M.detect(root_or_buf)
    if not root or not vcs then
        return nil, nil
    end
    return state.repos[root], impl(vcs)
end

-- ── public reads (render-safe cached; refresh is async) ─────────────────────

--- True when the path/buffer is inside a repo.
---@param root_or_buf? string|integer
---@return boolean
function M.is_repo(root_or_buf)
    local root = M.detect(root_or_buf)
    return root ~= nil
end

--- The cached Repo model (render-safe). nil when not in a repo. Refreshed by `M.refresh` on events.
---@param root_or_buf? string|integer
---@return Repo?
function M.repo(root_or_buf)
    local root = M.detect(root_or_buf)
    return root and state.repos[root] or nil
end

--- Short HEAD commit id / jj change-id (cached).
---@param root_or_buf? string|integer
---@return string?
function M.head(root_or_buf)
    local repo = M.repo(root_or_buf)
    return repo and repo.head or nil
end

--- Current branch name (git) / active bookmark (jj) (cached).
---@param root_or_buf? string|integer
---@return string?
function M.branch(root_or_buf)
    local repo = M.repo(root_or_buf)
    return repo and repo.branch or nil
end

--- Ahead / behind counts vs upstream (cached).
---@param root_or_buf? string|integer
---@return integer ahead, integer behind
function M.ahead_behind(root_or_buf)
    local repo = M.repo(root_or_buf)
    if not repo then
        return 0, 0
    end
    return repo.ahead or 0, repo.behind or 0
end

--- Refresh the cached Repo header (head/branch/ahead/behind/state/dirty) asynchronously, then
--- `cb(repo)`. This is where the header cache that `repo()`/`head()`/… serve gets populated.
---@param root_or_buf? string|integer
---@param cb? fun(repo: Repo?)
function M.refresh(root_or_buf, cb)
    local repo, im = M.resolve(root_or_buf)
    if not repo or not im then
        if cb then
            cb(nil)
        end
        return
    end
    im.repo_info(repo, function()
        if cb then
            cb(repo)
        end
    end)
end

--- The cached porcelain status for a single path (render-safe once the status model is populated).
---@param path string
---@return { staged?: boolean, unstaged?: boolean, untracked?: boolean, conflicted?: boolean, code?: string }?
function M.file_status(path)
    local root = M.detect(path)
    if not root then
        return nil
    end
    local repo = state.repos[root]
    local model = repo and repo._status ---@type StatusModel?
    if not model then
        return nil
    end
    local rel = vim.fs.normalize(vim.fn.fnamemodify(path, ":p")):gsub("^" .. vim.pesc(root) .. "/", "")
    for _, bucket in ipairs({ "staged", "unstaged", "untracked", "conflicted" }) do
        for _, e in ipairs(model[bucket]) do
            if e.path == rel then
                return {
                    staged = e.staged,
                    unstaged = e.unstaged,
                    untracked = bucket == "untracked",
                    conflicted = bucket == "conflicted",
                    code = e.code,
                }
            end
        end
    end
    return nil
end

--- The full sectioned status model (async — hits the VCS). Caches the result on the Repo for the
--- render-safe `file_status`. `cb(model)`.
---@param root_or_buf? string|integer
---@param cb fun(model: StatusModel?)
function M.status(root_or_buf, cb)
    local repo, im = M.resolve(root_or_buf)
    if not repo or not im then
        cb(nil)
        return
    end
    im.status(repo, function(model)
        if model then
            repo._status = model
        end
        cb(model)
    end)
end

--- Branches / bookmarks / tags / remotes (async). `cb(Ref[])`.
---@param root_or_buf? string|integer
---@param cb fun(refs: Ref[]?)
function M.refs(root_or_buf, cb)
    local repo, im = M.resolve(root_or_buf)
    if not repo or not im then
        cb(nil)
        return
    end
    im.refs(repo, cb)
end

--- Commit list for a revset/range/paths/filters (async). `cb(Commit[])`. `extra` is a list of raw log
--- args appended verbatim (the log-filter transient's assembled argv: `--all`/`--author=…`/…). `L` is a
--- line-range file history request `{ lo, hi, path }` → the commits touching those lines (rename-aware).
---@param opts { root_or_buf?: string|integer, revset?: string, range?: string, paths?: string[], limit?: integer, filters?: table, extra?: string[], follow?: boolean, L?: { lo: integer, hi: integer, path: string } }
---@param cb fun(commits: Commit[]?)
function M.log(opts, cb)
    local repo, im = M.resolve(opts.root_or_buf)
    if not repo or not im then
        cb(nil)
        return
    end
    im.log(repo, opts, cb)
end

--- The whole diff of one file (async), parsed to DiffHunk[]. `opts.rev` diffs vs a rev (default the
--- working tree vs index/HEAD per the impl). `cb(hunks, raw)`.
---@param opts { root_or_buf?: string|integer, path: string, rev?: string, staged?: boolean, context?: integer }
---@param cb fun(hunks: DiffHunk[]?, raw: string?)
function M.diff_file(opts, cb)
    local repo, im = M.resolve(opts.root_or_buf)
    if not repo or not im then
        cb(nil)
        return
    end
    im.diff_file(repo, opts, cb)
end

--- The list of changed files for a rev/range (async). `cb(StatusEntry[])`.
---@param opts { root_or_buf?: string|integer, rev?: string, range?: string, paths?: string[] }
---@param cb fun(entries: StatusEntry[]?)
function M.diff_tree(opts, cb)
    local repo, im = M.resolve(opts.root_or_buf)
    if not repo or not im then
        cb(nil)
        return
    end
    im.diff_tree(repo, opts, cb)
end

--- The blob contents of `path` at `rev` (async), as a line array. `cb(lines)`.
---@param opts { root_or_buf?: string|integer, path: string, rev: string }
---@param cb fun(lines: string[]?)
function M.blob(opts, cb)
    local repo, im = M.resolve(opts.root_or_buf)
    if not repo or not im then
        cb(nil)
        return
    end
    im.blob(repo, opts, cb)
end

--- The base blob for a buffer's gutter signs (git: the index or HEAD per `signs.base`; jj: `@-`),
--- as a line array. `cb(lines, base_id)`.
---@param opts { root_or_buf?: string|integer, path: string, base?: "index"|"head" }
---@param cb fun(lines: string[]?, base_id: string?)
function M.hunks_base(opts, cb)
    local repo, im = M.resolve(opts.root_or_buf)
    if not repo or not im then
        cb(nil)
        return
    end
    im.hunks_base(repo, opts, cb)
end

--- Per-line blame for a file (async, streamed by the impl). `cb(BlameLine[])`. `args` are extra blame
--- flags (`-w`/`-M`/`-C`/`--ignore-revs-file`); `range` limits to `{ lo, hi }`; `contents` blames the
--- working buffer text exactly (`--contents -`, mutually exclusive with `rev`).
---@param opts { root_or_buf?: string|integer, path: string, rev?: string, args?: string[], range?: { lo: integer, hi: integer }, contents?: string }
---@param cb fun(lines: BlameLine[]?)
function M.blame(opts, cb)
    local repo, im = M.resolve(opts.root_or_buf)
    if not repo or not im then
        cb(nil)
        return
    end
    im.blame(repo, opts, cb)
end

--- The whole-tree unified diff (every changed file) as RAW text — the status surface splits it per
--- file. git: `git diff` (worktree vs index) or `--cached` (index vs HEAD, `staged`); jj: `jj diff
--- --git -r @` (working copy vs `@-`; `staged` is empty — no index). `cb(raw)`.
---@param opts { root_or_buf?: string|integer, staged?: boolean, context?: integer }
---@param cb fun(raw: string?)
function M.diff_all(opts, cb)
    local repo, im = M.resolve(opts.root_or_buf)
    if not repo or not im or not im.diff_all then
        cb(nil)
        return
    end
    im.diff_all(repo, opts, cb)
end

--- The jj operation log (async; jj only — `caps.oplog`). `cb(ops)` with
--- `{ id, time, description, tags, current }[]`, or nil when the impl has no op-log concept (git).
---@param root_or_buf? string|integer
---@param cb fun(ops: table[]?)
function M.op_log(root_or_buf, cb)
    local repo, im = M.resolve(root_or_buf)
    if not repo or not im or not im.op_log then
        cb(nil)
        return
    end
    im.op_log(repo, cb)
end

--- The git HEAD reflog (async; git only — `caps.reflog`). `cb(ops)` with the SAME shape `op_log`
--- returns, or nil when the impl has no reflog (jj — it has the op log instead).
---@param root_or_buf? string|integer
---@param cb fun(ops: table[]?)
function M.reflog(root_or_buf, cb)
    local repo, im = M.resolve(root_or_buf)
    if not repo or not im or not im.reflog then
        cb(nil)
        return
    end
    im.reflog(repo, cb)
end

--- The stash list (async; git only — gated on `caps.stash`). `cb(stashes)` with `{ ref, message }[]`,
--- or nil when the repo/impl has no stash concept (jj: `caps.stash = false`).
---@param root_or_buf? string|integer
---@param cb fun(stashes: { ref: string, message: string }[]?)
function M.stash_list(root_or_buf, cb)
    local repo, im = M.resolve(root_or_buf)
    if not repo or not im or not im.stash_list then
        cb(nil)
        return
    end
    im.stash_list(repo, cb)
end

--- The submodule list with per-submodule sha + sync state (async; git only — `caps.submodule`). `cb`
--- receives nil when the impl has no submodule concept (jj).
---@param root_or_buf? string|integer
---@param cb fun(subs: { path: string, sha: string, describe?: string, state: string }[]?)
function M.submodule_status(root_or_buf, cb)
    local repo, im = M.resolve(root_or_buf)
    if not repo or not im or not im.submodule_status then
        cb(nil)
        return
    end
    im.submodule_status(repo, cb)
end

--- The worktree list (async; `caps.worktree` — both git worktrees and jj workspaces). `cb(worktrees)`.
---@param root_or_buf? string|integer
---@param cb fun(worktrees: table[]?)
function M.worktree_list(root_or_buf, cb)
    local repo, im = M.resolve(root_or_buf)
    if not repo or not im or not im.worktree_list then
        cb(nil)
        return
    end
    im.worktree_list(repo, cb)
end

--- The in-progress bisect state (async; git only — `caps.bisect`). `cb(state)` with `active=false` when
--- idle, or nil when the impl has no bisect concept (jj).
---@param root_or_buf? string|integer
---@param cb fun(state: table?)
function M.bisect_state(root_or_buf, cb)
    local repo, im = M.resolve(root_or_buf)
    if not repo or not im or not im.bisect_state then
        cb(nil)
        return
    end
    im.bisect_state(repo, cb)
end

--- The sparse-checkout state (async; `caps.sparse` — git sparse checkout / jj sparse). `cb(state)`.
---@param root_or_buf? string|integer
---@param cb fun(state: table?)
function M.sparse_state(root_or_buf, cb)
    local repo, im = M.resolve(root_or_buf)
    if not repo or not im or not im.sparse_state then
        cb(nil)
        return
    end
    im.sparse_state(repo, cb)
end

-- ── shared unified-diff parser ──────────────────────────────────────────────

--- Parse a unified diff (a `git diff`/`jj diff --git` body) into DiffHunk[]. Both implementations
--- feed their `--no-color -U<ctx>` / `--git` output through here, so the hunk model is identical
--- regardless of VCS. Ignores the file headers (`diff --git`, `index`, `---`, `+++`) — callers that
--- need per-file splitting pre-split on `diff --git`.
---@param text string
---@return DiffHunk[]
function M.parse_unified(text)
    ---@type DiffHunk[]
    local hunks = {}
    local cur ---@type DiffHunk?
    for line in (text .. "\n"):gmatch("(.-)\n") do
        local os_, oc, ns, nc = line:match("^@@%s+%-(%d+),?(%d*)%s+%+(%d+),?(%d*)%s+@@")
        if os_ then
            cur = {
                old_start = tonumber(os_) --[[@as integer]],
                old_count = oc == "" and 1 or tonumber(oc) --[[@as integer]],
                new_start = tonumber(ns) --[[@as integer]],
                new_count = nc == "" and 1 or tonumber(nc) --[[@as integer]],
                header = line,
                lines = {},
            }
            hunks[#hunks + 1] = cur
        elseif cur then
            local first = line:sub(1, 1)
            if first == "+" then
                cur.lines[#cur.lines + 1] = { kind = "add", text = line:sub(2) }
            elseif first == "-" then
                cur.lines[#cur.lines + 1] = { kind = "del", text = line:sub(2) }
            elseif first == " " then
                cur.lines[#cur.lines + 1] = { kind = "context", text = line:sub(2) }
            elseif first == "\\" then
                -- "\ No newline at end of file" — keep the model but do not add a line.
                cur = cur
            end
        end
    end
    return hunks
end

--- Split a multi-file unified diff into { path → hunk-text } chunks on `diff --git a/… b/…`.
---@param text string
---@return table<string, string>  path (b-side) → the diff body for that file
function M.split_files(text)
    ---@type table<string, string>
    local out = {}
    local cur_path, buf
    local function flush()
        if cur_path and buf then
            out[cur_path] = table.concat(buf, "\n")
        end
    end
    for line in (text .. "\n"):gmatch("(.-)\n") do
        local a, b = line:match("^diff %-%-git a/(.-) b/(.+)$")
        if a then
            flush()
            cur_path = b or a
            buf = { line }
        elseif buf then
            buf[#buf + 1] = line
        end
    end
    flush()
    return out
end

return M
