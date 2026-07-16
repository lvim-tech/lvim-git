-- lvim-git.backend.jj: the jj (Jujutsu) implementation of the backend function table.
--
-- The SIBLING of `backend/git.lua` behind the SAME seam (`backend/init.lua`): every read returns the
-- EXACT model shape git.lua returns (StatusModel / DiffHunk / Commit / BlameLine / Ref / Repo header),
-- so every UI component built in phases 4-12 renders against a jj repo unchanged — the UI gates on
-- `repo.caps.*`, never on `vcs == "jj"`.
--
-- Everything is machine-readable, never scraped from human porcelain:
--   * repo header → `log --no-graph -r @ -T <template>` (working-copy change `@`) + `-r @-` bookmarks
--   * status      → `diff --summary -r @` (jj has NO index: all changes are the working copy vs `@-`),
--                   conflicted paths from `resolve --list`
--   * changed     → `diff --summary -r <rev>`
--   * diffs       → `diff --git` (fed through the SHARED unified-diff parser, same as git)
--   * blobs       → `file show -r <rev> <path>`  (rev translated: git's `:0`/`HEAD` → jj's `@-`)
--   * blame       → `file annotate -T <template>`
--   * log         → `log --no-graph -T <\x1f-separated template>` over a revset (default ancestors(@))
--   * refs        → `bookmark list -a -T <template>` (bookmarks + remote bookmarks → the Ref shape)
--   * op log      → `op log --no-graph -T <template>` (jj's killer undo surface, no git analogue)
--
-- jj has no staging index (`@` IS a commit, auto-snapshotted), no stash, no submodule/bisect, and no
-- interactive-rebase todo — those caps are false (see `backend.CAPS.jj`) so the UI omits them. Rewrites
-- are direct (squash/split/abandon/rebase), undo is first-class (op log). Colocated repos read through
-- jj; the git side is reconciled by the sync layer (phase 14).
--
---@module "lvim-git.backend.jj"

local backend = require("lvim-git.backend")
local config = require("lvim-git.config")

local M = {}

-- Field / record separators (US / RS) for the machine-readable templates — the SAME approach git.lua
-- uses with `%x1f`, so both impls parse identically. jj interprets the `"\x1f"` escapes in a template
-- string literal; we split on the raw bytes.
local US = "\31" -- 0x1f field separator
local RS = "\30" -- 0x1e record separator

--- The jj argv prefix (executable + repo-agnostic globals). `--color=never` keeps parsing safe under a
--- user's global color config; `--no-pager` is implicit (vim.system has no tty) but harmless to omit.
---@param extra string[]
---@return string[]
local function jj(extra)
    local argv = { config.jj.cmd, "--color=never" }
    vim.list_extend(argv, extra)
    return argv
end

--- Translate a git-flavoured rev spec (the UI speaks git: `:0`, `:0:`, `HEAD`) into the jj equivalent,
--- so the impl-agnostic UI needs no per-VCS special-casing. The gutter/diff "base" (git index `:0` /
--- `HEAD`) maps to jj's parent change `@-`; a `A..B` range is handled by the caller (split into --from/
--- --to). Anything else (a commit id, `@`, `@-`, a change id) passes through — jj accepts them verbatim.
---@param rev? string
---@return string
local function jjrev(rev)
    if not rev or rev == "" then
        return "@"
    end
    if rev == ":0" or rev == ":0:" or rev == "HEAD" or rev == "@{upstream}" then
        return "@-"
    end
    return rev
end

-- ── repo header + state ─────────────────────────────────────────────────────

-- The @ (working-copy change) header template: commit_id (short, matches the log `id`), empty flag
-- (→ dirty), conflict flag.
local HEAD_TMPL = table.concat({
    "commit_id.short(12)",
    'if(empty,"empty","")',
    'if(conflict,"conflict","")',
}, ' ++ "\\x1f" ++ ') .. ' ++ "\\n"'

