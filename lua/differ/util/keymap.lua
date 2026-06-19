-- buffer-local keymap binding from the resolved keymaps config. the one
-- place that understands the action value shape: a string, a list of strings
-- (multiple binds), or false/nil to disable

local M = {}

-- bind `fn` to every lhs in `spec` on `bufnr`. a false/nil spec is a no-op (the action
-- is disabled); a string binds one lhs, a list binds several. `mode` is the keymap mode
-- (a string or list), defaulting to normal; the pr range-comment binds visual ("x")
---@param bufnr integer
---@param spec string|string[]|false|nil
---@param fn fun()
---@param desc string
---@param mode? string|string[]
function M.bind(bufnr, spec, fn, desc, mode)
    if not spec then
        return
    end
    local list = type(spec) == "table" and spec or { spec }
    for _, lhs in ipairs(list) do
        vim.keymap.set(mode or "n", lhs, fn, { buffer = bufnr, desc = desc, nowait = true })
    end
end

return M
