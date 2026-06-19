-- runs under headless nvim: drives the View over real lua source and asserts the
-- treesitter syntax pass projects captures onto the derived buffer through
-- the line map, in its own namespace, layered under the diff highlights
local diff = require("differ.model.diff")
local View = require("differ.view")

local ns = vim.api.nvim_create_namespace("differ.syntax")

local function model(old, new, path)
    return diff.build({
        path = path or "x.lua",
        old_rev = "A",
        new_rev = "B",
        old_text = old,
        new_text = new,
    })
end

-- syntax extmarks for a buffer: { {row, col, end_col, hl}, ... }
local function syntax_marks(bufnr)
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })) do
        out[#out + 1] = { row = m[2], col = m[3], end_col = m[4].end_col, hl = m[4].hl_group }
    end
    return out
end

-- is there a mark with `hl` on `row` (optionally starting at `col`)?
local function has(marks, row, hl, col)
    for _, m in ipairs(marks) do
        if m.row == row and m.hl == hl and (col == nil or m.col == col) then
            return true
        end
    end
    return false
end

local function view(old, new, opts)
    return View.new(
        model(old, new, opts and opts.path),
        vim.tbl_extend(
            "force",
            { layout = "stacked", context = math.huge, deep_diff = { enabled = true } },
            opts or {}
        )
    )
end

describe("syntax pass (stacked)", function()
    it("projects captures onto both old and new lines via the map", function()
        -- single-line substitution: stacked emits old on row 0, new on row 1
        local v = view("local x = 1\n", "local y = 2\n")
        v:open()
        local marks = syntax_marks(v.columns[1].bufnr)
        -- `local` keyword highlighted on the old line (row 0) and the new line (row 1)
        assert.is_true(has(marks, 0, "@keyword.lua", 0))
        assert.is_true(has(marks, 1, "@keyword.lua", 0))
        v:close()
    end)

    it("highlights context lines too (they map from the real source)", function()
        local v = view("local a = 1\nkeep()\n", "local b = 1\nkeep()\n")
        v:open()
        -- buffer: old "local a = 1" (0), new "local b = 1" (1), context "keep()" (2)
        local marks = syntax_marks(v.columns[1].bufnr)
        assert.is_true(has(marks, 0, "@keyword.lua", 0))
        assert.is_true(has(marks, 1, "@keyword.lua", 0))
        assert.is_true(has(marks, 2, "@function.call.lua")) -- keep() on the context row
        v:close()
    end)

    it("is a no-op when the path has no treesitter language", function()
        local v = view("local x = 1\n", "local y = 1\n", { path = "x" })
        v:open()
        assert.are.same({}, syntax_marks(v.columns[1].bufnr))
        v:close()
    end)
end)

describe("syntax pass (split)", function()
    it("paints each column from its own side's source", function()
        local v = view("local x = 1\n", "local y = 1\n", { layout = "split" })
        v:open()
        local left = syntax_marks(v.columns[1].bufnr) -- old
        local right = syntax_marks(v.columns[2].bufnr) -- new
        assert.is_true(has(left, 0, "@keyword.lua", 0))
        assert.is_true(has(right, 0, "@keyword.lua", 0))
        v:close()
    end)
end)
