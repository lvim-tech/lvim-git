-- lvim-git: a two-VCS (git + jj) porcelain for the lvim-tech ecosystem — a Magit-grade status
-- surface + transient command system, gutter signs + hunk ops, blame, a rich diff/log/history view,
-- 3-way merge, and the raw `git`/`jj` backbone — all over ONE VCS abstraction that speaks both git
-- and jj and keeps a colocated repo bidirectionally in sync.
--
-- Internally lvim-git is a SUITE of independently-usable components (signs / blame / diffview / log /
-- status / …) over a shared core (backend / model / config / state / highlights). A disabled
-- component loads NOTHING. `setup()` merges user opts into the LIVE config, registers the self-theming
-- highlights, wires the `:LvimGit` command, and lazily bootstraps each enabled component on first use.
--
-- This file is also the PUBLIC facade: the component openers (M.status/diffview/log/…) and the hot,
-- render-safe read accessors (M.repo/head/buf_status/line_hunk/line_hl/…) re-exported from the owning
-- components. See the Public API section of the README / `:help lvim-git-api`.
--
---@module "lvim-git"

local config = require("lvim-git.config")
local highlights = require("lvim-git.highlights")

local M = {}

---@type boolean  guards the one-time command / highlight registration
local registered = false

-- ── component openers (each bootstraps ONLY its own component on demand) ─────

--- Open the status client.
---@param opts? table
function M.status(opts)
    require("lvim-git.ui.status").open(opts)
end

--- Open the diff view (`diff` alias). `opts = { rev?, range?, paths?, mode?, layout? }`.
---@param opts? table
function M.diffview(opts)
    require("lvim-git.ui.diff").open(opts)
end

--- Open the log / graph panel.
---@param opts? table
function M.log(opts)
    require("lvim-git.ui.log").open(opts)
end

--- Open the file-history panel.
---@param path? string
---@param range? string
function M.history(path, range)
    require("lvim-git.ui.history").open({ path = path, range = range })
end

--- Open the full blame split.
---@param opts? table
function M.blame(opts)
    require("lvim-git.blame").open(opts)
end

--- Toggle inline (virtual-text) blame for a buffer.
---@param buf? integer
function M.blame_line(buf)
    require("lvim-git.blame").toggle_inline(buf)
end

--- Open the conflict / 3-block merge view.
function M.conflict()
    require("lvim-git.conflict").open()
end

--- Open the stash panel.
function M.stash()
    require("lvim-git.ui.stash").open()
end

--- Open the refs (branches/bookmarks/tags/remotes) panel.
function M.refs()
    require("lvim-git.ui.refs").open()
end

--- Open the op-log (jj) / reflog (git) panel.
function M.oplog()
    require("lvim-git.ui.oplog").open()
end

--- Open the submodule panel.
function M.submodule()
    require("lvim-git.ui.submodule").open()
end

--- Open the worktree (jj workspace) panel.
function M.worktree()
    require("lvim-git.ui.worktree").open()
end

--- Open the bisect panel/transient.
function M.bisect()
    require("lvim-git.bisect").open()
end

--- Open the work-in-progress (wip) refs transient (opt-in; `config.wip.enabled`).
function M.wip()
    require("lvim-git.wip").open()
end

--- Open the dispatch popup (the Magit `?` menu).
function M.dispatch()
    require("lvim-git.ui.dispatch").open()
end

--- Generic dispatch to any subcommand (used by the `:LvimGit` command layer).
---@param sub string
---@param opts? table
function M.open(sub, opts)
    require("lvim-git.commands").run(sub, opts)
end

-- ── hot reads (render-safe unless noted; re-exported from the owning component) ──

--- The cached Repo model for a buffer/path/cwd (render-safe).
---@param root_or_buf? string|integer
---@return Repo?
function M.repo(root_or_buf)
    return require("lvim-git.backend").repo(root_or_buf)
end

--- Short HEAD / change-id of the buffer's repo (render-safe).
---@param root_or_buf? string|integer
---@return string?
function M.head(root_or_buf)
    return require("lvim-git.backend").head(root_or_buf)
end

--- Per-buffer add/changed/removed (+staged) counts for a statusline segment (render-safe, O(1)).
---@param buf? integer
---@return { added: integer, changed: integer, removed: integer, staged?: integer }?
function M.buf_status(buf)
    return require("lvim-git.signs").buf_status(buf or vim.api.nvim_get_current_buf())
end

--- The hunk TYPE for a buffer line (render-safe, O(1)) — the statuscolumn case.
---@param buf integer
---@param lnum integer
---@return string?
function M.line_hunk(buf, lnum)
    return require("lvim-git.signs").line_hunk(buf, lnum)
end

--- The auto-defined HL group name for a buffer line's hunk (render-safe, O(1)).
---@param buf integer
---@param lnum integer
---@return string?
function M.line_hl(buf, lnum)
    return require("lvim-git.signs").line_hl(buf, lnum)
end

--- True when signs are attached to the buffer.
---@param buf? integer
---@return boolean
function M.is_attached(buf)
    return require("lvim-git.signs").is_attached(buf or vim.api.nvim_get_current_buf())
end

--- The cached in-progress SEQUENCE (rebase / cherry-pick / revert) for a repo (render-safe). `{ active
--- = false }` when idle. The statusline "rebasing 3/8" segment source.
---@param root? string
---@return LvimGitSequencerState
function M.sequencer_state(root)
    return require("lvim-git.sequencer").state(root or require("lvim-git.backend").detect())
end

