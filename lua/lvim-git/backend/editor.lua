-- lvim-git.backend.editor: the EDITOR BRIDGE — Magit's `with-editor` mechanism, done through the seam
-- git itself provides (`GIT_EDITOR` / `GIT_SEQUENCE_EDITOR`), never a PTY game.
--
-- When a git (or jj) command wants a human to edit a file — a commit message it spawns an editor for, an
-- interactive-rebase todo, an annotated-tag message — it runs `$GIT_EDITOR <file>` and BLOCKS until that
-- process exits. We point `GIT_EDITOR` at a tiny shell script that:
--   1. asks THIS running nvim (over its RPC server) to open `<file>` in a managed editable surface, then
--   2. blocks on a FIFO until the parent writes an exit code — 0 when the user finishes, non-zero to abort.
-- The user edits the file in a real lvim-managed buffer (the canonical editable surface, never a raw
-- float / `vim.ui.*`); on finish we write the buffer back to `<file>` and unblock the child, so git
-- resumes exactly as if a terminal editor had been used. No polling loop, no blocking of the UI loop:
-- the child's `cat <fifo>` is the reader, so the parent's one-shot write returns immediately.
--
-- `M.run(root, argv, opts, cb)` runs a git command WITH this editor env in place, so any verb whose git
-- invocation spawns an editor (annotated tag, the rebase todo) routes through the bridge with one call.
-- `M.env()` exposes the env table for callers that assemble their own `vim.system` opts.
--
-- The interactive-rebase TODO is a SPECIAL editor file (`git-rebase-todo`): instead of the plain message
-- surface, the sequencer registers a dedicated todo-panel opener via `M.on_todo(...)`, and this bridge
-- hands that file to it (passing a `ctrl` with `submit`/`cancel` that write the edited todo back and
-- release git). The bridge stays the ONE seam; the sequencer owns the panel — no circular require (core
-- never statically requires the component; the component self-registers).
--
---@module "lvim-git.backend.editor"

local uv = vim.uv or vim.loop
local api = vim.api
local backend = require("lvim-git.backend")
local surface = require("lvim-ui.surface")
local cursor = require("lvim-utils.cursor")

local M = {}

-- ── the editor script + server ────────────────────────────────────────────────

---@type string?  the cached path of the generated editor script (nil until first setup)
local script_path
---@type string?  the RPC server address this instance listens on (for the child to reach back)
local server_addr

--- Ensure this nvim instance is listening on an RPC server and return its address. `v:servername` is
--- normally already set; only when it is empty (a bare `--headless -u NONE`) do we start one.
---@return string
local function ensure_server()
    if server_addr then
        return server_addr
    end
    local name = vim.v.servername
    if not name or name == "" then
        name = vim.fn.serverstart()
    end
    server_addr = name
    return name
end

