-- lvim-git.backend.git: the git implementation of the backend function table.
--
-- Everything machine-readable, never scraped from porcelain meant for humans:
--   * status  → `status --porcelain=v2 --branch -z`  (ahead/behind from `# branch.ab`)
--   * changed → `diff --name-status -z`
--   * diffs   → `diff --no-color -U<ctx>`            (parsed by the shared unified-diff parser)
--   * blobs   → `show <rev>:<path>`
--   * blame   → `blame --porcelain --incremental`     (streamed)
--   * log     → `log -z --format=<%x1f-separated>`     (the graph is OURS, never `--graph` ASCII)
--   * refs    → `for-each-ref` with a `%(…)` field format
--
-- The in-progress operation state (merge/rebase/cherry-pick/revert/bisect/am) is read from marker
-- files in GIT_DIR, exactly as Magit derives it. Every call goes through `backend.system` (async).
--
---@module "lvim-git.backend.git"

local uv = vim.uv or vim.loop
local backend = require("lvim-git.backend")
local config = require("lvim-git.config")

local M = {}

--- The git argv prefix (executable + repo-agnostic globals). `-c color.ui=false` keeps parsing safe
--- even under a user's global color config; `--no-optional-locks` avoids racing a concurrent process.
---@param extra string[]
---@return string[]
local function git(extra)
    local argv = { config.git.cmd, "--no-optional-locks", "-c", "color.ui=false" }
    vim.list_extend(argv, extra)
    return argv
end

-- ── repo header + state ─────────────────────────────────────────────────────

--- Resolve the absolute GIT_DIR for a repo (cached on the handle), for state marker-file checks.
---@param repo Repo
---@param cb fun(git_dir: string?)
local function git_dir(repo, cb)
    if repo._git_dir then
        cb(repo._git_dir)
        return
    end
    backend.output(repo.root, git({ "rev-parse", "--absolute-git-dir" }), function(out)
        local dir = out and vim.trim(out)
        if dir and dir ~= "" then
            repo._git_dir = dir
        end
        cb(repo._git_dir)
    end)
end

