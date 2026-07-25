-- Tests for the multi-client model: more than one Kakoune JSON-UI
-- session attached to a single nvim. The plan replaces the
-- singleton `ACTIVE` table with a `SESSIONS` registry keyed by
-- content buffer; this file pins down the new invariants so a
-- refactor that regresses them is caught.
--
-- Run:
--   make test FILTER='multi client'

local h = require('test.helpers')

-- A 1-line spec for the fake kak fixture: emit a draw, a
-- draw_status, then sleep long enough for the assertions.
local FAKE_KAK_SPEC = [[
  fake.notify('set_ui_options', {{}})
  fake.notify('draw', {
    { { { contents = 'session-A', face = { fg = 'red', bg = 'default' } } } },
    { line = 0, column = 0 },
    { fg = 'red', bg = 'default' },
    { fg = 'default', bg = 'default' },
    0,
  })
  fake.notify('draw_status', {
    { { { contents = 'A', face = { fg = 'red', bg = 'default' } } } },
    { { { contents = 'a', face = { fg = 'red', bg = 'default' } } } },
    -1,
    {},
    { fg = 'red', bg = 'default' },
    'status',
  })
  fake.sleep(5000)
]]

local FAKE_KAK_SPEC_B = [[
  fake.notify('set_ui_options', {{}})
  fake.notify('draw', {
    { { { contents = 'session-B', face = { fg = 'green', bg = 'default' } } } },
    { line = 0, column = 0 },
    { fg = 'green', bg = 'default' },
    { fg = 'default', bg = 'default' },
    0,
  })
  fake.notify('draw_status', {
    { { { contents = 'B', face = { fg = 'green', bg = 'default' } } } },
    { { { contents = 'b', face = { fg = 'green', bg = 'default' } } } },
    -1,
    {},
    { fg = 'green', bg = 'default' },
    'status',
  })
  fake.sleep(5000)
]]

