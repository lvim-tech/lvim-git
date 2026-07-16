-- lvim-git: :checkhealth lvim-git.
-- Reports what makes a git client silently misbehave: git missing/too old (the whole backend), jj
-- absent (the second lens is simply unavailable — not an error), the ecosystem deps the panels are
-- built on, the current buffer's repo + colocation detection, the enabled-components report, and a
-- Public-API self-check that every documented accessor resolves. Read-only — never mutates state.
--
---@module "lvim-git.health"

local config = require("lvim-git.config")

local M = {}

--- The version of an executable as `major*100 + minor`, or 0 when absent / unparseable.
---@param cmd string
---@param arg string
---@return integer
local function version(cmd, arg)
    if vim.fn.executable(cmd) ~= 1 then
        return 0
    end
    local ok, out = pcall(vim.fn.systemlist, { cmd, arg })
    local maj, min = ((ok and out and out[1]) or ""):match("(%d+)%.(%d+)")
    return (maj and tonumber(maj) * 100 + tonumber(min)) or 0
end

--- The components that carry an `enabled` flag, for the enabled-report.
---@type string[]
local COMPONENTS = {
    "signs",
    "blame",
    "diffview",
    "log",
    "history",
    "status",
    "stash",
    "refs",
    "oplog",
    "conflict",
    "submodule",
    "worktree",
    "bisect",
    "subtree",
    "patch",
    "sparse",
    "wip",
    "browse",
    "run",
    "transient",
}

--- Run the health report.
function M.check()
    local health = vim.health
    health.start("lvim-git")

    if vim.fn.has("nvim-0.10") == 1 then
        health.ok("Neovim >= 0.10 (vim.system, vim.uv, extmark signs)")
    else
        health.error("Neovim >= 0.10 is required")
    end

    -- git — required.
    local gv = version(config.git.cmd, "--version")
    if gv == 0 then
        health.error(("git (`%s`) not found on PATH — the backend cannot run"):format(config.git.cmd))
    elseif gv < 223 then
        health.warn(
            ("git %d.%d found — >= 2.23 recommended (porcelain v2, --absolute-git-dir)"):format(
                math.floor(gv / 100),
                gv % 100
            )
        )
    else
        health.ok(("git %d.%d"):format(math.floor(gv / 100), gv % 100))
    end

    -- jj — optional (the second lens).
    local jv = version(config.jj.cmd, "--version")
    if jv == 0 then
        health.info(
            ("jj (`%s`) not found — the jj lens + colocated sync are unavailable (git still works)"):format(
                config.jj.cmd
            )
        )
    else
        health.ok(("jj %d.%d (jj lens + colocated sync available)"):format(math.floor(jv / 100), jv % 100))
    end

    -- Ecosystem deps.
    local ok_ui = pcall(require, "lvim-ui.surface")
    local ok_utils, colors = pcall(require, "lvim-utils.colors")
    if ok_ui and ok_utils and type(colors.blend) == "function" then
        health.ok("lvim-ui + lvim-utils found (surface chassis + palette)")
    else
        health.error("lvim-ui / lvim-utils not found — the panels cannot render")
    end
    if pcall(require, "lvim-utils.icons") then
        health.ok("lvim-utils.icons found (file devicons in rows)")
    else
        health.info("lvim-utils.icons unavailable — rows show no file icons")
    end

    -- Current-buffer repo detection + colocation.
    local backend = require("lvim-git.backend")
    local root, vcs, colocated = backend.detect(0)
    if root then
        health.ok(("repo detected: %s (lens: %s%s)"):format(root, vcs, colocated and ", colocated git+jj" or ""))
        -- Colocated bidirectional sync: mode + whether watchers are live + any drift (conflicted bookmark).
        if colocated then
            local ss = require("lvim-git.backend.sync").sync_state(root)
            if ss then
                local mode = ss.mode == "auto" and "auto (after every op + watchers/focus)" or "manual (:LvimGit sync)"
                health.ok(("colocated sync: %s%s"):format(mode, ss.watching and ", watchers active" or ""))
                if ss.drift then
                    health.warn(
                        "colocated sync: a bookmark is CONFLICTED — git and jj both moved a ref; resolve in the refs panel"
                    )
                end
            end
        end
        -- Browse: the remote → forge-host mapping for `:LvimGit browse` (`:GBrowse`).
        if config.browse.enabled then
            local remote = (config.browse.remote ~= "" and config.browse.remote) or "origin"
            local url = vim.fn.systemlist({ config.git.cmd, "-C", root, "remote", "get-url", remote })[1]
            if vim.v.shell_error == 0 and url and url ~= "" then
                local browse = require("lvim-git.browse")
                local parsed = browse.parse_remote(url)
                if parsed then
                    health.ok(
                        ("browse: remote `%s` → %s (%s)"):format(remote, parsed.host, browse.forge_of(parsed.host))
                    )
                else
                    health.warn(("browse: could not parse remote `%s` URL: %s"):format(remote, url))
                end
            else
                health.info(("browse: no `%s` remote in this repo (browse falls back to the repo URL)"):format(remote))
            end
        end
    else
        health.info("current buffer is not inside a git/jj repo")
    end

    -- Enabled-components report.
    local enabled = {}
    for _, name in ipairs(COMPONENTS) do
        local c = config[name]
        if type(c) == "table" and c.enabled then
            enabled[#enabled + 1] = name
        end
    end
    health.info("enabled components: " .. (next(enabled) and table.concat(enabled, ", ") or "none"))

    -- Public-API self-check: the facade accessors resolve.
    local api = require("lvim-git")
    local missing = {}
    for _, fn in ipairs({
        "repo",
        "head",
        "buf_status",
        "line_hunk",
        "line_hl",
        "is_attached",
        "status",
        "diffview",
        "log",
        "is_colocated",
        "sync_state",
        "sync",
    }) do
        if type(api[fn]) ~= "function" then
            missing[#missing + 1] = fn
        end
    end
    if #missing == 0 then
        health.ok("public API surface present (facade accessors resolve)")
    else
        health.error("public API missing: " .. table.concat(missing, ", "))
    end

    -- Config sanity.
    if not vim.tbl_contains({ "auto", "git", "jj" }, config.vcs) then
        health.error('vcs must be "auto", "git" or "jj"')
    elseif not vim.tbl_contains({ "float", "cursor", "bottom" }, config.transient.layout) then
        health.error('transient.layout must be "float", "cursor" or "bottom"')
    else
        health.ok("config valid")
    end
end

return M
