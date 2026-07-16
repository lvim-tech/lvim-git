# lvim-git

A comprehensive, two-VCS (**git** + **jj / Jujutsu**) porcelain for the lvim-tech
ecosystem — a single plugin that unifies the roles of a status client, a transient
command system, gutter signs + hunk staging, blame, a rich diff / log / graph / history
view, a 3-way merge resolver, the interactive-rebase sequencer, stash / submodule /
worktree / bisect / subtree / patch / sparse / wip tooling, a raw command passthrough +
a browse-on-forge helper, and — on a **colocated** repo — automatic **bidirectional
git ↔ jj synchronisation**.

Everything runs over **one VCS abstraction** that speaks both git and jj: every panel
renders from the same model regardless of the backend, so the whole UI works unchanged
on a jj repo (with the jj-only surfaces — the operation log, bookmarks, workspaces —
lit up and the git-only ones, e.g. the index and bisect, cleanly hidden).

Internally lvim-git is a **suite of independently-usable components** over a shared core
(`backend` / `model` / `config` / `state` / `highlights`). Each component has its own
`enabled` flag, depends only on the core (never on another component), and a disabled
component loads **nothing** — no `require`, no autocmd, no keymap, no namespace.

[![License: BSD-3-Clause](https://img.shields.io/badge/License-BSD--3--Clause-blue.svg)](https://github.com/lvim-tech/lvim-git/blob/main/LICENSE)

## Features

- **Status client** (`:LvimGit status`) — a sectioned status surface (conflicted /
  staged / unstaged / untracked / stashes / unpushed / unpulled / recent), each an
  accordion of file → hunk rows with a live diff preview. Stage / unstage / discard at
  **section · file · hunk · visual-line region** granularity; visibility levels; a filter
  band; a footer of transient verb launchers. Leading sequencer / bisect sections while
  one is in progress.
- **Transient command system** — a full transient engine: grouped switch / option /
  action popups with direct single-key hotkeys, inline per-row values, a visibility level
  (1–7), and session `set` / persistent `save` / `reset` of argument sets. The `?`
  dispatch popup is the top-level menu.
- **Gutter signs + hunk ops** — in-process (`vim.diff`) hunk computation, debounced,
  with a public render-hot API (`line_hunk` / `line_hl` / `buf_status`) for a statusline /
  statuscolumn. `<Plug>` maps to stage / unstage / reset / preview / navigate hunks.
- **Diff view** (`:LvimGit diffview [rev|range] [-- paths]`) — a dedicated tabpage of real
  windows: a files panel + a split (`diffthis`) or inline diff with char-level intra-line
  refinement; hunk & line-region staging; a diff options transient (whitespace / context /
  algorithm).
- **Log / graph** (`:LvimGit log [revset]`) — a coloured DAG graph, ref badges, a live
  `--stat` preview, a filter band + a log-args transient (`--all` / author / grep /
  since / until / path), per-commit action popup, lazy pagination.
- **File history** (`:LvimGit history [path]`, visual range → `-L`) — whole-file `--follow`
  or a line-range history; open any revision's change to the file.
- **Blame** (`:LvimGit blame`, `:LvimGit toggle_blame`) — inline virtual-text blame that
  follows the cursor (aligned with unsaved edits) **and** a scroll-locked native split
  with a triage loop (reblame-at-parent, reblame-at-rev, per-commit
  actions, options transient). Public authorship reads for a statusline.
- **Refs** (`:LvimGit refs`) — branches / remotes / tags (and jj **bookmarks**), tracking
  + ahead/behind badges, a conflicted-bookmark badge, checkout / create / delete / rename,
  and the cherry (`git cherry`) view.
- **Sequencer** — the interactive-rebase TODO panel (pick / reword / edit / squash /
  fixup / drop + reorder), driven through git's own `GIT_SEQUENCE_EDITOR`; a live
  sequencer status section with continue / skip / abort / edit-todo controls for
  rebase / cherry-pick / revert.
- **Stash / conflict / merge** — a stash panel + transient; a 3-block (OURS | RESULT |
  THEIRS, + optional BASE) merge view of real `diffthis` windows, plus in-buffer conflict
  resolution ops (`]x` / `[x`, `co` / `ct` / `cb` / `cB` / `cn`, `Co` / `Ct`).
- **Submodule / worktree / bisect / subtree / patch / wip / sparse** — list panels and/or
  transients for each, with caps-gated status sections (bisect, submodules, sparse).
- **Raw passthrough & browse** — `:LvimGit run <args>` (streamed output panel;
  `:LvimGit! run` = a real terminal for TTY-interactive commands) and `:LvimGit browse` —
  the forge web URL for the current file+line / a commit / the repo (github / gitlab /
  bitbucket / sourcehut + a self-hosted map).
- **Tab workspace** — any heavy view (`status` / `log` / `history` / `diffview` /
  `conflict`) can open fullscreen in a dedicated workspace tabpage (`… tab`).
- **jj backend + operation log** — a full jj implementation behind the same seam:
  `:LvimGit jj` (the jj verb menu), `describe` / `new` / `squash` / `abandon` / `edit` /
  `bookmark` / `workspace` / `undo`, and the operation log (`:LvimGit oplog`) with op
  undo / restore (git repos show the reflog there instead).
- **Colocated bidirectional sync** — on a repo that is both `.git` and `.jj`, an external
  or plugin-side git change is imported into jj and jj-side changes are exported to git,
  automatically (fs_event watchers + after-op + on-focus), with root-cause loop-avoidance
  and a `git+jj` / drift indicator in the panel headers. `:LvimGit sync` forces a
  reconcile.

## Installation

Requires Neovim >= 0.10 and the lvim-tech runtime deps
[lvim-utils](https://github.com/lvim-tech/lvim-utils),
[lvim-ui](https://github.com/lvim-tech/lvim-ui), and
[lvim-icons](https://github.com/lvim-tech/lvim-icons). `git` is required; `jj`
(Jujutsu) is optional — the jj lens and colocated sync light up only when it is present.

### lvim-installer (recommended)

Install and manage it from the LVIM package manager — open the **Plugins** tab and
install / update / pin it:

```vim
:LvimInstaller plugins
```

lvim-installer installs plugins through Neovim's built-in `vim.pack`, so no external
plugin manager is needed.

### Native (vim.pack)

```lua
vim.pack.add({
    { src = "https://github.com/lvim-tech/lvim-utils" },
    { src = "https://github.com/lvim-tech/lvim-ui" },
    { src = "https://github.com/lvim-tech/lvim-icons" },
    { src = "https://github.com/lvim-tech/lvim-git" },
})
require("lvim-git").setup({})
```

## Commands

Everything is one command: `:LvimGit <subcommand> [area|float|bottom|tab] [git|jj] [args]`.
The **layout token** (`area` / `float` / `bottom` / `tab`) is recognised anywhere in the
args and is sticky for the session; a one-off **lens token** (`git` / `jj`) forces the
other backend for that call on a colocated repo. `:LvimGit` with no subcommand opens
`status`.

| Command | Description |
| --- | --- |
| `:LvimGit status` | The sectioned status client (default). |
| `:LvimGit diffview [rev\|range] [-- paths]` | The diff view (`diff` is an alias). |
| `:LvimGit log [revset]` | The log / graph panel. |
| `:LvimGit history [path]` | File history (visual range → `-L` line history). |
| `:LvimGit blame` | The native blame split (visual range → `-L`). |
| `:LvimGit toggle_blame` | Toggle inline virtual-text blame. |
| `:LvimGit refs` | Branches / remotes / tags / bookmarks. |
| `:LvimGit stash` | The stash panel. |
| `:LvimGit conflict [path]` | The 3-block merge / conflict resolver. |
| `:LvimGit oplog` | jj operation log (git → reflog). |
| `:LvimGit submodule` \| `worktree` | Submodule / worktree (jj workspace) panels. |
| `:LvimGit bisect` \| `subtree` \| `patch` \| `sparse` \| `wip` | Their panels / transients. |
| `:LvimGit dispatch` | The `?` top-level transient menu. |
| `:LvimGit commit\|push\|pull\|fetch\|rebase\|merge\|cherry-pick\|revert\|reset\|tag` | The git verb transients. |
| `:LvimGit jj` | The jj verb menu. |
| `:LvimGit describe\|new\|squash\|abandon\|edit\|bookmark\|workspace\|undo` | Direct jj verbs. |
| `:LvimGit sync [import\|export]` | Force a colocated git ↔ jj reconcile. |
| `:LvimGit run <args>` / `:LvimGit! run <args>` | Raw passthrough (streamed panel / terminal). |
| `:LvimGit browse [file\|rev] [--yank] [--commit]` | The forge web URL for the file / commit / repo. |
| `:LvimGit toggle_signs` | Toggle gutter signs. |

Also `:checkhealth lvim-git`.

## Setup

`config.lua` is the **live config**: `setup()` merges your options into it in place, and
every reader sees the effective values — a change takes effect on the next open, no
restart. Below is the **complete default configuration** (every option at its default):

```lua
require("lvim-git").setup({
    -- The PRIMARY lens. "auto" prefers jj when a `.jj` dir exists (colocated → jj wins),
    -- else git. A one-off `git`/`jj` token in a `:LvimGit` command forces the other lens.
    vcs = "auto", -- "auto" | "git" | "jj"
    git = { cmd = "git" },
    jj = { cmd = "jj" },
    colocated = {
        sync = "auto", -- "auto" (after every op + watchers/focus) | "manual" (:LvimGit sync)
        watch = true, -- fs_event watchers on .git refs/HEAD + .jj op heads
        debounce = 200, -- ms a burst of watcher events is coalesced before one reconcile
        indicator = true, -- "git+jj" lens badge (+ a drift flag) in panel headers
    },
    -- Sign colors are FREE: the LvimGitSign{Add,Change,Delete,TopDelete,ChangeDelete,
    -- Untracked} groups (+ their …Nr line-number variants) are AUTO-DEFINED from the
    -- lvim-utils palette, rebuilt on ColorScheme. Consumers read the per-line group via
    -- `line_hl` (Public API). Only the glyphs are configured here.
    signs = {
        enabled = true,
        base = "index", -- git: "index" | "head"; jj always uses the parent change @-
        debounce = 150, -- ms a buffer change is debounced before recomputing hunks
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
            delay = 700, -- ms after the cursor settles before resolving the line
            format = "<author>, <date> ➤ <summary>", -- <sha> <author> <date> <summary>
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
        char_level = true, -- char-level intra-line refinement
        context = 3, -- diff context lines (-U<n>)
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
    patch = { enabled = true }, -- format-patch / am / apply
    sparse = { enabled = true }, -- sparse-checkout transient + status section
    sequencer = { enabled = true }, -- interactive-rebase todo panel + status section
    wip = { enabled = false }, -- work-in-progress refs mode (opt-in)
    transient = {
        enabled = true, -- the transient engine (the dispatch popup needs it)
        level = 4, -- transient levels 1-7: hide advanced infixes/actions above this
        layout = "float", -- "float" | "cursor" | "bottom"
        save_defaults = true, -- persist per-prefix `save`d args (the one store use)
    },
    -- Per-view default layout; a per-command token (area|float|bottom|tab) overrides it
    -- and is sticky for the session. All four layouts are available for every view.
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
        subtree = "float",
        patch = "float",
        sparse = "float",
        wip = "float",
        sequencer = "float",
    },
    keymaps = { hunk_next = "]h", hunk_prev = "[h" }, -- set to "" to skip a nav map
    confirm_destructive = true, -- confirm discard/reset-hard/force-push/branch-delete/op-restore
    browse = {
        enabled = true,
        remote = "origin", -- the remote to browse ("" = the branch's upstream remote)
        yank = false, -- yank the URL instead of opening it (`--yank` forces this per-call)
        commit = false, -- permalink at the HEAD sha instead of the branch ref (`--commit` forces it)
        hosts = {}, -- self-hosted host → forge family, e.g. { ["git.acme.io"] = "gitlab" }
    },
    run = { enabled = true }, -- `:LvimGit run <args>` raw passthrough + its streamed output panel
    hl = {}, -- highlight-group name overrides
})
```

## Public API

`require("lvim-git")` re-exports the component openers and a set of **render-safe** read
accessors (safe to call from a statusline / statuscolumn `render`). The `line_hunk` /
`line_hl` / `buf_status` reads are O(1) and never shell out; `line` may resolve a blame
asynchronously (its `line_cached` twin is O(1)).

| Function | Description |
| --- | --- |
| `setup(opts)` | Merge options into the live config and wire enabled components (idempotent). |
| `status(opts)` / `diffview(opts)` / `log(opts)` / `history(path, range)` | Open a view. |
| `blame(opts)` / `blame_line(buf)` | The blame split / toggle inline blame. |
| `conflict()` / `stash()` / `refs()` / `oplog()` | Open the respective panel. |
| `submodule()` / `worktree()` / `bisect()` / `wip()` / `dispatch()` | Open the respective panel / menu. |
| `open(sub, opts)` | Run any subcommand programmatically. |
| `repo(root_or_buf?)` | The cached `Repo` model (render-safe). |
| `head(root_or_buf?)` | Short HEAD / change-id (render-safe). |
| `buf_status(buf?)` | Per-buffer `{ added, changed, removed, staged? }` counts (O(1)). |
| `line_hunk(buf, lnum)` | The hunk **type** for a line (O(1)) — the statuscolumn case. |
| `line_hl(buf, lnum)` | The auto-defined sign HL group for a line (O(1)). |
| `is_attached(buf?)` | Whether signs are attached to the buffer. |
| `sequencer_state(root?)` | The in-progress rebase/cherry-pick/revert state (`{ active = false }` when idle). |
| `is_colocated(root_or_buf?)` | Whether the repo is a colocated `.git` + `.jj`. |
| `sync_state(root_or_buf?)` | `{ colocated, mode, watching, syncing, drift, imported, exported }` (nil when not colocated). |
| `sync(root_or_buf?, direction?)` | Force a colocated reconcile (`:LvimGit sync` in code form). |
| `refresh(root_or_buf?)` | Re-derive the repo model (invalidate caches) and fire `User LvimGitRepoChanged { reason = "external" }` so every open panel reloads. The seam for a tool that changed the working tree **outside** lvim-git. No-op outside a repo. |

Two more stable surfaces live on their own modules (a sibling plugin's soft seams):

- `require("lvim-git.browse")` — the pure forge-host helpers `parse_remote(url)`,
  `forge_of(host)` and `build_url(forge, base, target)` (classify a remote's forge family
  and build its web URL; used by `:LvimGit browse` and safe to reuse).
- `require("lvim-git.ui.status").register_section(provider)` — register an extra **trailing**
  section in the status buffer. `provider = { id, title?, position = "trailing", accent?,
  rows(root) }`; `rows(root)` must be render-safe (a cache read) and returns the section's
  child rows, or nil/empty to hide it. Rendered with the same fold machinery as the built-in
  sections; re-registering an `id` replaces it. A companion plugin self-registers its section
  when both are installed.

The blame authorship reads live on the component:
`require("lvim-git.blame").line(buf, lnum, cb)` (async, cached) and
`require("lvim-git.blame").line_cached(buf, lnum)` (render-safe, O(1)).

### Statuscolumn example

```lua
-- A minimal statuscolumn segment painting the git sign colour per line.
function _G.LvimGitStatusCol()
    local git = require("lvim-git")
    local buf = vim.api.nvim_get_current_buf()
    local lnum = vim.v.lnum
    local group = git.line_hl(buf, lnum)
    local glyph = git.line_hunk(buf, lnum) and "▎" or " "
    return group and ("%#" .. group .. "#" .. glyph .. "%*") or " "
end

vim.opt.statuscolumn = "%{%v:lua.LvimGitStatusCol()%}%s%l "
```

### Statusline example

```lua
-- A branch + add/change/remove segment.
function _G.LvimGitBranch()
    local git = require("lvim-git")
    local head = git.head() -- short HEAD / change-id
    local s = git.buf_status() -- { added, changed, removed, staged? }
    if not head then
        return ""
    end
    local parts = { " " .. head }
    if s then
        if s.added > 0 then
            parts[#parts + 1] = "+" .. s.added
        end
        if s.changed > 0 then
            parts[#parts + 1] = "~" .. s.changed
        end
        if s.removed > 0 then
            parts[#parts + 1] = "-" .. s.removed
        end
    end
    return table.concat(parts, " ")
end
```

## Events, `<Plug>` maps, buffer variables

lvim-git fires `User` autocmd events you can hook:

| Event | When |
| --- | --- |
| `LvimGitAttach` / `LvimGitDetach` | Signs attach / detach from a buffer. |
| `LvimGitBufChanged` | A buffer's hunks were recomputed. |
| `LvimGitRepoChanged` | Any repo mutation (staging, a verb, an external / synced change). |
| `LvimGitBlameLine` | The inline blame line under the cursor changed (`{ buf, lnum, info }`). |
| `LvimGitProgress` | Streamed push / pull / fetch progress. |
| `LvimGitConflicts` | The conflicted-file set changed (`{ root, count }`). |
| `LvimGitDiffOpen` / `LvimGitDiffClose` | The diff view opened / closed. |

The gutter hunk `<Plug>` maps (bind them yourself; the nav ones are also bound to
`config.keymaps.hunk_next` / `hunk_prev`, default `]h` / `[h`):

```lua
vim.keymap.set("n", "<leader>gs", "<Plug>(LvimGitHunkStage)")
vim.keymap.set("n", "<leader>gu", "<Plug>(LvimGitHunkUnstage)")
vim.keymap.set("n", "<leader>gr", "<Plug>(LvimGitHunkReset)")
vim.keymap.set("n", "<leader>gp", "<Plug>(LvimGitHunkPreview)")
vim.keymap.set("n", "]h", "<Plug>(LvimGitHunkNext)")
vim.keymap.set("n", "[h", "<Plug>(LvimGitHunkPrev)")
```

On every attached buffer these buffer-local variables are set (for a statusline):
`b:lvim_git_status`, `b:lvim_git_head`, `b:lvim_git_branch`, `b:lvim_git_root`.

## Highlights

All highlight groups are built from the `lvim-utils` palette and rebuilt on colorscheme
change (self-theming per the ecosystem canon); override any of them via `config.hl` or
your colorscheme. The families:

- **Signs** — `LvimGitSign{Add,Change,Delete,TopDelete,ChangeDelete,Untracked}` and their
  `…Nr` line-number variants (auto-defined; read per line via `line_hl`).
- **Diff** — `LvimGitDiff{Add,Delete,AddText,DeleteText,Fill}` (a two-tier line + char wash).
- **Blame** — `LvimGitBlame`, `LvimGitBlameHead`.
- **Log / graph** — `LvimGitGraphLane1..7`, `LvimGitLogId`, `LvimGitRefHead`, and the ref
  badge groups.
- **Conflict** — `LvimGitConflict{Ours,Base,Theirs,Marker}`.
- **Sequencer** — `LvimGitSeq*` (the action-word accents).

## Health

`:checkhealth lvim-git` reports: Neovim version; git version (and a warning below 2.23);
jj availability (the second lens); the lvim-ui / lvim-utils / lvim-icons deps; the current
buffer's repo + colocation detection; the colocated-sync mode + watcher state + any drift;
the browse remote → forge mapping; the enabled-components list; a public-API self-check;
and config sanity.
