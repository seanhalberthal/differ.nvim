-- the merge-tool session (§8.5): lay the 3-way render into windows — ours / theirs on
-- top (plus base under the diff3_mixed layout), the result spine full-width below — drive
-- conflict navigation (]x/[x), and resolve per conflict (take ours/theirs/both/base/none),
-- splicing the chosen slab into the result and stripping the markers. the result column is
-- the real worktree file: :w writes it and auto-stages once no markers remain.
--
-- each input column is a read-only scratch buffer of a whole stage file, so windows use
-- native `number` + native syntax; conflict regions are extmark-only in the dipher.merge
-- namespace (no buffer/text touch on the inputs)

local set_local = require("dipher.util.win").set_local
local bind = require("dipher.util.keymap").bind

local M = {}

local merge_ns = vim.api.nvim_create_namespace("dipher.merge")

---@type table<string, string> -- column side -> region highlight group
local REGION_HL = {
    ours = "dipherMergeOurs",
    base = "dipherMergeBase",
    theirs = "dipherMergeTheirs",
    result = "dipherMergeConflict",
}

---@class dipher.MergeSession
---@field root string
---@field path string
---@field regions dipher.merge.Region[]   -- re-derived from the live result buffer
---@field result_win integer
---@field result_buf integer              -- the real worktree file (editable)
---@field bufs integer[]                  -- the scratch input buffers (deleted on close)
---@field return_tab integer
---@field session_tab integer

---@type dipher.MergeSession|nil
local session = nil

---@param msg string
---@param level integer|nil
local function notify(msg, level)
    vim.notify("dipher: " .. msg, level or vim.log.levels.INFO)
end

-- the active session, or nil. exposed so :Dipher close can route to it
---@return dipher.MergeSession|nil
function M.current()
    return session
end

-- a scratch buffer for one column: the side's content, named + filetyped so native
-- syntax highlights it (these are whole, valid source files, unlike the diff buffers),
-- locked read-only for this slice
---@param side string
---@param path string
---@param lines string[]
---@return integer bufnr
local function make_buffer(side, path, lines)
    local buf = vim.api.nvim_create_buf(false, true)
    local name = ("dipher://merge/%s/%s"):format(side, path)
    if not pcall(vim.api.nvim_buf_set_name, buf, name) then
        pcall(vim.api.nvim_buf_set_name, buf, name .. "#" .. buf)
    end
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].filetype = vim.filetype.match({ filename = path }) or ""
    return buf
end

-- common window dressing: real line numbers, no wrap/fold chrome, scroll-bound so the
-- columns track one another (loosely — the files diverge, the result is the spine)
---@param win integer
local function dress(win)
    set_local(win, "number", true)
    set_local(win, "relativenumber", false)
    set_local(win, "wrap", false)
    set_local(win, "foldcolumn", "0")
    set_local(win, "foldenable", false)
    set_local(win, "signcolumn", "no")
    set_local(win, "cursorline", true)
    set_local(win, "scrollbind", true)
end

-- paint a buffer's conflict regions as full-line backgrounds (extmark-only, §invariant 2)
---@param buf integer
---@param regions dipher.merge.ColumnRegion[]
---@param hl string
local function paint(buf, regions, hl)
    for _, r in ipairs(regions) do
        for row = r.first - 1, r.last - 1 do
            vim.api.nvim_buf_set_extmark(buf, merge_ns, row, 0, {
                end_row = row + 1,
                end_col = 0,
                hl_group = hl,
                hl_eol = true,
                priority = 100,
            })
        end
    end
end

