---
--- Renders Kakoune `draw` output into the content buffer.
---
--- The statusline / cmdline is rendered by `kak.ui.statusbar` onto
--- nvim's native `&statusline`; this module only handles the content
--- buffer (extension-row formula, extmark highlights, cursor cell).

---@alias kak.ui.render.DrawStyle kak.ui.protocol.DrawStyle

---@class kak.ui.render.CursorPos
---@field line integer
---@field column integer

---@class kak.ui.render.Renderer
---@field faces kak.ui.faces.Cache
---@field content_buf integer?
---@field set_lines_cache string[]
---@field last_cursor kak.ui.render.CursorPos
---@field current_mode string
---@field prompt_active boolean
---@field set_buf fun(self: kak.ui.render.Renderer, buf: integer)
---@field draw fun(self: kak.ui.render.Renderer, lines: kak.ui.protocol.Lines, cursor_pos: kak.ui.render.CursorPos?, default_face: kak.ui.faces.Face?, padding_face: kak.ui.faces.Face?)
---@field _place_cursor fun(self: kak.ui.render.Renderer, buf: integer, coord: kak.ui.render.CursorPos, face_for_default: kak.ui.faces.Face?)

local M = {}

local CONTENT_NS = vim.api.nvim_create_namespace('kak.ui.render.content')

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

--- Byte length of the UTF-8 codepoint starting at `offset`. Returns 1
--- if `offset` is at/past EOL or points at a continuation byte (defensive).
--- @param line string
--- @param offset integer 0-based byte offset
--- @return integer
local function codepoint_width(line, offset)
  if offset < 0 or offset >= #line then return 1 end
  local b = string.byte(line, offset + 1)
  if not b then return 1 end
  if b < 0x80 then return 1 end
  if b < 0xC0 then return 1 end
  if b < 0xE0 then return 2 end
  if b < 0xF0 then return 3 end
  return 4
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

---@param opts { faces: kak.ui.faces.Cache }
---@return kak.ui.render.Renderer
function M.new(opts)
  return setmetatable({
    faces = opts.faces,
    content_buf = nil,
    set_lines_cache = {},
    last_cursor = { line = 0, column = 0 },
    current_mode = 'normal',
    prompt_active = false,
  }, Renderer)
end

---@param buf integer
function Renderer:set_buf(buf)
  self.content_buf = buf
  self.set_lines_cache = {}
  vim.api.nvim_set_option_value('modifiable', false, { buf = buf })
end

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

--- Place the real nvim cursor at the Kakoune `coord`. Earlier
--- revisions drew a reverse extmark here AND called a typo'd
--- `vim.nvim_win_set_cursor` inside a `pcall`, so the real cursor was
--- never actually moved; the extmark was the only visible signal.
---@param buf integer
---@param coord kak.ui.render.CursorPos
---@param _face_for_default kak.ui.faces.Face?
function Renderer:_place_cursor(buf, coord, _face_for_default)
  -- While the user is in the command/search/prompt line the real nvim
  -- cursor lives in the status float (see `statusbar.render`); skip the
  -- content cursor so a later `draw` does not yank it back.
  if self.prompt_active then return end
  local total = vim.api.nvim_buf_line_count(buf)
  local row = math.max(0, math.min(coord.line, total - 1))
  local lines = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)
  local line_text = lines[1] or ''
  -- The Kakoune cursor column already points at the insertion cell
  -- (after the just-typed char). The insert/replace off-by-one is NOT
  -- fixed by nudging the column (a block covers a full cell either
  -- way -- shifting right just hides the NEXT char instead); instead
  -- `M.apply_cursor_shape` swaps the nvim cursor to a beam in
  -- insert/replace so the vertical bar marks the insertion point
  -- without covering any character, mirroring kakoune's terminal UI.
  local col = column_to_byte(line_text, coord.column)
  self.last_cursor = { line = row, column = col }
  local win = vim.fn.bufwinid(buf)
  if win and win > 0 then vim.api.nvim_win_set_cursor(win, { row + 1, col }) end
end

---@type fun(line: string, column: integer): integer
M.column_to_byte = column_to_byte
---@type fun(line: string, offset: integer): integer
M.codepoint_width = codepoint_width
---@type fun(a: kak.ui.faces.Face?, b: kak.ui.faces.Face?): boolean
M.full_face_equal = full_face_equal
---@type fun(lines: kak.ui.protocol.Lines?): string[]
M.compose_text = compose_text

-- Saved user `guicursor` so we can restore it when the kak session
-- leaves insert/replace (or closes). Lazy: captured on the first
-- insert/replace draw_status so a user who never enters insert keeps
-- their default untouched.
---@type string?
local orig_guicursor = nil

-- BEAM in insert/replace so the cursor marks the insertion point
-- without covering a character (kakoune's terminal does the same).
-- `a:` applies to every nvim mode since the kak content buffer is
-- always in nvim normal mode; the WinLeave autocmd in `open()`
-- restores the original so non-kak windows keep their own shape.
local BEAM_GUICURSOR = 'a:ver25-Cursor'

--- Switch the nvim cursor shape to match the kakoune mode.
---@param mode string
function M.apply_cursor_shape(mode)
  if mode == 'insert' or mode == 'replace' then
    if orig_guicursor == nil then orig_guicursor = vim.o.guicursor end
    if vim.o.guicursor ~= BEAM_GUICURSOR then vim.o.guicursor = BEAM_GUICURSOR end
  elseif orig_guicursor ~= nil then
    if vim.o.guicursor ~= orig_guicursor then vim.o.guicursor = orig_guicursor end
    orig_guicursor = nil
  end
end

--- Restore the user's original `guicursor` (called from WinLeave /
--- Session:close / VimLeavePre so non-kak windows keep their shape).
function M.restore_cursor_shape()
  if orig_guicursor ~= nil then
    if vim.o.guicursor ~= orig_guicursor then vim.o.guicursor = orig_guicursor end
    orig_guicursor = nil
  end
end
return M
