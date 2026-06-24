-- build a git-apply-ready unified diff for a single hunk, straight from the hunk
-- model (never derived from buffer text). zero context, so callers apply
-- with `git apply --unidiff-zero`; the `@@` line numbers come from the model and
-- match the index/worktree content exactly. the missing-final-newline marker is
-- emitted when a hunk reaches an unterminated end of file, so staging the last
-- hunk doesn't corrupt it. pure: no vim, no git, unit-testable

local to_lines = require("differ.util.text").to_lines

local M = {}

local NO_NL = "\\ No newline at end of file"

-- does `text`'s final line lack a trailing newline (so a hunk reaching it needs
-- the `\ No newline` marker)
---@param text string
---@return boolean
local function unterminated(text)
    return text ~= "" and text:sub(-1) ~= "\n"
end

-- one hunk as a unified diff against `path`. `old_text`/`new_text` are the full
-- file sides, read only to detect an unterminated end of file. assumes a plain
-- modification (same path both sides); renames/adds/deletes stage file-level.
-- `offset` shifts the located side's start by the net line delta of the staged
-- hunks before this one: the frozen view's line numbers are from open time, but
-- git applies against the live index, so a preceding staged insert/delete moves
-- this hunk's position. under `--unidiff-zero` git relocates a single zero-context
-- hunk by content and only reads one side's start (`-` for a forward stage, `+`
-- for a reverse unstage), so only that side carries the offset; the other side
-- keeps its frozen, always-non-negative line number. shifting both would let a
-- net-negative offset (earlier deletions) drive the unused side below zero, and
-- git rejects a negative `@@` number as `corrupt patch at line 4` before it ever
-- tries to apply
---@param path string
---@param hunk differ.Hunk
---@param old_text string
---@param new_text string
---@param offset integer|nil
---@param reverse boolean|nil  -- true for an unstage apply (shifts new_start, not old_start)
---@return string
function M.hunk(path, hunk, old_text, new_text, offset, reverse)
    offset = offset or 0
    local old_n, new_n = #to_lines(old_text), #to_lines(new_text)
    local old_eof, new_eof = unterminated(old_text), unterminated(new_text)
    local old_shift = reverse and 0 or offset
    local new_shift = reverse and offset or 0

    local out = {
        ("diff --git a/%s b/%s"):format(path, path),
        "--- a/" .. path,
        "+++ b/" .. path,
        ("@@ -%d,%d +%d,%d @@"):format(
            hunk.old_start + old_shift,
            hunk.old_count,
            hunk.new_start + new_shift,
            hunk.new_count
        ),
    }
    for i, line in ipairs(hunk.old_lines) do
        out[#out + 1] = "-" .. line
        if old_eof and (hunk.old_start + i - 1) == old_n then
            out[#out + 1] = NO_NL
        end
    end
    for i, line in ipairs(hunk.new_lines) do
        out[#out + 1] = "+" .. line
        if new_eof and (hunk.new_start + i - 1) == new_n then
            out[#out + 1] = NO_NL
        end
    end
    return table.concat(out, "\n") .. "\n"
end

return M
