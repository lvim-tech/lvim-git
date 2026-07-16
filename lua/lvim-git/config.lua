-- lvim-git.config: the LIVE configuration table for the two-VCS (git + jj) porcelain.
-- Holds the defaults; `setup()` merges user overrides into it IN PLACE (via lvim-utils.utils.merge),
-- so every `require("lvim-git.config")` reader sees the effective values. Nothing is captured at
-- setup time — a control-center toggle takes effect on the next open with no restart.
--
-- Each COMPONENT has its own `enabled` flag: a disabled component loads nothing (no require, no
-- autocmd, no keymap, no signs namespace). Components depend only on the shared core (backend/model/
-- config/state/highlights), never on each other — see the decoupling contract in the plan.
--
---@module "lvim-git.config"

---@class LvimGitGitConfig
---@field cmd string  the git executable (default "git")

---@class LvimGitJjConfig
---@field cmd string  the jj executable (default "jj")

---@class LvimGitColocatedConfig
---@field sync      "auto"|"manual"  "auto" reconciles after every op + on watchers/focus; "manual" only on `:LvimGit sync`
---@field watch     boolean          fs_event watchers on .git refs/HEAD + .jj op heads
---@field debounce  integer          ms a burst of watcher events is coalesced before one reconcile
---@field indicator boolean          show the "git+jj" colocated lens badge in panel headers

---@class LvimGitSignsIcons
---@field add           string
---@field change        string
---@field delete        string
---@field top_delete    string
---@field change_delete string
---@field untracked     string

---@class LvimGitSignsConfig
---@field enabled  boolean            attach gutter signs to tracked buffers
---@field base     "index"|"head"     git sign base (jj always uses the parent change @-)
---@field debounce integer            ms a buffer change is debounced before recomputing hunks
---@field icons    LvimGitSignsIcons  the gutter glyphs (verified single-width Nerd/box-drawing)
---@field gutter   boolean            place the visible gutter GLYPH (default true). `false` = still compute the
---                                    hunk data + serve the PUBLIC reads (`line_hunk`/`line_hl`/`line_sign`),
---                                    but draw NO glyph — for a custom `statuscolumn` that colours its own bar
---                                    from `line_hl` (one symbol, colour tells the state) instead of a glyph.

---@class LvimGitBlameInlineConfig
---@field enabled   boolean          auto-attach inline blame virtual text to file buffers on load
---@field scope     "line"|"file"    "line" = only the cursor line; "file" = every line
---@field delay     integer          debounce (ms) after the cursor settles before resolving the line
---@field format    string           template with <sha> <author> <date> <summary> tokens
---@field highlight string           highlight group for the inline virtual text

---@class LvimGitBlameConfig
---@field enabled     boolean                inline blame + the full blame split
---@field inline      LvimGitBlameInlineConfig
---@field date_format "relative"|"iso"|"short"  the date column / <date> token format
---@field recency     boolean                heat-tint the split's sha column by commit age
---@field split_width integer                the native blame split's column width (min 24)
---@field ignore_whitespace boolean          seed the split with `-w` (ignore whitespace)
---@field detect_moves boolean               seed the split with `-M` (detect moved lines within a file)
---@field detect_copies boolean              seed the split with `-C` (detect moved/copied lines across files)
---@field ignore_revs_file? string           seed the split with `--ignore-revs-file=<path>` (skip formatting revs)

---@class LvimGitDiffviewConfig
---@field enabled    boolean            the rich revision/range diff view (alias `diff`)
---@field mode       "split"|"inline"   default diff rendering (runtime-toggleable with `t`)
---@field char_level boolean            char-level intra-line refinement pass
---@field context    integer            diff context lines (-U<n>)
---@field base_block boolean            merge view: show the 4th BASE block

---@class LvimGitLogConfig
---@field enabled boolean
---@field limit   integer  max commits fetched per log query
---@field graph   boolean  render the colored DAG graph lanes

---@class LvimGitHistoryConfig
---@field enabled boolean
---@field follow  boolean  follow renames (--follow)
---@field limit   integer

---@class LvimGitStatusConfig
---@field enabled      boolean
---@field recent_count integer  how many recent commits the status "Recent" section shows

---@class LvimGitToggleComponent
---@field enabled boolean

---@class LvimGitTransientConfig
---@field enabled       boolean                    the transient engine (the dispatch popup needs it)
---@field level         integer                    Magit levels 1-7: hide advanced infixes/actions above this
---@field layout        "float"|"cursor"|"bottom"  the transient popup layout
---@field save_defaults boolean                    persist per-prefix `save`d args (the one json store use)

