---
--- Pure popup positioning math. No `nvim_open_win`, no buffer writes.
--- Box-frame rendering lives in `popups.frame`; this module just
--- exposes the geometry picks and shared text-composition helpers.
---
--- Layout rules mirror Kakoune's `terminal_ui.cc`:
---   * `menu_show` line 1130
---   * `info_show` line 1333
---   * `compute_pos`  line 1260

---@alias kak.ui.popups.layout.MenuKind 'float' | 'inline'
---@alias kak.ui.popups.layout.InfoKind 'float' | 'inline'
---@alias kak.ui.popups.layout.Dim { line: integer, column: integer }
---@alias kak.ui.popups.layout.Rect { pos: kak.ui.popups.layout.Dim, size: kak.ui.popups.layout.Dim }

---@class kak.ui.popups.layout.Geom
---@field win_anchor 'NW'|'NE'|'SW'|'SE'|'inline'
---@field row integer
---@field col integer
---@field height integer
---@field width integer
---@field items_max_width integer?

local M = {}

local MENU_MAX_HEIGHT = 20
local INFO_MAX_HEIGHT_FLOOR = 5
local INFO_MAX_WIDTH_FLOOR = 20

-- Named reference points for fixed info styles. Geometry (height /
-- width) is filled in by `info_geom`; these are just the (row, col)
-- pre-size. Add a new anchor by adding a key here; the dispatcher in
-- `info_pos` reads it from the table.
---@alias kak.ui.popups.layout.AnchorPoint
---| 'editor_corner' -- SE corner of the editor
---| 'editor_origin' -- NW corner
---| 'editor_right'  -- right edge at row 0

---@type table<kak.ui.popups.layout.AnchorPoint, fun(editor_h: integer, editor_w: integer): integer, integer>
local ANCHOR_POINTS = {
  editor_corner = function(h, w) return h, w end,
  editor_origin = function() return 0, 0 end,
  editor_right = function(_, w) return 0, w end,
}

--- Style -> (win_anchor, reference point). The (row, col) of the
--- placeholder geom is derived from the point; `info_geom` later
--- replaces height/width and adjusts row/col for content.
---@type table<string, { win_anchor: 'NW'|'NE'|'SW'|'SE', point: kak.ui.popups.layout.AnchorPoint }>
local INFO_ANCHORS = {
  prompt = { win_anchor = 'SE', point = 'editor_corner' },
  modal = { win_anchor = 'NW', point = 'editor_origin' },
  menuDoc = { win_anchor = 'NW', point = 'editor_right' },
}

