---
--- Self-contained NDJSON JSON-RPC over a child-process stdio (or a unix
--- domain socket). Ported from neovim/runtime/lua/vim/json/rpc.lua so the
--- plugin does not depend on a host nvim that ships `vim.json.rpc`.
---
--- Wire format: one JSON object per `\n`-terminated chunk. JSON-RPC 2.0
--- objects with `jsonrpc`, `method`, `params` (positional array) and
--- optional `id`. Kakoune writes notifications to stdout and never reads
--- replies, so the Kakoune -> UI direction is pure notification traffic.
--- The UI -> Kakoune direction is pure `keys` / `mouse_*` / `resize` /
--- `scroll` / `menu_select` notifications.

local M = {}

-- ---------------------------------------------------------------------------
-- Host shims
-- ---------------------------------------------------------------------------

local uv = vim.uv or vim.loop
if not uv then error('kak.ui.json_rpc requires vim.uv (nvim 0.5+)') end

local json_encode = (vim.json and vim.json.encode) or vim.fn.json_encode
local json_decode = (vim.json and vim.json.decode) or vim.fn.json_decode

local NIL = vim.NIL or setmetatable({}, { __tostring = function() return 'vim.NIL' end })

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

local function assert_integer(x)
  if type(x) ~= 'number' or x ~= math.floor(x) then
    error('expected integer, got ' .. tostring(x), 2)
  end
  return x
end

local function noop_log()
  return {
    info = function() end,
    debug = function() end,
    warn = function(...) end,
    error = function(...) end,
  }
end

