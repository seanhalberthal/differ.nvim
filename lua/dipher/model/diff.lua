-- Canonical hunk model built from vim.diff(); buffers are projections of this

---@class dipher.Hunk
---@field old_start integer
---@field old_count integer
---@field new_start integer
---@field new_count integer
---@field old_lines string[]
---@field new_lines string[]
---@field pairs dipher.LinePair[]|nil

---@class dipher.DiffModel
---@field path string
---@field old_rev string
---@field new_rev string
---@field hunks dipher.Hunk[]
---@field old_text string
---@field new_text string

local M = {}

-- Split text into lines, tolerating a missing trailing newline
---@param text string
---@return string[]
local function to_lines(text)
    if text == "" then
        return {}
    end
    local lines = vim.split(text, "\n", { plain = true })
    if lines[#lines] == "" then
        table.remove(lines)
    end
    return lines
end

-- vim.text.diff is line-oriented; an unterminated final line reads as changed,
-- so normalise to newline-terminated before diffing
---@param text string
---@return string
local function ensure_trailing_nl(text)
    if text == "" or text:sub(-1) == "\n" then
        return text
    end
    return text .. "\n"
end

-- Slice a 1-based inclusive range out of a line array
---@param lines string[]
---@param start integer
---@param count integer
---@return string[]
local function slice(lines, start, count)
    local out = {}
    for i = start, start + count - 1 do
        out[#out + 1] = lines[i]
    end
    return out
end

-- Build a DiffModel from old/new file contents
---@param opts { path: string, old_rev: string, new_rev: string, old_text: string, new_text: string }
---@return dipher.DiffModel
function M.build(opts)
    local old_lines = to_lines(opts.old_text)
    local new_lines = to_lines(opts.new_text)

    local raw =
        vim.text.diff(ensure_trailing_nl(opts.old_text), ensure_trailing_nl(opts.new_text), {
            result_type = "indices",
            algorithm = "histogram",
        })

    ---@cast raw integer[][]
    local hunks = {}
    for _, h in ipairs(raw) do
        local old_start, old_count, new_start, new_count = h[1], h[2], h[3], h[4]
        hunks[#hunks + 1] = {
            old_start = old_start,
            old_count = old_count,
            new_start = new_start,
            new_count = new_count,
            old_lines = slice(old_lines, old_start, old_count),
            new_lines = slice(new_lines, new_start, new_count),
        }
    end

    return {
        path = opts.path,
        old_rev = opts.old_rev,
        new_rev = opts.new_rev,
        hunks = hunks,
        old_text = opts.old_text,
        new_text = opts.new_text,
    }
end

return M
