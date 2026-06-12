-- Runs under headless nvim (vim.diff available); invoked via the nvim-test target
local diff = require("dipher.model.diff")

describe("model.diff.build", function()
    it("produces no hunks for identical text", function()
        local m = diff.build({
            path = "x.lua",
            old_rev = "HEAD",
            new_rev = "WORKTREE",
            old_text = "a\nb\nc\n",
            new_text = "a\nb\nc\n",
        })
        assert.are.equal(0, #m.hunks)
    end)

    it("materializes changed lines per hunk", function()
        local m = diff.build({
            path = "x.lua",
            old_rev = "HEAD",
            new_rev = "WORKTREE",
            old_text = "a\nb\nc\n",
            new_text = "a\nB\nc\n",
        })
        assert.are.equal(1, #m.hunks)
        assert.are.same({ "b" }, m.hunks[1].old_lines)
        assert.are.same({ "B" }, m.hunks[1].new_lines)
    end)

    it("handles add-only and missing trailing newline", function()
        local m = diff.build({
            path = "x.lua",
            old_rev = "HEAD",
            new_rev = "WORKTREE",
            old_text = "a",
            new_text = "a\nb",
        })
        assert.are.equal(1, #m.hunks)
        assert.are.same({ "b" }, m.hunks[1].new_lines)
    end)
end)
