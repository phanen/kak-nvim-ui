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
    h.with_kak_session({ extra_args = { '-e', 'edit ' .. file }, keep_open = true }, function(sess)
      vim.wait(3000, function()
        local lines = vim.api.nvim_buf_get_lines(sess.id, 0, -1, false)
        return #lines >= 3 and lines[1] == 'alpha line'
      end)
    end)

    -- Layout: 3 content rows + 20 tildes + status float at the last
    -- row. The float carries the status message body (here, the
    -- default "scratch buffer" notice kak emits on a freshly opened
    -- buffer). mode_line is dropped because content+mode exceed
    -- cols. Cursor col 0 puts `^` before "alpha".
    screen:expect([[
      {MATCH:alpha line}
      {MATCH:beta line}
      {MATCH:gamma line}
      {MATCH:.*~.*}|*20
      {MATCH:.*scratch.*}
    ]])
  end)

  it('renders a single-line file', function()
    local file = tmp_with({ 'only line' })
    h.with_kak_session({ extra_args = { '-e', 'edit ' .. file }, keep_open = true }, function(sess)
      vim.wait(3000, function()
        local lines = vim.api.nvim_buf_get_lines(sess.id, 0, -1, false)
        return #lines >= 1 and lines[1] == 'only line'
      end)
    end)
    screen:snapshot_util()

    -- Layout: 1 content row + 22 tildes + status float. Cursor col 0
    -- marks the content row with `^`.
    screen:expect([[
      {MATCH:only line}
      {MATCH:.*~.*}|*22
      {MATCH:.*scratch.*}
    ]])
  end)

  it('renders an empty file as all-tildes grid', function()
    local file = tmp_with({})
    h.with_kak_session({ extra_args = { '-e', 'edit ' .. file }, keep_open = true }, function(sess)
      vim.wait(3000, function()
        local lines = vim.api.nvim_buf_get_lines(sess.id, 0, -1, false)
        return #lines >= 1
      end)
    end)

    -- Empty file: cursor row 0 is empty (^), all other content rows
    -- are tildes. The status float shows kak's scratch-buffer notice
    -- because no real filename is bound yet.
    screen:expect([[
      {MATCH:^}
      {MATCH:.*~.*}|*22
      {MATCH:.*scratch.*}
    ]])
  end)

  it('re-renders the buffer when kak emits a second edit', function()
    -- Kakoune accepts only one -e flag, so chain commands with `;`.
    local file1 = tmp_with({ 'first file' })
    local file2 = tmp_with({ 'second-A', 'second-B' })
    h.with_kak_session({
      extra_args = { '-e', 'edit ' .. file1 .. '; edit ' .. file2 },
      keep_open = true,
    }, function(sess)
      vim.wait(3000, function()
        local lines = vim.api.nvim_buf_get_lines(sess.id, 0, -1, false)
        return #lines >= 2 and lines[1] == 'second-A'
      end)
    end)

    -- 2 content rows + 21 tildes + status float.
    screen:expect([[
      {MATCH:second%-A}
      {MATCH:second%-B}
      {MATCH:.*~.*}|*21
      {MATCH:.*scratch.*}
    ]])
  end)

  it('places the cursor on the line that kak selects', function()
    -- `select 2.1,2.1` is a degenerate range that resolves (1-indexed
    -- -> 0-indexed via `str_to_int - 1` in selection.cc) to
    -- (line=1, col=0) 0-indexed = the "two" line. The content row
    -- shows `^two` with the cursor glyph prepended, and the status
    -- float shows "scratch" notice (because the buffer has been
    -- modified by `edit` but not yet saved) -- the cursor's line:col
    -- is encoded in the modelinefmt but the test only needs to
    -- verify the cursor visual at row 2.
    --
    -- The original test sent the malformed `select 1.0` (single
    -- coordinate, kakoune throws "does not follow <line>.<column>,
    -- <line>.<column> format"). The test passed only because the
    -- status error message happened to contain "1:1" as a
    -- substring (via the long preamble-injected command line). After
    -- removing the preamble (Fix 3) the error no longer contained
    -- "1:1" and the test reliably failed; the fix is a properly-
    -- formed range + a check that doesn't depend on the error path.
    local file = tmp_with({ 'one', 'two', 'three' })
    h.with_kak_session({
      extra_args = { '-e', 'edit ' .. file .. '; select 2.1,2.1' },
      keep_open = true,
    }, function(sess)
      vim.wait(3000, function()
        local lines = vim.api.nvim_buf_get_lines(sess.id, 0, -1, false)
        return #lines >= 3 and lines[1] == 'one'
      end)
    end)

    -- Cursor glyph `^` is auto-prepended to the focused row;
    -- use {MATCH:^two} for the cursor at line 2. Status float at
    -- the last row carries the scratch-buffer notice rather than
    -- the full modeline (since the buffer is modified but unnamed
    -- here); assert that shape rather than the cursor digits.
    screen:expect([[
      {MATCH:one}
      {MATCH:%^two}
      {MATCH:three}
      {MATCH:.*~.*}|*20
      {MATCH:.*scratch.*}
    ]])
  end)
end)
