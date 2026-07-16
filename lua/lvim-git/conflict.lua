-- lvim-git.conflict: merge-conflict resolution — the marker engine (git `<<<<<<< ======= >>>>>>>`,
-- with the optional diff3 `|||||||` base), the IN-BUFFER choose/nav ops, and the 3-block MERGE VIEW.
-- A decoupled COMPONENT over the shared core (backend / config / highlights), standalone
-- (`:LvimGit conflict` + the status conflicted section route here).
--
-- Two independent surfaces over ONE marker parser:
--   * IN-BUFFER — while a real file buffer holds conflict markers, buffer-local `]x`/`[x` navigate the
--     conflicts and `co`/`ct`/`cb`/`cB`/`cn` resolve the region under the cursor (ours / theirs / both /
--     keep-base / none); `Co`/`Ct` take the WHOLE file from ours / theirs (`git checkout --ours/--theirs`).
--     Conflict regions are washed with the `LvimGitConflict*` groups. Auto-attaches on read, detaches when
--     the markers are gone. `LvimGitConflicts { root, count }` fires as conflicts appear / clear.
--   * The 3-block MERGE VIEW — a dedicated TABPAGE of REAL windows (the diffview's model; a `diffthis`
--     3-way needs real windows, never a float): OURS | RESULT | THEIRS (+ an optional BASE column per
--     `diffview.base_block`), each `diffthis` for alignment. RESULT is the real editable working file — the
--     user assembles the resolution there with the same choose/nav ops, then `<C-c><C-c>` marks it resolved
--     (`git add`). OURS/THEIRS/BASE are read-only blobs from the index stages (`:2:`/`:3:`/`:1:`).
--
-- The marker parser + the per-hunk resolution are PURE (`M.parse_markers` / `M.resolve_body`,
-- headless-tested). WHY stages not branch tips: the working stages (`:1:`/`:2:`/`:3:`) are exactly what
-- git recorded for THIS conflict, rename-aware and correct for a rebase/cherry-pick as well as a merge.
--
-- PUBLIC: open / conflicts(root) (feeds `LvimGitConflicts`). Internal otherwise.
--
---@module "lvim-git.conflict"

local api = vim.api
local config = require("lvim-git.config")
local backend = require("lvim-git.backend")
local ui = require("lvim-ui")

local M = {}

-- ── glyphs (verified single-width Nerd Font, + the `➤` pointer canon) ──────────
local GLYPH = {
    merge = "\u{e727}", --  nf-dev-git_merge (title)
    git = "\u{e725}", --  nf-dev-git_branch (winbars)
    arrow = "➤", -- the pointer canon
}

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

-- ── the marker parser (PURE) ────────────────────────────────────────────────────

---@class LvimGitConflictRange
---@field lo integer  first body line (1-based, inclusive)
---@field hi integer  last body line (inclusive; hi < lo = an empty side)

---@class LvimGitConflictHunk
---@field start   integer                 the `<<<<<<<` line (1-based)
---@field finish  integer                 the `>>>>>>>` line
---@field ours    LvimGitConflictRange
---@field base?   LvimGitConflictRange    present only for a diff3 (`|||||||`) conflict
---@field theirs  LvimGitConflictRange
---@field mid     integer                 the `=======` line
---@field basemark? integer               the `|||||||` line (diff3)
---@field ours_label?   string
---@field base_label?   string
---@field theirs_label? string