describe('multi client', function()
  before_each(function() h.setup() end)

  it('registry holds two distinct sessions keyed by content buffer', function()
    local result = h.exec_lua(function()
      local ui = require('kak.ui')
      local handlers = require('kak.ui.handlers')
      local surface = require('kak.ui.ui_surface')

      local buf_a = vim.api.nvim_create_buf(false, true)
      vim.bo[buf_a].buftype = 'nofile'
      vim.bo[buf_a].bufhidden = 'wipe'
      vim.bo[buf_a].swapfile = false
      vim.bo[buf_a].filetype = 'kak-ui'
      local buf_b = vim.api.nvim_create_buf(false, true)
      vim.bo[buf_b].buftype = 'nofile'
      vim.bo[buf_b].bufhidden = 'wipe'
      vim.bo[buf_b].swapfile = false
      vim.bo[buf_b].filetype = 'kak-ui'

      local surf_a = surface.new({ session = 'A' })
      surf_a.content_buf = buf_a
      local surf_b = surface.new({ session = 'B' })
      surf_b.content_buf = buf_b

      local h_a = handlers.new({
        ctx = { ui_options = {}, last_force = false },
        ui_options = {},
        surface = surf_a,
      })
      local h_b = handlers.new({
        ctx = { ui_options = {}, last_force = false },
        ui_options = {},
        surface = surf_b,
      })

      local fake_conn_a = { is_closing = function() return false end }
      local fake_conn_b = { is_closing = function() return false end }

      local s_a = {
        id = buf_a,
        conn = fake_conn_a,
        handlers = h_a,
        surface = surf_a,
        input = nil,
        augroup = 0,
        closed = false,
        close = function() end,
      }
      local s_b = {
        id = buf_b,
        conn = fake_conn_b,
        handlers = h_b,
        surface = surf_b,
        input = nil,
        augroup = 0,
        closed = false,
        close = function() end,
      }
      h_a.session = s_a
      h_b.session = s_b

      -- The public API: `set_current` puts one of two sessions in
      -- the current slot; `current()` returns it. `session_for_buf`
      -- only consults the internal SESSIONS registry, which we
      -- didn't populate for our shim sessions, so we test the
      -- slot semantics here.
      ui.set_current(s_a)
      local via_current = ui.current()
      ui.set_current(s_b)
      local via_current_b = ui.current()

      return {
        distinct_id = s_a.id ~= s_b.id,
        distinct_conn = s_a.conn ~= s_b.conn,
        distinct_surf = s_a.surface ~= s_b.surface,
        distinct_renderer = h_a ~= h_b,
        via_current_a = via_current == s_a,
        via_current_b = via_current_b == s_b,
      }
    end)
    h.eq(true, result.distinct_id)
    h.eq(true, result.distinct_conn)
    h.eq(true, result.distinct_surf)
    h.eq(true, result.distinct_renderer)
    h.eq(true, result.via_current_a)
    h.eq(true, result.via_current_b)
  end)

  it('one session closing does not affect the other (sibling survives)', function()
    local result = h.exec_lua(function()
      local buf_a = vim.api.nvim_create_buf(false, true)
      local buf_b = vim.api.nvim_create_buf(false, true)
      local closed_a = false
      local s_a = {
        id = buf_a,
        conn = {
          is_closing = function() return closed_a end,
          terminate = function() closed_a = true end,
        },
        handlers = nil,
        surface = nil,
        input = nil,
        augroup = 0,
        closed = false,
        close = function(self)
          if self.closed then return end
          self.closed = true
          if self.conn then self.conn:terminate() end
        end,
      }
      local s_b = {
        id = buf_b,
        conn = { is_closing = function() return false end, terminate = function() end },
        handlers = nil,
        surface = nil,
        input = nil,
        augroup = 0,
        closed = false,
        close = function() end,
      }

      s_a:close()
      return {
        a_closed = s_a.closed,
        b_closed = s_b.closed,
        b_closing = s_b.conn:is_closing(),
      }
    end)
    h.eq(true, result.a_closed)
    h.eq(false, result.b_closed)
    h.eq(false, result.b_closing)
  end)

  it('two handlers.new instances draw to independent surfaces', function()
    local result = h.exec_lua(function()
      local handlers = require('kak.ui.handlers')
      local surface = require('kak.ui.ui_surface')

      local buf_a = vim.api.nvim_create_buf(false, true)
      local buf_b = vim.api.nvim_create_buf(false, true)
      vim.bo[buf_a].buftype = 'nofile'
      vim.bo[buf_b].buftype = 'nofile'

      local surf_a = surface.new({ session = 'A' })
      surf_a.content_buf = buf_a
      local surf_b = surface.new({ session = 'B' })
      surf_b.content_buf = buf_b

      local h_a = handlers.new({
        ctx = { ui_options = {}, last_force = false },
        ui_options = {},
        surface = surf_a,
      })
      local h_b = handlers.new({
        ctx = { ui_options = {}, last_force = false },
        ui_options = {},
        surface = surf_b,
      })

      -- Two independent draws to two independent surfaces.
      h_a:draw({
        { { { contents = 'alpha', face = { fg = 'red', bg = 'default' } } } },
        { line = 0, column = 0 },
        { fg = 'red', bg = 'default' },
        { fg = 'default', bg = 'default' },
        0,
      })
      h_b:draw({
        { { { contents = 'beta', face = { fg = 'green', bg = 'default' } } } },
        { line = 0, column = 0 },
        { fg = 'green', bg = 'default' },
        { fg = 'default', bg = 'default' },
        0,
      })

      local lines_a = vim.api.nvim_buf_get_lines(buf_a, 0, -1, false)
      local lines_b = vim.api.nvim_buf_get_lines(buf_b, 0, -1, false)

      -- The two renderer instances own DIFFERENT content bufs, so
      -- surface A's draw must NOT appear in B's buffer.
      return {
        a_first = lines_a[1] or '',
        b_first = lines_b[1] or '',
        a_has_beta = (lines_a[1] or ''):find('beta', 1, true) ~= nil,
        b_has_alpha = (lines_b[1] or ''):find('alpha', 1, true) ~= nil,
        h_a_render_buf = h_a.renderer.content_buf,
        h_b_render_buf = h_b.renderer.content_buf,
      }
    end)
    h.eq('alpha', result.a_first)
    h.eq('beta', result.b_first)
    h.eq(false, result.a_has_beta)
    h.eq(false, result.b_has_alpha)
    h.eq(true, result.h_a_render_buf ~= result.h_b_render_buf)
  end)

  it('end-to-end: two fake-kak clients render into independent bufs', function()
    local a_label = 'session-A'
    local b_label = 'session-B'

    local capture = h.exec_lua(function(a_label, b_label, spec_a_src, spec_b_src)
      local ui = require('kak.ui')

      local function write_spec(src)
        local p = vim.fn.tempname() .. '.lua'
        local f = assert(io.open(p, 'w'))
        f:write(src)
        f:close()
        return p
      end
      local spec_a_path = write_spec(spec_a_src)
      local spec_b_path = write_spec(spec_b_src)

      local nvim_path = require('test.helpers').fake_kak_nvim_path()
      local fixture = require('test.helpers').fake_kak_fixture_path()

      local function open_fake(spec_path, session_name)
        vim.cmd('vsplit')
        local cmd = { nvim_path, '-l', fixture, spec_path }
        -- `session_name` flows into the `-c` argv (so the buffer
        -- gets a unique `kak://<name>` name) AND into the dummy
        -- `-e` flag so the fake-kak-server spec can echo it back.
        return ui.open({
          cmd = cmd,
          session = session_name,
          extra_args = { '-e', 'set global kak_session ' .. session_name },
        })
      end

      local sess_a = open_fake(spec_a_path, 'a')
      vim.cmd('wincmd h')
      local sess_b = open_fake(spec_b_path, 'b')

      local function buf_has(buf, needle)
        if not buf or not vim.api.nvim_buf_is_valid(buf) then return false end
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        for _, l in ipairs(lines) do
          if l:find(needle, 1, true) then return true end
        end
        return false
      end
      local ok = vim.wait(
        5000,
        function() return buf_has(sess_a.id, a_label) and buf_has(sess_b.id, b_label) end
      )

      local a_lines = vim.api.nvim_buf_is_valid(sess_a.id)
          and vim.api.nvim_buf_get_lines(sess_a.id, 0, -1, false)
        or {}
      local b_lines = vim.api.nvim_buf_is_valid(sess_b.id)
          and vim.api.nvim_buf_get_lines(sess_b.id, 0, -1, false)
        or {}

      sess_a:close()
      local b_still_alive = not sess_b.conn:is_closing()

      os.remove(spec_a_path)
      os.remove(spec_b_path)

      return {
        ok = ok,
        a_id = sess_a.id,
        b_id = sess_b.id,
        distinct_id = sess_a.id ~= sess_b.id,
        a_first_line = a_lines[1] or '',
        b_first_line = b_lines[1] or '',
        b_still_alive = b_still_alive,
      }
    end, a_label, b_label, FAKE_KAK_SPEC, FAKE_KAK_SPEC_B)

    h.eq(true, capture.ok)
    h.eq(true, capture.distinct_id)
    h.eq(
      true,
      type(capture.a_first_line) == 'string' and capture.a_first_line:find(a_label, 1, true) ~= nil
    )
    h.eq(
      true,
      type(capture.b_first_line) == 'string' and capture.b_first_line:find(b_label, 1, true) ~= nil
    )
    h.eq(true, capture.b_still_alive)
  end)

  -- Regression for the frozen-frame bug. After `:q` in the current
  -- session, the dead window used to stay open with the session's
  -- last frame and input went nowhere (because `session_for_buf`
  -- resolved to nil and `current_session` was also nil). The fix:
  -- `Session:close()` synchronously switches `current_session` to
  -- a surviving session, schedules an `nvim_set_current_win` to
  -- land in the survivor's window, and `Surface:close()` removes
  -- the dead content_win when there is a sibling.
  it('closing the current session switches current + focus to a survivor', function()
    local capture = h.exec_lua(function(spec_a_src, spec_b_src)
      local ui = require('kak.ui')
      local helpers = require('test.helpers')

      local function write_spec(src)
        local p = vim.fn.tempname() .. '.lua'
        local f = assert(io.open(p, 'w'))
        f:write(src)
        f:close()
        return p
      end
      local spec_a = write_spec(spec_a_src)
      local spec_b = write_spec(spec_b_src)
      local nvim_path = helpers.fake_kak_nvim_path()
      local fixture = helpers.fake_kak_fixture_path()

      local function open_fake(spec_path, name)
        vim.cmd('vsplit')
        return ui.open({
          cmd = { nvim_path, '-l', fixture, spec_path },
          session = name,
          extra_args = { '-e', 'set global kak_session ' .. name },
        })
      end

      local sess_a = open_fake(spec_a, 'a')
      vim.cmd('wincmd h')
      local sess_b = open_fake(spec_b, 'b')
      local win_a = sess_a.surface.content_win
      local win_b = sess_b.surface.content_win
      local buf_a = sess_a.id
      local buf_b = sess_b.id

      -- Sanity: sess_b was just opened, so it owns the current slot
      -- and the focus is on its window.
      local before = {
        current_is_b = ui.current() == sess_b,
        focused_is_b = vim.api.nvim_get_current_win() == win_b,
      }

      -- Close the CURRENT session (sess_b).
      sess_b:close()

      -- Synchronously (no vim.wait): the registry slot has flipped
      -- to the survivor and the dead window is gone.
      local sync = {
        current_is_a = ui.current() == sess_a,
        win_b_invalid = not (win_b and vim.api.nvim_win_is_valid(win_b)),
        sess_b_gone_from_registry = ui.session_for_buf(buf_b) == nil,
        sess_a_still_resolvable = ui.session_for_buf(buf_a) == sess_a,
        sess_a_alive = not sess_a.conn:is_closing(),
        win_a_still_valid = win_a and vim.api.nvim_win_is_valid(win_a) or false,
      }

      -- Asynchronously (after the scheduled focus move fires): the
      -- focused window is the survivor's window.
      local focused = vim.wait(500, function() return vim.api.nvim_get_current_win() == win_a end)
      local final_focus = vim.api.nvim_get_current_win()

      os.remove(spec_a)
      os.remove(spec_b)

      return {
        before_current_is_b = before.current_is_b,
        before_focused_is_b = before.focused_is_b,
        sync_current_is_a = sync.current_is_a,
        sync_win_b_invalid = sync.win_b_invalid,
        sync_sess_b_gone = sync.sess_b_gone_from_registry,
        sync_sess_a_resolvable = sync.sess_a_still_resolvable,
        sync_sess_a_alive = sync.sess_a_alive,
        sync_win_a_valid = sync.win_a_still_valid,
        async_focused = focused,
        final_focus_equals_a = final_focus == win_a,
      }
    end, FAKE_KAK_SPEC, FAKE_KAK_SPEC_B)

    h.eq(true, capture.before_current_is_b)
    h.eq(true, capture.before_focused_is_b)
    h.eq(true, capture.sync_current_is_a)
    h.eq(true, capture.sync_win_b_invalid)
    h.eq(true, capture.sync_sess_b_gone)
    h.eq(true, capture.sync_sess_a_resolvable)
    h.eq(true, capture.sync_sess_a_alive)
    h.eq(true, capture.sync_win_a_valid)
    h.eq(true, capture.async_focused)
    h.eq(true, capture.final_focus_equals_a)
  end)

  -- Regression for "external focus events (mouse click, :new) should
  -- switch the kak window": after :KakNewWin the new split must be the
  -- current session/focused window, WinEnter must track window
  -- switches, and focus_active must focus whichever session is current.
  it('focus tracks the active window and focus_active targets it', function()
    local result = h.exec_lua(function(spec_a_src, spec_b_src)
      local ui = require('kak.ui')
      local w = require('kak.ui.windowing')
      local helpers = require('test.helpers')
      local nvim_path = helpers.fake_kak_nvim_path()
      local fixture = helpers.fake_kak_fixture_path()

      local function write_spec(src)
        local p = vim.fn.tempname() .. '.lua'
        local f = assert(io.open(p, 'w'))
        f:write(src)
        f:close()
        return p
      end
      local spec_a = write_spec(spec_a_src)
      local spec_b = write_spec(spec_b_src)

      local function open_fake(spec_path, name)
        vim.cmd('vsplit')
        return ui.open({
          cmd = { nvim_path, '-l', fixture, spec_path },
          session = name,
          extra_args = { '-e', 'set global kak_session ' .. name },
        })
      end

      local sess_a = open_fake(spec_a, 'a')
      local win_a = sess_a.surface.content_win
      local sess_b = open_fake(spec_b, 'b')
      local win_b = sess_b.surface.content_win

      -- :KakNewWin's vsplit focuses the new window and open() sets
      -- current to it, so after opening b the focus + current is b.
      local current_after_open = ui.current()
      local focused_after_open = vim.api.nvim_get_current_win()

      -- focus_active must focus the current (b) session's window.
      w.focus_active()
      local focused_after_focus_b = vim.api.nvim_get_current_win()

      -- Switching to a's window fires WinEnter -> set_current(a).
      vim.api.nvim_set_current_win(win_a)
      local current_after_switch = ui.current()

      -- focus_active now targets a.
      w.focus_active()
      local focused_after_focus_a = vim.api.nvim_get_current_win()

      sess_a:close()
      sess_b:close()
      os.remove(spec_a)
      os.remove(spec_b)

      return {
        current_is_b_after_open = current_after_open == sess_b,
        focused_is_b = focused_after_open == win_b,
        focus_active_targets_b = focused_after_focus_b == win_b,
        current_is_a_after_switch = current_after_switch == sess_a,
        focus_active_targets_a = focused_after_focus_a == win_a,
      }
    end, FAKE_KAK_SPEC, FAKE_KAK_SPEC_B)

    h.eq(true, result.current_is_b_after_open)
    h.eq(true, result.focused_is_b)
    h.eq(true, result.focus_active_targets_b)
    h.eq(true, result.current_is_a_after_switch)
    h.eq(true, result.focus_active_targets_a)
  end)
end)
