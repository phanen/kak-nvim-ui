-- Test helpers. Re-exports nvim-test's and adds:
--   write_file, with_kak_session, with_fake_kak_server, with_screen,
--   rmdir, assert_log, assert_nolog

local helpers = require('nvim-test.helpers')

local M = helpers

local exec_lua = helpers.exec_lua
local Screen = require('nvim-test.screen')

function M.setup()
  M.clear()
  exec_lua(function() vim.opt.rtp:append(vim.fn.getcwd()) end)
end

---@param lines string[]
---@return string
function M.write_file(lines)
  local path = M.fn.tempname()
  local f = assert(io.open(path, 'w'))
  f:write(table.concat(lines, '\n') .. '\n')
  f:flush()
  f:close()
  return path
end

---@param logfile string
local function truncate_log(logfile)
  local dir = M.fn.fnamemodify(logfile, ':h')
  if dir and dir ~= '' and dir ~= '.' then M.fn.mkdir(dir, 'p') end
  local f = assert(io.open(logfile, 'w'))
  f:close()
end

---@param opts { cmd?: string[], extra_args?: string[], wire_log?: string }
---@param body fun(sess: any, ...): any
function M.with_kak_session(opts, body, ...)
  local cmd = opts.cmd or { 'kak' }
  local extra_args = opts.extra_args or {}

  if opts.wire_log then truncate_log(opts.wire_log) end

  -- busted's finally() cannot be used from module-level helpers.
  -- '' sentinel keeps exec_lua varargs dense.
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

---@param width integer
---@param height integer
---@return table
function M.with_screen(width, height)
  local screen = Screen.new(width, height)
  screen:attach()
  return screen
end

---@param path string
function M.rmdir(path)
  vim.fs.rm(path, { recursive = true, force = true })
end

---@return string
function M.fake_kak_fixture_path()
  return assert(
    M.fn.fnamemodify('./test/fixtures/fake-kak-server.lua', ':p'),
    'fake-kak-server fixture missing'
  )
end

---@return string
function M.fake_kak_nvim_path() return os.getenv('NVIM_PRG') or M.fn.exepath('nvim') or 'nvim' end

---@param spec_lua_src string
---@param opts? { wire_log?: string, log_level?: string, on_notify?: fun(method: string, params?: any[]): any }
---@param body fun(sess: any, captured: table, ...): any
function M.with_fake_kak_server(spec_lua_src, opts, body, ...)
  if type(opts) == 'function' then
    body, opts = opts, nil
  end
  opts = opts or {}
  local log_level = opts.log_level or 'DEBUG'
  -- LuaJIT `...` resolves only in immediate vararg scope; capture first.
  local forward = { ... }
  local n_forward = select('#', ...)

  local spec_path = M.fn.tempname()
  local spec_f = assert(io.open(spec_path, 'w'))
  spec_f:write(spec_lua_src)
  spec_f:close()

  local fixture = M.fake_kak_fixture_path()
  local nvim_path = M.fake_kak_nvim_path()
  local cmd = { nvim_path, '-l', fixture, spec_path }
  local env = {}
  if opts.wire_log then
    truncate_log(opts.wire_log)
    env.FAKE_KAK_WIRE_LOG = opts.wire_log
  end

  local custom_on_notify_src = opts.on_notify and string.dump(opts.on_notify) or nil

  local result
  local ok, err = pcall(function()
    result = exec_lua(function(cmd, env, wire_log, log_level, custom_on_notify, body_src, fwd, n_fwd)
      -- Set logger env BEFORE requiring the plugin.
      if wire_log ~= nil and wire_log ~= vim.NIL and wire_log ~= '' then
        vim.env.KAK_UI_LOG_FILE = wire_log
        vim.env.KAK_UI_LOG_LEVEL = log_level
      end
      local body = assert(loadstring(body_src))
      local rpc = require('kak.ui.json_rpc')
      local captured = {}
      local on_notify
      if custom_on_notify ~= nil and custom_on_notify ~= vim.NIL and custom_on_notify ~= '' then
        local user_notify = assert(loadstring(custom_on_notify))
        on_notify = function(method, params)
          captured[#captured + 1] = { method, params }
          user_notify(method, params)
        end
      else
        on_notify = function(method, params) captured[#captured + 1] = { method, params } end
      end
      local spawn_opts = {
        dispatchers = {
          on_notify = on_notify,
          on_request = function(method, _params)
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
    end, cmd, env, opts.wire_log or '', log_level, custom_on_notify_src or '', string.dump(body), forward, n_forward)
  end)

  M.sleep(200)
  os.remove(spec_path)
  if not ok then error(err) end
  return result
end

--- Poll `buf` until `predicate(lines)` returns true, or `timeout` ms.
---@param buf integer
---@param predicate fun(lines: string[]): boolean
---@param timeout? integer
---@return string[]?
function M.wait_for_lines(buf, predicate, timeout)
  timeout = timeout or 3000
  local got = nil
  vim.wait(timeout, function()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    if predicate(lines) then
      got = lines
      return true
    end
    return false
  end)
  return got
end

---@param logfile? string
---@return string
function M.default_log_path(logfile)
  if logfile and logfile ~= '' then return logfile end
  local env = os.getenv('KAK_UI_LOG_FILE')
  if env and env ~= '' then return env end
  return M.fn.stdpath('log') .. '/kak-ui.log'
end

---@param logfile string
---@param nrlines integer
---@return string[]
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

--- Poll `logfile` until `check(lines)` returns true, or 1 s deadline.
--- `check` may also call error() to fail immediately. Returns the final
--- lines and whether check returned true before the deadline.
---@param logfile string
---@param nrlines integer
---@param check fun(lines: string[]): boolean?
---@return string[] lines
---@return boolean matched
local function wait_for_log(logfile, nrlines, check)
  local hrtime = vim.uv and vim.uv.hrtime or os.clock
  local deadline = hrtime() + 1e9
  local lines
  while true do
    lines = read_log_tail(logfile, nrlines)
    if check(lines) then return lines, true end
    if hrtime() > deadline then return lines, false end
    M.sleep(50)
  end
end

---@param pat string Lua pattern
---@param logfile? string
---@param nrlines? integer
function M.assert_log(pat, logfile, nrlines)
  logfile = M.default_log_path(logfile)
  nrlines = nrlines or 10
  local lines, matched = wait_for_log(logfile, nrlines, function(ls)
    for _, l in ipairs(ls) do
      if l:match(pat) then return true end
    end
  end)
  if matched then return true end
  error(string.format(
    'pattern %s not found in last %d lines of %q:\n%s',
    vim.inspect(pat), nrlines, logfile, table.concat(lines, '\n')
  ))
end

---@param pat string Lua pattern
---@param logfile? string
---@param nrlines? integer
function M.assert_nolog(pat, logfile, nrlines)
  logfile = M.default_log_path(logfile)
  nrlines = nrlines or 10
  wait_for_log(logfile, nrlines, function(ls)
    for _, l in ipairs(ls) do
      if l:match(pat) then
        error(string.format(
          'pattern %s unexpectedly found in last %d lines of %q:\n%s',
          vim.inspect(pat), nrlines, logfile, table.concat(ls, '\n')
        ))
      end
    end
  end)
  return true
end

return M
