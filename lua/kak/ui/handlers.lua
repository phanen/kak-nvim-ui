local P = require('kak.ui.protocol')
local faces_mod = require('kak.ui.faces')
local popups_mod = require('kak.ui.popups')
local render = require('kak.ui.render')
local cursor_shape = require('kak.ui.cursor')
local statusbar = require('kak.ui.statusbar')

--- Per-session cross-notification state. `refresh` only flips
--- `last_force`; the UI-rendering helpers read it later if they care.
--- `ui_options` lives on the Handlers directly to keep one source of
--- truth for the wire contract.
---@class kak.ui.HandlerContext
---@field last_force boolean

---@class kak.ui.Handlers
---@field ctx kak.ui.HandlerContext
---@field ui_options table<string, any>
---@field surface kak.ui.surface.Surface?
---@field faces kak.ui.faces.Cache
---@field renderer kak.ui.render.Renderer
---@field popups kak.ui.popups.Manager
---@field session kak.ui.Session?
local Handlers = {}

--- Construct a fresh Handlers INSTANCE. Each Kakoune session owns its
--- own dispatch surface (draw / popups / statusbar) so multiple kak
--- clients can coexist in a single nvim without cross-routing.
---@param opts { ctx: kak.ui.HandlerContext, ui_options: table<string, any>, surface?: kak.ui.surface.Surface, session?: kak.ui.Session }
---@return kak.ui.Handlers
function Handlers.new(opts)
  local self = setmetatable({}, { __index = Handlers })
  self.ctx = opts.ctx
  self.ui_options = opts.ui_options
  self.surface = opts.surface
  self.session = opts.session
  self.faces = faces_mod.new({ cap = 512 })
  self.renderer = render.new({ faces = self.faces })
  self.popups = popups_mod.new({
    faces = self.faces,
    renderer = self.renderer,
    surface = opts.surface,
  })
  if opts.surface and opts.surface.content_buf then
    self.renderer:set_buf(opts.surface.content_buf)
  end
  return self
end

function Handlers:draw(raw)
  P.expect_array('draw', raw, 5)
  self.renderer:draw(
    P.parse_lines('draw', raw[1], 1),
    P.parse_coord('draw', raw[2], 2),
    P.parse_face('draw', raw[3], 3),
    P.parse_face('draw', raw[4], 4)
  )
end

--- Parse the Kakoune `draw_status` mode line and return the active
--- Kakoune mode (`normal` / `insert` / `replace`). Substring match
--- against every mode-line atom so wrapped forms like `*insert*` or
--- `[replace]` still register. Replaces a former `==` check that
--- silently broke when users customised `modelinefmt` to drop the
--- `{{mode_info}}` token or wrap the mode in colour codes.
---@param mode_line kak.ui.protocol.Line
---@return 'normal'|'insert'|'replace'
local function detect_mode(mode_line)
  for _, atom in ipairs(mode_line) do
    local c = atom.contents
    if type(c) == 'string' then
      if c:find('replace', 1, true) then return 'replace' end
      if c:find('insert', 1, true) then return 'insert' end
    end
  end
  return 'normal'
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
  -- `content` is a single `Line` (not `Lines`) per the JSON-UI protocol:
  -- `draw_status(Line prompt, Line content, ...)`. Using `parse_lines` here
  -- treated each content atom as a line and silently dropped the typed text.
  local content = P.parse_line('draw_status', raw[2], 2)
  local face = P.parse_face('draw_status', raw[5], 5)
  -- check_enum runs after parsing the face so wire_log_spec's unknown
  -- style test still produces both the 'handler' and 'draw_status'
  -- log lines (the error fires through init.lua's on_notify pcall).
  local style = P.check_enum('draw_status', raw[6] or 'status', valid, 6)
  ---@cast style kak.ui.protocol.DrawStyle
  local mode_line = P.parse_line('draw_status', raw[4], 4)
  -- Track the active Kakoune mode so `_place_cursor` can nudge the real
  -- nvim cursor one cell right in insert/replace (the Kakoune cursor
  -- sits on the just-typed char; we want the block at the insertion
  -- point).
  local mode = detect_mode(mode_line)
  self.renderer.current_mode = mode
  cursor_shape.apply_cursor_shape(mode)
  -- `prompt_active` lets `render._place_cursor` skip the content cursor
  -- while the user is in the command/search/prompt line, so the real
  -- nvim cursor stays in the status float (ui2-style cmdline overlay).
  self.renderer.prompt_active = cursor >= 0
  statusbar.render(
    self.surface,
    self.renderer,
    prompt,
    content,
    cursor,
    mode_line,
    face,
    style,
    self.faces,
    self.session
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
  for k, v in pairs(raw[1]) do
    self.ui_options[k] = v
  end
end

return Handlers
