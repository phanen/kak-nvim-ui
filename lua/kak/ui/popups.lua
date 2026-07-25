---
--- Renders Kakoune `menu_show` / `info_show` popups.
--- Short inline menus / search results use extmark `virt_text` in the main
--- buffer. Longer menus, prompt menus, modal info, and menuDoc use floating
--- windows (`nvim_open_win`).
---
--- Lifecycle: `menu_show` / `info_show` create a window, `*_select` updates
--- the highlighted entry, `*_hide` closes the window.
---
--- Per-atom faces: Kakoune's terminal UI merges each atom face with the
--- line base (`menu_bg` / `menu_fg` for menus, the single `face` for info)
--- via `Face::merge_faces`. The JSON UI sends raw atoms plus a separate
--- line base, so we mirror that merge here via `faces.merge`. Without
--- this, popup content collapses to a single colour and inline
--- highlights (matched chars in completions, type colouring in `:%sh`
--- output, etc.) are lost.

---@alias kak.ui.popups.MenuKind
---| 'float'
---| 'inline'

---@alias kak.ui.popups.InfoKind
---| 'float'
---| 'inline'

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

---@alias kak.ui.popups.MenuState kak.ui.popups.MenuStateFloat|kak.ui.popups.MenuStateInline

---@class kak.ui.popups.InfoStateBase
---@field style kak.ui.protocol.InfoStyle

---@class kak.ui.popups.InfoStateFloat : kak.ui.popups.InfoStateBase
---@field kind 'float'
---@field buf integer
---@field win integer

---@class kak.ui.popups.InfoStateInline : kak.ui.popups.InfoStateBase
---@field row integer
---@field col integer

---@alias kak.ui.popups.InfoState kak.ui.popups.InfoStateFloat|kak.ui.popups.InfoStateInline

---@class kak.ui.popups.Manager
---@field faces kak.ui.faces.Cache
---@field renderer kak.ui.render.Renderer
---@field menu_state kak.ui.popups.MenuState?
---@field info_state kak.ui.popups.InfoState?
---@field float_ns integer
---@field menu_show fun(self: kak.ui.popups.Manager, items: kak.ui.protocol.Lines, anchor: kak.ui.protocol.Coord, fg: kak.ui.faces.Face?, bg: kak.ui.faces.Face?, style: kak.ui.protocol.MenuStyle)
---@field menu_select fun(self: kak.ui.popups.Manager, selected: integer)
---@field menu_hide fun(self: kak.ui.popups.Manager)
---@field info_show fun(self: kak.ui.popups.Manager, title: kak.ui.protocol.Line, content: kak.ui.protocol.Lines, anchor: kak.ui.protocol.Coord, face: kak.ui.faces.Face?, style: kak.ui.protocol.InfoStyle)
---@field info_hide fun(self: kak.ui.popups.Manager)

local M = {}

local INLINE_MAX_ITEMS = 12

local faces = require('kak.ui.faces')

