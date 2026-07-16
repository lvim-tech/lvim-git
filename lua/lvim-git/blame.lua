-- lvim-git.blame: per-line authorship — a complete, STANDALONE "who wrote this line" install on its own
-- (inline blame + the full blame split with no status client, no other component loaded).
--
-- TWO independent entry points over the ONE backend read (`backend.blame` → BlameLine[], parsed from
-- `git blame --porcelain --incremental`):
--
--   * INLINE virtual text — an attachable, per-buffer mode: dim eol virtual text on the cursor line
--     (or every line, `blame.inline.scope`) showing `<author>, <date> ➤ <summary>` (format per config).
--     The overlay sits on the REAL, editable file buffer — so the cursor is NEVER hidden here. Debounced
--     follow of the cursor; toggled on/off; detaches cleanly; the whole-file blame is cached per buffer
--     changedtick (invalidated on write / `LvimGitRepoChanged`) so a moving cursor is O(1).
--
--   * The native blame SPLIT (`:LvimGit blame`) — a REAL side split (surface `mode="split", native=true`,
--     the outline precedent) scroll-/cursor-bound to the file, a gutter of sha·author·date columns aligned
--     line-for-line, with the fugitive/Magit TRIAGE loop: open the commit under the cursor (its per-commit
--     action popup / diff), reblame at the PARENT (`<sha>^`, stepping back through history at that line —
--     rename-aware via the porcelain `previous`), reblame the whole file at a chosen revision, and return
--     (pop back through the reblame stack). The panel's cursor is hidden via the lvim-utils cursor module
--     (self-registered `panel_ft`); a cursorline marks the active row. The source window swaps to the
--     historical blob on a reblame (so alignment always holds) and restores on close.
--
-- PUBLIC (stability contract): open / close / toggle / is_open (the split component) · line(buf,lnum,cb) /
-- line_cached(buf,lnum) (async + render-safe authorship reads, the statusline case) · enable_inline /
-- disable_inline / toggle_inline (the inline mode). Fires `User LvimGitBlameLine` `{ buf, lnum, info }`.
--
---@module "lvim-git.blame"

local uv = vim.uv or vim.loop
local api = vim.api
local config = require("lvim-git.config")
local backend = require("lvim-git.backend")
local transient = require("lvim-git.transient")
local surface = require("lvim-ui.surface")
local cursor = require("lvim-utils.cursor")

local M = {}

---@type string  the blame-split panel filetype (registered as a cursor `panel_ft`)
local BLAME_FT = "lvim-git-blame"

---@type integer  the namespace for inline blame virtual text
local INLINE_NS = api.nvim_create_namespace("lvim-git.blame.inline")

-- Blame-column layout (chars): 2 lead + 8 sha + 1 + AUTHOR_W + 1 + date. The author is truncated/padded
-- to its column; the WINDOW width is `blame.split_width` (floored so the sha+author columns always fit),
-- kept fixed for the session so the native split never re-sizes on a reblame.
local AUTHOR_W = 16

--- The blame panel's window width — `blame.split_width` clamped to a floor that fits the sha+author columns.
---@return integer
local function panel_width()
    return math.max(2 + 8 + 1 + AUTHOR_W + 1 + 8, config.blame.split_width or 44)
end

-- ── shared helpers ───────────────────────────────────────────────────────────

--- Notify with the plugin prefix.
---@param msg string
---@param level? integer
local function notify(msg, level)
    vim.notify("lvim-git: " .. msg, level or vim.log.levels.INFO)
end