--- Write the editor bridge script once (idempotent) and return its path. The script embeds THIS nvim's
--- binary (`v:progpath`) so the child re-uses the same executable, and reads the server address + the
--- file to edit at runtime. A FIFO gives a true block (no poll): the child's `cat` waits, the parent's
--- single write releases it with the exit code.
---@return string
local function ensure_script()
    if script_path and uv.fs_stat(script_path) then
        return script_path
    end
    local dir = vim.fn.stdpath("cache") .. "/lvim-git"
    vim.fn.mkdir(dir, "p")
    local path = dir .. "/with-editor.sh"
    local nvim = vim.v.progpath
    -- POSIX sh. $1 = the file git wants edited. Ask the parent to open it, then block on a FIFO until the
    -- parent writes the exit code (0 finish / non-zero abort).
    --
    -- SECURITY: the file path lives inside GIT_DIR, hence inside the REPO path, which the user controls —
    -- a repo under e.g. `/home/o'brien/…` (or a TMPDIR with the same) carries a single quote. Splicing it
    -- raw into the single-quoted `--remote-expr` Lua string would break the expression (or inject code) and
    -- the `--remote-expr` would fail, leaving the child's `cat "$fifo"` blocked forever → git hangs. So we
    -- HEX-encode both paths (`od -An -tx1` — POSIX) before they cross the expr seam: the expr then carries
    -- only `[0-9a-f]`, injection-proof whatever the repo/TMPDIR path contains, and `_on_edit` decodes them.
    local body = table.concat({
        "#!/bin/sh",
        "# lvim-git with-editor bridge — generated, do not edit.",
        'file="$1"',
        'fifo="$(mktemp -u "${TMPDIR:-/tmp}/lvim-git-editor.XXXXXX")"',
        'mkfifo "$fifo" 2>/dev/null || exit 1',
        'file_hex="$(printf %s "$file" | od -An -tx1 | tr -d " \\n")"',
        'fifo_hex="$(printf %s "$fifo" | od -An -tx1 | tr -d " \\n")"',
        string.format(
            '%s --server "$LVIM_GIT_SERVER" --remote-expr '
                .. "\"v:lua.require'lvim-git.backend.editor'._on_edit('$file_hex','$fifo_hex')\" >/dev/null 2>&1",
            vim.fn.shellescape(nvim)
        ),
        'code="$(cat "$fifo")"',
        'rm -f "$fifo"',
        'exit "${code:-1}"',
        "",
    }, "\n")
    local fd = assert(io.open(path, "w"))
    fd:write(body)
    fd:close()
    vim.fn.setfperm(path, "rwxr-xr-x")
    script_path = path
    return path
end

--- Prepare the bridge (server + script). Safe to call repeatedly; the first `env()`/`run()` triggers it.
function M.setup()
    ensure_server()
    ensure_script()
end

--- The environment that routes git's editor invocations through the bridge. Sets `GIT_EDITOR` and
--- `GIT_SEQUENCE_EDITOR` (rebase todo) to the script, `JJ_EDITOR` for the jj lens, and the server address
--- the child reaches back on.
---@return table<string, string>
function M.env()
    local script = ensure_script()
    local addr = ensure_server()
    return {
        GIT_EDITOR = script,
        GIT_SEQUENCE_EDITOR = script,
        JJ_EDITOR = script,
        LVIM_GIT_SERVER = addr,
    }
end

-- ── the parent side: open the file, block the child, finish/abort ──────────────

---@class LvimGitEditorSession
---@field file   string   the file git is waiting on
---@field fifo   string   the FIFO the child blocks reading
---@field handle table?   the editable surface / todo panel handle (nil until the panel opens)
---@field buf    integer  the editable buffer
---@field done   boolean  guards a double finish/abort

---@type LvimGitEditorSession?  the one in-flight editor session (git edits are serial)
local session

---@type boolean  the last editor session was ABORTED by the user (see `M.take_cancelled`)
local cancelled = false

