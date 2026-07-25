-- Tests for `kak.ui.input` (key translation + handler routing).

local h = require('test.helpers')

describe('nvim_to_kak', function()
  before_each(function() h.setup() end)

  it('passes bare printable', function()
    local r = h.exec_lua(
      function()
        return {
          require('kak.ui.input').nvim_to_kak('j'),
          require('kak.ui.input').nvim_to_kak('a'),
        }
      end
    )
    h.eq('j', r[1])
    h.eq('a', r[2])
  end)

  it('translates special keys', function()
    local r = h.exec_lua(
      function()
        return {
          require('kak.ui.input').nvim_to_kak('<CR>'),
          require('kak.ui.input').nvim_to_kak('<Tab>'),
          require('kak.ui.input').nvim_to_kak('<Esc>'),
          require('kak.ui.input').nvim_to_kak('<Up>'),
        }
      end
    )
    h.eq('<ret>', r[1])
    h.eq('<tab>', r[2])
    h.eq('<esc>', r[3])
    h.eq('<up>', r[4])
  end)

  it('lowercases modifier prefix', function()
    local r = h.exec_lua(
      function()
        return {
          require('kak.ui.input').nvim_to_kak('<C-A>'),
          require('kak.ui.input').nvim_to_kak('<c-a>'),
          require('kak.ui.input').nvim_to_kak('<S-Tab>'),
        }
      end
    )
    h.eq('<c-a>', r[1])
    h.eq('<c-a>', r[2])
    h.eq('<s-tab>', r[3])
  end)
end)

