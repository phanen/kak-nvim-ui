-- Test helpers. Re-exports nvim-test's and adds:
--   write_file - tmp data file
--   with_kak_session - spawn real kak -ui json and run a body in the child
--   with_fake_kak_server - structured Lua spec for fake-kak-server fixture
--   with_screen - attach a Screen for screen:expect / snapshot_util
--   rmdir - safe recursive delete (replaces `rm -rf` shell patterns)
--   assert_log / assert_nolog - match patterns in the plugin log file
--
-- Wire logging no longer goes through a shell wrapper. The plugin's
-- own logger is file-backed (lua/kak/ui/log.lua) and reads
-- $KAK_UI_LOG_FILE / $KAK_UI_LOG_LEVEL at process start. Tests
-- forward those env vars into the child nvim (or fake-kak-server)
-- and then `assert_log(pat, logfile)` against the resulting file.

local helpers = require('nvim-test.helpers')

local M = helpers

local exec_lua = helpers.exec_lua
local Screen = require('nvim-test.screen')

--- Append project root to the child's runtimepath. Call in before_each.
function M.setup()
  M.clear()
  exec_lua(function() vim.opt.rtp:append(vim.fn.getcwd()) end)
end

--- Write `lines` joined by `\n` to a tmp file. Caller removes with os.remove.
--- @param lines string[]
--- @return string path
function M.write_file(lines)
  local path = M.fn.tempname()
  local f = assert(io.open(path, 'w'))
  f:write(table.concat(lines, '\n') .. '\n')
  f:flush()
  f:close()
  return path
end

--- Truncate `logfile` (creating it if missing) so the next test
--- starts with a clean tail. `with_kak_session` and
--- `with_fake_kak_server` call this when `wire_log` is set.
--- @param logfile string
local function truncate_log(logfile)
  local dir = M.fn.fnamemodify(logfile, ':h')
  if dir and dir ~= '' and dir ~= '.' then M.fn.mkdir(dir, 'p') end
  local f = assert(io.open(logfile, 'w'))
  f:close()
end

--- Spawn real `kak -ui json` and run `body(sess, ...)` in the child.
--- `sess` is a `kak.ui.Session` with `.buf` / `.renderer` / `.conn`.
--- Extra args are forwarded through the rpc layer (Lua closures do
--- not survive `string.dump` and would be nil in the child).
--- Drains 200 ms after body returns.
---
--- When `opts.wire_log` is set, the child nvim's plugin logger is
--- redirected to that path at DEBUG level BEFORE `kak.ui` is
--- required, so log.lua picks up the override at module load time.
--- Use `assert_log` to inspect what the child wrote.
--- @param opts { cmd?: string[], extra_args?: string[], wire_log?: string }
--- @param body fun(sess: any, ...): any
--- @return any
function M.with_kak_session(opts, body, ...)
  local cmd = opts.cmd or { 'kak' }
  local extra_args = opts.extra_args or {}

  if opts.wire_log then truncate_log(opts.wire_log) end

  -- pcall so internal cleanup runs even if body throws inside the child.
  -- busted's `finally()` resolves via the test's _ENV, so it cannot be
  -- used from this module-level helper.
  -- `wire_log` defaults to '' so exec_lua packs a dense args array even
  -- when the test does not request wire capture.
  local ok, result = pcall(exec_lua, function(cmd, extra_args, wire_log, body_src, ...)
    if wire_log ~= nil and wire_log ~= vim.NIL and wire_log ~= '' then
      vim.env.KAK_UI_LOG_FILE = wire_log
      vim.env.KAK_UI_LOG_LEVEL = 'DEBUG'
    end
    local body = assert(loadstring(body_src))
    local sess = require('kak.ui').open({ cmd = cmd, extra_args = extra_args })
    local got = body(sess, ...)
    sess:close()
    return got
  end, cmd, extra_args, opts.wire_log or '', string.dump(body), ...)

  M.sleep(200)
  if not ok then error(result) end
  return result
end

--- Attach a `nvim-test.screen.Screen` to the current test session.
--- Use in `before_each` so redraw events from `kak.ui` (driven via
--- `exec_lua` in the test body) flow into the screen, then call
--- `screen:expect(...)` from the test body to assert the rendered grid.
--- Detach in `after_each`.
--- @param width integer
--- @param height integer
--- @return table -- Screen instance.
function M.with_screen(width, height)
  local screen = Screen.new(width, height)
  screen:attach()
  return screen
