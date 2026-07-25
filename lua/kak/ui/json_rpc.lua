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

---@class kak.ui.json_rpc.JsonValue
---@field [integer] kak.ui.json_rpc.JsonValue
---@field [string] kak.ui.json_rpc.JsonValue|string|integer|boolean|nil

---@class kak.ui.json_rpc.RpcRequest
---@field jsonrpc '2.0'
---@field id integer
---@field method string
---@field params any[]

---@class kak.ui.json_rpc.RpcNotification
---@field jsonrpc '2.0'
---@field method string
---@field params any[]

---@class kak.ui.json_rpc.RpcResponse
---@field jsonrpc '2.0'
---@field id integer
---@field error any
---@field result any

---@alias kak.ui.json_rpc.RpcMessage
---| kak.ui.json_rpc.RpcRequest
---| kak.ui.json_rpc.RpcNotification
---| kak.ui.json_rpc.RpcResponse

---@alias kak.ui.json_rpc.RequestCallback fun(err: any, result: any, request_id: integer)

---@class kak.ui.json_rpc.Dispatchers
---@field on_notify fun(method: string, params?: any[]): nil
---@field on_request fun(method: string, params?: any[]): any?, table?
---@field on_exit fun(code: integer, signal: integer): nil
---@field on_error fun(code: integer, err: any): nil

---@class kak.ui.json_rpc.TransportOptions
---@field cwd? string
---@field env? table<string, string>

---@class kak.ui.json_rpc.Transport
---@field closing boolean
---@field cmd string[]
---@field extra? kak.ui.json_rpc.TransportOptions
---@field sysobj? vim.SystemObj
---@field on_data fun(err: any, data: string?)
---@field on_exit_cb fun(code: integer, signal: integer)
---@field on_stderr fun(err: any, data: string?)
---@field listen fun(self: kak.ui.json_rpc.Transport, on_data: fun(err: any, data: string?), on_exit: fun(code: integer, signal: integer))
---@field write fun(self: kak.ui.json_rpc.Transport, s: string): boolean
---@field is_closing fun(self: kak.ui.json_rpc.Transport): boolean
---@field terminate fun(self: kak.ui.json_rpc.Transport)

---@class kak.ui.json_rpc.Connection
---@field request_count integer
---@field request_callbacks table<integer, kak.ui.json_rpc.RequestCallback>
---@field transport kak.ui.json_rpc.Transport
---@field dispatchers kak.ui.json_rpc.Dispatchers
---@field log kak.ui.log.Logger
---@field incoming_buf string
---@field closed boolean
---@field notify fun(self: kak.ui.json_rpc.Connection, method: string, params: any[]): boolean
---@field request fun(self: kak.ui.json_rpc.Connection, method: string, params: any[], callback: kak.ui.json_rpc.RequestCallback): boolean|integer
---@field respond fun(self: kak.ui.json_rpc.Connection, request_id: integer, err: any, result: any): boolean
---@field is_closing fun(self: kak.ui.json_rpc.Connection): boolean
---@field terminate fun(self: kak.ui.json_rpc.Connection)

local M = {}

if not vim.system then error('kak.ui.json_rpc requires vim.system (nvim 0.10+)') end

local json_encode = vim.json.encode
local json_decode = vim.json.decode

local NIL = vim.NIL

local log = require('kak.ui.log').log

---@param fn fun(...: any)
---@return fun(...: any)
local function schedule_wrap(fn)
  if vim.schedule_wrap then return vim.schedule_wrap(fn) end
  return function(...)
    local args = { ... }
    vim.schedule(function() fn(unpack(args)) end)
  end
end

---@param fn fun(...: any)
---@return fun(...: any)
local function schedule_fn(fn)
  return function(...)
    local args = { ... }
    vim.schedule(function() fn(unpack(args)) end)
  end
end

---@param msg string
---@return string
local function ndjson_encode(msg) return msg .. '\n' end

---@param buf string
---@param chunk string
---@param on_message fun(line: string)
---@return string remaining (incomplete) tail left in the buffer
local function ndjson_feed(buf, chunk, on_message)
  -- Splits `buf .. chunk` on `\n`, emits each complete line, retains
  -- the trailing partial line in `buf`. Tolerates `\r\n` and empty lines.
  local data = buf .. chunk
  local start, last_tail = 1, ''
  while true do
    local nl = data:find('\n', start, true)
    if not nl then
      last_tail = data:sub(start)
      break
    end
    local line = data:sub(start, nl - 1)
    if line:sub(-1) == '\r' then line = line:sub(1, -2) end
    if #line > 0 then on_message(line) end
    start = nl + 1
  end
  return last_tail
end

local Transport = {}
Transport.__index = Transport