-- jump the result cursor to the next/prev conflict block, wrapping at the ends
---@param dir "next"|"prev"
local function goto_conflict(dir)
    if not (session and vim.api.nvim_win_is_valid(session.result_win)) then
        return
    end
    local cur = vim.api.nvim_win_get_cursor(session.result_win)[1]
    local target
    for _, r in ipairs(session.regions) do
        if dir == "next" and r.result_start > cur then
            target = target or r.result_start
        elseif dir == "prev" and r.result_start < cur then
            target = r.result_start -- keep the last one below the cursor
        end
    end
    if not target and #session.regions > 0 then -- wrap
        target = dir == "next" and session.regions[1].result_start
            or session.regions[#session.regions].result_start
    end
    if target then
        vim.api.nvim_win_set_cursor(session.result_win, { target, 0 })
        vim.api.nvim_win_call(session.result_win, function()
            vim.cmd("normal! zz")
        end)
    end
end

-- the conflict regions of the live result buffer (re-parsed each call, so hand edits and
-- keymap splices stay consistent), plus the buffer's current lines
---@return dipher.merge.Region[], string[]
local function live_regions()
    local lines = vim.api.nvim_buf_get_lines(session.result_buf, 0, -1, false)
    return require("dipher.git.conflict").parse(lines), lines
end

-- re-parse the result buffer and repaint its conflict-block backgrounds, caching the
-- regions on the session for navigation
local function repaint_result()
    local regions = live_regions()
    session.regions = regions
    vim.api.nvim_buf_clear_namespace(session.result_buf, merge_ns, 0, -1)
    local marks = {}
    for _, r in ipairs(regions) do
        marks[#marks + 1] = { index = r.index, first = r.result_start, last = r.result_end }
    end
    paint(session.result_buf, marks, REGION_HL.result)
end

-- the conflict at the cursor, else the first one at or below it (so a take-this from just
-- above a block still resolves it)
---@param regions dipher.merge.Region[]
---@param lnum integer
---@return dipher.merge.Region|nil
local function region_at(regions, lnum)
    for _, r in ipairs(regions) do
        if lnum >= r.result_start and lnum <= r.result_end then
            return r
        end
    end
    for _, r in ipairs(regions) do
        if r.result_start >= lnum then
            return r
        end
    end
    return nil
end

-- resolve the conflict under the cursor by splicing in the chosen slab, then re-derive +
-- repaint and advance to the next remaining conflict (§8.5)
---@param choice "ours"|"theirs"|"both"|"base"|"none"
local function resolve_choice(choice)
    if not session then
        return
    end
    local regions, lines = live_regions()
    if #regions == 0 then
        return notify("no conflicts remain")
    end
    local cur = vim.api.nvim_win_get_cursor(session.result_win)[1]
    local region = region_at(regions, cur)
    if not region then
        return notify("no conflict under the cursor")
    end
    local new_lines = require("dipher.merge.resolve").splice(lines, region, choice)
    if not new_lines then
        return notify("no base version in this conflict", vim.log.levels.WARN)
    end
    local anchor = region.result_start
    vim.bo[session.result_buf].modifiable = true
    vim.api.nvim_buf_set_lines(session.result_buf, 0, -1, false, new_lines)
    repaint_result()
    -- land on the next remaining conflict at or after where this one was
    local target
    for _, r in ipairs(session.regions) do
        if r.result_start >= anchor then
            target = target or r.result_start
        end
    end
    if target then
        vim.api.nvim_win_set_cursor(session.result_win, { target, 0 })
    elseif #session.regions == 0 then
        notify("all conflicts resolved — :w to save and stage")
    end
end

-- end the session: drop the tab + buffers and return to the invoking tab
function M.close()
    if not session then
        return
    end
    local s = session
    session = nil
    for _, buf in ipairs(s.bufs) do
        if vim.api.nvim_buf_is_valid(buf) then
            pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
    end
    if vim.api.nvim_tabpage_is_valid(s.session_tab) then
        if #vim.api.nvim_list_tabpages() == 1 then
            vim.cmd("tabnew")
        end
        pcall(vim.cmd, "tabclose " .. vim.api.nvim_tabpage_get_number(s.session_tab))
    end
    if vim.api.nvim_tabpage_is_valid(s.return_tab) then
        vim.api.nvim_set_current_tabpage(s.return_tab)
    end
end

-- lay out the render in a fresh session tab and wire navigation
---@param root string
---@param relpath string
---@param model dipher.MergeModel
---@param layout "default"|"diff3_mixed"
local function lay_out(root, relpath, model, layout)
    if session then -- re-open over a live session
        M.close()
    end
    local result = require("dipher.render.merge").render(model, { layout = layout })

    local return_tab = vim.api.nvim_get_current_tabpage()
    vim.cmd("tab split")
    local session_tab = vim.api.nvim_get_current_tabpage()
    vim.cmd("silent! only")

    -- result spans the bottom; inputs share the top row left-to-right
    local top = vim.api.nvim_get_current_win()
    vim.cmd("botright split")
    local result_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(top)

    local abs = root .. "/" .. relpath
    local bufs, result_buf = {}, nil -- bufs: the scratch input buffers (deleted on close)
    local input_wins = {}
    for i, col in ipairs(result.columns) do
        if i == result.result_index then
            -- the result is the REAL worktree file: editable, native syntax/undo/LSP, and
            -- :w writes it for real (BufWritePost stages it once it's marker-free)
            vim.api.nvim_win_call(result_win, function()
                vim.cmd.edit(vim.fn.fnameescape(abs))
            end)
            result_buf = vim.api.nvim_win_get_buf(result_win)
            paint(result_buf, col.regions, REGION_HL.result)
        else
            local buf = make_buffer(col.side, relpath, col.lines)
            bufs[#bufs + 1] = buf
            local win
            if #input_wins == 0 then
                win = top
            else
                vim.api.nvim_set_current_win(input_wins[#input_wins])
                vim.cmd("rightbelow vsplit")
                win = vim.api.nvim_get_current_win()
            end
            input_wins[#input_wins + 1] = win
            vim.api.nvim_win_set_buf(win, buf)
            paint(buf, col.regions, REGION_HL[col.side])
        end
    end

    for _, win in ipairs(input_wins) do
        dress(win)
    end
    dress(result_win)

    session = {
        root = root,
        path = relpath,
        regions = model.regions,
        result_win = result_win,
        result_buf = result_buf,
        bufs = bufs,
        return_tab = return_tab,
        session_tab = session_tab,
    }

    -- nav + take-this resolution live on the result buffer (the working surface), from
    -- the configurable merge keymaps (§4.3); falls back to the flat defaults when setup
    -- wasn't called, like the diff view does
    local cfg = require("dipher").get_config()
    local km = cfg.keymaps.merge or require("dipher.config").defaults.keymaps
    local function rb(action, fn, desc)
        bind(result_buf, km[action], fn, desc)
    end
    rb("next_conflict", function()
        goto_conflict("next")
    end, "dipher: next conflict")
    rb("prev_conflict", function()
        goto_conflict("prev")
    end, "dipher: previous conflict")
    rb("choose_ours", function()
        resolve_choice("ours")
    end, "dipher: take ours")
    rb("choose_theirs", function()
        resolve_choice("theirs")
    end, "dipher: take theirs")
    rb("choose_base", function()
        resolve_choice("base")
    end, "dipher: take base")
    rb("choose_all", function()
        resolve_choice("both")
    end, "dipher: take both")
    rb("choose_none", function()
        resolve_choice("none")
    end, "dipher: drop the conflict")
    -- q closes the tool (conventional, no config action)
    vim.keymap.set(
        "n",
        "q",
        M.close,
        { buffer = result_buf, silent = true, desc = "dipher: close" }
    )

    -- :w writes the real file; once no markers remain it auto-stages (git add = resolve),
    -- otherwise it just reports what's left. repaint so a hand-edit's regions stay current
    vim.api.nvim_create_autocmd("BufWritePost", {
        buffer = result_buf,
        group = vim.api.nvim_create_augroup("dipher.merge." .. result_buf, { clear = true }),
        callback = function()
            if not session then
                return
            end
            repaint_result()
            if #session.regions == 0 then
                require("dipher.git").stage(session.root, session.path)
                notify(session.path .. " resolved and staged")
            else
                notify(("%d conflict(s) still unresolved — not staged"):format(#session.regions))
            end
        end,
    })

    -- land in the result on the first conflict, columns scroll-bound to it
    vim.api.nvim_set_current_win(result_win)
    if #model.regions > 0 then
        vim.api.nvim_win_set_cursor(result_win, { model.regions[1].result_start, 0 })
    end
    vim.cmd("normal! zz")
    vim.cmd("syncbind")
end

-- resolve root + the target relpath, then build + open. with no path the current file is
-- used when it's conflicted, else the sole conflicted file, else a picker over them
---@param opts { path?: string, layout?: "default"|"diff3_mixed" }|nil
function M.open(opts)
    opts = opts or {}
    local git = require("dipher.git")
    local layout = opts.layout or "default"

    local file = vim.api.nvim_buf_get_name(0)
    local anchor = (file ~= "" and vim.fn.filereadable(file) == 1) and file or vim.fn.getcwd()
    local root = git.root(anchor)
    if not root then
        return notify("not in a git repository", vim.log.levels.WARN)
    end

    local conflicted = git.conflicted(root)
    if #conflicted == 0 then
        return notify("no conflicted files to resolve")
    end

    local function go(relpath)
        local model, err = require("dipher.merge.model").build(root, relpath, nil)
        if not model then
            return notify(err or "could not open the merge tool", vim.log.levels.WARN)
        end
        lay_out(root, relpath, model, layout)
    end

    if opts.path and opts.path ~= "" then
        local abs = vim.fn.fnamemodify(opts.path, ":p")
        local rel = (abs:sub(1, #root + 1) == root .. "/") and abs:sub(#root + 2) or opts.path
        if not vim.tbl_contains(conflicted, rel) then
            return notify(("%s is not conflicted"):format(opts.path), vim.log.levels.WARN)
        end
        return go(rel)
    end

    -- no explicit path: prefer the current file when it's one of the conflicted
    local rel
    if file ~= "" then
        local resolved = vim.fn.resolve(file)
        if resolved:sub(1, #root + 1) == root .. "/" then
            rel = resolved:sub(#root + 2)
        end
    end
    if rel and vim.tbl_contains(conflicted, rel) then
        return go(rel)
    end
    if #conflicted == 1 then
        return go(conflicted[1])
    end
    vim.ui.select(conflicted, { prompt = "Resolve conflict in:" }, function(choice)
        if choice then
            go(choice)
        end
    end)
end

return M
