-- Tests for the real `kak -ui json` session: spawn, render, screen grid.

local h = require('test.helpers')

---@param lines string[]
---@return string
local function tmp_with(lines)
  local path = h.write_file(lines)
  finally(function() os.remove(path) end)
  return path
end

describe('kak session lifecycle', function()
  before_each(function() h.setup() end)

  it('spawns kak and emits subprocess exit on close', function()
    local log = h.fn.tempname() .. '.log'
    finally(function() os.remove(log) end)
    h.with_kak_session({
      cmd = { '/usr/bin/kak' },
      wire_log = log,
    }, function(sess)
      vim.wait(3000, function() return sess.conn:is_closing() end)
    end)
    h.assert_log('subprocess exit', log)
  end)

  it('forwards ESC through input.from_on_key', function()
    local notation_ok = h.exec_lua(function()
      local m = require('kak.ui.input')
      local raw = vim.api.nvim_replace_termcodes('<Esc>', true, false, true)
      local keys = m.from_on_key(raw)
      return keys[1] == '<esc>'
    end)
    h.eq(true, notation_ok)
  end)
end)

describe('kak renders buffer + grid', function()
  local screen
  before_each(function()
    h.setup()
    screen = h.with_screen(80, 24)
  end)
  after_each(function()
    if screen then
      screen:detach()
      screen = nil
    end
  end)

  it('renders a multi-line file into the content buffer', function()
    local file = tmp_with({ 'alpha line', 'beta line', 'gamma line' })
    h.with_kak_session({ extra_args = { '-e', 'edit ' .. file } }, function(sess)
      vim.wait(3000, function()
        local lines = vim.api.nvim_buf_get_lines(sess.buf, 0, -1, false)
        return #lines >= 3 and lines[1] == 'alpha line'
      end)
    end)

    screen:expect([[
      {MATCH:^.*k//main.*}
      {MATCH:alpha line}
      {MATCH:beta line}
      {MATCH:gamma line}
      {MATCH:.*~.*}|*19
      {MATCH:^ *}
    ]])
  end)

  it('renders a single-line file', function()
    local file = tmp_with({ 'only line' })
    h.with_kak_session({ extra_args = { '-e', 'edit ' .. file } }, function(sess)
      vim.wait(3000, function()
        local lines = vim.api.nvim_buf_get_lines(sess.buf, 0, -1, false)
        return #lines >= 1 and lines[1] == 'only line'
      end)
    end)
    screen:snapshot_util()

    screen:expect([[
      {MATCH:^.*k//main.*}
      {MATCH:only line}
      {MATCH:.*~.*}|*21
      {MATCH:^ *}
    ]])
  end)

  it('renders an empty file as all-tildes grid', function()
    local file = tmp_with({})
    h.with_kak_session({ extra_args = { '-e', 'edit ' .. file } }, function(sess)
      vim.wait(3000, function()
        local lines = vim.api.nvim_buf_get_lines(sess.buf, 0, -1, false)
        return #lines >= 1
      end)
    end)

    -- 1 mode + 1 cursor-on-empty row + 21 tildes + 1 cmdline.
    screen:expect([[
      {MATCH:^.*k//main.*}
      {MATCH:^ *}
      {MATCH:.*~.*}|*21
      {MATCH:^ *}
    ]])
  end)

  it('re-renders the buffer when kak emits a second edit', function()
    -- Kakoune accepts only one -e flag, so chain commands with `;`.
    local file1 = tmp_with({ 'first file' })
    local file2 = tmp_with({ 'second-A', 'second-B' })
    h.with_kak_session({
      extra_args = { '-e', 'edit ' .. file1 .. '; edit ' .. file2 },
    }, function(sess)
      vim.wait(3000, function()
        local lines = vim.api.nvim_buf_get_lines(sess.buf, 0, -1, false)
        return #lines >= 2 and lines[1] == 'second-A'
      end)
    end)

    screen:expect([[
      {MATCH:^.*k//main.*}
      {MATCH:second%-A}
      {MATCH:second%-B}
      {MATCH:.*~.*}|*20
      {MATCH:^ *}
    ]])
  end)

  it('places the cursor on the line that kak selects', function()
    -- `select 1.0` (0-indexed line) jumps cursor to line 2 column 0.
    local file = tmp_with({ 'one', 'two', 'three' })
    h.with_kak_session({
      extra_args = { '-e', 'edit ' .. file .. '; select 1.0' },
    }, function(sess)
      vim.wait(3000, function()
        local lines = vim.api.nvim_buf_get_lines(sess.buf, 0, -1, false)
        return #lines >= 3 and lines[1] == 'one'
      end)
    end)

    -- The cursor glyph `^` is auto-prepended to the focused row;
    -- use {MATCH:two} not {MATCH:^two}.
    screen:expect([[
      {MATCH:^.*k//main.*}
      {MATCH:one}
      {MATCH:two}
      {MATCH:three}
      {MATCH:.*~.*}|*19
      {MATCH:^ *}
    ]])
  end)
end)
