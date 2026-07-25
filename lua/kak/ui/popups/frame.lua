---
--- Box-frame drawing for prompt/modal info floats. Paints the
--- Kakoune-style `╭─┤title├─╮` / `│ │` / `╰──╯` frame onto a scratch
--- buffer and applies frame-character extmark highlights.
---
--- Extracted from `popups.layout` so layout can stay pure positioning
--- math while frame work (buffer writes + extmarks) lives next to
--- `popups.float`. Mirrors Kakoune `terminal_ui.cc 1442-1466`.

local layout = require('kak.ui.popups.layout')

local M = {}

local HL_SEP_T = '┤'
local HL_SEP_B = '├'
local HL_TL = '╭'
local HL_TR = '╮'
local HL_BL = '╰'
local HL_BR = '╯'
local HL_H = '─'
local HL_V = '│'

--- Compute the inner-content width, the rendered top-line string, and
--- the byte-range of the title embedded inside it.
---
--- Returns `(inner_w, top_text, title_byte_start, title_byte_end)`.
--- `title_byte_*` are 0-based byte offsets into `top_text`; if no
--- title was embedded both are nil.
---@param inner_w integer
---@param title_text string
---@return integer inner_w
---@return string top
---@return integer? title_byte_start
---@return integer? title_byte_end
local function top_frame_text(inner_w, title_text)
  if title_text == nil or title_text == '' or inner_w < 4 then
    return inner_w, HL_TL .. string.rep(HL_H, inner_w) .. HL_TR
  end
  local display = vim.fn.strdisplaywidth(title_text)
  if display + 2 > inner_w then
    title_text = vim.fn.strcharpart(title_text, 0, inner_w - 2)
    display = vim.fn.strdisplaywidth(title_text)
  end
  local remaining = inner_w - display - 2
  local left = math.floor(remaining / 2)
  local right = remaining - left
  local top = HL_TL
    .. string.rep(HL_H, left)
    .. HL_SEP_T
    .. title_text
    .. HL_SEP_B
    .. string.rep(HL_H, right)
    .. HL_TR
  local t_start = top:find(HL_SEP_T, 1, true)
  local b_start = top:find(HL_SEP_B, (t_start or 0) + 1, true)
  if not t_start or not b_start then return inner_w, top end
  return inner_w, top, t_start + #HL_SEP_T, b_start - 1
end

--- Draw a Kakoune-style box frame onto `buf` (writes the frame text
--- directly into the buffer) and apply frame-character extmark
--- highlights.
---
--- Buffer layout produced here (height rows of exactly `width` chars):
---   row 0          : top frame, e.g. `╭─...─┤title├...─╮`
---   row 1          : inner title (` content[1] or '' `)
---   rows 2..h-2    : inner content (one string per row)
---   row height - 1 : bottom frame, e.g. `╰─...─╯`
---
--- Side borders are baked into the lines so per-line extmark spans
--- can address the entire `width` without crossing the line boundary.
---
---@param buf integer
---@param ns integer
---@param width integer total window width, including frame columns
---@param height integer total window height, including frame rows
---@param title_line kak.ui.protocol.Line? title atoms (or nil)
---@param content_lines string[] pre-composed inner content, EXCLUDING
---    the title row (one string per row). May be empty.
---@param default_face kak.ui.faces.Face?
---@param cache kak.ui.faces.Cache
function M.box_extmarks(buf, ns, width, height, title_line, content_lines, default_face, cache)
  if width < 3 or height < 3 then return end

  local faces = require('kak.ui.faces')
  local inner_w = width - 2
  local inner_h = height - 2

  local title_text = layout.line_to_text(title_line)
  local top_text
  local t_start, t_end
  do
    local _iw, _top, _ts, _te = top_frame_text(inner_w, title_text)
    top_text = _top
    t_start = _ts
    t_end = _te
  end

  -- Compose each row as exactly `width` chars.
  local function pad(s)
    s = s or ''
    if #s > inner_w then s = s:sub(1, inner_w) end
    return HL_V .. s .. string.rep(' ', inner_w - #s) .. HL_V
  end

  local inner_rows = { pad(title_text) }
  for i = 1, inner_h - 1 do
    inner_rows[#inner_rows + 1] = pad(content_lines[i])
  end

  local buf_lines = { top_text }
  for _, row in ipairs(inner_rows) do
    buf_lines[#buf_lines + 1] = row
  end
  buf_lines[#buf_lines + 1] = HL_BL .. string.rep(HL_H, inner_w) .. HL_BR
  while #buf_lines < height do
    buf_lines[#buf_lines + 1] = pad('')
  end
  if #buf_lines > height then
    local trimmed = {}
    for i = 1, height do
      trimmed[i] = buf_lines[i]
    end
    buf_lines = trimmed
  end

  vim.api.nvim_set_option_value('modifiable', true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, buf_lines)

  local frame_hl = default_face and cache:get(default_face) or 'Normal'
  for row = 0, height - 1 do
    vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
      end_col = width,
      hl_group = frame_hl,
      right_gravity = false,
    })
  end

  -- Per-atom title highlights. The atom byte offsets `byte` /
  -- `end_byte` are local to the title's own text (starting at 0);
  -- the rendered position in the top frame is at `t_start + byte`.
  -- Bounds check uses the title's display byte length
  -- (`t_end - t_start + 1`).
  if title_line and t_start and t_end and t_start <= t_end then
    local title_len = t_end - t_start + 1
    local byte = 0
    for _, atom in ipairs(title_line) do
      local s = atom.contents or ''
      if s ~= '' then
        local end_byte = byte + #s
        if byte >= 0 and end_byte <= title_len then
          local merged = faces.merge(default_face, atom.face)
          local hl = cache:get(merged)
          vim.api.nvim_buf_set_extmark(buf, ns, 0, t_start + byte, {
            end_col = t_start + end_byte,
            hl_group = hl,
            right_gravity = false,
          })
        end
        byte = end_byte
      end
    end
  end
end

return M