--- Parse conflict markers out of a line array into hunks. Robust to the diff3 base block (`|||||||`)
--- and to empty sides. Non-conflict text between hunks is ignored. A malformed / unterminated marker
--- run is skipped (never throws).
---@param lines string[]
---@return LvimGitConflictHunk[]
function M.parse_markers(lines)
    ---@type LvimGitConflictHunk[]
    local hunks = {}
    local n = #lines
    local i = 1
    while i <= n do
        if lines[i]:match("^<<<<<<<") then
            local start = i
            local ours_label = lines[i]:match("^<<<<<<<%s*(.*)$")
            local basemark, mid, finish, base_label, theirs_label
            local j = i + 1
            while j <= n do
                local lj = lines[j]
                if lj:match("^|||||||") and not basemark and not mid then
                    basemark = j
                    base_label = lj:match("^|||||||%s*(.*)$")
                elseif lj:match("^=======%s*$") and not mid then
                    mid = j
                elseif lj:match("^>>>>>>>") then
                    finish = j
                    theirs_label = lj:match("^>>>>>>>%s*(.*)$")
                    break
                end
                j = j + 1
            end
            if mid and finish then
                local ours_hi = (basemark or mid) - 1
                ---@type LvimGitConflictHunk
                local h = {
                    start = start,
                    finish = finish,
                    mid = mid,
                    basemark = basemark,
                    ours = { lo = start + 1, hi = ours_hi },
                    theirs = { lo = mid + 1, hi = finish - 1 },
                    ours_label = ours_label,
                    base_label = base_label,
                    theirs_label = theirs_label,
                }
                if basemark then
                    h.base = { lo = basemark + 1, hi = mid - 1 }
                end
                hunks[#hunks + 1] = h
                i = finish + 1
            else
                i = i + 1
            end
        else
            i = i + 1
        end
    end
    return hunks
end

--- Slice a body range out of a line array ({} when the range is empty / nil).
---@param lines string[]
---@param range? LvimGitConflictRange
---@return string[]
local function slice(lines, range)
    local out = {}
    if not range then
        return out
    end
    for k = range.lo, range.hi do
        out[#out + 1] = lines[k]
    end
    return out
end

--- The replacement body a conflict hunk resolves to for a choice (PURE): ours / theirs / both
--- (ours-then-theirs) / base (keep the diff3 base) / none (drop the region entirely).
---@param lines string[]
---@param hunk LvimGitConflictHunk
---@param choice "ours"|"theirs"|"both"|"base"|"none"
---@return string[]
function M.resolve_body(lines, hunk, choice)
    if choice == "theirs" then
        return slice(lines, hunk.theirs)
    elseif choice == "both" then
        local out = slice(lines, hunk.ours)
        vim.list_extend(out, slice(lines, hunk.theirs))
        return out
    elseif choice == "base" then
        return slice(lines, hunk.base)
    elseif choice == "none" then
        return {}
    end
    return slice(lines, hunk.ours) -- "ours" (default)
end

-- ── buffer <-> repo resolution ──────────────────────────────────────────────────

--- Resolve a buffer to its repo root + repo-relative path + vcs (nil when not a real file in a repo).
---@param buf integer
---@return string? root, string? rel, string? vcs
local function buf_repo(buf)
    if not (buf and api.nvim_buf_is_valid(buf)) then
        return nil, nil, nil
    end
    local name = api.nvim_buf_get_name(buf)
    if name == "" or name:match("^%w+://") then
        return nil, nil, nil
    end
    local root, vcs = backend.detect(buf)
    if not root then
        return nil, nil, nil
    end
    local abs = vim.fs.normalize(vim.fn.fnamemodify(name, ":p"))
    local rel = abs:gsub("^" .. vim.pesc(root) .. "/", "")
    return root, rel, vcs
end

--- Whether a buffer currently holds any conflict marker (a bounded scan of its lines).
---@param buf integer
---@return boolean
local function has_markers(buf)
    if not (buf and api.nvim_buf_is_valid(buf)) then
        return false
    end
    for _, l in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
        if l:match("^<<<<<<<") then
            return true
        end
    end
    return false
end

-- ── conflict-region washes ──────────────────────────────────────────────────────

---@type integer  the extmark namespace for the conflict washes
local ns = api.nvim_create_namespace("lvim-git.conflict")

---@type table<integer, boolean>  buffers with the conflict maps attached
local attached = {}

--- Repaint the conflict-region washes for a buffer: ours / base / theirs body lines get their tint, the
--- marker lines their red marker highlight. Returns the parsed hunks so callers can act on the count.
---@param buf integer
---@return LvimGitConflictHunk[]
local function render_washes(buf)
    api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
    local hunks = M.parse_markers(lines)
    ---@param lo integer  1-based first line
    ---@param hi integer  1-based last line
    ---@param group string
    local function wash(lo, hi, group)
        for l = lo, hi do
            pcall(api.nvim_buf_set_extmark, buf, ns, l - 1, 0, { line_hl_group = group, hl_eol = true })
        end
    end
    for _, h in ipairs(hunks) do
        wash(h.ours.lo, h.ours.hi, "LvimGitConflictOurs")
        if h.base then
            wash(h.base.lo, h.base.hi, "LvimGitConflictBase")
        end
        wash(h.theirs.lo, h.theirs.hi, "LvimGitConflictTheirs")
        for _, ml in ipairs({ h.start, h.basemark, h.mid, h.finish }) do
            if ml then
                pcall(api.nvim_buf_set_extmark, buf, ns, ml - 1, 0, {
                    line_hl_group = "LvimGitConflictMarker",
                    hl_eol = true,
                })
            end
        end
    end
    return hunks
end

-- ── in-buffer choose / navigate ──────────────────────────────────────────────────

--- The conflict hunk under (or containing) `lnum`, else the first hunk at/after it.
---@param hunks LvimGitConflictHunk[]
---@param lnum integer
---@return LvimGitConflictHunk?
local function hunk_at(hunks, lnum)
    for _, h in ipairs(hunks) do
        if lnum >= h.start and lnum <= h.finish then
            return h
        end
    end
    for _, h in ipairs(hunks) do
        if h.start >= lnum then
            return h
        end
    end
    return hunks[1]
end

--- Resolve the conflict under the cursor with `choice`, replacing the whole marker block with the chosen
--- body, then repaint. Fires `LvimGitConflicts` (and detaches) when the buffer is fully resolved.
---@param buf integer
---@param choice "ours"|"theirs"|"both"|"base"|"none"
local function choose(buf, choice)
    local win = api.nvim_get_current_win()
    local lnum = api.nvim_win_get_cursor(win)[1]
    local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
    local hunks = M.parse_markers(lines)
    if #hunks == 0 then
        notify("no conflict here")
        return
    end
    local h = hunk_at(hunks, lnum)
    if not h then
        return
    end
    local body = M.resolve_body(lines, h, choice)
    api.nvim_buf_set_lines(buf, h.start - 1, h.finish, false, body)
    local remaining = render_washes(buf)
    -- keep the cursor near the resolved region
    pcall(api.nvim_win_set_cursor, win, { math.max(1, math.min(h.start, api.nvim_buf_line_count(buf))), 0 })
    if #remaining == 0 then
        local root = buf_repo(buf)
        if root then
            api.nvim_exec_autocmds("User", { pattern = "LvimGitConflicts", data = { root = root, count = 0 } })
        end
        notify("all conflicts resolved — save + stage (`s` in status / `<C-c><C-c>` in the merge view)")
    end
end

--- Jump to the next / previous conflict marker.
---@param buf integer
---@param dir integer  1 forward, -1 backward
local function nav(buf, dir)
    local win = api.nvim_get_current_win()
    local lnum = api.nvim_win_get_cursor(win)[1]
    local hunks = M.parse_markers(api.nvim_buf_get_lines(buf, 0, -1, false))
    if #hunks == 0 then
        notify("no conflicts")
        return
    end
    local target
    if dir > 0 then
        for _, h in ipairs(hunks) do
            if h.start > lnum then
                target = h.start
                break
            end
        end
        target = target or hunks[1].start
    else
        for i = #hunks, 1, -1 do
            if hunks[i].start < lnum then
                target = hunks[i].start
                break
            end
        end
        target = target or hunks[#hunks].start
    end
    pcall(api.nvim_win_set_cursor, win, { target, 0 })
end

--- Take the WHOLE file from one side (`git checkout --ours/--theirs`), reload the buffer, and mark it
--- resolved by staging it. A worktree-mutating shortcut for a file you want entirely from one side.
---@param buf integer
---@param side "ours"|"theirs"
local function take_whole(buf, side)
    local root, rel, vcs = buf_repo(buf)
    if not (root and rel) then
        notify("not a tracked file in a repo", vim.log.levels.WARN)
        return
    end
    backend.system(root, git_argv({ "checkout", "--" .. side, "--", rel }), {}, function(res)
        if res.code ~= 0 then
            vim.schedule(function()
                notify("checkout --" .. side .. " failed: " .. vim.trim(res.stderr or ""), vim.log.levels.ERROR)
            end)
            return
        end
        require("lvim-git.actions").execute(root, { "add", "--", rel }, { op = "resolve", vcs = vcs, quiet = true })
        vim.schedule(function()
            vim.cmd("checktime")
            notify("took " .. side .. " for " .. rel .. " (staged)")
        end)
    end)
end

--- Wire the buffer-local conflict maps (choose / navigate / whole-file) on a real conflicted file buffer.
---@param buf integer
local function wire_buffer_keys(buf)
    local function map(lhs, fn, desc)
        vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = "lvim-git: " .. desc })
    end
    map("]x", function()
        nav(buf, 1)
    end, "next conflict")
    map("[x", function()
        nav(buf, -1)
    end, "prev conflict")
    map("co", function()
        choose(buf, "ours")
    end, "take ours")
    map("ct", function()
        choose(buf, "theirs")
    end, "take theirs")
    map("cb", function()
        choose(buf, "both")
    end, "take both (ours+theirs)")
    map("cB", function()
        choose(buf, "base")
    end, "keep base")
    map("cn", function()
        choose(buf, "none")
    end, "take neither")
    map("Co", function()
        take_whole(buf, "ours")
    end, "take whole file: ours")
    map("Ct", function()
        take_whole(buf, "theirs")
    end, "take whole file: theirs")
end

--- Remove the buffer-local conflict maps + washes.
---@param buf integer
local function unwire_buffer_keys(buf)
    for _, lhs in ipairs({ "]x", "[x", "co", "ct", "cb", "cB", "cn", "Co", "Ct" }) do
        pcall(vim.keymap.del, "n", lhs, { buffer = buf })
    end
end

--- Attach the in-buffer conflict maps + washes to `buf` (idempotent — repaints on a re-attach).
---@param buf integer
function M.attach(buf)
    if not (buf and api.nvim_buf_is_valid(buf)) then
        return
    end
    if not attached[buf] then
        wire_buffer_keys(buf)
        attached[buf] = true
        api.nvim_create_autocmd({ "InsertLeave", "TextChanged" }, {
            buffer = buf,
            group = api.nvim_create_augroup("lvim-git.conflict.buf." .. buf, { clear = true }),
            callback = function()
                if api.nvim_buf_is_valid(buf) then
                    render_washes(buf)
                end
            end,
        })
    end
    render_washes(buf)
end

--- Detach the in-buffer conflict maps + washes from `buf`.
---@param buf integer
function M.detach(buf)
    if not (buf and api.nvim_buf_is_valid(buf)) then
        return
    end
    pcall(api.nvim_del_augroup_by_name, "lvim-git.conflict.buf." .. buf)
    api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    unwire_buffer_keys(buf)
    attached[buf] = nil
end

--- Attach / detach the conflict maps for a buffer based on whether it currently holds markers. The
--- generic autocmd path (any conflicted file gets the ops, with or without the merge view).
---@param buf integer
function M.maybe_attach(buf)
    if not (buf and api.nvim_buf_is_valid(buf)) then
        return
    end
    if vim.bo[buf].buftype ~= "" then
        return
    end
    local root = buf_repo(buf)
    if not root then
        return
    end
    if has_markers(buf) then
        M.attach(buf)
    elseif attached[buf] then
        M.detach(buf)
    end
end

-- ── public: the conflict set ─────────────────────────────────────────────────────

--- The conflicted files for a repo (async) — fires `LvimGitConflicts { root, count }` and `cb(entries)`.
--- The documented read that feeds a statusline conflict badge.
---@param root? string
---@param cb? fun(entries: StatusEntry[])
function M.conflicts(root, cb)
    root = root or backend.detect(api.nvim_get_current_buf())
    if not root then
        if cb then
            cb({})
        end
        return
    end
    backend.status(root, function(model)
        local list = (model and model.conflicted) or {}
        api.nvim_exec_autocmds("User", { pattern = "LvimGitConflicts", data = { root = root, count = #list } })
        if cb then
            cb(list)
        end
    end)
end

-- ── the 3-block merge view (dedicated tabpage of real windows) ────────────────────

---@class LvimGitMergeView
---@field tab integer?
---@field origin_tab integer?
---@field origin_win integer?
---@field root string?
---@field vcs string?
---@field path string?
---@field result_buf integer?
---@field result_win integer?
---@field wins table<string, integer>
---@field scratch integer[]
---@field saved_diffopt string?
local view = { wins = {}, scratch = {} }

--- Whether the merge view is open.
---@return boolean
function M.is_open()
    return view.tab ~= nil and api.nvim_tabpage_is_valid(view.tab)
end

--- Set the native diff engine tuning for the 3-way `diffthis` (saved once, restored on close).
local function apply_diffopt()
    if view.saved_diffopt == nil then
        view.saved_diffopt = vim.o.diffopt
    end
    vim.o.diffopt = "internal,filler,closeoff,algorithm:histogram,linematch:60"
end

--- A read-only scratch buffer of `lines`, filetype inferred from `path` for syntax under `diffthis`.
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

--- The merge-view help cheatsheet.
local function show_help()
    ui.help({
        title = "Git Merge (conflict) keymaps",
        items = {
            { "]x / [x", "next / previous conflict (in RESULT)" },
            { "co / ct", "take ours / theirs for the conflict" },
            { "cb", "take both (ours then theirs)" },
            { "cB", "keep the base (diff3)" },
            { "cn", "take neither (drop the region)" },
            { "Co / Ct", "take the WHOLE file: ours / theirs" },
            { "<C-c><C-c>", "mark resolved (stage) & close" },
            { "<C-c><C-k>", "close without staging" },
            { "<C-w>", "move between the OURS / RESULT / THEIRS windows" },
            { "?", "dispatch (all commands)" },
            { "q", "close the merge view" },
        },
        close_keys = { "q", "<Esc>" },
    })
end

--- Mark the current file resolved: write it (if modified) then stage it (`git add`), and close the view.
local function mark_resolved()
    local buf = view.result_buf
    local root, rel, vcs = view.root, view.path, view.vcs
    if not (buf and root and rel) then
        return
    end
    if has_markers(buf) then
        notify("unresolved conflict markers remain — resolve them first", vim.log.levels.WARN)
        return
    end
    if vim.bo[buf].modified then
        api.nvim_buf_call(buf, function()
            vim.cmd("silent noautocmd write")
        end)
    end
    require("lvim-git.actions").execute(root, { "add", "--", rel }, { op = "resolve", vcs = vcs, quiet = true })
    notify("resolved " .. rel .. " (staged)")
    M.close()
end

--- Wire the merge-view keys on the editable RESULT buffer (choose/nav come from `M.attach`; these add
--- the view lifecycle chords). `<C-c><C-c>`/`<C-c><C-k>` avoid hijacking `q` on an editable buffer.
---@param buf integer
local function wire_result_keys(buf)
    local function map(lhs, fn, desc)
        vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = "lvim-git: " .. desc })
    end
    map("<C-c><C-c>", mark_resolved, "mark resolved & close")
    map("<C-c><C-k>", M.close, "close merge view")
    map("g?", show_help, "help")
    map("?", function()
        require("lvim-git.ui.dispatch").open()
    end, "dispatch")
end

--- Wire the read-only side (OURS/THEIRS/BASE) window keys: `q` closes, `g?` help.
---@param buf integer
local function wire_side_keys(buf)
    local function map(lhs, fn)
        vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
    end
    map("q", M.close)
    map("g?", show_help)
end

--- Close the merge view (its tabpage + scratch buffers), restore diffopt, return to the origin tab.
function M.close()
    if not M.is_open() then
        return
    end
    local tab = view.tab
    if view.result_buf and api.nvim_buf_is_valid(view.result_buf) then
        pcall(api.nvim_buf_call, view.result_buf, function()
            vim.cmd("diffoff")
        end)
    end
    if view.saved_diffopt ~= nil then
        vim.o.diffopt = view.saved_diffopt
        view.saved_diffopt = nil
    end
    if tab and api.nvim_tabpage_is_valid(tab) then
        pcall(function()
            api.nvim_set_current_tabpage(tab)
            vim.cmd("tabclose")
        end)
    end
    for _, b in ipairs(view.scratch) do
        if api.nvim_buf_is_valid(b) then
            pcall(api.nvim_buf_delete, b, { force = true })
        end
    end
    if view.origin_tab and api.nvim_tabpage_is_valid(view.origin_tab) then
        pcall(api.nvim_set_current_tabpage, view.origin_tab)
    end
    view.tab, view.origin_tab, view.origin_win = nil, nil, nil
    view.result_buf, view.result_win, view.path, view.root, view.vcs = nil, nil, nil, nil, nil
    view.wins, view.scratch = {}, {}
end

--- Build the merge-view tabpage for `path` given its three stage blobs. RESULT is the real working file.
---@param root string
---@param vcs string?
---@param path string
---@param base_lines string[]
---@param ours_lines string[]
---@param theirs_lines string[]
local function build_view(root, vcs, path, base_lines, ours_lines, theirs_lines)
    if M.is_open() then
        M.close()
    end
    view.origin_tab = api.nvim_get_current_tabpage()
    view.origin_win = api.nvim_get_current_win()
    view.root, view.vcs, view.path = root, vcs, path
    view.wins, view.scratch = {}, {}

    vim.cmd("tabnew")
    view.tab = api.nvim_get_current_tabpage()
    apply_diffopt()

    local order = {}
    if config.diffview.base_block then
        order[#order + 1] = "base"
    end
    vim.list_extend(order, { "ours", "result", "theirs" })

    local blobs = { base = base_lines, ours = ours_lines, theirs = theirs_lines }
    local titles = {
        base = "BASE (:1: ancestor)",
        ours = "OURS (HEAD :2:)",
        result = "RESULT (working — edit here)",
        theirs = "THEIRS (incoming :3:)",
    }
    local title_hl = {
        base = "LvimGitRefTag",
        ours = "LvimGitRefBranch",
        result = "LvimGitLogId",
        theirs = "LvimGitRefHead",
    }
    local abs = root .. "/" .. path

    local first = true
    for _, col in ipairs(order) do
        local win
        if first then
            win = api.nvim_get_current_win()
            first = false
        else
            vim.cmd("rightbelow vsplit")
            win = api.nvim_get_current_win()
        end
        if col == "result" then
            api.nvim_set_current_win(win)
            vim.cmd("edit " .. vim.fn.fnameescape(abs))
            view.result_buf = api.nvim_get_current_buf()
            view.result_win = win
            wire_result_keys(view.result_buf)
        else
            local buf = scratch(blobs[col], path)
            api.nvim_win_set_buf(win, buf)
            view.scratch[#view.scratch + 1] = buf
            wire_side_keys(buf)
        end
        view.wins[col] = win
        api.nvim_win_call(win, function()
            vim.cmd("diffthis")
        end)
        vim.wo[win].winbar = "%#" .. title_hl[col] .. "# " .. GLYPH.git .. " " .. titles[col]
    end

    -- The RESULT buffer gets the in-buffer choose/nav ops + the region washes, and takes focus at the
    -- first conflict so the user starts resolving immediately.
    if view.result_win and api.nvim_win_is_valid(view.result_win) then
        api.nvim_set_current_win(view.result_win)
        M.attach(view.result_buf)
        local hunks = M.parse_markers(api.nvim_buf_get_lines(view.result_buf, 0, -1, false))
        if hunks[1] then
            pcall(api.nvim_win_set_cursor, view.result_win, { hunks[1].start, 0 })
        end
    end
end

--- Fetch the three conflict stages for `path` and open the merge view.
---@param root string
---@param vcs string?
---@param path string
local function open_for(root, vcs, path)
    -- The index stages: :1: = merge base (ancestor), :2: = ours (HEAD), :3: = theirs (incoming).
    backend.blob({ root_or_buf = root, path = path, rev = ":2" }, function(ours)
        backend.blob({ root_or_buf = root, path = path, rev = ":3" }, function(theirs)
            backend.blob({ root_or_buf = root, path = path, rev = ":1" }, function(base)
                build_view(root, vcs, path, base or {}, ours or {}, theirs or {})
            end)
        end)
    end)
end

--- Open the conflict / merge view. `opts = { path?, layout?, lens?, args? }`. Resolves the target file
--- from `opts.path` (the status conflicted section), a `:LvimGit conflict <path>` arg, the current buffer
--- when it is conflicted, else a picker over the repo's conflicted set.
---@param opts? table
function M.open(opts)
    opts = opts or {}
    if not config.conflict.enabled then
        notify("the conflict component is disabled (conflict.enabled = false)", vim.log.levels.WARN)
        return
    end
    local root, vcs = backend.detect(api.nvim_get_current_buf())
    if not root then
        notify("not inside a git repository", vim.log.levels.WARN)
        return
    end
    vcs = opts.lens or vcs
    local path = opts.path or (opts.args and opts.args[1]) or nil
    if path then
        open_for(root, vcs, path)
        return
    end
    -- prefer the current buffer if it is one of the conflicted files
    local _, cur_rel = buf_repo(api.nvim_get_current_buf())
    backend.status(root, function(model)
        local conflicted = (model and model.conflicted) or {}
        if #conflicted == 0 then
            notify("no conflicted files", vim.log.levels.WARN)
            return
        end
        if cur_rel then
            for _, e in ipairs(conflicted) do
                if e.path == cur_rel then
                    open_for(root, vcs, cur_rel)
                    return
                end
            end
        end
        if #conflicted == 1 then
            open_for(root, vcs, conflicted[1].path)
            return
        end
        local items = {}
        for _, e in ipairs(conflicted) do
            items[#items + 1] = { label = e.path, _p = e.path }
        end
        ui.select({
            title = "Resolve which conflicted file?",
            items = items,
            callback = function(ok, idx)
                if ok and items[idx] then
                    open_for(root, vcs, items[idx]._p)
                end
            end,
        })
    end)
end

-- ── setup (generic auto-attach of the in-buffer ops) ─────────────────────────────

---@type boolean  one-time setup guard
local did_setup = false

--- Wire the generic conflict auto-attach: any real file buffer that holds markers gets the choose/nav
--- ops + region washes on read, and drops them once the markers are gone. Refreshes on repo changes.
function M.setup()
    if did_setup then
        return
    end
    did_setup = true
    local grp = api.nvim_create_augroup("lvim-git.conflict", { clear = true })
    api.nvim_create_autocmd({ "BufReadPost", "BufWinEnter" }, {
        group = grp,
        callback = function(ev)
            M.maybe_attach(ev.buf)
        end,
    })
    api.nvim_create_autocmd("User", {
        group = grp,
        pattern = "LvimGitRepoChanged",
        callback = function()
            -- a resolve / checkout may have cleared (or introduced) markers in open buffers
            for buf in pairs(attached) do
                if api.nvim_buf_is_valid(buf) then
                    M.maybe_attach(buf)
                end
            end
        end,
    })
end

return M
