-- lvim-git.ui.workspace: the dedicated-TABPAGE host for the heavy views (`layout = "tab"`).
--
-- A `tab` open moves the WHOLE client (status / diffview / log / history / merge) into its OWN fullscreen
-- tabpage — never over your code — modelled on the lvim-db `:LvimDb open` workspace. This module owns ONLY
-- the tab lifecycle (create / find / close + return-focus); the view builds ITS surfaces/windows inside the
-- tab, exactly as it does in float/area/bottom. So the host generalizes the dedicated-tab pattern the
-- diffview + merge view already used inline (their own `tabnew`/`tabclose`+origin bookkeeping), removing the
-- duplication — it is a REAL tabpage/window host, never a float faking fullscreen.
--
-- The tab is marked with a tab-scoped var (`t:lvim_git_workspace = <view>`) and ALWAYS found by that marker,
-- NEVER by a stored handle — a stray `:tabclose` from elsewhere can't dangle it. Only the ORIGIN tab (where
-- focus returns on close) is remembered, in `state.workspace[view]`. The view's own module keeps the DATA
-- (fold/filter/revset/diff state), so a `close`→reopen (toggle) restores the workspace as it was left — only
-- the windows are torn down, the model persists (the lvim-db invariant).
--
-- Two seams:
--   * REAL-WINDOW views (diffview / merge) call `enter(view)` then build their own tiled windows in the tab,
--     and `exit(view)` on close.
--   * SURFACE views (status / log / history) call `enter(view)` then open their normal `lvim-ui` surface
--     with `slot = M.slot()` so the centred float FILLS the empty tab (fullscreen), and `exit(view)` from
--     the surface's close callback.
--
-- PUBLIC: enter / exit / is_open / tab_for / current_view / slot / focus.
--
---@module "lvim-git.ui.workspace"

local api = vim.api
local state = require("lvim-git.state")

local M = {}

--- The tab-scoped marker var; its value is the hosted VIEW name.
---@type string
local MARK = "lvim_git_workspace"

--- Re-entry guard for `exit` (closing the tab fires the hosted surface's close callback, which calls `exit`
--- again — the guard makes the second call a no-op instead of chasing an already-gone tab).
---@type table<string, boolean>
local exiting = {}

--- The tabpage hosting `view`, found by its marker var (never a cached handle). nil when not open.
---@param view string
---@return integer? tabpage
function M.tab_for(view)
    for _, t in ipairs(api.nvim_list_tabpages()) do
        local ok, v = pcall(api.nvim_tabpage_get_var, t, MARK)
        if ok and v == view then
            return t
        end
    end
    return nil
end

--- The view hosted by the CURRENT tabpage (if it is a workspace), else nil.
---@return string? view
function M.current_view()
    local ok, v = pcall(api.nvim_tabpage_get_var, api.nvim_get_current_tabpage(), MARK)
    return (ok and type(v) == "string") and v or nil
end

--- Whether `view` has an open workspace tab.
---@param view string
---@return boolean
function M.is_open(view)
    return M.tab_for(view) ~= nil
end

--- The per-open ANCHORED geometry override that makes a centred-float surface FILL the workspace tab
--- (near-full width/height). Passed as `opts.slot` to `lvim-ui.tabs` by the surface-based views when they
--- open in `tab` layout. (The central backdrop veil falls over the empty tab background — harmless, as
--- there is no code behind it in a dedicated tab.)
---@return { width: number, height: number }
function M.slot()
    -- Fill the tab's editor area EXACTLY (an absolute row count, not a screen fraction). A `0.96 × lines`
    -- fraction overshot by a row on a user running `cmdheight > 0`: the surface float ran one row past the
    -- global statusline, so its footer bar landed on / behind the statusline and the blank "air" row above the
    -- footer became the visible bottom (the "extra row"). The available content rows are `lines` minus the
    -- tabline (1) + statusline (1) + the `cmdheight` command-line rows. The surface centres it (its
    -- `math.max(1, …)` keeps the tabline row free), so the panel now spans tabline→statusline with no gap.
    local avail = vim.o.lines - vim.o.cmdheight - 2
    return { width = 1.0, height = math.max(10, avail) }
