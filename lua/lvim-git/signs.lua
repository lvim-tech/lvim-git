-- lvim-git.signs: the gutter-signs component — a complete, STANDALONE "gitsigns" install on its own
-- (attach with no status client, no other component loaded).
--
-- It diffs the base blob (git: the index or HEAD per `signs.base`; jj: the parent change `@-`) against
-- the live buffer IN-PROCESS via the shared hunk engine (`model.hunks`), places `signcolumn` extmarks
-- in the `lvim-git` namespace, and keeps a per-line hunk-type map IN MEMORY. That map is BOTH what
-- paints the signs AND what the Public API `line_hunk`/`line_hl` serve — O(1), render-safe, never a
-- git call on the render path (git runs async on events only). Recompute is debounced on buffer edits;
-- the base blob is refreshed on `User LvimGitRepoChanged` (any repo mutation).
--
-- PUBLIC (stability contract): attach / detach / is_attached / line_hunk / line_hl / line_sign / hl /
-- hunks / buf_status / hunk_at / nav (+ the stage/reset/unstage/preview hunk ops). Events:
-- `LvimGitAttach` `{buf,root,vcs}`, `LvimGitDetach` `{buf}`, `LvimGitBufChanged` `{buf,status}`.
-- Buffer vars: `b:lvim_git_status` `{added,changed,removed}`, `b:lvim_git_head`, `b:lvim_git_branch`,
-- `b:lvim_git_root`.
--
---@module "lvim-git.signs"

local uv = vim.uv or vim.loop
local config = require("lvim-git.config")
local state = require("lvim-git.state")
local backend = require("lvim-git.backend")
local hunks = require("lvim-git.model.hunks")
local highlights = require("lvim-git.highlights")

local M = {}

---@type integer  the extmark namespace for gutter signs
local NS = vim.api.nvim_create_namespace("lvim-git.signs")

---@type integer?  the autocmd group id (set on setup)
local augroup

--- Sign glyph + highlight groups per hunk type. `nr` is the line-number highlight; `sign_hl` the
--- gutter-glyph highlight. Untracked is a per-buffer variant (not a `line_hunk` type).
---@type table<string, { icon_key: string, sign: string, nr: string }>
local TYPE_INFO = {
    add = { icon_key = "add", sign = "LvimGitSignAdd", nr = "LvimGitSignAddNr" },
    change = { icon_key = "change", sign = "LvimGitSignChange", nr = "LvimGitSignChangeNr" },
    delete = { icon_key = "delete", sign = "LvimGitSignDelete", nr = "LvimGitSignDeleteNr" },
    topdelete = { icon_key = "top_delete", sign = "LvimGitSignTopDelete", nr = "LvimGitSignTopDeleteNr" },
    changedelete = { icon_key = "change_delete", sign = "LvimGitSignChangeDelete", nr = "LvimGitSignChangeDeleteNr" },
    untracked = { icon_key = "untracked", sign = "LvimGitSignUntracked", nr = "LvimGitSignUntrackedNr" },
}

-- ── helpers ──────────────────────────────────────────────────────────────────

