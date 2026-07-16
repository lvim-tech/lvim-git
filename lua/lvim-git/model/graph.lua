-- lvim-git.model.graph: the commit-graph LANE ENGINE — a pure, headless-testable model that lays a
-- commit DAG (each Commit carries its `parents`) into vertical LANES and the box-drawing connector
-- glyphs a log panel renders in its left column. It is the graph that is OURS: never scraped from
-- `git log --graph` ASCII — we compute lanes from the parent pointers, colour each lane from the
-- palette (`LvimGitGraphLane1..7`), and hand the log/history panels a ready per-row glyph column.
--
-- The model is single-ROW-PER-COMMIT (so every row maps 1:1 to a selectable commit in the list): each
-- row shows the commit's node `●` in its lane, a `│` for every other lane passing through, a `╮`/`─`
-- branch-out when a merge commit opens a lane for an extra parent, and a `╯`/`╰`/`─` when child lanes
-- collapse into the commit they share as their next ancestor. Commits arrive newest-first (git log
-- order), so a merge opens lanes at the TOP and the branch point closes them further DOWN.
--
-- PUBLIC (shared core, reusable by ui/log + ui/history): compute / lane_hl / row_text.
--
---@module "lvim-git.model.graph"

local M = {}

-- ── glyphs (box-drawing; each verified single display cell) ───────────────────
local G = {
    node = "\u{25cf}", -- ● the commit node
    vert = "\u{2502}", -- │ a lane passing through
    horiz = "\u{2500}", -- ─ a horizontal connector run
    branch = "\u{256e}", -- ╮ a lane opening to the right (extra parent of a merge)
    merge_r = "\u{256f}", -- ╯ a right lane collapsing left into the node (child merge)
    merge_l = "\u{2570}", -- ╰ a left lane collapsing right into the node
    space = " ",
}

--- The palette highlight group for a lane index (cycles through the 7 LvimGitGraphLane* groups).
---@param lane integer  1-based lane/column index
---@return string
function M.lane_hl(lane)
    return "LvimGitGraphLane" .. tostring(((lane - 1) % 7) + 1)
end

---@class LvimGitGraphRow
---@field node   integer    the 1-based column the commit's node sits in
---@field width  integer    number of columns this row spans
---@field glyphs string[]   one glyph per column (left→right)
---@field hls    string[]   the highlight group per column (parallel to glyphs)

---@alias LvimGitGraphSeg [integer, integer, string]  a `{ start_byte, end_byte, hl_group }` render tuple

