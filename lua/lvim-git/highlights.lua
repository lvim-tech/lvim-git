-- lvim-git.highlights: the self-theming highlight factory.
-- Every group lvim-git paints is DERIVED from the live lvim-utils palette here and registered through
-- `lvim-utils.highlight.bind`, so it re-applies on ColorScheme / palette sync and stays overridable
-- off-lvim. UI code never inlines a colour — it references one of these NAMED groups. Two-tier tints
-- follow the canon: `mtint(accent, t)` = blend the accent toward the popup bg (higher t = more accent).
--
-- The six sign groups (+ their …Nr line-number variants) are the Public-API-visible, auto-defined,
-- palette-driven colours a consumer gets for FREE (read the name via signs.line_hl / signs.hl).
--
---@module "lvim-git.highlights"

local hl = require("lvim-utils.highlight")

local M = {}

--- Build every LvimGit* group from the live palette. Passed to `hl.bind`, so it re-runs on every
--- palette change; read the palette INSIDE the factory so the groups track the theme.
---@param c table  the live lvim-utils palette
---@return table<string, table>
function M.build(c)
    local bg = c.bg_dark
    local mtint = function(accent, t)
        return hl.blend(accent, bg, t)
    end
    -- ALL git/sign colours are READ from the palette's differentiated git set (`c.git.*`), never a
    -- hardcoded base hue — so a theme fully controls the git look. The `*_nr` line-number variants are
    -- their OWN, slightly-darker palette colours (the gutter number reads a touch darker than the glyph).
    -- Fallbacks keep it nil-safe on a palette that predates a key (the current palette provides them all).
    local git = c.git or {}
    local add = git.add or c.green
    local change = git.change or c.yellow
    local delete = git.delete or c.red
    local change_delete = git.change_delete or c.orange
    local untracked = git.untracked or c.blue
    local add_nr = git.add_nr or hl.darken(add, 0.28)
    local change_nr = git.change_nr or hl.darken(change, 0.28)
    local delete_nr = git.delete_nr or hl.darken(delete, 0.28)
    local change_delete_nr = git.change_delete_nr or hl.darken(change_delete, 0.28)
    local untracked_nr = git.untracked_nr or hl.darken(untracked, 0.28)
    local groups = {
        -- ── gutter signs (auto-defined, palette-driven; the Public-API "colours for free") ──
        LvimGitSignAdd = { fg = add },
        LvimGitSignChange = { fg = change },
        LvimGitSignDelete = { fg = delete },
        LvimGitSignTopDelete = { fg = delete }, -- topdelete shares the delete hue
        LvimGitSignChangeDelete = { fg = change_delete },
        LvimGitSignUntracked = { fg = untracked },
        LvimGitSignAddNr = { fg = add_nr },
        LvimGitSignChangeNr = { fg = change_nr },
        LvimGitSignDeleteNr = { fg = delete_nr },
        LvimGitSignTopDeleteNr = { fg = delete_nr },
        LvimGitSignChangeDeleteNr = { fg = change_delete_nr },
        LvimGitSignUntrackedNr = { fg = untracked_nr },

        -- ── diff washes (two-tier: line wash 0.15 + char-level deep tint 0.4), all from c.git.* ──
        LvimGitDiffAdd = { bg = mtint(add, 0.15) },
        LvimGitDiffDelete = { bg = mtint(delete, 0.15) },
        LvimGitDiffChange = { bg = mtint(change, 0.15) },
        LvimGitDiffAddText = { bg = mtint(add, 0.4), bold = true },
        LvimGitDiffDeleteText = { bg = mtint(delete, 0.4), bold = true },
        LvimGitDiffFill = { fg = c.fg_dark, bg = mtint(c.blue, 0.05) },

        -- ── blame ──
        -- Inline virtual text (dim italic); the commit under triage in the split (accent).
        LvimGitBlame = { fg = c.fg_dark, italic = true },
        LvimGitBlameHead = { fg = c.blue, bold = true },
        -- Native blame split columns.
        LvimGitBlameSha = { fg = c.yellow },
        LvimGitBlameAuthor = { fg = c.green },
        LvimGitBlameDate = { fg = c.fg_dark, italic = true },
        LvimGitBlameSummary = { fg = c.fg },
        LvimGitBlameNotCommitted = { fg = c.orange, italic = true }, -- the zero-sha "Not Committed Yet" lines
        -- Recency HEAT buckets for the sha column (newest → oldest), warm → cool, palette-driven. The
        -- split assigns a bucket per line by author-time when `blame.recency` is on.
        LvimGitBlameAge1 = { fg = c.red }, -- newest
        LvimGitBlameAge2 = { fg = c.orange },
        LvimGitBlameAge3 = { fg = c.yellow },
        LvimGitBlameAge4 = { fg = c.green },
        LvimGitBlameAge5 = { fg = c.blue }, -- oldest

        -- ── log / graph ──
        LvimGitGraphLane1 = { fg = c.blue },
        LvimGitGraphLane2 = { fg = c.green },
        LvimGitGraphLane3 = { fg = c.magenta },
        LvimGitGraphLane4 = { fg = c.yellow },
        LvimGitGraphLane5 = { fg = c.cyan },
        LvimGitGraphLane6 = { fg = c.orange },
        LvimGitGraphLane7 = { fg = c.purple },
        LvimGitLogId = { fg = c.yellow, bold = true },
        LvimGitRefBranch = { fg = c.green, bold = true },
        LvimGitRefRemote = { fg = c.magenta },
        LvimGitRefTag = { fg = c.yellow },
        LvimGitRefBookmark = { fg = c.cyan, bold = true },
        LvimGitRefHead = { fg = c.blue, bold = true },
        LvimGitAhead = { fg = c.green },
        LvimGitBehind = { fg = c.red },

        -- ── conflict / merge ──
        LvimGitConflictOurs = { bg = mtint(c.green, 0.15) },
        LvimGitConflictTheirs = { bg = mtint(c.blue, 0.15) },
        LvimGitConflictBase = { bg = mtint(c.yellow, 0.15) },
        LvimGitConflictMarker = { fg = c.red, bold = true },

        -- ── transient ──
        LvimGitTransientOn = { fg = c.green, bold = true },
        LvimGitTransientOff = { fg = c.fg_dark },
        LvimGitTransientValue = { fg = c.yellow },
        LvimGitTransientSaved = { fg = c.cyan, bold = true },

        -- ── sequencer todo (per-command accents) ──
        LvimGitSeqPick = { fg = c.green },
        LvimGitSeqReword = { fg = c.yellow },
        LvimGitSeqEdit = { fg = c.yellow, bold = true },
        LvimGitSeqSquash = { fg = c.blue },
        LvimGitSeqFixup = { fg = c.blue },
        LvimGitSeqDrop = { fg = c.red },
    }
    return groups
