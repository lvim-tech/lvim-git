-- lvim-git.ui.commit: the COMMIT MESSAGE PANEL — the compose/amend/reword surface. A canonical
-- lvim-ui.surface (never a raw float / `vim.ui.*`) with an EDITABLE message block (subject + body, a
-- real buffer with a per-mode cursor via `lvim-utils.cursor`, the lvim-replace inputs precedent) above a
-- read-only STAGED-DIFF block (Magit's verbose commit context). A meta band shows the branch, the staged
-- count and the active flags (amend / signoff / …). Confirm composes the message, writes it to a temp
-- file and commits via `git commit -F <file>` (stdin-style handoff, per the plan) through the shared
-- `actions.execute` seam — so the commit fires `User LvimGitRepoChanged` and every panel + the gutter
-- signs refresh. This is the plugin's OWN compose panel; git-spawned editors (annotated tag, the later
-- rebase todo) instead go through `backend/editor.lua`.
--
-- PUBLIC: open(opts). Internal otherwise.
--
---@module "lvim-git.ui.commit"

local api = vim.api
local config = require("lvim-git.config")
local backend = require("lvim-git.backend")
local actions = require("lvim-git.actions")
local surface = require("lvim-ui.surface")
local cursor = require("lvim-utils.cursor")

local M = {}

---@class LvimGitCommitState
---@field handle table?      the surface handle
---@field root string?
---@field vcs string?
---@field mode string?       "commit"|"amend"|"reword"
---@field args string[]?     the assembled infix argv
---@field msg_buf integer?   the editable message buffer
---@field submitted boolean?
local state = {}

---@param msg string
---@param level? integer
local function notify(msg, level)
    vim.notify("lvim-git: " .. msg, level or vim.log.levels.INFO)
end

--- The git argv prefix.
---@param sub string[]
---@return string[]
local function git_argv(sub)
    local a = { config.git.cmd, "--no-optional-locks", "-c", "color.ui=false" }
    vim.list_extend(a, sub)
    return a
end

-- ── data ─────────────────────────────────────────────────────────────────────

