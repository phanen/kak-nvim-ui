---
--- Renders Kakoune `draw` / `draw_status` output into nvim buffers.
---
--- Layout:
---   * `content_buf` -- the main buffer. Holds the display_lines that
---     Kakoune draws. Cursor is placed here.
---   * `mode_buf`    -- one-line scratch buffer for the statusline mode
---     line from `draw_status`.

---@alias kak.ui.render.DrawStyle kak.ui.protocol.DrawStyle

---@class kak.ui.render.CursorPos
---@field line integer
---@field column integer

---@class kak.ui.render.PromptState
---@field open boolean
---@field prompt kak.ui.protocol.Line?
---@field content string[]
---@field cursor integer
---@field face kak.ui.faces.Face?
---@field style kak.ui.protocol.DrawStyle

---@class kak.ui.render.Renderer
---@field faces kak.ui.faces.Cache
---@field content_buf integer?
---@field mode_buf integer?
---@field set_lines_cache string[]
---@field last_cursor kak.ui.render.CursorPos
---@field prompt_state kak.ui.render.PromptState
---@field set_buf fun(self: kak.ui.render.Renderer, buf: integer)
---@field set_mode_buf fun(self: kak.ui.render.Renderer, buf: integer)
---@field draw fun(self: kak.ui.render.Renderer, lines: kak.ui.protocol.Lines, cursor_pos: kak.ui.render.CursorPos?, default_face: kak.ui.faces.Face?, padding_face: kak.ui.faces.Face?)
---@field draw_mode fun(self: kak.ui.render.Renderer, mode_line: kak.ui.protocol.Line?, default_face: kak.ui.faces.Face?)
---@field set_prompt fun(self: kak.ui.render.Renderer, prompt_line: kak.ui.protocol.Line?, content_line: kak.ui.protocol.Lines?, cursor_col: integer, default_face: kak.ui.faces.Face?, style: kak.ui.protocol.DrawStyle?)
---@field _place_cursor fun(self: kak.ui.render.Renderer, buf: integer, coord: kak.ui.render.CursorPos, face_for_default: kak.ui.faces.Face?)

local M = {}

local NS = vim.api.nvim_create_namespace('kak.ui.render')
local CONTENT_NS = NS + 1
local CURSOR_NS = NS + 2
local MODE_NS = NS + 3

--- Convert a codepoint column to a byte offset within `line`.
--- @param line string
--- @param column integer 1-based codepoint column; 0 clamps to byte 0
--- @return integer
local function column_to_byte(line, column)
  if column <= 0 then return 0 end
  local byte = 0
  local cp = 0
  while byte < #line and cp < column do
    local b = string.byte(line, byte + 1)
    local len
    if not b then break end
    if b < 0x80 then
      len = 1
    elseif b < 0xC0 then
      len = 1
    elseif b < 0xE0 then
      len = 2
    elseif b < 0xF0 then
      len = 3
    else
      len = 4
    end
    byte = byte + len
    cp = cp + 1
  end
  if cp < column then return #line end
  return byte
end

---@param a string[]?
---@param b string[]?
---@return boolean
local function attrs_equal(a, b)
  if a == b then return true end
  if a == nil or b == nil then return false end
  if #a ~= #b then return false end
  local seen = {}
  for _, x in ipairs(a) do
    seen[x] = (seen[x] or 0) + 1
  end
  for _, x in ipairs(b) do
    if not seen[x] or seen[x] == 0 then return false end
    seen[x] = seen[x] - 1
  end
  return true
end

---@param a kak.ui.faces.Face
---@param b kak.ui.faces.Face
local function face_keys_equal(a, b)
  if a == b then return true end
  if a == nil or b == nil then return false end
  return (a.fg or 'default') == (b.fg or 'default')
    and (a.bg or 'default') == (b.bg or 'default')
    and (a.underline or 'default') == (b.underline or 'default')
end

---@param a kak.ui.faces.Face?
---@param b kak.ui.faces.Face?
---@return boolean
local function full_face_equal(a, b)
  if a == b then return true end
  if a == nil or b == nil then return false end
  return face_keys_equal(a, b) and attrs_equal(a.attributes or {}, b.attributes or {})
end

