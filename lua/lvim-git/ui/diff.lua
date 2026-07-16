-- lvim-git.ui.diff: the DIFFVIEW component (neogit/vgit/diffview/codediff role) — a rev / range /
-- buffer diff view with a changed-FILES panel + a side-by-side (split) OR inline diff, staging from
-- within the diff, and a diff-options transient. A decoupled COMPONENT over the shared core
-- (backend / model / highlights / config), standalone (`:LvimGit diffview [rev|range] [-- paths]`).
--
-- WHY a dedicated tabpage of REAL windows (not a centred float): a split `diffthis` needs real editor
-- windows — the native diff engine owns the line alignment, filler, scrollbind, folds and the
-- `linematch` char spans. A float cannot host that. So the diffview opens its OWN tabpage (the
-- "native docked / tab component" model): the FILES panel is a native docked `lvim-ui.surface` on the
-- LEFT (a real, navigable side tree — the lsp-outline precedent), and the DIFF fills the rest as real
-- windows on the RIGHT. The phase-12 generic `ui/workspace.lua` will later host any view in a tab; this
-- is the scoped precursor for diffview.
--
-- Split mode = two real windows with `diffthis`; the two-tier codediff look is native `linematch` +
-- per-window `winhighlight` (base side DiffText → LvimGitDiffDeleteText, work side → …AddText), so the
-- char tier is THEMED, never a redundant extmark pass over native DiffText. Inline mode = one window
-- of the new-side content with deletions as red `virt_lines` and additions/changes tinted inline, its
-- char spans computed here (prefix/suffix trim — no native diff engine inline). `t` toggles the mode.
--
-- Staging from the diff (working scope only): `s`/`x` stage / discard the hunk under the cursor OR the
-- visual-line region — a region builds a PARTIAL patch (unselected adds dropped, unselected dels turned
-- to context, counts recomputed → true line-level sub-hunk staging) applied with `git apply --cached`
-- (`-R` on the worktree for discard). Every mutation fires `User LvimGitRepoChanged`.
--
-- The diff-options transient (context / ignore-whitespace / algorithm) is the diffview's own `diff`
-- def; applying it re-renders live. The whole view refreshes on `User LvimGitRepoChanged`.
--
-- OVERLAY SEAM (a sibling — e.g. lvim-forge's review workspace — anchors its own extmarks on the diff's
-- file buffers): the diff opens ONE file at a time in throwaway scratch buffers that carry no name/var, so
-- a consumer cannot map buffer→path on its own. Two additive PUBLIC surfaces expose that mapping cleanly,
-- mirroring the existing `LvimGitDiffOpen`/`Close` event style:
--   • `User LvimGitDiffFileLoaded { root, vcs, path, mode, buf_base, buf_work, buf_inline }` fires whenever
--     a file finishes rendering (split → buf_base/buf_work; inline → buf_inline) — the reactive anchor hook.
--   • `M.show_file(path)` loads a specific changed file into the diff (drives cross-file navigation from the
--     consumer, e.g. jumping to the next review thread in another file).
-- Neither changes the diff's own behaviour; both are inert unless a consumer listens / calls.
--
-- PUBLIC: open / is_open / close / toggle / reload / show_file. Internal otherwise.
--
---@module "lvim-git.ui.diff"

local api = vim.api
local config = require("lvim-git.config")
local backend = require("lvim-git.backend")
local transient = require("lvim-git.transient")
local commands = require("lvim-git.commands")
local ui = require("lvim-ui")
local surface = require("lvim-ui.surface")
local cursor = require("lvim-utils.cursor")
local iconlib = require("lvim-utils.icons")

local M = {}

-- ── glyphs (verified single-width Nerd Font, + the `➤` pointer canon) ──────────
local GLYPH = {
    diff = "\u{f440}", --  nf-cod-diff (title)
    git = "\u{e725}", --  nf-dev-git_branch (repo band)
    arrow = "➤", -- rename / segment separator (the pointer canon)
    file = "\u{f15b}", --  nf-fa-file (fallback file icon)
}

--- The diffview filetype for the FILES panel (the user's cursor `panel_ft`: cursor hidden only while
--- the files panel is the current window; the diff windows are real code windows — cursor visible).
---@type string
local FILES_FT = "lvim-git-diff-files"

---@class LvimGitDiffState
---@field tab integer?          the dedicated diffview tabpage
---@field origin_tab integer?   the tabpage to return to on close
---@field origin_win integer?   the window focus came from
---@field files_handle table?   the native files-surface handle
---@field files_tree table?     the lvim-ui.tree handle for the files panel
---@field files_win integer?    the files panel window
---@field container integer?    the right-hand diff container window (inline win / split parent)
---@field win_base integer?     split: the base (left) window
---@field win_work integer?     split: the work/new (right) window
---@field buf_base integer?     split: the base scratch buffer
---@field buf_work integer?     split: the work scratch buffer
---@field win_inline integer?   inline: the single window
---@field buf_inline integer?   inline: the scratch buffer
---@field ns integer?           the inline/extmark namespace
---@field root string?          the repo root
---@field vcs string?           the repo vcs
---@field scope string?         "working"|"rev"|"range"
---@field rev string?           a single rev (rev scope)
---@field range string?         a rev range A..B / A...B (range scope)
---@field a string?             range base rev
---@field b string?             range new rev
---@field paths string[]?       path filter
---@field mode string?          "split"|"inline"
---@field files StatusEntry[]?  the changed files
---@field current string?       the current file path
---@field diff table?           the current file's { header, hunks } (parsed, for staging + inline)
---@field diff_args string[]?   the assembled diff-options transient args (context/whitespace/algorithm)
---@field load_token integer?   guards a stale async diff load (rapid file navigation)
---@field augroup integer?      the LvimGitRepoChanged listener group
---@field saved_diffopt string? the diffopt to restore on close
local state = { mode = "split", load_token = 0 }

