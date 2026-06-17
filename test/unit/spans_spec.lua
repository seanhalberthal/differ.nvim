local spans = require("dipher.worddiff.spans")

describe("worddiff.spans.emit (word)", function()
    it("emits no spans for identical lines", function()
        local s = spans.emit("local x = 1", "local x = 1", "word")
        assert.are.same({}, s.old)
        assert.are.same({}, s.new)
    end)

    it("isolates a single changed identifier", function()
        -- "local foo = 1" -> "local bar = 1"; only foo/bar differ
        local s = spans.emit("local foo = 1", "local bar = 1", "word")
        assert.are.same({ { col_start = 6, col_end = 9 } }, s.old)
        assert.are.same({ { col_start = 6, col_end = 9 } }, s.new)
    end)

    it("marks a pure insertion only on the new side", function()
        local s = spans.emit("a c", "a b c", "word")
        assert.are.same({}, s.old)
        -- inserted "b " sits at cols [2,4): the new word and the space after it
        assert.are.same({ { col_start = 2, col_end = 4 } }, s.new)
    end)

    it("merges adjacent changed tokens into one span", function()
        local s = spans.emit("xy", "ab", "word")
        assert.are.same({ { col_start = 0, col_end = 2 } }, s.old)
        assert.are.same({ { col_start = 0, col_end = 2 } }, s.new)
    end)

    it("ignores a whitespace-only change (gofmt realignment)", function()
        -- field name and type are identical; only the alignment padding widened
        local s = spans.emit("ctx     context.Context", "ctx       context.Context", "word")
        assert.are.same({}, s.old)
        assert.are.same({}, s.new)
    end)

    it("drops an isolated realignment gap but keeps the real change", function()
        -- the widened gap before '=' is alignment churn; only the type token changed
        local s = spans.emit("foo = string", "foo    = transcript", "word")
        assert.are.same({ { col_start = 6, col_end = 12 } }, s.old)
        assert.are.same({ { col_start = 9, col_end = 19 } }, s.new)
    end)

    it("keeps changes either side of an unchanged token separate", function()
        -- "a X b" -> "Z X Y": 'a'->'Z' and 'b'->'Y', the middle " X " survives
        local s = spans.emit("a X b", "Z X Y", "word")
        assert.are.same({ { col_start = 0, col_end = 1 }, { col_start = 4, col_end = 5 } }, s.old)
        assert.are.same({ { col_start = 0, col_end = 1 }, { col_start = 4, col_end = 5 } }, s.new)
    end)
end)

describe("worddiff.spans.emit (char)", function()
    it("narrows to the changed characters", function()
        local s = spans.emit("kitten", "kitsen", "char")
        assert.are.same({ { col_start = 3, col_end = 4 } }, s.old)
        assert.are.same({ { col_start = 3, col_end = 4 } }, s.new)
    end)
end)

describe("worddiff.spans.for_hunk", function()
    it("attaches spans to paired lines and skips unpaired ones", function()
        local hunk = {
            old_start = 1,
            old_count = 2,
            new_start = 1,
            new_count = 2,
            old_lines = { "local foo = 1", "totally unrelated" },
            new_lines = { "local bar = 1", "nothing alike here" },
        }
        local old_spans, new_spans = spans.for_hunk(hunk, 0.5, "word")
        -- line 1 pairs (high similarity) -> word span on foo/bar
        assert.are.same({ { col_start = 6, col_end = 9 } }, old_spans[1])
        assert.are.same({ { col_start = 6, col_end = 9 } }, new_spans[1])
        -- line 2 has no partner above threshold -> no spans (whole-line highlight)
        assert.is_nil(old_spans[2])
        assert.is_nil(new_spans[2])
    end)
end)
