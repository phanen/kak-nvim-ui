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
local INLINE_MAX_LINE_LEN = 240

local function total_byte_length(items)
  local n = 0
  for _, item in ipairs(items) do
    for _, atom in ipairs(item) do
      n = n + #(atom.contents or '')
    end
    n = n + 1
  end
  return n
end

local function line_to_text(line)
  local parts = {}
  for _, atom in ipairs(line) do
    parts[#parts + 1] = atom.contents or ''
  end
  return table.concat(parts)
end

local function all_items_byte_length(items) return total_byte_length(items) end

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

local function buffer_text(buf) return vim.api.nvim_buf_get_lines(buf, 0, -1, false) end

-- Track last anchor for inline menu re-renders on select.
local function anchor_column_get(self) return self.menu_state._anchor_col or 0 end

--- Show menu. Returns the mode actually used (inline vs float).
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
  local width = 0
  for _, l in ipairs(lines) do
    if #l > width then width = #l end
  end
  local win_h = math.min(#lines, 20)
  local total = vim.api.nvim_buf_line_count(self.renderer.content_buf)
  local row = math.max(0, math.min(anchor.line, total - 1))
  local row_offset = style == 'search' and 1 or 0
  local config = {
    relative = 'editor',
    style = 'minimal',
    width = math.max(width + 2, 4),
    height = win_h,
    row = row + 1 + row_offset,
    col = 0,
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
    selected = -1,
    style = style,
  }
  -- Apply virt_text at the cursor position.
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
    -- Update highlight overlay on selected line.
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
    -- Inline: re-apply virt_text with selected highlight.
    local buf = self.renderer.content_buf
    vim.api.nvim_buf_clear_namespace(buf, self.float_ns, 0, -1)
    for i, item in ipairs(self.menu_state.items) do
      local line = line_to_text(item)
      local hl
      if i == selected + 1 then
        hl = self.faces:get(self.menu_state.fg)
      else
        hl = self.faces:get(self.menu_state.bg)
      end
      vim.api.nvim_buf_set_extmark(
        buf,
        self.float_ns,
        selected ~= -1 and self.menu_state._anchor_row or 0,
        anchor_column_get(self),
        {
          virt_text = { { line, hl } },
          virt_text_pos = 'eol',
          hl_mode = 'combine',
          right_gravity = false,
          id = 1000 + i,
        }
      )
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
-- Track last anchor for inline menu re-renders on select.
-- (moved earlier)

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

  local hl = self.faces:get(face)
  local config = {
    relative = 'editor',
    style = 'minimal',
    width = 80,
    height = math.min(#lines, 20),
    row = style == 'modal' and 5 or (style == 'menuDoc' and 1 or 30),
    col = style == 'menuDoc' and 80 or 10,
    border = 'single',
    focusable = style == 'modal',
    noautocmd = true,
  }
  local win = vim.api.nvim_open_win(buf, style == 'modal', config)
  pcall(vim.api.nvim_set_option_value, 'winhighlight', 'Normal:' .. hl, { win = win })
  self.info_state = { kind = 'float', buf = buf, win = win }
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