---@class LvimGitLayouts
---@field status    "area"|"float"|"bottom"|"tab"
---@field diffview  "area"|"float"|"bottom"|"tab"
---@field log       "area"|"float"|"bottom"|"tab"
---@field history   "area"|"float"|"bottom"|"tab"
---@field conflict  "area"|"float"|"bottom"|"tab"
---@field stash     "area"|"float"|"bottom"|"tab"
---@field refs      "area"|"float"|"bottom"|"tab"
---@field oplog     "area"|"float"|"bottom"|"tab"
---@field submodule "area"|"float"|"bottom"|"tab"
---@field worktree  "area"|"float"|"bottom"|"tab"
---@field bisect    "area"|"float"|"bottom"|"tab"
---@field subtree   "area"|"float"|"bottom"|"tab"
---@field patch     "area"|"float"|"bottom"|"tab"
---@field sparse    "area"|"float"|"bottom"|"tab"
---@field wip       "area"|"float"|"bottom"|"tab"
---@field sequencer "area"|"float"|"bottom"|"tab"

---@class LvimGitKeymaps
---@field hunk_next string
---@field hunk_prev string

---@class LvimGitBrowseConfig
---@field enabled boolean                       remote-URL → web-host URL mapping (github/gitlab/bitbucket/sourcehut/self-hosted)
---@field remote  string                        the remote to browse (default "origin"; empty = the branch's upstream remote)
---@field yank    boolean                        yank the URL to the clipboard instead of opening it (a `--yank` arg forces this per-call)
---@field commit  boolean                        build a permalink at the HEAD sha instead of the branch ref (a `--commit` arg forces it)
---@field hosts   table<string, "github"|"gitlab"|"bitbucket"|"sourcehut">  self-hosted host → forge-family map

---@class LvimGitRunConfig
---@field enabled boolean  the `:LvimGit run <args>` raw passthrough + its streamed output panel

---@class LvimGitConfig
---@field vcs                 "auto"|"git"|"jj"        the PRIMARY lens; auto = jj when a .jj dir exists
---@field git                 LvimGitGitConfig
---@field jj                  LvimGitJjConfig
---@field colocated           LvimGitColocatedConfig
---@field signs               LvimGitSignsConfig
---@field blame               LvimGitBlameConfig
---@field diffview            LvimGitDiffviewConfig
---@field log                 LvimGitLogConfig
---@field history             LvimGitHistoryConfig
---@field status              LvimGitStatusConfig
---@field stash               LvimGitToggleComponent
---@field refs                LvimGitToggleComponent
---@field oplog               LvimGitToggleComponent
---@field conflict            LvimGitToggleComponent
---@field submodule           LvimGitToggleComponent
---@field worktree            LvimGitToggleComponent
---@field bisect              LvimGitToggleComponent
---@field subtree             LvimGitToggleComponent
---@field patch               LvimGitToggleComponent
---@field sparse              LvimGitToggleComponent
---@field sequencer           LvimGitToggleComponent
---@field wip                 LvimGitToggleComponent
---@field transient           LvimGitTransientConfig
---@field layouts             LvimGitLayouts
---@field keymaps             LvimGitKeymaps
---@field confirm_destructive boolean  confirm discard/reset-hard/force-push/branch-delete/op-restore
---@field browse              LvimGitBrowseConfig
---@field run                 LvimGitRunConfig
---@field hl                  table<string, string>  highlight-group name overrides

---@type LvimGitConfig
return {
    -- The PRIMARY lens. "auto" prefers jj when a `.jj` dir exists (colocated repos → jj wins), else
    -- git. A one-off `git`/`jj` token in a `:LvimGit` command forces the other lens for that command.
    vcs = "auto",
    git = { cmd = "git" },
    jj = { cmd = "jj" },
    colocated = {
        sync = "auto", -- "auto" (after every op + watchers/focus) | "manual" (:LvimGit sync)
        watch = true, -- fs_event watchers on .git refs/HEAD + .jj op heads
        debounce = 200, -- ms a burst of watcher events is coalesced before one reconcile
        indicator = true, -- "git+jj" lens badge in panel headers
    },
    -- signs colors are FREE: the LvimGitSign{Add,Change,Delete,TopDelete,ChangeDelete,Untracked}
    -- groups (+ their …Nr line-number variants) are AUTO-DEFINED from lvim-utils.colors via
    -- highlights.build() — no color config here, rebuilt on ColorScheme, overridable per the theming
    -- canon. Consumers read the group name per line via signs.line_hl (Public API).
    signs = {
        enabled = true,
        gutter = true, -- draw the gutter glyph; false = data-only (line_hl/line_hunk) for a custom statuscolumn
        base = "index", -- git: "index"|"head"; jj always the parent change @-
        debounce = 150,
        icons = {
            add = "▎",
            change = "▎",
            delete = "▁",
            top_delete = "▔",
            change_delete = "▎",
            untracked = "┆",
        },
    },
    blame = {
        enabled = true,
        inline = {
            enabled = false, -- opt-in (toggle with `:LvimGit toggle_blame`)
            scope = "line", -- "line" (cursor line only) | "file" (every line)
            delay = 700,
            format = "<author>, <date> ➤ <summary>",
            highlight = "LvimGitBlame",
        },
        date_format = "relative", -- "relative" | "iso" | "short"
        recency = false, -- heat-tint the split's sha column by commit age
        split_width = 44, -- the native blame split's column width (min 24)
        ignore_whitespace = false, -- seed the split transient with -w
        detect_moves = false, -- seed the split transient with -M
        detect_copies = false, -- seed the split transient with -C (moved/copied across files)
        ignore_revs_file = nil, -- seed the split transient with --ignore-revs-file=<path>
    },
    diffview = {
        enabled = true,
        mode = "split", -- "split" | "inline" (runtime-toggleable with `t`)
        char_level = true,
        context = 3,
        base_block = false, -- merge view: show the 4th BASE block
    },
    log = { enabled = true, limit = 256, graph = true },
    history = { enabled = true, follow = true, limit = 256 },
    status = { enabled = true, recent_count = 10 },
    stash = { enabled = true },
    refs = { enabled = true },
    oplog = { enabled = true },
    conflict = { enabled = true },
    submodule = { enabled = true },
    worktree = { enabled = true },
    bisect = { enabled = true },
    subtree = { enabled = true }, -- the subtree transient (add/pull/push/split, --prefix)
    patch = { enabled = true }, -- format-patch / am / apply (create & apply patches)
    sparse = { enabled = true }, -- sparse-checkout transient + the sparse status section
    sequencer = { enabled = true }, -- interactive-rebase todo panel + the sequencer status section
    wip = { enabled = false }, -- work-in-progress refs mode (opt-in, like Magit)
    transient = {
        enabled = true,
        level = 4, -- Magit levels 1-7: hide advanced infixes/actions above this
        layout = "float", -- "float" | "cursor" | "bottom"
        save_defaults = true, -- persist per-prefix `save`d args (the one store use)
    },
    -- Per-view default layout; a per-command token (area|float|bottom|tab) overrides it and is sticky
    -- for the session. ALL FOUR layouts are available for EVERY view. Heavy multi-sector views default
    -- to the fullscreen `tab` workspace, light list panels to `area`, history/bisect to `float`.
    layouts = {
        status = "tab",
        diffview = "tab",
        log = "tab",
        history = "float",
        conflict = "tab",
        stash = "area",
        refs = "area",
        oplog = "area",
        submodule = "area",
        worktree = "area",
        bisect = "float",
        subtree = "float", -- the subtree transient (a modal popup)
        patch = "float", -- the patch transient (a modal popup)
        sparse = "float", -- the sparse-checkout transient (a modal popup)
        wip = "float", -- the wip transient (a modal popup)
        sequencer = "float", -- the interactive-rebase todo panel (a modal editing surface)
    },
    keymaps = { hunk_next = "]h", hunk_prev = "[h" },
    confirm_destructive = true, -- discard/reset-hard/force-push/branch-delete/op-restore
    -- `:LvimGit browse [file|rev]` — remote-URL → web-host URL (github/gitlab/bitbucket/sourcehut/self-hosted).
    browse = {
        enabled = true,
        remote = "origin", -- the remote to browse ("" = the branch's upstream remote)
        yank = false, -- yank the URL instead of opening it (`--yank` forces this per-call)
        commit = false, -- permalink at the HEAD sha instead of the branch ref (`--commit` forces it)
        hosts = {}, -- self-hosted host → forge family, e.g. { ["git.acme.io"] = "gitlab" }
    },
    -- `:LvimGit run <git args>` — the fugitive `:Git` raw passthrough (streamed output panel; `run!` = a
    -- terminal for TTY-interactive commands).
    run = { enabled = true },
    hl = {},
}
