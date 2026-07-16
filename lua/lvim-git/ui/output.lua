-- lvim-git.ui.output: the streamed RAW-COMMAND output panel (fugitive's `:Git <cmd>` result window).
--
-- `:LvimGit run <git args>` runs an arbitrary command under the repo and STREAMS its stdout + stderr live
-- into this panel — a REAL native bottom-docked `lvim-ui.surface` whose scratch buffer APPENDS each chunk as
-- it arrives (never blocking the UI), then shows the exit status and refreshes the repo
-- (`User LvimGitRepoChanged`). stderr rows render dim so a warning/error stands out from stdout.
--
-- INTERACTIVE commands ride the SAME run: the command inherits the with-editor bridge env
-- (`backend.editor.env()` → `GIT_EDITOR`/`GIT_SEQUENCE_EDITOR`), so any verb that spawns an editor (a bare
-- `commit`, `rebase -i`, an annotated `tag -a`) opens in the bridge's editable surface / the sequencer todo
-- panel while its output still streams here — the clean seam git itself provides, no PTY. A truly TTY-
-- interactive command (a pager, `add -p`) is the `:LvimGit run! <cmd>` terminal variant (commands.lua), not
-- this panel.
--
-- PUBLIC: run / close / is_open. Internal otherwise. One run at a time (a new run replaces the panel).
--
---@module "lvim-git.ui.output"

local api = vim.api
local config = require("lvim-git.config")
local backend = require("lvim-git.backend")
local editor = require("lvim-git.backend.editor")
local surface = require("lvim-ui.surface")
local cursor = require("lvim-utils.cursor")

local M = {}

--- The output panel filetype (cursor hidden only while the panel is the current window — a `panel_ft`).
---@type string
local OUTPUT_FT = "lvim-git-output"

--- The `➤` sequence pointer (canon) for the exit-status footer line.
---@type string
local ARROW = "➤"

---@class LvimGitOutputSession
---@field root    string          the repo root the command ran under
---@field title   string          the panel title ("git status", …)
---@field lines   string[]        the accumulated output lines (rendered verbatim)
---@field hls     table[]         per-line full-row hls ({ row, 0, -1, group })
---@field partial table<string, string>  the trailing incomplete line per stream ("out"/"err")
---@field err_rows table<integer, boolean>  which line indices came from stderr (dim)
---@field handle table?           the lvim-ui surface handle
---@field pan    table?           the surface content panel (buf/win/refresh)
---@field obj    vim.SystemObj?   the running command handle (cancellable)
---@field done   boolean          the command has exited
---@type LvimGitOutputSession?
local session

--- One-time cursor self-registration for the output panel filetype.
---@type boolean
local registered = false

---@param msg string
---@param level? integer
local function notify(msg, level)
    vim.notify("lvim-git: " .. msg, level or vim.log.levels.INFO)
end

--- Whether the output panel is open.
---@return boolean
function M.is_open()
    return session ~= nil and session.pan ~= nil and session.pan.win ~= nil and api.nvim_win_is_valid(session.pan.win)
end

--- Rebuild the per-line hl list from the current lines (stderr rows dim, the exit line accented).
---@param s LvimGitOutputSession
local function rebuild_hls(s)
    s.hls = {}
    for i = 1, #s.lines do
        if s.err_rows[i] then
            s.hls[#s.hls + 1] = { i - 1, 0, -1, "LvimUiPathDim" }
        end
    end
end

--- Repaint the panel from `session.lines` and pin the view to the bottom (a live tail).
local function repaint()
    local s = session
    if not (s and s.pan and s.pan.refresh) then
        return
    end
    rebuild_hls(s)
    s.pan.refresh()
    if s.pan.win and api.nvim_win_is_valid(s.pan.win) and s.pan.buf and api.nvim_buf_is_valid(s.pan.buf) then
        local n = api.nvim_buf_line_count(s.pan.buf)
        pcall(api.nvim_win_set_cursor, s.pan.win, { n, 0 })
    end
end

--- Fold a stream chunk into complete lines (carrying the trailing partial line across chunks) and append
--- them to the session, marking stderr rows for the dim wash. Repaints on the main loop.
---@param stream "out"|"err"
---@param chunk string?
local function feed(stream, chunk)
    if not chunk or chunk == "" then
        return
    end
    vim.schedule(function()
        local s = session
        if not s then
            return
        end
        local text = (s.partial[stream] or "") .. chunk:gsub("\r\n", "\n"):gsub("\r", "\n")
        local parts = vim.split(text, "\n", { plain = true })
        s.partial[stream] = table.remove(parts) -- the last piece is the (possibly incomplete) trailing line
        for _, line in ipairs(parts) do
            s.lines[#s.lines + 1] = line
            if stream == "err" then
                s.err_rows[#s.lines] = true
            end
        end
        if #parts > 0 then
            repaint()
        end
    end)
end

--- Flush any trailing partial lines (a stream that ended without a final newline).
---@param s LvimGitOutputSession
local function flush_partials(s)
    for stream, rest in pairs(s.partial) do
        if rest and rest ~= "" then
            s.lines[#s.lines + 1] = rest
            if stream == "err" then
                s.err_rows[#s.lines] = true
            end
        end
    end
    s.partial = { out = "", err = "" }
end

--- Close the output panel (idempotent). Does NOT cancel a still-running command — closing just hides the
--- live output; the command completes and still fires `LvimGitRepoChanged`.
function M.close()
    local s = session
    if not s then
        return
    end
    session = nil
    if s.handle and s.handle.close then
        pcall(s.handle.close)
    end
end

--- The content provider for the native panel: renders the accumulated lines verbatim + the stderr wash.
---@return table provider
local function provider()
    return {
        filetype = OUTPUT_FT,
        cursorline = false,
        hide_cursor = true,
        size = function()
            local h = math.max(6, math.min(18, math.floor(vim.o.lines * 0.35)))
            return vim.o.columns, h
        end,
        render = function()
            local s = session
            if not s then
                return {}, {}
            end
            return s.lines, s.hls
        end,
        keys = function(map)
            map("q", function()
                M.close()
            end)
        end,
        on_close = function()
            -- the surface tore down; drop the panel refs but keep the session only if a new run replaced it.
            if session and session.pan then
                session.pan = nil
            end
        end,
    }
end

--- Open (or replace) the streamed output panel for a command and start it. `argv` is the full executable
--- argv (git/jj + args); `title` names the panel; on completion fires `LvimGitRepoChanged`.
---@param root string        the repo root (cwd)
---@param title string       the panel title
---@param argv string[]      the full command argv
function M.run(root, title, argv)
    if not registered then
        registered = true
        cursor.register({ panel_ft = { OUTPUT_FT } })
    end
    if M.is_open() then
        M.close()
    end
    session = {
        root = root,
        title = title,
        lines = { "$ " .. title, "" },
        hls = {},
        partial = { out = "", err = "" },
        err_rows = {},
        done = false,
    }
    local prov = provider()
    session.handle = surface.open({
        mode = "split",
        native = true,
        dock = "below",
        enter = true,
        persistent = true,
        normal_hl = "NormalSB",
        title = { icon = "\u{f489}", text = title }, --  nf-oct-terminal
        height = (function()
            local _, h = prov.size()
            return h
        end)(),
        content = { blocks = { { id = "output", provider = prov } } },
        close_keys = {},
        footer = {
            bars = {
                {
                    align = "center",
                    items = {
                        surface.button({ name = "close", key = "q", style = "action", run = M.close }, "action"),
                    },
                },
            },
        },
        on_close = function()
            if session then
                session.pan = nil
            end
        end,
    })
    -- Resolve the content panel (buf/win/refresh) from the handle for the live append + tail.
    session.pan = session.handle and session.handle.panels and session.handle.panels[1] or nil
    repaint()

    -- Stream the command. The bridge env lets an editor-spawning command open in our editable surface while
    -- the output still streams here (the clean git seam). The completion cb runs on the main loop.
    session.obj = backend.system(root, argv, {
        env = editor.env(),
        stdout = function(_, data)
            feed("out", data)
        end,
        stderr = function(_, data)
            feed("err", data)
        end,
    }, function(res)
        local s = session
        if not s then
            return
        end
        s.done = true
        flush_partials(s)
        local code = res.code or 0
        s.lines[#s.lines + 1] = ""
        s.lines[#s.lines + 1] = ("%s exited %d"):format(ARROW, code)
        rebuild_hls(s)
        -- Accent the exit line green (0) / red (non-zero).
        s.hls[#s.hls + 1] = { #s.lines - 1, 0, -1, code == 0 and "LvimGitDiffAdd" or "LvimGitDiffDelete" }
        repaint()
        vim.cmd("checktime")
        api.nvim_exec_autocmds("User", {
            pattern = "LvimGitRepoChanged",
            data = { root = root, reason = "run" },
        })
        if code ~= 0 then
            notify("run: `" .. title .. "` exited " .. code, vim.log.levels.WARN)
        end
    end)
end

return M