---@param on_data fun(err: any, data: string?)
---@param on_exit fun(code: integer, signal: integer)
function Transport:listen(on_data, on_exit)
  self.on_data = schedule_wrap(on_data)
  self.on_exit_cb = schedule_fn(on_exit)
  -- Subprocess stderr is captured into the plugin logger so it
  -- travels through the same file sink as every other event
  -- (json rpc frames, decode errors, exit codes). Tests point
  -- `KAK_UI_LOG_FILE` at a per-test path and assert_log over the
  -- combined stream.
  self.on_stderr = function(_, chunk)
    if chunk then log.error('rpc.stderr', self.cmd[1], chunk) end
  end

  ---@type vim.SystemOpts
  local spawn_opts = {
    stdin = true,
    stdout = self.on_data,
    stderr = self.on_stderr,
  }
  if self.extra then
    if self.extra.cwd then spawn_opts.cwd = self.extra.cwd end
    if self.extra.env then spawn_opts.env = self.extra.env end
  end

  local ok, sysobj_or_err = pcall(vim.system, self.cmd, spawn_opts, function(out)
    log.info('subprocess exit', { code = out.code, signal = out.signal })
    if self.on_exit_cb then self.on_exit_cb(out.code, out.signal) end
  end)

  if not ok then
    ---@cast sysobj_or_err string
    local err = sysobj_or_err
    local sfx = err:match('ENOENT')
        and '. The command is either not installed, missing from PATH, or not executable.'
      or string.format(' with error message: %s', err)
    error(('Spawning process with cmd: `%s` failed%s'):format(vim.inspect(self.cmd), sfx))
  end
  ---@cast sysobj_or_err vim.SystemObj
  self.sysobj = sysobj_or_err
end

---@param s string
---@return boolean
function Transport:write(s)
  if self.closing then return false end
  if self.sysobj and not self.sysobj:is_closing() then
    self.sysobj:write(s)
    return true
  end
  return false
end

---@return boolean
function Transport:is_closing()
  if self.closing then return true end
  return self.sysobj ~= nil and self.sysobj:is_closing()
end

function Transport:terminate()
  if self.closing then return end
  self.closing = true
  if self.sysobj and not self.sysobj:is_closing() then
    pcall(function() self.sysobj:kill(15) end)
  end
end

---@param cmd string[]
---@param extra? kak.ui.json_rpc.TransportOptions
---@return kak.ui.json_rpc.Transport
function Transport.spawn(cmd, extra)
  return setmetatable({
    closing = false,
    cmd = cmd,
    extra = extra,
  }, Transport)
end

local Connection = {}
Connection.__index = Connection

---@enum kak.ui.json_rpc.ClientError
M.client_errors = {
  INVALID_SERVER_MESSAGE = 1,
  INVALID_SERVER_JSON = 2,
  READ_ERROR = 3,
  NOTIFICATION_HANDLER_ERROR = 4,
  SERVER_REQUEST_HANDLER_ERROR = 5,
  SERVER_RESULT_CALLBACK_ERROR = 6,
}

local ERR_INTERNAL = -32603

---@param transport kak.ui.json_rpc.Transport
---@param dispatchers kak.ui.json_rpc.Dispatchers
---@return kak.ui.json_rpc.Connection
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

---@param line string
function Connection:_dispatch_raw(line)
  if #line == 0 then return end
  local ok, message = pcall(json_decode, line)
  if not ok or type(message) ~= 'table' then
    self:on_error(M.client_errors.INVALID_SERVER_JSON, message)
    return
  end
  ---@cast message kak.ui.json_rpc.RpcMessage
  self:_dispatch(message)
end

---@param message kak.ui.json_rpc.RpcMessage
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
    ---@cast message.id integer
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

---@param message kak.ui.json_rpc.RpcNotification|kak.ui.json_rpc.RpcRequest|kak.ui.json_rpc.RpcResponse
---@return boolean
function Connection:_send(message)
  if self.transport:is_closing() then return false end
  local ok, json = pcall(json_encode, message)
  if not ok then
    log.error('encode failed', json)
    return false
  end
  return self.transport:write(ndjson_encode(json))
end

---@return boolean
function Connection:is_closing() return self.closed or self.transport:is_closing() end

function Connection:terminate()
  if self.closed then return end
  self.closed = true
  self.transport:terminate()
end

---@param method string
---@param params any[]
---@return boolean
function Connection:notify(method, params)
  assert(type(method) == 'string', 'method must be string')
  return self:_send({
    jsonrpc = '2.0',
    method = method,
    params = params,
  })
end

---@param request_id integer
---@param err any
---@param result any
---@return boolean
function Connection:respond(request_id, err, result)
  return self:_send({
    jsonrpc = '2.0',
    id = request_id,
    error = err,
    result = result,
  })
end

---@param method string
---@param params any[]
---@param callback kak.ui.json_rpc.RequestCallback
---@return boolean success status, or `false` if the message could not be sent
---@return integer? request_id id assigned by the server role when sent
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

---@param code integer
---@param err any
function Connection:on_error(code, err) pcall(self.dispatchers.on_error, code, err) end

---@class kak.ui.json_rpc.SpawnOptions
---@field dispatchers kak.ui.json_rpc.Dispatchers
---@field cwd? string
---@field env? table<string, string>

--- Spawn a child process and start a NDJSON JSON-RPC connection to it
--- over stdio.
---@param cmd string[] Command argv. The first element is the executable.
---@param opts? kak.ui.json_rpc.SpawnOptions
---@return kak.ui.json_rpc.Connection
function M.spawn(cmd, opts)
  assert(type(cmd) == 'table' and #cmd >= 1, 'cmd must be non-empty array')
  ---@cast opts -nil
  local resolved = opts or {}
  assert(type(resolved.dispatchers) == 'table', 'opts.dispatchers required')
  return Connection.new(
    Transport.spawn(cmd, { cwd = resolved.cwd, env = resolved.env }),
    resolved.dispatchers
  )
end

---@type fun(buf: string, chunk: string, on_message: fun(line: string)): string
M._ndjson_feed = ndjson_feed

return M
