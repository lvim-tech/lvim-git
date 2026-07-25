-- lvim-git.ui.workspace: a thin adapter over the shared `lvim-ui.workspace` tab shell.
--
-- The dedicated-tabpage host — create / find-by-marker / close+return-focus / fullscreen `slot` — used to
-- live here (and forge held a byte-for-byte COPY of it). It now lives ONCE in `lvim-ui.workspace`; this
-- module is a thin adapter that keeps lvim-git's VIEW-keyed API (enter / exit / is_open / tab_for /
-- current_view / slot / focus) so every caller (status / log / history / diffview / merge / …) is
-- unchanged, while the tab logic is shared. Each view gets its own tab, id-namespaced `lvim-git:<view>`.
--
--   * SURFACE views (status / log / history) call `enter(view)`, open their `lvim-ui` surface with
--     `slot = M.slot()` so it FILLS the tab, and `exit(view)` from the surface's close callback.
--   * REAL-WINDOW views (diffview / merge) call `enter(view)`, build their own tiled windows in the tab,
--     and `exit(view)` on close.
--
-- PUBLIC: enter / exit / is_open / tab_for / current_view / slot / focus.
--
---@module "lvim-git.ui.workspace"

local workspace = require("lvim-ui.workspace")

local M = {}

-- Every lvim-git workspace tab is id-namespaced under this prefix in the shared shell.
local PREFIX = "lvim-git:"

--- The shared-shell id for a view name.
---@param view string
---@return string
local function id(view)
    return PREFIX .. view
end

--- The tabpage hosting `view` (found by its shared marker), or nil.
---@param view string
---@return integer?
function M.tab_for(view)
    return workspace.tab_for(id(view))
end

--- The view hosted by the CURRENT tabpage (if it is an lvim-git workspace), else nil.
---@return string?
function M.current_view()
    local cur = workspace.current()
    if cur and cur:sub(1, #PREFIX) == PREFIX then
        return cur:sub(#PREFIX + 1)
    end
    return nil
end

--- Whether `view` has an open workspace tab.
---@param view string
---@return boolean
function M.is_open(view)
    return workspace.is_open(id(view))
end

--- The fullscreen fill geometry — passed as `slot` to a surface opened in `tab` layout.
---@return { width: number, height: integer }
function M.slot()
    return workspace.slot()
end

--- Focus the workspace tab for `view` (no-op when it is not open).
---@param view string
function M.focus(view)
    workspace.focus(id(view))
end

--- Enter (create-or-focus) the view's tab; the caller then builds its view inside it. Returns true when
--- an existing tab was reused (the caller should refresh, not rebuild).
---@param view string
---@return boolean existing
function M.enter(view)
    local handle = workspace.open({
        id = id(view),
        editor = { name = (view:gsub("^%l", string.upper)) }, -- tabline reads "Status" / "Diffview" / …
    })
    return handle.existing == true
end

--- Exit the view's tab: return to the origin tabpage, then close it. Idempotent + re-entry safe.
---@param view string
function M.exit(view)
    workspace.close(id(view))
end

return M
