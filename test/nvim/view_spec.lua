-- runs under headless nvim: drives the View through real windows/buffers and
-- asserts content, the diff highlight extmarks, and split scroll-binding
local diff = require("dipher.model.diff")
local View = require("dipher.view")

-- nvim_create_namespace is idempotent by name, so this is the same ns the View uses
local ns = vim.api.nvim_create_namespace("dipher")

local function model(old, new)
    return diff.build({ path = "x", old_rev = "A", new_rev = "B", old_text = old, new_text = new })
end

-- collect line fills per 0-based row and word hl_group spans from the namespace.
-- the line bg is a char-level full-line fill (hl_eol) rather than a line_hl_group,
-- so it wins/loses against the word spans by priority; classify it by hl_eol
local function extmarks(bufnr)
    local line_hl, word = {}, {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })) do
        local row, d = m[2], m[4]
        if d.hl_eol then
            line_hl[row] = d.hl_group
        elseif d.hl_group then
            word[#word + 1] = { row = row, col = m[3], end_col = d.end_col, hl = d.hl_group }
        end
    end
    return line_hl, word
end

describe("view stacked", function()
    it("opens one window with rendered lines and line-level highlights", function()
        local v = View.new(model("a\nb\nc\n", "a\nB\nc\n"), {
            layout = "stacked",
            context = math.huge,
            deep_diff = { enabled = true },
        })
        v:open()
        assert.are.equal(1, #v.columns)
        local buf = v.columns[1].bufnr
        assert.are.same({ "a", "b", "B", "c" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))

        local win = v.columns[1].winid
        assert.is_false(vim.wo[win].number)
        assert.is_true(vim.wo[win].wrap) -- wrap defaults on

        local line_hl = extmarks(buf)
        assert.are.equal("dipherLineDelete", line_hl[1]) -- "b" (old)
        assert.are.equal("dipherLineAdd", line_hl[2]) -- "B" (new)
        assert.is_nil(line_hl[0]) -- "a" (context) unhighlighted
        v:close()
    end)

    it("honours wrap = false, disabling soft-wrap in the diff window", function()
        local v = View.new(model("a\nb\n", "a\nB\n"), {
            layout = "stacked",
            context = math.huge,
            wrap = false,
            deep_diff = { enabled = true },
        })
        v:open()
        assert.is_false(vim.wo[v.columns[1].winid].wrap)
        v:close()
    end)

    it("paints word-level spans for paired changed lines", function()
        local v = View.new(model("local foo = 1\n", "local bar = 1\n"), {
            layout = "stacked",
            context = math.huge,
            deep_diff = { enabled = true },
        })
        v:open()
        local _, word = extmarks(v.columns[1].bufnr)
        -- one old-side and one new-side span, both over cols [6,9)
        table.sort(word, function(x, y)
            return x.hl < y.hl
        end)
        assert.are.equal(2, #word)
        assert.are.equal("dipherWordAdd", word[1].hl)
        assert.are.equal(6, word[1].col)
        assert.are.equal(9, word[1].end_col)
        assert.are.equal("dipherWordDelete", word[2].hl)
        v:close()
    end)
end)

describe("view window options", function()
    it("sets gutter/fold options window-locally, not on the global default", function()
        local g_statuscolumn, g_number, g_wrap = vim.go.statuscolumn, vim.go.number, vim.go.wrap
        local v = View.new(model("a\nb\n", "a\nB\n"), {
            layout = "stacked",
            context = math.huge,
            deep_diff = { enabled = true },
        })
        v:open()
        local win = v.columns[1].winid
        -- the window carries dipher's dressing...
        assert.is_truthy(vim.wo[win].statuscolumn:find("dipher", 1, true))
        assert.is_false(vim.wo[win].number)
        -- ...but the global defaults are untouched, so other windows are unaffected
        assert.are.equal(g_statuscolumn, vim.go.statuscolumn)
        assert.are.equal(g_number, vim.go.number)
        assert.are.equal(g_wrap, vim.go.wrap)
        v:close()
    end)
end)

describe("view split", function()
    it("opens a scroll-bound pair with per-side highlights", function()
        local v = View.new(model("a\nM\nb\n", "a\nX\nb\n"), {
            layout = "split",
            context = math.huge,
            deep_diff = { enabled = true },
        })
        v:open()
        assert.are.equal(2, #v.columns)
        local left, right = v.columns[1], v.columns[2]

        assert.are.same({ "a", "M", "b" }, vim.api.nvim_buf_get_lines(left.bufnr, 0, -1, false))
        assert.are.same({ "a", "X", "b" }, vim.api.nvim_buf_get_lines(right.bufnr, 0, -1, false))

        assert.is_true(vim.wo[left.winid].scrollbind)
        assert.is_true(vim.wo[right.winid].scrollbind)

        local left_hl = extmarks(left.bufnr)
        local right_hl = extmarks(right.bufnr)
        assert.are.equal("dipherLineDelete", left_hl[1]) -- old "M" on the left
        assert.are.equal("dipherLineAdd", right_hl[1]) -- new "X" on the right
        v:close()
    end)
end)

describe("view hunk navigation", function()
    -- two changes far apart so there are two distinct hunks to jump between
    local function two_hunk_view()
        return View.new(model("1\n2\n3\n4\n5\n6\n7\n8\n9\n", "1\nX\n3\n4\n5\n6\n7\nY\n9\n"), {
            layout = "stacked",
            context = math.huge,
            deep_diff = { enabled = true },
        })
    end

    it("moves the cursor between hunks via goto_hunk", function()
        local v = two_hunk_view()
        v:open()
        local win = v.columns[1].winid
        vim.api.nvim_win_set_cursor(win, { 1, 0 })
        v:goto_hunk("next")
        assert.are.equal(2, vim.api.nvim_win_get_cursor(win)[1]) -- first hunk
        v:goto_hunk("next")
        assert.are.equal(9, vim.api.nvim_win_get_cursor(win)[1]) -- second hunk
        v:goto_hunk("next")
        assert.are.equal(9, vim.api.nvim_win_get_cursor(win)[1]) -- last hunk, no panel to step into
        v:goto_hunk("prev")
        assert.are.equal(2, vim.api.nvim_win_get_cursor(win)[1])
        v:close()
    end)

    it("the diff winbar reports the file and the hunk under the cursor", function()
        local v = two_hunk_view()
        v:open()
        local win = v.columns[1].winid
        local winbar = require("dipher.ui.winbar")
        vim.g.statusline_winid = win
        vim.api.nvim_win_set_cursor(win, { 2, 0 }) -- first hunk
        local s = winbar.diff()
        assert.is_truthy(s:find("x", 1, true)) -- the file basename
        assert.is_truthy(s:find("hunk 1/2", 1, true))
        vim.api.nvim_win_set_cursor(win, { 9, 0 }) -- second hunk
        assert.is_truthy(winbar.diff():find("hunk 2/2", 1, true))
        vim.g.statusline_winid = nil
        v:close()
    end)

    it("binds ]c and [c as buffer-local motions", function()
        local v = two_hunk_view()
        v:open()
        local buf = v.columns[1].bufnr
        local lhs = {}
        for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
            lhs[m.lhs] = true
        end
        assert.is_true(lhs["]c"])
        assert.is_true(lhs["[c"])
        v:close()
    end)
end)

describe("view in-view keymaps", function()
    local function maps(v)
        local lhs = {}
        for _, m in ipairs(vim.api.nvim_buf_get_keymap(v.columns[1].bufnr, "n")) do
            lhs[m.lhs] = true
        end
        return lhs
    end

    it("binds ]f/[f and (by default) f/b in the diff window", function()
        local v = View.new(model("a\nb\n", "a\nB\n"), {
            layout = "stacked",
            context = math.huge,
            deep_diff = { enabled = true },
        })
        v:open()
        local lhs = maps(v)
        assert.is_true(lhs["]f"])
        assert.is_true(lhs["[f"])
        assert.is_true(lhs["f"])
        assert.is_true(lhs["b"])
        v:close()
    end)

    it("omits f/b when scroll is disabled, keeping ]f/[f", function()
        local v = View.new(model("a\nb\n", "a\nB\n"), {
            layout = "stacked",
            context = math.huge,
            deep_diff = { enabled = true },
            keymaps = { scroll_down = false, scroll_up = false },
        })
        v:open()
        local lhs = maps(v)
        assert.is_true(lhs["]f"])
        assert.is_nil(lhs["f"])
        assert.is_nil(lhs["b"])
        v:close()
    end)

    it("remaps an action to a custom lhs, dropping the default", function()
        local v = View.new(model("a\nb\n", "a\nB\n"), {
            layout = "stacked",
            context = math.huge,
            deep_diff = { enabled = true },
            keymaps = require("dipher.config").resolve_keymaps({ next_hunk = "gh" }).diff,
        })
        v:open()
        local lhs = maps(v)
        assert.is_true(lhs["gh"]) -- the custom lhs is bound
        assert.is_nil(lhs["]c"]) -- the default is gone
        v:close()
    end)
end)

describe("view layout toggle", function()
    it("drops the surplus column when going split -> stacked", function()
        local v = View.new(model("a\nM\nb\n", "a\nX\nb\n"), {
            layout = "split",
            context = math.huge,
            deep_diff = { enabled = true },
        })
        v:open()
        local stale = v.columns[2].bufnr
        v:rerender({ layout = "stacked", context = math.huge, deep_diff = { enabled = true } })
        assert.are.equal(1, #v.columns)
        assert.is_false(vim.api.nvim_buf_is_valid(stale))
        v:close()
    end)

    it("relays windows when toggling stacked <-> split", function()
        vim.cmd("silent! only")
        local v = View.new(model("a\nM\nb\n", "a\nX\nb\n"), {
            layout = "stacked",
            context = math.huge,
            deep_diff = { enabled = true },
        })
        v:open()
        assert.are.equal(1, #v.columns)

        v:toggle_layout() -- -> split
        assert.are.equal(2, #v.columns)
        assert.are.equal("old", v.columns[1].side)
        assert.are.equal("new", v.columns[2].side)
        assert.is_true(vim.api.nvim_win_is_valid(v.columns[2].winid))
        assert.is_true(vim.wo[v.columns[1].winid].scrollbind)

        v:toggle_layout() -- -> stacked
        assert.are.equal(1, #v.columns)
        assert.are.equal("unified", v.columns[1].side)
        assert.is_false(vim.wo[v.columns[1].winid].scrollbind)
        v:close()
    end)
end)

describe("view context controls", function()
    local function fold_count(view)
        return #(view.columns[1].folds or {})
    end

    -- two hunks with a 5-line gap between them
    local function gap_view()
        return View.new(model("1\n2\n3\n4\n5\n6\n7\n8\n9\n", "1\nX\n3\n4\n5\n6\n7\nY\n9\n"), {
            layout = "stacked",
            context = math.huge,
            deep_diff = { enabled = true },
        })
    end

    it("collapses context into a fold, and opens it again at full context", function()
        local v = gap_view()
        v:open()
        assert.are.equal(0, fold_count(v)) -- whole file: nothing folded
        v:set_context(1)
        assert.are.equal(1, fold_count(v)) -- the 5-line gap folds
        v:set_context(math.huge)
        assert.are.equal(0, fold_count(v))
        v:close()
    end)

    it("creates the collapsed region as an open native fold the user can close", function()
        local v = View.new(model("1\n2\n3\n4\n5\n6\n7\n8\n9\n", "1\nX\n3\n4\n5\n6\n7\nY\n9\n"), {
            layout = "stacked",
            context = 1,
            deep_diff = { enabled = true },
        })
        v:open()
        local win = v.columns[1].winid
        assert.are.equal("manual", vim.wo[win].foldmethod)
        -- buffer rows 5..7 are the foldable middle: a real fold (level >= 1) but open
        -- by default, so za/zo/zc/zm act on it and zc collapses it to its start row
        local fold = vim.api.nvim_win_call(win, function()
            local c = vim.fn.foldclosed(5)
            local l = vim.fn.foldlevel(5)
            vim.cmd("normal! 5Gzc")
            return { open = c, level = l, after_close = vim.fn.foldclosed(5) }
        end)
        assert.are.equal(-1, fold.open) -- open by default
        assert.is_true(fold.level >= 1) -- but a real fold lives there
        assert.are.equal(5, fold.after_close) -- and zc collapses it
        v:close()
    end)

    it("widens/narrows by one and no-ops at whole-file", function()
        local v = gap_view()
        v:open()
        v:set_context(2)
        v:adjust_context(-1)
        assert.are.equal(1, v.context)
        v:adjust_context(1)
        assert.are.equal(2, v.context)
        v:set_context(math.huge)
        v:adjust_context(-1) -- can't decrement infinity
        assert.are.equal(math.huge, v.context)
        v:close()
    end)
end)

describe("view re-source", function()
    it("set_source swaps the file in place, reusing the column buffer", function()
        local v = View.new(model("a\nb\n", "a\nB\n"), {
            layout = "stacked",
            context = math.huge,
            deep_diff = { enabled = true },
        })
        v:open()
        local buf = v.columns[1].bufnr
        v:set_source(model("x\ny\n", "x\nY\n"))
        assert.are.equal(buf, v.columns[1].bufnr) -- same buffer, re-rendered
        assert.are.same({ "x", "y", "Y" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
        v:close()
    end)

    it("names the stacked buffer dipher://<path> and renames on re-source", function()
        local function named(path)
            return diff.build({
                path = path,
                old_rev = "HEAD",
                new_rev = "WORKTREE",
                old_text = "a\n",
                new_text = "a\nb\n",
            })
        end
        local v = View.new(named("lua/a.lua"), {
            layout = "stacked",
            context = math.huge,
            deep_diff = { enabled = true },
        })
        v:open()
        local buf = v.columns[1].bufnr
        local name = vim.api.nvim_buf_get_name(buf)
        -- clean name: scheme + path only, no revs/side noise
        assert.is_truthy(name:find("dipher://lua/a.lua", 1, true))
        assert.are.equal("a.lua", vim.fn.fnamemodify(name, ":t")) -- statusline shows the basename

        v:set_source(named("lua/b.lua"))
        assert.is_truthy(vim.api.nvim_buf_get_name(buf):find("dipher://lua/b.lua", 1, true))
        v:close()
    end)

    it("disambiguates a split's two columns with an old/new segment", function()
        local v = View.new(model("a\nb\n", "a\nB\n"), {
            layout = "split",
            context = math.huge,
            deep_diff = { enabled = true },
        })
        v:open()
        assert.is_truthy(
            vim.api.nvim_buf_get_name(v.columns[1].bufnr):find("dipher://old/x", 1, true)
        )
        assert.is_truthy(
            vim.api.nvim_buf_get_name(v.columns[2].bufnr):find("dipher://new/x", 1, true)
        )
        v:close()
    end)

    it("sets the file's filetype (for the statusline) but keeps native syntax off", function()
        local function named(path)
            return diff.build({
                path = path,
                old_rev = "A",
                new_rev = "B",
                old_text = "x\n",
                new_text = "x\ny\n",
            })
        end
        local v = View.new(named("foo.lua"), {
            layout = "stacked",
            context = math.huge,
            deep_diff = { enabled = true },
        })
        v:open()
        local buf = v.columns[1].bufnr
        assert.are.equal("lua", vim.bo[buf].filetype)
        assert.are.equal("OFF", vim.bo[buf].syntax) -- dipher paints its own syntax pass
        v:set_source(named("bar.py")) -- filetype tracks the re-sourced file
        assert.are.equal("python", vim.bo[buf].filetype)
        v:close()
    end)

    it("holds the cursor near the prior hunk when re-sourced with a focus_line", function()
        -- two hunks: line 2 (b->B) and line 8 (h->H)
        local old, new = "a\nb\nc\nd\ne\nf\ng\nh\n", "a\nB\nc\nd\ne\nf\ng\nH\n"
        local v = View.new(model(old, new), {
            layout = "stacked",
            context = math.huge,
            deep_diff = { enabled = true },
        })
        v:open()
        local win = v.columns[1].winid

        -- a bare re-source jumps to the first hunk (row 2: the deleted "b")
        v:set_source(model(old, new))
        assert.are.equal(2, vim.api.nvim_win_get_cursor(win)[1])

        -- park on the second hunk, capture its new-side line, re-source preserving it:
        -- the cursor holds on the second hunk (row 9) rather than snapping back to row 2
        vim.api.nvim_win_set_cursor(win, { 10, 0 })
        local line = v:cursor_new_line()
        assert.are.equal(8, line) -- the new-side line under the cursor ("H")
        v:set_source(model(old, new), nil, { focus_line = line })
        assert.are.equal(9, vim.api.nvim_win_get_cursor(win)[1])
        v:close()
    end)
end)

describe("view jump-to-file", function()
    local function write(dir, name, text)
        vim.fn.mkdir(dir, "p")
        local fd = assert(io.open(dir .. "/" .. name, "w"))
        fd:write(text)
        fd:close()
    end

    it("opens the real file at the mapped line and tears the view down", function()
        vim.cmd("silent! only")
        local dir = vim.fn.tempname()
        write(dir, "f.txt", "a\nB\nc\n")
        local m = diff.build({
            path = "f.txt",
            old_rev = "HEAD",
            new_rev = "WORKTREE",
            old_text = "a\nb\nc\n",
            new_text = "a\nB\nc\n",
            root = dir,
        })
        local v =
            View.new(m, { layout = "stacked", context = math.huge, deep_diff = { enabled = true } })
        v:open()
        local buf, win = v.columns[1].bufnr, v.columns[1].winid
        -- cursor on the added "B" (buffer line 3 -> new-side line 2)
        vim.api.nvim_win_set_cursor(win, { 3, 0 })
        v:jump_to_file()

        local cur = vim.api.nvim_get_current_buf()
        assert.are.equal("f.txt", vim.fn.fnamemodify(vim.api.nvim_buf_get_name(cur), ":t"))
        assert.are.equal("", vim.bo[cur].buftype) -- a real file, not the synthetic buffer
        assert.are.same({ "a", "B", "c" }, vim.api.nvim_buf_get_lines(cur, 0, -1, false))
        assert.are.equal(2, vim.api.nvim_win_get_cursor(0)[1])
        assert.is_false(vim.api.nvim_buf_is_valid(buf)) -- the diff buffer is gone
        -- dipher's custom gutter is shed, so the real file's line numbers render
        assert.are.equal("", vim.wo[win].statuscolumn)
    end)

    it("notifies and stays put for a source with no root", function()
        local v = View.new(model("a\nb\n", "a\nB\n"), {
            layout = "stacked",
            context = math.huge,
            deep_diff = { enabled = true },
        })
        v:open()
        local buf = v.columns[1].bufnr
        v:jump_to_file()
        assert.is_true(vim.api.nvim_buf_is_valid(buf)) -- still open: no file-backed source
        v:close()
    end)
end)

describe("command router", function()
    local command = require("dipher.command")

    it("dispatches layout + context against the current view", function()
        vim.cmd("silent! only")
        local v = View.new(model("1\n2\n3\n4\n5\n6\n7\n8\n9\n", "1\nX\n3\n4\n5\n6\n7\nY\n9\n"), {
            layout = "stacked",
            context = math.huge,
            deep_diff = { enabled = true },
        })
        v:open()
        vim.api.nvim_set_current_win(v.columns[1].winid)
        assert.are.equal(v, View.current())

        command.dispatch({ "layout", "split" })
        assert.are.equal(2, #v.columns)

        command.dispatch({ "context", "1" })
        assert.are.equal(1, v.context)
        v:close()
    end)

    it("completes subcommands and values", function()
        local subs = command.complete("", "Dipher ")
        table.sort(subs)
        assert.are.same(
            { "cache", "close", "context", "gofile", "layout", "log", "panel", "sidecar" },
            subs
        )
        assert.are.same(
            { "split", "stacked" },
            (function()
                local v = command.complete("s", "Dipher layout s")
                table.sort(v)
                return v
            end)()
        )
    end)
end)
