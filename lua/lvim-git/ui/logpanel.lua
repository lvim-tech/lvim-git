-- lvim-git.ui.logpanel: the SHARED commit-list surface — the internal chassis both the log/graph panel
-- (`ui/log.lua`) and the file-history panel (`ui/history.lua`) compose over, plus the cherry view. It is
-- NOT a component (no `enabled`, no subcommand, no public opener); it is shared UI INFRASTRUCTURE over
-- the core (backend / model.graph / highlights / config) — so the two commit-list components reuse ONE
-- renderer without depending on EACH OTHER (the decoupling contract forbids component→component requires,
-- not a shared internal builder, exactly like backend/model/highlights).
--
-- Each open builds a `lvim-ui.tabs` menu surface (the status/lvim-tasks persistent-panel chassis): a
-- SELECTABLE list of commit rows — the coloured `model.graph` lane column + short id + subject + ref
-- badges + a dim author/rel-date meta — with a live commit-detail PREVIEW block (message + diffstat via
-- `on_item_change`). Row keys are supplied by the caller (per-commit actions, view-diff, options, load-
-- more); navigation/fold/`g?` are the chassis'. State is closure-local per open, so a log panel and a
-- history panel can coexist without clobbering one another. Refreshes on `User LvimGitRepoChanged`.
--
---@module "lvim-git.ui.logpanel"

local api = vim.api
local config = require("lvim-git.config")
local backend = require("lvim-git.backend")
local commands = require("lvim-git.commands")
local workspace = require("lvim-git.ui.workspace")
local graph = require("lvim-git.model.graph")
local ui = require("lvim-ui")
local ui_filters = require("lvim-ui.filters")
local hl = require("lvim-utils.highlight")

