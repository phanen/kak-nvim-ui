-- Tests for `kak.ui.log` file-backed logger and `assert_log` helpers.

local h = require('test.helpers')

local function fresh_log()
  local dir = h.fn.tempname()
  h.fn.mkdir(dir, 'p')
  local log = dir .. '/kak-ui.log'
  return log, dir
end

describe('assert_log polling', function()
  before_each(function() h.setup() end)

  it('returns true when pattern matches within deadline', function()
    local log = fresh_log()
    local f = assert(io.open(log, 'w'))
    f:write('[INFO] test line that has the marker MARK\n')
    f:close()
    h.eq(true, h.assert_log('MARK', log))
  end)

  it('throws when pattern never matches, including tail dump', function()
    local log = fresh_log()
    local f = assert(io.open(log, 'w'))
    f:write('unrelated output\n')
    f:close()
    local ok, err = pcall(h.assert_log, 'NEVER_MATCH', log)
    h.eq(false, ok)
    assert(tostring(err):find('NEVER_MATCH', 1, true), 'error must name the pattern')
    assert(tostring(err):find('unrelated output', 1, true), 'error must dump the log tail')
  end)

  it('blocks until pattern appears', function()
    local log = fresh_log()
    local f = assert(io.open(log, 'w'))
    f:close()
    -- vim.defer_fn is unavailable in -l (script) mode; use uv timer.
    h.exec_lua(function(logpath)
      local timer = vim.uv.new_timer()
      timer:start(100, 0, function()
        timer:stop()
        timer:close()
        local fh = assert(io.open(logpath, 'a'))
        fh:write('late arrival HIT\n')
        fh:close()
      end)
    end, log)
    h.eq(true, h.assert_log('HIT', log, 50))
  end)
end)

describe('assert_nolog polling', function()
  before_each(function() h.setup() end)

  it('returns true when pattern stays absent', function()
    local log = fresh_log()
    local f = assert(io.open(log, 'w'))
    f:write('clean stream\n')
    f:close()
    h.eq(true, h.assert_nolog('BAD', log))
  end)

  it('throws immediately when pattern appears', function()
    local log = fresh_log()
    local f = assert(io.open(log, 'w'))
    f:write('clean\nBAD\nmore\n')
    f:close()
    local ok, err = pcall(h.assert_nolog, 'BAD', log)
    h.eq(false, ok)
    assert(tostring(err):find('BAD', 1, true), 'error must name the pattern')
  end)
end)

