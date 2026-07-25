---
--- Parses and dispatches Kakoune JSON-UI messages. Wire format matches
--- Kakoune master per doc/json_ui.asciidoc.
---
--- One JSON object per `\n`-terminated chunk. Params are positional arrays.

local M = {}

local NIL = vim.NIL or setmetatable({}, { __tostring = function() return 'vim.NIL' end })

-- Tolerate Lua `nil` and `vim.NIL` (what `vim.json.decode` returns for
-- JSON `null`); both mean "absent" on the wire.
local function absent(v) return v == nil or v == NIL end

local function expect_array(name, params, min)
  if absent(params) then error(name .. ': params must be array', 3) end
  if type(params) ~= 'table' then
    error(name .. ': params must be array, got ' .. type(params), 3)
  end
  if min and #params < min then error(name .. ': need ' .. min .. ' params, got ' .. #params, 3) end
  return params
end

local function parse_color(method, v)
  if absent(v) or v == 'default' then return nil end
  if type(v) ~= 'string' then error(method .. ': color must be string', 3) end
  if v:sub(1, 1) == '#' and #v == 7 then return v end
  if v:sub(1, 4) == 'rgb:' and #v == 10 then return '#' .. v:sub(5) end
  if v:sub(1, 5) == 'rgba:' and #v == 13 then return '#' .. v:sub(6, 11) end
  -- Named color or unknown; pass through and let the face mapper handle it.
  return v
end

local function parse_face(method, face, idx)
  if absent(face) then return nil end
  if type(face) ~= 'table' then
    error(method .. ': face @' .. tostring(idx) .. ' must be table', 3)
  end
  return {
    fg = parse_color(method, face.fg),
    bg = parse_color(method, face.bg),
    underline = parse_color(method, face.underline),
    attributes = (type(face.attributes) == 'table') and face.attributes or {},
  }
end

local function parse_coord(method, coord, idx)
  if absent(coord) or type(coord) ~= 'table' then
    error(method .. ': coord @' .. tostring(idx) .. ' missing', 3)
  end
  if type(coord.line) ~= 'number' or type(coord.column) ~= 'number' then
    error(method .. ': coord @' .. tostring(idx) .. ' missing line/column', 3)
  end
  return coord
end

local function parse_line(method, line, idx)
  if absent(line) or type(line) ~= 'table' then
    error(method .. ': line @' .. tostring(idx) .. ' must be array of atoms', 3)
  end
  local atoms = {}
  for i, atom in ipairs(line) do
    if absent(atom) or type(atom) ~= 'table' then
      error(method .. ': atom @' .. tostring(idx) .. '.' .. i .. ' must be table', 3)
    end
    atoms[i] = {
      face = parse_face(method, atom.face, idx .. '.' .. i),
      contents = atom.contents or '',
    }
  end
  return atoms
end

local function parse_lines(method, lines, idx)
  if absent(lines) or type(lines) ~= 'table' then
    error(method .. ': lines @' .. tostring(idx) .. ' must be array of lines', 3)
  end
  local out = {}
  for i, line in ipairs(lines) do
    out[i] = parse_line(method, line, idx .. '.' .. i)
  end
  return out
end

local function check_enum(method, val, valid, idx)
  if not valid[val] then
    error(method .. ': bad enum value ' .. tostring(val) .. ' @' .. tostring(idx), 3)
  end
  return val
end

local HANDLERS = {}

HANDLERS.draw = function(params)
  expect_array('draw', params, 5)
  return {
    lines = parse_lines('draw', params[1], 1),
    cursor_pos = parse_coord('draw', params[2], 2),
    default_face = parse_face('draw', params[3], 3),
    padding_face = parse_face('draw', params[4], 4),
    widget_columns = params[5],
  }
end

HANDLERS.draw_status = function(params)
  expect_array('draw_status', params, 6)
  local cursor = params[3]
  if absent(cursor) or type(cursor) ~= 'number' then
    error('draw_status: cursor_pos @3 must be integer', 3)
  end
  local valid = { command = true, search = true, prompt = true, status = true }
  return {
    prompt = parse_line('draw_status', params[1], 1),
    content = parse_line('draw_status', params[2], 2),
    cursor_pos = cursor,
    mode_line = parse_line('draw_status', params[4], 4),
    default_face = parse_face('draw_status', params[5], 5),
    style = check_enum('draw_status', params[6] or 'status', valid, 6),
  }
end

HANDLERS.menu_show = function(params)
  expect_array('menu_show', params, 5)
  return {
    items = parse_lines('menu_show', params[1], 1),
    anchor = parse_coord('menu_show', params[2], 2),
    fg = parse_face('menu_show', params[3], 3),
    bg = parse_face('menu_show', params[4], 4),
    style = check_enum('menu_show', params[5], { prompt = true, search = true, inline = true }, 5),
  }
end

HANDLERS.menu_select = function(params)
  expect_array('menu_select', params, 1)
  if type(params[1]) ~= 'number' then
    error('menu_select: expected int, got ' .. type(params[1]), 3)
  end
  return { selected = params[1] }
end

HANDLERS.menu_hide = function(params)
  if params and #params > 0 then error('menu_hide: expected no params', 3) end
  return {}
end

HANDLERS.info_show = function(params)
  expect_array('info_show', params, 5)
  return {
    title = parse_line('info_show', params[1], 1),
    content = parse_lines('info_show', params[2], 2),
    anchor = parse_coord('info_show', params[3], 3),
    face = parse_face('info_show', params[4], 4),
    style = check_enum('info_show', params[5], {
      prompt = true,
      inline = true,
      inlineAbove = true,
      inlineBelow = true,
      menuDoc = true,
      modal = true,
    }, 5),
  }
end

HANDLERS.info_hide = function(params)
  if params and #params > 0 then error('info_hide: expected no params', 3) end
  return {}
end

HANDLERS.refresh = function(params)
  expect_array('refresh', params, 1)
  if type(params[1]) ~= 'boolean' then error('refresh: expected bool', 3) end
  return { force = params[1] }
end

HANDLERS.set_ui_options = function(params)
  expect_array('set_ui_options', params, 1)
  if absent(params[1]) or type(params[1]) ~= 'table' then
    error('set_ui_options: expected object of key/value', 3)
  end
  return { options = params[1] }
end

--- Decode a single inbound JSON object into {method, params}.
function M.decode(message)
  if absent(message) or type(message) ~= 'table' then error('message must be object', 2) end
  if message.jsonrpc ~= '2.0' then
    error('unsupported jsonrpc version: ' .. tostring(message.jsonrpc), 2)
  end
  if type(message.method) ~= 'string' then error('message.method must be string', 2) end
  local fn = HANDLERS[message.method]
  if not fn then error('unknown method: ' .. message.method, 2) end
  return {
    method = message.method,
    params = fn(message.params or {}),
  }
end

--- Dispatch a parsed JSON-RPC inbound message to `handlers`.
function M.dispatch(message, handlers)
  local decoded
  local ok, err = pcall(function() decoded = M.decode(message) end)
  if not ok then
    io.stderr:write('[kak.ui.protocol] decode error: ', tostring(err), '\n')
    return
  end
  local h = handlers['on_' .. decoded.method] or handlers.on_default
  if not h then return end
  h(decoded.params)
end

--- Encode a UI -> Kakoune notification.
function M.encode_notify(method, params)
  assert(type(method) == 'string', 'method must be string')
  assert(type(params) == 'table', 'params must be array')
  return {
    jsonrpc = '2.0',
    method = method,
    params = params,
  }
end

M._parse_color = parse_color
return M
