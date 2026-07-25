---
--- Extmark-based inline rendering for short Kakoune menus and info
--- popups. Used when the layout decides the popup can fit on-screen
--- as virtual text rather than a floating window.
---
--- All extmarks are written into `buf` under `ns`; the caller clears
--- the namespace before re-rendering.

local layout = require('kak.ui.popups.layout')

local M = {}

local faces = require('kak.ui.faces')

--- Build virt_text chunks where each atom is merged with `base`.
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

M._line_to_chunks = line_to_chunks

--- Apply per-atom extmark highlights in the float buffer at row `i`.
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
      vim.api.nvim_buf_set_extmark(buf, ns, i, byte, {
        end_col = end_byte,
        hl_group = hl,
        right_gravity = false,
      })
      byte = end_byte
    end
  end
end

M._apply_atom_extmarks = apply_atom_extmarks

--- Clear all inline-popup extmarks from `buf`.
---@param buf integer
---@param ns integer
function M.clear(buf, ns)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
end

--- Render a menu as a column of virt_text rows anchored at
--- `anchor.column` on the buffer row nearest `anchor.line`. Each item
--- gets a single `virt_text_pos='eol'` extmark; the selected row uses
--- `fg` as the line base, the rest use `bg`.
---
---@param buf integer
---@param ns integer
---@param anchor kak.ui.protocol.Coord
---@param items kak.ui.protocol.Lines
---@param fg kak.ui.faces.Face?
---@param bg kak.ui.faces.Face?
---@param cache kak.ui.faces.Cache
---@param selected integer 0-based selected index, or -1 for none
function M.render_menu(buf, ns, anchor, items, fg, bg, cache, selected)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  local total = vim.api.nvim_buf_line_count(buf)
  local row = math.max(0, math.min(anchor.line, total - 1))
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, item in ipairs(items) do
    local line_base = (i == selected + 1) and fg or bg
    local chunks = line_to_chunks(item, line_base, cache)
    vim.api.nvim_buf_set_extmark(buf, ns, row, anchor.column or 0, {
      virt_text = chunks,
      virt_text_pos = 'eol',
      hl_mode = 'combine',
      right_gravity = false,
      id = 1000 + i,
    })
  end
end

--- Render info content (title + body) as inline virt_text. Each
--- output line is anchored at `anchor.column` on the row computed by
--- `layout.info_pos` for the chosen style (default: `inline`, i.e.
--- just below the cursor). For `inlineAbove` the title is placed
--- above the cursor and the body unfolds upward; for `inlineBelow`
--- the reverse. The single `face` is the base for every line.
---
---@param buf integer
---@param ns integer
---@param anchor kak.ui.protocol.Coord
---@param title kak.ui.protocol.Line
---@param content kak.ui.protocol.Lines
---@param face kak.ui.faces.Face?
---@param style kak.ui.protocol.InfoStyle
---@param cache kak.ui.faces.Cache
function M.render_info(buf, ns, anchor, title, content, face, style, cache)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  local total = vim.api.nvim_buf_line_count(buf)
  local geom = layout.info_pos(style, anchor, buf, nil)
  local order = (style == 'inlineAbove') and -1 or 1
  local base_row = geom.row
  ---@cast base_row integer
  local col = anchor.column or 0
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  -- Title at base_row.
  vim.api.nvim_buf_set_extmark(buf, ns, base_row, col, {
    virt_text = line_to_chunks(title, face, cache),
    virt_text_pos = 'eol',
    hl_mode = 'combine',
    right_gravity = false,
    id = 2000,
  })
  for i, line in ipairs(content) do
    local r = math.max(0, math.min(base_row + i * order, total - 1))
    vim.api.nvim_buf_set_extmark(buf, ns, r, col, {
      virt_text = line_to_chunks(line, face, cache),
      virt_text_pos = 'eol',
      hl_mode = 'combine',
      right_gravity = false,
      id = 2000 + i,
    })
  end
end

return M
