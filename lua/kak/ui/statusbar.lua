---
--- Renders the Kakoune `draw_status` line into a 1-row floating window
--- at the bottom of the editor. The float shows
---   `[prompt][content]<pad>[mode_line]`
--- with the prompt cursor as a reverse extmark covering the codepoint at
--- `prompt_len + cursor_byte` (or a reverse space if the cursor is past
--- the end of content). The MAIN content cursor stays the real nvim
--- cursor in `kak.ui.render`; only the status area lives in a float.
---
--- Why a float, not `&statusline`: nvim reliably redraws a window whose
--- buffer changed, so updates always paint. The string-based
--- `&statusline` approach dropped typed cmdline chars in real use, even
--- after stripping the `\n`/`\r` line terminators.

local faces = require('kak.ui.faces')
local render = require('kak.ui.render')

local M = {}

local NS = vim.api.nvim_create_namespace('kak.ui.statusbar')

--- Strip the `\n`/`\r` line terminators Kakoune appends to atoms.
---@param text string
---@return string
local function clean(text) return (text:gsub('[\r\n]', '')) end

--- Concat a Line into flat text and build one span per atom. Returns
--- the joined text, its display width (so CJK contributes 1 cell, not
--- 1 byte), and the list of `{b0, b1, hl_group}` spans.
---@param line kak.ui.protocol.Line?
---@param default_face kak.ui.faces.Face?
---@param cache kak.ui.faces.Cache
---@return string text, integer display_width, { [1]: integer, [2]: integer, [3]: string }[] spans
local function line_to_parts(line, default_face, cache)
  local parts = {}
  local spans = {}
  local byte = 0
  for _, atom in ipairs(line or {}) do
    local text = clean(atom.contents or '')
    parts[#parts + 1] = text
    local merged = faces.merge(default_face, atom.face)
    spans[#spans + 1] = { byte, byte + #text, cache:get(merged) }
    byte = byte + #text
  end
  local joined = table.concat(parts)
  return joined, vim.fn.strdisplaywidth(joined), spans
end

---@class kak.ui.statusbar.Built
---@field text string
---@field spans { [1]: integer, [2]: integer, [3]: string }[]
---@field prompt_len integer byte length of the prompt portion
---@field content_str string concatenated cleaned content atoms

--- Build the single statusbar line. Prompt on the left, content next,
--- pad with spaces, then right-justified `mode_line`. The mode_line is
--- dropped if it does not fit; truncating mode_line is left for a later
--- revision.
---@param prompt kak.ui.protocol.Line?
---@param content kak.ui.protocol.Lines?
---@param mode_line kak.ui.protocol.Line?
---@param default_face kak.ui.faces.Face?
---@param cols integer
---@param cache kak.ui.faces.Cache
---@return kak.ui.statusbar.Built
function M.build_line(prompt, content, mode_line, default_face, cols, cache)
  local prompt_text, _, prompt_spans = line_to_parts(prompt, default_face, cache)
  local prompt_len = #prompt_text

  local content_parts = {}
  local content_spans = {}
  local byte = 0
  for _, line in ipairs(content or {}) do
    for _, atom in ipairs(line) do
      local text = clean(atom.contents or '')
      content_parts[#content_parts + 1] = text
      local merged = faces.merge(default_face, atom.face)
      content_spans[#content_spans + 1] = { byte, byte + #text, cache:get(merged) }
      byte = byte + #text
    end
  end
  local content_str = table.concat(content_parts)

  -- Concatenated spans live after the prompt: shift content spans by
  -- `prompt_len` and prepend prompt spans unchanged.
  local spans = {}
  for _, s in ipairs(prompt_spans) do
    spans[#spans + 1] = s
  end
  for _, s in ipairs(content_spans) do
    spans[#spans + 1] = { s[1] + prompt_len, s[2] + prompt_len, s[3] }
  end

  local left_text = prompt_text .. content_str
  local left_display = vim.fn.strdisplaywidth(left_text)

  local mode_text, mode_display, mode_spans = line_to_parts(mode_line, default_face, cache)

  -- Pad only when there is a mode_line AND it fits on the right.
  if mode_text == '' then
    return {
      text = left_text,
      spans = spans,
      prompt_len = prompt_len,
      content_str = content_str,
    }
  end
  local pad = cols - left_display - mode_display
  if pad < 0 then
    return {
      text = left_text,
      spans = spans,
      prompt_len = prompt_len,
      content_str = content_str,
    }
  end

  local pad_text = string.rep(' ', pad)
  local pad_byte = #left_text + #pad_text

  spans[#spans + 1] = { #left_text, pad_byte, cache:get(default_face) }
  for _, s in ipairs(mode_spans) do
    spans[#spans + 1] = { s[1] + pad_byte, s[2] + pad_byte, s[3] }
  end

  return {
    text = left_text .. pad_text .. mode_text,
    spans = spans,
    prompt_len = prompt_len,
    content_str = content_str,
  }
end

--- Render the kak status line into the surface's status float.
---@param surface kak.ui.surface.Surface?
---@param prompt kak.ui.protocol.Line?
---@param content kak.ui.protocol.Lines?
---@param cursor_pos integer 0-based codepoint column into content, or -1
---@param mode_line kak.ui.protocol.Line?
---@param default_face kak.ui.faces.Face?
---@param _style kak.ui.protocol.DrawStyle
---@param cache kak.ui.faces.Cache
function M.render(surface, prompt, content, cursor_pos, mode_line, default_face, _style, cache)
  if not surface then return end
  surface:ensure_status_float()
  local buf, win = surface.status_buf, surface.status_win
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  if not win or not vim.api.nvim_win_is_valid(win) then return end

  local dims = surface:editor_dims()
  local cols = dims.width

  local built = M.build_line(prompt, content, mode_line, default_face, cols, cache)

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { built.text })
  vim.bo[buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  for _, s in ipairs(built.spans) do
    if s[2] > s[1] then
      pcall(vim.api.nvim_buf_set_extmark, buf, NS, 0, s[1], {
        end_col = s[2],
        hl_group = s[3],
        right_gravity = false,
      })
    end
  end

  -- Prompt cursor: reverse extmark covering the codepoint at
  -- `prompt_len + cursor_byte`. Past end -> reverse space.
  if cursor_pos >= 0 then
    local cbyte_in_content = render.column_to_byte(built.content_str, cursor_pos)
    local cbyte = built.prompt_len + cbyte_in_content
    local clen
    if cbyte_in_content >= #built.content_str then
      clen = 1
      cbyte = built.prompt_len + #built.content_str
    else
      clen = render.codepoint_width(built.content_str, cbyte_in_content)
    end
    local cursor_face = {
      fg = (default_face and default_face.bg) or 'default',
      bg = (default_face and default_face.fg) or 'default',
      underline = 'default',
      attributes = { 'reverse' },
    }
    local cursor_hl = cache:get(cursor_face)
    local end_col = math.min(cbyte + clen, #built.text)
    if end_col <= cbyte then end_col = math.min(cbyte + 1, #built.text) end
    pcall(vim.api.nvim_buf_set_extmark, buf, NS, 0, cbyte, {
      end_col = end_col,
      hl_group = cursor_hl,
      right_gravity = false,
    })
  end

  if default_face then
    pcall(
      vim.api.nvim_set_option_value,
      'winhighlight',
      'Normal:' .. cache:get(default_face),
      { win = win }
    )
  end

  -- Reposition every render (cheap; covers resize).
  pcall(vim.api.nvim_win_set_config, win, {
    relative = 'editor',
    row = dims.height,
    col = 0,
    width = cols,
    height = 1,
  })
  pcall(vim.api.nvim__redraw, { win = win, flush = true })
end

return M
