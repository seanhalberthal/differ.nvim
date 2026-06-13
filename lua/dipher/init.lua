-- public entry point: setup() and the top-level API surface

local config = require("dipher.config")

local M = {}

---@type dipher.Config|nil
M.config = nil

-- resolve options and register highlight groups; call once from user config
---@param opts table|nil
function M.setup(opts)
    M.config = config.resolve(opts)
    require("dipher.ui.highlights").setup()
end

-- return the resolved config, defaulting if setup() was never called
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

-- open a View from an already-built DiffModel. the git frontend and panel use
-- this; `opts` overrides the layout/context defaults per-view
---@param model dipher.DiffModel
---@param opts { layout?: dipher.Layout, context?: integer }|nil
---@return dipher.View
function M.diff_model(model, opts)
    require("dipher.ui.highlights").setup()
    local cfg = M.get_config()
    opts = opts or {}
    return require("dipher.view")
        .new(model, {
            layout = opts.layout or cfg.layout,
            context = opts.context or cfg.context,
            deep_diff = cfg.deep_diff,
            keymaps = cfg.keymaps,
        })
        :open()
end

-- open a diff view for an old/new text pair. the frontends (local git, PR) build
-- their DiffModel from real sources; this is the shared, source-agnostic entry
---@param spec dipher.DiffSpec
---@return dipher.View
function M.diff(spec)
    local model = require("dipher.model.diff").build({
        path = spec.path or "",
        old_rev = spec.old_rev or "OLD",
        new_rev = spec.new_rev or "NEW",
        old_text = spec.old_text,
        new_text = spec.new_text,
    })
    return M.diff_model(model, { layout = spec.layout, context = spec.context })
end

-- open a local git change set from a rev spec (§8.1), DiffviewOpen-style: the file
-- panel plus the first file's diff. the entry-point keymaps bind to this, e.g.
-- `require("dipher").open("main...")` for the branch-total diff. a string is one
-- rev token; pass a table for multi-arg forms
---@param spec string|string[]|nil
---@return dipher.Panel|nil
function M.open(spec)
    return require("dipher.git").panel({ rev = spec, open_first = true })
end

-- open (or toggle) the file panel over a local git change set (§8.6). `opts` are
-- runtime, not setup config: `rev` (rev spec, string or args), `position`
-- ("bottom"|"top"|"left"|"right"), `listing` ("tree"|"flat"), `height`, `width`.
-- the live panel is reachable via `require("dipher.panel").current()` for runtime
-- tweaks, e.g. `:current():set_position("left")` / `:toggle_listing()`
---@param opts table|nil
---@return dipher.Panel|nil
function M.panel(opts)
    return require("dipher.git").panel(opts or {})
end

-- close the local session, the file panel and the diff view it drives (the `dc`
-- keymap binds to this). mirrors `:DiffviewClose`
function M.close()
    require("dipher.git").close()
end

-- jump-to-file (§8.1, the `de` keymap): from the diff under the cursor, close the
-- session and open the real file on disk at the mapped line. a no-op with a notice
-- when the cursor isn't in a dipher diff
function M.jump_to_file()
    local view = require("dipher.view").current()
    if not view then
        return vim.notify("dipher: no diff view here", vim.log.levels.WARN)
    end
    view:jump_to_file()
end

return M