--- True when the path/buffer is inside a COLOCATED repo (a `.jj` + `.git` sharing one working copy) —
--- the state where the bidirectional git↔jj sync is active. Render-safe.
---@param root_or_buf? string|integer
---@return boolean
function M.is_colocated(root_or_buf)
    return require("lvim-git.backend.sync").is_colocated(root_or_buf)
end

--- The colocated git↔jj sync state for a repo (nil when not colocated): `{ colocated, mode, watching,
--- syncing, drift, imported, exported }`. Render-safe — the source for a status-header " git+jj" /
--- drift indicator.
---@param root_or_buf? string|integer
---@return table?
function M.sync_state(root_or_buf)
    return require("lvim-git.backend.sync").sync_state(root_or_buf)
end

--- Force a colocated git↔jj reconcile (the `:LvimGit sync` command in code form). No-op on a
--- non-colocated repo. `direction` optionally hints "import" / "export" (both run either way — each is
--- an idempotent no-op when the other side is already consistent).
---@param root_or_buf? string|integer
---@param direction? "import"|"export"
function M.sync(root_or_buf, direction)
    require("lvim-git.backend.sync").sync(root_or_buf, false, direction)
end

--- PUBLIC: re-derive the repo model and broadcast the change. Invalidates the cached status model and
--- re-reads the repo header (HEAD / branch / ahead-behind / state), then fires `User LvimGitRepoChanged`
--- with `data.reason = "external"` so every open lvim-git panel (and any sibling listening on the event)
--- reloads from the fresh model. This is the clean seam for a SIBLING plugin that changed the working tree
--- OUTSIDE lvim-git (e.g. a forge PR checkout / merge) — it re-syncs lvim-git instead of forging the event
--- itself. No-op (nothing fired) when the path/buffer is not inside a repo. Async: the header is refreshed
--- before the event fires.
---@param root_or_buf? string|integer
function M.refresh(root_or_buf)
    local backend = require("lvim-git.backend")
    local root = backend.detect(root_or_buf)
    if not root then
        return
    end
    -- Invalidate the render-safe caches the header reads serve, so a listener that renders synchronously
    -- (before the async refresh lands) does not paint a stale model.
    local repo = backend.repo(root)
    if repo then
        repo._status = nil
    end
    local function broadcast()
        vim.api.nvim_exec_autocmds(
            "User",
            { pattern = "LvimGitRepoChanged", data = { root = root, reason = "external" } }
        )
    end
    -- Re-derive the header (head/branch/ahead-behind/state), then broadcast. If the async read fails the
    -- event still fires so panels re-load themselves.
    backend.refresh(root, broadcast)
end

-- ── setup ────────────────────────────────────────────────────────────────────

--- Merge user options into the LIVE config (in place) and wire ONLY the enabled components.
---@param opts? LvimGitConfig
function M.setup(opts)
    require("lvim-utils.utils").merge(config, opts or {})
    if registered then
        return
    end
    registered = true
    require("lvim-utils.highlight").bind(highlights.build)
    require("lvim-git.commands").setup()

    -- Register the `git/` parent with the wallet (if installed), so `:LvimKeyring` renders git HTTPS
    -- credentials under a git icon + accent. pcall-guarded: lvim-git never hard-depends on lvim-keyring.
    pcall(function()
        require("lvim-keyring").register_namespace("git", { icon = "", accent = "orange" })
    end)
    -- Enabled components self-wire (autocmds/keymaps/cursor registration) on setup; a disabled one is
    -- never touched. Signs auto-attach; the rest bootstrap lazily on their opener/subcommand.
    -- (Component wiring is added phase-by-phase as each component lands.)
    if config.signs.enabled then
        require("lvim-git.signs").setup()
    end
    -- Blame self-wires: inline auto-attach (when on by default) + debounced follow, cache invalidation,
    -- repo-change refresh, and the split's cursor `panel_ft` registration.
    if config.blame.enabled then
        require("lvim-git.blame").setup()
    end
    -- The transient engine is a shared FACILITY: register the core verb defs (commit/push/…) so the
    -- status footer verbs + the dispatch popup resolve, and ready the with-editor bridge (its RPC server
    -- + script) so a git-spawned editor opens in this instance.
    if config.transient.enabled then
        require("lvim-git.actions").register()
        require("lvim-git.backend.editor").setup()
    end
    -- The sequencer self-registers its interactive-rebase todo-panel opener with the editor bridge, so a
    -- git-spawned `git-rebase-todo` opens in the pick/reword/edit/squash/fixup/drop panel (its status
    -- section + the `state` read need no wiring — the status surface pulls them on refresh).
    if config.sequencer.enabled then
        require("lvim-git.sequencer").setup()
    end
    -- The conflict component self-wires the generic in-buffer auto-attach: any real file buffer holding
    -- conflict markers gets the choose/nav ops (`]x`/`[x`, `co`/`ct`/`cb`/`cB`/`cn`, `Co`/`Ct`) + the
    -- region washes on read, dropped once the markers clear. The 3-block merge view opens on demand.
    if config.conflict.enabled then
        require("lvim-git.conflict").setup()
    end
    -- Colocated bidirectional git↔jj sync is a BACKEND facility, not a toggleable component: it wires
    -- unconditionally but is INERT unless the current repo is colocated (`.jj` + `.git`). The setup
    -- attaches fs_event watchers on colocated buffers, reconciles after every plugin mutation + on
    -- FocusGained (when `colocated.sync ~= "manual"`), and tears the watchers down on exit.
    require("lvim-git.backend.sync").setup()
end

return M
