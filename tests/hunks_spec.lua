-- The diff model behind the gutter signs, the hunk navigation and staging.
--
-- `compute` is pure (base lines in, buffer lines in, hunks out), so every case the gutter has to
-- get right can be stated exactly — including the two the code carries warnings about: an EMPTY
-- base side must read as a whole-file `add` rather than a `change` (an untracked file), and a hunk
-- whose removed side is longer than its added side is a `changedelete`, with the deleted tail
-- hanging off its LAST line, which is what the gutter draws.

local hunks = require("lvim-git.model.hunks")

---@param base string[]
---@param buf string[]
---@return table[], table<integer, string>
local function compute(base, buf)
    return hunks.compute(base, buf)
end

describe("lvim-git.model.hunks.compute")

it("sees nothing in an unchanged file", function()
    local list = compute({ "a", "b", "c" }, { "a", "b", "c" })
    eq(0, #list)
end)

it("reads added lines as an add", function()
    local list, map = compute({ "a", "c" }, { "a", "b", "c" })
    eq(1, #list)
    eq("add", list[1].type)
    eq(2, list[1].first)
    eq(2, list[1].last)
    eq("add", map[2])
    eq(nil, map[1], "an untouched line carries no sign")
end)

it("reads a whole untracked file as one add, not a change", function()
    -- The base side is empty. Fabricating a single empty base line here would pair it with the
    -- buffer's first line and report hunk 1 as a `change`.
    local list = compute({}, { "a", "b", "c" })
    eq(1, #list)
    eq("add", list[1].type)
    eq(1, list[1].first)
    eq(3, list[1].last)
    eq(0, list[1].removed)
end)

it("reads removed lines as a delete anchored on one line", function()
    local list, map = compute({ "a", "b", "c" }, { "a", "c" })
    eq(1, #list)
    eq("delete", list[1].type)
    eq(0, list[1].count, "a delete occupies no buffer lines")
    eq("delete", map[list[1].first])
end)

it("reads a deletion at the very top as a topdelete", function()
    local list = compute({ "a", "b" }, { "b" })
    eq(1, #list)
    eq("topdelete", list[1].type)
    eq(1, list[1].first, "the anchor is line 1, there being no line above it")
end)

it("reads a replacement as a change", function()
    local list, map = compute({ "a", "b", "c" }, { "a", "B", "c" })
    eq(1, #list)
    eq("change", list[1].type)
    eq("change", map[2])
end)

it("splits a small shrinking edit into a change and a delete", function()
    -- `linematch` (60 lines) pairs the lines inside a small hunk, so three lines becoming one is
    -- reported as what it really is — one line changed, two deleted — rather than one blurred
    -- hunk. Measured, because this is the diff's behaviour and not an invention of ours.
    local list = compute({ "one", "two", "three", "four", "five" }, { "one", "CHANGED", "five" })
    eq(2, #list)
    eq("delete", list[1].type)
    eq(2, list[1].removed, "the two lines that went")
    eq("change", list[2].type)
end)

it("marks the LAST line as changedelete when the hunk is too big to pair up", function()
    -- Past the linematch limit the lines are not paired, so a shrinking hunk stays ONE hunk and
    -- the deleted tail hangs off its last line — which is what the gutter draws.
    local base, buf = { "keep" }, { "keep" }
    for i = 1, 70 do
        base[#base + 1] = "old" .. i
    end
    for i = 1, 2 do
        buf[#buf + 1] = "new" .. i
    end
    local list, map = compute(base, buf)
    eq(1, #list)
    eq("changedelete", list[1].type)
    eq(70, list[1].removed)
    eq(2, list[1].added)
    eq("changedelete", map[list[1].last], "the tail hangs off the last changed line")
    eq("change", map[list[1].first], "the lines before it are an ordinary change")
end)

it("counts what each side contributed", function()
    local list = compute({ "a", "b", "c" }, { "a", "X", "Y", "c" })
    eq(2, #list, "an insert and a replacement, not one blurred hunk")
    eq("add", list[1].type)
    eq(1, list[1].added)
    eq(0, list[1].removed)
    eq("change", list[2].type)
    eq(1, list[2].added)
    eq(1, list[2].removed)
    eq(2, list[2].base_start, "where the replacement starts in the base")
end)

it("finds several hunks in one file", function()
    local list = compute({ "a", "b", "c", "d", "e" }, { "A", "b", "c", "d", "E" })
    eq(2, #list)
    eq(1, list[1].first)
    eq(5, list[2].first)
end)

describe("lvim-git.model.hunks.hunk_at")

it("finds the hunk covering a line", function()
    local list = compute({ "a", "b", "c", "d", "e" }, { "a", "X", "Y", "Z", "e" })
    eq(1, #list)
    eq("change", (hunks.hunk_at(list, 2) or {}).type)
    eq("change", (hunks.hunk_at(list, 4) or {}).type, "anywhere inside its range")
    eq(nil, hunks.hunk_at(list, 1), "a line outside every hunk")
    eq(nil, hunks.hunk_at(list, 5), "and one past its end")
end)

it("finds a delete only on its anchor line", function()
    local list = compute({ "a", "b", "c" }, { "a", "c" })
    local anchor = list[1].first
    eq("delete", (hunks.hunk_at(list, anchor) or {}).type)
    eq(nil, hunks.hunk_at(list, anchor + 1), "a delete occupies one line, not a range")
end)

describe("lvim-git.model.hunks.nav")

it("walks forward and backward between hunks", function()
    local list = compute({ "a", "b", "c", "d", "e" }, { "A", "b", "c", "d", "E" })
    eq(5, hunks.nav(list, 1, 1), "forward from the first hunk")
    eq(1, hunks.nav(list, 5, -1), "backward from the last")
end)

it("wraps at the ends", function()
    local list = compute({ "a", "b", "c", "d", "e" }, { "A", "b", "c", "d", "E" })
    eq(1, hunks.nav(list, 5, 1), "forward from the last wraps to the first")
    eq(5, hunks.nav(list, 1, -1), "backward from the first wraps to the last")
end)

it("says nothing when there are no hunks", function()
    eq(nil, hunks.nav({}, 1, 1))
end)

describe("lvim-git.model.hunks.patch")

it("writes a zero-context patch git can locate", function()
    local list = compute({ "a", "b", "c" }, { "a", "X", "c" })
    local patch = hunks.patch("file.txt", list[1])
    truthy(patch:find("diff --git a/file.txt b/file.txt", 1, true), patch)
    truthy(patch:find("@@", 1, true), "no hunk header: " .. patch)
    truthy(patch:find("\n-b", 1, true), "the removed line is missing: " .. patch)
    truthy(patch:find("\n+X", 1, true), "the added line is missing: " .. patch)
end)

it("expresses an add's start in BASE coordinates", function()
    -- git apply locates a zero-context hunk by that start; using the modified buffer's line number
    -- would misplace the change by the size of the other, unstaged hunks.
    local list = compute({ "a", "c" }, { "a", "b", "c" })
    local patch = hunks.patch("file.txt", list[1])
    truthy(patch:find("@@ -1,0 +2,1 @@", 1, true), "header should insert after base line 1: " .. patch)
end)

it("marks a missing trailing newline, which git checks byte-exactly", function()
    local list = compute({ "a", "b" }, { "a", "B" })
    local patch = hunks.patch("file.txt", list[1], { buf_noeol = true, buf_total = 2, base_total = 2 })
    truthy(patch:find("No newline at end of file", 1, true) ~= nil, "the marker is missing: " .. patch)
end)
