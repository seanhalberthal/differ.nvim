-- :Dipher subcommand router. Phase 1 wires the runtime view controls (§8.3);
-- diff/pr/log/mergetool subcommands arrive with their frontends (phases 2+).

local View = require("dipher.view")

local M = {}

---@param msg string
---@param level integer|nil
local function notify(msg, level)
    vim.notify("dipher: " .. msg, level or vim.log.levels.INFO)
end

-- :Dipher layout [stacked|split] — no arg flips the current view's layout.
---@param arg string|nil
function M.layout(arg)
    local view = View.current()
    if not view then
        return notify("no diff view here", vim.log.levels.WARN)
    end
    if arg == nil or arg == "" then
        view:toggle_layout()
    elseif arg == "stacked" or arg == "split" then
        view:set_layout(arg)
    else
        notify("layout: expected 'stacked' or 'split'", vim.log.levels.ERROR)
    end
end

-- :Dipher context <n|full|+|-> — sets/adjusts the per-view context lines.
---@param arg string|nil
function M.context(arg)
    local view = View.current()
    if not view then
        return notify("no diff view here", vim.log.levels.WARN)
    end
    if arg == "full" then
        view:set_context(math.huge)
    elseif arg == "+" then
        view:adjust_context(1)
    elseif arg == "-" then
        view:adjust_context(-1)
    else
        local n = tonumber(arg)
        if not n then
            return notify("context: expected a number, 'full', '+' or '-'", vim.log.levels.ERROR)
        end
        view:set_context(math.max(0, math.floor(n)))
    end
end

---@type table<string, fun(arg: string|nil)>
local SUB = { layout = M.layout, context = M.context }

-- Route `:Dipher ...`. A recognised subcommand (layout/context) takes its arg;
-- anything else — including no args — is a local-diff rev spec (§8.1), so
-- `:Dipher`, `:Dipher main...`, `:Dipher a..b` all open a diff of the current file.
---@param fargs string[]
function M.dispatch(fargs)
    local handler = fargs[1] and SUB[fargs[1]]
    if handler then
        return handler(fargs[2])
    end
    require("dipher.git").open(fargs)
end

---@type table<string, string[]>
local VALUES = { layout = { "stacked", "split" }, context = { "full", "+", "-" } }

-- Completion: subcommands at position 1, then that subcommand's value set.
---@param arglead string
---@param cmdline string
---@return string[]
function M.complete(arglead, cmdline)
    local parts = vim.split(vim.trim(cmdline), "%s+")
    -- parts[1] == "Dipher"; completing the subcommand while on parts[2]
    local completing_sub = #parts < 2 or (#parts == 2 and arglead ~= "")
    local pool = completing_sub and vim.tbl_keys(SUB) or (VALUES[parts[2]] or {})
    return vim.tbl_filter(function(c)
        return c:find(arglead, 1, true) == 1
    end, pool)
end

return M
