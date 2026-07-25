---
--- Renders Kakoune `menu_show` / `info_show` popups.
--- Short inline menus / search results use extmark `virt_text` in the main
--- buffer. Longer menus, prompt menus, modal info, and menuDoc use floating
--- windows (`nvim_open_win`).
---
--- Lifecycle: `menu_show` / `info_show` create a window, `*_select` updates
--- the highlighted entry, `*_hide` closes the window.

local M = {}

local INLINE_MAX_ITEMS = 12

local function line_to_text(line)
  local parts = {}
  for _, atom in ipairs(line) do
    parts[#parts + 1] = atom.contents or ''
  end
  return table.concat(parts)
end

--- @class kak.ui.popups.Manager
local Manager = {}
Manager.__index = Manager

function M.new(opts)
  return setmetatable({
    faces = opts.faces,
    renderer = opts.renderer,
    menu_state = nil,
    info_state = nil,
    float_ns = vim.api.nvim_create_namespace('kak.ui.popups'),
  }, Manager)
end

function Manager:_show_menu(items, anchor, fg, bg, style)
  self:menu_hide()

  local use_float = style ~= 'search' and (style == 'prompt' or #items > INLINE_MAX_ITEMS)

  if use_float then return self:_show_menu_float(items, anchor, fg, bg, style) end
  return self:_show_menu_inline(items, anchor, fg, bg, style)
end

function Manager:_show_menu_float(items, anchor, fg, bg, style)
  if not self.renderer or not self.renderer.content_buf then return 'float' end
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
  local win_anchor, row, col
  if style == 'prompt' then
    win_anchor = 'SW'
    row = editor_h
    col = math.max(0, math.floor(editor_w / 2))
  else
    win_anchor = 'NW'
    local total = vim.api.nvim_buf_line_count(self.renderer.content_buf)
    local base = math.max(0, math.min(anchor.line, total - 1))
    local row_offset = style == 'search' and 1 or 0
    row = math.max(0, math.min(base + 1 + row_offset, editor_h - win_h - 2))
    col = 0
  end

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

function Manager:_show_menu_inline(items, anchor, fg, bg, style)
  if not self.renderer or not self.renderer.content_buf then return 'inline' end
  local lines = {}
  for _, item in ipairs(items) do
    lines[#lines + 1] = line_to_text(item)
  end
  self.menu_state = {
    kind = 'inline',
    items = items,
    fg = fg,
    bg = bg,
    anchor = anchor,
    selected = -1,
    style = style,
  }
  local buf = self.renderer.content_buf
  local total = vim.api.nvim_buf_line_count(buf)
  local row = math.max(0, math.min(anchor.line, total - 1))
  vim.api.nvim_buf_clear_namespace(buf, self.float_ns, 0, -1)
  local bg_hl = self.faces:get(bg)
  for i, line in ipairs(lines) do
    vim.api.nvim_buf_set_extmark(buf, self.float_ns, row, anchor.column or 0, {
      virt_text = { { line, bg_hl } },
      virt_text_pos = 'eol',
      hl_mode = 'combine',
      right_gravity = false,
      id = 1000 + i,
    })
  end
  return 'inline'
end

function Manager:menu_show(items, anchor, fg, bg, style)
  return self:_show_menu(items, anchor, fg, bg, style)
end

function Manager:menu_select(selected)
  if not self.menu_state then return end
  self.menu_state.selected = selected
  if self.menu_state.kind == 'float' then
    local buf = self.menu_state.buf
    vim.api.nvim_buf_clear_namespace(buf, self.float_ns, 0, -1)
    for i, item in ipairs(self.menu_state.items) do
      local hl = (i == selected + 1) and self.faces:get(self.menu_state.fg)
        or self.faces:get(self.menu_state.bg)
      vim.api.nvim_buf_set_extmark(
        buf,
        self.float_ns,
        i - 1,
        0,
        { end_col = #line_to_text(item), hl_group = hl, right_gravity = false }
      )
    end
  else
    local buf = self.renderer.content_buf
    local total = vim.api.nvim_buf_line_count(buf)
    local anchor = self.menu_state.anchor or { line = 0, column = 0 }
    local row = math.max(0, math.min(anchor.line, total - 1))
    vim.api.nvim_buf_clear_namespace(buf, self.float_ns, 0, -1)
    for i, item in ipairs(self.menu_state.items) do
      local line = line_to_text(item)
      local hl = (i == selected + 1) and self.faces:get(self.menu_state.fg)
        or self.faces:get(self.menu_state.bg)
      vim.api.nvim_buf_set_extmark(buf, self.float_ns, row, anchor.column or 0, {
        virt_text = { { line, hl } },
        virt_text_pos = 'eol',
        hl_mode = 'combine',
        right_gravity = false,
        id = 1000 + i,
      })
    end
  end
end

function Manager:menu_hide()
  if not self.menu_state then return end
  if
    self.menu_state.kind == 'float'
    and self.menu_state.win
    and vim.api.nvim_win_is_valid(self.menu_state.win)
  then
    pcall(vim.api.nvim_win_close, self.menu_state.win, true)
  end
  if
    self.renderer
    and self.renderer.content_buf
    and vim.api.nvim_buf_is_valid(self.renderer.content_buf)
  then
    vim.api.nvim_buf_clear_namespace(self.renderer.content_buf, self.float_ns, 0, -1)
  end
  self.menu_state = nil
end

function Manager:info_show(title, content, anchor, face, style)
  self:info_hide()

  if style == 'inline' or style == 'inlineAbove' or style == 'inlineBelow' then
    return self:_info_inline(title, content, anchor, face, style)
  end
  if style == 'prompt' or style == 'modal' or style == 'menuDoc' then
    return self:_info_float(title, content, anchor, face, style)
  end
  return 'unknown'
end

function Manager:_info_float(title, content, anchor, face, style)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value('modifiable', true, { buf = buf })
  local lines = { line_to_text(title) }
  for _, line in ipairs(content) do
    lines[#lines + 1] = line_to_text(line)
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

  local win_anchor, row, col
  if style == 'modal' then
    win_anchor = 'NW'
    row = math.max(0, math.floor((editor_h - height) / 2) - 1)
    col = math.max(0, math.floor((editor_w - width) / 2))
  elseif style == 'menuDoc' then
    local total = (self.renderer and self.renderer.content_buf)
        and vim.api.nvim_buf_line_count(self.renderer.content_buf)
      or editor_h
    local menu_row = anchor and anchor.line or 0
    local base = math.max(0, math.min(menu_row, total - 1))
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

  local hl = self.faces:get(face)
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
  self.info_state = { kind = 'float', buf = buf, win = win, style = style }
  return 'float'
end

function Manager:_info_inline(title, content, anchor, face, style)
  if not self.renderer or not self.renderer.content_buf then return 'inline' end
  local buf = self.renderer.content_buf
  local total = vim.api.nvim_buf_line_count(buf)
  local row = math.max(0, math.min(anchor.line, total - 1))
  local hl = self.faces:get(face)
  vim.api.nvim_buf_clear_namespace(buf, self.float_ns, 0, -1)
  local order = style == 'inlineAbove' and -1 or 1
  local base_row = math.max(0, math.min(row + order, total - 1))
  local col = anchor.column or 0
  vim.api.nvim_buf_set_extmark(buf, self.float_ns, base_row, col, {
    virt_text = { { line_to_text(title), hl } },
    virt_text_pos = 'eol',
    hl_mode = 'combine',
    right_gravity = false,
    id = 2000,
  })
  for i, line in ipairs(content) do
    local r = math.max(0, math.min(base_row + i * order, total - 1))
    vim.api.nvim_buf_set_extmark(buf, self.float_ns, r, col, {
      virt_text = { { line_to_text(line), hl } },
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
  if not self.info_state then return end
  if
    self.info_state.kind == 'float'
    and self.info_state.win
    and vim.api.nvim_win_is_valid(self.info_state.win)
  then
    pcall(vim.api.nvim_win_close, self.info_state.win, true)
  end
  if
    self.renderer
    and self.renderer.content_buf
    and vim.api.nvim_buf_is_valid(self.renderer.content_buf)
  then
    vim.api.nvim_buf_clear_namespace(self.renderer.content_buf, self.float_ns, 0, -1)
  end
  self.info_state = nil
end

Manager._Manager = Manager
return M
