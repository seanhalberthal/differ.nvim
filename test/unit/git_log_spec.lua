local log = require("dipher.git.log")

local US = "\31"

describe("git.log.log_args", function()
    it("builds a single-file log invocation with the path after --", function()
        local a = log.log_args({ path = "lua/foo.lua" })
        assert.are.equal("log", a[1])
        assert.are.equal("--date=short", a[3])
        assert.are.equal("--", a[#a - 1])
        assert.are.equal("lua/foo.lua", a[#a])
    end)

    it("omits the -- path pair when no path is given", function()
        local a = log.log_args({})
        for _, v in ipairs(a) do
            assert.are_not.equal("--", v)
        end
    end)

    it("splices extra args before the path (the dp range seam)", function()
        local a = log.log_args({ path = "x", extra = { "--no-merges", "main...HEAD" } })
        -- order: ... extra ... -- path
        assert.are.equal("main...HEAD", a[#a - 2])
        assert.are.equal("--no-merges", a[#a - 3])
        assert.are.equal("--", a[#a - 1])
        assert.are.equal("x", a[#a])
    end)

    it("does not depend on vim (pure, busted-runnable)", function()
        -- log_args is called above with no vim global available; reaching here is the
        -- assertion. a marker keeps luacheck from flagging an empty body
        assert.is_table(log.log_args({}))
    end)
end)

describe("git.log.parse_log", function()
    local function record(sha, short, author, date, subject)
        return table.concat({ sha, short, author, date, subject }, US)
    end

    it("parses one commit per line, newest first", function()
        local out = table.concat({
            record("aaaa1111", "aaaa111", "Ada", "2026-06-13", "add the thing"),
            record("bbbb2222", "bbbb222", "Bo", "2026-06-01", "seed the file"),
        }, "\n")
        local c = log.parse_log(out)
        assert.are.equal(2, #c)
        assert.are.same({
            sha = "aaaa1111",
            short = "aaaa111",
            author = "Ada",
            date = "2026-06-13",
            subject = "add the thing",
        }, c[1])
        assert.are.equal("seed the file", c[2].subject)
    end)

    it("returns an empty list for empty output", function()
        assert.are.same({}, log.parse_log(""))
    end)

    it("skips blank lines and short records", function()
        local out = table.concat({
            record("a", "a", "Ada", "2026-06-13", "ok"),
            "",
            "garbage-without-separators",
        }, "\n")
        local c = log.parse_log(out)
        assert.are.equal(1, #c)
        assert.are.equal("ok", c[1].subject)
    end)

    it("preserves a subject that itself contains the field separator", function()
        local out = record("a", "a", "Ada", "2026-06-13", "weird" .. US .. "subject")
        local c = log.parse_log(out)
        assert.are.equal("weird" .. US .. "subject", c[1].subject)
    end)
end)
