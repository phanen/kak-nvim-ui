-- PoC: screen:expect + screen:snapshot_util against real Kakoune.
-- Pattern for adopting the assertion into kak_e2e_spec.lua.
--
-- Run with:
--   make test FILTER='renders grid via screen:expect'
--   KAK_UI_SNAPSHOT=1 make test FILTER='renders grid via screen:expect'  -- dump grid
--
-- Notes:
--   * Screen is attached in before_each and detached in after_each so the
--     child nvim's redraw events from `kak.ui.open` flow into the screen.
--   * Without screen, the existing test only verifies `nvim_buf_get_lines`
--     and `nvim_buf_is_valid` -- it cannot catch visual regressions like
--     missing highlights, wrong cursor row, or an error overlay hiding the
--     buffer (see commit history: json_rpc.lua obj:wait crash).

local h = require('test.helpers')

local screen

describe('screen PoC', function()
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

  it('renders grid via screen:expect', function()
    local file = h.write_file({ 'alpha line', 'beta line', 'gamma line' })

    local result = h.with_kak_session({
      extra_args = { '-e', 'edit ' .. file },
    }, function(sess, f)
      local got = nil
      vim.wait(3000, function()
        local lines = vim.api.nvim_buf_get_lines(sess.buf, 0, -1, false)
        if not (#lines >= 3 and lines[1] == 'alpha line') then return false end
        local mode = vim.api.nvim_buf_get_lines(sess.renderer.mode_buf, 0, -1, false)
        local basename = vim.fn.fnamemodify(f, ':t')
        if #mode > 0 and mode[1]:find(basename, 1, true) then
          got = { content = lines, mode = mode }
          return true
        end
        return false
      end)
      return got
    end, file)

    os.remove(file)

    screen:sleep(50)

    if os.getenv('KAK_UI_SNAPSHOT') then
      screen:snapshot_util({}, true)
    end

    h.eq('table', type(result))

    -- 80x24: 1 mode + 3 content + 19 empty (cmdline height = 1).
    -- Cursor `^` glyph sits at column 0 of the focused row, so the alpha
    -- row actually begins with `^`, not the alpha text.
    screen:expect([[
      {MATCH:^.*k//main.*X}|
      {MATCH:alpha line}
      {MATCH:beta line}
      {MATCH:gamma line}
      {MATCH:^~.*}|*19
      {MATCH:^ *}|
    ]])
  end)
end)
