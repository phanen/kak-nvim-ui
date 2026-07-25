-- Test helpers. Re-exports nvim-test's and adds:
--   write_executable / write_file / write_wire_logged - tmp scripts/files
--   with_kak_session - spawn real kak -ui json and run a body in the child
--   with_fake_kak_server - structured Lua spec for fake-kak-server fixture
--   with_screen - attach a Screen for screen:expect / snapshot_util
--   rmdir - safe recursive delete (replaces `rm -rf` shell patterns)

local helpers = require('nvim-test.helpers')

local M = helpers

local exec_lua = helpers.exec_lua
local Screen = require('nvim-test.screen')

--- Append project root to the child's runtimepath. Call in before_each.
function M.setup()
  M.clear()
  exec_lua(function() vim.opt.rtp:append(vim.fn.getcwd()) end)
end

--- Write `body` to a tmp file and chmod 755. Caller removes with os.remove.
--- @param body string
--- @return string path
function M.write_executable(body)
  local path = M.fn.tempname()
  local f = assert(io.open(path, 'w'))
  f:write(body)
  f:close()
  assert(vim.uv.fs_chmod(path, tonumber('755', 8)))
  return path
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

--- Write a wrapper that exec's `cmd` while teeing its stdout/stderr to
--- `wire_log`. `cmd` is shell-quoted (e.g. '/usr/bin/kak -ui json').
--- @param cmd string
--- @param wire_log string
--- @return string path
function M.write_wire_logged(cmd, wire_log)
  return M.write_executable(
    '#!/bin/sh\nexec '
      .. cmd
      .. ' "$@" 2>> '
      .. wire_log
      .. ' | tee -a '
      .. wire_log
      .. ' >/dev/null\n'
  )
end

--- Spawn real `kak -ui json` and run `body(sess, ...)` in the child.
--- `sess` is a `kak.ui.Session` with `.buf` / `.renderer` / `.conn`.
--- Extra args are forwarded through the rpc layer (Lua closures do
--- not survive `string.dump` and would be nil in the child).
--- Drains 200 ms after body returns.
--- @param opts { cmd?: string[], extra_args?: string[], wire_log?: string }
--- @param body fun(sess: any, ...): any
--- @return any
function M.with_kak_session(opts, body, ...)
  local cmd = opts.cmd or { 'kak' }
  local extra_args = opts.extra_args or {}
  local wire_path
  if opts.wire_log then
    wire_path = M.write_wire_logged(
      table.concat(cmd, ' ') .. ' ' .. table.concat(extra_args, ' '),
      opts.wire_log
    )
    cmd = { wire_path }
    extra_args = {}
  end

  -- pcall so internal cleanup runs even if body throws inside the child.
  -- busted's `finally()` resolves via the test's _ENV, so it cannot be
  -- used from this module-level helper.
  local ok, result = pcall(exec_lua, function(cmd, extra_args, body_src, ...)
    local body = assert(loadstring(body_src))
    local sess = require('kak.ui').open({ cmd = cmd, extra_args = extra_args })
    local got = body(sess, ...)
    sess:close()
    return got
  end, cmd, extra_args, string.dump(body), ...)

  M.sleep(200)
  if wire_path then os.remove(wire_path) end
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
--- Replaces the old shell-script `with_fake_kak`: the spec drives the
--- wire through structured tables instead of hand-written JSON strings.
--- See `test/fixtures/fake-kak-server.lua`.
---
--- `opts.wire_log` mirrors `with_kak_session`; the fixture writes every
--- inbound/outbound frame to it via the `FAKE_KAK_WIRE_LOG` env var.
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

  local spec_path = M.fn.tempname()
  local spec_f = assert(io.open(spec_path, 'w'))
  spec_f:write(spec_lua_src)
  spec_f:close()

  local fixture = M.fake_kak_fixture_path()
  local nvim_path = M.fake_kak_nvim_path()
  local prefix = ''
  if opts.wire_log then prefix = 'FAKE_KAK_WIRE_LOG=' .. opts.wire_log .. ' ' end
  local wrapper = M.write_executable(
    '#!/bin/sh\n'
      .. prefix
      .. "exec '"
      .. nvim_path
      .. "' -l '"
      .. fixture
      .. "' '"
      .. spec_path
      .. "'\n"
  )

  local result
  local ok, err = pcall(function()
    result = exec_lua(function(fake_path, body_src, fwd, n_fwd)
      local body = assert(loadstring(body_src))
      local rpc = require('kak.ui.json_rpc')
      local captured = {}
      local sess = rpc.spawn({ fake_path }, {
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
      })
      local got = body(sess, captured, unpack(fwd, 1, n_fwd))
      sess:terminate()
      return got
    end, wrapper, string.dump(body), forward, n_forward)
  end)

  M.sleep(200)
  os.remove(wrapper)
  os.remove(spec_path)
  if not ok then error(err) end
  return result
end

return M
