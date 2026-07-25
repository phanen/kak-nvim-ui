---
--- `nvim_open_win` wrapper. Responsible for:
---   * buffer creation + content writing (inner area)
---   * window configuration (relative=editor, anchor/row/col from layout)
---   * per-atom highlight extmarks on inner content
---   * for prompt/modal info: borderless + Kakoune box frame drawn by
---     `popups.frame.box_extmarks`
---   * all floats are borderless to match Kakoune's terminal-UI
---     (menu/non-framed-info have no box; only prompt/modal draw one)
---   * winhighlight (Normal:bg)
---
--- No positioning decisions live here -- those are in `popups.layout`.

local layout = require('kak.ui.popups.layout')
local frame = require('kak.ui.popups.frame')

local M = {}

local faces = require('kak.ui.faces')

---@param ns integer
---@param buf integer
---@param i integer
---@param line kak.ui.protocol.Line
---@param base kak.ui.faces.Face?
---@param cache kak.ui.faces.Cache
---@param col_offset? integer 0-based start column for the first atom (default 0; framed info passes 1 to skip the left border)
local function write_atom_extmarks(ns, buf, i, line, base, cache, col_offset)
  col_offset = col_offset or 0
  -- Clamp end_col to the actual buffer line byte length. Framed info
  -- body rows are truncated to inner_w by `frame.pad`, but the Line
  -- atoms carry the FULL content; without clamping, an atom whose
  -- end_byte exceeds the truncated line length throws
  -- "Invalid 'end_col': out of range".
  local line_text = vim.api.nvim_buf_get_lines(buf, i, i + 1, false)[1] or ''
  local line_len = #line_text
  local byte = 0
  for _, atom in ipairs(line) do
    local s = atom.contents or ''
    if s ~= '' then
      local end_byte = byte + #s
      local start_col = math.min(col_offset + byte, line_len)
      local end_col = math.min(col_offset + end_byte, line_len)
      if start_col < end_col then
        local merged = faces.merge(base, atom.face)
        local hl = cache:get(merged)
        vim.api.nvim_buf_set_extmark(buf, ns, i, start_col, {
          end_col = end_col,
          hl_group = hl,
          right_gravity = false,
        })
      end
      byte = end_byte
    end
  end
end

--- Open a menu float.
---
--- Borderless to match Kakoune's terminal-UI menus (the bg face fills
--- the whole region; selected items use fg, others bg -- no box frame).
---
---@param items kak.ui.protocol.Lines
---@param bg kak.ui.faces.Face?
---@param geom kak.ui.popups.layout.Geom geometry from `layout.menu_pos`
---@param cache kak.ui.faces.Cache
---@return integer buf
---@return integer win
function M.open_menu(items, bg, geom, cache)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value('modifiable', true, { buf = buf })
  local lines = layout.lines_to_text(items)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value('modifiable', false, { buf = buf })

  local bg_hl = cache:get(bg)
  local anchor = geom.win_anchor
  ---@cast anchor 'NW'|'NE'|'SW'|'SE'
  ---@type vim.api.keyset.win_config
  local config = {
    relative = 'editor',
    anchor = anchor,
    style = 'minimal',
    width = math.max(geom.width, 1),
    height = math.max(geom.height, 1),
    row = geom.row,
    col = geom.col,
    border = 'none',
    focusable = false,
    noautocmd = true,
  }
  local win = vim.api.nvim_open_win(buf, false, config)
  vim.api.nvim_set_option_value('winhighlight', 'Normal:' .. bg_hl, { win = win })

  return buf, win
end

--- Open an info float. All styles are borderless to match Kakoune's
--- terminal-UI: `prompt`/`modal` draw their own box frame via
--- `popups.frame.box_extmarks`; other styles (menuDoc, generic) have
--- no box at all.
---
---@param ns integer
---@param title kak.ui.protocol.Line
---@param content kak.ui.protocol.Lines
---@param face kak.ui.faces.Face?
---@param style kak.ui.protocol.InfoStyle
---@param geom kak.ui.popups.layout.Geom geometry from `layout.info_geom`
---@param focusable boolean
---@param cache kak.ui.faces.Cache
---@return integer buf
---@return integer win
function M.open_info(ns, title, content, face, style, geom, focusable, cache)
  local framed = (style == 'prompt') or (style == 'modal')
  local buf = vim.api.nvim_create_buf(false, true)

  local hl = cache:get(face)
  local anchor = geom.win_anchor
  ---@cast anchor 'NW'|'NE'|'SW'|'SE'
  ---@type vim.api.keyset.win_config
  local config = {
    relative = 'editor',
    anchor = anchor,
    style = 'minimal',
    width = geom.width,
    height = geom.height,
    row = geom.row,
    col = geom.col,
    border = 'none',
    focusable = focusable,
    noautocmd = true,
  }
  local win = vim.api.nvim_open_win(buf, focusable, config)
  vim.api.nvim_set_option_value('winhighlight', 'Normal:' .. hl, { win = win })

  -- For framed styles the popups.frame.box_extmarks helper writes
  -- the entire buffer (frame + inner content) in one shot; otherwise
  -- we write the buffer here and apply per-atom extmarks below.
  if framed then
    -- inner content lines for the framed buffer: the title sits at
    -- row 1 inside the frame; everything else follows.
    local body = {}
    for _, c in ipairs(content) do
      body[#body + 1] = layout.line_to_text(c)
    end
    frame.box_extmarks(buf, ns, geom.width, geom.height, title, body, face, cache)
    -- Per-atom highlights on body lines (rows 2..h-2). col_offset=1
    -- skips the left `|` border baked into each padded row.
    local inner_h = math.max(1, geom.height - 2)
    for i = 1, inner_h - 1 do
      write_atom_extmarks(ns, buf, i + 1, content[i] or {}, face, cache, 1)
    end
  else
    local lines = { layout.line_to_text(title) }
    for _, c in ipairs(content) do
      lines[#lines + 1] = layout.line_to_text(c)
    end
    vim.api.nvim_set_option_value('modifiable', true, { buf = buf })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_set_option_value('modifiable', false, { buf = buf })
    write_atom_extmarks(ns, buf, 0, title, face, cache)
    for i, line in ipairs(content) do
      write_atom_extmarks(ns, buf, i, line, face, cache)
    end
  end

  return buf, win
end

--- Re-apply per-atom extmarks on the float buffer (used by
--- `menu_select` for highlight updates).
---@param ns integer
---@param buf integer
---@param items kak.ui.protocol.Lines
---@param fg kak.ui.faces.Face?
---@param bg kak.ui.faces.Face?
---@param selected integer 0-based selected index, or -1 for none
---@param cache kak.ui.faces.Cache
function M.repaint_menu(ns, buf, items, fg, bg, selected, cache)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, item in ipairs(items) do
    local line_base = (i == selected + 1) and fg or bg
    write_atom_extmarks(ns, buf, i - 1, item, line_base, cache)
  end
end

return M
