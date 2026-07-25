---
--- Self-contained NDJSON JSON-RPC over child-process stdio. Ported from
--- neovim/runtime/lua/vim/json/rpc.lua so the plugin does not depend on
--- a host nvim that ships `vim.json.rpc`.
---
--- Wire format: one JSON object per `\n`-terminated chunk. JSON-RPC 2.0
--- with `jsonrpc`, `method`, `params` (positional array) and optional
--- `id`. The Kakoune -> UI direction is pure notifications; the UI ->
--- Kakoune direction is pure `keys` / `mouse_*` / `resize` / `scroll` /
--- `menu_select` notifications.

local M = {}

local uv = vim.uv or vim.loop
if not uv then error('kak.ui.json_rpc requires vim.uv (nvim 0.5+)') end

local json_encode = vim.json.encode
local json_decode = vim.json.decode

local NIL = vim.NIL

local log = require('kak.ui.log').log

local function schedule_wrap(fn)
  if vim.schedule_wrap then return vim.schedule_wrap(fn) end
  return function(...)
    local args = { ... }
    vim.schedule(function() fn(unpack(args)) end)
  end
end

local function schedule_fn(fn)
  return function(...)
    local args = { ... }
    vim.schedule(function() fn(unpack(args)) end)
  end
end

local function ndjson_encode(msg) return msg .. '\n' end

local function ndjson_feed(buf, chunk, on_message)
  -- Splits `buf .. chunk` on `\n`, emits each complete line, retains
  -- the trailing partial line in `buf`. Tolerates `\r\n` and empty lines.
  local data = buf .. chunk
  local start = 1
  while true do
    local nl = data:find('\n', start, true)
    if not nl then return data:sub(start) end
    local line = data:sub(start, nl - 1)
    if line:sub(-1) == '\r' then line = line:sub(1, -2) end
    if #line > 0 then on_message(line) end
    start = nl + 1
  end
end

--- @class kak.ui.json_rpc.Transport
--- @field closing boolean
--- @field stdin uv.uv_pipe_t
--- @field stdout uv.uv_pipe_t
--- @field stderr uv..uv_pipe_t|nil
--- @field process uv.uv_process_t|nil
local Transport = {}
Transport.__index = Transport

function Transport:listen(on_data, on_exit)
  self.on_data = schedule_wrap(on_data)
  self.on_exit_cb = schedule_fn(on_exit)
  self.stdout:read_start(self.on_data)
end

function Transport:write(s)
  if self.closing then return false end
  if self.stdin and not self.stdin:is_closing() then
    self.stdin:write(s)
    return true
  end
  return false
end

function Transport:is_closing() return self.closing end

function Transport:terminate()
  if self.closing then return end
  self.closing = true
  if self.stdout and not self.stdout:is_closing() then
    pcall(function() self.stdout:read_stop() end)
    pcall(function() self.stdout:close() end)
  end
  if self.stdin and not self.stdin:is_closing() then
    pcall(function() self.stdin:shutdown() end)
    pcall(function() self.stdin:close() end)
  end
  if self.process and not self.process:is_closing() then
    pcall(function() self.process:kill('sigterm') end)
  end
  if self.stderr and not self.stderr:is_closing() then
    pcall(function() self.stderr:read_stop() end)
    pcall(function() self.stderr:close() end)
  end
  if self.on_exit_cb then self.on_exit_cb(0, 0) end
end

function Transport.spawn(cmd, extra)
  local stdin = uv.new_pipe(false)
  local stdout = uv.new_pipe(false)
  local stderr = uv.new_pipe(false)
  local spawn_opts = {
    args = cmd,
    stdio = { stdin, stdout, stderr },
  }
  if extra then
    if extra.cwd then spawn_opts.cwd = extra.cwd end
    if extra.env then spawn_opts.env = extra.env end
  end
  local handle, pid_or_err = uv.spawn(cmd[1], spawn_opts, function(code, signal)
    log.info('subprocess exit', { code = code, signal = signal })
    if stdout and not stdout:is_closing() then pcall(function() stdout:read_stop() end) end
  end)
  if not handle then
    pcall(function() stdin:close() end)
    pcall(function() stdout:close() end)
    pcall(function() stderr:close() end)
    error('uv.spawn failed: ' .. tostring(pid_or_err))
  end
  return setmetatable({
    closing = false,
    stdin = stdin,
    stdout = stdout,
    stderr = stderr,
    process = handle,
    pid = pid_or_err,
  }, Transport)
end

--- @class kak.ui.json_rpc.Dispatchers
--- @field on_notify fun(method: string, params?: any[]): nil
--- @field on_request fun(method: string, params?: any[]): any?, table?
--- @field on_exit fun(code: integer, signal: integer): nil
--- @field on_error fun(code: integer, err: any): nil
local Connection = {}
Connection.__index = Connection

M.client_errors = {
  INVALID_SERVER_MESSAGE = 1,
  INVALID_SERVER_JSON = 2,
  READ_ERROR = 3,
  NOTIFICATION_HANDLER_ERROR = 4,
  SERVER_REQUEST_HANDLER_ERROR = 5,
  SERVER_RESULT_CALLBACK_ERROR = 6,
}

local ERR_INTERNAL = -32603

