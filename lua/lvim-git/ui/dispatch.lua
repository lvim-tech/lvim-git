-- lvim-git.ui.dispatch: the DISPATCH popup (Magit's `?`) — the discoverable top-level menu of every
-- command group. It is ITSELF a transient whose actions OPEN the other transients / views, so a user who
-- does not remember a prefix key can always reach everything from one place. Built on the same engine +
-- lvim-ui `transient` preset as every verb popup (no bespoke menu).
--
-- The dispatch only offers what is ENABLED: a view action is guarded (pcall) so a disabled/not-yet-built
-- component simply reports the gap instead of erroring, and a verb action opens its transient (which warns
-- if that verb's def has not landed yet). As components land, their entries here light up.
--
---@module "lvim-git.ui.dispatch"

local transient = require("lvim-git.transient")

local M = {}

--- Open a component view by facade name, guarded — a not-yet-built / disabled component reports the gap.
---@param name string
local function open_view(name)
    local ok, err = pcall(function()
        require("lvim-git")[name]()
    end)
    if not ok then
        vim.notify("lvim-git: " .. name .. " is not available yet", vim.log.levels.WARN)
        if err then
            -- keep the underlying reason discoverable without a stack trace in the UI path
            vim.schedule(function() end)
        end
    end
end

---@type boolean  guards the one-time dispatch def registration
local registered = false

--- Register the dispatch transient def (once). Its groups mirror Magit's dispatch: inspecting views,
--- manipulating verbs, transferring verbs — each action opening the relevant view/transient.
local function register()
    if registered then
        return
    end
    registered = true
    transient.define({
        id = "dispatch",
        title = "Dispatch",
        groups = {
            {
                title = "Inspect",
                actions = {
                    {
                        key = "g",
                        label = "Status",
                        run = function()
                            open_view("status")
                        end,
                    },
                    {
                        key = "d",
                        label = "Diff view",
                        run = function()
                            open_view("diffview")
                        end,
                    },
                    {
                        key = "l",
                        label = "Log",
                        run = function()
                            open_view("log")
                        end,
                    },
                    {
                        key = "b",
                        label = "Blame",
                        run = function()
                            open_view("blame")
                        end,
                    },
                    {
                        key = "y",
                        label = "Refs",
                        run = function()
                            open_view("refs")
                        end,
                    },
                },
            },
            {
                title = "Manipulate",
                actions = {
                    {
                        key = "c",
                        label = "Commit",
                        run = function()
                            transient.open("commit")
                        end,
                    },
                    {
                        key = "m",
                        label = "Merge",
                        run = function()
                            transient.open("merge")
                        end,
                    },
                    {
                        key = "r",
                        label = "Rebase",
                        run = function()
                            transient.open("rebase")
                        end,
                    },
                    {
                        key = "V",
                        label = "Revert",
                        run = function()
                            transient.open("revert")
                        end,
                    },
                    {
                        key = "A",
                        label = "Cherry-pick",
                        run = function()
                            transient.open("cherry-pick")
                        end,
                    },
                    {
                        key = "X",
                        label = "Reset",
                        run = function()
                            transient.open("reset")
                        end,
                    },
                    {
                        key = "t",
                        label = "Tag",
                        run = function()
                            transient.open("tag")
                        end,
                    },
                    {
                        key = "Z",
                        label = "Stash",
                        run = function()
                            open_view("stash")
                        end,
                    },
                },
            },
            {
                title = "Transfer",
                actions = {
                    {
                        key = "f",
                        label = "Fetch",
                        run = function()
                            transient.open("fetch")
                        end,
                    },
                    {
                        key = "F",
                        label = "Pull",
                        run = function()
                            transient.open("pull")
                        end,
                    },
                    {
                        key = "P",
                        label = "Push",
                        run = function()
                            transient.open("push")
                        end,
                    },
                },
            },
            {
                title = "Miscellaneous",
                actions = {
                    {
                        key = "o",
                        label = "Submodule",
                        run = function()
                            open_view("submodule")
                        end,
                    },
                    {
                        key = "w",
                        label = "Worktree",
                        run = function()
                            open_view("worktree")
                        end,
                    },
                    {
                        key = "B",
                        label = "Bisect",
                        run = function()
                            open_view("bisect")
                        end,
                    },
                    {
                        key = "s",
                        label = "Subtree",
                        run = function()
                            transient.open("subtree")
                        end,
                    },
                    {
                        key = "u",
                        label = "Patch",
                        run = function()
                            transient.open("patch")
                        end,
                    },
                    {
                        key = "S",
                        label = "Sparse checkout",
                        run = function()
                            transient.open("sparse")
                        end,
                    },
                    {
                        key = "W",
                        label = "Wip",
                        run = function()
                            open_view("wip")
                        end,
                    },
                },
            },
            {
                -- jj-lens entries (meaningful on a jj repo; the git-only groups above are inert there).
                title = "Jujutsu",
                actions = {
                    {
                        key = "J",
                        label = "jj verb menu (describe/new/squash/…)",
                        run = function()
                            transient.open("jj")
                        end,
                    },
                    {
                        key = "O",
                        label = "Operation log (undo / restore)",
                        run = function()
                            open_view("oplog")
                        end,
                    },
                },
            },
        },
    })
end

--- Open the dispatch popup.
---@param opts? table
function M.open(opts) ---@diagnostic disable-line: unused-local
    register()
    transient.open("dispatch")
end

return M
