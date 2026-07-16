-- lvim-git.ui.status: the Magit-grade STATUS surface — the neogit/Magit client, a decoupled COMPONENT
-- over the shared core (backend / model / highlights / config). It is ONE `lvim-ui.tabs` menu tab (the
-- canonical persistent-panel chassis — same as lvim-tasks / lvim-build) whose rows are a SECTIONS TREE:
-- one collapsible `lvim-ui.section` fold header per Magit section (conflicted / staged / unstaged /
-- untracked / stashes / unpushed / unpulled / recent), each shown only when it has content. A file row
-- expands to its HUNKS as sub-rows; the focused file/hunk's diff renders live in the chassis PREVIEW
-- block via `on_item_change`. A filter band (shared `lvim-ui.filters` group) narrows by section; the
-- footer chips are the transient VERB launchers (commit/push/pull/…), each opening its `transient`
-- popup (their defs land in later phases — `transient.open` warns cleanly until then).
--
-- Staging granularity — `s`/`u`/`x` dispatch on the row under the cursor: a SECTION header stages /
-- unstages / discards every file in it (stage-all / unstage-all), a FILE row the whole file, a HUNK
-- sub-row that one hunk (a constructed patch → `git apply --cached`; discard reverse-applies). The whole
-- surface refreshes on `User LvimGitRepoChanged` and after every mutation.
--
-- Chassis-canon notes (deliberate, vs the plan's raw key list): `<Tab>` is the surface's panel-toggle
-- (list ⇄ diff preview — the ONLY way onto the preview), so section folding uses the native `<CR>` /
-- `l` / `h` and `<S-Tab>` cycles the global visibility LEVEL; a file is VISITED with `o` (its `<CR>`
-- toggles its hunks, Magit-style). Cursor hiding is the surface's own (`hide_cursor` panels self-register
-- their frame filetype) — no manual `cursor.register` needed.
--
-- PUBLIC: open / is_open / close / toggle / refresh / register_section (the trailing sibling-section hook).
-- Internal to the status component otherwise.
--
---@module "lvim-git.ui.status"

local api = vim.api
local config = require("lvim-git.config")
local backend = require("lvim-git.backend")
local transient = require("lvim-git.transient")
local commands = require("lvim-git.commands")
local workspace = require("lvim-git.ui.workspace")
local ui = require("lvim-ui")
local ui_filters = require("lvim-ui.filters")
local surface = require("lvim-ui.surface")
local hl = require("lvim-utils.highlight")
local iconlib = require("lvim-utils.icons")

local M = {}

-- ── glyphs (verified single-width Nerd Font, + the `➤` pointer canon) ──────────
local GLYPH = {
    git = "\u{e725}", --  nf-dev-git_branch (title + repo band)
    fold_open = "\u{f0d7}", --  nf-fa-caret_down  (section/file expanded)
    fold_closed = "\u{f0da}", --  nf-fa-caret_right (section/file collapsed)
    hunk = "➤", -- U+27A4 the pointer canon (hunk sub-row marker)
    ahead = "\u{f062}", --  nf-fa-arrow_up
    behind = "\u{f063}", --  nf-fa-arrow_down
    arrow = "➤", -- repo-band segment separator
    drift = "\u{f071}", --  nf-fa-exclamation_triangle (colocated git↔jj drift)
}

--- The Magit status sections, in render order. `file` sections read the StatusModel bucket; `commit`
--- sections read a Commit[]; `stash` the stash list. `accent` is a palette-colour NAME (the fold-header
--- canon: the plugin passes only the accent, the tints are global via lvim-utils).
---@type { id: string, title: string, accent: string, kind: "file"|"commit"|"stash" }[]
local SECTIONS = {
    { id = "conflicted", title = "Conflicted", accent = "red", kind = "file" },
    { id = "staged", title = "Staged", accent = "green", kind = "file" },
    { id = "unstaged", title = "Unstaged", accent = "red", kind = "file" },
    { id = "untracked", title = "Untracked", accent = "magenta", kind = "file" },
    { id = "stashes", title = "Stashes", accent = "cyan", kind = "stash" },
    { id = "unpushed", title = "Unpushed to upstream", accent = "orange", kind = "commit" },
    { id = "unpulled", title = "Unpulled from upstream", accent = "teal", kind = "commit" },
    { id = "recent", title = "Recent commits", accent = "green", kind = "commit" },
}

--- The footer / dispatch VERBS. `verb` opens a transient (def lands in a later phase — warns cleanly);
--- `view` opens a component (guarded); `dispatch` is the Magit `?` menu.
---@type { key: string, label: string, kind: "verb"|"view"|"dispatch", id?: string }[]
local VERBS = {
    { key = "c", label = "commit", kind = "verb", id = "commit" },
    { key = "P", label = "push", kind = "verb", id = "push" },
    { key = "p", label = "pull", kind = "verb", id = "pull" },
    { key = "f", label = "fetch", kind = "verb", id = "fetch" },
    { key = "b", label = "branch", kind = "verb", id = "branch" },
    { key = "M", label = "remote", kind = "verb", id = "remote" },
    { key = "r", label = "rebase", kind = "verb", id = "rebase" },
    { key = "m", label = "merge", kind = "verb", id = "merge" },
    { key = "V", label = "revert", kind = "verb", id = "revert" },
    { key = "A", label = "cherry-pick", kind = "verb", id = "cherry-pick" },
    { key = "X", label = "reset", kind = "verb", id = "reset" },
    { key = "t", label = "tag", kind = "verb", id = "tag" },
    { key = "Z", label = "stash", kind = "verb", id = "stash" },
    { key = "L", label = "log", kind = "view", id = "log" },
    { key = "d", label = "diffview", kind = "view", id = "diffview" },
    { key = "?", label = "dispatch", kind = "dispatch" },
}

--- The jj-lens footer / dispatch verbs (caps.oplog): jj has no index/stash/git-branch model, so the
--- footer shows the jj verb menu (`c`), the log / diffview views, the operation log, and dispatch. The
--- git-only verbs (stage/branch/rebase/tag/…) are simply absent on a jj repo.
---@type { key: string, label: string, kind: "verb"|"view"|"dispatch", id?: string }[]
local JJ_VERBS = {
    { key = "c", label = "jj", kind = "verb", id = "jj" },
    { key = "O", label = "oplog", kind = "view", id = "oplog" },
    { key = "L", label = "log", kind = "view", id = "log" },
    { key = "d", label = "diffview", kind = "view", id = "diffview" },
    { key = "?", label = "dispatch", kind = "dispatch" },
}

---@class LvimGitStatusState
---@field handle table?          the live ui.tabs handle
---@field tabs table[]?          the tab specs (rows rebuilt in place, seen by recalc)
---@field root string?           the repo root
---@field vcs string?            the repo vcs
---@field layout string?         the resolved layout of the open panel
---@field is_tab boolean?        the panel is hosted in a fullscreen workspace tabpage (layout = "tab")
---@field opener integer?        the window the panel was opened from (for `o` visit)
---@field model StatusModel?     the cached porcelain status model
---@field unstaged_diffs table?  path → { header, hunks } (worktree vs index)
---@field staged_diffs table?    path → { header, hunks } (index vs HEAD)
---@field stashes table[]?       { { ref, message } }
---@field recent table?          Commit[] (recent commits)
---@field unpushed table?        Commit[] (@{upstream}..HEAD)
---@field unpulled table?        Commit[] (HEAD..@{upstream})
---@field sequencer table?       LvimGitSequencerState (the in-progress rebase/cherry-pick/revert)
---@field registry table         row name → item (the cursor-dispatch seam)
---@field rowsById table         accordion id → its live row (fold-state capture before rebuild)
---@field folds table            id → expanded boolean (nil = the level default)
---@field level integer          global visibility level 0/1/2 (S-Tab cycles)
---@field filter string          active section filter id
---@field focused table?         the _item under the cursor (drives the preview)
---@field preview_pan table?     the preview panel handle
---@field augroup integer?       the LvimGitRepoChanged listener group
local state = {
    registry = {},
    rowsById = {},
    folds = {},
    level = 2,
    filter = "all",
    recent_limit = nil, -- how many recent commits to show (grows by `status.recent_count` via the "more" row)
}

