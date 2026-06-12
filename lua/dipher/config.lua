-- Plugin options: defaults, user merge, and shallow validation

---@class dipher.Config
---@field layout dipher.Layout
---@field context integer
---@field deep_diff { enabled: boolean, granularity: "word"|"char", similarity_threshold: number }
---@field comments { inline: boolean, collapsed: boolean }
---@field sidecar_bin string|nil

local M = {}

---@type dipher.Config
M.defaults = {
    layout = "stacked",
    context = 3,
    deep_diff = {
        enabled = true,
        granularity = "word",
        similarity_threshold = 0.5,
    },
    comments = {
        inline = true,
        collapsed = false,
    },
    sidecar_bin = nil,
}

-- Merge user opts over defaults and return the resolved config
---@param user table|nil
---@return dipher.Config
function M.resolve(user)
    return vim.tbl_deep_extend("force", M.defaults, user or {})
end

return M
