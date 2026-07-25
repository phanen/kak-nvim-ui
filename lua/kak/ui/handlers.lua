local P = require('kak.ui.protocol')

---@class kak.ui.HandlerContext
---@field ui_options table<string, any>
---@field last_force boolean

---@class kak.ui.Handlers
---@field ctx kak.ui.HandlerContext
---@field ui_options table<string, any>
---@field surface kak.ui.surface.Surface?
---@field faces kak.ui.faces.Cache
---@field renderer kak.ui.render.Renderer
---@field popups kak.ui.popups.Manager
local Handlers = {}

---@param opts { ctx: kak.ui.HandlerContext, ui_options: table<string, any>, surface?: kak.ui.surface.Surface }
function Handlers.setup(opts)
  Handlers.ctx = opts.ctx
  Handlers.ui_options = opts.ui_options
  Handlers.surface = opts.surface
  Handlers.faces = require('kak.ui.faces').new({ cap = 512 })
  Handlers.renderer = require('kak.ui.render').new({ faces = Handlers.faces })
  Handlers.popups = require('kak.ui.popups').new({
    faces = Handlers.faces,
    renderer = Handlers.renderer,
    surface = opts.surface,
  })
  if opts.surface then
    if opts.surface.content_buf then Handlers.renderer:set_buf(opts.surface.content_buf) end
  end
end

---@return integer
function Handlers:ensure_buf()
  if not self.renderer.content_buf or not vim.api.nvim_buf_is_valid(self.renderer.content_buf) then
    self.renderer:set_buf(vim.api.nvim_create_buf(false, true))
    vim.api.nvim_set_option_value('bufhidden', 'wipe', { buf = self.renderer.content_buf })
    vim.api.nvim_set_option_value('swapfile', false, { buf = self.renderer.content_buf })
  end
  local buf = self.renderer.content_buf
  ---@cast buf integer
  return buf
end

function Handlers:draw(raw)
  P.expect_array('draw', raw, 5)
  self:ensure_buf()
  self.renderer:draw(
    P.parse_lines('draw', raw[1], 1),
    P.parse_coord('draw', raw[2], 2),
    P.parse_face('draw', raw[3], 3),
    P.parse_face('draw', raw[4], 4)
  )
end

function Handlers:draw_status(raw)
  P.expect_array('draw_status', raw, 6)
  local cursor = raw[3]
  if P.absent(cursor) or type(cursor) ~= 'number' then
    error('draw_status: cursor_pos @3 must be integer', 2)
  end
  ---@cast cursor integer
  local valid = { command = true, search = true, prompt = true, status = true }
  local prompt = P.parse_line('draw_status', raw[1], 1)
  local content = P.parse_lines('draw_status', raw[2], 2)
  local face = P.parse_face('draw_status', raw[5], 5)
  -- check_enum runs after parsing the face so wire_log_spec's unknown
  -- style test still produces both the 'handler' and 'draw_status'
  -- log lines (the error fires through init.lua's on_notify pcall).
  local style = P.check_enum('draw_status', raw[6] or 'status', valid, 6)
  ---@cast style kak.ui.protocol.DrawStyle
  require('kak.ui.statusbar').render(
    self.surface,
    prompt,
    content,
    cursor,
    P.parse_line('draw_status', raw[4], 4),
    face,
    style,
    self.faces
  )
end

function Handlers:menu_show(raw)
  P.expect_array('menu_show', raw, 5)
  local style =
    P.check_enum('menu_show', raw[5], { prompt = true, search = true, inline = true }, 5)
  ---@cast style kak.ui.protocol.MenuStyle
  self.popups:menu_show(
    P.parse_lines('menu_show', raw[1], 1),
    P.parse_coord('menu_show', raw[2], 2),
    P.parse_face('menu_show', raw[3], 3),
    P.parse_face('menu_show', raw[4], 4),
    style
  )
end

function Handlers:menu_select(raw)
  P.expect_array('menu_select', raw, 1)
  if type(raw[1]) ~= 'number' then error('menu_select: expected int, got ' .. type(raw[1]), 2) end
  self.popups:menu_select(raw[1])
end

function Handlers:menu_hide(raw)
  if raw and #raw > 0 then error('menu_hide: expected no params', 2) end
  self.popups:menu_hide()
end

function Handlers:info_show(raw)
  P.expect_array('info_show', raw, 5)
  local style = P.check_enum('info_show', raw[5], {
    prompt = true,
    inline = true,
    inlineAbove = true,
    inlineBelow = true,
    menuDoc = true,
    modal = true,
  }, 5)
  ---@cast style kak.ui.protocol.InfoStyle
  self.popups:info_show(
    P.parse_line('info_show', raw[1], 1),
    P.parse_lines('info_show', raw[2], 2),
    P.parse_coord('info_show', raw[3], 3),
    P.parse_face('info_show', raw[4], 4),
    style
  )
end

function Handlers:info_hide(raw)
  if raw and #raw > 0 then error('info_hide: expected no params', 2) end
  self.popups:info_hide()
end

function Handlers:refresh(raw)
  P.expect_array('refresh', raw, 1)
  if type(raw[1]) ~= 'boolean' then error('refresh: expected bool', 2) end
  self.ctx.last_force = raw[1]
end

function Handlers:set_ui_options(raw)
  P.expect_array('set_ui_options', raw, 1)
  if P.absent(raw[1]) or type(raw[1]) ~= 'table' then
    error('set_ui_options: expected object of key/value', 2)
  end
  self.ctx.ui_options = raw[1]
  for k, v in pairs(raw[1]) do
    self.ui_options[k] = v
  end
end

return Handlers
