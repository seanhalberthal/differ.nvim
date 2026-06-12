-- Pure tokenizer for the word-level pass, no Neovim API
-- Word mode keeps [%w_]+ runs whole, so foo_bar and fooBar are single tokens

---@class dipher.Token
---@field text string
---@field col_start integer -- byte col, 0-based inclusive
---@field col_end integer   -- byte col, 0-based exclusive

local M = {}

-- Tokenize into identifier runs, whitespace runs, and single punctuation chars
---@param line string
---@return dipher.Token[]
function M.word(line)
    local tokens = {}
    local i = 1
    local n = #line
    while i <= n do
        local s, e = line:find("[%w_]+", i)
        if s and e and s == i then
            tokens[#tokens + 1] = { text = line:sub(s, e), col_start = s - 1, col_end = e }
            i = e + 1
        else
            local ws_s, ws_e = line:find("%s+", i)
            if ws_s and ws_e and ws_s == i then
                tokens[#tokens + 1] =
                    { text = line:sub(ws_s, ws_e), col_start = ws_s - 1, col_end = ws_e }
                i = ws_e + 1
            else
                tokens[#tokens + 1] = { text = line:sub(i, i), col_start = i - 1, col_end = i }
                i = i + 1
            end
        end
    end
    return tokens
end

-- Tokenize into one token per byte
---@param line string
---@return dipher.Token[]
function M.char(line)
    local tokens = {}
    for i = 1, #line do
        tokens[i] = { text = line:sub(i, i), col_start = i - 1, col_end = i }
    end
    return tokens
end

-- Dispatch to the word or char tokenizer
---@param line string
---@param mode "word"|"char"
---@return dipher.Token[]
function M.tokenize(line, mode)
    return mode == "char" and M.char(line) or M.word(line)
end

return M
