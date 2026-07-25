---
--- Renders Kakoune `menu_show` / `info_show` popups.
---
--- This module is a thin orchestrator: it holds the manager state,
--- delegates positioning to `popups.layout`, extmark rendering to
--- `popups.inline`, and `nvim_open_win` plumbing to `popups.float`.
---
--- Per-atom faces: Kakoune's terminal UI merges each atom face with
--- the line base (`menu_bg` / `menu_fg` for menus, the single `face`
--- for info) via `Face::merge_faces`. The JSON UI sends raw atoms
--- plus a separate line base, so we mirror that merge here via
--- `faces.merge`.

---@alias kak.ui.popups.MenuKind 'float' | 'inline'
---@alias kak.ui.popups.InfoKind 'float' | 'inline'

---@class kak.ui.popups.MenuStateBase
---@field items kak.ui.protocol.Lines
---@field fg kak.ui.faces.Face?
---@field bg kak.ui.faces.Face?
---@field style kak.ui.protocol.MenuStyle
---@field selected integer

---@class kak.ui.popups.MenuStateFloat : kak.ui.popups.MenuStateBase
---@field kind 'float'
---@field buf integer
---@field win integer
---@field anchor kak.ui.protocol.Coord

---@class kak.ui.popups.MenuStateInline : kak.ui.popups.MenuStateBase
---@field kind 'inline'
---@field anchor kak.ui.protocol.Coord?

---@alias kak.ui.popups.MenuState kak.ui.popups.MenuStateFloat | kak.ui.popups.MenuStateInline

---@class kak.ui.popups.InfoStateBase
---@field style kak.ui.protocol.InfoStyle

---@class kak.ui.popups.InfoStateFloat : kak.ui.popups.InfoStateBase
---@field kind 'float'
---@field buf integer
---@field win integer

---@class kak.ui.popups.InfoStateInline : kak.ui.popups.InfoStateBase
---@field row integer
---@field col integer

---@alias kak.ui.popups.InfoState kak.ui.popups.InfoStateFloat | kak.ui.popups.InfoStateInline

---@class kak.ui.popups.Manager
---@field faces kak.ui.faces.Cache
---@field renderer kak.ui.render.Renderer
---@field surface kak.ui.surface.Surface?
---@field menu_state kak.ui.popups.MenuState?
---@field info_state kak.ui.popups.InfoState?
---@field float_ns integer
---@field menu_show fun(self: kak.ui.popups.Manager, items: kak.ui.protocol.Lines, anchor: kak.ui.protocol.Coord, fg: kak.ui.faces.Face?, bg: kak.ui.faces.Face?, style: kak.ui.protocol.MenuStyle)
---@field menu_select fun(self: kak.ui.popups.Manager, selected: integer)
---@field menu_hide fun(self: kak.ui.popups.Manager)
---@field info_show fun(self: kak.ui.popups.Manager, title: kak.ui.protocol.Line, content: kak.ui.protocol.Lines, anchor: kak.ui.protocol.Coord, face: kak.ui.faces.Face?, style: kak.ui.protocol.InfoStyle)
---@field info_hide fun(self: kak.ui.popups.Manager)
---@field reset fun(self: kak.ui.popups.Manager)
---@field close fun(self: kak.ui.popups.Manager)
---@field _menu_rect fun(self: kak.ui.popups.Manager): kak.ui.popups.layout.Rect?

local layout = require('kak.ui.popups.layout')
local inline = require('kak.ui.popups.inline')
local float = require('kak.ui.popups.float')

local M = {}

local MENU_MAX_HEIGHT = 20

local Manager = {}
Manager.__index = Manager

---@param opts { faces: kak.ui.faces.Cache, renderer: kak.ui.render.Renderer, surface?: kak.ui.surface.Surface }
---@return kak.ui.popups.Manager
function M.new(opts)
  assert(opts.faces, 'popups.new: faces required')
  assert(opts.renderer, 'popups.new: renderer required')
  return setmetatable({
    faces = opts.faces,
    renderer = opts.renderer,
    surface = opts.surface,
    menu_state = nil,
    info_state = nil,
    float_ns = vim.api.nvim_create_namespace('kak.ui.popups'),
  }, Manager)
end

--- Read editor dims from the surface (preferred) or fall back to
--- `vim.o.{lines,columns}`.
---@return { width: integer, height: integer }?
function Manager:editor_dims()
  if self.surface then return self.surface:editor_dims() end
  return { width = vim.o.columns or 120, height = vim.o.lines or 40 }
end

--- Active menu rect (pos + size in editor-relative coords), or nil.
---@return kak.ui.popups.layout.Rect?
function Manager:_menu_rect()
  local s = self.menu_state
  if not s or s.kind ~= 'float' then return nil end
  if not vim.api.nvim_win_is_valid(s.win) then return nil end
  local cfg = vim.api.nvim_win_get_config(s.win)
  local row = assert(cfg.row) ---@as integer
  local col = assert(cfg.col) ---@as integer
  local h = assert(cfg.height) ---@as integer
  local w = assert(cfg.width) ---@as integer
  return {
    pos = { line = row, column = col },
    size = { line = h, column = w },
  }
end

