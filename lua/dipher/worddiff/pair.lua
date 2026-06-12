-- Pure line-pairing scorer for the word-level pass, no Neovim API
-- Lines with no partner above threshold stay unpaired (whole-line highlight)

local tokenize = require("dipher.worddiff.tokenize")

---@class dipher.LinePair
---@field old integer|nil -- index into the hunk's old_lines (nil = pure addition)
---@field new integer|nil -- index into the hunk's new_lines (nil = pure deletion)
---@field score number    -- similarity in [0,1]; 0 for unpaired

local M = {}

-- Token-set similarity (Sørensen–Dice over word tokens) in [0,1]
---@param a string
---@param b string
---@return number
function M.similarity(a, b)
    if a == b then
        return 1.0
    end
    local sa, sb = {}, {}
    for _, t in ipairs(tokenize.word(a)) do
        if t.text:match("%S") then
            sa[t.text] = (sa[t.text] or 0) + 1
        end
    end
    for _, t in ipairs(tokenize.word(b)) do
        if t.text:match("%S") then
            sb[t.text] = (sb[t.text] or 0) + 1
        end
    end
    local total, inter = 0, 0
    for tok, n in pairs(sa) do
        total = total + n
        if sb[tok] then
            inter = inter + math.min(n, sb[tok])
        end
    end
    for _, n in pairs(sb) do
        total = total + n
    end
    if total == 0 then
        return 0.0
    end
    return (2 * inter) / total
end

-- Pair old/new lines by similarity; greedy best-match above threshold
---@param old_lines string[]
---@param new_lines string[]
---@param threshold number
---@return dipher.LinePair[]
function M.pair(old_lines, new_lines, threshold)
    -- TODO: positional fast-path for equal-count hunks; greedy m→n otherwise
    local pairs_out = {}
    local used_new = {}
    for oi, ol in ipairs(old_lines) do
        local best_ni, best_score = nil, threshold
        for ni, nl in ipairs(new_lines) do
            if not used_new[ni] then
                local s = M.similarity(ol, nl)
                if s >= best_score then
                    best_ni, best_score = ni, s
                end
            end
        end
        if best_ni then
            used_new[best_ni] = true
            pairs_out[#pairs_out + 1] = { old = oi, new = best_ni, score = best_score }
        else
            pairs_out[#pairs_out + 1] = { old = oi, new = nil, score = 0 }
        end
    end
    for ni in ipairs(new_lines) do
        if not used_new[ni] then
            pairs_out[#pairs_out + 1] = { old = nil, new = ni, score = 0 }
        end
    end
    return pairs_out
end

return M
