-- :Dipher subcommand router. phase 1 wires the runtime view controls (§8.3);
-- diff/pr/log/mergetool subcommands arrive with their frontends (phases 2+)

local View = require("dipher.view")

local M = {}

---@param msg string
---@param level integer|nil
local function notify(msg, level)
    vim.notify("dipher: " .. msg, level or vim.log.levels.INFO)
end

-- :Dipher layout [stacked|split], no arg flips the current view's layout
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

-- :Dipher context <n|full|+|->, sets/adjusts the per-view context lines
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

-- :Dipher panel [revspec], open/toggle the file panel (§8.6) over a change set,
-- without auto-selecting a file (bare `:Dipher` is the open-and-show entry)
---@param arg string|nil
function M.panel(arg)
    require("dipher.git").panel({ rev = (arg ~= "" and arg) or nil })
end

-- :Dipher close: close the panel + diff view (the whole local session)
function M.close()
    require("dipher.git").close()
end

-- :Dipher log [arg]: file history (§8.4). no arg or an arg naming a readable file →
-- single-file history (that file, else the current buffer); any other arg is treated
-- as a rev-range → branch-range history
---@param arg string|nil
function M.log(arg)
    if arg and arg ~= "" and vim.fn.filereadable(vim.fn.fnamemodify(arg, ":p")) == 0 then
        return require("dipher.git").range_history({ range = arg })
    end
    require("dipher.git").history({ path = (arg ~= "" and arg) or nil })
end

-- :Dipher gofile: jump from the diff to the real file at the cursor's mapped line
function M.gofile()
    require("dipher").jump_to_file()
end

---@type table<string, fun(arg: string|nil)>
local SUB = {
    layout = M.layout,
    context = M.context,
    panel = M.panel,
    close = M.close,
    gofile = M.gofile,
    log = M.log,
}

-- route `:Dipher ...`. a recognised subcommand (layout/context/panel) takes its
-- arg; anything else, including no args, is a local-diff rev spec (§8.1), so
-- `:Dipher`, `:Dipher main...`, `:Dipher a..b` open the file panel over that
-- change set and show the first file's diff (DiffviewOpen-style)
---@param fargs string[]
function M.dispatch(fargs)
    local handler = fargs[1] and SUB[fargs[1]]
    if handler then
        return handler(fargs[2])
    end
    require("dipher.git").panel({ rev = fargs, open_first = true })
end

---@type table<string, string[]>
local VALUES = { layout = { "stacked", "split" }, context = { "full", "+", "-" } }

-- completion: subcommands at position 1, then that subcommand's value set
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