---@type boolean  one-time cursor self-registration + diff transient def
local registered = false

--- Forward declaration: the diff-window buffer keymaps (defined after the actions it binds).
---@type fun(buf: integer)
local wire_diff_keys

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

--- Whether the diffview is open (its tabpage still exists).
---@return boolean
function M.is_open()
    return state.tab ~= nil and api.nvim_tabpage_is_valid(state.tab)
end

-- ── the diff-options transient (the diffview's own `diff` def) ───────────────────

--- Register the `diff` transient once: switches (ignore-whitespace) + options (context lines,
--- algorithm) + the apply action that re-renders the current file live with the assembled options.
local function ensure_transient()
    if transient.has("diff") then
        return
    end
    transient.define({
        id = "diff",
        title = "Diff options",
        groups = {
            {
                title = "Whitespace",
                infix = {
                    { kind = "switch", key = "-w", label = "Ignore all whitespace", flag = "--ignore-all-space" },
                    {
                        kind = "switch",
                        key = "-b",
                        label = "Ignore whitespace change",
                        flag = "--ignore-space-change",
                    },
                },
            },
            {
                title = "Diff",
                infix = {
                    {
                        kind = "option",
                        key = "=U",
                        label = "Context lines",
                        arg = "--unified",
                        default = tostring(config.diffview.context or 3),
                    },
                    {
                        kind = "option",
                        key = "=A",
                        label = "Algorithm",
                        arg = "--diff-algorithm",
                        choices = { "default", "minimal", "patience", "histogram" },
                    },
                },
                actions = {
                    {
                        key = "g",
                        label = "Apply / refresh",
                        run = function(args)
                            state.diff_args = args
                            M.reload()
                        end,
                    },
                },
            },
        },
    })
end

--- Open the diff-options transient (re-renders the current file when its apply action runs).
local function open_diff_transient()
    ensure_transient()
    transient.open("diff", { root = state.root, lens = state.vcs })
end

--- The diff-options argv (context/whitespace/algorithm) currently in effect. Seeds from the transient
--- session default (which carries the `--unified=<context>` default) until the user applies changes.
---@return string[]
local function diff_options()
    if state.diff_args then
        return state.diff_args
    end
    ensure_transient()
    state.diff_args = transient.args("diff", state.root)
    return state.diff_args
end

-- ── scope + argv resolution ──────────────────────────────────────────────────

--- Resolve the diff SCOPE from opts/args: a `<rev>..<rev>` token → range (base A, new B); a single rev
--- → rev (base rev, new worktree); nothing → working (base index, new worktree). A `--` splits paths.
---@param opts table
local function resolve_scope(opts)
    state.rev, state.range, state.a, state.b, state.paths = nil, nil, nil, nil, nil
    local paths = opts.paths and vim.deepcopy(opts.paths) or {}
    local rev, range
    local after_dashes = false
    for _, w in ipairs(opts.args or {}) do
        if w == "--" then
            after_dashes = true
        elseif after_dashes then
            paths[#paths + 1] = w
        elseif w:find("%.%.") then
            range = w
        elseif not rev then
            rev = w
        end
    end
    range = opts.range or range
    rev = opts.rev or rev
    if range then
        state.scope, state.range = "range", range
        -- `...` (merge-base) is approximated as `..` for the base/new blobs (base A, new B).
        local a, _dots, b = range:match("^(.-)(%.%.%.?)(.*)$")
        state.a = (a and a ~= "" and a) or "HEAD"
        state.b = (b and b ~= "" and b) or "HEAD"
    elseif rev then
        state.scope, state.rev = "rev", rev
    else
        state.scope = "working"
    end
    state.paths = #paths > 0 and paths or nil
end

--- Whether the current scope stages (only the worktree-vs-index working scope does).
---@return boolean
local function is_stageable()
    return state.scope == "working"
end

-- ── file list ────────────────────────────────────────────────────────────────

--- Load the changed-file set for the scope via `backend.diff_tree`. `cb(entries)`.
---@param cb fun(entries: StatusEntry[])
local function load_files(cb)
    local opts = { root_or_buf = state.root, paths = state.paths }
    if state.scope == "range" then
        opts.range = state.range
    elseif state.scope == "rev" then
        opts.rev = state.rev
    end
    backend.diff_tree(opts, function(entries)
        cb(entries or {})
    end)
end

-- ── per-file diff text (respecting the diff transient) ──────────────────────────

--- Fetch the file diff header + hunks for `path` (with the active diff options). `cb({header, hunks})`.
---@param path string
---@param cb fun(diff: { header: string, hunks: DiffHunk[] })
local function fetch_file_diff(path, cb)
    local argv = { "diff", "--no-color", "-M" }
    vim.list_extend(argv, diff_options())
    if state.scope == "range" then
        argv[#argv + 1] = state.range
    elseif state.scope == "rev" then
        argv[#argv + 1] = state.rev
    end
    argv[#argv + 1] = "--"
    argv[#argv + 1] = path
    backend.output(state.root, git_argv(argv), function(out)
        local body
        for _, b in pairs(backend.split_files(out or "")) do
            body = b
            break
        end
        if not body then
            cb({ header = "", hunks = {} })
            return
        end
        local header_lines = {}
        for line in (body .. "\n"):gmatch("(.-)\n") do
            if line:match("^@@") then
                break
            end
            header_lines[#header_lines + 1] = line
        end
        cb({ header = table.concat(header_lines, "\n"), hunks = backend.parse_unified(body) })
    end)
end

-- ── base / new side content (for the split + inline buffers) ────────────────────

--- The BASE-side line array for `path` under the scope. `cb(lines)`.
---@param path string
---@param cb fun(lines: string[])
local function base_lines(path, cb)
    local rev
    if state.scope == "range" then
        rev = state.a or "HEAD"
    elseif state.scope == "rev" then
        rev = state.rev or "HEAD"
    else
        rev = ":0" -- the index blob (working scope)
    end
    backend.blob({ root_or_buf = state.root, path = path, rev = rev }, function(lines)
        cb(lines or {})
    end)
end

--- The NEW-side line array for `path` under the scope. `cb(lines)`.
---@param path string
---@param cb fun(lines: string[])
local function new_lines(path, cb)
    if state.scope == "range" then
        backend.blob({ root_or_buf = state.root, path = path, rev = state.b or "HEAD" }, function(lines)
            cb(lines or {})
        end)
    else
        -- working / rev scope → the working-tree file on disk.
        local abs = state.root .. "/" .. path
        local ok, fl = pcall(vim.fn.readfile, abs)
        cb((ok and fl) or {})
    end
end

-- ── scratch buffers + window plumbing ──────────────────────────────────────────

--- Create a throw-away scratch buffer filled with `lines`, its filetype set from `path` for syntax.
---@param lines string[]
---@param path string
---@return integer buf
local function scratch(lines, path)
    local buf = api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    local ft = vim.filetype.match({ filename = path, buf = buf }) or ""
    if ft ~= "" then
        vim.bo[buf].filetype = ft
    end
    vim.bo[buf].modifiable = false
    return buf
end

--- Wipe a buffer if it is still valid (scratch teardown).
---@param buf integer?
local function wipe(buf)
    if buf and api.nvim_buf_is_valid(buf) then
        pcall(api.nvim_buf_delete, buf, { force = true })
    end
end

--- Close the split / inline diff windows (kept between file loads; only torn down on close/mode change).
--- The container window is PARKED on a fresh empty buffer first, so wiping the old diff buffers (one of
--- which is displayed IN the container) cannot close the container window out from under us.
local function tear_diff_windows()
    if state.container and api.nvim_win_is_valid(state.container) then
        local park = api.nvim_create_buf(false, true)
        vim.bo[park].bufhidden = "wipe"
        pcall(api.nvim_win_set_buf, state.container, park)
    end
    for _, w in ipairs({ state.win_base, state.win_work, state.win_inline }) do
        if w and api.nvim_win_is_valid(w) and w ~= state.container then
            pcall(api.nvim_win_close, w, true)
        end
    end
    wipe(state.buf_base)
    wipe(state.buf_work)
    wipe(state.buf_inline)
    state.win_base, state.win_work, state.buf_base, state.buf_work = nil, nil, nil, nil
    state.win_inline, state.buf_inline = nil, nil
end

--- Announce that a changed file finished rendering, so an overlay consumer (a sibling review layer) can
--- (re)anchor its extmarks on the now-valid diff buffers. Carries the file path + the per-mode buffers.
local function emit_file_loaded()
    if not (state.root and state.current) then
        return
    end
    api.nvim_exec_autocmds("User", {
        pattern = "LvimGitDiffFileLoaded",
        data = {
            root = state.root,
            vcs = state.vcs,
            path = state.current,
            mode = state.mode,
            buf_base = state.buf_base,
            buf_work = state.buf_work,
            buf_inline = state.buf_inline,
        },
    })
end

-- ── diffopt (native diff engine tuning while the split view is open) ────────────

--- Set the global `diffopt` for a clean two-tier `diffthis` (internal engine + linematch char spans),
--- honouring the whitespace switches. Saves the previous value once (restored on close).
local function apply_diffopt()
    if state.saved_diffopt == nil then
        state.saved_diffopt = vim.o.diffopt
    end
    local parts = { "internal", "filler", "closeoff", "algorithm:histogram", "linematch:60" }
    local args = diff_options()
    if vim.tbl_contains(args, "--ignore-all-space") then
        parts[#parts + 1] = "iwhiteall"
    elseif vim.tbl_contains(args, "--ignore-space-change") then
        parts[#parts + 1] = "iwhite"
    end
    vim.o.diffopt = table.concat(parts, ",")
end

--- Per-window `winhighlight` for a diff side: line wash + (when char_level) the deep char tier. The
--- base (left) window paints its unique/changed lines as DELETIONS, the work (right) window as ADDITIONS.
---@param side "base"|"work"
---@return string
local function diff_winhl(side)
    local line = side == "base" and "LvimGitDiffDelete" or "LvimGitDiffAdd"
    local text = config.diffview.char_level == false and line
        or (side == "base" and "LvimGitDiffDeleteText" or "LvimGitDiffAddText")
    return table.concat({
        "DiffAdd:" .. line,
        "DiffChange:" .. line,
        "DiffText:" .. text,
        "DiffDelete:LvimGitDiffFill",
    }, ",")
end

-- ── SPLIT render ───────────────────────────────────────────────────────────────

--- Build the side-by-side split for the current file: base (left) + new (right) scratch buffers with
--- real `diffthis`, the per-side char-tier winhighlight, and the diff keymaps.
---@param bl string[]  base-side lines
---@param nl string[]  new-side lines
local function render_split(bl, nl)
    tear_diff_windows()
    apply_diffopt()
    if not (state.container and api.nvim_win_is_valid(state.container)) then
        return
    end
    api.nvim_set_current_win(state.container)
    state.buf_base = scratch(bl, state.current or "base")
    state.buf_work = scratch(nl, state.current or "work")
    api.nvim_win_set_buf(state.container, state.buf_base)
    state.win_base = state.container
    vim.cmd("rightbelow vsplit")
    state.win_work = api.nvim_get_current_win()
    api.nvim_win_set_buf(state.win_work, state.buf_work)

    for side, win in pairs({ base = state.win_base, work = state.win_work }) do
        api.nvim_win_call(win, function()
            vim.cmd("diffthis")
        end)
        vim.wo[win].winhighlight = diff_winhl(side)
        vim.wo[win].winfixwidth = false
    end
    wire_diff_keys(state.buf_base)
    wire_diff_keys(state.buf_work)
    -- Land on the work (new) side — the side you stage from.
    if api.nvim_win_is_valid(state.win_work) then
        api.nvim_set_current_win(state.win_work)
    end
    emit_file_loaded()
end

-- ── INLINE render ────────────────────────────────────────────────────────────

--- The differing intra-line span of two strings via common prefix/suffix trim (the gitsigns word-diff
--- fallback). Returns the 0-based byte range on the NEW string that changed (nil when identical).
---@param a string  old line
---@param b string  new line
---@return integer? start_col, integer? end_col
local function intra_span(a, b)
    if a == b then
        return nil
    end
    local la, lb = #a, #b
    local p = 0
    while p < la and p < lb and a:byte(p + 1) == b:byte(p + 1) do
        p = p + 1
    end
    local s = 0
    while s < (la - p) and s < (lb - p) and a:byte(la - s) == b:byte(lb - s) do
        s = s + 1
    end
    return p, lb - s
end

--- Build the inline view for the current file: the new-side content in one scratch buffer, deletions as
--- red `virt_lines` above their position, additions/changes tinted (with an intra-line char tint on
--- changed pairs). This is the vgit/codediff single-block look (no native diff engine → spans computed).
---@param nl string[]  new-side lines
local function render_inline(nl)
    tear_diff_windows()
    if not (state.container and api.nvim_win_is_valid(state.container)) then
        return
    end
    state.buf_inline = scratch(nl, state.current or "inline")
    api.nvim_win_set_buf(state.container, state.buf_inline)
    state.win_inline = state.container
    local ns = state.ns
    api.nvim_buf_clear_namespace(state.buf_inline, ns, 0, -1)

    for _, h in ipairs((state.diff and state.diff.hunks) or {}) do
        local new_ln = h.new_start -- 1-based new-side line the next +/context sits on
        local pending_del = {} ---@type string[]  deletions awaiting their anchor
        local function flush_dels(anchor0)
            if #pending_del == 0 then
                return
            end
            local virt = {}
            for _, d in ipairs(pending_del) do
                virt[#virt + 1] = { { "  " .. d, "LvimGitDiffDelete" } }
            end
            pcall(api.nvim_buf_set_extmark, state.buf_inline, ns, math.max(0, anchor0), 0, {
                virt_lines = virt,
                virt_lines_above = true,
            })
            pending_del = {}
        end
        for _, l in ipairs(h.lines) do
            if l.kind == "context" then
                flush_dels(new_ln - 1)
                new_ln = new_ln + 1
            elseif l.kind == "del" then
                pending_del[#pending_del + 1] = l.text
            else -- add
                local row0 = new_ln - 1
                -- paired deletion → intra-line char tint on the changed span; else a whole-line add wash.
                local paired = table.remove(pending_del, 1)
                pcall(api.nvim_buf_set_extmark, state.buf_inline, ns, row0, 0, {
                    line_hl_group = "LvimGitDiffAdd",
                })
                if paired then
                    local sc, ec = intra_span(paired, l.text)
                    if sc and ec and ec > sc then
                        pcall(api.nvim_buf_set_extmark, state.buf_inline, ns, row0, sc, {
                            end_col = math.min(ec, #l.text),
                            hl_group = "LvimGitDiffAddText",
                        })
                    end
                    -- a leftover of the deletion (longer than the addition) still shows as a virt line.
                    pcall(api.nvim_buf_set_extmark, state.buf_inline, ns, row0, 0, {
                        virt_lines = { { { "  " .. paired, "LvimGitDiffDelete" } } },
                        virt_lines_above = true,
                    })
                end
                new_ln = new_ln + 1
            end
        end
        flush_dels(new_ln - 1)
    end
    wire_diff_keys(state.buf_inline)
    if api.nvim_win_is_valid(state.win_inline) then
        api.nvim_set_current_win(state.win_inline)
    end
    emit_file_loaded()
end

-- ── file load (drives the diff windows) ─────────────────────────────────────────

--- Load `path` into the diff windows in the active mode. Guards against a stale async result via a
--- monotonic token (rapid file navigation in the files panel).
---@param path string
local function load_file(path)
    if not path then
        return
    end
    state.current = path
    state.load_token = (state.load_token or 0) + 1
    local token = state.load_token
    fetch_file_diff(path, function(diff)
        if token ~= state.load_token then
            return
        end
        state.diff = diff
        if state.mode == "inline" then
            new_lines(path, function(nl)
                if token ~= state.load_token then
                    return
                end
                render_inline(nl)
            end)
        else
            base_lines(path, function(bl)
                if token ~= state.load_token then
                    return
                end
                new_lines(path, function(nl)
                    if token ~= state.load_token then
                        return
                    end
                    render_split(bl, nl)
                end)
            end)
        end
    end)
end

--- Re-render the CURRENT file (after a diff-option change or a mode toggle).
function M.reload()
    if state.current then
        load_file(state.current)
    end
end

--- PUBLIC (overlay seam): load a SPECIFIC changed file into the diff (the file-list order the panel uses),
--- keeping the files-panel selection in sync. A sibling review layer calls this to jump the diff to the file
--- holding the next/prev thread. Returns false when the diffview is closed or `path` is not in the change set.
---@param path string
---@return boolean shown
function M.show_file(path)
    if not (M.is_open() and type(path) == "string" and path ~= "") then
        return false
    end
    local idx
    for i, e in ipairs(state.files or {}) do
        if e.path == path then
            idx = i
            break
        end
    end
    if not idx then
        return false
    end
    load_file(path)
    -- Keep the files-panel highlight on the shown file (its on_move no-ops since state.current == path now).
    local tw = state.files_tree
    if tw and tw.win and tw.win() and api.nvim_win_is_valid(tw.win()) then
        pcall(api.nvim_win_set_cursor, tw.win(), { idx, 0 })
    end
    return true
end

--- Toggle split ⇄ inline and re-render the current file.
local function toggle_mode()
    state.mode = state.mode == "split" and "inline" or "split"
    M.reload()
end

-- ── staging from within the diff ────────────────────────────────────────────────

--- Annotate a hunk's lines with their new-side line numbers (for cursor→line-range mapping + patches).
---@param hunk DiffHunk
---@return { kind: string, text: string, new_ln: integer? }[]
local function annotate(hunk)
    local out = {}
    local new_ln = hunk.new_start
    for _, l in ipairs(hunk.lines) do
        if l.kind == "context" then
            out[#out + 1] = { kind = "context", text = l.text, new_ln = new_ln }
            new_ln = new_ln + 1
        elseif l.kind == "add" then
            out[#out + 1] = { kind = "add", text = l.text, new_ln = new_ln }
            new_ln = new_ln + 1
        else -- del: anchored at the new-side line it precedes
            out[#out + 1] = { kind = "del", text = l.text, new_ln = new_ln }
        end
    end
    return out
end

--- The hunk covering the new-side line `lnum` (cursor line in the work/inline window), or nil.
---@param lnum integer
---@return DiffHunk?
local function hunk_at_line(lnum)
    for _, h in ipairs((state.diff and state.diff.hunks) or {}) do
        local lo = h.new_start
        local hi = h.new_start + math.max(h.new_count, 1) - 1
        if lnum >= lo and lnum <= hi then
            return h
        end
    end
    return nil
end

--- Build the patch a hunk (optionally a NEW-side line sub-range [lo,hi]) stages as. Unselected added
--- lines are dropped; unselected deletions become context; counts recomputed. Whole-hunk (no range)
--- keeps every line verbatim.
---@param hunk DiffHunk
---@param lo integer?  first selected new-side line (nil = whole hunk)
---@param hi integer?  last selected new-side line
---@return string? patch
local function build_patch(hunk, lo, hi)
    local all = lo == nil
    local ann = annotate(hunk)
    local body, old_count, new_count = {}, 0, 0
    for _, l in ipairs(ann) do
        if l.kind == "context" then
            body[#body + 1] = " " .. l.text
            old_count = old_count + 1
            new_count = new_count + 1
        elseif l.kind == "add" then
            if all or (l.new_ln >= lo and l.new_ln <= hi) then
                body[#body + 1] = "+" .. l.text
                new_count = new_count + 1
            end -- unselected add → dropped
        else -- del
            if all or (l.new_ln >= lo and l.new_ln <= hi) then
                body[#body + 1] = "-" .. l.text
                old_count = old_count + 1
            else -- unselected del → keep the line (context)
                body[#body + 1] = " " .. l.text
                old_count = old_count + 1
                new_count = new_count + 1
            end
        end
    end
    -- Nothing to stage (selection touched no +/- line).
    local touched = false
    for _, b in ipairs(body) do
        if b:sub(1, 1) ~= " " then
            touched = true
            break
        end
    end
    if not touched then
        return nil
    end
    local path = state.current
    local hdr = ("@@ -%d,%d +%d,%d @@"):format(hunk.old_start, old_count, hunk.old_start, new_count)
    local parts = {
        ("diff --git a/%s b/%s"):format(path, path),
        "--- a/" .. path,
        "+++ b/" .. path,
        hdr,
    }
    vim.list_extend(parts, body)
    return table.concat(parts, "\n") .. "\n"
end

--- Run a git mutation; on success fire `LvimGitRepoChanged` (signs + panels refresh) + reload the view.
---@param extra string[]
---@param stdin string
local function run_git(extra, stdin)
    backend.system(state.root, git_argv(extra), { stdin = stdin }, function(res)
        if res.code ~= 0 then
            notify("git " .. (extra[1] or "") .. " failed: " .. vim.trim(res.stderr or ""), vim.log.levels.ERROR)
            return
        end
        vim.schedule(function()
            vim.cmd("checktime")
            api.nvim_exec_autocmds("User", {
                pattern = "LvimGitRepoChanged",
                data = { root = state.root, vcs = state.vcs, reason = extra[1] },
            })
        end)
    end)
end

--- Stage / discard the hunk under the cursor, or a visual-line region of it (true line-level sub-hunk).
---@param op "stage"|"discard"
---@param region? { lo: integer, hi: integer }  a NEW-side line range (visual selection)
local function apply_at_cursor(op, region)
    if not is_stageable() then
        notify("staging is only available in the working-tree diff", vim.log.levels.WARN)
        return
    end
    local win = api.nvim_get_current_win()
    local lnum = api.nvim_win_get_cursor(win)[1]
    local hunk = hunk_at_line(region and region.lo or lnum)
    if not hunk then
        notify("no hunk under the cursor")
        return
    end
    local patch = build_patch(hunk, region and region.lo, region and region.hi)
    if not patch then
        notify("nothing to " .. op .. " in the selection")
        return
    end
    if op == "stage" then
        run_git({ "apply", "--cached", "--whitespace=nowarn", "-" }, patch)
    else
        local function go()
            run_git({ "apply", "-R", "--whitespace=nowarn", "-" }, patch)
        end
        if config.confirm_destructive then
            ui.confirm({
                prompt = "Discard this change?",
                callback = function(yes)
                    if yes then
                        go()
                    end
                end,
            })
        else
            go()
        end
    end
end

--- Stage / discard the visual-line region (new-side line range the selection spans).
---@param op "stage"|"discard"
local function apply_region(op)
    api.nvim_feedkeys(api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
    local buf = api.nvim_get_current_buf()
    local lo = api.nvim_buf_get_mark(buf, "<")[1]
    local hi = api.nvim_buf_get_mark(buf, ">")[1]
    if lo > hi then
        lo, hi = hi, lo
    end
    apply_at_cursor(op, { lo = lo, hi = hi })
end

-- ── hunk / file navigation ────────────────────────────────────────────────────

--- Jump the cursor to the next / prev hunk (native `]c`/`[c` in split diff mode; computed inline).
---@param dir integer  1 forward, -1 backward
local function nav_hunk(dir)
    if state.mode == "split" then
        vim.cmd("normal! " .. (dir > 0 and "]c" or "[c"))
        return
    end
    local lnum = api.nvim_win_get_cursor(0)[1]
    local anchors = {}
    for _, h in ipairs((state.diff and state.diff.hunks) or {}) do
        anchors[#anchors + 1] = h.new_start
    end
    table.sort(anchors)
    local target
    if dir > 0 then
        for _, a in ipairs(anchors) do
            if a > lnum then
                target = a
                break
            end
        end
        target = target or anchors[1]
    else
        for i = #anchors, 1, -1 do
            if anchors[i] < lnum then
                target = anchors[i]
                break
            end
        end
        target = target or anchors[#anchors]
    end
    if target then
        pcall(api.nvim_win_set_cursor, 0, { target, 0 })
    end
end

--- Move the files-panel cursor to the next / prev file (`]f`/`[f` from a diff window).
---@param dir integer
local function nav_file(dir)
    local tw = state.files_tree
    if not (tw and tw.win and tw.win() and api.nvim_win_is_valid(tw.win())) then
        return
    end
    local w = tw.win()
    local n = api.nvim_buf_line_count(api.nvim_win_get_buf(w))
    local cur = api.nvim_win_get_cursor(w)[1]
    pcall(api.nvim_win_set_cursor, w, { math.min(n, math.max(1, cur + dir)), 0 })
    -- moving the cursor there fires the tree's on_move → loads that file.
    api.nvim_set_current_win(w)
end

-- ── the help window (canonical cheatsheet) ─────────────────────────────────────

--- The diffview keymap cheatsheet through the shared `lvim-ui.help` component.
local function show_help()
    ui.help({
        title = "Git Diffview keymaps",
        items = {
            { "j / k", "next / previous changed file (files panel)" },
            { "<CR>", "focus the diff (from the files panel)" },
            { "]c / [c", "next / previous hunk" },
            { "]f / [f", "next / previous file (from a diff window)" },
            { "s", "stage the hunk / the visual-line region" },
            { "x", "discard the hunk / the region (confirm)" },
            { "u", "unstage the current file" },
            { "t", "toggle split ⇄ inline" },
            { "D", "diff options (context / whitespace / algorithm)" },
            { "<C-w>", "move between the files panel and the diff windows" },
            { "?", "dispatch (all commands)" },
            { "q", "close the diffview" },
        },
        close_keys = { "q", "<Esc>" },
    })
end

-- ── diff-window keymaps ────────────────────────────────────────────────────────

--- Wire the buffer-local keys on a diff window buffer (stage/discard/nav/toggle/help/close).
---@param buf integer
wire_diff_keys = function(buf)
    if not (buf and api.nvim_buf_is_valid(buf)) then
        return
    end
    local function map(mode, lhs, fn, desc)
        vim.keymap.set(mode, lhs, fn, { buffer = buf, nowait = true, silent = true, desc = "lvim-git: " .. desc })
    end
    map("n", "s", function()
        apply_at_cursor("stage")
    end, "stage hunk")
    map("n", "x", function()
        apply_at_cursor("discard")
    end, "discard hunk")
    map("x", "s", function()
        apply_region("stage")
    end, "stage region")
    map("x", "x", function()
        apply_region("discard")
    end, "discard region")
    map("n", "u", function()
        if is_stageable() and state.current then
            run_git({ "restore", "--staged", "--", state.current }, "")
            notify("unstaged " .. state.current .. " (whole file)")
        else
            notify("nothing to unstage here")
        end
    end, "unstage file")
    map("n", "]c", function()
        nav_hunk(1)
    end, "next hunk")
    map("n", "[c", function()
        nav_hunk(-1)
    end, "prev hunk")
    map("n", "]f", function()
        nav_file(1)
    end, "next file")
    map("n", "[f", function()
        nav_file(-1)
    end, "prev file")
    map("n", "t", toggle_mode, "toggle split/inline")
    map("n", "D", open_diff_transient, "diff options")
    map("n", "?", function()
        require("lvim-git.ui.dispatch").open()
    end, "dispatch")
    map("n", "g?", show_help, "help")
    map("n", "q", M.close, "close diffview")
end

-- ── the files panel (native docked surface + lvim-ui.tree) ──────────────────────

--- Build the tree nodes from the changed-file set (icon + dimmed dir / bright name + status badge).
---@return table[]  lvim-ui.tree nodes
local function file_nodes()
    local nodes = {}
    for _, e in ipairs(state.files or {}) do
        local base = vim.fs.basename(e.path)
        local ico = iconlib.get(base) or {}
        local label = e.path
        if e.renamed and e.orig_path then
            label = e.orig_path .. " " .. GLYPH.arrow .. " " .. e.path
        end
        local letter = (e.code or "?"):sub(1, 1)
        local badge_hl = ({
            A = "LvimGitDiffAdd",
            M = "LvimGitSignChange",
            D = "LvimGitDiffDelete",
            R = "LvimGitRefBranch",
            C = "LvimGitRefBranch",
        })[letter] or "LvimUiPathDim"
        nodes[#nodes + 1] = {
            id = e.path,
            label = label,
            icon = (ico.glyph ~= "" and ico.glyph) or GLYPH.file,
            icon_hl = (ico.hl and ico.hl ~= "") and ico.hl or "LvimUiPathName",
            label_hl = "LvimUiPathName",
            data = e,
            badges = { { letter, badge_hl } },
        }
    end
    return nodes
end

--- The repo band winbar for the files panel: branch ➤ scope.
---@return string
local function panel_title()
    local repo = backend.repo(state.root)
    local branch = (repo and repo.branch) or "detached"
    local scope = state.scope == "range" and state.range or (state.scope == "rev" and state.rev or "working tree")
    return (branch .. "  " .. GLYPH.arrow .. "  " .. scope):upper()
end

--- Repopulate the files tree from the current model, keeping the selection where possible.
local function refresh_files()
    if not state.files_tree then
        return
    end
    state.files_tree.set_root(file_nodes())
end

--- Open the native docked files panel (left), plugging in the lvim-ui.tree content provider.
local function open_files_panel()
    local tw = ui.tree({
        default_expanded = true,
        filetype = FILES_FT,
        cursorline = true,
        empty = " No changes",
        size = function()
            return math.max(28, math.floor(vim.o.columns * 0.22)), 1
        end,
        root = file_nodes(),
        on_move = function(node)
            if node and node.id and node.id ~= state.current then
                load_file(node.id)
            end
        end,
        on_activate = function(node)
            if node and node.id then
                load_file(node.id)
                -- jump into the diff to stage / navigate.
                local w = state.win_work or state.win_inline
                if w and api.nvim_win_is_valid(w) then
                    api.nvim_set_current_win(w)
                end
            end
        end,
        on_keys = function(map, pan)
            state.files_win = pan.win
            map("s", function()
                local n = state.files_tree and state.files_tree.selected()
                if n and n.id and is_stageable() then
                    run_git({ "add", "--", n.id }, "")
                    notify("staged " .. n.id)
                else
                    notify("staging is only available in the working-tree diff", vim.log.levels.WARN)
                end
            end)
            map("u", function()
                local n = state.files_tree and state.files_tree.selected()
                if n and n.id and is_stageable() then
                    run_git({ "restore", "--staged", "--", n.id }, "")
                    notify("unstaged " .. n.id)
                end
            end)
            map("t", toggle_mode)
            map("D", open_diff_transient)
            map("?", function()
                require("lvim-git.ui.dispatch").open()
            end)
            map("g?", show_help)
        end,
    })
    state.files_tree = tw
    state.files_handle = surface.open({
        mode = "split",
        native = true,
        dock = "left",
        enter = false,
        persistent = true,
        normal_hl = "NormalSB",
        title = { icon = GLYPH.diff, text = "Diffview" },
        size = { width = { fixed = math.max(28, math.floor(vim.o.columns * 0.22)) } },
        content = { blocks = { { id = "files", provider = tw.provider } } },
        close_keys = {},
        footer = {
            bars = {
                {
                    align = "center",
                    items = {
                        surface.button({ name = "help", key = "g?", style = "action", run = show_help }, "action"),
                        surface.button({
                            name = "close",
                            key = "q",
                            style = "action",
                            run = function()
                                M.close()
                            end,
                        }, "action"),
                    },
                },
            },
        },
        on_close = function()
            state.files_handle = nil
            state.files_tree = nil
            state.files_win = nil
        end,
    })
    state.files_win = state.files_tree and state.files_tree.win and state.files_tree.win()
    -- The panel winbar carries the repo band (native mode has no header bars).
    if state.files_win and api.nvim_win_is_valid(state.files_win) then
        pcall(function()
            vim.wo[state.files_win].winbar = "%#LvimGitRefHead# " .. GLYPH.git .. " " .. panel_title()
        end)
    end
end

-- ── autocmds ───────────────────────────────────────────────────────────────────

--- Refresh the files list + the current diff on any repo mutation (our staging ops + external drift).
local function setup_autocmds()
    if state.augroup then
        pcall(api.nvim_del_augroup_by_id, state.augroup)
    end
    state.augroup = api.nvim_create_augroup("lvim-git.diff", { clear = true })
    api.nvim_create_autocmd("User", {
        group = state.augroup,
        pattern = "LvimGitRepoChanged",
        callback = function()
            if not M.is_open() then
                return
            end
            load_files(function(entries)
                state.files = entries
                refresh_files()
                if state.current then
                    -- the current file may have dropped out of the changed set after a full stage.
                    local still = false
                    for _, e in ipairs(entries) do
                        if e.path == state.current then
                            still = true
                            break
                        end
                    end
                    if still then
                        M.reload()
                    elseif entries[1] then
                        load_file(entries[1].path)
                    end
                end
            end)
        end,
    })
end

-- ── open / close ───────────────────────────────────────────────────────────────

--- Tear down all diffview state (windows, buffers, autocmds, diffopt).
local function teardown()
    if state.augroup then
        pcall(api.nvim_del_augroup_by_id, state.augroup)
        state.augroup = nil
    end
    tear_diff_windows()
    if state.saved_diffopt ~= nil then
        vim.o.diffopt = state.saved_diffopt
        state.saved_diffopt = nil
    end
    api.nvim_exec_autocmds("User", {
        pattern = "LvimGitDiffClose",
        data = { root = state.root, rev = state.rev, range = state.range },
    })
    state.tab, state.container, state.files_handle, state.files_tree, state.files_win = nil, nil, nil, nil, nil
    state.current, state.diff, state.files = nil, nil, nil
end

--- Close the diffview (its tabpage + all its windows), returning to the origin tab.
function M.close()
    if not M.is_open() then
        return
    end
    local tab = state.tab
    if state.files_handle and state.files_handle.close then
        pcall(state.files_handle.close)
    end
    teardown()
    if tab and api.nvim_tabpage_is_valid(tab) then
        -- close the whole diffview tabpage; focus returns to the previous tab.
        pcall(function()
            api.nvim_set_current_tabpage(tab)
            vim.cmd("tabclose")
        end)
    end
    if state.origin_tab and api.nvim_tabpage_is_valid(state.origin_tab) then
        pcall(api.nvim_set_current_tabpage, state.origin_tab)
    end
    state.origin_tab, state.origin_win = nil, nil
end

--- Open the diffview in its dedicated tabpage. `opts = { rev?, range?, paths?, mode?, layout?, lens?, args? }`.
---@param opts? table
function M.open(opts)
    opts = opts or {}
    if not config.diffview.enabled then
        notify("the diffview component is disabled (diffview.enabled = false)", vim.log.levels.WARN)
        return
    end
    local root, vcs = backend.detect(api.nvim_get_current_buf())
    if not root then
        notify("not inside a git repository", vim.log.levels.WARN)
        return
    end
    if M.is_open() then
        M.close()
    end
    if not registered then
        registered = true
        cursor.register({ panel_ft = { FILES_FT } })
        ensure_transient()
    end
    state.root, state.vcs = root, opts.lens or vcs
    state.mode = opts.mode or config.diffview.mode or "split"
    state.diff_args = nil
    -- The diffview inherently needs REAL windows for `diffthis`, so it opens its own tabpage regardless
    -- of the layout token (the phase-12 workspace host will honour area/float/bottom later).
    local _ = commands.layout_for("diffview", opts.layout)
    resolve_scope(opts)
    state.origin_tab = api.nvim_get_current_tabpage()
    state.origin_win = api.nvim_get_current_win()

    load_files(function(entries)
        state.files = entries
        vim.cmd("tabnew")
        state.tab = api.nvim_get_current_tabpage()
        state.container = api.nvim_get_current_win()
        state.ns = state.ns or api.nvim_create_namespace("lvim-git.diff.inline")
        -- a throwaway buffer so the container is not the [No Name] the split/inline replaces
        api.nvim_win_set_buf(state.container, api.nvim_create_buf(false, true))
        open_files_panel()
        setup_autocmds()
        api.nvim_exec_autocmds("User", {
            pattern = "LvimGitDiffOpen",
            data = { root = state.root, rev = state.rev, range = state.range },
        })
        if entries[1] then
            load_file(entries[1].path)
        end
        -- start in the files panel (browse the change set).
        vim.schedule(function()
            if state.files_win and api.nvim_win_is_valid(state.files_win) then
                api.nvim_set_current_win(state.files_win)
            end
        end)
    end)
end

--- Toggle the diffview.
---@param opts? table
function M.toggle(opts)
    if M.is_open() then
        M.close()
    else
        M.open(opts)
    end
end

return M