---@param line kak.ui.protocol.Line
---@return string
local function line_to_text(line)
  local parts = {}
  for _, atom in ipairs(line) do
    parts[#parts + 1] = atom.contents or ''
  end
  return table.concat(parts)
end

--- Build virt_text-style chunks where each atom gets a merged face.
--- Empty atoms are skipped so empty padding never widens the chunk list.
---@param line kak.ui.protocol.Line
---@param base kak.ui.faces.Face?
---@param cache kak.ui.faces.Cache
---@return { [1]: string, [2]: string }[]
local function line_to_chunks(line, base, cache)
  local chunks = {}
  for _, atom in ipairs(line) do
    local text = atom.contents or ''
    if text ~= '' then
      local merged = faces.merge(base, atom.face)
      chunks[#chunks + 1] = { text, cache:get(merged) }
    end
  end
  return chunks
end

--- Apply per-atom extmark highlights in the float buffer at row `i`.
--- Skips atoms that resolve to the float's winhighlight (no-op visually)
--- but still writes the extmark so future face changes don't repaint
--- stale regions.
---@param buf integer
---@param ns integer
---@param i integer 0-based row
---@param line kak.ui.protocol.Line
---@param base kak.ui.faces.Face?
---@param cache kak.ui.faces.Cache
local function apply_atom_extmarks(buf, ns, i, line, base, cache)
  local byte = 0
  for _, atom in ipairs(line) do
    local s = atom.contents or ''
    if s ~= '' then
      local end_byte = byte + #s
      local merged = faces.merge(base, atom.face)
      local hl = cache:get(merged)
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, i, byte, {
        end_col = end_byte,
        hl_group = hl,
        right_gravity = false,
      })
      byte = end_byte
    end
  end
end

local Manager = {}
Manager.__index = Manager

---@param opts { faces: kak.ui.faces.Cache, renderer: kak.ui.render.Renderer }
---@return kak.ui.popups.Manager
function M.new(opts)
  return setmetatable({
    faces = opts.faces,
    renderer = opts.renderer,
    menu_state = nil,
    info_state = nil,
    float_ns = vim.api.nvim_create_namespace('kak.ui.popups'),
  }, Manager)
end

---@param items kak.ui.protocol.Lines
---@param anchor kak.ui.protocol.Coord
---@param fg kak.ui.faces.Face?
---@param bg kak.ui.faces.Face?
---@param style kak.ui.protocol.MenuStyle
---@return kak.ui.popups.MenuKind
function Manager:_show_menu(items, anchor, fg, bg, style)
  self:menu_hide()

  local use_float = style ~= 'search' and (style == 'prompt' or #items > INLINE_MAX_ITEMS)

  if use_float then return self:_show_menu_float(items, anchor, fg, bg, style) end
  return self:_show_menu_inline(items, anchor, fg, bg, style)
end

---@param items kak.ui.protocol.Lines
---@param anchor kak.ui.protocol.Coord
---@param fg kak.ui.faces.Face?
---@param bg kak.ui.faces.Face?
---@param style kak.ui.protocol.MenuStyle
---@return kak.ui.popups.MenuKind
function Manager:_show_menu_float(items, anchor, fg, bg, style)
  local renderer = self.renderer
  if not renderer or not renderer.content_buf then return 'float' end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value('modifiable', true, { buf = buf })
  local lines = {}
  for _, item in ipairs(items) do
    lines[#lines + 1] = line_to_text(item)
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value('modifiable', false, { buf = buf })

  local bg_hl = self.faces:get(bg)
  local editor_w = vim.o.columns or 120
  local editor_h = vim.o.lines or 40
  local width = 0
  for _, l in ipairs(lines) do
    if #l > width then width = #l end
  end
  local win_h = math.min(#lines, 20)

  -- `prompt` sits at the bottom of the editor (completion menu); everything
  -- else floats just below the matched row.
  local win_anchor
  local row
  local col
  if style == 'prompt' then
    win_anchor = 'SW'
    row = editor_h
    col = math.max(0, math.floor(editor_w / 2))
  else
    win_anchor = 'NW'
    local total = vim.api.nvim_buf_line_count(renderer.content_buf)
    local base = math.max(0, math.min(anchor.line, total - 1))
    local row_offset = style == 'search' and 1 or 0
    ---@cast base integer
    ---@cast editor_h integer
    ---@cast row_offset integer
    ---@cast win_h integer
    row = math.max(0, math.min(base + 1 + row_offset, editor_h - win_h - 2))
    col = 0
  end
  ---@cast row integer
  ---@cast col integer

  ---@type vim.api.keyset.win_config
  local config = {
    relative = 'editor',
    anchor = win_anchor,
    style = 'minimal',
    width = math.max(width + 2, 4),
    height = win_h,
    row = row,
    col = col,
    border = 'single',
    focusable = false,
    noautocmd = true,
  }
  local win = vim.api.nvim_open_win(buf, false, config)
  vim.api.nvim_set_option_value('winhighlight', 'Normal:' .. bg_hl, { win = win })

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
function Manager:_show_menu_inline(items, anchor, fg, bg, style)
  local renderer = self.renderer
  if not renderer or not renderer.content_buf then return 'inline' end
  ---@type kak.ui.popups.MenuStateInline
  local inline_state = {
    kind = 'inline',
    items = items,
    fg = fg,
    bg = bg,
    anchor = anchor,
    selected = -1,
    style = style,
  }
  self.menu_state = inline_state
  local buf = renderer.content_buf
  local total = vim.api.nvim_buf_line_count(buf)
  ---@cast anchor.line integer
  local row = math.max(0, math.min(anchor.line, total - 1))
  ---@cast row integer
  vim.api.nvim_buf_clear_namespace(buf, self.float_ns, 0, -1)
  for i, item in ipairs(items) do
    local line_base = bg
    local chunks = line_to_chunks(item, line_base, self.faces)
    vim.api.nvim_buf_set_extmark(buf, self.float_ns, row, anchor.column or 0, {
      virt_text = chunks,
      virt_text_pos = 'eol',
      hl_mode = 'combine',
      right_gravity = false,
      id = 1000 + i,
    })
  end
  return 'inline'
end

---@param items kak.ui.protocol.Lines
---@param anchor kak.ui.protocol.Coord
---@param fg kak.ui.faces.Face?
---@param bg kak.ui.faces.Face?
---@param style kak.ui.protocol.MenuStyle
function Manager:menu_show(items, anchor, fg, bg, style)
  self:_show_menu(items, anchor, fg, bg, style)
end

---@param selected integer
function Manager:menu_select(selected)
  local state = self.menu_state
  if not state then return end
  state.selected = selected
  if state.kind == 'float' then
    local buf = state.buf
    vim.api.nvim_buf_clear_namespace(buf, self.float_ns, 0, -1)
    for i, item in ipairs(state.items) do
      local line_base = (i == selected + 1) and state.fg or state.bg
      apply_atom_extmarks(buf, self.float_ns, i - 1, item, line_base, self.faces)
    end
  else
    local renderer = self.renderer
    if not renderer or not renderer.content_buf then return end
    local buf = renderer.content_buf
    local total = vim.api.nvim_buf_line_count(buf)
    local anchor = state.anchor or { line = 0, column = 0 }
    local row = math.max(0, math.min(anchor.line, total - 1))
    ---@cast row integer
    vim.api.nvim_buf_clear_namespace(buf, self.float_ns, 0, -1)
    for i, item in ipairs(state.items) do
      local line_base = (i == selected + 1) and state.fg or state.bg
      local chunks = line_to_chunks(item, line_base, self.faces)
      vim.api.nvim_buf_set_extmark(buf, self.float_ns, row, anchor.column or 0, {
        virt_text = chunks,
        virt_text_pos = 'eol',
        hl_mode = 'combine',
        right_gravity = false,
        id = 1000 + i,
      })
    end
  end
end

function Manager:menu_hide()
  local state = self.menu_state
  if not state then return end
  if state.kind == 'float' and state.win and vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  local renderer = self.renderer
  if renderer and renderer.content_buf and vim.api.nvim_buf_is_valid(renderer.content_buf) then
    vim.api.nvim_buf_clear_namespace(renderer.content_buf, self.float_ns, 0, -1)
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
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value('modifiable', true, { buf = buf })
  local lines = { line_to_text(title) }
  local source = { title }
  for _, line in ipairs(content) do
    lines[#lines + 1] = line_to_text(line)
    source[#source + 1] = line
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value('modifiable', false, { buf = buf })

  local editor_w = vim.o.columns or 120
  local editor_h = vim.o.lines or 40
  local maxw = 0
  for _, l in ipairs(lines) do
    local n = vim.fn.strdisplaywidth(l)
    if n > maxw then maxw = n end
  end
  local width = math.min(maxw + 2, math.max(20, math.floor(editor_w / 2)))
  local height = math.min(#lines, math.max(5, math.floor(editor_h / 3)))

  local win_anchor
  local row
  local col
  if style == 'modal' then
    win_anchor = 'NW'
    row = math.max(0, math.floor((editor_h - height) / 2) - 1)
    col = math.max(0, math.floor((editor_w - width) / 2))
  elseif style == 'menuDoc' then
    local renderer = self.renderer
    local total = (renderer and renderer.content_buf)
        and vim.api.nvim_buf_line_count(renderer.content_buf)
      or editor_h
    local menu_row = anchor and anchor.line or 0
    local base = math.max(0, math.min(menu_row, total - 1))
    ---@cast base integer
    ---@cast editor_h integer
    ---@cast height integer
    win_anchor = 'NE'
    row = math.min(base + 1, editor_h - height - 2)
    col = editor_w
  else
    -- `prompt` style (help popup): strict bottom-right corner of editor,
    -- mirroring kakoune's terminal UI which aligns the info box's right
    -- edge with the rightmost column.
    win_anchor = 'SE'
    row = editor_h
    col = editor_w
  end
  ---@cast row integer
  ---@cast col integer

  local hl = self.faces:get(face)
  ---@type vim.api.keyset.win_config
  local config = {
    relative = 'editor',
    anchor = win_anchor,
    style = 'minimal',
    width = width,
    height = height,
    row = row,
    col = col,
    border = 'single',
    focusable = style == 'modal',
    noautocmd = true,
  }
  local win = vim.api.nvim_open_win(buf, style == 'modal', config)
  pcall(vim.api.nvim_set_option_value, 'winhighlight', 'Normal:' .. hl, { win = win })

  -- Per-atom highlights: every atom face is merged with the info face
  -- so colours specified inside `content` lines survive.
  for i, line in ipairs(source) do
    apply_atom_extmarks(buf, self.float_ns, i - 1, line, face, self.faces)
  end

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
  local renderer = self.renderer
  if not renderer or not renderer.content_buf then return 'inline' end
  local buf = renderer.content_buf
  local total = vim.api.nvim_buf_line_count(buf)
  local row = math.max(0, math.min(anchor.line, total - 1))
  ---@cast row integer
  vim.api.nvim_buf_clear_namespace(buf, self.float_ns, 0, -1)
  local order = style == 'inlineAbove' and -1 or 1
  ---@cast order integer
  local base_row = math.max(0, math.min(row + order, total - 1))
  ---@cast base_row integer
  local col = anchor.column or 0
  ---@cast col integer
  vim.api.nvim_buf_set_extmark(buf, self.float_ns, base_row, col, {
    virt_text = line_to_chunks(title, face, self.faces),
    virt_text_pos = 'eol',
    hl_mode = 'combine',
    right_gravity = false,
    id = 2000,
  })
  for i, line in ipairs(content) do
    local r = math.max(0, math.min(base_row + i * order, total - 1))
    ---@cast r integer
    vim.api.nvim_buf_set_extmark(buf, self.float_ns, r, col, {
      virt_text = line_to_chunks(line, face, self.faces),
      virt_text_pos = 'eol',
      hl_mode = 'combine',
      right_gravity = false,
      id = 2000 + i,
    })
  end
  self.info_state = { kind = 'inline', row = base_row, col = col }
  return 'inline'
end

function Manager:info_hide()
  local state = self.info_state
  if not state then return end
  if state.kind == 'float' and state.win and vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  local renderer = self.renderer
  if renderer and renderer.content_buf and vim.api.nvim_buf_is_valid(renderer.content_buf) then
    vim.api.nvim_buf_clear_namespace(renderer.content_buf, self.float_ns, 0, -1)
  end
  self.info_state = nil
end

Manager._Manager = Manager
---@type fun(line: kak.ui.protocol.Line, base: kak.ui.faces.Face?, cache: kak.ui.faces.Cache): { [1]: string, [2]: string }[]
M._line_to_chunks = line_to_chunks
---@type fun(buf: integer, ns: integer, i: integer, line: kak.ui.protocol.Line, base: kak.ui.faces.Face?, cache: kak.ui.faces.Cache)
M._apply_atom_extmarks = apply_atom_extmarks
return M