--- Fetch the current HEAD commit message (for amend / reword prefill). `cb(lines)`.
---@param root string
---@param cb fun(lines: string[])
local function head_message(root, cb)
    backend.output(root, git_argv({ "log", "-1", "--format=%B" }), function(out)
        local lines = vim.split(vim.trim(out or ""), "\n", { plain = true })
        cb(#lines > 0 and lines or { "" })
    end)
end

--- Fetch the staged diff (index vs HEAD) for the context block. `cb(lines, hls)`.
---@param root string
---@param cb fun(lines: string[], hls: table[])
local function staged_diff(root, cb)
    local ctx = config.diffview.context or 3
    backend.output(root, git_argv({ "diff", "--cached", "--no-color", "-U" .. tostring(ctx) }), function(out)
        local lines, hls = {}, {}
        for line in ((out or "") .. "\n"):gmatch("(.-)\n") do
            local first = line:sub(1, 1)
            lines[#lines + 1] = line
            if line:match("^@@") then
                hls[#hls + 1] = { #lines - 1, 0, -1, "LvimGitLogId" }
            elseif line:match("^%+%+%+") or line:match("^%-%-%-") or line:match("^diff ") then
                hls[#hls + 1] = { #lines - 1, 0, -1, "LvimUiPathDim" }
            elseif first == "+" then
                hls[#hls + 1] = { #lines - 1, 0, -1, "LvimGitDiffAdd" }
            elseif first == "-" then
                hls[#hls + 1] = { #lines - 1, 0, -1, "LvimGitDiffDelete" }
            end
        end
        if #lines == 0 then
            lines = { "  (nothing staged)" }
        end
        cb(lines, hls)
    end)
end

-- ── the message → commit ───────────────────────────────────────────────────────

--- Compose the message from the editable buffer: drop `#`-comment lines and trailing blanks.
---@param buf integer
---@return string
local function compose(buf)
    local raw = api.nvim_buf_get_lines(buf, 0, -1, false)
    local kept = {}
    for _, l in ipairs(raw) do
        if l:sub(1, 1) ~= "#" then
            kept[#kept + 1] = l
        end
    end
    while #kept > 0 and vim.trim(kept[#kept]) == "" do
        kept[#kept] = nil
    end
    return table.concat(kept, "\n")
end

--- The git subcommand for the current mode (message supplied via `-F <file>`).
---@param mode string
---@param file string
---@param args string[]
---@return string[]
local function commit_argv(mode, file, args)
    local a
    if mode == "amend" then
        a = { "commit", "--amend", "-F", file }
    elseif mode == "reword" then
        a = { "commit", "--amend", "--only", "-F", file }
    else
        a = { "commit", "-F", file }
    end
    return vim.list_extend(a, args)
end

--- Close the panel (guarded).
local function close()
    if state.handle and state.handle.close then
        pcall(state.handle.close)
    end
end

--- Submit: compose → write a temp file → commit via the shared seam → close + refresh.
local function submit()
    local buf = state.msg_buf
    if not (buf and api.nvim_buf_is_valid(buf)) then
        return
    end
    local msg = compose(buf)
    local allow_empty = vim.tbl_contains(state.args or {}, "--allow-empty")
    if vim.trim(msg) == "" and state.mode ~= "reword" and not allow_empty then
        notify("aborting commit due to empty message", vim.log.levels.WARN)
        return
    end
    local file = vim.fn.tempname()
    vim.fn.writefile(vim.split(msg, "\n", { plain = true }), file)
    state.submitted = true
    local argv = commit_argv(state.mode or "commit", file, state.args or {})
    actions.execute(state.root, argv, {
        op = state.mode == "commit" and "commit" or (state.mode .. " commit"),
        vcs = state.vcs,
        head_changed = state.mode ~= "commit",
    }, function()
        pcall(vim.fn.delete, file)
    end)
    close()
end

-- ── open ─────────────────────────────────────────────────────────────────────

--- Build + show the panel with the given prefill lines.
---@param prefill string[]
local function open_frame(prefill)
    local repo = backend.repo(state.root)
    local branch = (repo and repo.branch) or "detached HEAD"
    local flags = {}
    for _, a in ipairs(state.args or {}) do
        if a:match("^%-%-") then
            flags[#flags + 1] = a
        end
    end
    local title = ({ commit = "Commit", amend = "Amend", reword = "Reword" })[state.mode] or "Commit"

    local painted = false
    local msg_provider = {
        editable = true,
        cursorline = false,
        filetype = "gitcommit",
        update = function(pan)
            if not painted then
                painted = true
                state.msg_buf = pan.buf
                surface.paint(pan, #prefill > 0 and prefill or { "" }, {})
            end
        end,
        keys = function(_, pan)
            state.msg_buf = pan.buf
            cursor.mark_cursor_buffer(pan.buf, "n-v-c:ver1-LvimUtilsHiddenCursor")
        end,
    }

    local diff_lines, diff_hls = { "  loading…" }, {}
    local diff_provider = {
        hide_cursor = true,
        filetype = "lvim-git-diff",
        update = function(pan)
            surface.paint(pan, diff_lines, diff_hls)
        end,
    }

    local subtitle = {
        { text = " " .. branch, hl = "LvimGitRefHead" },
    }
    if #flags > 0 then
        subtitle[#subtitle + 1] = { text = table.concat(flags, " "), hl = "LvimGitTransientValue" }
    end

    state.handle = surface.open({
        mode = "float",
        enter = true,
        title = { icon = "\u{e729}", text = title }, --  nf-dev-git_commit
        subtitle = subtitle,
        size = { width = { fixed = 0.7 }, height = { fixed = 0.7 } },
        content = {
            blocks = {
                { id = "message", provider = msg_provider, size = { height = { fixed = 8 } } },
                { id = "diff", provider = diff_provider },
            },
        },
        close_keys = { "q" },
        keymaps = {
            { key = { "<C-c><C-c>" }, run = submit },
            { key = { "<C-c><C-k>" }, run = close },
        },
        footer = {
            bars = {
                {
                    align = "center",
                    items = {
                        surface.button(
                            { name = "commit", key = "<C-c><C-c>", style = "action", run = submit },
                            "action"
                        ),
                        surface.button(
                            { name = "cancel", key = "<C-c><C-k>", style = "action", run = close },
                            "action"
                        ),
                    },
                },
            },
        },
        on_close = function()
            state.handle = nil
            state.msg_buf = nil
        end,
    })

    -- Fill the staged-diff block once its data arrives.
    staged_diff(state.root, function(lines, hls)
        diff_lines, diff_hls = lines, hls
        if state.handle and state.handle.focus_block then
            -- repaint by re-focusing the diff block's provider update (the surface repaints on relayout)
            if state.handle.relayout then
                pcall(state.handle.relayout)
            end
        end
    end)

    -- Land in the message block, in insert (a compose-first flow) for a fresh message.
    vim.schedule(function()
        if state.handle and state.handle.focus_block then
            pcall(state.handle.focus_block, "message")
            if state.mode == "commit" then
                vim.cmd("startinsert")
            end
        end
    end)
end

--- Open the commit message panel. `opts = { root, vcs?, args?, mode? }`.
---@param opts { root: string, vcs?: string, args?: string[], mode?: "commit"|"amend"|"reword" }
function M.open(opts)
    opts = opts or {}
    if not opts.root then
        notify("not inside a git repository", vim.log.levels.WARN)
        return
    end
    if state.handle then
        close()
    end
    state.root = opts.root
    state.vcs = opts.vcs
    state.mode = opts.mode or "commit"
    state.args = opts.args or {}
    state.submitted = false
    state.msg_buf = nil

    if state.mode == "amend" or state.mode == "reword" then
        head_message(state.root, function(lines)
            open_frame(lines)
        end)
    else
        open_frame({ "" })
    end
end

return M