--- A sibling-registered status section (the documented `register_section` hook). Rendered TRAILING with
--- the same `ui.section` fold machinery as the submodules / sparse sections: content-gated (an empty
--- `rows` result hides it) and shown only under the `all` filter. `rows(root)` MUST be render-safe (a
--- cache/DB read — the status surface calls it synchronously on every rebuild) and returns the section's
--- child rows (each a form row with its own `run`, or nil/empty to omit the section). A sibling plugin
--- self-registers its section (e.g. lvim-forge's open-topics) when both plugins are installed.
---@class LvimGitStatusSection
---@field id       string                       unique section id (fold-state + registry key)
---@field title?   string                       the fold-header label (default = id)
---@field position? "trailing"                  where it renders (only "trailing" in v1)
---@field accent?  string                       palette accent NAME (fold-header canon; default "blue")
---@field rows     fun(root: string): table[]?  the child rows (render-safe); nil/empty hides the section

---@type LvimGitStatusSection[]  sibling-registered trailing sections, in registration order
local ext_sections = {}

---@param msg string
---@param level? integer
local function notify(msg, level)
    vim.notify("lvim-git: " .. msg, level or vim.log.levels.INFO)
end

--- The git argv prefix (matching backend/git.lua): repo-agnostic globals for safe, concurrent parsing.
---@param extra string[]
---@return string[]
local function git_argv(extra)
    local a = { config.git.cmd, "--no-optional-locks", "-c", "color.ui=false" }
    vim.list_extend(a, extra)
    return a
end

--- Whether the panel is open.
---@return boolean
function M.is_open()
    return state.handle ~= nil and state.handle.valid ~= nil and state.handle.valid()
end

-- ── data load ──────────────────────────────────────────────────────────────────

--- Split a `git diff` body into `path → { header, hunks }`. `header` is the file's diff header (the
--- lines before the first `@@`), kept verbatim so a reconstructed single-hunk patch applies cleanly.
---@param text string?
---@return table<string, { header: string, hunks: DiffHunk[] }>
local function parse_file_diffs(text)
    local out = {}
    if not text or text == "" then
        return out
    end
    for path, body in pairs(backend.split_files(text)) do
        local header_lines = {}
        for line in (body .. "\n"):gmatch("(.-)\n") do
            if line:match("^@@") then
                break
            end
            header_lines[#header_lines + 1] = line
        end
        out[path] = { header = table.concat(header_lines, "\n"), hunks = backend.parse_unified(body) }
    end
    return out
end

--- Fetch a whole-tree diff (worktree vs index, or `--cached` index vs HEAD) and parse it per file.
--- Routed through the backend seam (`diff_all`) so it is impl-agnostic: git returns `git diff`/`--cached`,
--- jj returns `jj diff --git -r @` (and an empty staged diff — jj has no index).
---@param staged boolean
---@param cb fun(diffs: table)
local function fetch_diffs(staged, cb)
    backend.diff_all(
        { root_or_buf = state.root, staged = staged, context = config.diffview.context or 3 },
        function(out)
            cb(parse_file_diffs(out or ""))
        end
    )
end

--- Fetch the stash list via the shared backend read (machine-readable `%gd%x1f%s`). `cb({ { ref, message } })`.
---@param cb fun(stashes: table[])
local function fetch_stashes(cb)
    backend.stash_list(state.root, function(list)
        cb(list or {})
    end)
end

--- Load EVERYTHING the surface renders (repo header, status model, both diffs, stashes, recent /
--- unpushed / unpulled commits) in parallel, then `done()` once. Errors resolve to empty (a repo with
--- no upstream simply has no unpushed/unpulled section).
---@param done fun()
local function load(done)
    local pending = 0
    local finished = false
    local function step()
        pending = pending - 1
        if pending <= 0 and not finished then
            finished = true
            done()
        end
    end
    local function fire(fn)
        pending = pending + 1
        fn()
    end

    fire(function()
        backend.refresh(state.root, function()
            step()
        end)
    end)
    fire(function()
        backend.status(state.root, function(model)
            state.model = model or { staged = {}, unstaged = {}, untracked = {}, conflicted = {} }
            step()
        end)
    end)
    fire(function()
        fetch_diffs(false, function(d)
            state.unstaged_diffs = d
            step()
        end)
    end)
    fire(function()
        fetch_diffs(true, function(d)
            state.staged_diffs = d
            step()
        end)
    end)
    fire(function()
        fetch_stashes(function(s)
            state.stashes = s
            step()
        end)
    end)
    fire(function()
        -- Fetch ONE past the current window so we know whether a "more" row is warranted (Magit's `+`).
        local lim = state.recent_limit or config.status.recent_count or 10
        backend.log({ root_or_buf = state.root, limit = lim + 1 }, function(c)
            c = c or {}
            state.recent_has_more = #c > lim
            if state.recent_has_more then
                c[#c] = nil -- drop the probe commit; show exactly `lim`
            end
            state.recent = c
            step()
        end)
    end)
    fire(function()
        backend.log({ root_or_buf = state.root, range = "@{upstream}..HEAD", limit = 50 }, function(c)
            state.unpushed = c or {}
            step()
        end)
    end)
    fire(function()
        backend.log({ root_or_buf = state.root, range = "HEAD..@{upstream}", limit = 50 }, function(c)
            state.unpulled = c or {}
            step()
        end)
    end)
    fire(function()
        require("lvim-git.sequencer").load(state.root, function(sq)
            state.sequencer = sq
            step()
        end)
    end)
    -- The phase-11 status sections (modules / bisect / sparse) are caps-gated (git only) AND toggled by
    -- their component `enabled` flag: a jj repo or a disabled component simply skips the read, so the
    -- section never renders. Each read is cheap and independent.
    local repo = backend.repo(state.root)
    local caps = (repo and repo.caps) or {}
    if config.submodule.enabled and caps.submodule then
        fire(function()
            backend.submodule_status(state.root, function(subs)
                state.submodules = subs or {}
                step()
            end)
        end)
    else
        state.submodules = {}
    end
    if config.bisect.enabled and caps.bisect then
        fire(function()
            require("lvim-git.bisect").load(state.root, function(bi)
                state.bisect = bi
                step()
            end)
        end)
    else
        state.bisect = { active = false }
    end
    if config.sparse.enabled and caps.sparse then
        fire(function()
            backend.sparse_state(state.root, function(sp)
                state.sparse = sp or { enabled = false, patterns = {} }
                step()
            end)
        end)
    else
        state.sparse = { enabled = false, patterns = {} }
    end
end

-- ── section content ────────────────────────────────────────────────────────────

--- The entries a `file` section renders from the status model (nil for a non-file section).
---@param id string
---@return StatusEntry[]?
local function section_entries(id)
    return state.model and state.model[id] or nil
end

--- The Commit[] a `commit` section renders.
---@param id string
---@return table[]
local function section_commits(id)
    if id == "recent" then
        return state.recent or {}
    elseif id == "unpushed" then
        return state.unpushed or {}
    elseif id == "unpulled" then
        return state.unpulled or {}
    end
    return {}
end

--- The row count a section header shows (drives whether the section renders at all).
---@param sec { id: string, kind: string }
---@return integer
local function section_count(sec)
    if sec.kind == "file" then
        local e = section_entries(sec.id)
        return e and #e or 0
    elseif sec.kind == "stash" then
        return state.stashes and #state.stashes or 0
    else
        return #section_commits(sec.id)
    end
end

--- Whether a section is shown under the active filter: a file filter (staged/unstaged/…) shows ONLY
--- that file section; `all` shows every non-empty section.
---@param sec { id: string, kind: string }
---@return boolean
local function section_visible(sec)
    if state.filter == "all" then
        return true
    end
    return sec.kind == "file" and sec.id == state.filter
end

-- ── row building ───────────────────────────────────────────────────────────────

--- Default expanded state for an accordion id: an explicit fold wins, else the global LEVEL (level 0 =
--- all collapsed, 1 = sections open / files collapsed, 2 = sections + files open).
---@param id string
---@param is_section boolean
---@return boolean
local function default_expanded(id, is_section)
    local f = state.folds[id]
    if f ~= nil then
        return f == true
    end
    if is_section then
        return state.level >= 1
    end
    return state.level >= 2
end

--- One hunk sub-row: the `➤` marker + the hunk's `@@` header, `_item` carrying the patch material so
--- `s`/`u`/`x` stage / unstage / discard exactly this hunk; `<CR>` jumps to it in the file.
---@param parent string   the file row name (namespace)
---@param hi integer      hunk index
---@param path string
---@param staged boolean
---@param header string   the file diff header (for the reconstructed patch)
---@param hunk DiffHunk
---@return table
local function hunk_row(parent, hi, path, staged, header, hunk)
    local name = parent .. "#" .. hi
    local item = { kind = "hunk", path = path, staged = staged, header = header, hunk = hunk }
    state.registry[name] = item
    return {
        type = "action",
        name = name,
        flat = true,
        tight = true,
        icon = " " .. GLYPH.hunk .. " ",
        icon_hl = "LvimGitLogId",
        label = vim.trim(hunk.header:gsub("@@.-@@", "%0")),
        text_hl = "LvimUiPathDim",
        _item = item,
        run = function()
            M.visit(path, hunk.new_start)
        end,
    }
end

--- One file row: the file icon + dimmed dir / bright name, `_item` for the live diff preview. When the
--- file has hunks (a tracked modification) it is an ACCORDION whose children are its hunk sub-rows.
---@param sec { id: string }
---@param entry StatusEntry
---@return table
local function file_row(sec, entry)
    local name = sec.id .. ":" .. entry.path
    local staged = sec.id == "staged"
    local diffs = staged and state.staged_diffs or state.unstaged_diffs
    local fdiff = diffs and diffs[entry.path] or nil
    local item = { kind = "file", section = sec.id, path = entry.path, staged = staged, entry = entry }
    state.registry[name] = item

    local base = vim.fs.basename(entry.path)
    local ico = iconlib.get(base) or {}
    local label = entry.path
    if entry.renamed and entry.orig_path then
        label = entry.orig_path .. " " .. GLYPH.arrow .. " " .. entry.path
    end
    local dir = vim.fs.dirname(entry.path)
    local dim_to = (dir and dir ~= "" and dir ~= ".") and (#dir + 1) or 0

    ---@type table[]
    local children = {}
    if fdiff and fdiff.hunks and #fdiff.hunks > 0 then
        for hi, h in ipairs(fdiff.hunks) do
            children[#children + 1] = hunk_row(name, hi, entry.path, staged, fdiff.header, h)
        end
    end

    local row = {
        type = "action",
        name = name,
        flat = true,
        tight = true,
        icon = " " .. (ico.glyph ~= "" and ico.glyph or "\u{f15b}") .. " ",
        icon_hl = (ico.hl and ico.hl ~= "") and ico.hl or "LvimUiPathName",
        label = label,
        dim_to = dim_to,
        _item = item,
    }
    -- A conflicted file opens the 3-block MERGE VIEW on `<CR>` (Magit hands conflicts to the merge view).
    if sec.id == "conflicted" then
        row.run = function()
            require("lvim-git.conflict").open({ path = entry.path })
        end
    end
    if #children > 0 then
        row.children = children
        row.expanded = default_expanded(name, false)
        state.rowsById[name] = row
    end
    return row
end

--- One commit row (recent / unpushed / unpulled): short id + subject, `_item` for the preview.
---@param sec { id: string }
---@param commit table
---@return table
local function commit_row(sec, commit)
    local name = sec.id .. ":" .. commit.abbrev
    state.registry[name] = { kind = "commit", commit = commit }
    return {
        type = "action",
        name = name,
        flat = true,
        tight = true,
        icon = " " .. commit.abbrev .. " ",
        -- The SHA wears its SECTION'S accent (bold), so each commit section reads as one hue and the hashes are
        -- clearly coloured + differentiated (was a shared muted `LvimGitLogId` yellow → looked uncoloured).
        icon_hl = hl.section_accent(sec.accent).text,
        label = commit.subject or "",
        text_hl = hl.section_accent("yellow").text, -- the commit subject in yellow

        _item = { kind = "commit", commit = commit },
        -- <CR> on a recent-commit row opens the per-commit action popup (checkout / cherry-pick / view
        -- diff → ui/diff.lua / … — "the thing at point"), the same actions the log panel offers.
        run = function()
            require("lvim-git.actions").commit_actions(commit, state.root, state.vcs)
        end,
    }
end

--- The "load more" row under the recent-commits section (Magit's `+`): grow the window by
--- `status.recent_count` and re-fetch. Shown only while more commits exist (`state.recent_has_more`).
---@return table
local function more_row()
    return {
        type = "action",
        name = "recent:more",
        flat = true,
        tight = true,
        icon = " " .. GLYPH.fold_open .. " ",
        icon_hl = "LvimUiPathDim",
        label = ("show more  (+%d)"):format(config.status.recent_count or 10),
        text_hl = "LvimUiPathDim",
        run = function()
            local n = config.status.recent_count or 10
            state.recent_limit = (state.recent_limit or n) + n
            load(function()
                M.rebuild()
            end)
        end,
    }
end

--- One stash row.
---@param stash { ref: string, message: string }
---@return table
local function stash_row(stash)
    local name = "stashes:" .. stash.ref
    state.registry[name] = { kind = "stash", ref = stash.ref, message = stash.message }
    return {
        type = "action",
        name = name,
        flat = true,
        tight = true,
        icon = " " .. GLYPH.hunk .. " ",
        icon_hl = "LvimGitRefBookmark",
        label = stash.ref .. "  " .. (stash.message or ""),
        text_hl = "LvimUiPathName",
        _item = { kind = "stash", ref = stash.ref, message = stash.message },
        -- `<CR>` on a stash opens the stash transient scoped to THIS stash (apply / pop / drop / branch /
        -- show act on it directly via `ctx.selection`).
        run = function()
            require("lvim-git.actions").register()
            transient.open("stash", {
                root = state.root,
                lens = state.vcs,
                selection = { ref = stash.ref, message = stash.message },
            })
        end,
    }
end

-- ── the sequencer status section (in-progress rebase / cherry-pick / revert) ────

--- The per-action accent (matches the sequencer todo panel) for a status-section todo row.
---@type table<string, string>
local SEQ_HL = {
    pick = "LvimGitSeqPick",
    reword = "LvimGitSeqReword",
    edit = "LvimGitSeqEdit",
    squash = "LvimGitSeqSquash",
    fixup = "LvimGitSeqFixup",
    drop = "LvimGitSeqDrop",
}

--- The `Rebasing/Cherry-picking/Reverting …` section, shown while a sequence is in progress: the applied
--- (`done`) and remaining (`todo`) commits, then Continue / Skip / Abort / Edit-todo action rows driven
--- off `actions.sequence` (all sequence ops share git's sequencer state). Returns nil when idle.
---@return table?
local function sequencer_section()
    local sq = state.sequencer
    if not (sq and sq.active) then
        return nil
    end
    local accent = sq.type == "cherry-pick" and "magenta" or (sq.type == "revert" and "red" or "yellow")
    local title = ({ rebase = "Rebasing", ["cherry-pick"] = "Cherry-picking", revert = "Reverting" })[sq.type]
        or "Sequencing"
    if sq.type == "rebase" and sq.head_name then
        title = title .. " " .. sq.head_name
    end
    if sq.onto then
        title = title .. " onto " .. sq.onto
    end

    ---@type table[]
    local children = {}
    --- A read-only informational leaf row (a done/current/todo commit line).
    ---@param key string
    ---@param glyph string
    ---@param text string
    ---@param text_hl string
    local function info_row(key, glyph, text, text_hl)
        local name = "seq-info:" .. key .. #children
        state.registry[name] = { kind = "seq-info" }
        children[#children + 1] = {
            type = "action",
            name = name,
            flat = true,
            tight = true,
            icon = " " .. glyph .. " ",
            icon_hl = text_hl,
            label = text,
            text_hl = text_hl,
            run = function() end,
        }
    end
    --- A sequence CONTROL row (Continue/Skip/Abort/Edit-todo) → actions.sequence.
    ---@param op string
    ---@param glyph string
    ---@param label string
    local function control_row(op, glyph, label)
        local name = "seq-op:" .. op
        state.registry[name] = { kind = "seq-op", op = op }
        children[#children + 1] = {
            type = "action",
            name = name,
            flat = true,
            tight = true,
            icon = " " .. glyph .. " ",
            icon_hl = "LvimGitLogId",
            label = label,
            text_hl = "LvimGitTransientOn",
            run = function()
                require("lvim-git.actions").sequence(state.root, state.vcs, op)
            end,
        }
    end

    -- Abbreviate a possibly-full sha (the rebase-merge todo/done files store full 40-char shas).
    ---@param sha string?
    ---@return string
    local function ab(sha)
        return sha and (sha:sub(1, 8) .. "  ") or ""
    end
    for _, e in ipairs(sq.done or {}) do
        info_row("done", "\u{f00c}", ab(e.sha) .. (e.subject or e.action or ""), "LvimUiPathDim")
    end
    if sq.current then
        info_row("cur", GLYPH.hunk, ab(sq.current.sha) .. (sq.current.subject or "(stopped here)"), "LvimGitSeqEdit")
    end
    for _, e in ipairs(sq.todo or {}) do
        info_row(
            "todo",
            " ",
            string.format("%-7s ", e.action) .. ab(e.sha) .. (e.subject or ""),
            SEQ_HL[e.action] or "LvimUiPathName"
        )
    end
    control_row("continue", "\u{f04b}", "Continue") --  play
    control_row("skip", "\u{f051}", "Skip") --  step-forward
    control_row("abort", "\u{f04d}", "Abort") --  stop
    if sq.type == "rebase" then
        control_row("edit-todo", "\u{f044}", "Edit todo") --  edit
    end

    local sa = hl.section_accent(accent)
    local srow = ui.section({
        name = "sequencer",
        icon = " " .. GLYPH.fold_open .. " ",
        box_hl = sa.text,
        label = title,
        count = #(sq.todo or {}),
        accent = accent,
        expanded = true,
        children = children,
    })
    state.registry["sequencer"] = { kind = "seq-section" }
    state.rowsById["sequencer"] = srow
    return srow
end

--- The in-progress BISECT section — leads the tree (like the sequencer) while a bisect is running: a
--- "Bisecting: N revisions left …" header + Good / Bad / Skip / Reset control rows whose `<CR>` runs the
--- matching bisect verb (`actions.bisect_*`). Fed from `bisect.state` (via `state.bisect`). nil when idle.
---@return table?
local function bisect_section()
    local bi = state.bisect
    if not (bi and bi.active) then
        return nil
    end
    local head = "Bisecting"
    if bi.remaining then
        head = ("Bisecting: %d revision%s left"):format(bi.remaining, bi.remaining == 1 and "" or "s")
    end
    if bi.testing then
        head = head .. ", testing " .. bi.testing
    end

    ---@type table[]
    local children = {}
    --- A bisect CONTROL row (Good/Bad/Skip/Reset).
    ---@param op string
    ---@param glyph string
    ---@param label string
    ---@param run fun()
    local function control_row(op, glyph, label, run)
        local name = "bisect-op:" .. op
        state.registry[name] = { kind = "bisect-op", op = op }
        children[#children + 1] = {
            type = "action",
            name = name,
            flat = true,
            tight = true,
            icon = " " .. glyph .. " ",
            icon_hl = "LvimGitLogId",
            label = label,
            text_hl = "LvimGitTransientOn",
            run = run,
        }
    end
    local a = require("lvim-git.actions")
    control_row("good", "\u{f00c}", "Good (" .. (bi.term_good or "good") .. ")", function()
        a.bisect_mark(state.root, state.vcs, "good")
    end)
    control_row("bad", "\u{f00d}", "Bad (" .. (bi.term_bad or "bad") .. ")", function()
        a.bisect_mark(state.root, state.vcs, "bad")
    end)
    control_row("skip", "\u{f051}", "Skip", function()
        a.bisect_mark(state.root, state.vcs, "skip")
    end)
    control_row("reset", "\u{f04d}", "Reset (end bisect)", function()
        a.bisect_reset(state.root, state.vcs)
    end)

    local sa = hl.section_accent("orange")
    local srow = ui.section({
        name = "bisect",
        icon = " " .. GLYPH.fold_open .. " ",
        box_hl = sa.text,
        label = head,
        count = bi.remaining,
        accent = "orange",
        expanded = true,
        children = children,
    })
    state.registry["bisect"] = { kind = "bisect-section" }
    state.rowsById["bisect"] = srow
    return srow
end

--- The SUBMODULES status section — one row per submodule (path · sha · state); `<CR>` opens that
--- submodule's own lvim-git status. Rendered only when the repo actually has submodules. nil otherwise.
---@return table?
local function submodules_section()
    local subs = state.submodules
    if not subs or #subs == 0 then
        return nil
    end
    local SUB_HL = {
        insync = "LvimUiPathDim",
        modified = "LvimGitTransientValue",
        uninitialized = "LvimGitBehind",
        conflict = "LvimGitBehind",
    }
    ---@type table[]
    local children = {}
    for i, s in ipairs(subs) do
        local name = "submodule:" .. i
        state.registry[name] = { kind = "submodule", sub = s }
        local badge = ({
            modified = " (modified)",
            uninitialized = " (uninit)",
            conflict = " (conflict)",
        })[s.state] or ""
        local label, spans = "", {}
        local function seg(text, group)
            local st = #label
            label = label .. text
            spans[#spans + 1] = { st, #label, group }
        end
        seg(s.path, "LvimGitRefBranch")
        seg("  " .. s.sha, "LvimGitLogId")
        if badge ~= "" then
            seg(badge, SUB_HL[s.state] or "LvimUiPathName")
        end
        children[#children + 1] = {
            type = "action",
            name = name,
            flat = true,
            tight = true,
            icon = " " .. GLYPH.hunk .. " ",
            icon_hl = SUB_HL[s.state] or "LvimGitRefBranch",
            label = label,
            label_spans = spans,
            run = function()
                local path = state.root .. "/" .. s.path
                if vim.fn.isdirectory(path) == 1 then
                    vim.cmd("tcd " .. vim.fn.fnameescape(path))
                    require("lvim-git").status()
                else
                    notify("submodule not initialized: " .. s.path, vim.log.levels.WARN)
                end
            end,
        }
    end
    local expanded = default_expanded("modules", true)
    local sa = hl.section_accent("green")
    local srow = ui.section({
        name = "modules",
        icon = " " .. (expanded and GLYPH.fold_open or GLYPH.fold_closed) .. " ",
        box_hl = sa.text,
        label = "Submodules",
        count = #children,
        accent = "green",
        expanded = expanded,
        children = children,
    })
    state.registry["modules"] = { kind = "modules-section" }
    state.rowsById["modules"] = srow
    return srow
end

--- The SPARSE-CHECKOUT status section — the current pattern/directory list (read-only), shown only when
--- sparse checkout is enabled. nil otherwise.
---@return table?
local function sparse_section()
    local sp = state.sparse
    if not (sp and sp.enabled) then
        return nil
    end
    ---@type table[]
    local children = {}
    for i, p in ipairs(sp.patterns or {}) do
        local name = "sparse:" .. i
        state.registry[name] = { kind = "sparse-pattern" }
        children[#children + 1] = {
            type = "action",
            name = name,
            flat = true,
            tight = true,
            icon = " " .. GLYPH.hunk .. " ",
            icon_hl = "LvimUiPathDim",
            label = p,
            text_hl = "LvimGitRefBranch",
            run = function() end,
        }
    end
    if #children == 0 then
        return nil
    end
    local expanded = default_expanded("sparse", true)
    local sa = hl.section_accent("cyan")
    local srow = ui.section({
        name = "sparse",
        icon = " " .. (expanded and GLYPH.fold_open or GLYPH.fold_closed) .. " ",
        box_hl = sa.text,
        label = "Sparse checkout (" .. (sp.cone and "cone" or "pattern") .. ")",
        count = #children,
        accent = "cyan",
        expanded = expanded,
        children = children,
    })
    state.registry["sparse"] = { kind = "sparse-section" }
    state.rowsById["sparse"] = srow
    return srow
end

--- Build a sibling-registered section (the `register_section` hook) into a `ui.section` fold row, using
--- the same machinery as submodules / sparse. Returns nil when the provider yields no rows (content-gated).
---@param prov LvimGitStatusSection
---@return table?
local function ext_section(prov)
    if not state.root then
        return nil
    end
    local ok, children = pcall(prov.rows, state.root)
    if not ok or type(children) ~= "table" or #children == 0 then
        return nil
    end
    local id = "ext:" .. prov.id
    local accent = prov.accent or "blue"
    local expanded = default_expanded(id, true)
    local sa = hl.section_accent(accent)
    local srow = ui.section({
        name = id,
        icon = " " .. (expanded and GLYPH.fold_open or GLYPH.fold_closed) .. " ",
        box_hl = sa.text,
        label = prov.title or prov.id,
        count = #children,
        accent = accent,
        expanded = expanded,
        children = children,
    })
    -- Inert to s/u/x staging (like modules-section / sparse-section): it is not a file-status section.
    state.registry[id] = { kind = "ext-section", id = prov.id }
    state.rowsById[id] = srow
    return srow
end

--- The status filter bar — the shared filter-group model, one group of section narrowers. No direct
--- letter hotkeys (they would clash with the `s`/`u`/`c`/`x` row-action keys); clickable, sector-
--- focusable, and `<C-f>` cycles it.
---@return table  a `type="bar"` row
local function filter_bar()
    local buttons = { { id = "all", label = "All" } }
    -- jj has NO index and NO separate untracked bucket (an untracked file is already part of @),
    -- so the Staged / Untracked chips would always read 0 — omit them on a jj repo.
    if not state.is_jj then
        buttons[#buttons + 1] = { id = "staged", label = "Staged" }
    end
    buttons[#buttons + 1] = { id = "unstaged", label = "Unstaged" }
    if not state.is_jj then
        buttons[#buttons + 1] = { id = "untracked", label = "Untracked" }
    end
    buttons[#buttons + 1] = { id = "conflicted", label = "Conflicted" }
    local fb = ui_filters.bar({ { id = "section", active = state.filter, buttons = buttons } }, {
        count = function(_, b)
            if b.id == "all" then
                return nil
            end
            local e = section_entries(b.id)
            return e and #e or 0
        end,
        on_select = function(_, id)
            state.filter = id
            M.rebuild(false)
        end,
    })
    return { type = "bar", name = "filter", align = "center", items = fb.band.items }
end

--- Build the tab's rows from the loaded model + the active filter + the fold state.
---@return table[]
local function build_rows()
    state.registry = {}
    state.rowsById = {}
    local rows = { filter_bar() }
    -- The in-progress sequence (rebase / cherry-pick / revert) leads the tree while active, so it is the
    -- first thing the user sees with its continue/skip/abort controls.
    if state.filter == "all" then
        local seq = sequencer_section()
        if seq then
            rows[#rows + 1] = seq
        end
        -- A running bisect leads with its progress + good/bad/skip/reset controls, like the sequencer.
        local bi = bisect_section()
        if bi then
            rows[#rows + 1] = bi
        end
    end
    for _, sec in ipairs(SECTIONS) do
        if section_visible(sec) and section_count(sec) > 0 then
            ---@type table[]
            local children = {}
            if sec.kind == "file" then
                for _, e in ipairs(section_entries(sec.id) or {}) do
                    children[#children + 1] = file_row(sec, e)
                end
            elseif sec.kind == "stash" then
                for _, s in ipairs(state.stashes or {}) do
                    children[#children + 1] = stash_row(s)
                end
            else
                for _, c in ipairs(section_commits(sec.id)) do
                    children[#children + 1] = commit_row(sec, c)
                end
                -- Magit's `+`: a trailing "show more" row when the recent window has more behind it.
                if sec.id == "recent" and state.recent_has_more then
                    children[#children + 1] = more_row()
                end
            end
            local expanded = default_expanded(sec.id, true)
            local sa = hl.section_accent(sec.accent)
            local srow = ui.section({
                name = sec.id,
                icon = " " .. (expanded and GLYPH.fold_open or GLYPH.fold_closed) .. " ",
                box_hl = sa.text,
                label = sec.title,
                count = section_count(sec), -- the real item count (never the trailing "show more" row)
                accent = sec.accent,
                expanded = expanded,
                children = children,
            })
            state.registry[sec.id] = { kind = "section", id = sec.id, section = sec }
            state.rowsById[sec.id] = srow
            rows[#rows + 1] = srow
        end
    end
    -- The repo-structure sections (submodules / sparse checkout) trail the file/commit sections, shown
    -- only when they have content and only under the `all` filter (they are not file-status sections).
    if state.filter == "all" then
        local mods = submodules_section()
        if mods then
            rows[#rows + 1] = mods
        end
        local sparse = sparse_section()
        if sparse then
            rows[#rows + 1] = sparse
        end
        -- Sibling-registered trailing sections (the `register_section` hook) render last, each content-
        -- gated and wrapped in the same fold machinery.
        for _, prov in ipairs(ext_sections) do
            if prov.position == nil or prov.position == "trailing" then
                local ext = ext_section(prov)
                if ext then
                    rows[#rows + 1] = ext
                end
            end
        end
    end
    if #rows == 1 then
        rows[#rows + 1] = {
            type = "spacer",
            name = "clean",
            label = "  Working tree clean",
            hl = { inactive = "LvimGitTransientOn" },
        }
    end
    return rows
end

-- ── the repo header band ───────────────────────────────────────────────────────

--- The subtitle repo band: branch ➤ ahead/behind ➤ HEAD subject (+ a `git+jj` colocated badge).
---@return table[]?
local function repo_band()
    local repo = backend.repo(state.root)
    if not repo then
        return nil
    end
    -- Each part its own palette hue (branch green · ahead orange · behind teal · HEAD sha magenta · subject
    -- yellow), assembled into ONE meta line with per-part INLINE hl spans (byte offsets). The line is STATIC —
    -- the repo HEAD, Magit-style — never a cursor breadcrumb (that is the preview on the right).
    ---@type { text: string, accent: string, sep?: string }[]
    local parts = {}
    local branch = repo.branch or (repo.detached and "detached HEAD" or "?")
    parts[#parts + 1] = { text = GLYPH.git .. " " .. branch, accent = "green" }
    if (repo.ahead or 0) > 0 then
        parts[#parts + 1] = { text = GLYPH.ahead .. tostring(repo.ahead), accent = "orange" }
    end
    if (repo.behind or 0) > 0 then
        parts[#parts + 1] = { text = GLYPH.behind .. tostring(repo.behind), accent = "teal" }
    end
    local head = state.recent and state.recent[1]
    if head then
        parts[#parts + 1] = { text = repo.head or head.abbrev, accent = "magenta" }
        parts[#parts + 1] = { text = head.subject or "", accent = "yellow", sep = " " } -- follows the sha with a space
    elseif repo.head then
        parts[#parts + 1] = { text = repo.head, accent = "magenta" }
    end
    local text, hls = hl.band_line(parts, " " .. GLYPH.arrow .. " ")
    if repo.colocated and config.colocated.indicator then
        text = text .. "   " .. GLYPH.git .. " git+jj"
        -- Colocated drift: git and jj both moved a ref (a conflicted bookmark). Flag it in the band so
        -- the user knows the two views disagree and to resolve it in the refs panel.
        local ss = require("lvim-git.backend.sync").sync_state(state.root)
        if ss and ss.drift then
            text = text .. " " .. GLYPH.drift .. " drift"
        end
    end
    return { { text = text, hls = hls } }
end

-- ── the diff preview block ─────────────────────────────────────────────────────

--- Push a unified-diff body (a hunk's `@@` header + its lines) into the preview line/hl accumulators.
---@param lines string[]
---@param hls table[]
---@param header string
---@param hunk DiffHunk
local function push_hunk(lines, hls, header, hunk)
    lines[#lines + 1] = header
    hls[#hls + 1] = { #lines - 1, 0, -1, "LvimGitLogId" }
    for _, l in ipairs(hunk.lines) do
        if l.kind == "add" then
            lines[#lines + 1] = "+" .. l.text
            hls[#hls + 1] = { #lines - 1, 0, -1, "LvimGitDiffAdd" }
        elseif l.kind == "del" then
            lines[#lines + 1] = "-" .. l.text
            hls[#hls + 1] = { #lines - 1, 0, -1, "LvimGitDiffDelete" }
        else
            lines[#lines + 1] = " " .. l.text
        end
    end
end

--- Build the preview content for the focused `_item`: a file's whole diff, a single hunk, a commit's
--- detail, a stash message, or a placeholder.
---@param item table?
---@return string[] lines, table[] hls
local function preview_content(item)
    local lines, hls = {}, {}
    if not item then
        return { "", "  " .. GLYPH.arrow .. " select a file or hunk" }, { { 1, 0, -1, "LvimUiPathDim" } }
    end
    if item.kind == "file" then
        local diffs = item.staged and state.staged_diffs or state.unstaged_diffs
        local fd = diffs and diffs[item.path] or nil
        if fd and #fd.hunks > 0 then
            for _, h in ipairs(fd.hunks) do
                push_hunk(lines, hls, h.header, h)
            end
        elseif item.section == "untracked" then
            local ok, fl = pcall(vim.fn.readfile, state.root .. "/" .. item.path, "", 500)
            for _, l in ipairs((ok and fl) or {}) do
                lines[#lines + 1] = "+" .. l
                hls[#hls + 1] = { #lines - 1, 0, -1, "LvimGitDiffAdd" }
            end
            if #lines == 0 then
                lines = { "  (empty file)" }
            end
        else
            lines = { "  (no textual diff)" }
        end
    elseif item.kind == "hunk" then
        push_hunk(lines, hls, item.hunk.header, item.hunk)
    elseif item.kind == "commit" then
        local c = item.commit
        -- Each field its own hue: the label dim, the value coloured (sha orange · author green · date purple ·
        -- subject yellow, matching the list). The subject is at the FAR LEFT (no git 4-space message indent).
        local sha_hl = hl.section_accent("orange").text
        lines[#lines + 1] = "commit " .. (c.id or c.abbrev or "")
        hls[#hls + 1] = { #lines - 1, 0, 7, "LvimUiPathDim" }
        hls[#hls + 1] = { #lines - 1, 7, -1, sha_hl }
        lines[#lines + 1] = "Author: " .. (c.author or "")
        hls[#hls + 1] = { #lines - 1, 0, 8, "LvimUiPathDim" }
        hls[#hls + 1] = { #lines - 1, 8, -1, hl.section_accent("green").text }
        if c.date and c.date > 0 then
            lines[#lines + 1] = "Date:   " .. os.date("%Y-%m-%d %H:%M", c.date)
            hls[#hls + 1] = { #lines - 1, 0, 8, "LvimUiPathDim" }
            hls[#hls + 1] = { #lines - 1, 8, -1, hl.section_accent("purple").text }
        end
        lines[#lines + 1] = ""
        lines[#lines + 1] = c.subject or ""
        hls[#hls + 1] = { #lines - 1, 0, -1, hl.section_accent("yellow").text }
        for _, bl in ipairs(vim.split(c.body or "", "\n", { plain = true })) do
            lines[#lines + 1] = bl
        end
    elseif item.kind == "stash" then
        lines = { item.ref or "", "", "  " .. (item.message or "") }
        hls[#hls + 1] = { 0, 0, -1, "LvimGitRefBookmark" }
    end
    if #lines == 0 then
        lines = { "" }
    end
    return lines, hls
end

--- The preview block provider (a `render` provider; repainted via `pan.refresh()` on cursor move).
---@return table
local function build_preview()
    return {
        hide_cursor = true,
        filetype = "lvim-git-diff",
        ---@return integer width, integer height
        size = function()
            return math.max(50, math.floor(vim.o.columns * 0.55)), 20
        end,
        ---@param width integer
        ---@return string[] lines, table[] hls
        render = function(width) ---@diagnostic disable-line: unused-local
            return preview_content(state.focused)
        end,
        keys = function(_, pan)
            state.preview_pan = pan
        end,
        on_close = function()
            state.preview_pan = nil
        end,
    }
end

--- Start the previewed FILE's treesitter on the preview buffer, so the diff CODE is syntax-coloured by its
--- language (the +/- add/delete and @@ header extmarks layer ON TOP). Dropped for a commit / stash detail
--- (plain text) or a language with no installed parser. Re-run on every focus change — the previewed file,
--- hence its language, varies. (The leading `+`/`-`/space is tolerated: a context/added line's code parses
--- fine; only a changed line's very first token can mis-scan, which the diff bg tint covers anyway.)
local function apply_preview_syntax()
    local pan = state.preview_pan
    if not (pan and pan.win and api.nvim_win_is_valid(pan.win)) then
        return
    end
    local buf = api.nvim_win_get_buf(pan.win)
    pcall(vim.treesitter.stop, buf) -- drop the previous file's highlighter (the buffer is reused per focus)
    local item = state.focused
    local path = item and (item.kind == "file" or item.kind == "hunk") and item.path or nil
    if not path then
        return
    end
    local ft = vim.filetype.match({ filename = path }) or ""
    local lang = ft ~= "" and vim.treesitter.language.get_lang(ft) or nil
    if lang then
        vim.bo[buf].syntax = "" -- no regex-syntax double-paint under the treesitter highlighter
        pcall(vim.treesitter.start, buf, lang)
    end
end

--- Repaint the preview from the focused item (skipped while the cursor is inside the preview window).
local function update_preview()
    local pan = state.preview_pan
    if pan and pan.win and api.nvim_win_is_valid(pan.win) and api.nvim_get_current_win() ~= pan.win then
        if pan.refresh then
            pan.refresh()
        end
        apply_preview_syntax()
    end
end

-- ── rebuild / refresh ──────────────────────────────────────────────────────────

--- Re-derive the rows and re-fit the panel, keeping the cursor line. `capture ~= false` first snapshots
--- the live accordions' expanded state into `state.folds` (so a manual `<CR>`/`l`/`h` fold persists a
--- data refresh); a LEVEL cycle passes `false` so the level, not the stale rows, decides visibility.
---@param capture? boolean
function M.rebuild(capture)
    if not M.is_open() then
        return
    end
    if capture ~= false then
        for id, row in pairs(state.rowsById) do
            state.folds[id] = row.expanded == true
        end
    end
    state.tabs[1].rows = build_rows()
    local idx = state.handle.cursor_index()
    state.handle.recalc()
    state.handle.focus_index(idx)
    update_preview()
end

--- Reload the model + diffs and rebuild — the ONE refresh path (repo events + post-mutation).
function M.refresh()
    if not M.is_open() then
        return
    end
    load(function()
        M.rebuild(true)
    end)
end

--- PUBLIC: register a sibling-owned TRAILING status section (the Forge-section hook). The provider renders
--- with the same fold machinery as the built-in submodules / sparse sections — content-gated (an empty
--- `rows` result hides it) and shown only under the `all` filter. `provider.rows(root)` MUST be render-safe
--- (a cache/DB read) and returns the section's child rows. Re-registering the same `id` replaces the prior
--- provider. Idempotent; safe to call before or after the status panel is open (it repaints on the next
--- rebuild — trigger one with `M.refresh()` if the panel is already up). A sibling self-registers here when
--- both plugins are installed (e.g. lvim-forge's open-topics section).
---@param provider LvimGitStatusSection
function M.register_section(provider)
    if type(provider) ~= "table" or type(provider.id) ~= "string" or type(provider.rows) ~= "function" then
        notify("register_section: provider needs { id = string, rows = function }", vim.log.levels.WARN)
        return
    end
    for i, p in ipairs(ext_sections) do
        if p.id == provider.id then
            ext_sections[i] = provider
            M.refresh()
            return
        end
    end
    ext_sections[#ext_sections + 1] = provider
    M.refresh()
end

--- Cycle the global visibility LEVEL (0 all-collapsed → 1 sections → 2 sections+hunks), dropping the
--- per-row folds so the level decides. Bound to `<S-Tab>`.
local function cycle_level()
    state.level = (state.level + 1) % 3
    state.folds = {}
    M.rebuild(false)
end

-- ── the focused row / visit ────────────────────────────────────────────────────

--- The `_item` under the cursor (resolved through the row registry).
---@return table?
local function cur_item()
    local name = state.handle and state.handle.cursor_name and state.handle.cursor_name()
    return name and state.registry[name] or nil
end

--- Visit a file in the editor (the window the panel was opened from), optionally at `lnum`. Bound to
--- `o` and to a hunk sub-row's `<CR>`.
---@param path string
---@param lnum? integer
function M.visit(path, lnum)
    local abs = state.root .. "/" .. path
    if state.opener and api.nvim_win_is_valid(state.opener) then
        api.nvim_set_current_win(state.opener)
    end
    vim.cmd("edit " .. vim.fn.fnameescape(abs))
    if lnum then
        pcall(api.nvim_win_set_cursor, 0, { math.max(1, lnum), 0 })
    end
end

-- ── git mutations (stage / unstage / discard) ──────────────────────────────────

--- Run a git mutation under the repo root; on success fire `LvimGitRepoChanged` (signs + panels
--- refresh) + reload this panel; on failure notify. `stdin` feeds a constructed patch.
---@param extra string[]
---@param stdin? string
local function run_git(extra, stdin)
    backend.system(state.root, git_argv(extra), { stdin = stdin }, function(res)
        if res.code ~= 0 then
            notify("git " .. (extra[1] or "") .. " failed: " .. vim.trim(res.stderr or ""), vim.log.levels.ERROR)
            return
        end
        vim.schedule(function()
            vim.cmd("checktime") -- a worktree-editing op (discard hunk) → reload open buffers
            api.nvim_exec_autocmds("User", {
                pattern = "LvimGitRepoChanged",
                data = { root = state.root, vcs = state.vcs, reason = extra[1] },
            })
            M.refresh()
        end)
    end)
end

--- The paths a file section covers (for stage-all / unstage-all / discard-all on a section header).
---@param id string
---@return string[]
local function section_paths(id)
    local out = {}
    for _, e in ipairs(section_entries(id) or {}) do
        out[#out + 1] = e.path
    end
    return out
end

--- Build the single-hunk patch a hunk item stages / unstages as (its file header + the one hunk).
---@param item table  a `hunk` registry item
---@return string
local function hunk_patch(item)
    local parts = { item.header, item.hunk.header }
    for _, l in ipairs(item.hunk.lines) do
        local p = l.kind == "add" and "+" or (l.kind == "del" and "-" or " ")
        parts[#parts + 1] = p .. l.text
    end
    return table.concat(parts, "\n") .. "\n"
end

--- True (and notifies) when the repo has NO staging index (jj): stage/unstage are not applicable — the
--- working copy IS a change; fold it with the jj menu's "Squash into @-" instead.
---@return boolean unavailable
local function no_index()
    local repo = backend.repo(state.root)
    if repo and repo.caps and not repo.caps.index then
        notify("jj has no staging index — use the jj menu (Squash into @-) to fold @", vim.log.levels.WARN)
        return true
    end
    return false
end

--- Stage the row under the cursor: a section stages all its files, a file the whole file, a hunk that
--- hunk (a constructed patch → `git apply --cached`).
function M.stage_current()
    if no_index() then
        return
    end
    local item = cur_item()
    if not item then
        return
    end
    if item.kind == "section" then
        if item.id == "staged" then
            notify("already staged")
        elseif item.id == "unstaged" or item.id == "untracked" or item.id == "conflicted" then
            local paths = section_paths(item.id)
            if #paths > 0 then
                run_git(vim.list_extend({ "add", "--" }, paths))
            end
        end
    elseif item.kind == "file" then
        if item.staged then
            notify("already staged")
        else
            run_git({ "add", "--", item.path })
        end
    elseif item.kind == "hunk" then
        if item.staged then
            notify("already staged")
        else
            run_git({ "apply", "--cached", "-" }, hunk_patch(item))
        end
    end
end

--- Unstage the row under the cursor (a section, file, or hunk — `git restore --staged` / a reverse
--- `git apply --cached -R`).
function M.unstage_current()
    if no_index() then
        return
    end
    local item = cur_item()
    if not item then
        return
    end
    if item.kind == "section" then
        if item.id == "staged" then
            local paths = section_paths("staged")
            if #paths > 0 then
                run_git(vim.list_extend({ "restore", "--staged", "--" }, paths))
            end
        else
            notify("nothing staged here")
        end
    elseif item.kind == "file" then
        if item.staged then
            run_git({ "restore", "--staged", "--", item.path })
        else
            notify("not staged")
        end
    elseif item.kind == "hunk" then
        if item.staged then
            run_git({ "apply", "--cached", "-R", "-" }, hunk_patch(item))
        else
            notify("not staged")
        end
    end
end

--- Discard the row under the cursor (confirmed when `confirm_destructive`): a file restores from the
--- index / is deleted (untracked); a hunk reverse-applies to the worktree.
function M.discard_current()
    local item = cur_item()
    if not item then
        return
    end
    ---@param run fun()
    local function guarded(prompt, run)
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
    if item.kind == "section" then
        local id = item.id
        local paths = section_paths(id)
        if #paths == 0 then
            return
        end
        guarded(("Discard all %d file(s) in %s?"):format(#paths, id), function()
            if id == "untracked" then
                for _, p in ipairs(paths) do
                    vim.fn.delete(state.root .. "/" .. p)
                end
                api.nvim_exec_autocmds("User", {
                    pattern = "LvimGitRepoChanged",
                    data = { root = state.root, vcs = state.vcs, reason = "discard" },
                })
                M.refresh()
            elseif id == "staged" then
                run_git(vim.list_extend({ "restore", "--staged", "--worktree", "--" }, paths))
            else
                run_git(vim.list_extend({ "restore", "--" }, paths))
            end
        end)
    elseif item.kind == "file" then
        guarded(("Discard changes in %s?"):format(item.path), function()
            if item.section == "untracked" then
                vim.fn.delete(state.root .. "/" .. item.path)
                api.nvim_exec_autocmds("User", {
                    pattern = "LvimGitRepoChanged",
                    data = { root = state.root, vcs = state.vcs, reason = "discard" },
                })
                M.refresh()
            elseif item.staged then
                run_git({ "restore", "--staged", "--worktree", "--", item.path })
            else
                run_git({ "restore", "--", item.path })
            end
        end)
    elseif item.kind == "hunk" then
        if item.staged then
            notify("unstage the hunk first (u)", vim.log.levels.WARN)
            return
        end
        guarded("Discard this hunk?", function()
            run_git({ "apply", "-R", "-" }, hunk_patch(item))
        end)
    end
end

-- ── the help window (canonical cheatsheet) ─────────────────────────────────────

--- The status keymap cheatsheet through the shared `lvim-ui.help` component.
local function show_help()
    ui.help({
        title = "Git Status keymaps",
        items = {
            { "s", "stage file / hunk / whole section" },
            { "u", "unstage file / hunk / whole section" },
            { "x", "discard file / hunk / whole section" },
            { "o", "open (visit) the file" },
            { "<CR>", "fold a section · fold a file's hunks · jump to a hunk" },
            { "l / h", "expand / collapse the fold under the cursor" },
            { "<S-Tab>", "cycle the visibility level (all → sections → hunks)" },
            { "<Tab>", "toggle the diff preview panel" },
            { "<C-f>", "cycle the section filter" },
            { "c", "commit" },
            { "P / p / f", "push / pull / fetch" },
            { "b / M", "branch / remote" },
            { "r / m", "rebase / merge" },
            { "<CR>", "on a Continue/Skip/Abort row: drive the in-progress sequence" },
            { "<CR>", "on a conflicted file: open the 3-block merge view" },
            { "<CR>", "on a stash: the stash transient (apply/pop/drop/branch/show)" },
            { "V / A / X", "revert / cherry-pick / reset" },
            { "t / Z", "tag / stash (Z = the stash transient)" },
            { "L / d", "log / diffview" },
            { "?", "dispatch (all commands)" },
            { "q / <Esc>", "close" },
        },
        close_keys = { "q", "<Esc>" },
    })
end

-- ── verbs (footer + dispatch) ──────────────────────────────────────────────────

--- Run a verb: open its transient (def lands later — warns cleanly), a component view (guarded), or the
--- dispatch popup.
---@param v { kind: string, id?: string }
local function run_verb(v)
    if v.kind == "verb" then
        transient.open(v.id, { root = state.root, buf = api.nvim_get_current_buf(), lens = state.vcs })
    elseif v.kind == "view" then
        local ok = pcall(function()
            require("lvim-git")[v.id]()
        end)
        if not ok then
            notify(v.id .. " is not available yet", vim.log.levels.WARN)
        end
    elseif v.kind == "dispatch" then
        require("lvim-git.ui.dispatch").open()
    end
end

--- The active verb set for the repo's lens (git verbs, or the jj verb menu on a jj repo).
---@return table[]
local function active_verbs()
    return state.is_jj and JJ_VERBS or VERBS
end

--- The frame-wide verb hotkeys (fire from anywhere in the panel) + the help chord.
---@return table[]
local function build_keymaps()
    local km = {}
    for _, v in ipairs(active_verbs()) do
        km[#km + 1] = {
            key = v.key,
            run = function()
                run_verb(v)
            end,
        }
    end
    km[#km + 1] = { key = "g?", run = show_help }
    return km
end

--- The footer legend chips (clickable; their letter hotkeys fire via `build_keymaps` / `wire_keys`, so
--- the chips are `no_hotkey` to avoid a double-binding).
---@return table[]
local function build_footer()
    local function chip(key, label, run)
        return { key = key, label = label, no_hotkey = true, run = run }
    end
    local function verb_chip(id, label)
        for _, v in ipairs(active_verbs()) do
            if v.id == id or (id == "dispatch" and v.kind == "dispatch") then
                return chip(v.key, label, function()
                    run_verb(v)
                end)
            end
        end
        return chip("?", label, function() end)
    end
    local sep = { type = "separator", text = "●", style = { padding = { 1, 1 }, hl = "LvimUiFooterSep" } }
    if state.is_jj then
        -- jj: no index (stage/unstage/discard are N/A) — the footer shows the jj verb menu + views.
        return {
            verb_chip("jj", "jj"),
            verb_chip("oplog", "oplog"),
            verb_chip("log", "log"),
            verb_chip("diffview", "diff"),
            verb_chip("dispatch", "more"),
            sep,
            chip("g?", "help", show_help),
            chip("q/Esc", "close", function(st)
                st.close()
            end),
        }
    end
    return {
        chip("s", "stage", M.stage_current),
        chip("u", "unstage", M.unstage_current),
        chip("x", "discard", M.discard_current),
        sep,
        verb_chip("commit", "commit"),
        verb_chip("push", "push"),
        verb_chip("log", "log"),
        verb_chip("dispatch", "more"),
        sep,
        chip("g?", "help", show_help),
        chip("q/Esc", "close", function(st)
            st.close()
        end),
    }
end

-- ── per-row action keys ────────────────────────────────────────────────────────

--- Wire the buffer-local row-action keys (s/u/x/o + S-Tab + C-f). The fold keys (<CR>/l/h) and nav
--- stay the chassis'; `<Tab>` stays the panel toggle.
---@param buf integer
local function wire_keys(buf)
    local function map(lhs, fn, desc)
        vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = "lvim-git: " .. desc })
    end
    map("s", M.stage_current, "stage file/hunk/section")
    map("u", M.unstage_current, "unstage file/hunk/section")
    map("x", M.discard_current, "discard file/hunk/section")
    -- visual-line region: stage/unstage every file/hunk row the selection spans (row-range region).
    vim.keymap.set("x", "s", function()
        M.region("stage")
    end, { buffer = buf, nowait = true, silent = true, desc = "lvim-git: stage region" })
    vim.keymap.set("x", "u", function()
        M.region("unstage")
    end, { buffer = buf, nowait = true, silent = true, desc = "lvim-git: unstage region" })
    map("o", function()
        local item = cur_item()
        if item and (item.kind == "file" or item.kind == "hunk") then
            M.visit(item.path, item.kind == "hunk" and item.hunk.new_start or nil)
        end
    end, "visit the file")
    map("<S-Tab>", cycle_level, "cycle visibility level")
    map("<C-f>", function()
        local order = { "all", "staged", "unstaged", "untracked", "conflicted" }
        local i = 1
        for j, id in ipairs(order) do
            if id == state.filter then
                i = j
            end
        end
        state.filter = order[i % #order + 1]
        M.rebuild(false)
    end, "cycle filter")
end

--- Stage / unstage every file or hunk row the visual-line selection spans (the visual-line REGION).
--- (Line-level sub-hunk region staging lands with the diffview in phase 6; the status tree operates at
--- the row granularity it renders.)
---@param op "stage"|"unstage"
function M.region(op)
    api.nvim_feedkeys(api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
    local win = state.handle and state.handle.win and state.handle.win()
    if not (win and api.nvim_win_is_valid(win)) then
        return
    end
    local s = api.nvim_buf_get_mark(api.nvim_win_get_buf(win), "<")[1]
    local e = api.nvim_buf_get_mark(api.nvim_win_get_buf(win), ">")[1]
    if s > e then
        s, e = e, s
    end
    -- Apply to each row in the range: stage/unstage the file or hunk it maps to.
    for line = s, e do
        pcall(api.nvim_win_set_cursor, win, { line, 0 })
        local item = cur_item()
        if item and (item.kind == "file" or item.kind == "hunk") then
            if op == "stage" then
                M.stage_current()
            else
                M.unstage_current()
            end
        end
    end
end

-- ── autocmds ───────────────────────────────────────────────────────────────────

--- Refresh the whole surface on any repo mutation (our ops + external drift reconciled elsewhere).
local function setup_autocmds()
    if state.augroup then
        pcall(api.nvim_del_augroup_by_id, state.augroup)
    end
    state.augroup = api.nvim_create_augroup("lvim-git.status", { clear = true })
    api.nvim_create_autocmd("User", {
        group = state.augroup,
        pattern = "LvimGitRepoChanged",
        callback = function()
            M.refresh()
        end,
    })
end

-- ── open / close ───────────────────────────────────────────────────────────────

--- Tear down the panel state (the frame close callback).
local function teardown()
    if state.augroup then
        pcall(api.nvim_del_augroup_by_id, state.augroup)
        state.augroup = nil
    end
    state.handle = nil
    state.tabs = nil
    state.preview_pan = nil
    state.registry = {}
    state.rowsById = {}
    state.focused = nil
end

--- Build + show the frame (state is fully re-derivable from the repo, so the frame is reconstructible).
local function open_frame()
    state.tabs = {
        {
            label = "Status",
            icon = GLYPH.git,
            menu = true,
            rows = build_rows(),
            footer = build_footer(),
        },
    }
    state.handle = ui.tabs({
        -- VCS-aware title: on a jj repo the client shows the jj working copy, not the git index.
        title = { icon = GLYPH.git, text = state.is_jj and "Jujutsu Status" or "Git Status" },
        title_pos = "center",
        -- A LIVE subtitle (a function): lvim-ui.tabs re-evaluates it on every recalc, so the repo band
        -- follows HEAD / branch / ahead-behind after a commit / checkout / reset verb refresh.
        subtitle = repo_band,
        tabs = state.tabs,
        -- A `tab` layout hosts the status client in its own fullscreen workspace tabpage (ui/workspace):
        -- the surface opens as a float sized (via `slot`) to FILL that empty tab — never over your code.
        layout = state.is_tab and "float" or state.layout,
        slot = state.is_tab and workspace.slot() or nil,
        pad = 0,
        cursorline_hl = "LvimUiCursorLine",
        content_width = 0.4,
        preview = build_preview(),
        preview_side = "right",
        keymaps = build_keymaps(),
        on_item_change = function(item)
            state.focused = item
            update_preview()
        end,
        on_open = function(buf)
            wire_keys(buf)
            setup_autocmds()
        end,
        callback = function()
            teardown()
            if state.is_tab then
                workspace.exit("status")
            end
        end,
    })
end

--- Open the status client. `opts = { layout?, lens?, args? }`.
---@param opts? table
function M.open(opts)
    opts = opts or {}
    if not config.status.enabled then
        notify("the status component is disabled (status.enabled = false)", vim.log.levels.WARN)
        return
    end
    local root, vcs = backend.detect(api.nvim_get_current_buf())
    if not root then
        notify("not inside a git repository", vim.log.levels.WARN)
        return
    end
    if M.is_open() and root == state.root then
        local win = state.handle.win and state.handle.win()
        if win and api.nvim_win_is_valid(win) then
            api.nvim_set_current_win(win)
        end
        M.refresh()
        return
    end
    if M.is_open() then
        state.handle.close()
    end
    state.root, state.vcs = root, opts.lens or vcs
    local repo_o = backend.repo(root)
    state.is_jj = (repo_o and repo_o.caps and repo_o.caps.oplog) == true
    -- A `tab` layout hosts the client in a dedicated fullscreen workspace tabpage (ui/workspace); the other
    -- layouts (area/float/bottom) open the surface in place.
    local layout = commands.layout_for("status", opts.layout)
    state.is_tab = layout == "tab"
    state.layout = layout
    state.opener = api.nvim_get_current_win()
    if state.is_tab then
        workspace.enter("status")
    end
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
