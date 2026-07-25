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

describe('set_prompt is dead state storage (6761b80 behavior)', function()
  before_each(function() h.setup() end)

  -- Regression: Phase 4 commit 4a0cd6a added a render_prompt method
  -- that wrote a virt_text overlay at the last visible row. That
  -- overlay replaced the buffer text at that row (obscuring highlight)
  -- and required cursor handling tricks that misplace the main
  -- cursor. 6761b80's set_prompt only stored prompt state without
  -- rendering anything -- cursor + highlight stayed correct.
  it('does not write any prompt extmark to the buffer', function()
    local r = h.exec_lua(function()
      local m = require('kak.ui.render')
      local cache = require('kak.ui.faces').new()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'one', 'two' })
      vim.bo[buf].modifiable = false
      local render = m.new({ faces = cache })
      render:set_buf(buf)
      local df = { fg = 'default', bg = 'default', underline = 'default', attributes = {} }
      render:set_prompt(
        { { face = df, contents = ':' } },
        { { { face = df, contents = 'edit' } } },
        4,
        df,
        'command'
      )
      local prompt_ns = vim.api.nvim_create_namespace('kak.ui.render.prompt')
      return {
        prompt_marks = vim.api.nvim_buf_get_extmarks(buf, prompt_ns, 0, -1, {}),
        state_style = render.prompt_state.style,
        state_cursor = render.prompt_state.cursor,
      }
    end)
    h.eq(0, #r.prompt_marks)
    -- State is still recorded for inspection.
    h.eq('command', r.state_style)
    h.eq(4, r.state_cursor)
  end)

  it('preserves the main cursor extmark when set_prompt fires in command mode', function()
    -- The bug from 4a0cd6a: render_prompt cleared or moved the
    -- cursor extmark. With the no-op set_prompt the cursor extmark
    -- placed by draw remains in place, so the cursor stays where
    -- Kakoune reported and the highlight under it survives.
    local r = h.exec_lua(function()
      local m = require('kak.ui.render')
      local cache = require('kak.ui.faces').new()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'one', 'two', 'three' })
      vim.bo[buf].modifiable = false
      local render = m.new({ faces = cache })
      render:set_buf(buf)
      local df = { fg = 'red', bg = 'default', underline = 'default', attributes = {} }

      local cursor_ns = vim.api.nvim_create_namespace('kak.ui.render.cursor')
      local content_ns = vim.api.nvim_create_namespace('kak.ui.render.content')

      render:draw({
        { { { face = df, contents = 'one' } } },
        { { { face = df, contents = 'two' } } },
        { { { face = df, contents = 'three' } } },
      }, { line = 0, column = 0 }, df, nil)
      local before = {
        cursor_marks = vim.api.nvim_buf_get_extmarks(buf, cursor_ns, 0, -1, {}),
        content_marks = vim.api.nvim_buf_get_extmarks(buf, content_ns, 0, -1, {}),
      }

      render:set_prompt(
        { { face = df, contents = ':' } },
        { { { face = df, contents = 'edit' } } },
        0,
        df,
        'command'
      )

      local after = {
        cursor_marks = vim.api.nvim_buf_get_extmarks(buf, cursor_ns, 0, -1, {}),
        content_marks = vim.api.nvim_buf_get_extmarks(buf, content_ns, 0, -1, {}),
      }

      return { before = before, after = after }
    end)

    -- Cursor extmark count and content extmark count are unchanged
    -- by set_prompt.
    h.eq(#r.before.cursor_marks, #r.after.cursor_marks)
    h.eq(#r.before.content_marks, #r.after.content_marks)
  end)
end)