--- Compose one display line (array of atoms) into a flat string.
--- Strips the trailing `\n` that Kakoune appends to the last atom.
---@param line kak.ui.protocol.Line
---@return string
local function compose_one_line(line)
  local parts = {}
  for _, atom in ipairs(line) do
    parts[#parts + 1] = atom.contents or ''
  end
  return (table.concat(parts):gsub('\n+$', ''))
end

--- Compose `lines` (array of atom arrays) into a flat text array,
--- one entry per buffer line.
---@param lines kak.ui.protocol.Lines?
---@return string[]
local function compose_text(lines)
  if not lines or #lines == 0 then return { '' } end
  local text = {}
  for i, line in ipairs(lines) do
    text[i] = compose_one_line(line)
  end
  return text
end

local Renderer = {}
Renderer.__index = Renderer

---@param opts? { faces: kak.ui.faces.Cache }
---@return kak.ui.render.Renderer
function M.new(opts)
  ---@cast opts -nil
  ---@type kak.ui.render.PromptState
  local prompt_state = {
    open = false,
    prompt = nil,
    content = {},
    cursor = 0,
    face = nil,
    style = 'status',
  }
  return setmetatable({
    faces = opts.faces,
    content_buf = nil,
    mode_buf = nil,
    set_lines_cache = {},
    last_cursor = { line = 0, column = 0 },
    prompt_state = prompt_state,
  }, Renderer)
end

---@param buf integer
function Renderer:set_buf(buf)
  self.content_buf = buf
  self.set_lines_cache = {}
  vim.api.nvim_set_option_value('modifiable', false, { buf = buf })
end

---@param buf integer
function Renderer:set_mode_buf(buf) self.mode_buf = buf end

--- Render `lines` into the content buffer. Per-atom extmark highlights
--- are applied for cells whose face differs from `default_face`.
---@param lines kak.ui.protocol.Lines
---@param cursor_pos kak.ui.render.CursorPos?
---@param default_face kak.ui.faces.Face?
---@param padding_face kak.ui.faces.Face? reserved for future use
function Renderer:draw(lines, cursor_pos, default_face, padding_face)
  ---@cast padding_face -nil
  local buf = self.content_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end

  vim.api.nvim_buf_clear_namespace(buf, CONTENT_NS, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, CURSOR_NS, 0, -1)

  local text = compose_text(lines)
  vim.api.nvim_set_option_value('modifiable', true, { buf = buf })
  local prev = self.set_lines_cache
  local same = #prev == #text
  if same then
    for i = 1, #text do
      if prev[i] ~= text[i] then
        same = false
        break
      end
    end
  end
  if not same then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, text)
    self.set_lines_cache = text
  end
  vim.api.nvim_set_option_value('modifiable', false, { buf = buf })

  if default_face then
    for i, line in ipairs(lines) do
      local byte = 0
      for _, atom in ipairs(line) do
        local s = atom.contents or ''
        local end_byte = byte + #s
        if s ~= '' and not full_face_equal(atom.face, default_face) then
          local hl = self.faces:get(atom.face)
          if hl then
            pcall(vim.api.nvim_buf_set_extmark, buf, CONTENT_NS, i - 1, byte, {
              end_col = end_byte,
              hl_group = hl,
              right_gravity = false,
            })
          end
        end
        byte = end_byte
      end
    end
  end

  if cursor_pos and cursor_pos.column >= 0 then
    self:_place_cursor(buf, cursor_pos, default_face)
  end
end

---@param buf integer
---@param coord kak.ui.render.CursorPos
---@param face_for_default kak.ui.faces.Face?
function Renderer:_place_cursor(buf, coord, face_for_default)
  local total = vim.api.nvim_buf_line_count(buf)
  local row = math.max(0, math.min(coord.line, total - 1))
  local lines = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)
  local line_text = lines[1] or ''
  local col = column_to_byte(line_text, coord.column)
  self.last_cursor = { line = row, column = col }
  ---@type kak.ui.faces.Face
  local cursor_face = {
    fg = (face_for_default and face_for_default.bg) or 'default',
    bg = (face_for_default and face_for_default.fg) or 'default',
    underline = 'default',
    attributes = { 'reverse' },
  }
  local hl = self.faces:get(cursor_face)
  pcall(vim.api.nvim_buf_set_extmark, buf, CURSOR_NS, row, col, {
    end_col = math.min(col + 1, #line_text),
    hl_group = hl,
    right_gravity = false,
  })
  local win = vim.fn.bufwinid(buf)
  if win and win > 0 then pcall(vim.api.nvim_win_set_cursor, win, { row + 1, col }) end
end

---@param buf integer?
function Renderer.hide_cursor(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  vim.api.nvim_buf_clear_namespace(buf, CURSOR_NS, 0, -1)
end

---@param mode_line kak.ui.protocol.Line?
---@param default_face kak.ui.faces.Face?
function Renderer:draw_mode(mode_line, default_face)
  local buf = self.mode_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  local text = compose_one_line(mode_line or {})
  vim.api.nvim_set_option_value('modifiable', true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
  vim.api.nvim_set_option_value('modifiable', false, { buf = buf })
  vim.api.nvim_buf_clear_namespace(buf, MODE_NS, 0, -1)
  local byte = 0
  for _, atom in ipairs(mode_line or {}) do
    local s = atom.contents or ''
    local end_byte = byte + #s
    if s ~= '' and not full_face_equal(atom.face, default_face) then
      local hl = self.faces:get(atom.face)
      if hl then
        pcall(vim.api.nvim_buf_set_extmark, buf, MODE_NS, 0, byte, {
          end_col = end_byte,
          hl_group = hl,
          right_gravity = false,
        })
      end
    end
    byte = end_byte
  end
end

---@param prompt_line kak.ui.protocol.Line?
---@param content_line kak.ui.protocol.Lines?
---@param cursor_col integer
---@param default_face kak.ui.faces.Face?
---@param style kak.ui.protocol.DrawStyle?
function Renderer:set_prompt(prompt_line, content_line, cursor_col, default_face, style)
  ---@type kak.ui.render.PromptState
  local s = self.prompt_state
  s.prompt = prompt_line
  s.content = compose_text(content_line)
  s.cursor = cursor_col
  s.face = default_face
  s.style = style or 'status'
end

---@type fun(line: string, column: integer): integer
M.column_to_byte = column_to_byte
---@type fun(a: kak.ui.faces.Face?, b: kak.ui.faces.Face?): boolean
M.full_face_equal = full_face_equal
---@type fun(lines: kak.ui.protocol.Lines?): string[]
M.compose_text = compose_text
return M
