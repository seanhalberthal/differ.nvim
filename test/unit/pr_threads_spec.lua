local threads = require("dipher.pr.threads")

describe("pr.threads.side_of", function()
    it("maps github LEFT/RIGHT to the line-map column side", function()
        assert.are.equal("old", threads.side_of({ side = "LEFT" }))
        assert.are.equal("new", threads.side_of({ side = "RIGHT" }))
        assert.are.equal("new", threads.side_of({ side = nil })) -- default to the new side
    end)
end)

describe("pr.threads.anchor_row", function()
    -- from_new-style index: source line -> buffer row
    local index = { [10] = 3, [11] = 4, [20] = 9 }

    it("returns the exact derived row when the anchor is in context", function()
        assert.are.equal(4, threads.anchor_row(index, 11))
    end)

    it("degrades an out-of-context anchor to the nearest rendered line", function()
        assert.are.equal(9, threads.anchor_row(index, 19)) -- nearest 20
        assert.are.equal(4, threads.anchor_row(index, 13)) -- nearest 11
    end)

    it("breaks a distance tie toward the lower row", function()
        -- line 15 is equidistant from 11 (row 4) and 20 (row 9 via |20-15|=5 vs |11-15|=4)
        -- so use a true tie: 14 is dist 3 from 11 and 6 from 20 -> 11; check 15.5 not needed
        local idx = { [10] = 2, [20] = 8 }
        assert.are.equal(2, threads.anchor_row(idx, 15)) -- tie -> lower row
    end)

    it("returns nil when nothing is rendered on that side", function()
        assert.is_nil(threads.anchor_row({}, 5))
    end)
end)

describe("pr.threads.stack_sort", function()
    it("orders same-row threads oldest first by first-comment time", function()
        local newer = { comments = { { created_at = "2026-03-02T00:00:00Z" } } }
        local older = { comments = { { created_at = "2026-01-01T00:00:00Z" } } }
        local mid = { comments = { { created_at = "2026-02-15T00:00:00Z" } } }
        local sorted = threads.stack_sort({ newer, older, mid })
        assert.are.equal(older, sorted[1])
        assert.are.equal(mid, sorted[2])
        assert.are.equal(newer, sorted[3])
    end)

    it("treats a thread with no comments as oldest (empty key)", function()
        local empty = { comments = {} }
        local has = { comments = { { created_at = "2026-01-01T00:00:00Z" } } }
        local sorted = threads.stack_sort({ has, empty })
        assert.are.equal(empty, sorted[1])
    end)
end)