function Connection.new(transport, dispatchers)
  assert(transport, 'transport required')
  assert(dispatchers, 'dispatchers required')
  assert(type(dispatchers.on_notify) == 'function', 'on_notify required')
  assert(type(dispatchers.on_request) == 'function', 'on_request required')
  assert(type(dispatchers.on_exit) == 'function', 'on_exit required')
  assert(type(dispatchers.on_error) == 'function', 'on_error required')

  local self = setmetatable({
    request_count = 0,
    request_callbacks = {},
    transport = transport,
    dispatchers = dispatchers,
    log = log,
    incoming_buf = '',
    closed = false,
  }, Connection)

  transport:listen(function(err, data)
    if self.closed then return end
    if err then
      self:on_error(M.client_errors.READ_ERROR, err)
      return
    end
    if data == nil then
      self.closed = true
      if #self.incoming_buf > 0 then
        self:_dispatch_raw(self.incoming_buf)
        self.incoming_buf = ''
      end
      self:terminate()
      return
    end
    self.incoming_buf = ndjson_feed(
      self.incoming_buf,
      data,
      function(line) self:_dispatch_raw(line) end
    )
  end, function(code, signal)
    if self.closed then return end
    self.closed = true
    pcall(self.dispatchers.on_exit, code, signal)
  end)

  return self
end

function Connection:_dispatch_raw(line)
  if #line == 0 then return end
  local ok, message = pcall(json_decode, line)
  if not ok or type(message) ~= 'table' then
    self:on_error(M.client_errors.INVALID_SERVER_JSON, message)
    return
  end
  self:_dispatch(message)
end

function Connection:_dispatch(message)
  log.debug('rpc.receive', message)

  -- Inbound request from peer: JSON-RPC server role.
  if type(message.method) == 'string' and message.id ~= nil then
    vim.schedule(function()
      xpcall(function()
        local result, err = self.dispatchers.on_request(message.method, message.params)
        if result == nil and err == nil then
          error('method ' .. tostring(message.method) .. ': either result or error required')
        end
        self:respond(message.id, err, result)
      end, function(err)
        self:on_error(M.client_errors.SERVER_REQUEST_HANDLER_ERROR, err)
        self:respond(message.id, { code = ERR_INTERNAL, message = tostring(err) }, nil)
      end)
    end)
    return
  end

  -- Inbound response to one of our requests.
  if message.id ~= nil then
    if type(message.id) ~= 'number' or message.id ~= math.floor(message.id) then
      log.error('peer response id not integer', message)
      self:on_error(M.client_errors.INVALID_SERVER_MESSAGE, message)
      return
    end
    if message.error == nil and message.result == nil then
      log.error('peer sent empty result and error', message)
      self:on_error(M.client_errors.INVALID_SERVER_MESSAGE, message)
      return
    end
    local cb = self.request_callbacks[message.id]
    if not cb then return end
    self.request_callbacks[message.id] = nil
    local ok, err = pcall(
      cb,
      message.error,
      (message.result ~= nil and message.result ~= NIL) and message.result or nil,
      message.id
    )
    if not ok then self:on_error(M.client_errors.SERVER_RESULT_CALLBACK_ERROR, err) end
    return
  end

  if type(message.method) == 'string' then
    local ok, err = pcall(self.dispatchers.on_notify, message.method, message.params)
    if not ok then self:on_error(M.client_errors.NOTIFICATION_HANDLER_ERROR, err) end
    return
  end

  self:on_error(M.client_errors.INVALID_SERVER_MESSAGE, message)
end

function Connection:_send(message)
  if self.transport:is_closing() then return false end
  local ok, json = pcall(json_encode, message)
  if not ok then
    log.error('encode failed', json)
    return false
  end
  return self.transport:write(ndjson_encode(json))
end

function Connection:is_closing() return self.closed or self.transport:is_closing() end

function Connection:terminate()
  if self.closed then return end
  self.closed = true
  self.transport:terminate()
end

function Connection:notify(method, params)
  assert(type(method) == 'string', 'method must be string')
  return self:_send({
    jsonrpc = '2.0',
    method = method,
    params = params,
  })
end

function Connection:respond(request_id, err, result)
  return self:_send({
    jsonrpc = '2.0',
    id = request_id,
    error = err,
    result = result,
  })
end

function Connection:request(method, params, callback)
  assert(type(method) == 'string', 'method must be string')
  assert(type(callback) == 'function', 'callback must be function')
  self.request_count = self.request_count + 1
  local request_id = self.request_count
  local sent = self:_send({
    jsonrpc = '2.0',
    id = request_id,
    method = method,
    params = params,
  })
  if not sent then return false end
  self.request_callbacks[request_id] = schedule_wrap(callback)
  return true, request_id
end

function Connection:on_error(code, err) pcall(self.dispatchers.on_error, code, err) end

--- Spawn a child process and start a NDJSON JSON-RPC connection to it
--- over stdio.
--- @param cmd string[] Command argv. The first element is the executable.
--- @param opts? { dispatchers: kak.ui.json_rpc.Dispatchers,
---                cwd?: string, env?: table<string,string> }
--- @return kak.ui.json_rpc.Connection
function M.spawn(cmd, opts)
  assert(type(cmd) == 'table' and #cmd >= 1, 'cmd must be non-empty array')
  opts = opts or {}
  assert(type(opts.dispatchers) == 'table', 'opts.dispatchers required')
  return Connection.new(Transport.spawn(cmd, { cwd = opts.cwd, env = opts.env }), opts.dispatchers)
end

M._ndjson_feed = ndjson_feed

return M
