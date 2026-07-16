-- lvim-git.commands: the `:LvimGit` command layer — parsing, completion, the layout token, and
-- dispatch to the (lazily-bootstrapped) component for each subcommand.
--
-- Grammar (works for EVERY view): `:LvimGit <subcommand> <area|float|bottom|tab> [args]`. The layout
-- token is recognised ANYWHERE in the args, so `:LvimGit diffview area` opens just the diffview in the
-- area layout and `:LvimGit log tab` opens the log fullscreen. All four layouts are first-class for
-- every subcommand; a used token is sticky for the session (kept in state.layout). Each subcommand
-- bootstraps ONLY its own component — nothing else initializes.
--
---@module "lvim-git.commands"

local state = require("lvim-git.state")

local M = {}

---@type table<string, true>  the recognised layout tokens (accepted anywhere in the args)
local LAYOUTS = { area = true, float = true, bottom = true, tab = true }

---@type table<string, true>  a one-off lens override token (colocated repos)
local LENS = { git = true, jj = true }

-- Subcommands (also the completion source). `diff` is an alias of `diffview`; `status` is the default.
---@type string[]
local SUBCOMMANDS = {
    "status",
    "diffview",
    "diff",
    "log",
    "history",
    "blame",
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
    "dispatch",
    "commit",
    "push",
    "pull",
    "fetch",
    "rebase",
    "merge",
    "cherry-pick",
    "revert",
    "reset",
    "tag",
    "jj",
    "describe",
    "new",
    "squash",
    "abandon",
    "edit",
    "bookmark",
    "workspace",
    "undo",
    "sync",
    "run",
    "browse",
    "toggle_signs",
    "toggle_blame",
}

---@class LvimGitCmd
---@field sub     string    the subcommand (defaults to "status")
---@field layout? string    an explicit layout token (area|float|bottom|tab)
---@field lens?   string    a one-off lens override (git|jj) for a colocated repo
---@field args    string[]  the remaining positional args
---@field range?  integer   the command range count (>0 = a visual/explicit range was given)
---@field line1?  integer   the range start line
---@field line2?  integer   the range end line
---@field bang?   boolean   `:LvimGit!` — the terminal variant for `run` (a TTY-interactive command)