describe('plugin logger routing through json_rpc', function()
  before_each(function() h.setup() end)

  it('captures rpc.stderr through the plugin logger', function()
    -- Fake process writes to stderr, which goes through
    -- json_rpc.lua:on_stderr -> log.error -> the env-overridden file.
    local log, dir = fresh_log()
    finally(function() h.rmdir(dir) end)

    h.with_fake_kak_server(
      [[
      io.stderr:write('FAKE-STDERR-MARKER\n')
      io.stderr:flush()
      fake.notify('set_ui_options', {{}})
      fake.sleep(500)
      fake.exit(0)
    ]],
      { wire_log = log },
      function(_, captured)
        vim.wait(2000, function() return #captured >= 1 end)
        return #captured
      end
    )

    -- Both the plugin logger and the fake process's wire capture
    -- share this file; either side or both could match.
    h.assert_log('rpc.stderr', log)
    h.assert_log('FAKE%-STDERR%-MARKER', log)
  end)

  it('emits a DEBUG rpc.receive line for every inbound notification', function()
    local log, dir = fresh_log()
    finally(function() h.rmdir(dir) end)

    h.with_fake_kak_server(
      [[
      fake.notify('set_ui_options', {{foo='bar'}})
      fake.sleep(500)
      fake.exit(0)
    ]],
      { wire_log = log },
      function(_, captured)
        vim.wait(2000, function() return #captured >= 1 end)
        return #captured
      end
    )

    h.assert_log('rpc%.receive', log)
    h.assert_log('set_ui_options', log)
  end)

  it('respects KAK_UI_LOG_LEVEL: DEBUG/INFO filtered at ERROR threshold', function()
    local log, dir = fresh_log()
    finally(function() h.rmdir(dir) end)

    -- stderr still routes through log.error (>= ERROR), so it must land
    -- in the file even with the level raised.
    h.with_fake_kak_server(
      [[
      fake.notify('set_ui_options', {{}})
      io.stderr:write('FAKE-STDERR-MARKER\n')
      io.stderr:flush()
      fake.sleep(500)
      fake.exit(0)
    ]],
      { wire_log = log, log_level = 'ERROR' },
      function(_, captured)
        vim.wait(2000, function() return #captured >= 1 end)
        return #captured
      end
    )

    -- DEBUG rpc.receive (from json_rpc._dispatch) and INFO subprocess
    -- exit (from Transport:listen) must both be suppressed.
    h.assert_nolog('rpc%.receive', log)
    h.assert_nolog('subprocess exit', log)
    -- ERROR-level stderr and the fake process wire capture still land.
    h.assert_log('rpc.stderr', log)
    h.assert_log('FAKE%-STDERR%-MARKER', log)
  end)

  it('logs a handler error when a notification payload fails decode', function()
    -- init.lua's on_notify wraps every handler in pcall; a bad params
    -- payload triggers log.warn('handler', method, 'error:', ...).
    local log, dir = fresh_log()
    finally(function() h.rmdir(dir) end)

    -- Mirror init.lua's on_notify: decode first, route to handler.
    local function user_on_notify(method, params)
      local ok, err = pcall(
        require('kak.ui.protocol').decode,
        { jsonrpc = '2.0', method = method, params = params }
      )
      if not ok then require('kak.ui.log').log.warn('handler', method, 'error:', tostring(err)) end
    end

    h.with_fake_kak_server(
      [[
      fake.notify('draw_status', { {}, {}, -1, {}, {}, 'unknown-style' })
      fake.notify('set_ui_options', {{}})
      fake.sleep(500)
      fake.exit(0)
    ]],
      { wire_log = log, on_notify = user_on_notify },
      function(_, captured)
        vim.wait(2000, function() return #captured >= 2 end)
        return #captured
      end
    )

    h.assert_log('handler', log)
    h.assert_log('draw_status', log)
  end)

  it('logs peer response id not integer when id is non-numeric', function()
    local log, dir = fresh_log()
    finally(function() h.rmdir(dir) end)

    h.with_fake_kak_server(
      [[
      fake.notify('set_ui_options', {{}})
      fake.sleep(200)
      io.stdout:write('{"jsonrpc":"2.0","id":"abc","result":{}}\n')
      io.stdout:flush()
      fake.sleep(500)
      fake.exit(0)
    ]],
      { wire_log = log },
      function(sess, captured)
        -- Wait until the fake process has fully exited so stdout
        -- and stderr are flushed.
        vim.wait(3000, function() return sess:is_closing() end)
        return #captured
      end
    )

    h.assert_log('peer response id not integer', log)
  end)
end)

describe('KAK_UI_LOG_FILE env override', function()
  before_each(function() h.setup() end)

  it('routes log writes to the override path (not stdpath default)', function()
    local log, dir = fresh_log()
    finally(function() h.rmdir(dir) end)

    h.with_fake_kak_server(
      [[
      io.stderr:write('env-override-marker\n')
      io.stderr:flush()
      fake.sleep(300)
      fake.exit(0)
    ]],
      { wire_log = log },
      function(sess, _)
        vim.wait(3000, function() return sess:is_closing() end)
        return 0
      end
    )

    -- The override path must have content; the default stdpath('log')
    -- destination must NOT have been touched by this run.
    h.assert_log('env%-override%-marker', log)
    local default_log = h.fn.stdpath('log') .. '/kak-ui.log'
    if h.fn.filereadable(default_log) == 1 then
      local content = table.concat(h.fn.readfile(default_log), '\n')
      assert(
        not content:find('env%-override%-marker', 1, true),
        'default stdpath log must not receive env-override writes'
      )
    end
  end)
end)
