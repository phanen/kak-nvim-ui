-- Tests for `kak.ui.render` (column/byte/width/cursor extmark).

local h = require('test.helpers')

describe('column to byte', function()
  before_each(function() h.setup() end)

  it('converts codepoint column to byte offset (ASCII)', function()
    local r = h.exec_lua(
      function()
        return {
          require('kak.ui.render').column_to_byte('hello', 0),
          require('kak.ui.render').column_to_byte('hello', 3),
          require('kak.ui.render').column_to_byte('hello', 5),
          require('kak.ui.render').column_to_byte('hello', 99),
        }
      end
    )
    h.eq(0, r[1])
    h.eq(3, r[2])
    h.eq(5, r[3])
    h.eq(5, r[4])
  end)

  it('converts codepoint column to byte offset (UTF-8 2-byte)', function()
    local r = h.exec_lua(
      function()
        return {
          require('kak.ui.render').column_to_byte('héllo', 1),
          require('kak.ui.render').column_to_byte('héllo', 2),
          require('kak.ui.render').column_to_byte('héllo', 3),
          require('kak.ui.render').column_to_byte('héllo', 5),
        }
      end
    )
    h.eq(1, r[1])
    h.eq(3, r[2])
    h.eq(4, r[3])
    h.eq(6, r[4])
  end)

  it('handles CJK 3-byte codepoints', function()
    local r = h.exec_lua(
      function()
        return {
          require('kak.ui.render').column_to_byte('中文', 0),
          require('kak.ui.render').column_to_byte('中文', 1),
          require('kak.ui.render').column_to_byte('中文', 2),
        }
      end
    )
    h.eq(0, r[1])
    h.eq(3, r[2])
    h.eq(6, r[3])
  end)
end)

describe('codepoint width', function()
  before_each(function() h.setup() end)

  it('returns 1 byte for ASCII', function()
    local r = h.exec_lua(function()
      local m = require('kak.ui.render')
      return { m.codepoint_width('a', 0), m.codepoint_width('hello', 2) }
    end)
    h.eq(1, r[1])
    h.eq(1, r[2])
  end)

  it('returns 2 bytes for Latin-1 supplementary', function()
    local r = h.exec_lua(
      function() return require('kak.ui.render').codepoint_width('héllo', 1) end
    )
    h.eq(2, r)
  end)

  it('returns 3 bytes for CJK', function()
    local r = h.exec_lua(function()
      local m = require('kak.ui.render')
      return { m.codepoint_width('中文', 0), m.codepoint_width('中文', 3) }
    end)
    h.eq(3, r[1])
    h.eq(3, r[2])
  end)

  it('returns 1 for past end-of-line', function()
    local r = h.exec_lua(function()
      local m = require('kak.ui.render')
      return { m.codepoint_width('', 0), m.codepoint_width('a', 5), m.codepoint_width('a', -1) }
    end)
    h.eq(1, r[1])
    h.eq(1, r[2])
    h.eq(1, r[3])
  end)
end)

