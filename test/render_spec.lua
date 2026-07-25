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

describe('statusbar.compose', function()
  before_each(function() h.setup() end)

  -- All cases are pure compose calls (no window interaction); the
  -- returned string is checked against Lua patterns since the cache
  -- generates per-process hl group names like KakFace_<hash>.

  it('inserts the cursor cell at cursor_pos and joins mode_line via %=', function()
    local r = h.exec_lua(function()
      local s = require('kak.ui.statusbar')
      local faces = require('kak.ui.faces').new()
      local df = { fg = 'default', bg = 'default', underline = 'default', attributes = {} }
      return s.compose(
        { { face = df, contents = ':' } },
        { { { face = df, contents = 'hello' } } },
        4,
        { { face = df, contents = 'NORMAL' } },
        df,
        'command',
        faces
      )
    end)
    -- %= separates left/right; left content is "hell" + reverse cell on "o".
    assert(r:find('%=', 1, true), 'expected %= separator, got: ' .. r)
    assert(r:find('NORMAL', 1, true), 'expected mode_line text on right side, got: ' .. r)
    assert(r:sub(1, 2) == '%#', 'string must start with a hl group marker')
    -- Cursor cell wraps the char at column 4 (zero-based): 'hell' | 'o' | ''
    -- Pattern: literal 'hell', then literal '%*%#' (end base + start hl),
    -- then any chars except '#', then '#', then literal 'o', then literal '%*'.
    -- '%%%*' (pattern) = literal '%*' (2 chars).
    assert(r:find('hell%%%*%%%#[^#]+#o%%%*'), 'expected cursor cell wrapping o, got: ' .. r)
  end)

  it('emits no cursor cell when cursor_pos < 0 (style=status)', function()
    local r = h.exec_lua(function()
      local s = require('kak.ui.statusbar')
      local faces = require('kak.ui.faces').new()
      local df = { fg = 'default', bg = 'default', underline = 'default', attributes = {} }
      return s.compose(
        { { face = df, contents = ':' } },
        { { { face = df, contents = 'hello' } } },
        -1,
        { { face = df, contents = 'NORMAL' } },
        df,
        'status',
        faces
      )
    end)
    assert(r:find('hello', 1, true), 'expected hello text in compose, got: ' .. r)
    assert(r:find('%=', 1, true), 'expected %= separator, got: ' .. r)
    -- No cursor group (`KakFace_` with `reverse`) should appear; the
    -- cursor face is computed but unused when cursor_pos < 0, so the
    -- only KakFace_* groups that appear are those for atoms with non-
    -- default face attributes (none here).
    for hl in r:gmatch('%%#([^#]+)#') do
      assert(not hl:match('reverse'), 'no reverse cursor group expected, got: ' .. hl)
    end
  end)

  it('escapes % in atom contents so nvim does not interpret it', function()
    local r = h.exec_lua(function()
      local s = require('kak.ui.statusbar')
      local faces = require('kak.ui.faces').new()
      local df = { fg = 'default', bg = 'default', underline = 'default', attributes = {} }
      return s.compose({ { face = df, contents = '50% off' } }, nil, -1, nil, df, 'status', faces)
    end)
    -- esc turns '50% off' -> '50%% off'; the literal '%%' appears once.
    assert(r:find('50%%', 1, true), 'expected 50%% (escaped), got: ' .. r)
    -- A nvim statusline item that starts with '%o' (filenamenr) must
    -- not appear: every literal '%' in the atom contents was doubled,
    -- so '%o' should never be present in the composed string.
    assert(not r:find('%%o'), 'unexpected unescaped %o statusline item: ' .. r)
    assert(r:find('off'), 'expected "off" in composed string: ' .. r)
  end)

  it('places cursor cell after content when cursor_pos >= content length', function()
    local r = h.exec_lua(function()
      local s = require('kak.ui.statusbar')
      local faces = require('kak.ui.faces').new()
      local df = { fg = 'default', bg = 'default', underline = 'default', attributes = {} }
      return s.compose(
        { { face = df, contents = ':' } },
        { { { face = df, contents = 'hi' } } },
        99,
        { { face = df, contents = 'NORMAL' } },
        df,
        'command',
        faces
      )
    end)
    -- The "after" cursor cell is a reverse space at the end of content.
    -- Use a pattern so the hl group name wildcard works. '%%%*' = literal
    -- '%*' (2 chars); ' ' is literal space; '# ' is literal `# ` and so on.
    assert(r:find('hi%%%*%%%#[^#]+# %%%%*'), 'expected cursor space after hi, got: ' .. r)
    assert(r:find('NORMAL', 1, true), 'mode_line still on right: ' .. r)
  end)

  it('collapses to empty LEFT when no prompt/content/mode_line', function()
    local r = h.exec_lua(function()
      local s = require('kak.ui.statusbar')
      local faces = require('kak.ui.faces').new()
      return s.compose(nil, nil, -1, nil, nil, 'status', faces)
    end)
    h.eq('', r)
  end)

  it('strips trailing \\n / \\r from atom contents so &statusline has no newlines', function()
    local r = h.exec_lua(function()
      local s = require('kak.ui.statusbar')
      local faces = require('kak.ui.faces').new()
      local df = { fg = 'default', bg = 'default', underline = 'default', attributes = {} }
      return s.compose(
        { { face = df, contents = ':\n' } },
        { { { face = df, contents = 'edit foo\n' } } },
        4,
        { { face = df, contents = 'NORMAL\n' } },
        df,
        'command',
        faces
      )
    end)
    -- The composed &statusline string must contain NO line terminators
    -- (Kakoune appends `\n` to atoms; stripping them keeps the cmdline
    -- visible instead of letting nvim garble the statusline).
    assert(not r:match('[\r\n]'), 'expected no \\r or \\n in composed statusline, got: ' .. r)
    -- The visible text content (prompt + typed + mode_line) is preserved.
    -- The cursor cell at column 4 wraps the space; each atom lives in
    -- its own hl-group chunk, so the boundaries are `%*%#KakFace_...#`.
    -- Allow those between visible fragments.
    local function contains_pieces(s, pieces)
      local pos = 1
      for _, p in ipairs(pieces) do
        local s_esc = (p:gsub('%%', '%%%%')):gsub('([%(%)%.%%%+%-%*%?%[%]%^%$])', '%%%1')
        -- match the visible fragment OR `%*%#KakFace_...#` (hl-group
        -- boundary) as a separator; advance past whichever we find.
        local pat = '()' .. s_esc
        local pat_at = s:find(pat, pos)
        local bnd_at = s:find('%%%*%%%#KakFace_%w+#', pos)
        if pat_at and (not bnd_at or pat_at < bnd_at) then
          pos = pat_at + #p
        elseif bnd_at then
          local _, e = s:find('%%%*%%%#KakFace_%w+#', pos)
          pos = e + 1
        else
          return false
        end
      end
      return true
    end
    assert(
      contains_pieces(r, { ':', 'edit', ' ', 'foo', 'NORMAL' }),
      'expected ":edit foo" cmdline + NORMAL mode visible, got: ' .. r
    )
  end)
end)
