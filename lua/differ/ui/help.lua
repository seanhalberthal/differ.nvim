-- floating keymap cheatsheet shared by the panel, history and diff surfaces.
-- takes prebuilt lines (each " lhs   desc") and opens a centred minimal float,
-- dismissed with q / <Esc> / g? (or the caller's own dismiss keys)

local M = {}

---@param lines string[]
---@param opts? { title?: string, dismiss?: string[] }
function M.show(lines, opts)
    opts = opts or {}
    local width = 0
    for _, l in ipairs(lines) do
        width = math.max(width, #l)
    end
    -- one blank row of breathing space above and below the keymap rows
    local padded = { "" }
    vim.list_extend(padded, lines)
    padded[#padded + 1] = ""
    lines = padded
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].bufhidden = "wipe"
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width + 1,
        height = #lines,
        row = math.floor((vim.o.lines - #lines) / 2),
        col = math.floor((vim.o.columns - width) / 2),
        style = "minimal",
        border = "rounded",
        title = opts.title or " Differ ",
    })
    local function close()
        if vim.api.nvim_win_is_valid(win) then
            pcall(vim.api.nvim_win_close, win, true)
        end
    end
    for _, lhs in ipairs(opts.dismiss or { "q", "<Esc>", "g?" }) do
        vim.keymap.set("n", lhs, close, { buffer = buf, nowait = true })
    end
end

return M
