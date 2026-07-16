-- lvim-git.model.hunks: the ONE hunk engine — `vim.diff` line math shared by the gutter signs, the
-- hunk-preview float, and the stage/reset/discard patch construction.
--
-- `compute(base, buf)` diffs the base blob (git: the index or HEAD; jj: the parent change `@-`) against
-- the live buffer lines IN-PROCESS (histogram + linematch), never shelling out per keystroke, and
-- returns both the Hunk[] list and a per-LINE type map. The map is what paints the signs AND what the
-- Public API `line_hunk`/`line_hl` read — O(1), in memory, safe from a statuscolumn expression.
--
-- `patch(path, hunk, …)` builds the minimal unified diff a hunk stages as (`git apply --cached
-- --unidiff-zero -`); `invert = true` reverses it (unstage / discard). No context lines (unidiff-zero),
-- so a single hunk applies in isolation regardless of the rest of the file.
--
---@module "lvim-git.model.hunks"

local M = {}

---@alias LvimGitHunkType "add"|"change"|"delete"|"topdelete"|"changedelete"

---@class Hunk
---@field type   LvimGitHunkType
---@field first  integer   first BUFFER line of the hunk (1-based; the sign anchor for delete/topdelete)
---@field last   integer   last BUFFER line of the hunk (== first for a pure deletion)
---@field count  integer   number of buffer lines the hunk spans (0 for a pure deletion)
---@field added  integer   lines added
---@field removed integer  lines removed
---@field base_start integer  first BASE line (removed side)
---@field base_count integer  base lines count (removed side)
---@field base_lines string[] the base (removed) line texts
---@field buf_lines  string[] the buffer (added) line texts

