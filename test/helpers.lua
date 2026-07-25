-- Test helpers. Re-exports nvim-test's and adds:
--   write_executable / write_file / write_wire_logged - tmp scripts/files
--   with_kak_session / with_fake_kak - spawn and run a body in the child
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

  local result = exec_lua(function(cmd, extra_args, body_src, ...)
    local body = assert(loadstring(body_src))
    local sess = require('kak.ui').open({ cmd = cmd, extra_args = extra_args })
    local got = body(sess, ...)
    sess:close()
    return got
  end, cmd, extra_args, string.dump(body), ...)

  M.sleep(200)
  if wire_path then os.remove(wire_path) end
  return result
end

--- Spawn a fake-kak shell script and run `body(sess, captured, ...)` in
--- the child. `sess` is a raw `kak.ui.json_rpc.Connection`; `captured`
--- is appended `{method, params}` for each inbound NOTIFY. Drains 200 ms.
--- @param script string
--- @param body fun(sess: any, captured: table, ...): any
--- @return any
function M.with_fake_kak(script, body, ...)
  local fake_path = M.write_executable(script)
  local result = exec_lua(function(fake_path, body_src, ...)
    local body = assert(loadstring(body_src))
    local rpc = require('kak.ui.json_rpc')
    local captured = {}
    local sess = rpc.spawn({ fake_path }, {
      dispatchers = {
        on_notify = function(method, params) captured[#captured + 1] = { method, params } end,
        on_request = function() end,
        on_exit = function() end,
        on_error = function() end,
      },
    })
    local got = body(sess, captured, ...)
    sess:terminate()
    return got
  end, fake_path, string.dump(body), ...)

  M.sleep(200)
  os.remove(fake_path)
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

return M
