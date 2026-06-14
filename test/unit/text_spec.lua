local text = require("dipher.util.text")

describe("util.text.truncate_end", function()
    it("returns the string unchanged when it already fits", function()
        assert.are.equal("abc", text.truncate_end("abc", 3))
        assert.are.equal("abc", text.truncate_end("abc", 10))
    end)

    it("keeps the front with a trailing ellipsis when over budget", function()
        local out = text.truncate_end("EnrolTotpSheet.test.tsx", 8)
        assert.are.equal("EnrolTo…", out) -- 7 front cols + "…"
    end)

    it("keeps distinct prefixes distinguishable", function()
        assert.are.equal("EnrolPh…", text.truncate_end("EnrolPhoneSheet.test.tsx", 8))
        assert.are.equal("EnrolTo…", text.truncate_end("EnrolTotpSheet.test.tsx", 8))
    end)

    it("leaves a too-small budget alone", function()
        assert.are.equal("abcdef", text.truncate_end("abcdef", 1))
    end)
end)
