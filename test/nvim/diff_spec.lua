-- runs under headless nvim (vim.diff available); invoked via the nvim-test target
local diff = require("differ.model.diff")

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

    it("flags binary content and skips diffing it", function()
        -- a modified binary file (NUL bytes both sides) must not be diffed: the word
        -- pass over megabyte pseudo-lines is an OOM. it carries no hunks, just a flag
        local m = diff.build({
            path = "demo.gif",
            old_rev = "HEAD",
            new_rev = "WORKTREE",
            old_text = "GIF89a\0\1\2\3",
            new_text = "GIF89a\0\4\5\6",
        })
        assert.is_true(m.binary)
        assert.are.equal(0, #m.hunks)
    end)
end)
