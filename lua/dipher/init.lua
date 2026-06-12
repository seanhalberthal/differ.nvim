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

---@class dipher.DiffSpec
---@field old_text string
---@field new_text string
---@field path string|nil
---@field old_rev string|nil
---@field new_rev string|nil
---@field layout dipher.Layout|nil
---@field context integer|nil

-- Open a diff view for an old/new text pair. The frontends (local git, PR) build
-- their DiffModel from real sources; this is the shared, source-agnostic entry.
---@param spec dipher.DiffSpec
---@return dipher.View
function M.diff(spec)
    require("dipher.ui.highlights").setup()
    local cfg = M.get_config()
    local model = require("dipher.model.diff").build({
        path = spec.path or "",
        old_rev = spec.old_rev or "OLD",
        new_rev = spec.new_rev or "NEW",
        old_text = spec.old_text,
        new_text = spec.new_text,
    })
    local view = require("dipher.view").new(model, {
        layout = spec.layout or cfg.layout,
        context = spec.context or cfg.context,
        deep_diff = cfg.deep_diff,
    })
    return view:open()
end

-- Open a local git diff for the current file from a rev spec (§8.1). The entry
-- point keymaps bind to this — e.g. `require("dipher").open("main...")` for the
-- branch-total diff. A string is one rev token; pass a table for multi-arg forms.
---@param spec string|string[]|nil
---@return dipher.View|nil
function M.open(spec)
    local args = {}
    if type(spec) == "table" then
        args = spec
    elseif type(spec) == "string" and spec ~= "" then
        args = { spec }
    end
    return require("dipher.git").open(args)
end

return M