end

--- A UI glyph the panels write INTO their own text (a ref badge, an ahead/behind count, the repo band's
--- branch icon) as its lvim-icons IMAGE where UI icons are images ("material"): the two placeholder cells and
--- the image's group — paint those bytes with that group only, its foreground IS the image id. Anywhere else
--- the glyph comes back as given and `img_hl` is nil (colour it with `group` as always).
---@param glyph string
---@param group string
---@return string text, string? img_hl
function M.ui_icon(glyph, group)
    local ok, iconlib = pcall(require, "lvim-utils.icons")
    if not (ok and iconlib.ui_text) then
        return glyph, nil
    end
    local t, h, img = iconlib.ui_text(glyph, group)
    if not img then
        return t, nil
    end
    return t, h
end

--- A repo-band builder (the `hl.band_line` parts of the status / log subtitle) whose glyphs become images
--- where UI icons are images. `part` makes a `{ text, accent }` part led by a glyph, `append` adds a glyph
--- badge after the joined line, and `spans` returns the line's spans plus one IMAGE span per image glyph —
--- placed after the accent spans so the image group wins over the part's accent on those bytes. With glyphs
--- (any mode but "material") the parts, text and spans are exactly the plain ones.
---@return { part: fun(glyph: string, rest: string, accent: string): table, append: fun(text: string, gap: string, glyph: string, rest: string): string, spans: fun(parts: table[], hls: table[]): table[] }
function M.band_icons()
    local extra = {}
    local b = {}
    function b.part(glyph, rest, accent)
        local icon, img_hl = M.ui_icon(glyph, hl.section_accent(accent).text)
        return { text = icon .. rest, accent = accent, img = img_hl and { #icon, img_hl } or nil }
    end
    function b.append(text, gap, glyph, rest)
        local icon, img_hl = M.ui_icon(glyph, "LvimUiSubtitle")
        local at = #text + #gap
        if img_hl then
            extra[#extra + 1] = { at, at + #icon, img_hl }
        end
        return text .. gap .. icon .. rest
    end
    function b.spans(parts, hls)
        local k = 0
        local out = vim.list_extend({}, hls)
        for _, p in ipairs(parts) do
            if p.accent then
                k = k + 1 -- band_line emits one span per accented part, in order
                if p.img and hls[k] then
                    out[#out + 1] = { hls[k][1], hls[k][1] + p.img[1], p.img[2] }
                end
            end
        end
        return vim.list_extend(out, extra)
    end
    return b
end

--- The Public-API registry mapping each hunk type → its `{ sign, nr }` group names, so consumers
--- (statuscolumn/statusline) discover the auto-defined group names instead of hardcoding them.
---@type table<string, { sign: string, nr: string }>
M.sign_groups = {
    add = { sign = "LvimGitSignAdd", nr = "LvimGitSignAddNr" },
    change = { sign = "LvimGitSignChange", nr = "LvimGitSignChangeNr" },
    delete = { sign = "LvimGitSignDelete", nr = "LvimGitSignDeleteNr" },
    topdelete = { sign = "LvimGitSignTopDelete", nr = "LvimGitSignTopDeleteNr" },
    changedelete = { sign = "LvimGitSignChangeDelete", nr = "LvimGitSignChangeDeleteNr" },
    untracked = { sign = "LvimGitSignUntracked", nr = "LvimGitSignUntrackedNr" },
}

return M
