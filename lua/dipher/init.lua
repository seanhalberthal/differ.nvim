-- Public entry point: setup() and the top-level API surface

local config = require("dipher.config")

local M = {}

---@type dipher.Config|nil
M.config = nil

-- Resolve options and register highlight groups; call once from user config
---@param opts table|nil
function M.setup(opts)
    M.config = config.resolve(opts)
    require("dipher.ui.highlights").setup()
end

-- Return the resolved config, defaulting if setup() was never called
---@return dipher.Config
function M.get_config()
    return M.config or config.defaults
end

return M
