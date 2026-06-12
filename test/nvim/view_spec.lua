-- Runs under headless nvim: drives the View through real windows/buffers and
-- asserts content, the diff highlight extmarks, and split scroll-binding.
local diff = require("dipher.model.diff")
local View = require("dipher.view")

-- nvim_create_namespace is idempotent by name, so this is the same ns the View uses.
local ns = vim.api.nvim_create_namespace("dipher")

local function model(old, new)
    return diff.build({ path = "x", old_rev = "A", new_rev = "B", old_text = old, new_text = new })
end

-- Collect line_hl_group per 0-based row and word hl_group spans from the namespace.
local function extmarks(bufnr)
    local line_hl, word = {}, {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })) do
        local row, d = m[2], m[4]
        if d.line_hl_group then
            line_hl[row] = d.line_hl_group
        end
        if d.hl_group then
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
        assert.is_false(vim.wo[win].wrap)

        local line_hl = extmarks(buf)
        assert.are.equal("dipherLineDelete", line_hl[1]) -- "b" (old)
        assert.are.equal("dipherLineAdd", line_hl[2]) -- "B" (new)
        assert.is_nil(line_hl[0]) -- "a" (context) unhighlighted
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
        assert.are.equal(9, vim.api.nvim_win_get_cursor(win)[1]) -- no wrap, stays put
        v:goto_hunk("prev")
        assert.are.equal(2, vim.api.nvim_win_get_cursor(win)[1])
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
    local function meta_count(view)
        local n = 0
        for _, l in ipairs(view.columns[1].map.lines) do
            if l.kind == "meta" then
                n = n + 1
            end
        end
        return n
    end

    -- two hunks with a 5-line gap between them
    local function gap_view()
        return View.new(model("1\n2\n3\n4\n5\n6\n7\n8\n9\n", "1\nX\n3\n4\n5\n6\n7\nY\n9\n"), {
            layout = "stacked",
            context = math.huge,
            deep_diff = { enabled = true },
        })
    end

    it("collapses context, producing a meta separator", function()
        local v = gap_view()
        v:open()
        assert.are.equal(0, meta_count(v)) -- whole file: nothing hidden
        v:set_context(1)
        assert.are.equal(1, meta_count(v)) -- the 5-line gap collapses
        v:set_context(math.huge)
        assert.are.equal(0, meta_count(v))
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
        assert.are.same({ "context", "layout" }, subs)
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
