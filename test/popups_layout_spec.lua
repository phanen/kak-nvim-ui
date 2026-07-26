-- Tests for the pure-popup-positioning math (popups.layout) and the
-- box-frame extmark painter (popups.frame). These bypass nvim-test's
-- renderer wiring so the layout decisions can be unit-tested in
-- isolation.

local h = require('test.helpers')

local function with_screen(body_src)
  return h.exec_lua(function(src)
    local body = assert(loadstring(src))
    return body()
  end, body_src)
end

describe('popups layout', function()
  before_each(function() h.setup() end)

  it('choose_float_or_inline routes search->inline and everything else->float', function()
    local r = with_screen([[
      local layout = require('kak.ui.popups.layout')
      return {
        search = layout.choose_float_or_inline('search', 5),
        prompt = layout.choose_float_or_inline('prompt', 5),
        inline = layout.choose_float_or_inline('inline', 5),
        long   = layout.choose_float_or_inline('inline', 999),
      }
    ]])
    h.eq('inline', r.search)
    h.eq('float', r.prompt)
    h.eq('float', r.inline)
    h.eq('float', r.long)
  end)

  it('menu_pos style=prompt uses NW anchor with row=editor_h-h, col=0', function()
    local geom = with_screen([[
      local layout = require('kak.ui.popups.layout')
      -- item_count=10 maps to height=min(10, 20)=10; items_max=40 -> width=40.
      local g = layout.menu_pos(
        'prompt', { line = 0, column = 0 }, nil,
        { width = 80, height = 24 }, 10, 40
      )
      return {
        win_anchor = g.win_anchor,
        row = g.row,
        col = g.col,
        height = g.height,
        width = g.width,
      }
    ]])
    h.eq('NW', geom.win_anchor)
    h.eq(24 - 10, geom.row)
    h.eq(0, geom.col)
    h.eq(10, geom.height)
    h.eq(40, geom.width)
  end)

  it('menu_pos does not leak globals', function()
    local ok = with_screen([[
      local layout = require('kak.ui.popups.layout')
      layout.menu_pos('prompt', { line = 0, column = 0 }, nil, { width = 80, height = 24 })
      return { h = _G.h, w = _G.w }
    ]])
    -- Cleanup just in case the bug regressed (and to keep global
    -- state unpolluted for later tests).
    if ok.h ~= nil or ok.w ~= nil then
      _G.h = nil
      _G.w = nil
    end
    h.eq(nil, ok.h)
    h.eq(nil, ok.w)
  end)

  it('info_geom menuDoc picks LEFT when right is narrower', function()
    local out = with_screen([[
      local layout = require('kak.ui.popups.layout')
      local menu_rect = { pos = { line = 0, column = 60 }, size = { line = 5, column = 20 } }
      local editor_dims = { width = 80, height = 24 }
      local geom = layout.info_pos('menuDoc', { line = 0, column = 0 }, menu_rect, nil, editor_dims)
      geom = layout.info_geom(
        'menuDoc', geom, { line = 0, column = 0 }, menu_rect,
        { { face = nil, contents = 'doc' } },
        { { { face = nil, contents = 'hello' } } },
        editor_dims
      )
      return {
        win_anchor = geom.win_anchor,
        row = geom.row,
        col = geom.col,
        width = geom.width,
      }
    ]])
    h.eq('NE', out.win_anchor)
    h.eq(60, out.col) -- LEFT: right edge of window at menu's left edge
    -- width is max_line_len(=5) + 2 = 7 in this geometry.
    h.eq(7, out.width)
  end)

  it('info_geom modal does not subtract menu height', function()
    local out = with_screen([[
      local layout = require('kak.ui.popups.layout')
      local function mod(maybe_rect)
        local geom = layout.info_pos(
          'modal', { line = 0, column = 0 }, maybe_rect, nil,
          { width = 80, height = 24 }
        )
        return layout.info_geom(
          'modal', geom, { line = 0, column = 0 }, maybe_rect,
          { { face = nil, contents = 'T' } },
          { { { face = nil, contents = 'B' } } },
          { width = 80, height = 24 }
        ).row
      end
      local with_menu = mod({ pos = { line = 0, column = 0 }, size = { line = 5, column = 5 } })
      local no_menu = mod(nil)
      return { with_menu = with_menu, no_menu = no_menu }
    ]])
    -- Kakoune centers modal against the full editor; an active menu
    -- must NOT drag the centre upward.
    h.eq(out.no_menu, out.with_menu)
  end)

  it('info_geom prompt caps height at editor_h - menu_h', function()
    local out = with_screen([[
      local layout = require('kak.ui.popups.layout')
      local function mk(menu_rect)
        local geom = layout.info_pos(
          'prompt', { line = 0, column = 0 }, nil,
          { width = 80, height = 24 }
        )
        local content = {}
        for i = 1, 30 do content[i] = { { face = nil, contents = 'x' } } end
        return layout.info_geom(
          'prompt', geom, { line = 0, column = 0 }, menu_rect,
          { { face = nil, contents = 'T' } }, content,
          { width = 80, height = 24 }
        ).height
      end
      local with_menu = mk({ pos = { line = 20, column = 0 }, size = { line = 4, column = 80 } })
      local no_menu = mk(nil)
      return { with_menu = with_menu, no_menu = no_menu }
    ]])
    -- 24 total rows; a 4-row menu at the bottom caps prompt info at
    -- 24 - 4 = 20. Without a menu the cap is the full 24 rows.
    h.eq(20, out.with_menu)
    h.eq(24, out.no_menu)
  end)

  it('info_geom prompt moves above a bottom-spanning menu', function()
    local out = with_screen([[
      local layout = require('kak.ui.popups.layout')
      local menu_rect = { pos = { line = 20, column = 0 }, size = { line = 4, column = 80 } }
      local geom = layout.info_pos(
        'prompt', { line = 0, column = 0 }, nil, { width = 80, height = 24 }
      )
      local content = {}
      for i = 1, 5 do content[i] = { { face = nil, contents = 'x' } } end
      geom = layout.info_geom(
        'prompt', geom, { line = 0, column = 0 }, menu_rect,
        { { face = nil, contents = 'T' } }, content,
        { width = 80, height = 24 }
      )
      return { win_anchor = geom.win_anchor, row = geom.row, col = geom.col }
    ]])
    -- Default SE at (24,80) would place the info at rows [16,23] /
    -- cols [73,79], which overlaps the menu at rows [20,23] / cols
    -- [0,79]. compute_pos nudges it above the menu: NW anchor, row
    -- = min(menu_top=20, editor_h=24) - height(=8) = 12, col stays
    -- right-justified at editor_w - width = 80 - 7 = 73.
    h.eq('NW', out.win_anchor)
    h.eq(12, out.row)
    h.eq(73, out.col)
  end)

  it('frame.box_extmarks places title extmark at prefix-aware column', function()
    local out = with_screen([[
      local cache = require('kak.ui.faces').new()
      local frame = require('kak.ui.popups.frame')
      local buf = vim.api.nvim_create_buf(false, true)
      local ns = vim.api.nvim_create_namespace('kak-test-frame')
      frame.box_extmarks(
        buf, ns,
        20, 3,
        { { face = { fg = 'default', bg = 'default', underline = 'default', attributes = {} },
            contents = 'Foo' } },
        { 'body' },
        { fg = 'default', bg = 'default', underline = 'default', attributes = {} },
        cache
      )
      local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
      -- Keep marks that look like the per-atom title highlight (not
      -- the row-wide bg highlight, which spans col=0..width).
      local title_marks = {}
      for _, m in ipairs(marks) do
        if m[2] == 0 and m[4].end_col and (m[4].end_col - m[3]) <= 8 then
          title_marks[#title_marks + 1] = { col = m[3], end_col = m[4].end_col }
        end
      end
      -- Identify the byte position of `┤` inside the top frame: that
      -- is where `t_start` would land (HL_SEP_T is 3 bytes UTF-8).
      local top = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ''
      local t_byte = top:find('┤', 1, true) + 3
      return {
        n = #title_marks,
        first = title_marks[1],
        t_byte = t_byte,
      }
    ]])
    assert(out.n >= 1, 'expected at least one title extmark')
    h.eq(true, out.first.col > 4)
    -- The 'Foo' atom occupies 3 bytes ending at t_byte + 3 at most.
    assert(
      out.first.end_col <= out.t_byte + 3,
      'title end_col should be within the title segment: '
        .. tostring(out.first.end_col)
        .. ' <= '
        .. tostring(out.t_byte + 3)
    )
  end)
end)