--- PUBLIC: did the user CANCEL the editor session that the just-finished git command spawned? Reads and
--- CLEARS the flag, so it answers for exactly one command (the next op starts clean).
---
--- Why this exists: git has ONE channel for "the editor said no" — a non-zero editor exit — and reports it
--- as `error: there was a problem with the editor '<script>'`. To a generic error handler that is
--- indistinguishable from a real breakage, so pressing `q` on the rebase todo surfaced as
--- "rebase failed: error: there was a problem with the editor …" (plus git's own "Applied autostash."),
--- reading like the plugin broke. The bridge is the only place that KNOWS it was deliberate, so it records
--- that and the caller asks. Declared HERE, right under the state it reads — above it the name would
--- resolve to a global `nil` and the flag would never be seen.
---@return boolean
function M.take_cancelled()
    local c = cancelled
    cancelled = false
    return c == true
end

---@class LvimGitEditorTodoCtrl
---@field submit fun(lines: string[])  write the edited todo lines back and release git (0), then close
---@field cancel fun()                 leave the todo untouched and abort the rebase (release git 1), close

---@type (fun(file: string, fifo: string, ctrl: LvimGitEditorTodoCtrl): table?)?
--- The registered interactive-rebase todo-panel opener (the sequencer self-registers it). Returns a
--- handle with `.close` so the bridge can dismiss it on preemption. nil until the sequencer registers.
local todo_opener

--- Register the interactive-rebase todo-panel opener. When git spawns its SEQUENCE editor on the
--- `git-rebase-todo` file, the bridge routes it here instead of the generic message surface, so the
--- todo opens in the sequencer's dedicated pick/reword/edit/squash/fixup/drop panel. Idempotent.
---@param fn fun(file: string, fifo: string, ctrl: LvimGitEditorTodoCtrl): table?
function M.on_todo(fn)
    todo_opener = fn
end

--- Release the blocked child with an exit code by writing it to the FIFO. The child's `cat` is already
--- reading, so this one-shot write returns immediately (never blocks the UI loop). Best-effort.
---@param fifo string
---@param code integer
local function release(fifo, code)
    -- `writefile` to a FIFO returns as soon as the waiting reader consumes it; guard so a vanished child
    -- (the FIFO gone) never errors on the UI path.
    pcall(vim.fn.writefile, { tostring(code) }, fifo)
end

--- Finish the current session: write the buffer back to the file, unblock the child with 0, close the UI.
local function finish()
    local s = session
    if not s or s.done then
        return
    end
    s.done = true
    cancelled = false
    if api.nvim_buf_is_valid(s.buf) then
        local lines = api.nvim_buf_get_lines(s.buf, 0, -1, false)
        pcall(vim.fn.writefile, lines, s.file)
    end
    release(s.fifo, 0)
    session = nil
    if s.handle and s.handle.close then
        pcall(s.handle.close)
    end
end

--- Abort the current session: leave the file untouched, unblock the child with 1 (git treats a non-zero
--- editor exit as "abort the operation"), close the UI.
--- Records `cancelled` so the CALLER can tell this deliberate abort apart from a real failure: git reports
--- the non-zero editor exit as `error: there was a problem with the editor '<script>'`, which the generic
--- handler would otherwise surface as "rebase failed: <that>" — reading like a broken plugin when the user
--- simply pressed `q` (see `M.take_cancelled`).
local function abort()
    local s = session
    if not s or s.done then
        return
    end
    s.done = true
    cancelled = true
    release(s.fifo, 1)
    session = nil
    if s.handle and s.handle.close then
        pcall(s.handle.close)
    end
end

--- Decode a hex string (pairs of `[0-9a-f]`) back to its bytes. The bridge script hex-encodes the file and
--- fifo paths so the `--remote-expr` seam carries no shell/Lua metacharacter, whatever the repo path holds.
---@param hex string
---@return string
local function unhex(hex)
    return (hex:gsub("%x%x", function(cc)
        return string.char(tonumber(cc, 16))
    end))
end

--- Open `file` in a canonical editable message surface and remember the session so finish/abort can
--- release the blocked child. Called by the bridge script via `--remote-expr`; returns "" immediately so
--- the child's RPC round-trip does not wait for the edit (it waits on the FIFO instead). Both paths arrive
--- HEX-encoded (see `unhex` / the bridge script) so no repo/TMPDIR path can break or inject the expr.
---@param file_hex string  the file git wants edited, hex-encoded
---@param fifo_hex string  the FIFO the child blocks on, hex-encoded
---@return string
function M._on_edit(file_hex, fifo_hex)
    local file = unhex(file_hex)
    local fifo = unhex(fifo_hex)
    -- A second editor request while one is open aborts the previous (git serialises editor spawns, so this
    -- is only a defensive guard).
    if session then
        abort()
    end

    -- The interactive-rebase todo → the sequencer's dedicated panel (when registered). `ctrl.submit`
    -- writes the reordered/edited todo back and releases git with 0 (proceed); `ctrl.cancel` releases 1
    -- (git aborts the whole rebase). Both go through the SAME `session`/`release` bookkeeping so a stray
    -- close still unblocks the child.
    if vim.fn.fnamemodify(file, ":t") == "git-rebase-todo" and todo_opener then
        ---@type LvimGitEditorSession
        local s = { file = file, fifo = fifo, buf = -1, done = false }
        session = s
        local handle
        ---@type LvimGitEditorTodoCtrl
        local ctrl = {
            submit = function(lines)
                if s.done then
                    return
                end
                s.done = true
                cancelled = false
                pcall(vim.fn.writefile, lines, file)
                release(fifo, 0)
                session = nil
                if handle and handle.close then
                    pcall(handle.close)
                end
            end,
            -- DELEGATES to `abort` rather than repeating it: this pair used to re-implement the session
            -- bookkeeping inline (the comment above already claimed they shared it), and the copy silently
            -- fell behind when `abort` started recording `cancelled` — so cancelling the rebase todo, the
            -- one path that matters most here, still reported git's raw editor error as a failure.
            cancel = abort,
        }
        handle = todo_opener(file, fifo, ctrl)
        s.handle = handle -- a preemptive abort() releases the child (1) AND dismisses the panel via .close
        return ""
    end

    local ok, existing = pcall(vim.fn.readfile, file)
    local lines = (ok and existing) or {}
    if #lines == 0 then
        lines = { "" }
    end

    local title = vim.fn.fnamemodify(file, ":t")
    local painted = false
    local buf
    local provider = {
        editable = true,
        cursorline = false,
        filetype = "gitcommit",
        update = function(pan)
            if not painted then
                painted = true
                buf = pan.buf
                surface.paint(pan, lines, {})
            end
        end,
        keys = function(_, pan)
            buf = pan.buf
            if session then
                session.buf = pan.buf
            end
            cursor.mark_cursor_buffer(pan.buf, "n-v-c:ver1-LvimUtilsHiddenCursor")
        end,
    }

    local handle = surface.open({
        mode = "float",
        enter = true,
        title = { icon = "\u{f044}", text = title }, --  nf-fa-edit
        size = { width = { fixed = 0.6 }, height = { auto = true, min = 8, max = 0.6 } },
        content = { blocks = { { id = "message", provider = provider } } },
        close_keys = {},
        keymaps = {
            { key = { "<C-c><C-c>", "ZZ" }, run = finish },
            { key = { "<C-c><C-k>" }, run = abort },
        },
        footer = {
            bars = {
                {
                    align = "center",
                    items = {
                        surface.button(
                            { name = "finish", key = "<C-c><C-c>", style = "action", run = finish },
                            "action"
                        ),
                        surface.button(
                            { name = "cancel", key = "<C-c><C-k>", style = "action", run = abort },
                            "action"
                        ),
                    },
                },
            },
        },
        on_close = function()
            -- A close by any other route (a stray :q) still unblocks the child — as an abort, so git never
            -- hangs on a dangling editor.
            abort()
        end,
    })

    session = { file = file, fifo = fifo, handle = handle, buf = buf or -1, done = false }
    return ""
end

-- ── run a git command through the bridge ───────────────────────────────────────

--- Run a git command under `root` with the editor env in place, so any editor it spawns opens in this
--- instance. `argv` is the git argv AFTER the executable+global prefix is prepended by the caller? No —
--- pass the full argv (executable first). `cb(res)` fires on completion (main loop).
---@param root string
---@param argv string[]         full git argv (executable first)
---@param opts? { stdin?: string, extra_env?: table<string,string> }
---@param cb? fun(res: vim.SystemCompleted)
---@return vim.SystemObj?
function M.run(root, argv, opts, cb)
    opts = opts or {}
    local env = M.env()
    if opts.extra_env then
        env = vim.tbl_extend("force", env, opts.extra_env)
    end
    return backend.system(root, argv, { stdin = opts.stdin, env = env }, cb)
end

return M