--- Route a Kakoune menu style to the rendering path Kakoune uses:
--- `search` is a single-row horizontal menu rendered inline as virt_text;
--- every other style is rendered as a 1-column vertical float
--- (borderless, mirroring Kakoune's `terminal_ui.cc` `columns = 1`).
---@param style kak.ui.protocol.MenuStyle
---@param _item_count integer
---@return kak.ui.popups.layout.MenuKind
function M.choose_float_or_inline(style, _item_count)
  if style == 'search' then return 'inline' end
  return 'float'
end

---@param items kak.ui.protocol.Lines
---@return integer
function M.items_max_width(items)
  local max = 0
  for _, item in ipairs(items) do
    local n = 0
    for _, atom in ipairs(item) do
      local s = atom.contents or ''
      n = n + vim.fn.strdisplaywidth(s)
    end
    if n > max then max = n end
  end
  return max
end

---@param title kak.ui.protocol.Line?
---@param content kak.ui.protocol.Lines
---@return integer
function M.lines_max_width(title, content)
  local max = 0
  if title then
    local n = 0
    for _, atom in ipairs(title) do
      n = n + vim.fn.strdisplaywidth(atom.contents or '')
    end
    if n > max then max = n end
  end
  for _, line in ipairs(content) do
    local n = 0
    for _, atom in ipairs(line) do
      n = n + vim.fn.strdisplaywidth(atom.contents or '')
    end
    if n > max then max = n end
  end
  return max
end

--- Editor dimensions as Kakoune sees them: line is num_rows, column is
--- num_cols. `editor_dims` matches `Surface:editor_dims()`.
---@param editor_dims { width: integer, height: integer }?
---@return kak.ui.popups.layout.Dim
function M.editor_dims_norm(editor_dims)
  local w = editor_dims and editor_dims.width or (vim.o.columns or 120)
  local h = editor_dims and editor_dims.height or (vim.o.lines or 40)
  return { line = h, column = w }
end

--- Kakoune `terminal_ui.cc:1186-1187`. For `prompt`, the top edge of
--- the menu sits on the bottom row of the editor.
---
--- Default body-only field height to `min(#items, 20)` if not
--- supplied; this matches Kakoune's `height_limit(Prompt) = 10_line`
--- for *menu* sizing but we keep the cap larger so longer completion
--- lists fit.
---
---@param style kak.ui.protocol.MenuStyle
---@param anchor kak.ui.protocol.Coord
---@param content_buf integer? renderer's content buffer (clamp source)
---@param editor_dims { width: integer, height: integer }?
---@param height integer?
---@param width integer?
---@return kak.ui.popups.layout.Geom
function M.menu_pos(style, anchor, content_buf, editor_dims, height, width)
  local ed = M.editor_dims_norm(editor_dims)
  local editor_h = ed.line
  local editor_w = ed.column

  local h = height or 1
  if h < 1 then h = 1 end
  if h > MENU_MAX_HEIGHT then h = MENU_MAX_HEIGHT end
  local w = width or editor_w
  if w < 1 then w = 1 end

  if style == 'prompt' then
    return {
      win_anchor = 'NW',
      row = math.max(0, editor_h - h),
      col = 0,
      height = h,
      width = w,
    }
  end

  if style == 'search' then
    return {
      win_anchor = 'NW',
      row = math.max(0, editor_h - 1),
      col = math.floor(editor_w / 2),
      height = 1,
      width = math.floor(editor_w / 2),
    }
  end

  -- inline (incl. long lists rendered as a float)
  local total = (content_buf and vim.api.nvim_buf_is_valid(content_buf))
      and vim.api.nvim_buf_line_count(content_buf)
    or editor_h
  local base = math.max(0, math.min(anchor.line, total - 1))
  local row = base + 1
  if row + h > editor_h and base >= h then row = base - h end
  row = math.max(0, math.min(row, editor_h - h))
  return {
    win_anchor = 'NW',
    row = row,
    col = 0,
    height = h,
    width = w,
  }
end

--- Compose info window geometry.
---
--- For fixed-anchor styles (`prompt`, `modal`, `menuDoc`), the
--- (row, col, win_anchor) is read from `INFO_ANCHORS`; `info_geom`
--- then fills in height/width and adjusts row/col for content.
--- For inline styles, position is derived from `anchor.line` and
--- `content_buf`.
---
---@param style kak.ui.protocol.InfoStyle
---@param anchor kak.ui.protocol.Coord
---@param content_buf integer?
---@param editor_dims { width: integer, height: integer }?
---@return kak.ui.popups.layout.Geom
function M.info_pos(style, anchor, content_buf, editor_dims)
  local ed = M.editor_dims_norm(editor_dims)
  local editor_h = ed.line
  local editor_w = ed.column

  local entry = INFO_ANCHORS[style]
  if entry then
    local row, col = ANCHOR_POINTS[entry.point](editor_h, editor_w)
    return { win_anchor = entry.win_anchor, row = row, col = col, height = 0, width = 0 }
  end

  local total = (content_buf and vim.api.nvim_buf_is_valid(content_buf))
      and vim.api.nvim_buf_line_count(content_buf)
    or editor_h
  local base = math.max(0, math.min(anchor.line, total - 1))
  local order = (style == 'inlineAbove') and -1 or 1
  local row = base + order
  if order < 0 and row < 0 then row = base + 1 end
  row = math.max(0, math.min(row, editor_h - 1))
  return {
    win_anchor = 'inline',
    row = row,
    col = anchor.column or 0,
    height = 0,
    width = 0,
  }
end

--- Fill the height/width/row/col/anchor fields of an info `Geom`,
--- given the chosen style's content sizes. Pure transform; geometry
--- math per style lives here so the float module only deals with
--- buffer/window plumbing.
---
---@param style kak.ui.protocol.InfoStyle
---@param geom kak.ui.popups.layout.Geom
---@param anchor kak.ui.protocol.Coord
---@param menu_rect kak.ui.popups.layout.Rect?
---@param title kak.ui.protocol.Line?
---@param content kak.ui.protocol.Lines
---@param editor_dims { width: integer, height: integer }?
---@return kak.ui.popups.layout.Geom
function M.info_geom(style, geom, anchor, menu_rect, title, content, editor_dims)
  local ed = M.editor_dims_norm(editor_dims)
  local editor_h = ed.line
  local editor_w = ed.column
  local maxw = M.lines_max_width(title, content)
  local total_lines = (title and 1 or 0) + #content

  if style == 'prompt' or style == 'modal' then
    -- Kakoune line 1374-1376: max(content, title + 2) + 4 (frame).
    local inner_w = math.max(maxw, M.lines_max_width(title, {}) + 2)
    local width = math.min(inner_w + 4, editor_w)
    local height = math.min(total_lines + 2, editor_h)
    if style == 'modal' then
      -- Kakoune line 1390-1394: anchor = rect.pos + half(rect.size)
      -- - half(size); rect uses the FULL editor dims (no menu
      -- subtraction -- only max_size for MenuDoc / non-modal touches
      -- menu size, see line 1351-1352 of terminal_ui.cc).
      local row = math.max(0, math.floor((editor_h - height) / 2))
      local col = math.max(0, math.floor((editor_w - width) / 2))
      geom.win_anchor = 'NW'
      geom.row = row
      geom.col = col
    else
      geom.win_anchor = 'SE'
      geom.row = editor_h
      geom.col = editor_w
    end
    geom.height = height
    geom.width = width
    return geom
  end

  if style == 'menuDoc' then
    local width = math.min(maxw + 2, math.max(INFO_MAX_WIDTH_FLOOR, math.floor(editor_w / 2)))
    local height = math.min(total_lines, math.max(INFO_MAX_HEIGHT_FLOOR, math.floor(editor_h / 3)))
    -- Kakoune line 1396-1404.
    local menu_pos_col, menu_pos_line, menu_size_col
    if menu_rect then
      menu_pos_col = menu_rect.pos.column
      menu_pos_line = menu_rect.pos.line
      menu_size_col = menu_rect.size.column
    else
      -- No active menu: right-justify against the editor and use the
      -- cursor anchor for vertical placement so menuDoc still feels
      -- attached when shown alone.
      menu_pos_col = editor_w - width
      menu_pos_line = anchor.line
      menu_size_col = 0
    end
    local right_max = editor_w - (menu_pos_col + menu_size_col)
    local left_max = menu_pos_col
    local row = math.max(0, math.min(menu_pos_line, editor_h - height))
    local right_branch = (width <= right_max) or (right_max >= left_max)
    if right_branch then
      -- Window's left edge sits at the menu's right edge.
      geom.win_anchor = 'NW'
      geom.col = menu_pos_col + menu_size_col
    else
      -- Window's right edge sits at the menu's left edge.
      geom.win_anchor = 'NE'
      geom.col = menu_pos_col
    end
    geom.row = row
    geom.height = height
    geom.width = width
    return geom
  end

  -- inline{,Above,Below}
  geom.height = total_lines
  geom.width = maxw
  return geom
end

--- Compose a `Line` into a flat string. Empty atoms contribute ''.
---@param line kak.ui.protocol.Line?
---@return string
function M.line_to_text(line)
  if not line then return '' end
  local parts = {}
  for _, atom in ipairs(line) do
    parts[#parts + 1] = atom.contents or ''
  end
  return table.concat(parts)
end

--- Compose lines to text (one entry per line).
---@param lines kak.ui.protocol.Lines?
---@return string[]
function M.lines_to_text(lines)
  local out = {}
  for i, line in ipairs(lines or {}) do
    out[i] = M.line_to_text(line)
  end
  return out
end

---@param geom kak.ui.popups.layout.Geom
---@return string
function M.dump(geom) return vim.inspect(geom) end

return M