--- Compute the per-commit graph rows for a newest-first Commit[] list. Pure: no side effects, no git.
--- Returns an array PARALLEL to `commits` — `rows[i]` is the graph column for `commits[i]`.
---@param commits Commit[]
---@return LvimGitGraphRow[]
function M.compute(commits)
    ---@type LvimGitGraphRow[]
    local rows = {}
    -- `lanes[k]` = the commit-id lane k is currently waiting to reach (or false = an empty slot).
    ---@type (string|false)[]
    local lanes = {}

    --- The first lane index waiting for `id`, or nil.
    ---@param id string
    ---@return integer?
    local function first_target(id)
        for k, t in ipairs(lanes) do
            if t == id then
                return k
            end
        end
        return nil
    end

    --- The first empty lane slot (reused), else a new column at the end.
    ---@return integer
    local function free_slot()
        for k, t in ipairs(lanes) do
            if not t then
                return k
            end
        end
        return #lanes + 1
    end

    for _, c in ipairs(commits) do
        local id = c.id
        -- 1. place the node: the lane already waiting for this id, else a fresh lane (a branch tip).
        local node = first_target(id)
        if not node then
            node = free_slot()
            lanes[node] = id
        end
        -- 2. snapshot the incoming lanes (as they entered this row) for the pass-through verticals.
        ---@type (string|false)[]
        local incoming = {}
        for k = 1, #lanes do
            incoming[k] = lanes[k]
        end
        -- 3. other lanes ALSO waiting for this id → children collapsing into the node (merges).
        ---@type integer[]
        local merges = {}
        for k, t in ipairs(lanes) do
            if t == id and k ~= node then
                merges[#merges + 1] = k
                lanes[k] = false
            end
        end
        -- 4. reassign the node lane to the first parent; extra parents open new lanes (branch-out).
        local parents = c.parents or {}
        ---@type integer[]
        local branch = {}
        if #parents == 0 then
            lanes[node] = false -- a root commit: the lane ends here
        else
            lanes[node] = parents[1]
            for i = 2, #parents do
                local slot = free_slot()
                lanes[slot] = parents[i]
                branch[#branch + 1] = slot
            end
        end
        -- compact trailing empty slots so the width does not grow unbounded.
        while #lanes > 0 and not lanes[#lanes] do
            lanes[#lanes] = nil
        end

        -- 5. paint the row. Width spans every column touched this row (incoming, outgoing, connectors).
        local width = math.max(#incoming, #lanes, node)
        for _, m in ipairs(merges) do
            width = math.max(width, m)
        end
        for _, b in ipairs(branch) do
            width = math.max(width, b)
        end
        ---@type string[]
        local glyphs = {}
        ---@type string[]
        local hls = {}
        for k = 1, width do
            glyphs[k] = G.space
            hls[k] = M.lane_hl(k)
        end
        -- pass-through verticals: a lane that came in AND continues out, other than the node/merges.
        local is_merge = {}
        for _, m in ipairs(merges) do
            is_merge[m] = true
        end
        for k = 1, width do
            if k ~= node and not is_merge[k] then
                local through = (incoming[k] and incoming[k] ~= false) or (lanes[k] and lanes[k] ~= false)
                if through then
                    glyphs[k] = G.vert
                end
            end
        end
        -- branch-out connectors (a merge commit opening lanes for extra parents, to the right).
        for _, b in ipairs(branch) do
            if b > node then
                for k = node + 1, b - 1 do
                    if glyphs[k] == G.space then
                        glyphs[k] = G.horiz
                        hls[k] = M.lane_hl(b)
                    end
                end
                glyphs[b] = G.branch
                hls[b] = M.lane_hl(b)
            end
        end
        -- merge connectors (child lanes collapsing into the node).
        for _, m in ipairs(merges) do
            if m > node then
                for k = node + 1, m - 1 do
                    if glyphs[k] == G.space then
                        glyphs[k] = G.horiz
                        hls[k] = M.lane_hl(m)
                    end
                end
                glyphs[m] = G.merge_r
                hls[m] = M.lane_hl(m)
            elseif m < node then
                for k = m + 1, node - 1 do
                    if glyphs[k] == G.space then
                        glyphs[k] = G.horiz
                        hls[k] = M.lane_hl(m)
                    end
                end
                glyphs[m] = G.merge_l
                hls[m] = M.lane_hl(m)
            end
        end
        -- the node marker last, so it always wins its column.
        glyphs[node] = G.node
        hls[node] = M.lane_hl(node)

        rows[#rows + 1] = { node = node, width = width, glyphs = glyphs, hls = hls }
    end
    return rows
end

--- Flatten a graph row into a display string + per-column BYTE highlight ranges (box-drawing glyphs are
--- multi-byte, so the ranges are computed in bytes for `nvim_buf_set_extmark`/a panel `hls` table). Each
--- segment is a `{ start_byte, end_byte, hl_group }` tuple.
---@param row LvimGitGraphRow
---@return string text
---@return LvimGitGraphSeg[] segments
function M.row_text(row)
    local parts = {}
    ---@type LvimGitGraphSeg[]
    local segs = {}
    local byte = 0
    for k = 1, row.width do
        local g = row.glyphs[k]
        parts[#parts + 1] = g
        if g ~= " " then
            segs[#segs + 1] = { byte, byte + #g, row.hls[k] }
        end
        byte = byte + #g
    end
    return table.concat(parts), segs
end

return M
