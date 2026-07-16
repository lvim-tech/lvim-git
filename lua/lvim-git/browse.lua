-- lvim-git.browse: open (or yank) a forge web-host URL for the current file+line / a commit / the repo —
-- vim-fugitive's `:GBrowse`. `:LvimGit browse [file|rev]` (+ a visual range → the line range).
--
-- The remote URL (from `git remote get-url <remote>`) is normalized to `https://<host>/<owner>/<repo>` from
-- any of the common forms (scp-like `git@host:owner/repo.git`, `ssh://`, `https://`, `git://`, a `user@`
-- prefix, a `:port`), the HOST is classified into a forge family (github / gitlab / bitbucket / sourcehut,
-- plus a `config.browse.hosts` map for self-hosted instances), and the target URL is built in that forge's
-- blob / commit / line-range shape. The URL is opened with `vim.ui.open` (the OS handler) or yanked to the
-- clipboard (`config.browse.yank` / a `--yank` arg) — never a raw `netrw`/shell-out.
--
-- Forge-specific (git only in v1; a jj repo with a git remote still browses via the git remote). PUBLIC:
-- open / parse_remote / forge_of / build_url (the last three are pure + unit-tested).
--
-- STABILITY CONTRACT — `parse_remote` / `forge_of` / `build_url` are a SUPPORTED public surface
-- (`require("lvim-git.browse")`, additive within a major), so a sibling plugin can classify a repo's forge
-- host + build web URLs without duplicating the remote-parsing (lvim-forge's soft lvim-git seam). They are
-- pure (no side effects, no I/O) and depend only on the passed URL/host/target (+ `config.browse.hosts` for
-- the self-hosted map).
--
---@module "lvim-git.browse"

local config = require("lvim-git.config")
local backend = require("lvim-git.backend")

local M = {}

---@param msg string
---@param level? integer
local function notify(msg, level)
    vim.notify("lvim-git: " .. msg, level or vim.log.levels.INFO)
end

--- The git argv prefix (matching the backend): repo-agnostic globals for clean, concurrent-safe reads.
---@param extra string[]
---@return string[]
local function git_argv(extra)
    local a = { config.git.cmd, "--no-optional-locks", "-c", "color.ui=false" }
    vim.list_extend(a, extra)
    return a
end

--- PUBLIC (stable): parse a remote URL into `{ host, path }` (path = "owner/repo", no `.git`, no
--- leading/trailing slash). Handles scp-like `git@host:owner/repo.git`, `ssh://[user@]host[:port]/owner/repo`,
--- `https://` / `git://`, an embedded `user@`, and a `:port`. Returns nil for an unrecognized URL. Pure.
---@param url string
---@return { host: string, path: string }?
function M.parse_remote(url)
    url = vim.trim(url or "")
    if url == "" then
        return nil
    end
    local host, path
    -- scp-like: [user@]host:owner/repo(.git)
    host, path = url:match("^[%w._%-]+@([%w._%-]+):(.+)$")
    if not host then
        -- scheme://[user@]host[:port]/owner/repo(.git)
        local rest = url:match("^%w+://(.+)$")
        if rest then
            rest = rest:gsub("^[^@/]+@", "") -- strip a user@ credential
            host, path = rest:match("^([^/]+)/(.+)$")
            if host then
                host = host:gsub(":%d+$", "") -- strip a :port
            end
        end
    end
    if not host or not path then
        return nil
    end
    path = path:gsub("%.git$", ""):gsub("^/", ""):gsub("/$", "")
    if path == "" then
        return nil
    end
    return { host = host, path = path }
end

--- PUBLIC (stable): classify a host into a forge family. `config.browse.hosts` (a `{ ["host"] =
--- "github"|… }` map) wins for self-hosted instances; else a substring match; else github (the most common
--- blob shape) as the default. Pure.
---@param host string
---@return "github"|"gitlab"|"bitbucket"|"sourcehut"
function M.forge_of(host)
    local map = config.browse.hosts or {}
    if map[host] then
        return map[host]
    end
    if host:find("github", 1, true) then
        return "github"
    elseif host:find("gitlab", 1, true) then
        return "gitlab"
    elseif host:find("bitbucket", 1, true) then
        return "bitbucket"
    elseif host:find("sr.ht", 1, true) or host:find("sourcehut", 1, true) then
        return "sourcehut"
    end
    return "github"
end

--- PUBLIC (stable): build the forge web URL for a target under `base` (`https://<host>/<owner>/<repo>`).
--- Pure.
---@param forge string
---@param base string
---@param target { kind: "repo"|"commit"|"file", sha?: string, ref?: string, path?: string, lo?: integer, hi?: integer }
---@return string
function M.build_url(forge, base, target)
    if target.kind == "repo" then
        return base
    end
    if target.kind == "commit" then
        local seg = ({
            github = "/commit/",
            gitlab = "/-/commit/",
            bitbucket = "/commits/",
            sourcehut = "/commit/",
        })[forge] or "/commit/"
        return base .. seg .. (target.sha or "")
    end
    -- a file blob at a ref, with an optional line range.
    local ref, path, lo, hi = target.ref or "HEAD", target.path or "", target.lo, target.hi
    if forge == "bitbucket" then
        local u = base .. "/src/" .. ref .. "/" .. path
        if lo then
            u = u .. "#lines-" .. lo .. (hi and hi ~= lo and (":" .. hi) or "")
        end
        return u
    elseif forge == "sourcehut" then
        local u = base .. "/tree/" .. ref .. "/item/" .. path
        if lo then
            u = u .. "#L" .. lo
        end
        return u
    end
    -- github / gitlab (and the default): `/blob/<ref>/<path>` (gitlab `/-/blob/`), `#L<lo>[-L<hi>]`
    -- (gitlab `#L<lo>-<hi>`).
    local blob = forge == "gitlab" and "/-/blob/" or "/blob/"
    local u = base .. blob .. ref .. "/" .. path
    if lo then
        u = u .. "#L" .. lo
        if hi and hi ~= lo then
            u = u .. (forge == "gitlab" and "-" or "-L") .. hi
        end
    end
    return u
end

--- The repo-relative path of a buffer (nil when it is not an on-disk file under `root`).
---@param buf integer
---@param root string
---@return string?
local function rel_path(buf, root)
    local name = vim.api.nvim_buf_get_name(buf)
    if name == "" or name:match("^%w+://") then
        return nil
    end
    local abs = vim.fs.normalize(vim.fn.fnamemodify(name, ":p"))
    local nroot = vim.fs.normalize(root)
    if abs:sub(1, #nroot + 1) ~= nroot .. "/" then
        return nil
    end
    return abs:sub(#nroot + 2)
end

--- Deliver a URL: open it in the OS handler, or (yank mode) copy it to the clipboard + unnamed registers.
---@param url string
---@param yank boolean
local function deliver(url, yank)
    if yank then
        pcall(vim.fn.setreg, "+", url)
        pcall(vim.fn.setreg, '"', url)
        notify("browse (yanked): " .. url)
    else
        local ok = pcall(vim.ui.open, url)
        if ok then
            notify("browse: " .. url)
        else
            pcall(vim.fn.setreg, "+", url)
            notify("browse (no opener; yanked): " .. url, vim.log.levels.WARN)
        end
    end
end

--- Resolve the target + build the URL under `base`/`forge`, then deliver it. Handles the three shapes:
--- an explicit rev arg → commit; an explicit/current file → blob (+ line range); nothing → the repo.
---@param root string
---@param base string
---@param forge string
---@param ctx { arg?: string, buf: integer, lo?: integer, hi?: integer, yank: boolean, commit: boolean }
local function resolve_and_open(root, base, forge, ctx)
    local repo = backend.repo(root)
    local ref = (ctx.commit and repo and repo.head) or (repo and repo.branch) or "HEAD"

    -- An explicit argument: a repo file → blob; else a rev → commit.
    if ctx.arg and ctx.arg ~= "" then
        local as_file = vim.fs.normalize(vim.fn.fnamemodify(root .. "/" .. ctx.arg, ":p"))
        if vim.fn.filereadable(as_file) == 1 then
            deliver(M.build_url(forge, base, { kind = "file", ref = ref, path = ctx.arg }), ctx.yank)
            return
        end
        backend.output(root, git_argv({ "rev-parse", "--verify", "--quiet", ctx.arg .. "^{commit}" }), function(out)
            local sha = out and vim.trim(out)
            if not sha or sha == "" then
                notify("browse: `" .. ctx.arg .. "` is neither a file nor a rev", vim.log.levels.WARN)
                return
            end
            deliver(M.build_url(forge, base, { kind = "commit", sha = sha }), ctx.yank)
        end)
        return
    end

    -- No argument: the current file (with the line/range), else the repo.
    local path = rel_path(ctx.buf, root)
    if not path then
        deliver(M.build_url(forge, base, { kind = "repo" }), ctx.yank)
        return
    end
    deliver(M.build_url(forge, base, { kind = "file", ref = ref, path = path, lo = ctx.lo, hi = ctx.hi }), ctx.yank)
end

--- Browse the current file+line / a rev / the repo on its forge web host.
---@param arg? string   an explicit file path or rev (nil = the current file / repo)
---@param opts? { yank?: boolean, commit?: boolean, line1?: integer, line2?: integer, buf?: integer }
function M.open(arg, opts)
    opts = opts or {}
    if not config.browse.enabled then
        notify("the browse component is disabled (browse.enabled = false)", vim.log.levels.WARN)
        return
    end
    local buf = opts.buf or vim.api.nvim_get_current_buf()
    local root = backend.detect(buf)
    if not root then
        notify("not inside a git repository", vim.log.levels.WARN)
        return
    end
    local repo = backend.repo(root)
    -- Pick the remote: the configured one, else the branch's upstream remote, else "origin".
    local remote = config.browse.remote
    if not remote or remote == "" then
        remote = (repo and repo.upstream and repo.upstream:match("^([^/]+)/")) or "origin"
    end
    -- A visual range narrows to those lines; otherwise the cursor line (a file target only).
    local lo, hi = opts.line1, opts.line2
    if not lo and not arg then
        local ok, pos = pcall(vim.api.nvim_win_get_cursor, 0)
        if ok then
            lo = pos[1]
        end
    end
    if lo and hi and lo > hi then
        lo, hi = hi, lo
    end

    backend.output(root, git_argv({ "remote", "get-url", remote }), function(out, res)
        local url = out and vim.trim(out)
        if not url or url == "" then
            notify(
                "browse: no URL for remote `"
                    .. remote
                    .. "`"
                    .. (res and res.stderr and (" — " .. vim.trim(res.stderr)) or ""),
                vim.log.levels.WARN
            )
            return
        end
        local parsed = M.parse_remote(url)
        if not parsed then
            notify("browse: could not parse the remote URL: " .. url, vim.log.levels.WARN)
            return
        end
        local base = "https://" .. parsed.host .. "/" .. parsed.path
        local forge = M.forge_of(parsed.host)
        resolve_and_open(root, base, forge, {
            arg = arg,
            buf = buf,
            lo = lo,
            hi = hi,
            yank = opts.yank == true or config.browse.yank == true,
            commit = opts.commit == true or config.browse.commit == true,
        })
    end)
end

return M