--- Parse fargs into an LvimGitCmd: pull the layout + lens tokens out from anywhere, leave the rest as
--- positional args. The first non-token word is the subcommand.
---@param fargs string[]
---@return LvimGitCmd
local function parse(fargs)
    local out = { sub = nil, args = {} }
    for _, w in ipairs(fargs) do
        if LAYOUTS[w] and not out.layout then
            out.layout = w
        elseif LENS[w] and not out.lens and out.sub then
            -- a lens token only after the subcommand (so `:LvimGit git` alone still = status default)
            out.lens = w
        elseif not out.sub then
            out.sub = w
        else
            out.args[#out.args + 1] = w
        end
    end
    out.sub = out.sub or "status"
    if out.sub == "diff" then
        out.sub = "diffview"
    end
    return out
end

--- Resolve the layout for a view: an explicit token (also made sticky) → the session sticky → config.
---@param view string
---@param token? string
---@return string
function M.layout_for(view, token)
    if token then
        state.layout[view] = token
    end
    if state.layout[view] then
        return state.layout[view]
    end
    local config = require("lvim-git.config")
    return (config.layouts or {})[view] or "float"
end

--- The dispatch table: subcommand → handler. Each handler lazily requires its component. Verb
--- subcommands open their transient (built in later phases). Layout/lens/args are forwarded via opts.
---@type table<string, fun(p: table)>
local HANDLERS = {}

--- Register the UI-opener handlers that map 1:1 to a component `.open(opts)`.
---@param name string          the subcommand
---@param modname string       the component module
---@param view? string         the view name for layout resolution (defaults to name)
local function opener(name, modname, view)
    view = view or name
    HANDLERS[name] = function(p)
        local opts = { layout = M.layout_for(view, p.layout), lens = p.lens, args = p.args }
        require(modname).open(opts)
    end
end

opener("status", "lvim-git.ui.status")
opener("diffview", "lvim-git.ui.diff")
opener("log", "lvim-git.ui.log")
opener("stash", "lvim-git.ui.stash")
opener("refs", "lvim-git.ui.refs")
opener("oplog", "lvim-git.ui.oplog")
opener("submodule", "lvim-git.ui.submodule")
opener("worktree", "lvim-git.ui.worktree")
opener("dispatch", "lvim-git.ui.dispatch")

--- File history — forwards the file path AND, for a VISUAL range invocation (`:'<,'>LvimGit history`),
--- the selected line range so `ui/history` opens a `git log -L<lo>,<hi>:<file>` line history.
HANDLERS.history = function(p)
    local opts = { layout = M.layout_for("history", p.layout), lens = p.lens, args = p.args }
    if p.range and p.range > 0 then
        opts.line1, opts.line2 = p.line1, p.line2
    end
    require("lvim-git.ui.history").open(opts)
end
--- Blame — the native split. A VISUAL range invocation (`:'<,'>LvimGit blame`) scopes the initial blame
--- to that line range (`-L`), mirroring `history`.
HANDLERS.blame = function(p)
    local opts = { layout = M.layout_for("blame", p.layout), lens = p.lens, args = p.args }
    if p.range and p.range > 0 then
        opts.line1, opts.line2 = p.line1, p.line2
    end
    require("lvim-git.blame").open(opts)
end
HANDLERS.conflict = function(p)
    require("lvim-git.conflict").open({ layout = M.layout_for("conflict", p.layout), lens = p.lens, args = p.args })
end
HANDLERS.bisect = function(p)
    require("lvim-git.bisect").open({ layout = M.layout_for("bisect", p.layout) })
end
--- Work-in-progress refs mode (opt-in) — its own small transient (save / log / restore).
HANDLERS.wip = function(p)
    require("lvim-git.wip").open({ layout = M.layout_for("wip", p.layout), lens = p.lens })
end
--- Subtree / patch / sparse — transient-only Miscellaneous verbs (like commit/push below).
for _, verb in ipairs({ "subtree", "patch", "sparse" }) do
    HANDLERS[verb] = function(p)
        require("lvim-git.actions").register()
        require("lvim-git.transient").open(verb, { lens = p.lens, args = p.args })
    end
end

--- The verb transients (commit/push/…) — each opens its transient definition from actions.lua.
for _, verb in ipairs({
    "commit",
    "push",
    "pull",
    "fetch",
    "rebase",
    "merge",
    "cherry-pick",
    "revert",
    "reset",
    "tag",
}) do
    HANDLERS[verb] = function(p)
        require("lvim-git.transient").open(verb, { lens = p.lens, args = p.args })
    end
end

--- The jj verb menu (`:LvimGit jj`) — the jj-lens analogue of the git verb transients.
HANDLERS.jj = function(p)
    require("lvim-git.actions").register()
    require("lvim-git.transient").open("jj", { lens = p.lens or "jj", args = p.args })
end
--- Individual jj verbs (`:LvimGit describe|new|squash|abandon|edit|bookmark|undo`) — direct helpers.
--- `workspace` is a jj-lens alias for the worktree panel (open question 13: one command for both).
for _, verb in ipairs({ "describe", "new", "squash", "abandon", "edit", "undo" }) do
    HANDLERS[verb] = function(p)
        local a = require("lvim-git.actions")
        a.register()
        local root, vcs = require("lvim-git.backend").detect(vim.api.nvim_get_current_buf())
        if not root then
            vim.notify("lvim-git: not inside a repository", vim.log.levels.WARN)
            return
        end
        vcs = p.lens or vcs
        local fn = {
            describe = a.jj_describe,
            new = a.jj_new,
            squash = a.jj_squash,
            abandon = a.jj_abandon,
            edit = a.jj_edit,
            undo = a.op_undo,
        }
        fn[verb](root, vcs)
    end
end
HANDLERS.bookmark = function(p)
    local a = require("lvim-git.actions")
    a.register()
    local root, vcs = require("lvim-git.backend").detect(vim.api.nvim_get_current_buf())
    if root then
        a.jj_bookmark_create(root, p.lens or vcs)
    end
end
HANDLERS.workspace = function(p)
    require("lvim-git.ui.worktree").open({ layout = M.layout_for("worktree", p.layout), lens = p.lens or "jj" })
end

--- Force a colocated git↔jj reconcile (`:LvimGit sync [import|export]`); reports what moved.
HANDLERS.sync = function(p)
    local dir = (p.args or {})[1]
    dir = (dir == "import" or dir == "export") and dir or nil
    require("lvim-git.backend.sync").sync(nil, true, dir)
end
--- Raw passthrough (`:LvimGit run <git args>`): stream into the output panel, or (`:LvimGit! run …` / a
--- leading `term`/`!` token) run it in a real terminal.
HANDLERS.run = function(p)
    M.raw(vim.deepcopy(p.args or {}), { bang = p.bang, lens = p.lens })
end
--- Browse (`:LvimGit browse [file|rev]`): the forge web URL for the current file+line / a commit / the repo.
--- `--yank` copies instead of opening; `--commit`/`--permalink` pins the HEAD sha.
HANDLERS.browse = function(p)
    local yank, commit, rest = false, false, {}
    for _, a in ipairs(p.args or {}) do
        if a == "--yank" then
            yank = true
        elseif a == "--commit" or a == "--permalink" then
            commit = true
        else
            rest[#rest + 1] = a
        end
    end
    local opts = { yank = yank, commit = commit }
    if p.range and p.range > 0 then
        opts.line1, opts.line2 = p.line1, p.line2
    end
    M.browse(rest[1], opts)
end
HANDLERS.toggle_signs = function()
    require("lvim-git.signs").toggle()
end
HANDLERS.toggle_blame = function()
    require("lvim-git.blame").toggle_inline()
end

--- Run a subcommand programmatically (also the `M.open` facade path).
---@param sub string
---@param opts? table
function M.run(sub, opts)
    opts = opts or {}
    local h = HANDLERS[sub == "diff" and "diffview" or sub]
    if not h then
        vim.notify("lvim-git: unknown subcommand " .. tostring(sub), vim.log.levels.ERROR)
        return
    end
    h({ sub = sub, layout = opts.layout, lens = opts.lens, args = opts.args or {} })
end

--- Dispatch a parsed `:LvimGit` invocation.
---@param p LvimGitCmd
local function dispatch(p)
    local h = HANDLERS[p.sub]
    if not h then
        vim.notify("lvim-git: unknown subcommand " .. tostring(p.sub), vim.log.levels.ERROR)
        return
    end
    local ok, err = pcall(h, p)
    if not ok then
        vim.notify("lvim-git: " .. tostring(err), vim.log.levels.ERROR)
    end
end

--- `:LvimGit` completion: subcommands, then the layout + lens tokens.
---@param arglead string
---@param cmdline string
---@return string[]
local function complete(arglead, cmdline)
    local candidates = {}
    -- Offer subcommands until one is chosen, then offer the layout/lens tokens.
    local has_sub = false
    for word in cmdline:gmatch("%S+") do
        if word ~= "LvimGit" and SUBCOMMANDS[1] and vim.tbl_contains(SUBCOMMANDS, word) then
            has_sub = true
        end
    end
    if not has_sub then
        vim.list_extend(candidates, SUBCOMMANDS)
    else
        candidates = { "area", "float", "bottom", "tab", "git", "jj" }
    end
    local out = {}
    for _, c in ipairs(candidates) do
        if c:find(arglead, 1, true) == 1 then
            out[#out + 1] = c
        end
    end
    return out
end

--- Raw passthrough `:LvimGit run <git args>` (fugitive's `:Git <cmd>`): run an arbitrary command under the
--- repo and STREAM its stdout+stderr into the output panel; on completion refresh the repo. An editor-
--- spawning command (a bare `commit`, `rebase -i`, `tag -a`) rides the with-editor bridge from within the
--- run. A TTY-interactive command (a pager, `add -p`) uses the terminal variant: `opts.bang` (`:LvimGit!`)
--- or a leading `term`/`!` token opens a real `:terminal` instead.
---@param args string[]
---@param opts? { bang?: boolean, lens?: string }
function M.raw(args, opts)
    opts = opts or {}
    local config = require("lvim-git.config")
    if not config.run.enabled then
        vim.notify("lvim-git: `run` is disabled (run.enabled = false)", vim.log.levels.WARN)
        return
    end
    args = args or {}
    local term = opts.bang == true
    if args[1] == "!" or args[1] == "term" then
        term = true
        table.remove(args, 1)
    end
    if #args == 0 then
        vim.notify("lvim-git: `run` needs a command, e.g. `:LvimGit run status`", vim.log.levels.WARN)
        return
    end
    local backend = require("lvim-git.backend")
    local root, vcs = backend.detect(vim.api.nvim_get_current_buf())
    if not root then
        vim.notify("lvim-git: not inside a git repository", vim.log.levels.WARN)
        return
    end
    local lens = opts.lens or vcs
    local exe = lens == "jj" and config.jj.cmd or config.git.cmd
    local argv = { exe }
    vim.list_extend(argv, args)
    local title = exe .. " " .. table.concat(args, " ")
    if term then
        -- A REAL terminal for TTY-interactive commands (pagers, `add -p`) — fugitive's `:Git!`.
        vim.cmd("botright new")
        local ok = pcall(vim.fn.jobstart, argv, { term = true, cwd = root })
        if not ok then
            vim.notify("lvim-git: could not start the terminal", vim.log.levels.ERROR)
            pcall(vim.cmd, "bwipeout!")
            return
        end
        vim.cmd("startinsert")
        return
    end
    require("lvim-git.ui.output").run(root, title, argv)
end

--- Browse a file/rev/the repo on its forge web host (fugitive's `:GBrowse`) — delegates to `lvim-git.browse`.
---@param arg? string
---@param opts? { yank?: boolean, commit?: boolean, line1?: integer, line2?: integer, buf?: integer }
function M.browse(arg, opts)
    require("lvim-git.browse").open(arg, opts)
end

--- Register the `:LvimGit` user command (once).
function M.setup()
    vim.api.nvim_create_user_command("LvimGit", function(cmd)
        local p = parse(cmd.fargs)
        -- Carry a VISUAL range (`:'<,'>LvimGit history`/`browse`) + the bang (`:LvimGit! run …` = terminal).
        p.range, p.line1, p.line2 = cmd.range, cmd.line1, cmd.line2
        p.bang = cmd.bang
        dispatch(p)
    end, {
        nargs = "*",
        range = true,
        bang = true,
        complete = complete,
        desc = "lvim-git: status | diffview | log | blame | commit | push | run | browse | … (+ area|float|bottom|tab)",
    })
end

return M
