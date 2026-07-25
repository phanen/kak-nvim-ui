-- Regression test: the status float must reflect typed command-mode chars
-- AND the real nvim cursor must move to the status float (ui2-style
-- cmdline overlay). Uses buffer-text + per-window cursor assertions so
-- the test stays robust against unrelated UI changes.

local h = require('test.helpers')

describe('cmdline float', function()
  before_each(function() h.setup() end)

  it('typed char shows in status float; real cursor moves into the float', function()
    local file = h.write_file({ 'abcdef' })
    finally(function() os.remove(file) end)

    -- The body runs inside nvim's Lua VM where the global `assert` is
    -- the built-in function, not busted's table. Capture state into a
    -- table and assert outside the body.
    local r = h.with_kak_session({
      extra_args = { '-e', 'edit ' .. file },
      keep_open = true,
    }, function(sess)
      -- Capture every draw_status so we can wait until kak has acked
      -- both the `:` and the `e`.
      local cap = {}
      local orig = sess.conn.dispatchers.on_notify
      sess.conn.dispatchers.on_notify = function(method, params)
        if method == 'draw_status' then cap[#cap + 1] = params end
        if orig then return orig(method, params) end
      end

      sess.conn:notify('keys', { ':' })
      vim.wait(1000, function() return #cap > 0 end)
      local after_colon = #cap
      sess.conn:notify('keys', { 'e' })
      vim.wait(1000, function() return #cap > after_colon end)

      local surface = sess.surface
      local status_buf = surface and surface.status_buf
      local status_win = surface and surface.status_win
      local content_win = surface and surface.content_win

      return {
        have_float = status_win ~= nil
          and status_buf ~= nil
          and vim.api.nvim_win_is_valid(status_win)
          and vim.api.nvim_buf_is_valid(status_buf),
        status_buf_lines = (status_buf and vim.api.nvim_buf_is_valid(status_buf))
            and vim.api.nvim_buf_get_lines(status_buf, 0, -1, false)
          or {},
        status_win_cursor = (status_win and vim.api.nvim_win_is_valid(status_win))
            and vim.api.nvim_win_get_cursor(status_win)
          or nil,
        content_win_cursor = (content_win and vim.api.nvim_win_is_valid(content_win))
            and vim.api.nvim_win_get_cursor(content_win)
          or nil,
      }
    end)

    -- (1) Status float is alive and the buffer contains the typed char.
    h.eq(true, r.have_float)
    h.eq(true, #r.status_buf_lines >= 1)
    h.eq(':e', r.status_buf_lines[1]:sub(1, 2))

    -- (2) Real nvim cursor moved into the status float: row 1, byte
    -- col >= 2 (just past the typed `:e`).
    h.eq(1, r.status_win_cursor[1])
    h.eq(true, r.status_win_cursor[2] >= 2)

    -- (3) The status cursor position differs from the content cursor
    -- (the float owns the rendered cursor in command mode).
    assert.truthy(
      r.status_win_cursor[1] ~= r.content_win_cursor[1]
        or r.status_win_cursor[2] ~= r.content_win_cursor[2],
      'status cursor should differ from content cursor in command mode'
    )
  end)
end)