--- Classify a raw `vim.diff` index tuple into a Hunk (line texts sliced from base/buf).
---@param sa integer  start_a (1-based; base side)
---@param ca integer  count_a
---@param sb integer  start_b (1-based; buffer side)
---@param cb integer  count_b
---@param base string[]
---@param buf string[]
---@return Hunk
local function classify(sa, ca, sb, cb, base, buf)
    local base_lines = {}
    for i = sa, sa + ca - 1 do
        base_lines[#base_lines + 1] = base[i] or ""
    end
    local buf_lines = {}
    for i = sb, sb + cb - 1 do
        buf_lines[#buf_lines + 1] = buf[i] or ""
    end
    ---@type LvimGitHunkType
    local kind
    local first, last, count
    if ca == 0 then
        kind = "add"
        first, count = sb, cb
        last = sb + cb - 1
    elseif cb == 0 then
        if sb == 0 then
            kind = "topdelete"
            first, last, count = 1, 1, 0
        else
            kind = "delete"
            first, last, count = sb, sb, 0
        end
    else
        kind = ca > cb and "changedelete" or "change"
        first, count = sb, cb
        last = sb + cb - 1
    end
    return {
        type = kind,
        first = first,
        last = last,
        count = count,
        added = cb,
        removed = ca,
        base_start = sa,
        base_count = ca,
        base_lines = base_lines,
        buf_lines = buf_lines,
    }
end

--- Diff the base blob against the buffer lines. Returns the Hunk[] and the per-line type map
--- (`map[lnum] = LvimGitHunkType`). For a change hunk whose removed side is LONGER than the added
--- side, the LAST changed buffer line is marked `changedelete` (the deleted tail hangs off it), matching
--- the gutter convention.
---@param base string[]  the base blob lines
---@param buf string[]   the live buffer lines
---@return Hunk[] hunks, table<integer, LvimGitHunkType> map
function M.compute(base, buf)
    local a = table.concat(base, "\n")
    local b = table.concat(buf, "\n")
    -- `vim.diff` needs trailing newlines so the last line participates.
    local raw = vim.diff(a .. "\n", b .. "\n", {
        result_type = "indices",
        algorithm = "histogram",
        linematch = 60,
    })
    ---@cast raw integer[][]
    ---@type Hunk[]
    local hunks = {}
    ---@type table<integer, LvimGitHunkType>
    local map = {}
    for _, r in ipairs(raw or {}) do
        local h = classify(r[1], r[2], r[3], r[4], base, buf)
        hunks[#hunks + 1] = h
        if h.type == "add" or h.type == "change" then
            for l = h.first, h.last do
                map[l] = h.type
            end
        elseif h.type == "changedelete" then
            for l = h.first, h.last - 1 do
                map[l] = "change"
            end
            map[h.last] = "changedelete"
        else -- delete / topdelete: a single anchor line
            map[h.first] = h.type
        end
    end
    return hunks, map
end

--- The hunk covering a buffer line (for a preview / nav), or nil.
---@param hunks Hunk[]
---@param lnum integer
---@return Hunk?
function M.hunk_at(hunks, lnum)
    for _, h in ipairs(hunks) do
        -- delete/topdelete occupy their single anchor line; others their [first,last] range.
        if h.count == 0 then
            if lnum == h.first then
                return h
            end
        elseif lnum >= h.first and lnum <= h.last then
            return h
        end
    end
    return nil
end

--- The next / previous hunk's anchor line from `lnum` (wraps). `dir` = 1 forward, -1 backward.
---@param hunks Hunk[]
---@param lnum integer
---@param dir integer
---@return integer?  the target line, or nil when there are no hunks
function M.nav(hunks, lnum, dir)
    if #hunks == 0 then
        return nil
    end
    local anchors = {}
    for _, h in ipairs(hunks) do
        anchors[#anchors + 1] = h.first
    end
    table.sort(anchors)
    if dir > 0 then
        for _, a in ipairs(anchors) do
            if a > lnum then
                return a
            end
        end
        return anchors[1] -- wrap
    else
        for i = #anchors, 1, -1 do
            if anchors[i] < lnum then
                return anchors[i]
            end
        end
        return anchors[#anchors] -- wrap
    end
end

--- Build the minimal unified-diff patch that a single hunk stages as (base → buffer). No context
--- (`--unidiff-zero`), so it applies in isolation. The ADDED-side start is expressed in BASE
--- coordinates (this hunk applied ALONE against the index) — NOT the fully-modified buffer's line
--- number — because git apply locates a zero-context hunk by that start: an `add` inserts AFTER
--- `base_start` (so `+base_start+1`), a `change` replaces AT `base_start`, a `delete` collapses to
--- `base_start-1`. Getting this wrong misplaces the change by the count of the OTHER (unstaged) hunks.
---
--- To UNSTAGE or DISCARD, callers apply THIS SAME forward patch with git's `-R` (reverse) flag —
--- `apply --cached -R` (index) / `apply -R` (worktree) — rather than a hand-inverted header, so git
--- itself does the reversal and re-locates the hunk.
---@param path string   repo-relative path
---@param hunk Hunk
---@return string patch  a complete `diff --git` patch (single hunk, base → buffer)
function M.patch(path, hunk)
    local new_start
    if hunk.removed == 0 then
        new_start = hunk.base_start + 1 -- add: inserted after the base_start line
    elseif hunk.added == 0 then
        new_start = hunk.base_start - 1 -- delete: collapses onto the preceding line (0 at top of file)
    else
        new_start = hunk.base_start -- change: replaced in place
    end
    local out = {
        ("diff --git a/%s b/%s"):format(path, path),
        "--- a/" .. path,
        "+++ b/" .. path,
        ("@@ -%d,%d +%d,%d @@"):format(hunk.base_start, hunk.base_count, new_start, hunk.added),
    }
    for _, l in ipairs(hunk.base_lines) do
        out[#out + 1] = "-" .. l
    end
    for _, l in ipairs(hunk.buf_lines) do
        out[#out + 1] = "+" .. l
    end
    return table.concat(out, "\n") .. "\n"
end

return M