--- The repo-relative path of a buffer (or nil if it has no on-disk file / isn't under `root`).
---@param buf integer
---@param root string
---@return string?
local function rel_path(buf, root)
    local name = vim.api.nvim_buf_get_name(buf)
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

--- True when a buffer is an ordinary, on-disk, modifiable file buffer (signs make sense there).
---@param buf integer
---@return boolean
local function is_file_buffer(buf)
    if not vim.api.nvim_buf_is_valid(buf) then
        return false
    end
    if vim.bo[buf].buftype ~= "" then
        return false
    end
    local name = vim.api.nvim_buf_get_name(buf)
    return name ~= "" and not name:match("^%w+://")
end

--- Aggregate the hunks into the `{ added, changed, removed }` counts a statusline consumes.
---@param hs Hunk[]
---@param untracked boolean
---@param line_count integer
---@return { added: integer, changed: integer, removed: integer }
local function counts(hs, untracked, line_count)
    if untracked then
        return { added = line_count, changed = 0, removed = 0 }
    end
    local added, changed, removed = 0, 0, 0
    for _, h in ipairs(hs) do
        if h.type == "add" then
            added = added + h.added
        elseif h.type == "change" then
            changed = changed + h.added
        elseif h.type == "changedelete" then
            changed = changed + h.added
            removed = removed + math.max(0, h.removed - h.added)
        else -- delete / topdelete
            removed = removed + h.removed
        end
    end
    return { added = added, changed = changed, removed = removed }
end

-- ── rendering ──────────────────────────────────────────────────────────────

--- Place the gutter extmarks for a buffer from its computed line map.
---@param buf integer
local function render(buf)
    local rec = state.buffers[buf]
    if not rec then
        return
    end
    vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
    if config.signs.gutter == false then
        return -- data-only: `rec.map` is already set by the caller, so `line_hl`/`line_hunk` still work
    end
    local icons = config.signs.icons
    local n = vim.api.nvim_buf_line_count(buf)
    for lnum, ty in pairs(rec.map) do
        if lnum >= 1 and lnum <= n then
            local info = rec.untracked and TYPE_INFO.untracked or TYPE_INFO[ty]
            if info then
                pcall(vim.api.nvim_buf_set_extmark, buf, NS, lnum - 1, 0, {
                    sign_text = icons[info.icon_key],
                    sign_hl_group = info.sign,
                    number_hl_group = info.nr,
                    priority = 10,
                })
            end
        end
    end
end

--- Recompute a buffer's hunks from its cached base and current lines (NO git call), re-render, refresh
--- the buffer vars, and fire `LvimGitBufChanged`. Safe to call from a debounced timer.
---@param buf integer
local function recompute(buf)
    local rec = state.buffers[buf]
    if not rec or not vim.api.nvim_buf_is_valid(buf) then
        return
    end
    local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local hs, map = hunks.compute(rec.base_lines, buf_lines)
    rec.hunks = hs
    rec.map = map
    rec.status = counts(hs, rec.untracked, #buf_lines)
    render(buf)
    vim.b[buf].lvim_git_status = rec.status
    vim.api.nvim_exec_autocmds("User", { pattern = "LvimGitBufChanged", data = { buf = buf, status = rec.status } })
end

--- Fetch (or refresh) the base blob for a buffer asynchronously, then recompute. Untracked / not-yet-
--- tracked files fall back to an EMPTY base (the whole file reads as added/untracked).
---@param buf integer
local function refresh_base(buf)
    local rec = state.buffers[buf]
    if not rec then
        return
    end
    backend.hunks_base({ root_or_buf = buf, path = rec.path, base = config.signs.base }, function(lines, base_id)
        if not state.buffers[buf] then
            return
        end
        if lines then
            rec.base_lines = lines
            rec.base_id = base_id
            rec.untracked = false
        else
            -- Not in the index/HEAD → treat as untracked: whole file is "added".
            rec.base_lines = {}
            rec.untracked = true
        end
        recompute(buf)
    end)
end

-- ── attach / detach ──────────────────────────────────────────────────────────

--- Attach gutter signs to a buffer: detect its repo, seed the buffer vars, fetch the base blob and
--- render. No-op when signs are disabled, the buffer is not a file buffer, or it is not in a repo.
---@param buf? integer
function M.attach(buf)
    buf = buf or vim.api.nvim_get_current_buf()
    if not config.signs.enabled or state.buffers[buf] or not is_file_buffer(buf) then
        return
    end
    local root, vcs = backend.detect(buf)
    if not root or not vcs then
        return
    end
    local path = rel_path(buf, root)
    if not path then
        return
    end
    ---@type table
    state.buffers[buf] = {
        root = root,
        vcs = vcs,
        path = path,
        base_lines = {},
        hunks = {},
        map = {},
        status = { added = 0, changed = 0, removed = 0 },
        untracked = false,
    }
    vim.b[buf].lvim_git_root = root
    vim.b[buf].lvim_git_head = backend.head(buf)
    vim.b[buf].lvim_git_branch = backend.branch(buf)
    vim.b[buf].lvim_git_status = state.buffers[buf].status
    -- Refresh the header cache (head/branch) so the vars are populated, then the base + hunks.
    backend.refresh(buf, function()
        if state.buffers[buf] then
            vim.b[buf].lvim_git_head = backend.head(buf)
            vim.b[buf].lvim_git_branch = backend.branch(buf)
        end
    end)
    refresh_base(buf)
    vim.api.nvim_exec_autocmds("User", { pattern = "LvimGitAttach", data = { buf = buf, root = root, vcs = vcs } })
end

--- Detach signs from a buffer: clear extmarks, drop the record + vars, fire `LvimGitDetach`.
---@param buf? integer
function M.detach(buf)
    buf = buf or vim.api.nvim_get_current_buf()
    local rec = state.buffers[buf]
    if not rec then
        return
    end
    if rec.timer then
        pcall(function()
            rec.timer:stop()
            rec.timer:close()
        end)
    end
    if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
        pcall(function()
            vim.b[buf].lvim_git_status = nil
        end)
    end
    state.buffers[buf] = nil
    vim.api.nvim_exec_autocmds("User", { pattern = "LvimGitDetach", data = { buf = buf } })
end

--- True when signs are attached to a buffer.
---@param buf? integer
---@return boolean
function M.is_attached(buf)
    return state.buffers[buf or vim.api.nvim_get_current_buf()] ~= nil
end

--- Debounced recompute (buffer edits): coalesce rapid TextChanged into one in-process diff.
---@param buf integer
local function schedule_recompute(buf)
    local rec = state.buffers[buf]
    if not rec then
        return
    end
    if not rec.timer then
        rec.timer = uv.new_timer()
    end
    rec.timer:stop()
    rec.timer:start(config.signs.debounce or 150, 0, function()
        vim.schedule(function()
            recompute(buf)
        end)
    end)
end

-- ── public reads (render-safe, O(1), in memory) ──────────────────────────────

--- The hunk TYPE for a buffer line (or nil). O(1), in-memory — safe from a statuscolumn expression.
---@param buf integer
---@param lnum integer
---@return LvimGitHunkType?
function M.line_hunk(buf, lnum)
    local rec = state.buffers[buf]
    return rec and rec.map[lnum] or nil
end

--- The auto-defined HL group name for a buffer line's hunk (or nil). For an untracked buffer every
--- changed line resolves to the Untracked group. Render a custom glyph in this group for free color.
---@param buf integer
---@param lnum integer
---@return string?
function M.line_hl(buf, lnum)
    local rec = state.buffers[buf]
    if not rec then
        return nil
    end
    local ty = rec.map[lnum]
    if not ty then
        return nil
    end
    local info = rec.untracked and TYPE_INFO.untracked or TYPE_INFO[ty]
    return info and info.sign or nil
end

--- The ready-made glyph + highlight for a buffer line (nil when the line has no hunk).
---@param buf integer
---@param lnum integer
---@return { type: string, text: string, hl: string, numhl: string }?
function M.line_sign(buf, lnum)
    local rec = state.buffers[buf]
    if not rec then
        return nil
    end
    local ty = rec.map[lnum]
    if not ty then
        return nil
    end
    local info = rec.untracked and TYPE_INFO.untracked or TYPE_INFO[ty]
    if not info then
        return nil
    end
    return { type = ty, text = config.signs.icons[info.icon_key], hl = info.sign, numhl = info.nr }
end

--- The buffer's Hunk[] (render-safe cached).
---@param buf integer
---@return Hunk[]
function M.hunks(buf)
    local rec = state.buffers[buf]
    return rec and rec.hunks or {}
end

--- The buffer's `{ added, changed, removed }` counts (the `b:lvim_git_status` source; render-safe).
---@param buf integer
---@return { added: integer, changed: integer, removed: integer }?
function M.buf_status(buf)
    local rec = state.buffers[buf]
    return rec and rec.status or nil
end

--- The whole hunk covering a buffer line (for a preview), or nil.
---@param buf integer
---@param lnum integer
---@return Hunk?
function M.hunk_at(buf, lnum)
    local rec = state.buffers[buf]
    return rec and hunks.hunk_at(rec.hunks, lnum) or nil
end

--- The next/prev hunk anchor line from a line (wraps). `dir` = 1 forward, -1 backward.
---@param buf integer
---@param lnum integer
---@param dir integer
---@return integer?
function M.nav(buf, lnum, dir)
    local rec = state.buffers[buf]
    return rec and hunks.nav(rec.hunks, lnum, dir) or nil
end

--- The Public group-name registry mapping each hunk type → its `{ sign, nr }` groups.
---@type table<string, { sign: string, nr: string }>
M.hl = highlights.sign_groups

-- ── hunk operations (stage / unstage / reset / preview) ──────────────────────

--- Move the cursor to the next/prev hunk (the `]h`/`[h` maps use this).
---@param dir integer  1 forward, -1 backward
function M.goto_hunk(dir)
    local buf = vim.api.nvim_get_current_buf()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local target = M.nav(buf, lnum, dir)
    if target then
        vim.api.nvim_win_set_cursor(0, { math.min(target, vim.api.nvim_buf_line_count(buf)), 0 })
    end
end

--- Apply a single-hunk patch to the index (`stage`) or reverse it out of the index (`unstage`).
---@param buf integer
---@param hunk Hunk
---@param unstage boolean
local function apply_index(buf, hunk, unstage)
    local rec = state.buffers[buf]
    if not rec then
        return
    end
    local patch = hunks.patch(rec.path, hunk)
    local argv = { config.git.cmd, "apply", "--cached", "--unidiff-zero" }
    if unstage then
        argv[#argv + 1] = "-R"
    end
    argv[#argv + 1] = "-"
    backend.system(rec.root, argv, { stdin = patch }, function(res)
        if res.code ~= 0 then
            vim.notify(
                "lvim-git: " .. (unstage and "unstage" or "stage") .. " failed: " .. (res.stderr or ""),
                vim.log.levels.ERROR
            )
            return
        end
        -- The index moved → refresh the base (and every panel) via the repo-changed event.
        vim.api.nvim_exec_autocmds("User", {
            pattern = "LvimGitRepoChanged",
            data = { root = rec.root, vcs = rec.vcs, reason = unstage and "unstage" or "stage" },
        })
        refresh_base(buf)
    end)
end

--- Stage the hunk under the cursor.
function M.stage_hunk()
    local buf = vim.api.nvim_get_current_buf()
    local h = M.hunk_at(buf, vim.api.nvim_win_get_cursor(0)[1])
    if h then
        apply_index(buf, h, false)
    end
end

--- Unstage the hunk under the cursor (reverse it out of the index).
function M.unstage_hunk()
    local buf = vim.api.nvim_get_current_buf()
    local h = M.hunk_at(buf, vim.api.nvim_win_get_cursor(0)[1])
    if h then
        apply_index(buf, h, true)
    end
end

--- Reset (discard) the hunk under the cursor — restore the base content for that region IN THE BUFFER
--- (in memory; the user saves as usual). Add → drop the added lines; delete → re-insert the removed
--- lines; change → replace with the base lines.
function M.reset_hunk()
    local buf = vim.api.nvim_get_current_buf()
    local h = M.hunk_at(buf, vim.api.nvim_win_get_cursor(0)[1])
    if not h then
        return
    end
    if h.type == "add" then
        vim.api.nvim_buf_set_lines(buf, h.first - 1, h.last, false, {})
    elseif h.type == "delete" then
        vim.api.nvim_buf_set_lines(buf, h.first, h.first, false, h.base_lines)
    elseif h.type == "topdelete" then
        vim.api.nvim_buf_set_lines(buf, 0, 0, false, h.base_lines)
    else -- change / changedelete
        vim.api.nvim_buf_set_lines(buf, h.first - 1, h.last, false, h.base_lines)
    end
    schedule_recompute(buf)
end

--- Preview the hunk under the cursor in a small cursor-anchored, read-only lvim-ui window with a
--- stage/reset/unstage/close action footer (the ONE cursor-anchored popup lvim-git needs).
function M.preview_hunk()
    local buf = vim.api.nvim_get_current_buf()
    local h = M.hunk_at(buf, vim.api.nvim_win_get_cursor(0)[1])
    if not h then
        return
    end
    local lines, hls = {}, {}
    for _, l in ipairs(h.base_lines) do
        lines[#lines + 1] = "-" .. l
        hls[#hls + 1] = { line = #lines - 1, col_start = 0, col_end = -1, group = "LvimGitDiffDelete" }
    end
    for _, l in ipairs(h.buf_lines) do
        lines[#lines + 1] = "+" .. l
        hls[#hls + 1] = { line = #lines - 1, col_start = 0, col_end = -1, group = "LvimGitDiffAdd" }
    end
    if #lines == 0 then
        lines = { "(no diff)" }
    end
    require("lvim-ui").info(lines, {
        position = "cursor",
        hide_cursor = true,
        highlights = hls,
        title = { icon = "", text = "Hunk" },
        -- M.info appends its own `q close`; these are the extra action buttons.
        footer_items = {
            {
                key = "s",
                name = "stage",
                run = function(st)
                    st.close()
                    M.stage_hunk()
                end,
            },
            {
                key = "r",
                name = "reset",
                run = function(st)
                    st.close()
                    M.reset_hunk()
                end,
            },
            {
                key = "u",
                name = "unstage",
                run = function(st)
                    st.close()
                    M.unstage_hunk()
                end,
            },
        },
    })
end

--- Toggle the whole signs component on/off (`:LvimGit toggle_signs`).
function M.toggle()
    config.signs.enabled = not config.signs.enabled
    if config.signs.enabled then
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
            M.attach(b)
        end
    else
        for b in
            pairs(vim.tbl_map(function(_)
                return true
            end, state.buffers))
        do
            M.detach(b)
        end
    end
end

-- ── setup: autocmds + keymaps + <Plug> maps ─────────────────────────────────

--- Wire the signs component: auto-attach file buffers, debounce recompute on edits, refresh the base
--- on repo mutations, and install the hunk-nav keymaps + `<Plug>` maps. Idempotent.
function M.setup()
    if augroup then
        return
    end
    augroup = vim.api.nvim_create_augroup("lvim-git.signs", { clear = true })

    vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile", "BufWinEnter" }, {
        group = augroup,
        callback = function(a)
            M.attach(a.buf)
        end,
    })
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "InsertLeave" }, {
        group = augroup,
        callback = function(a)
            if state.buffers[a.buf] then
                schedule_recompute(a.buf)
            end
        end,
    })
    vim.api.nvim_create_autocmd("BufWritePost", {
        group = augroup,
        callback = function(a)
            if state.buffers[a.buf] then
                schedule_recompute(a.buf)
            end
        end,
    })
    vim.api.nvim_create_autocmd("BufDelete", {
        group = augroup,
        callback = function(a)
            M.detach(a.buf)
        end,
    })
    -- Any repo mutation (from our ops or an external change) → refresh every attached buffer's base.
    vim.api.nvim_create_autocmd("User", {
        group = augroup,
        pattern = "LvimGitRepoChanged",
        callback = function()
            for b in pairs(state.buffers) do
                refresh_base(b)
            end
        end,
    })

    -- <Plug> maps (the user binds these; documented in the README).
    local plug = {
        ["<Plug>(LvimGitHunkStage)"] = M.stage_hunk,
        ["<Plug>(LvimGitHunkReset)"] = M.reset_hunk,
        ["<Plug>(LvimGitHunkUnstage)"] = M.unstage_hunk,
        ["<Plug>(LvimGitHunkPreview)"] = M.preview_hunk,
        ["<Plug>(LvimGitHunkNext)"] = function()
            M.goto_hunk(1)
        end,
        ["<Plug>(LvimGitHunkPrev)"] = function()
            M.goto_hunk(-1)
        end,
    }
    for lhs, fn in pairs(plug) do
        vim.keymap.set("n", lhs, fn, { desc = lhs:match("%((.-)%)") })
    end

    -- Hunk-nav keymaps (config-owned; skip when set to false/empty).
    local km = config.keymaps or {}
    if km.hunk_next and km.hunk_next ~= "" then
        vim.keymap.set("n", km.hunk_next, function()
            M.goto_hunk(1)
        end, { desc = "lvim-git: next hunk" })
    end
    if km.hunk_prev and km.hunk_prev ~= "" then
        vim.keymap.set("n", km.hunk_prev, function()
            M.goto_hunk(-1)
        end, { desc = "lvim-git: prev hunk" })
    end

    -- Attach any already-open file buffers (setup after buffers exist).
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(b) then
            M.attach(b)
        end
    end
end

return M
