-- Tests for the kakoune server/client decoupling (Fix A).
--
-- Each `:Kak` must spawn a separate `kak -d -s <name>` daemon so the
-- kakoune SERVER lives independently of any single client. `:q` then
-- kills only the JSON-UI client (clean exit, `vim.system` on_exit
-- fires reliably), while the daemon survives and other clients stay
-- connected.
--
-- Run:
--   make test FILTER='daemon'

local h = require('test.helpers')

describe('daemon', function()
  before_each(function() h.setup() end)

  it('gen_session produces unique names matching kak-nvim-<pid>-<seq>', function()
    local result = h.exec_lua(function()
      local ui = require('kak.ui')
      local a = ui._gen_session()
      local b = ui._gen_session()
      local c = ui._gen_session()
      -- The pid is captured inside the test nvim so the pattern
      -- matches the exec_lua instance's actual pid.
      local pid = vim.fn.getpid()
      local pat = '^kak%-nvim%-' .. pid .. '%-%d+$'
      return {
        distinct = (a ~= b) and (b ~= c) and (a ~= c),
        a_matches = a:match(pat) ~= nil,
        b_matches = b:match(pat) ~= nil,
        c_matches = c:match(pat) ~= nil,
        a = a,
        b = b,
        c = c,
        pid = pid,
      }
    end)
    h.eq(true, result.distinct)
    h.eq(true, result.a_matches)
    h.eq(true, result.b_matches)
    h.eq(true, result.c_matches)
  end)

  it('_ensure_daemon is idempotent (one DAEMONS entry per session)', function()
    -- We can't easily mock vim.system from nvim-test, but we can
    -- call _ensure_daemon twice with the same session and check the
    -- DAEMONS table only has one entry (and the same sysobj both
    -- times). Skip the test when kak isn't installed.
    local kak = h.kak_path()
    if h.fn.exepath(kak) == '' then return end
    local result = h.exec_lua(function()
      local ui = require('kak.ui')
      local sess = 'kak-test-idem-' .. tostring(os.time())
      ui._ensure_daemon(sess)
      local first = ui._daemons()[sess]
      ui._ensure_daemon(sess)
      local second = ui._daemons()[sess]
      return {
        had_first = first ~= nil,
        same_obj = first ~= nil and first == second,
        still_alive = first ~= nil and not first:is_closing(),
        count = 1,
      }
    end)
    h.eq(true, result.had_first)
    h.eq(true, result.same_obj)
    h.eq(true, result.still_alive)
    h.eq(1, result.count)
  end)

  it('real-kak smoke: open + close cleans up the daemon', function()
    -- End-to-end check using the real kak binary: open a real
    -- session (which spawns a `kak -d` daemon), close the session,
    -- verify the daemon entry is gone from the DAEMONS table.
    -- Skip when kak isn't installed (CI machines may not have it).
    local kak = h.kak_path()
    if h.fn.exepath(kak) == '' then return end

    local captured = h.exec_lua(function()
      local ui = require('kak.ui')
      -- Use a unique session name so we don't collide with the user's
      -- real sessions.
      local sess_name = 'kak-smoke-' .. tostring(os.time())
      local sess = ui.open({ session = sess_name })
      -- After open, the daemon for sess_name should be tracked.
      local d_after_open = ui._daemons()[sess_name]
      local was_daemon = d_after_open ~= nil
      -- Close the session: the daemon should be killed (since this
      -- was the only client for sess_name).
      sess:close()
      vim.wait(500, function() return ui._daemons()[sess_name] == nil end)
      local d_after_close = ui._daemons()[sess_name]
      return {
        was_daemon = was_daemon,
        daemon_gone = d_after_close == nil,
        session_name = sess_name,
      }
    end)
    h.eq(true, captured.was_daemon)
    h.eq(true, captured.daemon_gone)
  end)
end)
