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

describe('cursor extmark visual width', function()
  before_each(function() h.setup() end)

  it('covers 1 byte under ASCII cursor', function()
    local r = h.exec_lua(function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'abc' })
      vim.bo[buf].modifiable = false
      local render = require('kak.ui.render').new({ faces = require('kak.ui.faces').new() })
      render:set_buf(buf)
      render:draw({
        { { face = nil, contents = 'abc' } },
      }, { line = 0, column = 1 }, nil, nil)
      -- ns = -1 returns extmarks from every namespace.
      local marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
      local cursor = nil
      for _, m in ipairs(marks) do
        local hl = m[4] and m[4].hl_group
        if hl and hl:match('^KakFace_') then cursor = m end
      end
      return { count = cursor and 1 or 0, end_col = cursor and cursor[4].end_col or -1 }
    end)
    h.eq(1, r.count)
    h.eq(2, r.end_col)
  end)

  it('covers 3 bytes under CJK cursor', function()
    local r = h.exec_lua(function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '中文' })
      vim.bo[buf].modifiable = false
      local render = require('kak.ui.render').new({ faces = require('kak.ui.faces').new() })
      render:set_buf(buf)
      -- column 0 = before the first char, so cursor covers bytes 0..3.
      render:draw({
        { { face = nil, contents = '中文' } },
      }, { line = 0, column = 0 }, nil, nil)
      local marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
      local cursor = nil
      for _, m in ipairs(marks) do
        local hl = m[4] and m[4].hl_group
        if hl and hl:match('^KakFace_') then cursor = m end
      end
      return { count = cursor and 1 or 0, end_col = cursor and cursor[4].end_col or -1 }
    end)
    h.eq(1, r.count)
    h.eq(3, r.end_col)
  end)
end)