--- The repo-relative path of a buffer (or nil if it has no on-disk file / isn't under `root`).
---@param buf integer
---@param root string
---@return string?
local function rel_path(buf, root)
    local name = api.nvim_buf_get_name(buf)
    if name == "" or name:match("^%w+://") then
        return nil
    end
    local abs = vim.fs.normalize(vim.fn.fnamemodify(name, ":p"))
    local prefix = root:sub(-1) == "/" and root or (root .. "/")
    if abs:sub(1, #prefix) ~= prefix then
        return nil
    end
    return abs:sub(#prefix + 1)
end

--- True when a buffer is an ordinary, on-disk, modifiable file buffer (blame makes sense there).
---@param buf integer
---@return boolean
local function is_file_buffer(buf)
    if not api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "" then
        return false
    end
    local name = api.nvim_buf_get_name(buf)
    return name ~= "" and not name:match("^%w+://")
end

--- A human relative date ("3 days ago") from a unix time.
---@param t integer
---@return string
local function rel_date(t)
    local diff = os.time() - t
    if diff < 0 then
        diff = 0
    end
    local units = {
        { 60, "second" },
        { 3600, "minute" },
        { 86400, "hour" },
        { 604800, "day" },
        { 2629800, "week" },
        { 31557600, "month" },
        { math.huge, "year" },
    }
    local divisors = { 1, 60, 3600, 86400, 604800, 2629800, 31557600 }
    for i, u in ipairs(units) do
        if diff < u[1] then
            local n = math.max(1, math.floor(diff / divisors[i]))
            return n .. " " .. u[2] .. (n == 1 and "" or "s") .. " ago"
        end
    end
    return "just now"
end

--- Format an author time per the date style ("relative" | "iso" | "short").
---@param t integer?
---@param style string
---@return string
local function fmt_date(t, style)
    if not t or t == 0 then
        return ""
    end
    if style == "iso" then
        return os.date("%Y-%m-%d %H:%M", t) --[[@as string]]
    elseif style == "short" then
        return os.date("%Y-%m-%d", t) --[[@as string]]
    end
    return rel_date(t)
end

--- Truncate a string to a display width, appending `…` when it overflows (author names are ~ascii).
---@param s string
---@param w integer
---@return string
local function trunc(s, w)
    if vim.fn.strdisplaywidth(s) <= w then
        return s
    end
    return vim.fn.strcharpart(s, 0, math.max(0, w - 1)) .. "…"
end

--- Right-pad a string to a display width with spaces.
---@param s string
---@param w integer
---@return string
local function pad(s, w)
    local d = vim.fn.strdisplaywidth(s)
    return d >= w and s or (s .. string.rep(" ", w - d))
end

-- ══════════════════════════════════════════════════════════════════════════════
-- Authorship reads (public + the inline cache) — the ONE whole-file blame, cached per changedtick.
-- ══════════════════════════════════════════════════════════════════════════════

--- Whole-file blame cache keyed by buffer: `{ tick, lines = BlameLine[] }`. Both the inline mode and the
--- public `line`/`line_cached` reads share it, so a moving cursor never re-shells while the buffer is clean.
---@type table<integer, { tick: integer, lines: BlameLine[] }>
local line_cache = {}

--- Async per-line authorship for a statusline / caller. Blames the WHOLE buffer once (with the live buffer
--- text via `--contents -`, so a modified buffer still aligns), caches it per changedtick, and calls
--- `cb(BlameInfo?)` with the requested line. Never re-shells while the cache is valid.
---@param buf? integer
---@param lnum integer
---@param cb fun(info: BlameLine?)
function M.line(buf, lnum, cb)
    buf = buf or api.nvim_get_current_buf()
    if not is_file_buffer(buf) then
        cb(nil)
        return
    end
    local root = backend.detect(buf)
    local path = root and rel_path(buf, root)
    if not root or not path then
        cb(nil)
        return
    end
    local tick = api.nvim_buf_get_changedtick(buf)
    local c = line_cache[buf]
    if c and c.tick == tick then
        cb(c.lines[lnum])
        return
    end
    local contents = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n") .. "\n"
    backend.blame({ root_or_buf = root, path = path, contents = contents }, function(lines)
        if not api.nvim_buf_is_valid(buf) then
            cb(nil)
            return
        end
        line_cache[buf] = { tick = tick, lines = lines or {} }
        cb((lines or {})[lnum])
    end)
end

--- The cached authorship for a line if already computed, else nil (render-safe, O(1) — the statusline read).
---@param buf? integer
---@param lnum integer
---@return BlameLine?
function M.line_cached(buf, lnum)
    local c = line_cache[buf or api.nvim_get_current_buf()]
    return c and c.lines[lnum] or nil
end

-- ══════════════════════════════════════════════════════════════════════════════
-- Inline blame (attachable per-buffer virtual text)
-- ══════════════════════════════════════════════════════════════════════════════

--- Per-buffer inline records: `{ timer }` (the debounce timer). Presence = attached.
---@type table<integer, table>
local inline = {}

--- Substitute `<sha> <author> <date> <summary>` tokens in the inline format for a blame line.
---@param info BlameLine
---@return string
local function format_inline(info)
    local tokens = {
        sha = info.abbrev:sub(1, 8),
        author = info.author,
        date = fmt_date(info.author_time, config.blame.date_format),
        summary = info.summary,
    }
    local s = (config.blame.inline.format or "<author>, <date> ➤ <summary>"):gsub("<(%w+)>", function(t)
        return tokens[t] or ("<" .. t .. ">")
    end)
    return "  " .. s
end

--- Paint inline eol virtual text for the given lines from the cache (committed lines only).
---@param buf integer
---@param lnums integer[]
local function set_inline_marks(buf, lnums)
    if not api.nvim_buf_is_valid(buf) then
        return
    end
    api.nvim_buf_clear_namespace(buf, INLINE_NS, 0, -1)
    local c = line_cache[buf]
    if not c then
        return
    end
    local grp = config.blame.inline.highlight or "LvimGitBlame"
    local n = api.nvim_buf_line_count(buf)
    for _, l in ipairs(lnums) do
        local info = c.lines[l]
        if info and info.is_committed and l >= 1 and l <= n then
            pcall(api.nvim_buf_set_extmark, buf, INLINE_NS, l - 1, 0, {
                virt_text = { { format_inline(info), grp } },
                virt_text_pos = "eol",
                hl_mode = "combine",
            })
        end
    end
end

--- The window (and its cursor line) currently showing `buf` — the current window when it is `buf`, else
--- the first window that shows it.
---@param buf integer
---@return integer? win, integer lnum
local function win_for(buf)
    local win = api.nvim_get_current_win()
    if api.nvim_win_get_buf(win) ~= buf then
        win = nil
        for _, w in ipairs(api.nvim_list_wins()) do
            if api.nvim_win_get_buf(w) == buf then
                win = w
                break
            end
        end
    end
    if not win then
        return nil, 1
    end
    return win, api.nvim_win_get_cursor(win)[1]
end

--- Resolve + paint the inline blame for a buffer (debounced entry). `scope="file"` paints every line;
--- `"line"` paints only the cursor line (both share the ONE whole-file blame). Fires `LvimGitBlameLine`.
---@param buf integer
local function resolve_inline(buf)
    if not inline[buf] or not api.nvim_buf_is_valid(buf) then
        return
    end
    local scope = config.blame.inline.scope or "line"
    if scope == "file" then
        M.line(buf, 1, function()
            if not inline[buf] then
                return
            end
            local c = line_cache[buf]
            local lnums = {}
            if c then
                for l in pairs(c.lines) do
                    lnums[#lnums + 1] = l
                end
            end
            set_inline_marks(buf, lnums)
        end)
        return
    end
    local win, lnum = win_for(buf)
    if not win then
        return
    end
    M.line(buf, lnum, function(info)
        if not inline[buf] then
            return
        end
        set_inline_marks(buf, { lnum })
        api.nvim_exec_autocmds("User", { pattern = "LvimGitBlameLine", data = { buf = buf, lnum = lnum, info = info } })
    end)
end

--- Debounced resolve (the cursor settling / an edit): coalesce rapid events into one paint.
---@param buf integer
local function schedule_inline(buf)
    local rec = inline[buf]
    if not rec then
        return
    end
    if not rec.timer then
        rec.timer = uv.new_timer()
    end
    rec.timer:stop()
    rec.timer:start(config.blame.inline.delay or 700, 0, function()
        vim.schedule(function()
            resolve_inline(buf)
        end)
    end)
end

--- Attach inline blame to a buffer (idempotent). No-op unless it is a file buffer inside a repo.
---@param buf? integer
function M.enable_inline(buf)
    buf = buf or api.nvim_get_current_buf()
    if inline[buf] or not is_file_buffer(buf) then
        return
    end
    local root = backend.detect(buf)
    if not root or not rel_path(buf, root) then
        return
    end
    inline[buf] = {}
    resolve_inline(buf)
end

--- Detach inline blame from a buffer: stop the timer, clear the virtual text.
---@param buf? integer
function M.disable_inline(buf)
    buf = buf or api.nvim_get_current_buf()
    local rec = inline[buf]
    if not rec then
        return
    end
    if rec.timer then
        pcall(function()
            rec.timer:stop()
            rec.timer:close()
        end)
    end
    inline[buf] = nil
    if api.nvim_buf_is_valid(buf) then
        api.nvim_buf_clear_namespace(buf, INLINE_NS, 0, -1)
    end
end

--- Toggle inline blame for a buffer (`:LvimGit toggle_blame`).
---@param buf? integer
function M.toggle_inline(buf)
    buf = buf or api.nvim_get_current_buf()
    if inline[buf] then
        M.disable_inline(buf)
    else
        M.enable_inline(buf)
    end
end

-- ══════════════════════════════════════════════════════════════════════════════
-- The native blame SPLIT (the triage loop)
-- ══════════════════════════════════════════════════════════════════════════════

--- The single blame-split session (one at a time). Always a table so callbacks can dereference it without
--- a nil dance; `active` is false when closed, and every triage entry point is gated on it. A fresh table
--- is assigned per `M.open` so a stale callback from a previous session (comparing the reassigned upvalue)
--- naturally no-ops.
---@class LvimGitBlameSplit
---@field active boolean
---@field root string
---@field vcs string
---@field path string
---@field src_win integer
---@field src_winbar? string     the source window's original winbar (restored on close)
---@field orig_buf integer
---@field rev? string          the rev currently blamed (nil = working tree)
---@field stack { rev?: string, path: string, range?: table }[]  the reblame history (for `<BS>`)
---@field scratch_bufs integer[]  the historical-blob buffers to wipe on close
---@field lines BlameLine[]     the current blame (sparse, indexed by line)
---@field n integer             the blamed file's line count (= panel rows)
---@field args string[]         the blame flags (-w/-M/-C/…) in effect
---@field date_format string
---@field range? { lo: integer, hi: integer }
---@field start_line integer
---@field contents? string      buffer text for the working-tree `--contents -` blame
---@field src_lines? integer
---@field age_lo? integer
---@field age_hi? integer
---@field augroup? integer
---@field panel? table          the surface panel handle (refresh/win/buf)
---@field blame_win? integer
---@field blame_buf? integer
---@field surface? table        the surface frame handle (close)
---@field _cur_commit? string
--- A fully-defaulted (closed) split table — every required field present so the type is never partial.
---@return LvimGitBlameSplit
local function blank_split()
    return {
        active = false,
        root = "",
        vcs = "git",
        path = "",
        src_win = 0,
        orig_buf = 0,
        stack = {},
        scratch_bufs = {},
        lines = {},
        n = 0,
        args = {},
        date_format = "relative",
        start_line = 1,
    }
end

---@type LvimGitBlameSplit
local split = blank_split()

--- Forward decl: `load_blame` is referenced by the key handlers bound before it is defined.
local load_blame

-- ── the blame-options transient (-w / -M / -C / ignore-revs / date) ──────────

--- Register the `blame-options` transient once: whitespace / move-detection switches, an ignore-revs-file
--- option, and a date-format choice (no argv — read live), whose apply action reblames with the new args.
local function ensure_options_transient()
    if transient.has("blame-options") then
        return
    end
    transient.define({
        id = "blame-options",
        title = "Blame options",
        groups = {
            {
                title = "Blame",
                infix = {
                    {
                        kind = "switch",
                        key = "-w",
                        label = "Ignore whitespace",
                        flag = "-w",
                        default = config.blame.ignore_whitespace == true,
                    },
                    {
                        kind = "switch",
                        key = "-M",
                        label = "Detect moved lines (within file)",
                        flag = "-M",
                        default = config.blame.detect_moves == true,
                    },
                    {
                        kind = "switch",
                        key = "-C",
                        label = "Detect moves across files",
                        flag = "-C",
                        default = config.blame.detect_copies == true,
                        level = 3,
                    },
                    {
                        kind = "option",
                        key = "=i",
                        label = "Ignore-revs file",
                        arg = "--ignore-revs-file",
                        default = config.blame.ignore_revs_file,
                        level = 3,
                    },
                    { kind = "option", key = "=d", label = "Date format (relative/iso/short)" },
                },
                actions = {
                    {
                        key = "g",
                        label = "Apply / reblame",
                        run = function(args, ctx)
                            if not split.active then
                                return
                            end
                            split.args = args
                            local drow = ctx.rows and ctx.rows["=d"]
                            local dval = drow and drow.value and vim.trim(tostring(drow.value))
                            if dval and (dval == "relative" or dval == "iso" or dval == "short") then
                                split.date_format = dval
                            end
                            load_blame()
                        end,
                    },
                },
            },
        },
    })
end

--- The blame argv (`-w`/`-M`/`-C`/`--ignore-revs-file`) currently in effect, seeded from the transient
--- session default (which reflects the config switch defaults).
---@param root string
---@return string[]
local function blame_args(root)
    ensure_options_transient()
    return transient.args("blame-options", root)
end

-- ── column model + rendering ─────────────────────────────────────────────────

--- Recompute the recency (author-time) min/max over committed lines for the heat buckets.
local function compute_recency()
    local lo, hi
    for _, bl in pairs(split.lines or {}) do
        if bl.is_committed and bl.author_time and bl.author_time > 0 then
            lo = lo and math.min(lo, bl.author_time) or bl.author_time
            hi = hi and math.max(hi, bl.author_time) or bl.author_time
        end
    end
    split.age_lo, split.age_hi = lo, hi
end

--- The recency-bucket highlight group (newest → oldest) for an author time, when `blame.recency` is on.
---@param t integer
---@return string
local function age_group(t)
    local lo, hi = split.age_lo, split.age_hi
    if not lo or not hi or hi <= lo then
        return "LvimGitBlameAge1"
    end
    local frac = (hi - t) / (hi - lo) -- 0 newest .. 1 oldest
    local idx = math.min(5, math.max(1, 1 + math.floor(frac * 4.999)))
    return "LvimGitBlameAge" .. idx
end

--- The full commit sha of the blame line under the panel cursor (or nil).
---@return string?
local function cursor_commit()
    if not (split.active and split.blame_win and api.nvim_win_is_valid(split.blame_win)) then
        return nil
    end
    local l = api.nvim_win_get_cursor(split.blame_win)[1]
    local bl = (split.lines or {})[l]
    return bl and bl.is_committed and bl.commit or nil
end

--- Build the blame-column rows (one per source line) + byte-range highlight spans. The line the cursor is
--- on shares its commit's colour across every same-commit row (LvimGitBlameHead), the Magit "commit at point".
---@param _width integer
---@return string[] lines, table[] hls
local function build_rows(_width)
    local lines, hls = {}, {}
    local n = split.n or 0
    local recency = config.blame.recency == true
    local cur = cursor_commit()
    for i = 1, n do
        local bl = (split.lines or {})[i]
        local sha, auth, date, sha_hl, auth_hl
        if bl and bl.is_committed then
            sha = bl.abbrev:sub(1, 8)
            auth = bl.author
            date = fmt_date(bl.author_time, split.date_format)
            if cur and bl.commit == cur then
                sha_hl = "LvimGitBlameHead"
            elseif recency then
                sha_hl = age_group(bl.author_time)
            else
                sha_hl = "LvimGitBlameSha"
            end
            auth_hl = "LvimGitBlameAuthor"
        elseif bl then
            sha, auth, date = "0000000", "Not Committed Yet", ""
            sha_hl, auth_hl = "LvimGitBlameNotCommitted", "LvimGitBlameNotCommitted"
        else
            lines[i] = ""
            goto continue
        end
        local shacell = pad(sha, 8)
        local authcell = pad(trunc(auth, AUTHOR_W), AUTHOR_W)
        local row = "  " .. shacell .. " " .. authcell .. " " .. date
        lines[i] = row
        local o = 2
        hls[#hls + 1] = { i - 1, o, o + #shacell, sha_hl }
        o = o + #shacell + 1
        hls[#hls + 1] = { i - 1, o, o + #authcell, auth_hl }
        o = o + #authcell + 1
        if date ~= "" then
            hls[#hls + 1] = { i - 1, o, o + #date, "LvimGitBlameDate" }
        end
        ::continue::
    end
    return lines, hls
end

--- Refresh the winbar title with the current rev + path being blamed. The SOURCE window is given a
--- MATCHING 1-row winbar (its own winbar saved on open, restored on close) so the two windows' text areas
--- start on the same screen row — WITHOUT it the panel's title row skews the blame column one line below
--- the source it annotates. Both bars carry the triage context, so the winbar earns its row on both sides.
local function update_title()
    if not (split.active and split.blame_win and api.nvim_win_is_valid(split.blame_win)) then
        return
    end
    local rev = split.rev and split.rev:sub(1, 8) or "working tree"
    pcall(function()
        vim.wo[split.blame_win].winbar = "%=  GIT BLAME  ➤  " .. rev .. "  ➤  " .. split.path .. "  %="
    end)
    if split.src_win and api.nvim_win_is_valid(split.src_win) then
        pcall(function()
            vim.wo[split.src_win].winbar = "%=  " .. split.path .. "  @  " .. rev .. "  %="
        end)
    end
end

-- ── scroll/cursor binding + the source view swap ─────────────────────────────

--- Bind the blame panel and the source window together (native scroll + cursor sync, fugitive's mechanism),
--- then sync from the panel. Re-applied after every (re)load since a reblame swaps the source buffer.
local function apply_bind()
    if
        not (
            split
            and split.blame_win
            and api.nvim_win_is_valid(split.blame_win)
            and split.src_win
            and api.nvim_win_is_valid(split.src_win)
        )
    then
        return
    end
    for _, w in ipairs({ split.src_win, split.blame_win }) do
        vim.wo[w].scrollbind = true
        vim.wo[w].cursorbind = true
    end
    pcall(api.nvim_win_call, split.blame_win, function()
        vim.cmd("syncbind")
    end)
end

--- Ensure the source window shows the content matching `split.rev` (the working buffer for the working
--- tree, else a scratch buffer of the blob at that rev), then invoke `done()`. Remembers the source line
--- count so the blame column aligns exactly.
---@param done fun()
local function set_source_view(done)
    if split.rev == nil then
        if
            split.src_win
            and api.nvim_win_is_valid(split.src_win)
            and split.orig_buf
            and api.nvim_buf_is_valid(split.orig_buf)
            and api.nvim_win_get_buf(split.src_win) ~= split.orig_buf
        then
            pcall(api.nvim_win_set_buf, split.src_win, split.orig_buf)
        end
        split.contents = table.concat(api.nvim_buf_get_lines(split.orig_buf, 0, -1, false), "\n") .. "\n"
        split.src_lines = api.nvim_buf_line_count(split.orig_buf)
        done()
        return
    end
    backend.blob({ root_or_buf = split.root, path = split.path, rev = split.rev }, function(blines)
        if not split.active then
            return
        end
        blines = blines or {}
        if blines[#blines] == "" then
            blines[#blines] = nil
        end
        local sb = api.nvim_create_buf(false, true)
        vim.bo[sb].bufhidden = "wipe"
        api.nvim_buf_set_lines(sb, 0, -1, false, blines)
        vim.bo[sb].modifiable = false
        pcall(function()
            vim.bo[sb].filetype = vim.bo[split.orig_buf].filetype
        end)
        split.scratch_bufs[#split.scratch_bufs + 1] = sb
        if split.src_win and api.nvim_win_is_valid(split.src_win) then
            pcall(api.nvim_win_set_buf, split.src_win, sb)
        end
        split.contents = nil
        split.src_lines = #blines
        done()
    end)
end

--- (Re)load the blame for the current view (rev + path + args), repaint the panel, rebind, retitle.
function load_blame()
    if not split.active then
        return
    end
    set_source_view(function()
        if not split.active then
            return
        end
        local bopts = { root_or_buf = split.root, path = split.path, args = split.args }
        if split.rev then
            bopts.rev = split.rev
        else
            bopts.contents = split.contents
        end
        if split.range then
            bopts.range = split.range
        end
        backend.blame(bopts, function(lines)
            if not split.active then
                return
            end
            split.lines = lines or {}
            split.n = split.src_lines or 0
            compute_recency()
            if split.panel and split.panel.refresh then
                split.panel.refresh()
            end
            apply_bind()
            update_title()
            -- Keep the panel cursor in range and re-sync the source to it.
            if split.blame_win and api.nvim_win_is_valid(split.blame_win) then
                local l = math.min(api.nvim_win_get_cursor(split.blame_win)[1], math.max(1, split.n))
                pcall(api.nvim_win_set_cursor, split.blame_win, { l, 0 })
            end
        end)
    end)
end

-- ── the triage actions ───────────────────────────────────────────────────────

--- The blame line under the panel cursor (or nil).
---@return BlameLine?
local function current_blame_line()
    if not (split.active and split.blame_win and api.nvim_win_is_valid(split.blame_win)) then
        return nil
    end
    return (split.lines or {})[api.nvim_win_get_cursor(split.blame_win)[1]]
end

--- Fetch the full Commit for a sha (for the per-commit popup / diff), then invoke `cb`.
---@param sha string
---@param cb fun(commit: Commit?)
local function fetch_commit(sha, cb)
    backend.log({ root_or_buf = split.root, revset = sha, limit = 1 }, function(cs)
        cb(cs and cs[1] or nil)
    end)
end

--- Open the per-commit action popup for the line under the cursor (detail / diff / checkout / …).
local function open_commit_actions()
    local bl = current_blame_line()
    if not bl or not bl.is_committed then
        notify("blame: this line is not committed yet")
        return
    end
    fetch_commit(bl.commit, function(commit)
        if not commit then
            notify("blame: could not resolve " .. bl.abbrev, vim.log.levels.WARN)
            return
        end
        require("lvim-git.actions").commit_actions(commit, split.root, split.vcs)
    end)
end

--- View the diff of the commit under the cursor directly (its first-parent → the commit).
local function view_commit_diff()
    local bl = current_blame_line()
    if not bl or not bl.is_committed then
        notify("blame: this line is not committed yet")
        return
    end
    fetch_commit(bl.commit, function(commit)
        if commit then
            require("lvim-git.actions").view_commit_diff(commit)
        end
    end)
end

--- Open the commit under the cursor in the log panel.
local function open_log_detail()
    local bl = current_blame_line()
    if not bl or not bl.is_committed then
        notify("blame: this line is not committed yet")
        return
    end
    require("lvim-git.ui.log").open({ revset = bl.commit, lens = split.vcs })
end

--- Push the current view onto the reblame stack (so `<BS>` returns to it).
local function push_view()
    split.stack[#split.stack + 1] = { rev = split.rev, path = split.path, range = split.range }
end

--- Reblame at the PARENT of the line under the cursor (fugitive `-` — step back through history at that
--- line, rename-aware via the porcelain `previous`).
local function reblame_parent()
    local bl = current_blame_line()
    if not bl or not bl.is_committed then
        notify("blame: this line is not committed yet")
        return
    end
    if not bl.previous then
        notify("blame: reached the first commit that introduced this line")
        return
    end
    push_view()
    split.rev = bl.previous
    split.path = bl.previous_filename or split.path
    split.range = nil -- a range only scopes the initial working-tree blame
    load_blame()
end

--- Reblame the WHOLE file at a chosen revision (a select over the file's recent history).
local function reblame_at_rev()
    backend.log({ root_or_buf = split.root, paths = { split.path }, limit = 30 }, function(commits)
        if not commits or #commits == 0 then
            notify("blame: no history for this file", vim.log.levels.WARN)
            return
        end
        local items = {}
        for _, c in ipairs(commits) do
            items[#items + 1] = {
                label = c.id:sub(1, 8) .. "  " .. (c.subject or ""),
                icon = { text = "", hl = "LvimGitLogId" },
                commit = c,
            }
        end
        require("lvim-ui").select({
            title = "Reblame file at",
            items = items,
            callback = function(confirmed, index)
                if not confirmed or not split.active then
                    return
                end
                push_view()
                split.rev = items[index].commit.id
                split.range = nil
                load_blame()
            end,
        })
    end)
end

--- Return: pop one reblame level off the stack (or notify when already at the base view).
local function pop_view()
    local prev = table.remove(split.stack)
    if not prev then
        notify("blame: already at the working tree")
        return
    end
    split.rev, split.path, split.range = prev.rev, prev.path, prev.range
    load_blame()
end

--- Cycle the date-column format (relative → iso → short); repaint (no reblame needed).
local function cycle_date()
    local order = { "relative", "iso", "short" }
    local i = 1
    for k, v in ipairs(order) do
        if v == split.date_format then
            i = k
            break
        end
    end
    split.date_format = order[(i % #order) + 1]
    if split.panel and split.panel.refresh then
        split.panel.refresh()
    end
    notify("blame date: " .. split.date_format)
end

-- ── help (the canonical cheatsheet) ──────────────────────────────────────────

--- The blame-split keymap cheatsheet (help canon).
local HELP = {
    { "<CR> / a", "commit actions (detail / diff / checkout / …)" },
    { "d", "view the commit's diff" },
    { "L", "open the commit in the log panel" },
    { "p", "reblame at the parent (older attribution for this line)" },
    { "R", "reblame the whole file at a revision" },
    { "<BS>", "return (pop one reblame level)" },
    { "o", "blame options (-w / -M / -C / ignore-revs / date)" },
    { "D", "cycle date format (relative / iso / short)" },
    { "?", "dispatch menu" },
    { "q", "close" },
}

local function show_help()
    require("lvim-ui").help({ title = "Blame keymaps", items = HELP, close_keys = { "q", "<Esc>", "g?" } })
end

-- ── panel lifecycle ──────────────────────────────────────────────────────────

--- Tear-down: restore the source window's original buffer + unbind, wipe scratch blobs, mark inactive.
local function cleanup()
    if not split.active then
        return
    end
    split.active = false
    if split.augroup then
        pcall(api.nvim_del_augroup_by_id, split.augroup)
    end
    if split.src_win and api.nvim_win_is_valid(split.src_win) then
        if
            split.orig_buf
            and api.nvim_buf_is_valid(split.orig_buf)
            and api.nvim_win_get_buf(split.src_win) ~= split.orig_buf
        then
            pcall(api.nvim_win_set_buf, split.src_win, split.orig_buf)
        end
        pcall(function()
            vim.wo[split.src_win].scrollbind = false
            vim.wo[split.src_win].cursorbind = false
            vim.wo[split.src_win].winbar = split.src_winbar or ""
        end)
    end
    for _, sb in ipairs(split.scratch_bufs or {}) do
        if api.nvim_buf_is_valid(sb) then
            pcall(api.nvim_buf_delete, sb, { force = true })
        end
    end
end

--- Bind the triage keys on the blame panel + wire the CursorMoved repaint (the same-commit highlight
--- follows the hidden cursor). Records the panel handle/window/buffer.
---@param map fun(lhs: string|string[], fn: fun())
---@param pan table
local function bind_keys(map, pan)
    split.panel = pan
    split.blame_win = pan.win
    split.blame_buf = pan.buf
    map({ "<CR>", "a" }, open_commit_actions)
    map("d", view_commit_diff)
    map("L", open_log_detail)
    map("p", reblame_parent)
    map("R", reblame_at_rev)
    map({ "<BS>" }, pop_view)
    map("o", function()
        ensure_options_transient()
        transient.open("blame-options", { root = split.root, lens = split.vcs })
    end)
    map("D", cycle_date)
    map("g?", show_help)
    map("?", function()
        require("lvim-git.ui.dispatch").open()
    end)
    map("q", function()
        M.close()
    end)
    -- Repaint only when the commit under the cursor changes, so the same-commit tint follows without an
    -- O(n) render on every single-line move.
    split._cur_commit = cursor_commit()
    api.nvim_create_autocmd("CursorMoved", {
        group = split.augroup,
        buffer = pan.buf,
        callback = function()
            if not split.active then
                return
            end
            local c = cursor_commit()
            if c ~= split._cur_commit then
                split._cur_commit = c
                if split.panel and split.panel.refresh then
                    split.panel.refresh()
                end
            end
        end,
    })
end

--- Open the native blame-split surface (a left dock of the aligned blame columns).
local function open_panel()
    local provider = {
        filetype = BLAME_FT, -- the cursor module hides the hardware cursor while the panel is current
        cursorline = true,
        size = function()
            return panel_width(), 1
        end,
        render = function(width)
            return build_rows(width)
        end,
        keys = function(map, pan)
            bind_keys(map, pan)
        end,
        on_close = cleanup,
    }
    split.surface = surface.open({
        mode = "split",
        native = true, -- a REAL split window → native <C-w> nav, scrollbind + cursorbind, native redraw
        dock = "left",
        enter = true,
        persistent = true,
        normal_hl = "NormalSB",
        title = "GIT BLAME",
        size = { width = { fixed = panel_width() } },
        content = { blocks = { { id = "blame", provider = provider } } },
        close_keys = {}, -- persistent: our own `q` tears the frame down
    })
end

--- True when the blame split is open.
---@return boolean
function M.is_open()
    return split.active and split.blame_win ~= nil and api.nvim_win_is_valid(split.blame_win)
end

--- Close the blame split (restores the source window via the frame teardown → `cleanup`). Idempotent.
function M.close()
    if not split.active then
        return
    end
    local s = split.surface
    if s then
        pcall(s.close)
    else
        cleanup()
    end
end

--- Open the full blame split for the current buffer. `opts.line1/line2` (a visual `:'<,'>LvimGit blame`)
--- scope the initial blame to that line range (`-L`); `opts.lens` forces a vcs.
---@param opts? { line1?: integer, line2?: integer, lens?: string, layout?: string }
function M.open(opts)
    opts = opts or {}
    if not config.blame.enabled then
        return
    end
    local buf = api.nvim_get_current_buf()
    local root, vcs = backend.detect(buf)
    if not root then
        notify("not inside a git repository", vim.log.levels.WARN)
        return
    end
    local path = rel_path(buf, root)
    if not path then
        notify("blame: the current buffer is not a file in this repository", vim.log.levels.WARN)
        return
    end
    if M.is_open() then
        M.close()
    end
    M.register()
    local start_line = api.nvim_win_get_cursor(0)[1]
    local src_win = api.nvim_get_current_win()
    split = {
        active = true,
        root = root,
        vcs = opts.lens or vcs or "git",
        path = path,
        src_win = src_win,
        src_winbar = vim.wo[src_win].winbar,
        orig_buf = buf,
        rev = nil,
        stack = {},
        scratch_bufs = {},
        lines = {},
        n = 0,
        args = blame_args(root),
        date_format = config.blame.date_format or "relative",
        start_line = start_line,
    }
    if opts.line1 and opts.line2 then
        local a = opts.line1 --[[@as integer]]
        local b = opts.line2 --[[@as integer]]
        split.range = a <= b and { lo = a, hi = b } or { lo = b, hi = a }
    end
    split.augroup = api.nvim_create_augroup("lvim-git.blame.split", { clear = true })
    open_panel()
    -- Seed the panel cursor to the line the user was on, then load.
    if split.blame_win and api.nvim_win_is_valid(split.blame_win) then
        pcall(api.nvim_win_set_cursor, split.blame_win, { math.max(1, start_line), 0 })
    end
    load_blame()
end

-- ── component setup (inline autocmds + repo-change refresh) ──────────────────

---@type integer?  the inline / repo-change autocmd group (set on setup)
local augroup

--- Whether the cursor `panel_ft` has been registered (once).
local registered = false

--- Register the blame-split panel filetype for cursor hiding (idempotent, load-order-safe).
function M.register()
    if registered then
        return
    end
    registered = true
    cursor.register({ panel_ft = { BLAME_FT } })
end

--- Wire the blame component: inline auto-attach + debounced follow, cache invalidation on write, and a
--- refresh of both the inline overlay and the open split on any repo mutation. Idempotent.
function M.setup()
    if augroup then
        return
    end
    augroup = api.nvim_create_augroup("lvim-git.blame", { clear = true })
    M.register()

    -- Inline: auto-attach on load when configured on by default.
    if config.blame.inline.enabled then
        api.nvim_create_autocmd({ "BufReadPost", "BufWinEnter" }, {
            group = augroup,
            callback = function(a)
                M.enable_inline(a.buf)
            end,
        })
        for _, b in ipairs(api.nvim_list_bufs()) do
            if api.nvim_buf_is_loaded(b) then
                M.enable_inline(b)
            end
        end
    end

    -- Inline: follow the cursor (debounced) while attached.
    api.nvim_create_autocmd({ "CursorMoved", "CursorHold" }, {
        group = augroup,
        callback = function(a)
            if inline[a.buf] then
                schedule_inline(a.buf)
            end
        end,
    })
    -- An edit invalidates the whole-file blame; clear the stale overlay + re-resolve.
    api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
        group = augroup,
        callback = function(a)
            if inline[a.buf] then
                api.nvim_buf_clear_namespace(a.buf, INLINE_NS, 0, -1)
                schedule_inline(a.buf)
            end
        end,
    })
    api.nvim_create_autocmd("BufWritePost", {
        group = augroup,
        callback = function(a)
            line_cache[a.buf] = nil
            if inline[a.buf] then
                schedule_inline(a.buf)
            end
        end,
    })
    api.nvim_create_autocmd("BufDelete", {
        group = augroup,
        callback = function(a)
            M.disable_inline(a.buf)
            line_cache[a.buf] = nil
        end,
    })
    -- Any repo mutation → drop every cached blame, repaint attached inline overlays, reblame an open split.
    api.nvim_create_autocmd("User", {
        group = augroup,
        pattern = "LvimGitRepoChanged",
        callback = function()
            line_cache = {}
            for b in pairs(inline) do
                resolve_inline(b)
            end
            if split.active and split.rev == nil then
                load_blame()
            end
        end,
    })
end

return M