--- Refresh the cached Repo header: head (short commit id of `@`) / branch (the bookmark the working copy
--- sits on, i.e. on `@` else `@-`) / dirty (the working copy `@` is non-empty) / state. jj has no
--- ahead/behind vs an upstream in the git sense, so those stay 0 (surfaced via bookmarks in the refs
--- panel instead). No in-progress "sequence" state exists in jj (rewrites are direct) — always "clean".
---@param repo Repo
---@param cb fun()
function M.repo_info(repo, cb)
    backend.output(repo.root, jj({ "log", "--no-graph", "-r", "@", "-T", HEAD_TMPL }), function(out)
        if out then
            local rec = vim.split(vim.trim(out), "\n", { plain = true })[1] or ""
            local f = vim.split(rec, US, { plain = true })
            repo.head = (f[1] and f[1] ~= "" and f[1]:sub(1, 8)) or nil
            repo.dirty = f[2] ~= "empty" -- non-empty working copy = dirty
            repo.state = f[3] == "conflict" and "merge" or "clean"
        end
        -- The "current bookmark" is the bookmark the working copy sits on: on @ if any, else on @-.
        backend.output(
            repo.root,
            jj({ "log", "--no-graph", "-r", "@- | @", "-T", 'bookmarks.join(",") ++ "\\n"' }),
            function(bout)
                local bm
                for line in ((bout or "") .. "\n"):gmatch("(.-)\n") do
                    if line ~= "" then
                        bm = bm or vim.split(line, ",", { plain = true })[1]
                    end
                end
                repo.branch = bm
                repo.bookmark = bm
                cb()
            end
        )
    end)
end

-- ── status ──────────────────────────────────────────────────────────────────

