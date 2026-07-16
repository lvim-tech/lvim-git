-- lvim-git.sequencer: the interactive-rebase TODO panel + the in-progress SEQUENCE state — Magit's
-- `magit-rebase` todo editing and the sequencer status section, over git's REAL machinery (never a
-- hand-rolled rebase).
--
-- When a `git rebase -i` starts, git spawns its SEQUENCE editor on the `git-rebase-todo` file. The
-- with-editor bridge (`backend/editor.lua`) routes that file HERE (we self-register the opener via
-- `editor.on_todo` in `setup`), so the todo opens in a themed, navigable panel: one row per commit with
-- its action (pick / reword / edit / squash / fixup / drop), settable with single keys and re-orderable
-- with `K`/`J`. Submitting serialises the rows back to the todo file and releases git, which then drives
-- the real rebase (reword/squash message edits ride the SAME bridge → the commit message surface); a
-- stop (an `edit` step or a conflict) simply exits the rebase, and the SEQUENCER STATUS SECTION in the
-- status surface then offers continue / skip / abort / edit-todo, driven off the GIT_DIR marker files the
-- backend already reads.
--
-- PUBLIC: `state(root)` — the render-safe cached in-progress sequence (rebase / cherry-pick / revert), so
-- a statusline or custom renderer can surface "rebasing 3/8" without shelling. Populated by `load`.
--
---@module "lvim-git.sequencer"

local uv = vim.uv or vim.loop
local config = require("lvim-git.config")
local backend = require("lvim-git.backend")
local commands = require("lvim-git.commands")
local ui = require("lvim-ui")

local M = {}

-- ── glyphs (verified single-width Nerd Font, + the `➤` pointer canon) ──────────
local GLYPH = {
    git = "\u{e725}", --  nf-dev-git_branch (title + repo band)
    todo = "\u{e725}", --  nf-dev-git_branch (todo title)
    pointer = "➤", -- U+27A4 the pointer canon (the current / active commit)
}

--- The git argv prefix (matching backend/git.lua): repo-agnostic globals for safe, concurrent parsing.
---@param extra string[]
---@return string[]
local function git_argv(extra)
    local a = { config.git.cmd, "--no-optional-locks", "-c", "color.ui=false" }
    vim.list_extend(a, extra)
    return a
end

-- ── the todo action vocabulary ─────────────────────────────────────────────────

--- The pick-family actions a commit row can hold: each maps to its palette accent (highlights.lua) and
--- the single key that sets it. `exec`/`break`/`label`/`reset`/`merge` lines are round-tripped verbatim
--- (not offered as settable actions in v1) so a `--rebase-merges` / `-x` todo survives an edit intact.
---@type table<string, { hl: string, key: string }>
local ACTIONS = {
    pick = { hl = "LvimGitSeqPick", key = "p" },
    reword = { hl = "LvimGitSeqReword", key = "r" },
    edit = { hl = "LvimGitSeqEdit", key = "e" },
    squash = { hl = "LvimGitSeqSquash", key = "s" },
    fixup = { hl = "LvimGitSeqFixup", key = "f" },
    drop = { hl = "LvimGitSeqDrop", key = "d" },
}

---@type string[]  the `<CR>` cycle order
local CYCLE = { "pick", "reword", "edit", "squash", "fixup", "drop" }

---@type table<string, string>  git's short todo keywords → the full action name
local SHORT = {
    p = "pick",
    r = "reword",
    e = "edit",
    s = "squash",
    f = "fixup",
    d = "drop",
    x = "exec",
    b = "break",
    l = "label",
    t = "reset",
    m = "merge",
}

--- The accent highlight for an action keyword (dim for the round-tripped non-commit commands).
---@param action string
---@return string
local function action_hl(action)
    local a = ACTIONS[action]
    return a and a.hl or "LvimUiPathDim"
end

-- ── todo parse / serialize (pure — headless-testable) ───────────────────────────

---@class LvimGitTodoEntry
---@field action  string   pick|reword|edit|squash|fixup|drop|exec|break|label|reset|merge|…
---@field sha?     string   the commit sha (pick-family rows)
---@field subject? string   the commit subject (display; pick-family rows)
---@field rest?    string   the raw remainder round-tripped for non-commit commands (exec/label/…)
---@field commit   boolean  true for pick-family rows (the action is settable / re-orderable as a commit)

