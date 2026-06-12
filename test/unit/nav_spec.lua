local stacked = require("dipher.render.stacked")
local nav = require("dipher.nav")

-- Two hunks far apart -> stacked (full context) buffer:
--   1 ctx | 2 old"2" h1 | 3 new"X" h1 | 4-8 ctx | 9 old"8" h2 | 10 new"Y" h2 | 11 ctx
-- hunk starts at buffer lnums 2 and 9.
local function two_hunk_map()
    return stacked.render({
        path = "x",
        old_rev = "A",
        new_rev = "B",
        old_text = "1\n2\n3\n4\n5\n6\n7\n8\n9\n",
        new_text = "1\nX\n3\n4\n5\n6\n7\nY\n9\n",
        hunks = {
            {
                old_start = 2,
                old_count = 1,
                new_start = 2,
                new_count = 1,
                old_lines = { "2" },
                new_lines = { "X" },
            },
            {
                old_start = 8,
                old_count = 1,
                new_start = 8,
                new_count = 1,
                old_lines = { "8" },
                new_lines = { "Y" },
            },
        },
    }, { context = math.huge }).columns[1].map
end

describe("nav.next_hunk", function()
    local map = two_hunk_map()

    it("jumps from before the first hunk to its start", function()
        assert.are.equal(2, nav.next_hunk(map, 1))
    end)

    it("jumps from inside the first hunk to the second", function()
        assert.are.equal(9, nav.next_hunk(map, 2))
        assert.are.equal(9, nav.next_hunk(map, 5)) -- from context between hunks
    end)

    it("returns nil at/after the last hunk (no wrap)", function()
        assert.is_nil(nav.next_hunk(map, 9))
        assert.is_nil(nav.next_hunk(map, 11))
    end)
end)

describe("nav.prev_hunk", function()
    local map = two_hunk_map()

    it("jumps from after the last hunk back to its start", function()
        assert.are.equal(9, nav.prev_hunk(map, 11))
    end)

    it("jumps from inside the second hunk to the first", function()
        assert.are.equal(2, nav.prev_hunk(map, 9))
        assert.are.equal(2, nav.prev_hunk(map, 5))
    end)

    it("returns nil at/before the first hunk (no wrap)", function()
        assert.is_nil(nav.prev_hunk(map, 2))
        assert.is_nil(nav.prev_hunk(map, 1))
    end)
end)

describe("nav with no hunks", function()
    it("returns nil both directions", function()
        local map = stacked.render({
            path = "x",
            old_rev = "A",
            new_rev = "B",
            old_text = "a\nb\n",
            new_text = "a\nb\n",
            hunks = {},
        }, { context = math.huge }).columns[1].map
        assert.is_nil(nav.next_hunk(map, 1))
        assert.is_nil(nav.prev_hunk(map, 1))
    end)
end)
