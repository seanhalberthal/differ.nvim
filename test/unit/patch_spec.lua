local patch = require("differ.git.patch")

describe("patch.hunk", function()
    it("builds a zero-context patch for a one-line modification", function()
        local h = {
            old_start = 1,
            old_count = 1,
            new_start = 1,
            new_count = 1,
            old_lines = { "local x = 1" },
            new_lines = { "local x = 2" },
        }
        local p = patch.hunk("a.lua", h, "local x = 1\nreturn x\n", "local x = 2\nreturn x\n")
        assert.are.equal(
            "diff --git a/a.lua b/a.lua\n"
                .. "--- a/a.lua\n"
                .. "+++ b/a.lua\n"
                .. "@@ -1,1 +1,1 @@\n"
                .. "-local x = 1\n"
                .. "+local x = 2\n",
            p
        )
    end)

    it("emits all removed lines before added lines", function()
        local h = {
            old_start = 2,
            old_count = 2,
            new_start = 2,
            new_count = 1,
            old_lines = { "b", "c" },
            new_lines = { "X" },
        }
        local p = patch.hunk("f", h, "a\nb\nc\nd\n", "a\nX\nd\n")
        assert.are.equal("diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -2,2 +2,1 @@\n-b\n-c\n+X\n", p)
    end)

    it("formats a pure insertion (old_count 0) against the preceding line", function()
        local h = {
            old_start = 1,
            old_count = 0,
            new_start = 2,
            new_count = 1,
            old_lines = {},
            new_lines = { "b" },
        }
        local p = patch.hunk("f", h, "a\n", "a\nb\n")
        assert.are.equal("diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,0 +2,1 @@\n+b\n", p)
    end)

    it("marks a missing final newline on each side that reaches EOF", function()
        -- old "a\nb" (no trailing nl) -> "a\nB" (no trailing nl): the second line is
        -- the file's last on both sides, so both -/+ lines get the marker
        local h = {
            old_start = 2,
            old_count = 1,
            new_start = 2,
            new_count = 1,
            old_lines = { "b" },
            new_lines = { "B" },
        }
        local p = patch.hunk("f", h, "a\nb", "a\nB")
        assert.are.equal(
            "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -2,1 +2,1 @@\n"
                .. "-b\n\\ No newline at end of file\n"
                .. "+B\n\\ No newline at end of file\n",
            p
        )
    end)

    it("shifts the located side by the staged-hunk offset (forward stage)", function()
        -- a hunk at old/new line 5, with two extra lines already staged before it,
        -- applies at index line 7. forward apply locates by the `-` side, so old_start
        -- shifts to 7 and new_start stays frozen at 5
        local h = {
            old_start = 5,
            old_count = 1,
            new_start = 5,
            new_count = 1,
            old_lines = { "e" },
            new_lines = { "E" },
        }
        local p = patch.hunk("f", h, "a\nb\nc\nd\ne\n", "a\nb\nc\nd\nE\n", 2)
        assert.is_truthy(p:find("@@ -7,1 +5,1 @@", 1, true))
    end)

    it("never emits a negative line number when a deletion offset underflows", function()
        -- an earlier staged hunk deleted 6 lines (net offset -6); a later hunk sits at
        -- worktree line 3. shifting both starts would drive new_start to -3 and produce
        -- `@@ -3,1 +-3,1 @@`, which git rejects as a corrupt patch at line 4
        local h = {
            old_start = 9,
            old_count = 1,
            new_start = 3,
            new_count = 1,
            old_lines = { "i" },
            new_lines = { "I" },
        }
        local p = patch.hunk("f", h, "", "", -6)
        local header = p:match("@@[^\n]*@@")
        assert.is_nil(header:find("%-%-"), "negative old_start in header: " .. header)
        assert.is_nil(header:find("%+%-"), "negative new_start in header: " .. header)
    end)

    it("forward stage shifts only old_start, leaving new_start frozen", function()
        -- forward apply locates by the `-` side, so only old_start carries the offset;
        -- new_start (worktree coords) stays put and so can never go negative
        local h = {
            old_start = 9,
            old_count = 1,
            new_start = 3,
            new_count = 1,
            old_lines = { "i" },
            new_lines = { "I" },
        }
        local p = patch.hunk("f", h, "", "", -6, false)
        assert.is_truthy(p:find("@@ -3,1 +3,1 @@", 1, true), p)
    end)

    it("reverse unstage shifts only new_start, leaving old_start frozen", function()
        -- reverse apply locates by the `+` side, so only new_start carries the offset
        local h = {
            old_start = 3,
            old_count = 1,
            new_start = 9,
            new_count = 1,
            old_lines = { "i" },
            new_lines = { "I" },
        }
        local p = patch.hunk("f", h, "", "", -6, true)
        assert.is_truthy(p:find("@@ -3,1 +3,1 @@", 1, true), p)
    end)

    it("omits the marker when the hunk does not reach an unterminated EOF", function()
        -- the file lacks a trailing newline, but the hunk touches the first line only
        local h = {
            old_start = 1,
            old_count = 1,
            new_start = 1,
            new_count = 1,
            old_lines = { "a" },
            new_lines = { "A" },
        }
        local p = patch.hunk("f", h, "a\nb", "A\nb")
        assert.is_nil(p:find("No newline", 1, true))
    end)
end)