local function make_log(level)
  local lvl = level or 'warn'
  local levels = { trace = 0, debug = 1, info = 2, warn = 3, error = 4, off = 5 }
  local threshold = levels[lvl] or 3
  local function emit(name, ...)
    if (levels[name] or 99) < threshold then return end
    local n = select('#', ...)
    local args = { ... }
    local parts = { '[kak.json_rpc]', name }
    for i = 1, n do
      local v = args[i]
      if type(v) == 'string' then
        parts[#parts + 1] = v
      elseif type(v) == 'table' then
        parts[#parts + 1] = vim.inspect(v)
      else
        parts[#parts + 1] = tostring(v)
      end
    end
    io.stderr:write(table.concat(parts, ' '), '\n')
  end
  return {
    info = function(...) emit('info', ...) end,
    debug = function(...) emit('debug', ...) end,
    warn = function(...) emit('warn', ...) end,
    error = function(...) emit('error', ...) end,
  }
end

-- ---------------------------------------------------------------------------
-- NDJSON framing
-- ---------------------------------------------------------------------------

local function ndjson_encode(msg) return msg .. '\n' end

local function ndjson_feed(buf, chunk, on_message)
  -- Splits `buf .. chunk` on `\n`, emits each complete line, retains trailing
  -- partial line in `buf`. Tolerates empty lines and \r\n line endings.
  local data = buf .. chunk
  buf = nil
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

-- ---------------------------------------------------------------------------
-- Transport: a thin abstraction over vim.uv pipes.
--
--- @class kak.ui.json_rpc.Transport
--- @field closing boolean
--- @field stdin uv_pipe_t
--- @field stdout uv_pipe_t
--- @field stderr uv_pipe_t|nil
--- @field process uv_process_t|nil
local Transport = {}
Transport.__index = Transport

--- @param on_data fun(err: string|nil, chunk: string|nil)
--- @param on_exit fun(code: integer, signal: integer)
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

--- Spawn a child process and wire stdio.
--- @param cmd string[]
--- @param extra { cwd?: string, env?: table<string,string> }
--- @param log table
--- @return kak.ui.json_rpc.Transport
function Transport.spawn(cmd, extra, log)
  local stdin = uv.new_pipe(false)
  local stdout = uv.new_pipe(false)
  local stderr = uv.new_pipe(false)
  assert(stdin and stdout and stderr, 'failed to allocate uv pipes')
  local handle, pid_or_err
  local spawn_opts = {
    args = cmd,
    stdio = { stdin, stdout, stderr },
  }
  if extra then
    if extra.cwd then spawn_opts.cwd = extra.cwd end
    if extra.env then spawn_opts.env = extra.env end
  end
  handle, pid_or_err = uv.spawn(cmd[1] or cmd, spawn_opts, function(code, signal)
    if log then log.info('subprocess exit', { code = code, signal = signal }) end
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

-- ---------------------------------------------------------------------------
-- Connection
--
--- @class kak.ui.json_rpc.Dispatchers
--- @field on_notify fun(method: string, params?: any[]): nil
--- @field on_request fun(method: string, params?: any[]): any?, table?
--- @field on_exit fun(code: integer, signal: integer): nil
--- @field on_error fun(code: integer, err: any): nil
local Connection = {}
Connection.__index = Connection

local ERROR_CODES = {
  parse_error = -32700,
  invalid_request = -32600,
  method_not_found = -32601,
  invalid_params = -32602,
  internal_error = -32603,
}

M.client_errors = {
  INVALID_SERVER_MESSAGE = 1,
  INVALID_SERVER_JSON = 2,
  READ_ERROR = 3,
  NOTIFICATION_HANDLER_ERROR = 4,
  SERVER_REQUEST_HANDLER_ERROR = 5,
  SERVER_RESULT_CALLBACK_ERROR = 6,
}

--- @param transport kak.ui.json_rpc.Transport
--- @param dispatchers kak.ui.json_rpc.Dispatchers
--- @param log table
function Connection.new(transport, dispatchers, log)
  assert(transport, 'transport required')
  assert(dispatchers, 'dispatchers required')
  assert(type(dispatchers.on_notify) == 'function', 'on_notify required')
  assert(type(dispatchers.on_request) == 'function', 'on_request required')
  assert(type(dispatchers.on_exit) == 'function', 'on_exit required')
  assert(type(dispatchers.on_error) == 'function', 'on_error required')
  log = log or noop_log()

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
      -- Flush any partial line as a malformed message
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
  local log = self.log
  log.debug('rpc.receive', message)

  -- Inbound request from peer: JSON-RPC server role.
  if type(message.method) == 'string' and message.id ~= nil then
    local id = message.id
    if type(id) ~= 'number' and type(id) ~= 'string' and id ~= NIL then
      log.error('bad request id', message.method, id)
      self:on_error(M.client_errors.INVALID_SERVER_MESSAGE, message)
      return
    end
    vim.schedule(function()
      xpcall(function()
        local result, err = self.dispatchers.on_request(message.method, message.params)
        if result == nil and err == nil then
          error('method ' .. tostring(message.method) .. ': either result or error required')
        end
        if err then
          assert(type(err) == 'table', 'err must be table')
          assert(type(err.code) == 'number', 'err.code must be number')
          assert(type(err.message) == 'string', 'err.message must be string')
          assert(
            err.code >= -32768 and err.code <= -32000,
            'err.code ' .. tostring(err.code) .. ' outside JSON-RPC reserved range'
          )
        end
        self:respond(id, err, result)
      end, function(err)
        self:on_error(M.client_errors.SERVER_REQUEST_HANDLER_ERROR, err)
        self:respond(id, { code = ERROR_CODES.internal_error, message = tostring(err) }, nil)
      end)
    end)
    return
  end

  -- Inbound response to one of our requests.
  if message.id ~= nil then
    if message.id == NIL then
      log.warn('peer sent null id response')
      self:on_error(M.client_errors.INVALID_SERVER_MESSAGE, message)
      return
    end
    if message.error == nil and message.result == nil then
      log.error('peer sent empty result and error', message)
      self:on_error(M.client_errors.INVALID_SERVER_MESSAGE, message)
      return
    end
    local ok, result_id = pcall(assert_integer, message.id)
    if not ok then
      log.error('peer response id not integer', message)
      self:on_error(M.client_errors.INVALID_SERVER_MESSAGE, message)
      return
    end
    local cb = self.request_callbacks[result_id]
    if not cb then return end
    self.request_callbacks[result_id] = nil
    local ok2, err2 = pcall(
      cb,
      message.error,
      (message.result ~= nil and message.result ~= NIL) and message.result or nil,
      result_id
    )
    if not ok2 then self:on_error(M.client_errors.SERVER_RESULT_CALLBACK_ERROR, err2) end
    return
  end

  -- Inbound notification.
  if type(message.method) == 'string' then
    local ok, err = pcall(self.dispatchers.on_notify, message.method, message.params)
    if not ok then self:on_error(M.client_errors.NOTIFICATION_HANDLER_ERROR, err) end
    return
  end

  self:on_error(M.client_errors.INVALID_SERVER_MESSAGE, message)
end

--- @private
function Connection:_send(message)
  if self.transport:is_closing() then return false end
  local ok, json = pcall(json_encode, message)
  if not ok then
    self.log.error('encode failed', json)
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

--- @private
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

function Connection:on_error(code, err)
  assert(M.client_errors[code], 'unknown client error code: ' .. tostring(code))
  pcall(self.dispatchers.on_error, code, err)
end

-- ---------------------------------------------------------------------------
-- Public factory
-- ---------------------------------------------------------------------------

--- Spawn a child process and start a NDJSON JSON-RPC connection to it over
--- stdio. This is the primary entry point for talking to a Kakoune process
--- started with `-ui json`.
---
--- @param cmd string[] Command argv. The first element is the executable.
--- @param opts? { log?: table, dispatchers: kak.ui.json_rpc.Dispatchers,
---                cwd?: string, env?: table<string,string>,
---                log_level?: 'debug'|'info'|'warn'|'error' }
--- @return kak.ui.json_rpc.Connection
function M.spawn(cmd, opts)
  assert(type(cmd) == 'table' and #cmd >= 1, 'cmd must be non-empty array')
  opts = opts or {}
  assert(type(opts.dispatchers) == 'table', 'opts.dispatchers required')
  local log = opts.log or make_log(opts.log_level)
  local extra = { cwd = opts.cwd, env = opts.env }
  local transport = Transport.spawn(cmd, extra, log)
  return Connection.new(transport, opts.dispatchers, log)
end

M._make_log = make_log
M._ndjson_feed = ndjson_feed

return M
