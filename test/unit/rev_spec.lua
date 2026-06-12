local rev = require("dipher.git.rev")

describe("git.rev.source", function()
    it("defaults to HEAD vs worktree (uncommitted changes)", function()
        local s = rev.source({})
        assert.are.same({ kind = "rev", rev = "HEAD", label = "HEAD" }, s.old)
        assert.are.equal("worktree", s.new.kind)
    end)

    it("treats a lone rev as <rev> vs worktree", function()
        local s = rev.source({ "HEAD~2" })
        assert.are.same({ kind = "rev", rev = "HEAD~2", label = "HEAD~2" }, s.old)
        assert.are.equal("worktree", s.new.kind)
    end)

    it("reads a two-dot range as a plain rev pair", function()
        local s = rev.source({ "abc..def" })
        assert.are.equal("def", s.new.rev)
        assert.are.equal("abc", s.old.rev)
        assert.are.equal("rev", s.old.kind)
    end)

    it("reads two separate args as a rev pair", function()
        local s = rev.source({ "abc", "def" })
        assert.are.equal("abc", s.old.rev)
        assert.are.equal("def", s.new.rev)
    end)

    it("reads three-dot as merge-base(a,b) vs b", function()
        local s = rev.source({ "main...feature" })
        assert.are.same(
            { kind = "merge_base", base = "main", head = "feature", label = "main...feature" },
            s.old
        )
        assert.are.same({ kind = "rev", rev = "feature", label = "feature" }, s.new)
    end)

    it("reads empty-RHS three-dot as merge-base(a,HEAD) vs worktree", function()
        -- the <leader>dt branch-total form: everything since we diverged from main,
        -- including uncommitted work
        local s = rev.source({ "main..." })
        assert.are.same(
            { kind = "merge_base", base = "main", head = "HEAD", label = "main..." },
            s.old
        )
        assert.are.equal("worktree", s.new.kind)
    end)
end)

describe("git.rev.diff_args", function()
    it("lists a rev-vs-worktree diff with a single rev", function()
        assert.are.same({ "HEAD" }, rev.diff_args(rev.source({})))
    end)

    it("lists a rev pair as two args", function()
        assert.are.same({ "abc", "def" }, rev.diff_args(rev.source({ "abc..def" })))
    end)
end)

describe("git.rev.parse_name_status", function()
    it("parses NUL-delimited modify/add/delete records", function()
        local out = "M\0lua/a.lua\0A\0lua/b.lua\0D\0lua/c.lua\0"
        assert.are.same({
            { status = "M", path = "lua/a.lua" },
            { status = "A", path = "lua/b.lua" },
            { status = "D", path = "lua/c.lua" },
        }, rev.parse_name_status(out))
    end)

    it("captures previous_path on a rename record", function()
        local out = "R100\0old/name.lua\0new/name.lua\0"
        assert.are.same({
            { status = "R", path = "new/name.lua", previous_path = "old/name.lua" },
        }, rev.parse_name_status(out))
    end)

    it("returns nothing for empty output", function()
        assert.are.same({}, rev.parse_name_status(""))
    end)
end)