--- Derive the in-progress operation state from GIT_DIR marker files (Magit's mechanism).
---@param dir string
---@return LvimGitRepoState
local function state_from_dir(dir)
    local function exists(p)
        return uv.fs_stat(dir .. "/" .. p) ~= nil
    end
    if exists("rebase-merge") or exists("rebase-apply/rebasing") then
        return "rebase"
    elseif exists("rebase-apply/applying") or exists("rebase-apply") then
        return "am"
    elseif exists("MERGE_HEAD") then
        return "merge"
    elseif exists("CHERRY_PICK_HEAD") then
        return "cherry-pick"
    elseif exists("REVERT_HEAD") then
        return "revert"
    elseif exists("BISECT_LOG") then
        return "bisect"
    end
    return "clean"
end

--- Refresh the cached Repo header: head / branch / upstream / ahead / behind / dirty / state.
---@param repo Repo
---@param cb fun()
function M.repo_info(repo, cb)
    backend.output(repo.root, git({ "status", "--porcelain=v2", "--branch", "-z" }), function(out)
        local dirty = false
        if out then
            for field in (out .. "\0"):gmatch("(.-)%z") do
                local h = field:match("^# branch%.(.+)$")
                if h then
                    local key, val = h:match("^(%S+)%s*(.*)$")
                    if key == "oid" then
                        repo.head = val == "(initial)" and nil or val:sub(1, 8)
                    elseif key == "head" then
                        if val == "(detached)" then
                            repo.detached = true
                            repo.branch = nil
                        else
                            repo.detached = false
                            repo.branch = val
                        end
                    elseif key == "upstream" then
                        repo.upstream = val
                    elseif key == "ab" then
                        local a, b = val:match("^%+(%d+)%s+%-(%d+)$")
                        repo.ahead = tonumber(a) or 0
                        repo.behind = tonumber(b) or 0
                    end
                elseif field:match("^[12u?]") then
                    dirty = true
                end
            end
        end
        repo.dirty = dirty
        git_dir(repo, function(dir)
            repo.state = dir and state_from_dir(dir) or "clean"
            cb()
        end)
    end)
end

-- ── status ──────────────────────────────────────────────────────────────────

--- Parse `status --porcelain=v2 -z` records into a sectioned StatusModel. With `-z`, records are
--- NUL-separated; a rename/copy (type `2`) consumes an EXTRA NUL field (the original path).
---@param out string
---@param root string
---@return StatusModel
local function parse_status(out, root)
    ---@type StatusModel
    local model = { root = root, vcs = "git", staged = {}, unstaged = {}, untracked = {}, conflicted = {} }
    local fields = {}
    for field in (out .. "\0"):gmatch("(.-)%z") do
        fields[#fields + 1] = field
    end
    local i = 1
    while i <= #fields do
        local rec = fields[i]
        local t = rec:sub(1, 1)
        if t == "1" then
            -- "1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>"
            local xy, path = rec:match("^1 (..) %S+ %S+ %S+ %S+ %S+ %S+ (.+)$")
            if xy then
                local x, y = xy:sub(1, 1), xy:sub(2, 2)
                local e = { path = path, code = xy, staged = x ~= ".", unstaged = y ~= "." }
                if e.staged then
                    e.kind = "staged"
                    model.staged[#model.staged + 1] = e
                end
                if e.unstaged then
                    model.unstaged[#model.unstaged + 1] =
                        { path = path, code = xy, kind = "unstaged", staged = false, unstaged = true }
                end
            end
        elseif t == "2" then
            -- "2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path>" then NEXT field = <origPath>
            local xy, path = rec:match("^2 (..) %S+ %S+ %S+ %S+ %S+ %S+ %S+ (.+)$")
            local orig = fields[i + 1]
            i = i + 1
            if xy then
                local x, y = xy:sub(1, 1), xy:sub(2, 2)
                if x ~= "." then
                    model.staged[#model.staged + 1] = {
                        path = path,
                        orig_path = orig,
                        code = xy,
                        kind = "staged",
                        staged = true,
                        unstaged = y ~= ".",
                        renamed = true,
                    }
                end
                if y ~= "." then
                    model.unstaged[#model.unstaged + 1] =
                        { path = path, orig_path = orig, code = xy, kind = "unstaged", staged = false, unstaged = true }
                end
            end
        elseif t == "u" then
            -- porcelain v2 unmerged: "u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>"
            -- → XY + 8 space-separated fields (sub,m1,m2,m3,mW,h1,h2,h3) before the path.
            local path = rec:match("^u .. %S+ %S+ %S+ %S+ %S+ %S+ %S+ %S+ (.+)$")
            if path then
                model.conflicted[#model.conflicted + 1] = { path = path, code = rec:sub(3, 4), kind = "conflicted" }
            end
        elseif t == "?" then
            local path = rec:sub(3)
            model.untracked[#model.untracked + 1] = { path = path, code = "??", kind = "untracked" }
        end
        i = i + 1
    end
    return model
end

--- The full sectioned status model. `cb(model)`.
---@param repo Repo
---@param cb fun(model: StatusModel?)
function M.status(repo, cb)
    backend.output(repo.root, git({ "status", "--porcelain=v2", "--branch", "-z" }), function(out)
        cb(out and parse_status(out, repo.root) or nil)
    end)
end

-- ── changed-file list (diff --name-status) ──────────────────────────────────

--- The list of changed files for a rev/range/paths. `cb(StatusEntry[])`.
---@param repo Repo
---@param opts { rev?: string, range?: string, paths?: string[], staged?: boolean }
---@param cb fun(entries: StatusEntry[]?)
function M.diff_tree(repo, opts, cb)
    local argv = { "diff", "--name-status", "-z", "-M" }
    if opts.staged then
        argv[#argv + 1] = "--cached"
    end
    if opts.range then
        argv[#argv + 1] = opts.range
    elseif opts.rev then
        argv[#argv + 1] = opts.rev
    end
    if opts.paths and #opts.paths > 0 then
        argv[#argv + 1] = "--"
        vim.list_extend(argv, opts.paths)
    end
    backend.output(repo.root, git(argv), function(out)
        if not out then
            cb(nil)
            return
        end
        ---@type StatusEntry[]
        local entries = {}
        local fields = {}
        for f in (out .. "\0"):gmatch("(.-)%z") do
            fields[#fields + 1] = f
        end
        local i = 1
        while i <= #fields do
            local code = fields[i]
            if code == "" then
                break
            end
            local letter = code:sub(1, 1)
            if letter == "R" or letter == "C" then
                entries[#entries + 1] =
                    { path = fields[i + 2], orig_path = fields[i + 1], code = code, kind = "unstaged", renamed = true }
                i = i + 3
            else
                entries[#entries + 1] = { path = fields[i + 1], code = code, kind = "unstaged" }
                i = i + 2
            end
        end
        cb(entries)
    end)
end

-- ── whole-file diff → DiffHunk[] ────────────────────────────────────────────

--- The whole diff of a file, parsed to DiffHunk[]. Working-tree vs index by default; `staged` diffs
--- the index vs HEAD; `rev` diffs vs a rev. `cb(hunks, raw)`.
---@param repo Repo
---@param opts { path: string, rev?: string, staged?: boolean, context?: integer }
---@param cb fun(hunks: DiffHunk[]?, raw: string?)
function M.diff_file(repo, opts, cb)
    local ctx = opts.context or config.diffview.context or 3
    local argv = { "diff", "--no-color", "-U" .. tostring(ctx) }
    if opts.staged then
        argv[#argv + 1] = "--cached"
    end
    if opts.rev then
        argv[#argv + 1] = opts.rev
    end
    argv[#argv + 1] = "--"
    argv[#argv + 1] = opts.path
    backend.output(repo.root, git(argv), function(out)
        cb(out and backend.parse_unified(out) or nil, out)
    end)
end

--- The whole-tree unified diff (every changed file) for the status surface, as RAW text (the caller
--- splits it per file). Working tree vs index by default; `staged` = the index vs HEAD (`--cached`).
--- `cb(raw)`.
---@param repo Repo
---@param opts { staged?: boolean, context?: integer }
---@param cb fun(raw: string?)
function M.diff_all(repo, opts, cb)
    local ctx = opts.context or config.diffview.context or 3
    local argv = { "diff", "--no-color", "-M", "-U" .. tostring(ctx) }
    if opts.staged then
        argv[#argv + 1] = "--cached"
    end
    backend.output(repo.root, git(argv), function(out)
        cb(out or "")
    end)
end

-- ── blob ─────────────────────────────────────────────────────────────────────

--- The contents of `path` at `rev` as a line array. `rev` may be `:0:` (index), `HEAD`, a sha…
---@param repo Repo
---@param opts { path: string, rev: string }
---@param cb fun(lines: string[]?)
function M.blob(repo, opts, cb)
    local spec = opts.rev:sub(-1) == ":" and (opts.rev .. opts.path) or (opts.rev .. ":" .. opts.path)
    backend.output(repo.root, git({ "show", spec }), function(out)
        cb(out and vim.split(out, "\n", { plain = true }) or nil)
    end)
end

--- The base blob for a buffer's gutter signs — the index (`:0:path`) or HEAD per `signs.base`.
---@param repo Repo
---@param opts { path: string, base?: "index"|"head" }
---@param cb fun(lines: string[]?, base_id: string?)
function M.hunks_base(repo, opts, cb)
    local base = opts.base or config.signs.base or "index"
    local rev = base == "head" and "HEAD" or ":0"
    M.blob(repo, { path = opts.path, rev = rev }, function(lines)
        cb(lines, base)
    end)
end

-- ── blame (porcelain incremental) ────────────────────────────────────────────

--- Parse `blame --porcelain --incremental` output into BlameLine[] indexed by final line number.
---@param out string
---@return BlameLine[]
local function parse_blame(out)
    -- Commit-level metadata (author/summary) is emitted ONCE per commit and keyed by sha; the per-BLOCK
    -- headers `filename`/`previous` describe THAT contiguous line range (a commit can have several blocks
    -- with different `previous` targets — an ADDED line's block has none), so they are recorded per line,
    -- not per commit. The full BlameLine is assembled at the end once every commit's metadata is in.
    ---@type table<integer, { sha: string, filename?: string, previous?: string, previous_filename?: string }>
    local raw = {}
    ---@type table<string, table>
    local commits = {}
    local cur_sha, cur_final, cur_num
    for line in (out .. "\n"):gmatch("(.-)\n") do
        local sha, _, final, num = line:match("^(%x+) (%d+) (%d+) (%d+)$")
        if not sha then
            sha, _, final = line:match("^(%x+) (%d+) (%d+)$")
            num = "1"
        end
        if sha then
            cur_sha, cur_final, cur_num = sha, tonumber(final), tonumber(num)
            commits[sha] = commits[sha] or { commit = sha, abbrev = sha:sub(1, 8) }
            for l = 0, (cur_num or 1) - 1 do
                raw[cur_final + l] = { sha = sha }
            end
        elseif cur_sha then
            local c = commits[cur_sha]
            local key, val = line:match("^(%S+) ?(.*)$")
            if key == "author" then
                c.author = val
            elseif key == "author-mail" then
                c.author_mail = val:gsub("^<", ""):gsub(">$", "")
            elseif key == "author-time" then
                c.author_time = tonumber(val)
            elseif key == "summary" then
                c.summary = val
            elseif key == "filename" or key == "previous" then
                -- Block-level: apply to every line of the CURRENT block only.
                for l = 0, (cur_num or 1) - 1 do
                    local rec = raw[cur_final + l]
                    if rec then
                        if key == "filename" then
                            rec.filename = val
                        else
                            -- `previous <sha> <path-in-parent>` — keep BOTH so a reblame-at-parent follows
                            -- a rename to the correct historical path (fugitive's `-` triage move).
                            rec.previous = val:match("^(%x+)")
                            rec.previous_filename = val:match("^%x+%s+(.+)$")
                        end
                    end
                end
            end
        end
    end
    -- Assemble each line's full BlameLine (commit-level metadata + block-level filename/previous).
    ---@type BlameLine[]
    local lines = {}
    for lnum, rec in pairs(raw) do
        local sha = rec.sha
        local c = commits[sha] or {}
        local uncommitted = sha:match("^0+$") ~= nil
        lines[lnum] = {
            lnum = lnum,
            commit = sha,
            abbrev = c.abbrev or sha:sub(1, 8),
            author = c.author or "",
            author_mail = c.author_mail,
            author_time = c.author_time or 0,
            summary = c.summary or "",
            filename = rec.filename,
            previous = rec.previous,
            previous_filename = rec.previous_filename,
            is_committed = not uncommitted,
        }
    end
    return lines
end

--- Per-line blame for a file. `cb(BlameLine[])` (a sparse array indexed by final line number).
--- `args` are extra blame flags (`-w`, `-M`, `-C`, `--ignore-revs-file=…`). `range` blames only
--- lines `{ lo, hi }` (`-L`). `contents` (buffer text) blames the WORKING copy exactly via
--- `--contents -` — so the panel aligns line-for-line with a modified, unsaved buffer; it is mutually
--- exclusive with `rev` (git refuses `--contents` against a committed rev).
---@param repo Repo
---@param opts { path: string, rev?: string, args?: string[], range?: { lo: integer, hi: integer }, contents?: string }
---@param cb fun(lines: BlameLine[]?)
function M.blame(repo, opts, cb)
    local argv = { "blame", "--porcelain", "--incremental" }
    if opts.args then
        vim.list_extend(argv, opts.args)
    end
    if opts.range then
        argv[#argv + 1] = "-L"
        argv[#argv + 1] = opts.range.lo .. "," .. opts.range.hi
    end
    -- `--contents -` (working buffer) and a committed `rev` are mutually exclusive; contents wins.
    local use_contents = opts.contents ~= nil and opts.rev == nil
    if opts.rev and not use_contents then
        argv[#argv + 1] = opts.rev
    end
    if use_contents then
        argv[#argv + 1] = "--contents"
        argv[#argv + 1] = "-"
    end
    argv[#argv + 1] = "--"
    argv[#argv + 1] = opts.path
    backend.output(repo.root, git(argv), function(out)
        cb(out and parse_blame(out) or nil)
    end, use_contents and { stdin = opts.contents } or nil)
end

-- ── log ──────────────────────────────────────────────────────────────────────

-- Field separator (unit separator \x1f) between fields, records NUL-separated by `-z`.
local LOG_FMT = "%H%x1f%h%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%s%x1f%D%x1f%b"

---@alias LvimGitLogOpts { revset?: string, range?: string, paths?: string[], limit?: integer, filters?: table, extra?: string[], follow?: boolean, L?: { lo: integer, hi: integer, path: string } }

--- Parse `-z --format=<LOG_FMT>` output (NUL-separated records, \x1f-separated fields) into Commit[].
---@param out string
---@return Commit[]
local function parse_log(out)
    ---@type Commit[]
    local commits = {}
    for rec in (out .. "\0"):gmatch("(.-)%z") do
        if rec ~= "" then
            local f = vim.split(rec, "\31", { plain = true })
            local decor = {}
            for d in (f[8] or ""):gmatch("[^,]+") do
                decor[#decor + 1] = vim.trim(d)
            end
            commits[#commits + 1] = {
                id = f[1],
                abbrev = f[2],
                parents = vim.split(f[3] or "", " ", { trimempty = true }),
                author = f[4],
                author_mail = f[5],
                date = tonumber(f[6]) or 0,
                subject = f[7] or "",
                refs = decor,
                body = f[9],
            }
        end
    end
    return commits
end

--- Line-range file history (`git log -L<lo>,<hi>:<path>`). `-L` forces patch output that the `-z`
--- porcelain format cannot share, so we take the commit IDS from a `--format=%H` pass (the hash prints
--- on its own line ahead of each range patch) and then fetch their full metadata in ONE `--no-walk`
--- pass through the shared LOG_FMT parser — same Commit model as every other log read, rename-aware.
---@param repo Repo
---@param opts LvimGitLogOpts
---@param cb fun(commits: Commit[]?)
local function log_line_range(repo, opts, cb)
    assert(opts.L, "log_line_range requires opts.L")
    local range = ("%d,%d:%s"):format(opts.L.lo, opts.L.hi, opts.L.path)
    local idargv = { "log", "-M", "--format=%H", "-L" .. range }
    if opts.limit then
        idargv[#idargv + 1] = "-n"
        idargv[#idargv + 1] = tostring(opts.limit)
    end
    backend.output(repo.root, git(idargv), function(out)
        if not out then
            cb(nil)
            return
        end
        ---@type string[]
        local ids = {}
        local seen = {}
        for line in (out .. "\n"):gmatch("(.-)\n") do
            if
                line:match("^%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$")
                and not seen[line]
            then
                seen[line] = true
                ids[#ids + 1] = line
            end
        end
        if #ids == 0 then
            cb({})
            return
        end
        local meta = { "log", "-z", "--no-walk", "--format=" .. LOG_FMT }
        vim.list_extend(meta, ids)
        backend.output(repo.root, git(meta), function(mout)
            cb(mout and parse_log(mout) or {})
        end)
    end)
end

--- Commit list for a revset/range/paths. `cb(Commit[])`. `extra` (raw log args) and `follow`/`L` extend
--- the query for the log-filter transient and file history; the default `-n <limit>` is emitted first so
--- a `--max-count` inside `extra` (git honours the last one) overrides it.
---@param repo Repo
---@param opts LvimGitLogOpts
---@param cb fun(commits: Commit[]?)
function M.log(repo, opts, cb)
    if opts.L then
        log_line_range(repo, opts, cb)
        return
    end
    local argv = { "log", "-z", "--format=" .. LOG_FMT }
    argv[#argv + 1] = "-n"
    argv[#argv + 1] = tostring(opts.limit or config.log.limit or 256)
    if opts.follow then
        argv[#argv + 1] = "--follow"
    end
    local filters = opts.filters or {}
    for _, k in ipairs({ "author", "grep" }) do
        if filters[k] then
            argv[#argv + 1] = "--" .. k .. "=" .. filters[k]
        end
    end
    for _, k in ipairs({ "S", "G" }) do
        if filters[k] then
            argv[#argv + 1] = "-" .. k .. filters[k]
        end
    end
    if opts.extra and #opts.extra > 0 then
        vim.list_extend(argv, opts.extra)
    end
    if opts.range then
        argv[#argv + 1] = opts.range
    elseif opts.revset and opts.revset ~= "" then
        vim.list_extend(argv, vim.split(opts.revset, "%s+", { trimempty = true }))
    end
    if opts.paths and #opts.paths > 0 then
        argv[#argv + 1] = "--"
        vim.list_extend(argv, opts.paths)
    end
    backend.output(repo.root, git(argv), function(out)
        cb(out and parse_log(out) or nil)
    end)
end

-- ── stash ─────────────────────────────────────────────────────────────────────

--- The stash list (`git stash list`), machine-readable via `--format=%gd%x1f%s` so the ref (`stash@{N}`)
--- and the human message never have to be scraped out of one human-formatted line. `cb(stashes)`.
---@param repo Repo
---@param cb fun(stashes: { ref: string, message: string }[]?)
function M.stash_list(repo, cb)
    backend.output(repo.root, git({ "stash", "list", "--format=%gd%x1f%s" }), function(out)
        if not out then
            cb(nil)
            return
        end
        ---@type { ref: string, message: string }[]
        local list = {}
        for line in (out .. "\n"):gmatch("(.-)\n") do
            if line ~= "" then
                local ref, msg = line:match("^(.-)\31(.*)$")
                if ref then
                    list[#list + 1] = { ref = ref, message = msg or "" }
                end
            end
        end
        cb(list)
    end)
end

-- ── submodules ─────────────────────────────────────────────────────────────

--- The submodule list with each submodule's short sha + sync state. Parses `git submodule status`:
--- a leading status char (` ` in-sync / `+` checked-out commit differs / `-` not initialized /
--- `U` merge conflicts) + the recorded sha + the path + an optional `(describe)`. `cb(subs)`. An empty
--- list (no `.gitmodules` / no submodules) resolves to `{}`.
---@param repo Repo
---@param cb fun(subs: { path: string, sha: string, describe?: string, state: "insync"|"modified"|"uninitialized"|"conflict" }[]?)
function M.submodule_status(repo, cb)
    backend.output(repo.root, git({ "submodule", "status" }), function(out)
        if not out then
            cb({})
            return
        end
        ---@type { path: string, sha: string, describe?: string, state: string }[]
        local subs = {}
        local STATE = { [" "] = "insync", ["+"] = "modified", ["-"] = "uninitialized", ["U"] = "conflict" }
        for line in (out .. "\n"):gmatch("(.-)\n") do
            if line ~= "" then
                local ch = line:sub(1, 1)
                local sha, path, describe = line:sub(2):match("^(%x+)%s+(%S+)%s*(.*)$")
                if sha then
                    describe = describe and describe:match("^%((.-)%)$") or nil
                    subs[#subs + 1] = {
                        path = path,
                        sha = sha:sub(1, 8),
                        describe = describe,
                        state = STATE[ch] or "insync",
                    }
                end
            end
        end
        cb(subs)
    end)
end

-- ── worktrees ──────────────────────────────────────────────────────────────

--- The worktree list (`git worktree list --porcelain`): one blank-line-separated record per worktree
--- with `worktree <path>` / `HEAD <sha>` / `branch <ref>` (or `detached`) / `bare` / `locked [reason]`.
--- `cb(worktrees)`; the first entry is the main worktree.
---@param repo Repo
---@param cb fun(worktrees: { path: string, head?: string, branch?: string, detached?: boolean, bare?: boolean, locked?: boolean, lock_reason?: string, main?: boolean }[]?)
function M.worktree_list(repo, cb)
    backend.output(repo.root, git({ "worktree", "list", "--porcelain" }), function(out)
        if not out then
            cb(nil)
            return
        end
        ---@type table[]
        local list = {}
        local cur
        for line in (out .. "\n"):gmatch("(.-)\n") do
            if line == "" then
                cur = nil
            else
                local key, val = line:match("^(%S+) ?(.*)$")
                if key == "worktree" then
                    cur = { path = val, main = #list == 0 }
                    list[#list + 1] = cur
                elseif cur then
                    if key == "HEAD" then
                        cur.head = val:sub(1, 8)
                    elseif key == "branch" then
                        cur.branch = val:gsub("^refs/heads/", "")
                    elseif key == "detached" then
                        cur.detached = true
                    elseif key == "bare" then
                        cur.bare = true
                    elseif key == "locked" then
                        cur.locked = true
                        cur.lock_reason = val ~= "" and val or nil
                    end
                end
            end
        end
        cb(list)
    end)
end

-- ── bisect ─────────────────────────────────────────────────────────────────

--- The in-progress bisect state. Active when GIT_DIR holds `BISECT_LOG` (see `state_from_dir`). Reads
--- the good/bad terms (`BISECT_TERMS`, default bad/good), the `refs/bisect/*` marks, and — once at least
--- one bad AND one good are marked — git's OWN `rev-list --bisect-vars` (the exact math the porcelain
--- prints), giving the revision being tested (HEAD), the count remaining, and the estimated steps.
--- `cb(state)` with `active=false` when idle.
---@param repo Repo
---@param cb fun(state: { active: boolean, term_bad?: string, term_good?: string, bad?: string, goods?: string[], testing?: string, remaining?: integer, steps?: integer })
function M.bisect_state(repo, cb)
    git_dir(repo, function(dir)
        if not dir or not uv.fs_stat(dir .. "/BISECT_LOG") then
            cb({ active = false })
            return
        end
        local term_bad, term_good = "bad", "good"
        local fd = io.open(dir .. "/BISECT_TERMS", "r")
        if fd then
            local l1 = fd:read("*l")
            local l2 = fd:read("*l")
            fd:close()
            term_bad = (l1 and l1 ~= "" and l1) or term_bad
            term_good = (l2 and l2 ~= "" and l2) or term_good
        end
        backend.output(repo.root, git({ "for-each-ref", "--format=%(refname)", "refs/bisect/" }), function(out)
            local bad
            ---@type string[]
            local goods = {}
            for line in ((out or "") .. "\n"):gmatch("(.-)\n") do
                local name = line:gsub("^refs/bisect/", "")
                if name == term_bad then
                    bad = "refs/bisect/" .. term_bad
                elseif name:match("^" .. vim.pesc(term_good) .. "%-") then
                    goods[#goods + 1] = line
                end
            end
            local base = { active = true, term_bad = term_bad, term_good = term_good, bad = bad, goods = goods }
            base.testing = repo.head
            if not bad or #goods == 0 then
                cb(base)
                return
            end
            local argv = { "rev-list", "--bisect-vars", bad, "--not" }
            vim.list_extend(argv, goods)
            backend.output(repo.root, git(argv), function(vout)
                if vout then
                    base.remaining = tonumber(vout:match("bisect_nr=(%d+)"))
                    base.steps = tonumber(vout:match("bisect_steps=(%d+)"))
                    -- `--bisect-vars` prints shell-quoted values (bisect_rev='<sha>'), so skip the quote.
                    local rev = vout:match("bisect_rev='?(%x+)")
                    if rev then
                        base.testing = rev:sub(1, 8)
                    end
                end
                cb(base)
            end)
        end)
    end)
end

-- ── sparse checkout ────────────────────────────────────────────────────────

--- The sparse-checkout state: whether sparse checkout is on, cone vs pattern mode, and the current
--- pattern/directory list. `git sparse-checkout list` exits non-zero when sparse checkout is disabled,
--- so a nil read = disabled. `cb(state)`.
---@param repo Repo
---@param cb fun(state: { enabled: boolean, cone: boolean, patterns: string[] })
function M.sparse_state(repo, cb)
    backend.system(repo.root, git({ "sparse-checkout", "list" }), nil, function(res)
        if res.code ~= 0 then
            cb({ enabled = false, cone = false, patterns = {} })
            return
        end
        ---@type string[]
        local patterns = {}
        for line in ((res.stdout or "") .. "\n"):gmatch("(.-)\n") do
            if line ~= "" then
                patterns[#patterns + 1] = line
            end
        end
        backend.output(repo.root, git({ "config", "--get", "--bool", "core.sparseCheckoutCone" }), function(cout)
            cb({ enabled = true, cone = cout and vim.trim(cout) == "true" or false, patterns = patterns })
        end)
    end)
end

-- ── refs ─────────────────────────────────────────────────────────────────────

-- ── reflog (the git analogue of jj's op log) ────────────────────────────────

--- The HEAD reflog (`git reflog`) → a list of reflog entries, newest first, the first being the current
--- HEAD. Machine-readable via `--format=%H%x1f%gd%x1f%gs%x1f%cr` (hash / selector `HEAD@{N}` / subject /
--- relative date). The oplog UI shows this on a git repo (jump/checkout only — git's reflog is
--- read-mostly, unlike jj's undoable op log). `cb(ops)` with the SAME shape the op-log seam returns.
---@param repo Repo
---@param cb fun(ops: { id: string, time: string, description: string, tags: string, current: boolean }[]?)
function M.reflog(repo, cb)
    local limit = config.log.limit or 256
    local fmt = "%H%x1f%gd%x1f%gs%x1f%cr"
    backend.output(repo.root, git({ "reflog", "--format=" .. fmt, "-n", tostring(limit) }), function(out)
        if not out then
            cb(nil)
            return
        end
        ---@type table[]
        local ops = {}
        for line in (out .. "\n"):gmatch("(.-)\n") do
            if line ~= "" then
                local f = vim.split(line, "\31", { plain = true })
                if f[1] and f[1] ~= "" then
                    ops[#ops + 1] = {
                        id = f[1]:sub(1, 8),
                        selector = f[2] or "",
                        time = f[4] or "",
                        description = f[3] or "",
                        tags = f[2] or "",
                        current = #ops == 0,
                    }
                end
            end
        end
        cb(ops)
    end)
end

--- Branches / remote branches / tags with tracking + ahead/behind. `cb(Ref[])`.
---@param repo Repo
---@param cb fun(refs: Ref[]?)
function M.refs(repo, cb)
    local fmt = "%(refname)%1f%(objectname)%1f%(upstream:short)%1f%(upstream:track)"
    backend.output(
        repo.root,
        git({ "for-each-ref", "--format=" .. fmt, "refs/heads", "refs/remotes", "refs/tags" }),
        function(out)
            if not out then
                cb(nil)
                return
            end
            ---@type Ref[]
            local refs = {}
            for line in (out .. "\n"):gmatch("(.-)\n") do
                if line ~= "" then
                    local f = vim.split(line, "\31", { plain = true })
                    local name = f[1] or ""
                    local kind, short = "local", name
                    if name:match("^refs/heads/") then
                        kind, short = "local", name:gsub("^refs/heads/", "")
                    elseif name:match("^refs/remotes/") then
                        kind, short = "remote", name:gsub("^refs/remotes/", "")
                    elseif name:match("^refs/tags/") then
                        kind, short = "tag", name:gsub("^refs/tags/", "")
                    end
                    local ahead, behind
                    local track = f[4] or ""
                    ahead = tonumber(track:match("ahead (%d+)"))
                    behind = tonumber(track:match("behind (%d+)"))
                    refs[#refs + 1] = {
                        name = short,
                        kind = kind,
                        target = (f[2] or ""):sub(1, 8),
                        tracking = f[3] ~= "" and f[3] or nil,
                        ahead = ahead,
                        behind = behind,
                    }
                end
            end
            cb(refs)
        end
    )
end

return M