end

--- Recursively delete `path`. Safe replacement for
--- `os.execute('rm -rf ' .. path)`, which is shell-injection-prone when
--- `path` contains spaces or metacharacters. Uses libuv via `vim.fs.rm`
--- (available in nvim 0.8+) and tolerates a missing path.
--- @param path string
function M.rmdir(path)
  vim.fs.rm(path, { recursive = true, force = true })
end

--- Absolute path of the fake-kak-server fixture.
--- @return string
function M.fake_kak_fixture_path()
  return assert(
    M.fn.fnamemodify('./test/fixtures/fake-kak-server.lua', ':p'),
    'fake-kak-server fixture missing'
  )
end

--- Path to the nvim binary the spawned fake server should reuse. In
--- nvim-test, `NVIM_PRG` points at the target nvim (the same one that
--- ends up running the body), so the fake server and the body share
--- runtime/version. Falls back to `nvim` on PATH for non nvim-test use.
--- @return string
function M.fake_kak_nvim_path() return os.getenv('NVIM_PRG') or M.fn.exepath('nvim') or 'nvim' end

--- Spawn the fake-kak-server fixture running `spec_lua_src` and run
--- `body(sess, captured, ...)` in the child. The spec is a small Lua
--- script that drives the wire through the global `fake` API:
---
---   fake.notify(method, params)
---   fake.respond(id, err, result)
---   fake.expect_notify(method, params)
---   fake.expect_request(method, handler)
---   fake.recv()
---   fake.sleep(ms)
---   fake.exit(code)
---
--- See `test/fixtures/fake-kak-server.lua`.
---
--- `opts.wire_log` controls two parallel streams via env vars:
---   KAK_UI_LOG_FILE  -> child's plugin logger (json rpc + stderr)
---   FAKE_KAK_WIRE_LOG -> fake process's own wire capture
--- Both can be set to the same path or different paths.
---
--- @param spec_lua_src string
--- @param opts? { wire_log?: string }
--- @param body fun(sess: any, captured: table, ...): any
--- @return any
function M.with_fake_kak_server(spec_lua_src, opts, body, ...)
  if type(opts) == 'function' then
    body, opts = opts, nil
  end
  opts = opts or {}
  -- LuaJIT's `...` only resolves in the immediate vararg scope, so
  -- capture forwarded args into a table before entering `pcall`.
  local forward = { ... }
  local n_forward = select('#', ...)

  -- Spec is a plain Lua source file loaded by `nvim -l`; no +x bit
  -- needed, so skip the wrapper script and pass argv directly to
  -- vim.system. Env is forwarded via rpc.spawn opts.
  local spec_path = M.fn.tempname()
  local spec_f = assert(io.open(spec_path, 'w'))
  spec_f:write(spec_lua_src)
  spec_f:close()

  local fixture = M.fake_kak_fixture_path()
  local nvim_path = M.fake_kak_nvim_path()
  local cmd = { nvim_path, '-l', fixture, spec_path }
  -- Two parallel wire streams: child's plugin logger (json rpc,
  -- stderr) and fake process's own wire capture. Both write to
  -- `wire_log`. We always pass env so the child exec_lua packing
  -- stays dense even when no wire_log is set.
  local env = {}
  if opts.wire_log then
    truncate_log(opts.wire_log)
    env.FAKE_KAK_WIRE_LOG = opts.wire_log
  end

  local result
  local ok, err = pcall(function()
    result = exec_lua(function(cmd, env, wire_log, body_src, fwd, n_fwd)
      -- Set the child's plugin logger BEFORE requiring the plugin,
      -- so log.lua picks up the override at module load time.
      if wire_log ~= nil and wire_log ~= vim.NIL and wire_log ~= '' then
        vim.env.KAK_UI_LOG_FILE = wire_log
        vim.env.KAK_UI_LOG_LEVEL = 'DEBUG'
      end
      local body = assert(loadstring(body_src))
      local rpc = require('kak.ui.json_rpc')
      local captured = {}
      local spawn_opts = {
        dispatchers = {
          on_notify = function(method, params) captured[#captured + 1] = { method, params } end,
          on_request = function(method, _params)
            -- Forwarded requests from the fake server: no handler in
            -- current tests, but return an explicit error so the
            -- server role in `Connection:_dispatch` is happy.
            return nil, { code = -32601, message = 'not implemented: ' .. method }
          end,
          on_exit = function() end,
          on_error = function(code, err) captured[#captured + 1] = { 'error', { code, err } } end,
        },
      }
      if next(env) then spawn_opts.env = env end
      local sess = rpc.spawn(cmd, spawn_opts)
      local got = body(sess, captured, unpack(fwd, 1, n_fwd))
      sess:terminate()
      return got
    end, cmd, env, opts.wire_log or '', string.dump(body), forward, n_forward)
  end)

  M.sleep(200)
  os.remove(spec_path)
  if not ok then error(err) end
  return result
end

--- Resolve the log file path. Defaults to `$KAK_UI_LOG_FILE` when
--- set in the test runner's env, otherwise
--- `<stdpath('log')>/kak-ui.log` (matches what the child nvim would
--- pick). `assert_log` defaults to this when `logfile` is omitted.
--- @param logfile? string
--- @return string
function M.default_log_path(logfile)
  if logfile and logfile ~= '' then return logfile end
  local env = os.getenv('KAK_UI_LOG_FILE')
  if env and env ~= '' then return env end
  return M.fn.stdpath('log') .. '/kak-ui.log'
end

--- Read up to `nrlines` trailing lines from `logfile`. Tolerates a
--- missing file (returns an empty list) and trims to the last
--- 2 MB to avoid blowing up on long-running tests.
--- @param logfile string
--- @param nrlines integer
--- @return string[]
local function read_log_tail(logfile, nrlines)
  local f = io.open(logfile, 'r')
  if not f then return {} end
  local size = f:seek('end')
  local offset = size and (size - 2000000) or 0
  if offset < 0 then offset = 0 end
  f:seek('set', offset)
  local content = f:read('*a') or ''
  f:close()
  local lines = vim.split(content, '\n', { plain = true })
  if #lines > nrlines then
    local out = {}
    for i = #lines - nrlines + 1, #lines do
      out[#out + 1] = lines[i]
    end
    return out
  end
  return lines
end

--- Assert that `pat` matches at least one line in the tail of
--- `logfile`. Retries for up to ~1 s so writes that haven't been
--- flushed yet still satisfy the assertion. See neovim
--- `testutil.lua:assert_log` for the original pattern.
--- @param pat string Lua pattern (passed to `string.match`)
--- @param logfile? string Default: `default_log_path()`
--- @param nrlines? integer Tail size, default 10
function M.assert_log(pat, logfile, nrlines)
  logfile = M.default_log_path(logfile)
  nrlines = nrlines or 10
  local hrtime = vim.uv and vim.uv.hrtime or os.clock
  local deadline = hrtime() + 1e9
  local matched_lines
  while true do
    local lines = read_log_tail(logfile, nrlines)
    matched_lines = lines
    for _, line in ipairs(lines) do
      if line:match(pat) then return true end
    end
    if hrtime() > deadline then break end
    M.sleep(50)
  end
  error(string.format(
    'pattern %s not found in last %d lines of %q:\n%s',
    vim.inspect(pat),
    nrlines,
    logfile,
    table.concat(matched_lines or {}, '\n')
  ))
end

--- Assert that `pat` does NOT match any line in the tail of
--- `logfile`. Same retry behaviour as `assert_log`.
--- @param pat string Lua pattern
--- @param logfile? string
--- @param nrlines? integer
function M.assert_nolog(pat, logfile, nrlines)
  logfile = M.default_log_path(logfile)
  nrlines = nrlines or 10
  local hrtime = vim.uv and vim.uv.hrtime or os.clock
  local deadline = hrtime() + 1e9
  while true do
    local lines = read_log_tail(logfile, nrlines)
    for _, line in ipairs(lines) do
      if line:match(pat) then
        error(string.format(
          'pattern %s unexpectedly found in last %d lines of %q:\n%s',
          vim.inspect(pat),
          nrlines,
          logfile,
          table.concat(lines, '\n')
        ))
      end
    end
    if hrtime() > deadline then return true end
    M.sleep(50)
  end
end

return M