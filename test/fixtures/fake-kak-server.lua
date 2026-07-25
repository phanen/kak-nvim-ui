-- Fake kakoune JSON-RPC peer for tests. Run via:
--
--   nvim -l test/fixtures/fake-kak-server.lua <spec.lua>
--
-- The spec is a small Lua file that uses the global `fake` to drive
-- the wire. The API mirrors the helpers in
-- test/functional/plugin/lsp/testutil.lua fixtures, adapted to our
-- NDJSON framing (no Content-Length). Lua tables are JSON-encoded
-- directly, so test specs stay readable.
--
--   fake.notify(method, params)         -- emit notification
--   fake.respond(id, err, result)       -- emit response
--   fake.expect_notify(method, params)  -- read + assert notification
--   fake.expect_request(method, fn)     -- read request, run fn(params)
--                                          returning err, result, respond
--   fake.recv()                         -- read next message, no asserts
--   fake.sleep(ms)                      -- block; lets timers race
--   fake.exit(code)                     -- terminate the peer (default 0)
--
-- $FAKE_KAK_WIRE_LOG, when set, gets every inbound/outbound message
-- appended as `DIR<TAB><json>\n` for offline inspection.

if not vim.json or not vim.uv then
  io.stderr:write('fake-kak-server: requires nvim 0.10+ (vim.json + vim.uv)\n')
  os.exit(2)
end

local M = {}

local wire_log = os.getenv('FAKE_KAK_WIRE_LOG')

local function log_wire(dir, msg)
  if not wire_log then return end
  local f = assert(io.open(wire_log, 'a'))
  f:write(dir .. '\t' .. vim.json.encode(msg) .. '\n')
  f:close()
end

local function send(msg)
  io.stdout:write(vim.json.encode(msg) .. '\n')
  io.stdout:flush()
  log_wire('->', msg)
end

local stdin_buf = ''

local function read_line()
  while stdin_buf:find('\n', 1, true) == nil do
    local chunk = io.read(4096)
    if not chunk or #chunk == 0 then
      if #stdin_buf == 0 then return nil end
      local line = stdin_buf
      stdin_buf = ''
      return line
    end
    stdin_buf = stdin_buf .. chunk
  end
  local nl = stdin_buf:find('\n', 1, true)
  local line = stdin_buf:sub(1, nl - 1)
  stdin_buf = stdin_buf:sub(nl + 1)
  if line:sub(-1) == '\r' then line = line:sub(1, -2) end
  return line
end

local function recv()
  while true do
    local line = read_line()
    if line == nil then return nil end
    if #line > 0 then
      local msg = vim.json.decode(line)
      log_wire('<-', msg)
      return msg
    end
  end
end

function M.notify(method, params)
  assert(type(method) == 'string', 'notify: method must be string')
  send({ jsonrpc = '2.0', method = method, params = params or {} })
end

function M.respond(id, err, result)
  assert(type(id) == 'number', 'respond: id must be number')
  send({ jsonrpc = '2.0', id = id, error = err, result = result })
end

function M.expect_notify(method, params)
  local msg = recv()
  assert(msg, 'expect_notify: peer closed before ' .. method)
  assert(
    msg.method == method,
    ('expect_notify: got method=%s want %q'):format(vim.inspect(msg.method), method)
  )
  if params ~= nil then
    assert(
      vim.deep_equal(msg.params, params),
      ('expect_notify %q: params mismatch\nwant: %s\ngot:  %s'):format(
        method,
        vim.inspect(params),
        vim.inspect(msg.params)
      )
    )
  end
  return msg
end

function M.expect_request(method, handler)
  assert(type(handler) == 'function', 'expect_request: handler must be function')
  local msg = recv()
  assert(msg, 'expect_request: peer closed before ' .. method)
  assert(
    msg.method == method and type(msg.id) == 'number',
    ('expect_request: got %s'):format(vim.inspect(msg))
  )
  local err, result = handler(msg.params)
  M.respond(msg.id, err, result)
  return msg
end

function M.recv() return recv() end

function M.sleep(ms) vim.uv.sleep(ms or 0) end

function M.exit(code)
  io.stdout:flush()
  os.exit(code or 0)
end

local spec_path = arg and arg[1]
if not spec_path then
  io.stderr:write('fake-kak-server: usage: nvim -l <fixture> <spec.lua>\n')
  os.exit(2)
end

local chunk, err = loadfile(spec_path)
if not chunk then
  io.stderr:write('fake-kak-server: loadfile failed: ' .. tostring(err) .. '\n')
  os.exit(1)
end

_G.fake = M
local ok, run_err = pcall(chunk)
if not ok then
  io.stderr:write('fake-kak-server: spec failed: ' .. tostring(run_err) .. '\n')
  os.exit(1)
end
