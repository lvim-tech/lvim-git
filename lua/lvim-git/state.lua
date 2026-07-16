-- lvim-git.state: RUNTIME-ONLY state (never configuration — config.lua is the live config).
-- Everything here is a projection of the repository or of the current session: cached repo handles
-- keyed by root, the per-session sticky layout token per view, open-panel bookkeeping, and the
-- per-buffer sign/attach records. All of it is re-derivable from the repo (the repo IS the database),
-- so nothing here is persisted (the sole persisted store is the transient saved-defaults json).
--
---@module "lvim-git.state"

local M = {}

--- Cached backend repo handles, keyed by absolute repo root. Populated by backend detection; carries
--- the resolved vcs, caps, colocation flag and the last-fetched Repo model. Never a config value.
---@type table<string, table>
M.repos = {}

--- Root lookup cache: an absolute path (dir or file's dir) → its repo root (or false for "no repo").
--- Avoids walking the filesystem on every attach; invalidated when a watcher sees a repo appear/vanish.
---@type table<string, string|false>
M.root_of = {}

--- Sticky per-session layout token per view name (set when a `:LvimGit <view> <layout>` token is used).
--- Overrides config.layouts for the rest of the session; nil falls back to config.
---@type table<string, "area"|"float"|"bottom"|"tab">
M.layout = {}

--- Open panel handles keyed by a logical view id, so a re-open toggles/focuses instead of stacking.
---@type table<string, table>
M.panels = {}

--- Per-buffer attach records for the signs component: { root, vcs, hunks, status, base_sha, timer }.
--- Keyed by bufnr. Owned by signs.lua; kept here so other reads (Public API) share one source.
---@type table<integer, table>
M.buffers = {}

--- The SESSION defaults for each transient prefix, keyed by "<id>@<root>". Each value is a snapshot
--- `{ switches = { <key> = bool }, options = { <key> = value }, level? = integer }` — the committed
--- args a fresh open of that prefix starts from (Magit's `set`). Persisted for the session only; `save`
--- writes the same shape to the on-disk store. Owned by transient.lua; runtime, never config.
---@type table<string, { switches: table<string, boolean>, options: table<string, any>, level?: integer }>
M.transient = {}

--- The cached in-progress SEQUENCE (rebase / cherry-pick / revert) per repo root, populated by
--- `sequencer.load` from the GIT_DIR marker files and read back render-safe by `sequencer.state`.
--- Owned by sequencer.lua; runtime, never config.
---@type table<string, table>
M.sequencer = {}

--- The cached in-progress BISECT state per repo root, populated by `bisect.load` from the git-dir
--- markers + `rev-list --bisect-vars` and read back render-safe by `bisect.state`. Runtime, never config.
---@type table<string, table>
M.bisect = {}

--- The dedicated-tab WORKSPACE bookkeeping per hosted view (status/diffview/log/history/conflict). Each
--- value is `{ origin_tab = <integer> }` — the tabpage focus returns to when the view's workspace tab is
--- closed. The workspace tab itself is NEVER stored (found by its `t:lvim_git_workspace` marker so a stray
--- `:tabclose` can't dangle a handle); only the origin is remembered. Owned by ui/workspace.lua; runtime.
---@type table<string, { origin_tab?: integer }>
M.workspace = {}

--- The colocated git↔jj SYNC record per repo root, owned by `backend/sync.lua`. Holds the fs_event
--- watcher handles, the debounce timer, the last-reconciled git-ref + jj-op signatures (the
--- change-detection baseline that makes a redundant reconcile a no-op and kills import↔export
--- oscillation), the in-flight `syncing`/`pending` coalescing flags, the last import/export counts,
--- and the `drift` flag (a conflicted bookmark exists). Only present for COLOCATED roots; render-safe
--- fields are read by `sync.sync_state`. Runtime, never config.
---@type table<string, table>
M.sync = {}

--- Reset ALL runtime state (used by tests and a hard `:LvimGit sync` full refresh).
function M.reset()
    M.repos = {}
    M.root_of = {}
    M.layout = {}
    M.panels = {}
    M.buffers = {}
    M.transient = {}
    M.sequencer = {}
    M.bisect = {}
    M.workspace = {}
    M.sync = {}
end

return M
