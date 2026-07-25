---
--- Composes Kakoune `draw_status` output for nvim's native statusline.

local faces = require('kak.ui.faces')
local render = require('kak.ui.render')

local M = {}

---@param text string
---@return string
local function esc(text) return (text:gsub('%%', '%%%%')) end

---@param hl string
---@param text string
---@return string
local function highlighted(hl, text) return '%#' .. hl .. '#' .. esc(text) .. '%*' end

---@param atom kak.ui.protocol.Atom
---@param default_face kak.ui.faces.Face?
---@param cache kak.ui.faces.Cache
---@return string
local function atom_chunk(atom, default_face, cache)
  local merged = faces.merge(default_face, atom.face)
  return highlighted(cache:get(merged), atom.contents or '')
end

---@param line kak.ui.protocol.Line?
---@param default_face kak.ui.faces.Face?
---@param cache kak.ui.faces.Cache
---@return string
local function line_chunks(line, default_face, cache)
  local chunks = {}
  for _, atom in ipairs(line or {}) do
    chunks[#chunks + 1] = atom_chunk(atom, default_face, cache)
  end
  return table.concat(chunks)
end

---@class kak.ui.statusbar.AtomRange
---@field atom kak.ui.protocol.Atom
---@field b0 integer
---@field b1 integer

--- Compose prompt, content, status cursor, and right-justified mode line.
---@param prompt kak.ui.protocol.Line
---@param content kak.ui.protocol.Lines
---@param cursor_pos integer 0-based codepoint column into content
---@param mode_line kak.ui.protocol.Line
---@param default_face kak.ui.faces.Face?
---@param style kak.ui.protocol.DrawStyle
---@param cache kak.ui.faces.Cache
---@return string
function M.compose(prompt, content, cursor_pos, mode_line, default_face, style, cache)
  ---@cast style -nil
  local cursor_face = {
    fg = (default_face and default_face.bg) or 'default',
    bg = (default_face and default_face.fg) or 'default',
    underline = 'default',
    attributes = { 'reverse' },
  }
  local cursor_hl = cache:get(cursor_face)
  local left = { line_chunks(prompt or {}, default_face, cache) }
  local parts = {}
  ---@type kak.ui.statusbar.AtomRange[]
  local ranges = {}
  local byte = 0
  for _, line in ipairs(content or {}) do
    for _, atom in ipairs(line) do
      local text = atom.contents or ''
      local next_byte = byte + #text
      parts[#parts + 1] = text
      ranges[#ranges + 1] = { atom = atom, b0 = byte, b1 = next_byte }
      byte = next_byte
    end
  end
  local cstr = table.concat(parts)
  local cbyte = cursor_pos >= 0 and render.column_to_byte(cstr, cursor_pos) or -1
  local cursor_after = cursor_pos >= 0 and cbyte >= #cstr
  local cursor_drawn = false

  for _, range in ipairs(ranges) do
    local atom = range.atom
    local text = atom.contents or ''
    if cursor_pos >= 0 and cbyte >= range.b0 and cbyte < range.b1 then
      local rel = cbyte - range.b0
      local char_len = render.codepoint_width(cstr, cbyte)
      local merged = faces.merge(default_face, atom.face)
      local atom_hl = cache:get(merged)
      local pre = text:sub(1, rel)
      local cell = text:sub(rel + 1, rel + char_len)
      local post = text:sub(rel + char_len + 1)
      if pre ~= '' then left[#left + 1] = highlighted(atom_hl, pre) end
      left[#left + 1] = highlighted(cursor_hl, cell)
      if post ~= '' then left[#left + 1] = highlighted(atom_hl, post) end
      cursor_drawn = true
    else
      left[#left + 1] = atom_chunk(atom, default_face, cache)
    end
  end
  if cursor_after and not cursor_drawn then left[#left + 1] = highlighted(cursor_hl, ' ') end

  local mode = line_chunks(mode_line, default_face, cache)
  if mode ~= '' then return table.concat(left) .. '%=' .. mode end
  return table.concat(left)
end

--- Apply the composed statusline to a valid window.
---@param win integer?
---@param prompt kak.ui.protocol.Line
---@param content kak.ui.protocol.Lines
---@param cursor_pos integer
---@param mode_line kak.ui.protocol.Line
---@param default_face kak.ui.faces.Face?
---@param style kak.ui.protocol.DrawStyle
---@param cache kak.ui.faces.Cache
function M.render(win, prompt, content, cursor_pos, mode_line, default_face, style, cache)
  local statusline = M.compose(prompt, content, cursor_pos, mode_line, default_face, style, cache)
  if not win or not vim.api.nvim_win_is_valid(win) then return end
  vim.wo[win].statusline = statusline
  pcall(function() vim.cmd('redrawstatus') end)
end

return M
