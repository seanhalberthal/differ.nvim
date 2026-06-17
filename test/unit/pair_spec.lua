local pair = require("dipher.worddiff.pair")

describe("worddiff.pair.similarity", function()
    it("is 1 for identical lines", function()
        assert.are.equal(1.0, pair.similarity("foo bar", "foo bar"))
    end)

    it("is 0 for fully disjoint lines", function()
        assert.are.equal(0.0, pair.similarity("foo", "bar"))
    end)

    it("is between 0 and 1 for partial overlap", function()
        local s = pair.similarity("foo bar baz", "foo bar qux")
        assert.is_true(s > 0 and s < 1)
    end)

    it("scores reordered words far below an in-order match (order-aware)", function()
        -- identical word multiset, reversed order: a token-set metric would call this
        -- 1.0; the sequence metric must not, so scattered overlap can't force a pairing
        assert.is_true(pair.similarity("alpha beta gamma delta", "delta gamma beta alpha") < 0.5)
    end)

    it("rewards an in-order shared run", function()
        assert.is_true(pair.similarity("the quick brown fox", "the quick brown cat") > 0.5)
    end)
end)

describe("worddiff.pair.pair", function()
    it("pairs positionally when lines match", function()
        local p = pair.pair({ "a", "b" }, { "a", "b" }, 0.5)
        assert.are.equal(1, p[1].old)
        assert.are.equal(1, p[1].new)
        assert.are.equal(2, p[2].old)
        assert.are.equal(2, p[2].new)
    end)

    it("keeps the first partner on a similarity tie", function()
        -- "transcript string" ties (0.5) against both new lines; the closer
        -- "transcript transcript" must win over the later "statusContent string"
        local p = pair.pair(
            { "transcript string" },
            { "transcript transcript", "statusContent string" },
            0.5
        )
        assert.are.equal(1, p[1].old)
        assert.are.equal(1, p[1].new)
        -- the unmatched new line falls through as a pure insertion
        assert.is_nil(p[2].old)
        assert.are.equal(2, p[2].new)
    end)

    it("leaves no-partner lines unpaired", function()
        local p = pair.pair({ "totally different" }, { "nothing alike here" }, 0.5)
        assert.is_nil(p[1].new)
        assert.are.equal(0, p[1].score)
    end)

    it("aligns monotonically instead of crossing to a more similar partner", function()
        -- old[1]'s strongest partner is new[2] and old[2]'s is new[1]; pairing both
        -- would cross, so the monotonic alignment keeps order and drops one side
        local p = pair.pair({ "foo one", "bar two" }, { "bar two extra", "foo one extra" }, 0.5)
        assert.are.equal(2, p[1].new) -- old[1] -> new[2]
        assert.is_nil(p[2].new) -- old[2] left unpaired rather than crossing back
    end)

    it("leaves a rewritten line whole-line when overlap is only scattered words", function()
        -- a different struct field whose comment coincidentally shares tokens: the
        -- token-set metric mis-paired these, the order-aware one keeps them apart
        local p = pair.pair(
            { 'cursor int // row index; the last row (len(options)) is "Other"' },
            { "qi int // current question; len(questions) is the review tab" },
            0.5
        )
        assert.is_nil(p[1].new)
    end)
end)
