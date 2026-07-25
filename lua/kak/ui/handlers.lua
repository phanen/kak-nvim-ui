---
--- Notification handlers for Kakoune JSON-UI messages.
---
--- Pure data: `handlers.build` returns the `h` table that the JSON-RPC
--- dispatcher routes notifications to. No module-level side effects
--- beyond construction so the handlers can be reconstructed per-session
--- without leaking autocmds or globals.
---
--- Handler wires the protocol decoder output onto the renderer + popup
--- manager:
---   * `draw`         -> Renderer:draw (display lines + cursor)
---   * `draw_status`  -> Renderer:draw_mode (mode line) +
---                       Renderer:set_prompt (prompt state, no-op UI)
---   * `menu_*`       -> popups.Manager
---   * `info_*`       -> popups.Manager
---   * `refresh`      -> ctx.last_force bookkeeping
---   * `set_ui_options` -> ctx.ui_options + ui_options map merge

---@class kak.ui.HandlerContext
---@field ui_options table<string, any>
---@field last_force boolean

---@class kak.ui.RenderHandlers
---@field handlers table<string, function>
---@field renderer kak.ui.render.Renderer
---@field faces kak.ui.faces.Cache
---@field popups kak.ui.popups.Manager
---@field ensure_buf fun(): integer

---@param ctx kak.ui.HandlerContext
---@param ui_options table<string, any>
---@param surface? kak.ui.surface.Surface
---@param rpc? kak.ui.json_rpc.Connection
---@return kak.ui.RenderHandlers
local function build(ctx, ui_options, surface, rpc)
  ---@cast rpc -nil
  -- face_cache_size is exposed via set_ui_options only after this is
  -- built, so cap is fixed at construction time.
  local face_cache = require('kak.ui.faces').new({ cap = 512 })
  local renderer = require('kak.ui.render').new({ faces = face_cache })
  local popup_mgr = require('kak.ui.popups').new({
    faces = face_cache,
    renderer = renderer,
    surface = surface,
  })

  -- Attach the surface-owned buffers to the renderer. After this point
  -- the renderer mutates the same buffer the user sees in their tab.
  if surface then
    if surface.content_buf then renderer:set_buf(surface.content_buf) end
    if surface.mode_buf then renderer:set_mode_buf(surface.mode_buf) end
  end

  local function ensure_buf()
    if not renderer.content_buf or not vim.api.nvim_buf_is_valid(renderer.content_buf) then
      renderer:set_buf(vim.api.nvim_create_buf(false, true))
      vim.api.nvim_set_option_value('bufhidden', 'wipe', { buf = renderer.content_buf })
      vim.api.nvim_set_option_value('swapfile', false, { buf = renderer.content_buf })
    end
    if not renderer.mode_buf or not vim.api.nvim_buf_is_valid(renderer.mode_buf) then
      renderer:set_mode_buf(vim.api.nvim_create_buf(false, true))
      vim.api.nvim_set_option_value('bufhidden', 'wipe', { buf = renderer.mode_buf })
      vim.api.nvim_set_option_value('swapfile', false, { buf = renderer.mode_buf })
    end
    return renderer.content_buf
  end

  local h = {}
  h.draw = function(p)
    ensure_buf()
    renderer:draw(p.lines, p.cursor_pos, p.default_face, p.padding_face)
  end
  h.draw_status = function(p)
    ensure_buf()
    renderer:draw_mode(p.mode_line, p.default_face)
    renderer:set_prompt(p.prompt, p.content, p.cursor_pos, p.default_face, p.style)
  end
  h.menu_show = function(p) popup_mgr:menu_show(p.items, p.anchor, p.fg, p.bg, p.style) end
  h.menu_select = function(p) popup_mgr:menu_select(p.selected) end
  h.menu_hide = function() popup_mgr:menu_hide() end
  h.info_show = function(p) popup_mgr:info_show(p.title, p.content, p.anchor, p.face, p.style) end
  h.info_hide = function() popup_mgr:info_hide() end
  h.refresh = function(p) ctx.last_force = p.force and true or false end
  h.set_ui_options = function(p)
    ctx.ui_options = p.options
    for k, v in pairs(p.options) do
      ui_options[k] = v
    end
  end

  return {
    handlers = h,
    renderer = renderer,
    faces = face_cache,
    popups = popup_mgr,
    ensure_buf = ensure_buf,
  }
end

return { build = build }