---@param items kak.ui.protocol.Lines
---@param anchor kak.ui.protocol.Coord
---@param fg kak.ui.faces.Face?
---@param bg kak.ui.faces.Face?
---@param style kak.ui.protocol.MenuStyle
function Manager:menu_show(items, anchor, fg, bg, style)
  self:menu_hide()

  local kind = layout.choose_float_or_inline(style, #items)
  if kind == 'inline' then return self:_menu_inline(items, anchor, fg, bg, style) end
  return self:_menu_float(items, anchor, fg, bg, style)
end

---@param items kak.ui.protocol.Lines
---@param anchor kak.ui.protocol.Coord
---@param fg kak.ui.faces.Face?
---@param bg kak.ui.faces.Face?
---@param style kak.ui.protocol.MenuStyle
---@return kak.ui.popups.MenuKind
function Manager:_menu_float(items, anchor, fg, bg, style)
  local items_w = layout.items_max_width(items)
  local geom = layout.menu_pos(
    style,
    anchor,
    self.renderer.content_buf,
    self:editor_dims(),
    math.min(#items, MENU_MAX_HEIGHT),
    math.max(items_w, 1)
  )
  local buf, win = float.open_menu(items, bg, geom, self.faces)
  self.menu_state = {
    kind = 'float',
    buf = buf,
    win = win,
    items = items,
    fg = fg,
    bg = bg,
    style = style,
    anchor = anchor,
    selected = -1,
  }
  return 'float'
end

---@param items kak.ui.protocol.Lines
---@param anchor kak.ui.protocol.Coord
---@param fg kak.ui.faces.Face?
---@param bg kak.ui.faces.Face?
---@param style kak.ui.protocol.MenuStyle
---@return kak.ui.popups.MenuKind
function Manager:_menu_inline(items, anchor, fg, bg, style)
  self.menu_state = {
    kind = 'inline',
    items = items,
    fg = fg,
    bg = bg,
    anchor = anchor,
    selected = -1,
    style = style,
  }
  inline.render_menu(
    self.renderer.content_buf,
    self.float_ns,
    anchor,
    items,
    fg,
    bg,
    self.faces,
    -1
  )
  return 'inline'
end

---@param selected integer
function Manager:menu_select(selected)
  local state = self.menu_state
  if not state then return end
  state.selected = selected
  if state.kind == 'float' then
    float.repaint_menu(
      self.float_ns,
      state.buf,
      state.items,
      state.fg,
      state.bg,
      selected,
      self.faces
    )
    return
  end
  local renderer = self.renderer
  if not renderer or not renderer.content_buf then return end
  inline.render_menu(
    renderer.content_buf,
    self.float_ns,
    state.anchor or { line = 0, column = 0 },
    state.items,
    state.fg,
    state.bg,
    self.faces,
    selected
  )
end

function Manager:menu_hide()
  local state = self.menu_state
  if not state then return end
  if state.kind == 'float' and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  local renderer = self.renderer
  if renderer and renderer.content_buf and vim.api.nvim_buf_is_valid(renderer.content_buf) then
    inline.clear(renderer.content_buf, self.float_ns)
  end
  self.menu_state = nil
end

---@param title kak.ui.protocol.Line
---@param content kak.ui.protocol.Lines
---@param anchor kak.ui.protocol.Coord
---@param face kak.ui.faces.Face?
---@param style kak.ui.protocol.InfoStyle
function Manager:info_show(title, content, anchor, face, style)
  self:info_hide()

  if style == 'inline' or style == 'inlineAbove' or style == 'inlineBelow' then
    self:_info_inline(title, content, anchor, face, style)
    return
  end
  if style == 'prompt' or style == 'modal' or style == 'menuDoc' then
    self:_info_float(title, content, anchor, face, style)
    return
  end
end

---@param title kak.ui.protocol.Line
---@param content kak.ui.protocol.Lines
---@param anchor kak.ui.protocol.Coord
---@param face kak.ui.faces.Face?
---@param style kak.ui.protocol.InfoStyle
---@return kak.ui.popups.InfoKind
function Manager:_info_float(title, content, anchor, face, style)
  local geom0 = layout.info_pos(style, anchor, nil, self:editor_dims())
  local geom =
    layout.info_geom(style, geom0, anchor, self:_menu_rect(), title, content, self:editor_dims())
  local focusable = (style == 'modal')
  local buf, win =
    float.open_info(self.float_ns, title, content, face, style, geom, focusable, self.faces)
  self.info_state = { kind = 'float', buf = buf, win = win, style = style }
  return 'float'
end

---@param title kak.ui.protocol.Line
---@param content kak.ui.protocol.Lines
---@param anchor kak.ui.protocol.Coord
---@param face kak.ui.faces.Face?
---@param style kak.ui.protocol.InfoStyle
---@return kak.ui.popups.InfoKind
function Manager:_info_inline(title, content, anchor, face, style)
  inline.render_info(
    self.renderer.content_buf,
    self.float_ns,
    anchor,
    title,
    content,
    face,
    style,
    self.faces
  )
  local geom = layout.info_pos(style, anchor, self.renderer.content_buf, self:editor_dims())
  self.info_state = { kind = 'inline', row = geom.row, col = anchor.column or 0 }
  return 'inline'
end

function Manager:info_hide()
  local state = self.info_state
  if not state then return end
  if state.kind == 'float' and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  inline.clear(self.renderer.content_buf, self.float_ns)
  self.info_state = nil
end

--- Full cleanup: hide menu + info, clear all extmarks. Safe to call
--- multiple times. Wired into `Connection:on_exit` via the session
--- lifecycle.
function Manager:reset()
  self:menu_hide()
  self:info_hide()
end

--- Alias of `reset`. Provided so the session lifecycle hook
--- (`conn:on_exit` -> `sess:close()`) can drop all popups before
--- detaching the surface.
function Manager:close() self:reset() end

--- Module-level re-exports kept so `test/popups_spec.lua` (which
--- exercises `popups._line_to_chunks` and `popups._apply_atom_extmarks`
--- directly) continues to pass.
M._line_to_chunks = inline._line_to_chunks
M._apply_atom_extmarks = inline._apply_atom_extmarks

return M