-- Commit-row palette (matches the status page's "recent" section): the short id wears green, the subject
-- yellow — differentiated hues from the graph lanes and the dim meta, all pulled from the live theme.
local ID_HL = hl.section_accent("green").text
local SUBJECT_HL = hl.section_accent("yellow").text
-- Detail-preview palette (matches the status commit preview): sha orange · author green · date purple ·
-- message yellow — each header field its own hue instead of one flat dim block.
local DETAIL_SHA_HL = hl.section_accent("orange").text
local DETAIL_AUTHOR_HL = hl.section_accent("green").text
local DETAIL_DATE_HL = hl.section_accent("purple").text

local M = {}

-- ── glyphs (verified single-width Nerd Font, + the `➤` pointer canon) ──────────
local GLYPH = {
    git = "\u{e725}", --  nf-dev-git_branch (title + repo band)
    log = "\u{f1da}", --  nf-fa-history (log title)
    arrow = "➤", -- repo-band segment separator (the pointer canon)
    tag = "\u{f02b}", --  nf-fa-tag
    branch = "\u{e725}", --  nf-dev-git_branch
    remote = "\u{f0c2}", --  nf-fa-cloud
    drift = "\u{f071}", --  nf-fa-exclamation_triangle (colocated git↔jj drift)
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

-- ── formatting helpers ──────────────────────────────────────────────────────────

--- A short relative date ("3h", "2d", "5mo", "1y") from a unix time (dim meta on each commit row).
---@param t integer?
---@return string
local function rel_date(t)
    if not t or t <= 0 then
        return ""
    end
    local d = os.time() - t
    if d < 60 then
        return d .. "s"
    elseif d < 3600 then
        return math.floor(d / 60) .. "m"
    elseif d < 86400 then
        return math.floor(d / 3600) .. "h"
    elseif d < 86400 * 30 then
        return math.floor(d / 86400) .. "d"
    elseif d < 86400 * 365 then
        return math.floor(d / (86400 * 30)) .. "mo"
    end
    return math.floor(d / (86400 * 365)) .. "y"
end

--- Classify one ref decoration into its badge text + highlight (branch/remote/tag/HEAD).
---@param decor string  a single %D decoration entry (e.g. "HEAD -> main", "tag: v1.0", "origin/main")
---@return string text, string hl
local function badge_for(decor)
    local head = decor:match("^HEAD %-> (.+)$")
    if head then
        return GLYPH.git .. " " .. head, "LvimGitRefHead"
    elseif decor == "HEAD" then
        return GLYPH.git .. " HEAD", "LvimGitRefHead"
    end
    local tag = decor:match("^tag: (.+)$")
    if tag then
        return GLYPH.tag .. " " .. tag, "LvimGitRefTag"
    end
    if decor:find("/", 1, true) then
        return GLYPH.remote .. " " .. decor, "LvimGitRefRemote"
    end
    return GLYPH.branch .. " " .. decor, "LvimGitRefBranch"
end

-- ── the panel ────────────────────────────────────────────────────────────────

---@class LvimGitLogPanelCfg
---@field view      string                          the view name for layout resolution (log/history)
---@field root      string                          the repo root
---@field vcs       string?                         the repo lens
---@field title     { icon: string, text: string }  the frame title
---@field subtitle? fun(): table[]?                 a live subtitle band (repo header)
---@field layout?   string                          the resolved layout token
---@field graph?    boolean                         render the coloured graph lane column
---@field filters?  { active: string, buttons: table[], on_select: fun(id: string) }  a filter bar sector
---@field load      fun(cb: fun(commits: Commit[]))  fetch the commit list
---@field on_action? fun(commit: Commit)            `a`/`<CR>` — the per-commit action popup
---@field on_view_diff? fun(commit: Commit)         `d` — open the commit's diff
---@field on_options? fun()                          `o` — the log-filter transient
---@field on_more?   fun()                           `+` — lazy-extend (load more)
---@field help_items? table[]                        extra rows for the `g?` cheatsheet

--- Open a commit-list panel. Returns a handle `{ win, is_open, close, reload, focus_commit, root }`.
---@param cfg LvimGitLogPanelCfg
---@return table handle
function M.open(cfg)
    ---@class LvimGitLogPanelState
    local st = {
        commits = {}, ---@type Commit[]
        graphs = {}, ---@type LvimGitGraphRow[]
        registry = {}, ---@type table<string, Commit>
        detail_cache = {}, ---@type table<string, { lines: string[], hls: table[] }>
        focused = nil, ---@type Commit?
        preview_pan = nil, ---@type table?
        handle = nil, ---@type table?
        tabs = nil, ---@type table[]?
        augroup = nil, ---@type integer?
    }

    -- A `tab` layout hosts the panel in a dedicated fullscreen workspace tabpage (ui/workspace), keyed by
    -- the view name (log / history coexist), with the surface float sized (via `slot`) to fill the tab.
    local is_tab = cfg.layout == "tab"
    local view = cfg.view

    local function is_open()
        return st.handle ~= nil and st.handle.valid and st.handle.valid()
    end

    -- ── commit rows ──────────────────────────────────────────────────────────
    --- Build one commit row: the coloured graph column + short id + subject + ref badges + dim meta,
    --- all in the label with per-segment `label_spans` (byte ranges → highlights).
    ---@param i integer
    ---@param c Commit
    ---@return table
    local function commit_row(i, c)
        local name = "c" .. i
        st.registry[name] = c
        local spans = {}
        local label = ""
        local function seg(text, hl)
            local start = #label
            label = label .. text
            if hl then
                spans[#spans + 1] = { start, #label, hl }
            end
        end
        if cfg.graph and st.graphs[i] then
            local gt, gsegs = graph.row_text(st.graphs[i])
            local base = #label
            label = label .. gt .. " "
            for _, s in ipairs(gsegs) do
                spans[#spans + 1] = { base + s[1], base + s[2], s[3] }
            end
        end
        seg(c.abbrev or "", ID_HL)
        seg("  ")
        for _, d in ipairs(c.refs or {}) do
            local text, badge_hl = badge_for(d)
            seg(text, badge_hl)
            seg(" ")
        end
        seg(c.subject or "", SUBJECT_HL)
        local meta = "  " .. (c.author or "") .. (rel_date(c.date) ~= "" and (" · " .. rel_date(c.date)) or "")
        seg(meta, "LvimGitBlame")
        return {
            type = "action",
            name = name,
            flat = true,
            tight = true,
            icon = "",
            label = label,
            label_spans = spans,
            _item = { commit = c },
            run = function()
                if cfg.on_action then
                    cfg.on_action(c)
                end
            end,
        }
    end

    --- The optional filter bar sector (a `type="bar"` header row).
    ---@return table?
    local function filter_bar()
        if not cfg.filters then
            return nil
        end
        local fb = ui_filters.bar({
            { id = "filter", active = cfg.filters.active, buttons = cfg.filters.buttons },
        }, {
            on_select = function(_, id)
                cfg.filters.active = id
                cfg.filters.on_select(id)
            end,
        })
        return { type = "bar", name = "filter", align = "center", items = fb.band.items }
    end

    ---@return table[]
    local function build_rows()
        st.registry = {}
        local rows = {}
        local fb = filter_bar()
        if fb then
            rows[#rows + 1] = fb
        end
        if #st.commits == 0 then
            rows[#rows + 1] = {
                type = "spacer",
                name = "empty",
                label = "  No commits",
                hl = { inactive = "LvimUiPathDim" },
            }
            return rows
        end
        for i, c in ipairs(st.commits) do
            rows[#rows + 1] = commit_row(i, c)
        end
        return rows
    end

    -- ── the detail preview ───────────────────────────────────────────────────
    --- Fetch a commit's detail (message + diffstat) once, cache it, and repaint the preview.
    ---@param c Commit
    local function load_detail(c)
        if st.detail_cache[c.id] then
            if st.preview_pan and st.preview_pan.refresh then
                st.preview_pan.refresh()
            end
            return
        end
        backend.output(
            cfg.root,
            git_argv({ "show", "--no-color", "--stat", "--patch", "--format=medium", c.id }),
            function(out)
                local lines, hls = M.color_commit_show(out)
                if #lines == 0 then
                    lines = { "" }
                end
                st.detail_cache[c.id] = { lines = lines, hls = hls }
                if is_open() and st.focused and st.focused.id == c.id and st.preview_pan then
                    if st.preview_pan.refresh then
                        st.preview_pan.refresh()
                    end
                end
            end
        )
    end

    ---@param width integer
    ---@return string[] lines, table[] hls
    local function preview_content(width) ---@diagnostic disable-line: unused-local
        local c = st.focused
        if not c then
            return { "", "  " .. GLYPH.arrow .. " select a commit" }, { { 1, 0, -1, "LvimUiPathDim" } }
        end
        local d = st.detail_cache[c.id]
        if d then
            return d.lines, d.hls
        end
        return { "", "  loading " .. (c.abbrev or "") .. " …" }, { { 1, 0, -1, "LvimUiPathDim" } }
    end

    ---@return table
    --- Start the `diff` treesitter highlighter on the detail preview. The commit body IS a unified diff, and
    --- lvim-treesitter's `queries/diff/injections.scm` injects EACH file's own language into its hunks
    --- (inferred from the `+++ b/<path>` header via `injection.filename`) — so a multi-file commit highlights
    --- every file with its real parser, with no extension table here. The panel's own add/delete washes are
    --- bg-ONLY, so the injected syntax reads through them instead of being repainted flat.
    --- Idempotent: the preview buffer is reused across focus changes and treesitter re-parses on every paint.
    ---@param pan table?
    local function apply_preview_syntax(pan)
        if not (pan and pan.win and api.nvim_win_is_valid(pan.win)) then
            return
        end
        local buf = api.nvim_win_get_buf(pan.win)
        if vim.b[buf].lvim_git_diff_ts then
            return
        end
        vim.bo[buf].syntax = "" -- no regex-syntax double-paint under the treesitter highlighter
        if pcall(vim.treesitter.start, buf, "diff") then
            vim.b[buf].lvim_git_diff_ts = true
        end
    end

    local function build_preview()
        return {
            hide_cursor = true,
            filetype = "lvim-git-log-detail",
            size = function()
                return math.max(50, math.floor(vim.o.columns * 0.5)), 20
            end,
            render = preview_content,
            keys = function(_, pan)
                st.preview_pan = pan
                -- Attach the diff highlighter once the panel's window is actually realised (scheduled: at
                -- `keys` time the surface may not have laid the window out yet, and the attach is a no-op
                -- without a valid win).
                vim.schedule(function()
                    apply_preview_syntax(pan)
                end)
            end,
            on_close = function()
                st.preview_pan = nil
            end,
        }
    end

    local function update_preview()
        local pan = st.preview_pan
        -- Attach OUTSIDE the focus gate below: the highlighter belongs to the buffer regardless of which
        -- window is current, and this is the path that runs on every commit focus change.
        apply_preview_syntax(pan)
        if pan and pan.win and api.nvim_win_is_valid(pan.win) and api.nvim_get_current_win() ~= pan.win then
            if pan.refresh then
                pan.refresh()
            end
        end
    end

    -- ── rebuild / reload ──────────────────────────────────────────────────────
    local function rebuild()
        if not is_open() then
            return
        end
        st.tabs[1].rows = build_rows()
        local idx = st.handle.cursor_index()
        st.handle.recalc()
        st.handle.focus_index(idx)
        update_preview()
    end

    --- Reload the commit list from the caller's loader (recomputing the graph), then rebuild.
    local function reload()
        cfg.load(function(commits)
            st.commits = commits or {}
            st.graphs = cfg.graph and graph.compute(st.commits) or {}
            st.detail_cache = {}
            rebuild()
        end)
    end

    -- ── the cursor commit ─────────────────────────────────────────────────────
    local function cur_commit()
        local name = st.handle and st.handle.cursor_name and st.handle.cursor_name()
        return name and st.registry[name] or nil
    end

    -- ── the help window (canonical cheatsheet) ────────────────────────────────
    local function show_help()
        local items = {
            { "j / k", "next / previous commit" },
            { "<CR> / a", "commit actions (checkout / cherry-pick / reset / …)" },
        }
        if cfg.on_view_diff then
            items[#items + 1] = { "d", "view this commit's diff" }
        end
        items[#items + 1] = { "y", "yank the commit hash" }
        if cfg.on_options then
            items[#items + 1] = { "o", "log options (author / grep / max-count / …)" }
        end
        if cfg.filters then
            items[#items + 1] = { "<C-f>", "cycle the filter" }
        end
        if cfg.on_more then
            items[#items + 1] = { "+", "load more commits" }
        end
        items[#items + 1] = { "<Tab>", "toggle the detail preview" }
        items[#items + 1] = { "?", "dispatch (all commands)" }
        items[#items + 1] = { "q / <Esc>", "close" }
        for _, it in ipairs(cfg.help_items or {}) do
            items[#items + 1] = it
        end
        ui.help({ title = cfg.title.text .. " keymaps", items = items, close_keys = { "q", "<Esc>" } })
    end

    -- ── keymaps ────────────────────────────────────────────────────────────────
    local function build_keymaps()
        local km = {}
        km[#km + 1] = {
            key = "a",
            run = function()
                local c = cur_commit()
                if c and cfg.on_action then
                    cfg.on_action(c)
                end
            end,
        }
        km[#km + 1] = {
            key = "y",
            run = function()
                local c = cur_commit()
                if c then
                    vim.fn.setreg("+", c.id)
                    vim.fn.setreg('"', c.id)
                    notify("yanked " .. (c.abbrev or c.id))
                end
            end,
        }
        if cfg.on_view_diff then
            km[#km + 1] = {
                key = "d",
                run = function()
                    local c = cur_commit()
                    if c then
                        cfg.on_view_diff(c)
                    end
                end,
            }
        end
        if cfg.on_options then
            km[#km + 1] = { key = "o", run = cfg.on_options }
        end
        if cfg.on_more then
            km[#km + 1] = { key = "+", run = cfg.on_more }
        end
        if cfg.filters then
            km[#km + 1] = {
                key = "<C-f>",
                run = function()
                    local ids = {}
                    for _, b in ipairs(cfg.filters.buttons) do
                        ids[#ids + 1] = b.id
                    end
                    local i = 1
                    for j, id in ipairs(ids) do
                        if id == cfg.filters.active then
                            i = j
                        end
                    end
                    local nid = ids[i % #ids + 1]
                    cfg.filters.active = nid
                    cfg.filters.on_select(nid)
                end,
            }
        end
        km[#km + 1] = { key = "g?", run = show_help }
        km[#km + 1] = {
            key = "?",
            run = function()
                require("lvim-git.ui.dispatch").open()
            end,
        }
        return km
    end

    -- ── autocmds ─────────────────────────────────────────────────────────────
    local function setup_autocmds()
        if st.augroup then
            pcall(api.nvim_del_augroup_by_id, st.augroup)
        end
        st.augroup = api.nvim_create_augroup("lvim-git.logpanel." .. cfg.view, { clear = true })
        api.nvim_create_autocmd("User", {
            group = st.augroup,
            pattern = "LvimGitRepoChanged",
            callback = function()
                reload()
            end,
        })
    end

    -- ── teardown / open ──────────────────────────────────────────────────────
    local function teardown()
        if st.augroup then
            pcall(api.nvim_del_augroup_by_id, st.augroup)
            st.augroup = nil
        end
        st.handle = nil
        st.tabs = nil
        st.preview_pan = nil
        st.focused = nil
    end

    local function open_frame()
        st.tabs = {
            { label = cfg.title.text, icon = cfg.title.icon, menu = true, rows = build_rows() },
        }
        st.handle = ui.tabs({
            title = cfg.title,
            title_pos = "center",
            subtitle = cfg.subtitle,
            tabs = st.tabs,
            layout = is_tab and "float" or cfg.layout,
            slot = is_tab and workspace.slot() or nil,
            pad = 0,
            cursorline_hl = "LvimUiCursorLine",
            content_width = 0.45,
            preview = build_preview(),
            preview_side = "right",
            keymaps = build_keymaps(),
            on_item_change = function(item)
                st.focused = item and item.commit or nil
                if st.focused then
                    load_detail(st.focused)
                end
                update_preview()
            end,
            on_open = function()
                setup_autocmds()
            end,
            callback = function()
                teardown()
                if is_tab then
                    workspace.exit(view)
                end
            end,
        })
    end

    -- A `tab` layout enters the dedicated workspace tabpage first (so the surface opens inside it).
    if is_tab then
        workspace.enter(view)
    end
    -- initial load, then open.
    cfg.load(function(commits)
        st.commits = commits or {}
        st.graphs = cfg.graph and graph.compute(st.commits) or {}
        open_frame()
    end)

    return {
        root = cfg.root,
        is_open = is_open,
        win = function()
            return st.handle and st.handle.win and st.handle.win()
        end,
        close = function()
            if is_open() then
                st.handle.close()
            end
        end,
        reload = reload,
        --- Move the cursor to a commit row by its abbrev (best-effort).
        ---@param abbrev string
        focus_commit = function(abbrev)
            for name, c in pairs(st.registry) do
                if c.abbrev == abbrev and st.handle and st.handle.focus then
                    st.handle.focus(name)
                    return
                end
            end
        end,
    }
end

--- Colour a `git show` (or `jj op show`) block into lines + hls following the canon shared by every commit
--- detail preview. The output is walked in PHASES so the whole thing reads as one styled document:
---   • header  — `commit <sha>` → dim label + orange sha ; `Author:`/`Merge:` → dim label + green ; `Date:`
---                → dim label + purple.
---   • message — the block git indents by 4 spaces: the indent is STRIPPED (so the subject sits flush-left,
---                not pushed in) and the whole message is painted yellow.
---   • diff    — the file-header meta (`diff --git`, `index`, `--- a/`, `+++ b/`, mode/rename lines) → dim ;
---                hunk `@@` → id colour ; `+`/`-` content → add green / del red ; and any `| N ++--` diffstat
---                bar → per-char green/red. Nothing in the diff is left the default fg.
--- Appends to the given `lines`/`hls` (so a caller can prepend its own header rows) — both default to fresh
--- tables. `phase` starts "pre" and only enters the message state AFTER a real git header, so non-git output
--- (jj op show) never has lines mis-stripped as a message.
---@param out string?  the raw `git show` / `jj op show` output
---@param lines? string[]
---@param hls? table[]
---@return string[] lines, table[] hls
function M.color_commit_show(out, lines, hls)
    lines = lines or {}
    hls = hls or {}
    local phase = "pre" ---@type "pre"|"header"|"message"|"diff"
    for line in ((out or "") .. "\n"):gmatch("(.-)\n") do
        local text, n = line, #lines
        -- ── header ──────────────────────────────────────────────────────────────
        if phase ~= "diff" and line:match("^commit ") then
            phase = "header"
            hls[#hls + 1] = { n, 0, 7, "LvimUiPathDim" } -- "commit " label
            hls[#hls + 1] = { n, 7, -1, DETAIL_SHA_HL } -- the sha
        elseif phase == "header" and (line:match("^Author:") or line:match("^Merge:")) then
            hls[#hls + 1] = { n, 0, 7, "LvimUiPathDim" }
            hls[#hls + 1] = { n, 7, -1, DETAIL_AUTHOR_HL }
        elseif phase == "header" and line:match("^Date:") then
            hls[#hls + 1] = { n, 0, 7, "LvimUiPathDim" }
            hls[#hls + 1] = { n, 7, -1, DETAIL_DATE_HL }
        elseif phase == "header" and line == "" then
            phase = "message" -- the blank line that opens the indented message block
        -- ── message (git's 4-space indent stripped so it sits flush-left) ─────────
        elseif phase == "message" and (line == "" or line:match("^    ")) then
            text = line:gsub("^    ", "")
            if text ~= "" then
                hls[#hls + 1] = { n, 0, -1, SUBJECT_HL }
            end
        else
            -- ── diff / diffstat (everything after the message) ───────────────────
            if phase == "message" then
                phase = "diff"
            end
            if line:match("^@@") then
                hls[#hls + 1] = { n, 0, -1, "LvimGitLogId" } -- hunk header
            elseif
                line:match("^diff ")
                or line:match("^index ")
                or line:match("^%-%-%- ")
                or line:match("^%+%+%+ ")
                or line:match("^new file")
                or line:match("^deleted file")
                or line:match("^old mode")
                or line:match("^new mode")
                or line:match("^similarity ")
                or line:match("^rename ")
                or line:match("^copy ")
            then
                hls[#hls + 1] = { n, 0, -1, "LvimUiPathDim" } -- diff file-header meta
            elseif line:sub(1, 1) == "+" then
                hls[#hls + 1] = { n, 0, -1, "LvimGitDiffAdd" }
            elseif line:sub(1, 1) == "-" then
                hls[#hls + 1] = { n, 0, -1, "LvimGitDiffDelete" }
            else
                -- diffstat row (` file | N ++--`): colour each char of the trailing +/- bar green / red.
                local bar = line:match("|%s*%d*%s*([%+%-]+)%s*$")
                if bar then
                    local s = line:find("[%+%-]+%s*$") - 1 -- 0-based byte start of the bar
                    for k = 1, #bar do
                        local grp = bar:sub(k, k) == "+" and "LvimGitDiffAdd" or "LvimGitDiffDelete"
                        hls[#hls + 1] = { n, s + k - 1, s + k, grp }
                    end
                end
            end
        end
        lines[#lines + 1] = text
    end
    return lines, hls
end

--- The shared repo-band subtitle (branch ➤ ahead/behind ➤ HEAD subject + colocated badge). A view can
--- append its own scope segment (`extra`).
---@param root string
---@param extra? string  an appended segment (e.g. the revset / the file path)
---@return fun(): table[]?
function M.repo_band(root, extra)
    return function()
        local repo = backend.repo(root)
        if not repo then
            return nil
        end
        -- Same per-part palette as the status page's repo band (one line, inline `hls` spans): branch green ·
        -- ahead orange · behind teal · scope segment yellow. The git icon is built INTO the branch text so the
        -- byte offsets are exact.
        ---@type { text: string, accent: string }[]
        local parts = {}
        local branch = repo.branch or (repo.detached and "detached HEAD" or "?")
        parts[#parts + 1] = { text = GLYPH.git .. " " .. branch, accent = "green" }
        if (repo.ahead or 0) > 0 then
            parts[#parts + 1] = { text = "\u{f062}" .. tostring(repo.ahead), accent = "orange" }
        end
        if (repo.behind or 0) > 0 then
            parts[#parts + 1] = { text = "\u{f063}" .. tostring(repo.behind), accent = "teal" }
        end
        if extra and extra ~= "" then
            parts[#parts + 1] = { text = extra, accent = "yellow" }
        end
        local text, hls = hl.band_line(parts, " " .. GLYPH.arrow .. " ")
        if repo.colocated and config.colocated.indicator then
            text = text .. "   " .. GLYPH.git .. " git+jj"
            -- Colocated drift (a conflicted bookmark git and jj both moved) — flag it in the band.
            local ss = require("lvim-git.backend.sync").sync_state(root)
            if ss and ss.drift then
                text = text .. " " .. GLYPH.drift .. " drift"
            end
        end
        return { { text = text, hls = hls } }
    end
end

--- Helper: resolve the sticky/config layout for a view.
---@param view string
---@param token? string
---@return string
function M.layout_for(view, token)
    return commands.layout_for(view, token)
end

return M