--- Parse a `git-rebase-todo` file body into ordered entries. Comment (`#`) and blank lines (the trailer
--- git appends) are dropped; every command line becomes an entry. Short keywords are normalised to the
--- full action; a pick-family line splits into `action sha subject`, any other command keeps its raw
--- remainder so it serialises back byte-for-byte.
---@param text string
---@return LvimGitTodoEntry[]
function M.parse_todo(text)
    ---@type LvimGitTodoEntry[]
    local entries = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
        local trimmed = vim.trim(line)
        if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then
            local word, rest = trimmed:match("^(%S+)%s*(.*)$")
            local action = SHORT[word] or word
            if ACTIONS[action] then
                local sha, subject = rest:match("^(%S+)%s*(.*)$")
                -- Newer git (2.52+) writes the oneline as a `# <subject>` decorative comment after the sha
                -- (git re-derives the real message from the sha and ignores this text); strip the `# ` so
                -- the panel shows a clean subject. Older git has no prefix — the gsub is then a no-op.
                subject = subject and subject:gsub("^#%s*", "") or subject
                entries[#entries + 1] = { action = action, sha = sha, subject = subject, commit = true }
            else
                entries[#entries + 1] = { action = action, rest = rest, commit = false }
            end
        end
    end
    return entries
end

--- Serialise entries back into todo-file lines (git re-reads them as the rebase plan).
---@param entries LvimGitTodoEntry[]
---@return string[]
function M.serialize(entries)
    local lines = {}
    for _, e in ipairs(entries) do
        if e.commit then
            local tail = (e.subject and e.subject ~= "") and (" " .. e.subject) or ""
            lines[#lines + 1] = e.action .. " " .. (e.sha or "") .. tail
        else
            lines[#lines + 1] = e.action .. (e.rest and e.rest ~= "" and (" " .. e.rest) or "")
        end
    end
    return lines
end

-- ── the interactive todo PANEL ──────────────────────────────────────────────────

--- Open the interactive-rebase todo panel for `file` (git's `git-rebase-todo`). Called by the with-editor
--- bridge with a `ctrl` whose `submit`/`cancel` write the todo back + release git. Returns a handle with
--- `.close` so the bridge can dismiss the panel on preemption. The panel is a themed `lvim-ui.tabs` menu:
--- one selectable row per commit, single keys set the action, `K`/`J` reorder, `<C-c><C-c>` starts the
--- rebase, `q`/`<Esc>` aborts it.
---@param file string
---@param fifo string
---@param ctrl LvimGitEditorTodoCtrl
---@return table handle
function M.edit_todo(file, fifo, ctrl) ---@diagnostic disable-line: unused-local
    local ok, existing = pcall(vim.fn.readfile, file)
    local st = {
        entries = M.parse_todo(table.concat((ok and existing) or {}, "\n")), ---@type LvimGitTodoEntry[]
        registry = {}, ---@type table<string, integer>  row name → entry index
        handle = nil, ---@type table?
        tabs = nil, ---@type table[]?
    }

    local function is_open()
        return st.handle ~= nil and st.handle.valid and st.handle.valid()
    end

    --- One commit / command row: the action word (accented) + short sha + subject, per-segment coloured.
    ---@param i integer
    ---@param e LvimGitTodoEntry
    ---@return table
    local function entry_row(i, e)
        local name = "e" .. i
        st.registry[name] = i
        local spans, label = {}, ""
        local function seg(text, hl)
            local s = #label
            label = label .. text
            if hl then
                spans[#spans + 1] = { s, #label, hl }
            end
        end
        if e.commit then
            seg(string.format("%-7s", e.action), action_hl(e.action))
            seg(" ")
            seg(e.sha or "", "LvimGitLogId")
            seg("  ")
            seg(e.subject or "", "LvimUiPathName")
        else
            seg(e.action, "LvimUiPathDim")
            if e.rest and e.rest ~= "" then
                seg(" " .. e.rest, "LvimUiPathDim")
            end
        end
        return {
            type = "action",
            name = name,
            flat = true,
            tight = true,
            icon = "",
            label = label,
            label_spans = spans,
            run = function()
                M._cycle(st, i)
            end,
        }
    end

    ---@return table[]
    local function build_rows()
        st.registry = {}
        local rows = {}
        if #st.entries == 0 then
            rows[#rows + 1] = {
                type = "spacer",
                name = "empty",
                label = "  (empty todo — nothing to rebase)",
                hl = { inactive = "LvimUiPathDim" },
            }
            return rows
        end
        for i, e in ipairs(st.entries) do
            rows[#rows + 1] = entry_row(i, e)
        end
        return rows
    end

    --- Re-derive the rows in place and keep the cursor on `focus_name` (the moved / edited row).
    ---@param focus_name? string
    local function rebuild(focus_name)
        if not is_open() then
            return
        end
        st.tabs[1].rows = build_rows()
        local idx = st.handle.cursor_index()
        st.handle.recalc()
        if focus_name and st.handle.focus then
            st.handle.focus(focus_name)
        else
            st.handle.focus_index(idx)
        end
    end
    st._rebuild = rebuild

    --- The entry index under the cursor (nil off a commit row).
    ---@return integer?
    local function cur_index()
        local name = st.handle and st.handle.cursor_name and st.handle.cursor_name()
        return name and st.registry[name] or nil
    end

    --- Set the cursor commit's action directly (p/r/e/s/f/d).
    ---@param action string
    local function set_action(action)
        local i = cur_index()
        if not i then
            return
        end
        local e = st.entries[i]
        if not e.commit then
            return
        end
        e.action = action
        rebuild("e" .. i)
    end

    --- Move the cursor commit up (`dir = -1`) or down (`dir = 1`), keeping the cursor on it.
    ---@param dir integer
    local function move(dir)
        local i = cur_index()
        if not i then
            return
        end
        local j = i + dir
        if j < 1 or j > #st.entries then
            return
        end
        st.entries[i], st.entries[j] = st.entries[j], st.entries[i]
        rebuild("e" .. j)
    end

    local function submit()
        ctrl.submit(M.serialize(st.entries))
    end

    -- ── the help window (canonical cheatsheet) ────────────────────────────────
    local function show_help()
        ui.help({
            title = "Interactive rebase keymaps",
            items = {
                { "p", "pick — apply the commit as-is" },
                { "r", "reword — apply, then edit the message" },
                { "e", "edit — stop after applying (amend / split)" },
                { "s", "squash — meld into the previous commit (combine messages)" },
                { "f", "fixup — meld into the previous commit (discard message)" },
                { "d", "drop — remove the commit" },
                { "<CR>", "cycle the action of the commit under the cursor" },
                { "K / J", "move the commit up / down (reorder)" },
                { "<C-c><C-c>", "start the rebase" },
                { "q / <Esc>", "abort (cancel the whole rebase)" },
            },
            close_keys = { "q", "<Esc>" },
        })
    end

    -- ── keymaps + footer ──────────────────────────────────────────────────────
    local function build_keymaps()
        local km = {}
        for _, a in ipairs(CYCLE) do
            km[#km + 1] = {
                key = ACTIONS[a].key,
                run = function()
                    set_action(a)
                end,
            }
        end
        km[#km + 1] = {
            key = "K",
            run = function()
                move(-1)
            end,
        }
        km[#km + 1] = {
            key = "J",
            run = function()
                move(1)
            end,
        }
        km[#km + 1] = { key = { "<C-c><C-c>", "ZZ" }, run = submit }
        km[#km + 1] = { key = "g?", run = show_help }
        return km
    end

    local function build_footer()
        local function chip(key, label, run)
            return { key = key, label = label, no_hotkey = true, run = run }
        end
        local sep = { type = "separator", text = "●", style = { padding = { 1, 1 }, hl = "LvimUiFooterSep" } }
        return {
            chip("p/r/e/s/f/d", "action", function() end),
            chip("K/J", "reorder", function() end),
            sep,
            chip("<C-c><C-c>", "start", submit),
            chip("g?", "help", show_help),
            chip("q/Esc", "abort", function(s)
                s.close()
            end),
        }
    end

    -- ── open ──────────────────────────────────────────────────────────────────
    local function open_frame()
        local commits = 0
        for _, e in ipairs(st.entries) do
            if e.commit then
                commits = commits + 1
            end
        end
        local hint = string.format(
            "%d commit%s  %s  p/r/e/s/f/d set  %s  K/J reorder  %s  <C-c><C-c> start",
            commits,
            commits == 1 and "" or "s",
            GLYPH.pointer,
            GLYPH.pointer,
            GLYPH.pointer
        )
        st.tabs = {
            { label = "Rebase", icon = GLYPH.todo, menu = true, rows = build_rows(), footer = build_footer() },
        }
        local layout = commands.layout_for("sequencer")
        st.handle = ui.tabs({
            title = { icon = GLYPH.todo, text = "Interactive rebase" },
            title_pos = "center",
            subtitle = { { icon = GLYPH.git, text = hint, hl = "LvimGitRefHead" } },
            tabs = st.tabs,
            layout = layout == "tab" and "float" or layout,
            pad = 0,
            cursorline_hl = "LvimUiCursorLine",
            content_width = 0.7,
            keymaps = build_keymaps(),
            callback = function()
                st.handle = nil
                -- ANY close route (q / <Esc> / a stray :q) aborts the rebase; if we already submitted,
                -- `ctrl.cancel` is a guarded no-op.
                ctrl.cancel()
            end,
        })
    end

    -- Open on the next tick: `_on_edit` runs inside git's `--remote-expr` round-trip, so we defer the
    -- (window-creating) panel build off that call — the child is already blocked on the FIFO, so nothing
    -- races. Returns a handle immediately for the bridge's preemption path.
    vim.schedule(open_frame)

    return {
        close = function()
            if is_open() then
                st.handle.close()
            end
        end,
    }
end

--- Cycle the action of entry `i` forward (pick→reword→edit→squash→fixup→drop→pick). Internal seam so the
--- row's `<CR>` closure stays tiny.
---@param st table
---@param i integer
function M._cycle(st, i)
    local e = st.entries[i]
    if not e or not e.commit then
        return
    end
    local pos = 1
    for k, a in ipairs(CYCLE) do
        if a == e.action then
            pos = k
        end
    end
    e.action = CYCLE[pos % #CYCLE + 1]
    if st._rebuild then
        st._rebuild("e" .. i)
    end
end

-- ── in-progress sequence STATE (the sequencer status section + the public read) ──

---@class LvimGitSequencerState
---@field active   boolean             a rebase / cherry-pick / revert is in progress
---@field type?    "rebase"|"cherry-pick"|"revert"
---@field onto?    string              the target/onto short sha (rebase)
---@field head_name? string            the branch being rebased (rebase)
---@field current? { sha?: string, subject?: string }  the stopped-at commit (edit step / conflict)
---@field done?    LvimGitTodoEntry[]  the commits already applied
---@field todo?    LvimGitTodoEntry[]  the commits still to apply

--- Read a file's lines (nil when it does not exist).
---@param path string
---@return string[]?
local function read_lines(path)
    if not (path and uv.fs_stat(path)) then
        return nil
    end
    local ok, lines = pcall(vim.fn.readfile, path)
    return ok and lines or nil
end

--- First line of a file (nil when absent/empty).
---@param path string
---@return string?
local function first_line(path)
    local l = read_lines(path)
    return l and l[1] or nil
end

--- Derive the in-progress sequence from the GIT_DIR marker directories (Magit's mechanism): a rebase
--- keeps its plan in `rebase-merge/{git-rebase-todo,done,onto,head-name,stopped-sha}`; a cherry-pick /
--- revert sequence keeps `sequencer/todo` alongside `CHERRY_PICK_HEAD` / `REVERT_HEAD`.
---@param dir string?  the absolute GIT_DIR
---@return LvimGitSequencerState
local function read_state(dir)
    if not dir then
        return { active = false }
    end
    local function has(p)
        return uv.fs_stat(dir .. "/" .. p) ~= nil
    end
    if has("rebase-merge") or has("rebase-apply/rebasing") then
        local base = dir .. "/rebase-merge"
        local onto = first_line(base .. "/onto")
        local head = first_line(base .. "/head-name")
        local todo = M.parse_todo(table.concat(read_lines(base .. "/git-rebase-todo") or {}, "\n"))
        local done = M.parse_todo(table.concat(read_lines(base .. "/done") or {}, "\n"))
        local current
        local stopped = first_line(base .. "/stopped-sha")
        if stopped then
            current = { sha = stopped:sub(1, 8) }
        elseif #done > 0 then
            current = { sha = done[#done].sha, subject = done[#done].subject }
        end
        return {
            active = true,
            type = "rebase",
            onto = onto and onto:sub(1, 8) or nil,
            head_name = head and head:gsub("^refs/heads/", "") or nil,
            todo = todo,
            done = done,
            current = current,
        }
    elseif has("REVERT_HEAD") then
        return {
            active = true,
            type = "revert",
            todo = M.parse_todo(table.concat(read_lines(dir .. "/sequencer/todo") or {}, "\n")),
            done = {},
        }
    elseif has("CHERRY_PICK_HEAD") or has("sequencer/todo") then
        return {
            active = true,
            type = "cherry-pick",
            todo = M.parse_todo(table.concat(read_lines(dir .. "/sequencer/todo") or {}, "\n")),
            done = {},
        }
    end
    return { active = false }
end

--- Refresh the cached sequence state for `root` (resolves the GIT_DIR, reads the marker files), then
--- `cb(state)`. The status surface calls this in its parallel data load; the cache backs `M.state`.
---@param root string
---@param cb? fun(state: LvimGitSequencerState)
function M.load(root, cb)
    backend.output(root, git_argv({ "rev-parse", "--absolute-git-dir" }), function(out)
        local dir = out and vim.trim(out)
        local s = read_state((dir and dir ~= "") and dir or nil)
        require("lvim-git.state").sequencer[root] = s
        if cb then
            cb(s)
        end
    end)
end

--- The cached in-progress sequence for `root` (render-safe, O(1)). `{ active = false }` when idle or not
--- yet loaded. Public: a statusline / custom renderer surfaces the sequence without shelling.
---@param root? string
---@return LvimGitSequencerState
function M.state(root)
    if not root then
        return { active = false }
    end
    return require("lvim-git.state").sequencer[root] or { active = false }
end

-- ── setup ────────────────────────────────────────────────────────────────────

--- Self-register the todo-panel opener with the with-editor bridge, so a git-spawned `git-rebase-todo`
--- opens in this panel. Idempotent (the bridge just stores the opener).
function M.setup()
    require("lvim-git.backend.editor").on_todo(M.edit_todo)
end

return M