--- Parse `diff --summary` output (`<letter> <path>` per line: M modified / A added / D deleted / C
--- copied / R renamed) into StatusEntry[]. jj has NO index, so everything is a working-copy change —
--- it all goes in the `unstaged` bucket (the `staged` bucket stays empty, so the status "Staged"
--- section auto-hides). A two-char code mirrors git's XY so the UI's glyphs render unchanged.
---@param out string
---@return StatusEntry[]
local function parse_summary(out)
    ---@type StatusEntry[]
    local entries = {}
    for line in (out .. "\n"):gmatch("(.-)\n") do
        local letter, path = line:match("^(%a)%s+(.+)$")
        if letter and path then
            -- Map jj's single letter into a git-style unstaged XY code (space + letter): " M"/" A"/" D".
            entries[#entries + 1] =
                { path = path, code = " " .. letter, kind = "unstaged", staged = false, unstaged = true }
        end
    end
    return entries
end

--- The full sectioned status model. The working copy `@` (vs its parent `@-`) IS the change set: its
--- files fill the `unstaged` section; conflicted paths (from `jj resolve --list`) fill `conflicted`.
--- `staged` and `untracked` stay empty (jj tracks everything in `@`; there is no index). `cb(model)`.
---@param repo Repo
---@param cb fun(model: StatusModel?)
function M.status(repo, cb)
    backend.output(repo.root, jj({ "diff", "--summary", "-r", "@" }), function(out)
        if not out then
            cb(nil)
            return
        end
        ---@type StatusModel
        local model = { root = repo.root, vcs = "jj", staged = {}, unstaged = {}, untracked = {}, conflicted = {} }
        local entries = parse_summary(out)
        -- `resolve --list` exits non-zero when there are no conflicts; a listed path moves to conflicted.
        backend.system(repo.root, jj({ "resolve", "--list" }), nil, function(res)
            local conflicted = {}
            if res.code == 0 and res.stdout then
                for line in (res.stdout .. "\n"):gmatch("(.-)\n") do
                    local p = line:match("^(%S+)")
                    if p then
                        conflicted[p] = true
                    end
                end
            end
            for _, e in ipairs(entries) do
                if conflicted[e.path] then
                    model.conflicted[#model.conflicted + 1] = { path = e.path, code = "UU", kind = "conflicted" }
                else
                    model.unstaged[#model.unstaged + 1] = e
                end
            end
            cb(model)
        end)
    end)
end

-- ── changed-file list (diff --summary) ──────────────────────────────────────

--- The list of changed files for a rev/range. `cb(StatusEntry[])`. `range` "A..B" → `--from A --to B`;
--- a single `rev` → the changes IN that rev (`-r <rev>`); nothing → the working copy `@`.
---@param repo Repo
---@param opts { rev?: string, range?: string, paths?: string[] }
---@param cb fun(entries: StatusEntry[]?)
function M.diff_tree(repo, opts, cb)
    local argv = { "diff", "--summary" }
    if opts.range then
        local a, b = opts.range:match("^(.-)%.%.%.?(.+)$")
        if a and a ~= "" then
            vim.list_extend(argv, { "--from", jjrev(a), "--to", jjrev(b) })
        else
            vim.list_extend(argv, { "-r", jjrev(opts.rev) })
        end
    else
        vim.list_extend(argv, { "-r", jjrev(opts.rev) })
    end
    if opts.paths and #opts.paths > 0 then
        argv[#argv + 1] = "--"
        vim.list_extend(argv, opts.paths)
    end
    backend.output(repo.root, jj(argv), function(out)
        cb(out and parse_summary(out) or nil)
    end)
end

-- ── whole-file diff → DiffHunk[] ────────────────────────────────────────────

--- The whole diff of a file, parsed to DiffHunk[] via the SHARED unified-diff parser (`jj diff --git`
--- emits git-format unified diffs). Working copy (`@` vs `@-`) by default; `rev` diffs that change;
--- `range` "A..B" → `--from/--to`. jj has no index, so `staged` collapses to the working diff. `cb`.
---@param repo Repo
---@param opts { path: string, rev?: string, staged?: boolean, range?: string, context?: integer }
---@param cb fun(hunks: DiffHunk[]?, raw: string?)
function M.diff_file(repo, opts, cb)
    local ctx = opts.context or config.diffview.context or 3
    local argv = { "diff", "--git", "--context", tostring(ctx) }
    if opts.range then
        local a, b = opts.range:match("^(.-)%.%.%.?(.+)$")
        if a and a ~= "" then
            vim.list_extend(argv, { "--from", jjrev(a), "--to", jjrev(b) })
        else
            vim.list_extend(argv, { "-r", jjrev(opts.rev) })
        end
    else
        vim.list_extend(argv, { "-r", jjrev(opts.rev) })
    end
    argv[#argv + 1] = "--"
    argv[#argv + 1] = opts.path
    backend.output(repo.root, jj(argv), function(out)
        cb(out and backend.parse_unified(out) or nil, out)
    end)
end

--- The whole-tree unified diff (every changed file) for the status surface, as RAW git-format text (the
--- caller splits it per file). jj has no index, so `staged` returns "" (the "Staged" section stays
--- empty); `unstaged` is the working copy `@` vs `@-`. `cb(raw)`.
---@param repo Repo
---@param opts { staged?: boolean, context?: integer }
---@param cb fun(raw: string?)
function M.diff_all(repo, opts, cb)
    if opts.staged then
        cb("") -- no index in jj
        return
    end
    local ctx = opts.context or config.diffview.context or 3
    backend.output(repo.root, jj({ "diff", "--git", "--context", tostring(ctx), "-r", "@" }), function(out)
        cb(out or "")
    end)
end

-- ── blob ─────────────────────────────────────────────────────────────────────

--- The contents of `path` at `rev` as a line array (`jj file show -r <rev> <path>`). A git-style base
--- rev (`:0`/`HEAD`) is translated to `@-`. A path that does not exist at `rev` errors → nil (the signs
--- engine treats a nil base as "whole file added", matching an untracked/new file).
---@param repo Repo
---@param opts { path: string, rev: string }
---@param cb fun(lines: string[]?)
function M.blob(repo, opts, cb)
    backend.output(repo.root, jj({ "file", "show", "-r", jjrev(opts.rev), opts.path }), function(out)
        cb(out and vim.split(out, "\n", { plain = true }) or nil)
    end)
end

--- The base blob for a buffer's gutter signs — jj ALWAYS uses the parent change `@-` (`@` already
--- contains the working-copy edits, so the diff base is its parent). `cb(lines, base_id)`.
---@param repo Repo
---@param opts { path: string, base?: "index"|"head" }
---@param cb fun(lines: string[]?, base_id: string?)
function M.hunks_base(repo, opts, cb)
    M.blob(repo, { path = opts.path, rev = "@-" }, function(lines)
        cb(lines, "@-")
    end)
end

-- ── blame (file annotate) ────────────────────────────────────────────────────

-- The annotate template: one line per source line — commit_id, change_id, author, timestamp, summary,
-- final line number. Split on \x1f.
local ANNOTATE_TMPL = table.concat({
    "commit.commit_id()",
    "commit.change_id().short(12)",
    "commit.author().name()",
    "commit.author().email()",
    'commit.author().timestamp().format("%s")',
    "commit.description().first_line()",
    "line_number",
}, ' ++ "\\x1f" ++ ') .. ' ++ "\\n"'

--- Per-line blame for a file (`jj file annotate`), parsed into a BlameLine[] indexed by final line
--- number — the SAME sparse-array shape git.lua returns, so the blame component renders unchanged.
--- jj has no `-w`/`-M`/`--contents` porcelain flags, so `opts.args`/`opts.contents` are ignored (they
--- are git-only infixes; the blame-options transient's jj rows are caps-gated). A committed `rev` is
--- honoured (`-r <rev>` for reblame-at-parent). `previous`/`filename` are not surfaced by jj annotate,
--- so reblame-at-parent uses the change's own parent (the blame panel falls back gracefully).
---@param repo Repo
---@param opts { path: string, rev?: string, range?: { lo: integer, hi: integer } }
---@param cb fun(lines: BlameLine[]?)
function M.blame(repo, opts, cb)
    local argv = { "file", "annotate", "-T", ANNOTATE_TMPL }
    if opts.rev then
        argv[#argv + 1] = "-r"
        argv[#argv + 1] = jjrev(opts.rev)
    end
    argv[#argv + 1] = opts.path
    backend.output(repo.root, jj(argv), function(out)
        if not out then
            cb(nil)
            return
        end
        ---@type BlameLine[]
        local lines = {}
        for rec in (out .. "\n"):gmatch("(.-)\n") do
            if rec ~= "" then
                local f = vim.split(rec, US, { plain = true })
                local lnum = tonumber(f[7])
                -- `range` limits to `{ lo, hi }`; lines outside it are skipped. jj shows uncommitted
                -- working-copy lines attributed to the `@` change — there is no all-zero "not committed
                -- yet" sentinel like git, so every returned line is is_committed = true.
                local in_range = lnum and (not opts.range or (lnum >= opts.range.lo and lnum <= opts.range.hi))
                if lnum and in_range then
                    local commit = f[1] or ""
                    lines[lnum] = {
                        lnum = lnum,
                        commit = commit,
                        abbrev = commit:sub(1, 8),
                        author = f[3] or "",
                        author_mail = f[4],
                        author_time = tonumber(f[5]) or 0,
                        summary = f[6] or "",
                        is_committed = true,
                    }
                end
            end
        end
        cb(lines)
    end)
end

-- ── log ──────────────────────────────────────────────────────────────────────

-- The log template — one \x1e-separated record per commit, \x1f-separated fields: commit_id (full, so
-- graph parent-matching lines up with `id`), change_id, parent commit_ids (comma), author name/email,
-- author timestamp, description first line, bookmarks (→ refs decoration), full description (→ body).
local LOG_TMPL = table.concat({
    "commit_id",
    "change_id",
    'parents.map(|p| p.commit_id()).join(",")',
    "author.name()",
    "author.email()",
    'author.timestamp().format("%s")',
    "description.first_line()",
    "bookmarks.join(',')",
    "description",
}, ' ++ "\\x1f" ++ ') .. ' ++ "\\x1e\\n"'

--- Parse the \x1e/\x1f log template output into Commit[] — the SAME Commit model git.lua returns
--- (change_id filled for jj), so the log/graph/history panels render identically.
---@param out string
---@return Commit[]
local function parse_log(out)
    ---@type Commit[]
    local commits = {}
    for rec in (out .. RS):gmatch("(.-)" .. RS) do
        local trimmed = rec:gsub("^%s+", "")
        if trimmed ~= "" then
            local f = vim.split(trimmed, US, { plain = true })
            local id = f[1] or ""
            ---@type string[]
            local decor = {}
            for d in (f[8] or ""):gmatch("[^,]+") do
                decor[#decor + 1] = vim.trim(d)
            end
            commits[#commits + 1] = {
                id = id,
                change_id = f[2],
                abbrev = id:sub(1, 8),
                parents = vim.split(f[3] or "", ",", { trimempty = true }),
                author = f[4] or "",
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

--- Commit list for a revset/range/paths. `cb(Commit[])`. Default revset = `ancestors(@, <limit>)`
--- (the working copy and its history, linear + parseable, root included) — jj's own default `jj log`
--- revset elides commits, which the graph engine cannot reconstruct, so we ask for a full ancestor
--- walk. `revset`/`range` (a raw jj revset) override it; `paths` filter as a jj fileset. `L` (git line
--- history) is not supported by jj annotate, so it degrades to the file's whole history via `paths`.
---@param repo Repo
---@param opts LvimGitLogOpts
---@param cb fun(commits: Commit[]?)
function M.log(repo, opts, cb)
    local limit = opts.limit or config.log.limit or 256
    local argv = { "log", "--no-graph", "-T", LOG_TMPL }
    local revset
    if opts.range and opts.range:find("@{upstream}", 1, true) then
        -- git upstream-range syntax (status "unpushed"/"unpulled") has no jj analogue → empty.
        cb({})
        return
    elseif opts.range then
        revset = opts.range
    elseif opts.revset and opts.revset ~= "" then
        revset = opts.revset
    elseif opts.L then
        revset = ("ancestors(@, %d)"):format(limit)
    else
        revset = ("ancestors(@, %d)"):format(limit)
    end
    argv[#argv + 1] = "-r"
    argv[#argv + 1] = revset
    -- jj has no `-n <limit>` on log; the revset's `ancestors(@, N)` bounds it, and a user revset is
    -- taken as-is. A trailing fileset filters by path (history / -L fall back to whole-file history).
    local paths = opts.paths
    if not paths and opts.L then
        paths = { opts.L.path }
    end
    if paths and #paths > 0 then
        argv[#argv + 1] = "--"
        vim.list_extend(argv, paths)
    end
    backend.output(repo.root, jj(argv), function(out)
        cb(out and parse_log(out) or nil)
    end)
end

-- ── refs (bookmarks) ─────────────────────────────────────────────────────────

-- The bookmark template: name, remote (empty for a local bookmark), target commit_id, conflict flag,
-- tracked flag. `-a` lists local AND remote bookmarks.
local BOOKMARK_TMPL = table.concat({
    "name",
    'if(remote, remote, "")',
    "normal_target.commit_id()",
    'if(conflict, "conflict", "")',
    'if(tracked, "tracked", "")',
}, ' ++ "\\x1f" ++ ') .. ' ++ "\\n"'

--- Bookmarks (local) + remote bookmarks → the Ref shape. A local bookmark → kind "bookmark"; a remote
--- bookmark (`name@remote`) → kind "remote". jj has no lightweight-tag concept, so no "tag" refs. The
--- conflicted flag surfaces a divergent bookmark (the refs panel badges it). `cb(Ref[])`.
---@param repo Repo
---@param cb fun(refs: Ref[]?)
function M.refs(repo, cb)
    backend.output(repo.root, jj({ "bookmark", "list", "-a", "-T", BOOKMARK_TMPL }), function(out)
        if not out then
            cb(nil)
            return
        end
        ---@type Ref[]
        local refs = {}
        for line in (out .. "\n"):gmatch("(.-)\n") do
            if line ~= "" then
                local f = vim.split(line, US, { plain = true })
                local name = f[1] or ""
                local remote = f[2] or ""
                refs[#refs + 1] = {
                    name = remote ~= "" and (name .. "@" .. remote) or name,
                    kind = remote ~= "" and "remote" or "bookmark",
                    target = (f[3] or ""):sub(1, 8),
                    conflicted = f[4] == "conflict" or nil,
                }
            end
        end
        cb(refs)
    end)
end

-- ── workspaces (the jj analogue of git worktrees) ────────────────────────────

--- The jj workspace list (`jj workspace list`) → the SAME worktree model shape git.lua returns, so the
--- worktree panel renders unchanged (`caps.worktree` is true for both). Plain output is
--- `<name>: <change_id> <commit_id> <description>`. jj does not expose each workspace's on-disk PATH in
--- `workspace list`, so `path` carries the workspace NAME (the panel's identifier); `main` marks the
--- `default` workspace. `cb(worktrees)`.
---@param repo Repo
---@param cb fun(worktrees: table[]?)
function M.worktree_list(repo, cb)
    backend.output(repo.root, jj({ "workspace", "list" }), function(out)
        if not out then
            cb(nil)
            return
        end
        ---@type table[]
        local list = {}
        for line in (out .. "\n"):gmatch("(.-)\n") do
            local name, commit = line:match("^(%S+):%s+%S+%s+(%x+)")
            if name then
                list[#list + 1] = {
                    path = name,
                    branch = name,
                    head = commit:sub(1, 8),
                    main = name == "default",
                }
            end
        end
        cb(list)
    end)
end

-- ── operation log (jj's undo surface) ────────────────────────────────────────

-- The op-log template — one line per operation: id (short), start time, description first line, tags
-- (jj records the invoking `args: …` here). Split on \x1f.
local OPLOG_TMPL = table.concat({
    "id.short(12)",
    'time.start().format("%Y-%m-%d %H:%M:%S")',
    "description.first_line()",
    "tags",
}, ' ++ "\\x1f" ++ ') .. ' ++ "\\n"'

--- The jj operation log (`jj op log`) → a list of operations, newest first, the first being the CURRENT
--- op (`@`). Each op can be undone (`jj op undo`) or restored to (`jj op restore <id>`) — jj's killer
--- feature. `cb(ops)` with `{ id, time, description, tags, current }[]`.
---@param repo Repo
---@param cb fun(ops: { id: string, time: string, description: string, tags: string, current: boolean }[]?)
function M.op_log(repo, cb)
    local limit = config.log.limit or 256
    backend.output(repo.root, jj({ "op", "log", "--no-graph", "-n", tostring(limit), "-T", OPLOG_TMPL }), function(out)
        if not out then
            cb(nil)
            return
        end
        ---@type table[]
        local ops = {}
        for line in (out .. "\n"):gmatch("(.-)\n") do
            if line ~= "" then
                local f = vim.split(line, US, { plain = true })
                if f[1] and f[1] ~= "" then
                    ops[#ops + 1] = {
                        id = f[1],
                        time = f[2] or "",
                        description = f[3] or "",
                        tags = f[4] or "",
                        current = #ops == 0, -- the head operation is the current one
                    }
                end
            end
        end
        cb(ops)
    end)
end

return M
