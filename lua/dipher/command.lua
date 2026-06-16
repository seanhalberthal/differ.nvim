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

---@type table<string, true>
local PANEL_POSITIONS = { left = true, right = true, top = true, bottom = true }

-- :Dipher panel [left|right|top|bottom|revspec], open the file panel (§8.6) over a
-- change set and show the first file's diff (the diff window is the session anchor,
-- so there's never a panel without one). on a live session it hides/shows the sidebar
-- in place; `:Dipher close` ends the session. a position word repositions a live panel,
-- reveals a hidden sidebar there, or opens one at that edge when no session exists
-- (height/width carry over from config); any other arg is a rev spec
---@param arg string|nil
function M.panel(arg)
    if arg and PANEL_POSITIONS[arg] then
        local panel = require("dipher.panel").current()
        if panel then
            panel:set_position(arg) -- records position; repositions live if shown
            if not panel:is_open() then
                panel:show() -- hidden sidebar: reveal it at the new position
            end
            return
        end
        return require("dipher.git").panel({ position = arg, open_first = true })
    end
    require("dipher.git").panel({ rev = (arg ~= "" and arg) or nil, open_first = true })
end

-- :Dipher pr [number|owner/repo#number|list [filter]] (§8.2). no arg or a bare
-- number opens the picker / that PR; `owner/repo#number` targets a specific repo
-- (forks, §1); `list [filter]` opens the picker with a filter; `resolve` toggles the
-- review thread under the cursor (§6.4). the review/submit/… sub-verbs arrive later
---@param verb string|nil
---@param arg string|nil
function M.pr(verb, arg)
    local pr = require("dipher.pr")
    if verb == nil or verb == "" or tonumber(verb) then
        return pr.open({ number = verb and tonumber(verb) or nil })
    end
    -- explicit override: owner/repo#number targets a specific repo (forks, §1)
    local owner, repo, num = verb:match("^([^/]+)/([^#]+)#(%d+)$")
    if owner then
        return pr.open({ coords = { owner = owner, repo = repo }, number = tonumber(num) })
    end
    local dispatch = {
        list = function()
            pr.open({ filter = arg or "open" })
        end,
        -- cursor-context: resolve/unresolve the thread under the cursor in the diff (§6.4)
        resolve = function()
            pr.resolve()
        end,
    }
    local h = dispatch[verb]
    if h then
        return h()
    end
    notify("unknown `pr` subcommand: " .. verb, vim.log.levels.WARN)
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

-- :Dipher edit: edit-in-review (§8.1) — open the real worktree file in a transient
-- editable window at the cursor's mapped line, keeping the diff session live
function M.edit()
    require("dipher").edit_file()
end

-- :Dipher sidecar [stop]: smoke-check the Go sidecar (start + hello round trip,
-- report the binary version), or stop the supervised process
---@param arg string|nil
function M.sidecar(arg)
    local sidecar = require("dipher.sidecar")
    if arg == "stop" then
        sidecar.stop()
        return notify("sidecar stopped")
    end
    sidecar.ping(function(err, info)
        if err then
            return notify("sidecar: " .. (err.message or err.code), vim.log.levels.ERROR)
        end
        notify(
            ("sidecar ok — binary %s, protocol %d"):format(info.binary or "?", info.protocol or 0)
        )
    end)
end

-- :Dipher cache clear: flush the sidecar's in-process caches (§7.5)
---@param arg string|nil
function M.cache(arg)
    if arg ~= "clear" then
        return notify("cache: expected 'clear'", vim.log.levels.ERROR)
    end
    require("dipher.sidecar").request("cache_clear", nil, function(err)
        if err then
            return notify("cache clear: " .. (err.message or err.code), vim.log.levels.ERROR)
        end
        notify("sidecar cache cleared")
    end)
end

---@type table<string, fun(arg: string|nil)>
local SUB = {
    layout = M.layout,
    context = M.context,
    panel = M.panel,
    pr = M.pr,
    close = M.close,
    gofile = M.gofile,
    edit = M.edit,
    log = M.log,
    sidecar = M.sidecar,
    cache = M.cache,
}

-- route `:Dipher ...`. a recognised subcommand (layout/context/panel) takes its
-- arg; anything else, including no args, is a local-diff rev spec (§8.1), so
-- `:Dipher`, `:Dipher main...`, `:Dipher a..b` open the file panel over that
-- change set and show the first file's diff (DiffviewOpen-style)
---@param fargs string[]
function M.dispatch(fargs)
    local handler = fargs[1] and SUB[fargs[1]]
    if handler then
        return handler(fargs[2], fargs[3])
    end
    require("dipher.git").panel({ rev = fargs, open_first = true })
end

---@type table<string, string[]>
local VALUES = {
    layout = { "stacked", "split" },
    context = { "full", "+", "-" },
    panel = { "left", "right", "top", "bottom" },
    -- later slices implement these sub-verbs; listing now keeps completion stable
    pr = {
        "list",
        "resolve",
        "review",
        "submit",
        "discard",
        "resume",
        "checks",
        "merge",
        "checkout",
        "ready",
        "draft",
        "close",
        "reopen",
        "browser",
        "url",
    },
    sidecar = { "stop" },
    cache = { "clear" },
}

-- completion: subcommands at position 1, then that subcommand's value set
---@param arglead string
---@param cmdline string
---@return string[]
function M.complete(arglead, cmdline)
    local parts = vim.split(vim.trim(cmdline), "%s+")
    -- parts[1] == "Dipher"; completing the subcommand while on parts[2]
    local pool
    if #parts < 2 or (#parts == 2 and arglead ~= "") then
        pool = vim.tbl_keys(SUB)
    else
        pool = VALUES[parts[2]] or {}
    end
    return vim.tbl_filter(function(c)
        return c:find(arglead, 1, true) == 1
    end, pool)
end

return M
