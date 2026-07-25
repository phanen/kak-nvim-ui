---
--- Wire-format primitives for Kakoune JSON-UI messages.
---
--- `vim.json.decode` already produces Lua tables; this module just
--- normalizes faces / coords / enums and tolerates `vim.NIL`. The
--- per-method notification dispatch lives in `kak.ui.handlers` --
--- this module has no HANDLERS table of its own.

---@alias kak.ui.protocol.AtomFace kak.ui.faces.Face
---@alias kak.ui.protocol.Atom { face: kak.ui.protocol.AtomFace?, contents: string }
---@alias kak.ui.protocol.Line kak.ui.protocol.Atom[]
---@alias kak.ui.protocol.Lines kak.ui.protocol.Line[]
---@alias kak.ui.protocol.Coord { line: integer, column: integer }
---@alias kak.ui.protocol.DrawStyle 'command' | 'search' | 'prompt' | 'status'
---@alias kak.ui.protocol.MenuStyle 'prompt' | 'search' | 'inline'
---@alias kak.ui.protocol.InfoStyle
---| 'prompt'
---| 'inline'
---| 'inlineAbove'
---| 'inlineBelow'
---| 'menuDoc'
---| 'modal'

local M = {}

local NIL = vim.NIL or setmetatable({}, { __tostring = function() return 'vim.NIL' end })

--- Tolerate Lua `nil` and `vim.NIL` (what `vim.json.decode` returns for
--- JSON `null`); both mean "absent" on the wire.
---@param v any
---@return boolean
function M.absent(v) return v == nil or v == NIL end

---@param name string
---@param params any?
---@param min integer?
---@return table
function M.expect_array(name, params, min)
  if M.absent(params) then error(name .. ': params must be array', 3) end
  if type(params) ~= 'table' then
    error(name .. ': params must be array, got ' .. type(params), 3)
  end
  if min and #params < min then error(name .. ': need ' .. min .. ' params, got ' .. #params, 3) end
  return params
end

---@param method string
---@param v any
---@return string?
function M.parse_color(method, v)
  if M.absent(v) or v == 'default' then return nil end
  if type(v) ~= 'string' then error(method .. ': color must be string', 3) end
  if v:sub(1, 1) == '#' and #v == 7 then return v end
  if v:sub(1, 4) == 'rgb:' and #v == 10 then return '#' .. v:sub(5) end
  if v:sub(1, 5) == 'rgba:' and #v == 13 then return '#' .. v:sub(6, 11) end
  return v
end

---@param method string
---@param face any
---@param idx any
---@return kak.ui.faces.Face?
function M.parse_face(method, face, idx)
  if M.absent(face) then return nil end
  if type(face) ~= 'table' then
    error(method .. ': face @' .. tostring(idx) .. ' must be table', 3)
  end
  return {
    fg = M.parse_color(method, face.fg),
    bg = M.parse_color(method, face.bg),
    underline = M.parse_color(method, face.underline),
    attributes = (type(face.attributes) == 'table') and face.attributes or {},
  }
end

---@param method string
---@param coord any
---@param idx any
---@return kak.ui.protocol.Coord
function M.parse_coord(method, coord, idx)
  if M.absent(coord) or type(coord) ~= 'table' then
    error(method .. ': coord @' .. tostring(idx) .. ' missing', 3)
  end
  if type(coord.line) ~= 'number' or type(coord.column) ~= 'number' then
    error(method .. ': coord @' .. tostring(idx) .. ' missing line/column', 3)
  end
  return coord
end

---@param method string
---@param line any
---@param idx any
---@return kak.ui.protocol.Line
function M.parse_line(method, line, idx)
  if M.absent(line) or type(line) ~= 'table' then
    error(method .. ': line @' .. tostring(idx) .. ' must be array of atoms', 3)
  end
  local atoms = {}
  for i, atom in ipairs(line) do
    if M.absent(atom) or type(atom) ~= 'table' then
      error(method .. ': atom @' .. tostring(idx) .. '.' .. i .. ' must be table', 3)
    end
    atoms[i] = {
      face = M.parse_face(method, atom.face, idx .. '.' .. i),
      contents = atom.contents or '',
    }
  end
  return atoms
end

---@param method string
---@param lines any
---@param idx any
---@return kak.ui.protocol.Lines
function M.parse_lines(method, lines, idx)
  if M.absent(lines) or type(lines) ~= 'table' then
    error(method .. ': lines @' .. tostring(idx) .. ' must be array of lines', 3)
  end
  local out = {}
  for i, line in ipairs(lines) do
    out[i] = M.parse_line(method, line, idx .. '.' .. i)
  end
  return out
end

---@param method string
---@param val any
---@param valid table<string, boolean>
---@param idx any
---@return string
function M.check_enum(method, val, valid, idx)
  if not valid[val] then
    error(method .. ': bad enum value ' .. tostring(val) .. ' @' .. tostring(idx), 3)
  end
  return val
end

--- Encode a UI -> Kakoune notification.
---@param method string
---@param params any[]
---@return { jsonrpc: string, method: string, params: any[] }
function M.encode_notify(method, params)
  assert(type(method) == 'string', 'method must be string')
  assert(type(params) == 'table', 'params must be array')
  return {
    jsonrpc = '2.0',
    method = method,
    params = params,
  }
end

return M