describe('cursor placement', function()
  before_each(function() h.setup() end)

  it('places real nvim cursor on ASCII text at column=1', function()
    local r = h.exec_lua(function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'abc' })
      vim.bo[buf].modifiable = false
      local win = vim.api.nvim_open_win(buf, false, {
        relative = 'editor',
        row = 0,
        col = 0,
        width = 80,
        height = 24,
        style = 'minimal',
      })
      local render = require('kak.ui.render').new({ faces = require('kak.ui.faces').new() })
      render:set_buf(buf)
      render:draw({
        { { face = nil, contents = 'abc' } },
      }, { line = 0, column = 1 }, nil, nil)
      local pos = vim.api.nvim_win_get_cursor(win)
      local cursor_ns = vim.api.nvim_create_namespace('kak.ui.render.cursor')
      local remaining = #vim.api.nvim_buf_get_extmarks(buf, cursor_ns, 0, -1, {})
      pcall(vim.api.nvim_win_close, win, true)
      return { pos = pos, cursor_marks = remaining }
    end)
    h.eq({ 1, 1 }, r.pos)
    h.eq(0, r.cursor_marks)
  end)

  it('places real nvim cursor on CJK text at column=0', function()
    local r = h.exec_lua(function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '中文' })
      vim.bo[buf].modifiable = false
      local win = vim.api.nvim_open_win(buf, false, {
        relative = 'editor',
        row = 0,
        col = 0,
        width = 80,
        height = 24,
        style = 'minimal',
      })
      local render = require('kak.ui.render').new({ faces = require('kak.ui.faces').new() })
      render:set_buf(buf)
      render:draw({
        { { face = nil, contents = '中文' } },
      }, { line = 0, column = 0 }, nil, nil)
      local pos = vim.api.nvim_win_get_cursor(win)
      local cursor_ns = vim.api.nvim_create_namespace('kak.ui.render.cursor')
      local remaining = #vim.api.nvim_buf_get_extmarks(buf, cursor_ns, 0, -1, {})
      pcall(vim.api.nvim_win_close, win, true)
      return { pos = pos, cursor_marks = remaining }
    end)
    h.eq({ 1, 0 }, r.pos)
    h.eq(0, r.cursor_marks)
  end)
end)