end

--- Focus the workspace tab for `view` (no-op when it is not open).
---@param view string
function M.focus(view)
    local t = M.tab_for(view)
    if t and api.nvim_tabpage_is_valid(t) then
        api.nvim_set_current_tabpage(t)
    end
end

--- Enter the workspace tab for `view`: switch to the existing one, or create a fresh dedicated tabpage,
--- mark it, park a scratch buffer in its window and remember the origin tab. The caller then builds its
--- view (real windows, or a surface float with `M.slot()`) in the now-current tab.
---@param view string
---@return boolean existing  true when an existing workspace tab was reused (the caller should refresh, not rebuild)
function M.enter(view)
    local existing = M.tab_for(view)
    if existing and api.nvim_tabpage_is_valid(existing) then
        api.nvim_set_current_tabpage(existing)
        return true
    end
    state.workspace[view] = { origin_tab = api.nvim_get_current_tabpage() }
    vim.cmd("tabnew")
    local tab = api.nvim_get_current_tabpage()
    api.nvim_tabpage_set_var(tab, MARK, view)
    -- A throwaway scratch buffer as the tab's background (so it is not the `[No Name]` a real-window view
    -- would otherwise leave, and so a fill-slot surface float has a clean, code-free backdrop).
    local buf = api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].swapfile = false
    -- Name the backdrop so the tabline reads e.g. "Status" / "Diffview" instead of "[No Name]" for this tab.
    pcall(api.nvim_buf_set_name, buf, (view:gsub("^%l", string.upper)))
    local win = api.nvim_get_current_win()
    pcall(api.nvim_win_set_buf, win, buf)
    -- Strip the window CHROME on the backdrop: the fill-slot surface float covers ~96% of it, but its thin
    -- margin would otherwise leak the scratch buffer's line number ("1" top-left), its `~` end-of-buffer
    -- tildes, and the sign/fold columns. A clean, code-free backdrop shows nothing in that margin.
    for opt, val in pairs({
        number = false,
        relativenumber = false,
        signcolumn = "no",
        foldcolumn = "0",
        statuscolumn = "",
        colorcolumn = "",
        cursorline = false,
        list = false,
        winfixbuf = true,
    }) do
        pcall(function()
            vim.wo[win][opt] = val
        end)
    end
    pcall(function()
        vim.wo[win].fillchars = "eob: "
    end)
    return false
end

--- Exit the workspace tab for `view`: return to the origin tabpage, then close the workspace tab. Found by
--- its marker, so it is robust to a stray `:tabclose`. Idempotent + re-entry safe (the hosted surface's
--- close callback re-enters this).
---@param view string
function M.exit(view)
    if exiting[view] then
        return
    end
    exiting[view] = true
    local t = M.tab_for(view)
    local origin = (state.workspace[view] or {}).origin_tab
    if t and api.nvim_tabpage_is_valid(t) then
        -- Leave the tab BEFORE closing it so focus lands where the user came from (not nvim's default
        -- neighbour) when the workspace tab is the current one.
        if api.nvim_get_current_tabpage() == t and origin and api.nvim_tabpage_is_valid(origin) then
            pcall(api.nvim_set_current_tabpage, origin)
        end
        pcall(function()
            vim.cmd(api.nvim_tabpage_get_number(t) .. "tabclose")
        end)
    end
    if origin and api.nvim_tabpage_is_valid(origin) and api.nvim_get_current_tabpage() ~= origin then
        pcall(api.nvim_set_current_tabpage, origin)
    end
    state.workspace[view] = nil
    exiting[view] = nil
end

return M