describe('raw_to_kak', function()
  before_each(function() h.setup() end)

  it('splits notation into per-key list', function()
    local r = h.exec_lua(function() return require('kak.ui.input').raw_to_kak('<CR>j') end)
    h.eq(2, #r)
    h.eq('<ret>', r[1])
    h.eq('j', r[2])
  end)

  it('converts <C-H>', function()
    local r = h.exec_lua(function() return require('kak.ui.input').raw_to_kak('<C-H>') end)
    h.eq(1, #r)
    h.eq('<c-h>', r[1])
  end)
end)

describe('from_on_key', function()
  before_each(function() h.setup() end)

  it('translates raw <Esc> byte to <esc>', function()
    local r = h.exec_lua(function() return require('kak.ui.input').from_on_key('\27') end)
    h.eq(1, #r)
    h.eq('<esc>', r[1])
  end)

  it('translates raw <CR> byte to <ret>', function()
    local r = h.exec_lua(function() return require('kak.ui.input').from_on_key('\r') end)
    h.eq(1, #r)
    h.eq('<ret>', r[1])
  end)

  it('translates raw <Tab> byte to <tab>', function()
    local r = h.exec_lua(function() return require('kak.ui.input').from_on_key('\t') end)
    h.eq(1, #r)
    h.eq('<tab>', r[1])
  end)

  it('translates raw <Up> bytes (<80>ku) to <up>', function()
    local r = h.exec_lua(function()
      local up_internal = vim.api.nvim_replace_termcodes('<Up>', true, false, true)
      return require('kak.ui.input').from_on_key(up_internal)
    end)
    h.eq(1, #r)
    h.eq('<up>', r[1])
  end)

  it('translates raw Ctrl-A (<1>) to <c-a>', function()
    local r = h.exec_lua(function() return require('kak.ui.input').from_on_key('\x01') end)
    h.eq(1, #r)
    h.eq('<c-a>', r[1])
  end)

  it('returns empty for nil/empty input', function()
    local r = h.exec_lua(function()
      local m = require('kak.ui.input')
      return { #m.from_on_key(nil), #m.from_on_key(''), #m.from_on_key(' ') }
    end)
    h.eq(0, r[1])
    h.eq(0, r[2])
    h.eq(1, r[3])
  end)

  it('end-to-end: keytrans + raw_to_kak yields correct kak keys', function()
    local r = h.exec_lua(function()
      local m = require('kak.ui.input')
      local out = {}
      for _, k in ipairs({ '<Esc>', '<CR>', '<Tab>', '<C-a>', '<Up>', '<Down>', '<Backspace>' }) do
        local raw = vim.api.nvim_replace_termcodes(k, true, false, true)
        local notation = vim.fn.keytrans(raw)
        local kak = m.raw_to_kak(notation)
        out[#out + 1] = { input = k, notation = notation, kak = kak }
      end
      return out
    end)
    h.eq('<esc>', r[1].kak[1])
    h.eq('<ret>', r[2].kak[1])
    h.eq('<tab>', r[3].kak[1])
    h.eq('<c-a>', r[4].kak[1])
    h.eq('<up>', r[5].kak[1])
    h.eq('<down>', r[6].kak[1])
    h.eq('<backspace>', r[7].kak[1])
  end)
end)

describe('input handler routing', function()
  before_each(function() h.setup() end)

  it('maps mouse events to mouse_press / scroll (not keys)', function()
    local methods = h.with_fake_kak_server(
      [[
      fake.notify('set_ui_options', {{}})
      fake.notify('mouse_press', { 'left', 1, 5 })
      fake.notify('mouse_release', { 'left', 1, 5 })
      fake.notify('scroll', { 1, 1, 0 })
      fake.sleep(5000)
    ]],
      function(_, captured)
        vim.wait(3000, function() return #captured >= 4 end)
        local m = {}
        for _, e in ipairs(captured) do
          m[#m + 1] = e[1]
        end
        return m
      end
    )

    h.eq('set_ui_options', methods[1])
    h.eq('mouse_press', methods[2])
    h.eq('mouse_release', methods[3])
    h.eq('scroll', methods[4])
    for _, name in ipairs(methods) do
      assert(name ~= 'keys', 'mouse event leaked into keys path: ' .. name)
    end
  end)

  it('cleans up on_key listener on disable', function()
    local counts = h.exec_lua(function()
      local conn = {
        notify = function() end,
        is_closing = function() return false end,
      }
      local handler = require('kak.ui.input').new({ rpc = conn })
      local buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].buftype = 'nofile'
      handler:enable()
      local before = vim.on_key and vim.on_key() or 0
      handler:disable()
      local after = vim.on_key and vim.on_key() or 0
      return { before = before, after = after }
    end)
    h.eq(true, counts.after <= counts.before)
  end)

  -- |vim.on_key()|: returning '' tells nvim to discard the keypress.
  -- Without this, nvim would also act on ESC, `:`, `/`, etc.
  it('returns empty string from on_key callback so nvim drops the key', function()
    local got = h.exec_lua(function()
      local sent = {}
      local conn = {}
      conn.is_closing = function() return false end
      conn.notify = function(self, method, params) sent[#sent + 1] = { method, params } end
      local ui = require('kak.ui')
      local input = require('kak.ui.input')
      local handler = input.new({ rpc = conn })
      local buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].buftype = 'nofile'
      -- Register a fake session for this content buffer so the global
      -- on_key listener can route the current buffer to it. The
      -- registry was emptied in setup() but `set_current` still
      -- works; we also expose the conn via session_for_buf() by
      -- shipping a tiny mock that injects through a wrapper.
      local fake_session = {
        id = buf,
        conn = conn,
        surface = handler.surface,
      }
      -- `session_for_buf` consults a module-level SESSIONS table;
      -- we use `current()` as a fallback for any current-buffer
      -- lookup by temporarily making our fake the current session.
      handler:enable()
      vim.api.nvim_set_current_buf(buf)
      -- Point current_session at our fake via the public API.
      ui.set_current(fake_session)
      -- <Esc> arrives as a single \27 byte. The handler's global
      -- on_key closure looks up the session by the current buffer.
      local fn = assert(input._on_key_fn(), 'global on_key should be installed')
      local ret = fn('', '\27')
      handler:disable()
      ui.set_current(nil)
      return { ret = ret, sent = sent }
    end)
    h.eq('', got.ret)
    h.eq(1, #got.sent)
    h.eq('keys', got.sent[1][1])
    h.eq('<esc>', got.sent[1][2][1])
  end)

  -- Regression for the multi-client on_key double-install bug.
  -- Two Handler instances must share a single global `vim.on_key`
  -- listener; the second `:enable()` only bumps the refcount.
  -- Enabling two handlers and then disabling both must also
  -- restore the original `vim.on_key()` callback count (i.e. the
  -- listener is torn down exactly once, at refcount == 0).
  it('two handlers share a single global on_key listener (regression)', function()
    local counts = h.exec_lua(function()
      local input = require('kak.ui.input')
      local conn_a = {
        notify = function() end,
        is_closing = function() return false end,
      }
      local conn_b = {
        notify = function() end,
        is_closing = function() return false end,
      }
      local h_a = input.new({ rpc = conn_a })
      local h_b = input.new({ rpc = conn_b })

      local baseline = vim.on_key and vim.on_key() or 0

      h_a:enable()
      local after_first = vim.on_key and vim.on_key() or 0
      local state_after_first = input._global_state()

      -- A SECOND enable must NOT install a second on_key callback.
      h_b:enable()
      local after_second = vim.on_key and vim.on_key() or 0
      local state_after_second = input._global_state()

      -- The refcount is 2, but the listener is still installed once.
      h_a:disable()
      local state_after_dis_a = input._global_state()
      local after_dis_a = vim.on_key and vim.on_key() or 0

      -- Disabling the second handler is what finally tears the
      -- listener down (refcount -> 0).
      h_b:disable()
      local state_after_dis_b = input._global_state()
      local after_dis_b = vim.on_key and vim.on_key() or 0

      return {
        baseline = baseline,
        after_first = after_first,
        after_second = after_second,
        after_dis_a = after_dis_a,
        after_dis_b = after_dis_b,
        state_after_first = state_after_first,
        state_after_second = state_after_second,
        state_after_dis_a = state_after_dis_a,
        state_after_dis_b = state_after_dis_b,
      }
    end)
    -- Refcount path: 0 -> 1 -> 2 -> 1 -> 0.
    h.eq(1, counts.state_after_first.on_key_refcount)
    h.eq(2, counts.state_after_second.on_key_refcount)
    h.eq(1, counts.state_after_dis_a.on_key_refcount)
    h.eq(0, counts.state_after_dis_b.on_key_refcount)
    -- Listener installed only once (the first enable) and torn
    -- down only once (the last disable).
    h.eq(true, counts.state_after_first.on_key_installed)
    h.eq(true, counts.state_after_second.on_key_installed)
    h.eq(true, counts.state_after_dis_a.on_key_installed)
    h.eq(false, counts.state_after_dis_b.on_key_installed)
    -- The refcount map matches the nvim-side count exactly.
    h.eq(1, counts.after_first - counts.baseline)
    h.eq(1, counts.after_second - counts.baseline)
    h.eq(1, counts.after_dis_a - counts.baseline)
    h.eq(0, counts.after_dis_b - counts.baseline)
  end)

  -- Regression for the multi-client paste refcount bug. Two
  -- handlers must share a single `vim.paste` override; disabling
  -- one must NOT restore the original while the other is still
  -- enabled. The original is only restored when the refcount hits 0.
  it('two handlers share a single vim.paste override (regression)', function()
    local probe = h.exec_lua(function()
      local input = require('kak.ui.input')
      local saved = vim.paste
      local conn = {
        notify = function() end,
        is_closing = function() return false end,
      }
      local h_a = input.new({ rpc = conn })
      local h_b = input.new({ rpc = conn })

      local state_before = input._global_state()

      h_a:enable()
      local state_after_a = input._global_state()
      local paste_after_a = vim.paste
      local paste_is_saved_after_a = (paste_after_a == saved)

      h_b:enable()
      local state_after_b = input._global_state()
      local paste_after_b = vim.paste
      local paste_is_saved_after_b = (paste_after_b == saved)

      -- Disable A; B is still enabled, so `vim.paste` must stay
      -- routed (not clobbered back to the original).
      h_a:disable()
      local state_after_dis_a = input._global_state()
      local paste_after_dis_a = vim.paste
      local paste_is_saved_after_dis_a = (paste_after_dis_a == saved)

      -- Disable B; refcount hits 0, original is restored.
      h_b:disable()
      local state_after_dis_b = input._global_state()
      local paste_after_dis_b = vim.paste
      local paste_is_saved_after_dis_b = (paste_after_dis_b == saved)

      return {
        state_before = state_before,
        state_after_a = state_after_a,
        state_after_b = state_after_b,
        state_after_dis_a = state_after_dis_a,
        state_after_dis_b = state_after_dis_b,
        paste_is_saved_after_a = paste_is_saved_after_a,
        paste_is_saved_after_b = paste_is_saved_after_b,
        paste_is_saved_after_dis_a = paste_is_saved_after_dis_a,
        paste_is_saved_after_dis_b = paste_is_saved_after_dis_b,
        paste_a_eq_b = (paste_after_a == paste_after_b),
        paste_dis_a_eq_a = (paste_after_dis_a == paste_after_a),
      }
    end)
    h.eq(0, probe.state_before.paste_refcount)
    h.eq(false, probe.state_before.paste_installed)
    h.eq(1, probe.state_after_a.paste_refcount)
    h.eq(true, probe.state_after_a.paste_installed)
    h.eq(2, probe.state_after_b.paste_refcount)
    h.eq(true, probe.state_after_b.paste_installed)
    h.eq(1, probe.state_after_dis_a.paste_refcount)
    h.eq(true, probe.state_after_dis_a.paste_installed)
    h.eq(0, probe.state_after_dis_b.paste_refcount)
    h.eq(false, probe.state_after_dis_b.paste_installed)
    -- The override identity stays the same across enables (single
    -- install). `vim.paste` remains the override while ANY handler
    -- is enabled, and is restored only on the last disable.
    h.eq(true, probe.paste_a_eq_b)
    h.eq(true, probe.paste_dis_a_eq_a)
    h.eq(false, probe.paste_is_saved_after_a)
    h.eq(false, probe.paste_is_saved_after_b)
    h.eq(false, probe.paste_is_saved_after_dis_a)
    h.eq(true, probe.paste_is_saved_after_dis_b)
  end)

  -- Regression for the `:q` hang. When kak's client process exits,
  -- `is_closing()` flips true immediately, but `vim.system`'s
  -- `on_exit` is gated on stdout EOF (neovim #33627) and may be
  -- delayed or never fire (e.g. a grandchild inherited the pipe).
  -- During that gap, `session_for_current_buf` drops the dead
  -- session (its is_closing guard), so the global on_key listener
  -- would return '' and trap the user. The safety net:
  --   1. detects a dead session (per cur-owner or current() fallback)
  --   2. schedules sess:close() so current_session flips to a
  --      survivor + the dead window is removed next tick
  --   3. passes this key through (returns typed) so the user can
  --      act during the one-tick scheduling gap
  it('on_key safety net: dead current session gets scheduled close + pass-through', function()
    local result = h.exec_lua(function()
      local ui = require('kak.ui')
      local input = require('kak.ui.input')

      local buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].buftype = 'nofile'

      local close_called = 0
      local close_log = {}
      local dead_conn = {
        is_closing = function() return true end,
        terminate = function() end,
        notify = function() end,
      }
      local dead_session = {
        id = buf,
        conn = dead_conn,
        handlers = nil,
        surface = nil,
        input = nil,
        augroup = 0,
        closed = false,
        close = function(self)
          close_called = close_called + 1
          close_log[#close_log + 1] = { step = 'enter', closed = self.closed }
          if self.closed then return end
          self.closed = true
          close_log[#close_log + 1] = { step = 'mark' }
          if self.conn and not self.conn:is_closing() then self.conn:terminate() end
          if ui.current() == self then ui.set_current(nil) end
          close_log[#close_log + 1] = { step = 'leave' }
        end,
      }

      -- Handler for the listener install; uses a SEPARATE live
      -- conn so the listener enables even though `dead_conn` is
      -- already "closing". The listener itself only needs to be
      -- installed for `_on_key_fn` to exist; the dead branch
      -- doesn't care about the handler's own conn.
      local live_conn = {
        is_closing = function() return false end,
        terminate = function() end,
        notify = function() end,
      }
      local handler = input.new({ rpc = live_conn })
      handler:enable()
      vim.api.nvim_set_current_buf(buf)
      ui.set_current(dead_session)

      local fn = assert(input._on_key_fn(), 'global on_key should be installed')
      -- <Esc> is the canonical trapped key.
      local ret = fn('', '\27')
      local closed_sync = dead_session.closed
      local close_count_sync = close_called

      -- Wait for the scheduled close to fire (vim.schedule drain).
      local waited = vim.wait(500, function() return dead_session.closed end)
      local closed_async = dead_session.closed
      local close_count_async = close_called
      local current_after = ui.current()

      handler:disable()
      ui.set_current(nil)
      return {
        ret = ret,
        closed_sync = closed_sync,
        closed_async = closed_async,
        close_count_sync = close_count_sync,
        close_count_async = close_count_async,
        waited = waited,
        current_after = current_after,
        close_log = close_log,
      }
    end)
    -- 1. Pass-through: the key returns AS-IS, not the empty drop.
    --    The trap would be returning '' -- the safety net returns
    --    the typed bytes so nvim processes the key.
    h.eq('\27', result.ret)
    -- 2. The close was NOT called synchronously (it's behind
    --    vim.schedule). Confirm: closed=false right after on_key
    --    returns.
    h.eq(false, result.closed_sync)
    h.eq(0, result.close_count_sync)
    -- 3. After pumping the event loop, the scheduled close fired
    --    exactly once -- not zero, not twice (idempotency via the
    --    `closed` guard means a future real on_exit -> close would
    --    short-circuit).
    h.eq(true, result.waited)
    h.eq(true, result.closed_async)
    h.eq(1, result.close_count_async)
    -- 4. The dead session's close wiped current_session (no
    --    survivor was registered in this minimal test).
    h.eq(nil, result.current_after)
    -- 5. Close log shows the sequence: enter -> mark -> leave
    --    (idempotency guard never short-circuited).
    h.eq('enter', result.close_log[1].step)
    h.eq('mark', result.close_log[2].step)
    h.eq('leave', result.close_log[3].step)
  end)

  -- Regression: when the dead session is the one registered as the
  -- OWNER of the current buffer (not just `current()`), the
  -- per-cur `session_for_buf` lookup is the path that finds it.
  -- The current() fallback is a secondary path; both must converge
  -- on the same scheduled close + pass-through behavior.
  it('on_key safety net: dead session that owns cur is found via session_for_buf', function()
    local result = h.exec_lua(function()
      local ui = require('kak.ui')
      local input = require('kak.ui.input')

      local buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].buftype = 'nofile'

      -- Pre-register the fake dead session in SESSIONS via the
      -- `_sessions()` test handle, so `session_for_buf(buf)` is the
      -- path that finds it (not the current() fallback).
      local close_called = 0
      local dead_conn = {
        is_closing = function() return true end,
        terminate = function() end,
        notify = function() end,
      }
      local dead_session = {
        id = buf,
        conn = dead_conn,
        handlers = nil,
        surface = nil,
        input = nil,
        augroup = 0,
        closed = false,
        close = function(self)
          close_called = close_called + 1
          if self.closed then return end
          self.closed = true
        end,
      }
      ui._sessions()[buf] = dead_session

      local live_conn = {
        is_closing = function() return false end,
        terminate = function() end,
        notify = function() end,
      }
      local handler = input.new({ rpc = live_conn })
      handler:enable()
      vim.api.nvim_set_current_buf(buf)
      -- Intentionally NOT set_current -- we want the per-cur
      -- session_for_buf path to be the one that finds the dead
      -- session.

      local fn = assert(input._on_key_fn(), 'global on_key should be installed')
      local ret = fn('', '\27')
      local closed_sync = dead_session.closed
      local waited = vim.wait(500, function() return dead_session.closed end)
      local closed_async = dead_session.closed
      local close_count = close_called

      handler:disable()
      ui._sessions()[buf] = nil
      return {
        ret = ret,
        closed_sync = closed_sync,
        closed_async = closed_async,
        close_count = close_count,
        waited = waited,
      }
    end)
    h.eq('\27', result.ret)
    h.eq(false, result.closed_sync)
    h.eq(true, result.waited)
    h.eq(true, result.closed_async)
    h.eq(1, result.close_count)
  end)
end)