describe('statusbar.build_line', function()
  before_each(function() h.setup() end)

  -- Pure compose-style tests for the float-buffer builder. The float
  -- rendering itself is covered end-to-end by kak_session_spec screen
  -- tests; these cases verify the math that drives the cursor extmark
  -- and the right-justified mode_line.

  it('places prompt on left, pads, and right-justifies mode_line', function()
    local r = h.exec_lua(function()
      local s = require('kak.ui.statusbar')
      local faces = require('kak.ui.faces').new()
      local df = { fg = 'default', bg = 'default', underline = 'default', attributes = {} }
      local built = s.build_line(
        { { face = df, contents = ':' } },
        { { { face = df, contents = 'hello' } } },
        { { face = df, contents = 'NORMAL' } },
        df,
        40,
        faces
      )
      local n_at = built.text:find('NORMAL', 1, true)
      return {
        prompt_len = built.prompt_len,
        left = built.text:sub(1, 6),
        n_at = n_at,
        width = vim.fn.strdisplaywidth(built.text),
        left_width = n_at and vim.fn.strdisplaywidth(built.text:sub(1, n_at - 1)) or nil,
      }
    end)
    h.eq(1, r.prompt_len)
    h.eq(':hello', r.left)
    h.eq(40, r.width)
    h.eq(40 - 6, r.left_width)
  end)

  it(
    'strips trailing \\n / \\r from atom contents so the float text has no line terminators',
    function()
      local r = h.exec_lua(function()
        local s = require('kak.ui.statusbar')
        local faces = require('kak.ui.faces').new()
        local df = { fg = 'default', bg = 'default', underline = 'default', attributes = {} }
        return s.build_line(
          { { face = df, contents = ':\n' } },
          { { { face = df, contents = 'edit foo\n' } } },
          { { face = df, contents = 'NORMAL\n' } },
          df,
          40,
          faces
        )
      end)
      -- No line terminators in the buffer text (Kakoune terminates atoms
      -- with \n; we strip them so the float renders on a single row).
      assert(not r.text:match('[\r\n]'), 'expected no \\r or \\n in built text, got: ' .. r.text)
      assert(
        r.text:find(':edit foo', 1, true) ~= nil,
        'expected ":edit foo" visible, got: ' .. r.text
      )
      assert(r.text:find('NORMAL', 1, true) ~= nil, 'expected mode_line visible, got: ' .. r.text)
    end
  )

  it('tracks one span per atom byte range (prompt + content + mode)', function()
    local r = h.exec_lua(function()
      local s = require('kak.ui.statusbar')
      local faces = require('kak.ui.faces').new()
      local df = { fg = 'default', bg = 'default', underline = 'default', attributes = {} }
      return s.build_line(
        { { face = df, contents = ':' } },
        { { { face = df, contents = 'ab' }, { face = df, contents = 'cd' } } },
        { { face = df, contents = 'XY' } },
        df,
        20,
        faces
      )
    end)
    -- text = ':abcd' + padding + 'XY'; spans (b0,b1,hl):
    -- prompt ':'   -> 0..1
    -- content 'ab'  -> 1..3
    -- content 'cd'  -> 3..5
    -- pad spaces    -> 5..(5 + pad)  (uses default face hl)
    -- mode 'XY'     -> 5+pad..7+pad
    local pad_end = 5 + (#r.text - 7)
    assert(r.spans[1][1] == 0 and r.spans[1][2] == 1, 'prompt span mismatch')
    assert(r.spans[2][1] == 1 and r.spans[2][2] == 3, 'ab span mismatch')
    assert(r.spans[3][1] == 3 and r.spans[3][2] == 5, 'cd span mismatch')
    assert(r.spans[4][1] == 5 and r.spans[4][2] == pad_end, 'pad span mismatch')
    assert(r.spans[5][1] == pad_end and r.spans[5][2] == pad_end + 2, 'mode span mismatch')
    -- Every hl_group is a non-empty string (cache:get returns at least
    -- KakDefault for nil faces).
    for _, s in ipairs(r.spans) do
      assert(type(s[3]) == 'string' and #s[3] > 0, 'span missing hl_group')
    end
  end)

  it('drops mode_line when it does not fit', function()
    local r = h.exec_lua(function()
      local s = require('kak.ui.statusbar')
      local faces = require('kak.ui.faces').new()
      local df = { fg = 'default', bg = 'default', underline = 'default', attributes = {} }
      return s.build_line(
        { { face = df, contents = 'this-prompt' } },
        { { { face = df, contents = string.rep('x', 50) } } },
        { { face = df, contents = 'LONG_MODE_LINE' } },
        df,
        10,
        faces
      )
    end)
    assert(
      not r.text:find('LONG_MODE_LINE', 1, true),
      'expected mode_line dropped when it does not fit, got: ' .. r.text
    )
  end)

  it('no padding when mode_line is absent', function()
    local r = h.exec_lua(function()
      local s = require('kak.ui.statusbar')
      local faces = require('kak.ui.faces').new()
      local df = { fg = 'default', bg = 'default', underline = 'default', attributes = {} }
      return s.build_line(
        { { face = df, contents = ':' } },
        { { { face = df, contents = 'hello' } } },
        nil,
        df,
        40,
        faces
      )
    end)
    h.eq(':hello', r.text)
    h.eq(1, r.prompt_len)
  end)

  it(
    'cursor byte math: prompt_len + column_to_byte(content) places the cursor correctly',
    function()
      -- M.render's cursor math uses prompt_len + render.column_to_byte
      -- against content_str. Validate that the build_line output makes
      -- those values self-consistent for ASCII and UTF-8 supplementary.
      local r = h.exec_lua(function()
        local s = require('kak.ui.statusbar')
        local render = require('kak.ui.render')
        local faces = require('kak.ui.faces').new()
        local df = { fg = 'default', bg = 'default', underline = 'default', attributes = {} }
        local built = s.build_line(
          { { face = df, contents = ':' } },
          { { { face = df, contents = 'héllo' } } },
          nil,
          df,
          40,
          faces
        )
        local b2 = render.column_to_byte(built.content_str, 2)
        return {
          cbyte_at_2 = built.prompt_len + b2,
          clen_at_2 = render.codepoint_width(built.content_str, b2),
          cbyte_past = built.prompt_len + render.column_to_byte(built.content_str, 99),
          text_len = #built.text,
        }
      end)
      -- 'héllo' is 7 bytes; column 2 (zero-based) is the 'l'.
      -- h(1) é(2..3) l(4) -> column_to_byte(content, 2) = byte 3.
      h.eq(1 + 3, r.cbyte_at_2)
      h.eq(1, r.clen_at_2)
      -- column 99 is past end; column_to_byte clamps to #content_str=6,
      -- so cursor sits at byte 1+6 = 7.
      h.eq(1 + 6, r.cbyte_past)
    end
  )
end)
