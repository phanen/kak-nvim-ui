---
--- Maps a Kakoune Face (fg / bg / underline / attributes) onto a nvim
--- highlight group registered via `nvim_set_hl`.
---
--- `underline` color maps to nvim `sp`. `final_*` / `blink` / `dim`
--- have no nvim analog and are dropped.

local M = {}

local HL_NS = vim.api.nvim_create_namespace('kak-ui-faces')

local NAMED_TO_HEX = {
  default = 'default',
  black = '#000000',
  red = '#cc0000',
  green = '#00cc00',
  yellow = '#cccc00',
  blue = '#3465a4',
  magenta = '#cc00cc',
  cyan = '#00cccc',
  white = '#cccccc',
}

local function color_to_hl(color)
  if color == nil then return 'NONE' end
  if NAMED_TO_HEX[color] then return NAMED_TO_HEX[color] end
  if color:match('^#%x%x%x%x%x%x$') then return color end
  if color:match('^rgba:') then
    local hex = color:match('rgba:(%x%x%x%x%x%x)')
    return hex and ('#' .. hex) or 'NONE'
  end
  return 'NONE'
end

local bit = require('bit')

M._attr_bit = {
  underline = bit.lshift(1, 0),
  curly_underline = bit.lshift(1, 1),
  double_underline = bit.lshift(1, 2),
  reverse = bit.lshift(1, 3),
  bold = bit.lshift(1, 4),
  italic = bit.lshift(1, 5),
  strikethrough = bit.lshift(1, 6),
  final_fg = bit.lshift(1, 7),
  final_bg = bit.lshift(1, 8),
  final_attr = bit.lshift(1, 9),
  blink = bit.lshift(1, 10),
  dim = bit.lshift(1, 11),
}

local UNDERLINE_BIT = bit.lshift(1, 0)
local CURLY_BIT = bit.lshift(1, 1)
local DOUBLE_BIT = bit.lshift(1, 2)
local REVERSE_BIT = bit.lshift(1, 3)
local BOLD_BIT = bit.lshift(1, 4)
local ITALIC_BIT = bit.lshift(1, 5)
local STRIKE_BIT = bit.lshift(1, 6)

local ATTR_NAMES = {}
for name, bit in pairs(M._attr_bit) do
  ATTR_NAMES[bit] = name
end
M._ATTR_NAMES = ATTR_NAMES

local function attrs_to_bits(attrs)
  if not attrs or #attrs == 0 then return 0 end
  local bits = 0
  local seen = {}
  for _, a in ipairs(attrs) do
    if not seen[a] then
      seen[a] = true
      bits = bit.bor(bits, M._attr_bit[a] or 0)
    end
  end
  return bits
end

-- FNV-1a-ish hash for short stable suffix.
local function fnv1a(key)
  local h = 2166136261
  for i = 1, #key do
    h = bit.band(bit.bxor(h, string.byte(key, i)) * 16777619, 0xffffffff)
  end
  return h
end

local function face_to_val(face, opts)
  opts = opts or {}
  local val = {}
  local fg = color_to_hl(face and face.fg)
  local bg = color_to_hl(face and face.bg)
  local underline = color_to_hl(face and face.underline)
  local bits = attrs_to_bits(face and face.attributes)
  if fg ~= 'NONE' then val.fg = fg end
  if bg ~= 'NONE' then val.bg = bg end
  if
    bit.band(bits, UNDERLINE_BIT) ~= 0
    or bit.band(bits, CURLY_BIT) ~= 0
    or bit.band(bits, DOUBLE_BIT) ~= 0
  then
    if underline ~= 'NONE' then val.sp = underline end
    if bit.band(bits, CURLY_BIT) ~= 0 then
      val.undercurl = true
    elseif bit.band(bits, DOUBLE_BIT) ~= 0 then
      val.underdouble = true
    else
      val.underline = true
    end
  end
  if bit.band(bits, REVERSE_BIT) ~= 0 then val.reverse = true end
  if bit.band(bits, BOLD_BIT) ~= 0 then val.bold = true end
  if bit.band(bits, ITALIC_BIT) ~= 0 then val.italic = true end
  if bit.band(bits, STRIKE_BIT) ~= 0 then val.strikethrough = true end
  if opts.default then val.default = true end
  return val
end

local function face_to_key(face)
  if not face then return 'd' end
  local fg = face.fg or '_'
  local bg = face.bg or '_'
  local ul = face.underline or '_'
  local attrs = face.attributes
  local attr_str = ''
  if attrs and #attrs > 0 then
    local sorted = {}
    for _, a in ipairs(attrs) do
      sorted[#sorted + 1] = a
    end
    table.sort(sorted)
    attr_str = table.concat(sorted, ',')
  end
  return table.concat({ fg, bg, ul, attr_str }, '|')
end

--- @class kak.ui.faces.Cache
local Cache = {}
Cache.__index = Cache

function M.new(opts)
  opts = opts or {}
  return setmetatable({
    cap = opts.cap or 512,
    by_key = {},
    lru = {},
    counter = 0,
  }, Cache)
end

--- Return highlight group name for a Face. Registers the group via
--- `nvim_set_hl` on cache miss. `nil` face returns the cache's default.
function Cache:get(face)
  local key = face_to_key(face)
  local entry = self.by_key[key]
  if entry then
    entry.tick = (self.lru.tick or 0) + 1
    self.lru.tick = entry.tick
    return entry.name
  end
  self.counter = self.counter + 1
  local name = face and string.format('KakFace_%08x', fnv1a(key)) or 'KakDefault'
  pcall(vim.api.nvim_set_hl, HL_NS, name, face_to_val(face, { default = (face == nil) }))
  entry = { name = name, key = key, tick = (self.lru.tick or 0) + 1 }
  self.by_key[key] = entry
  self.lru.tick = entry.tick
  if vim.tbl_count(self.by_key) > self.cap then self:_evict() end
  return name
end

function Cache:_evict()
  local victim_key, victim_tick
  for k, e in pairs(self.by_key) do
    if not victim_tick or e.tick < victim_tick then
      victim_key = k
      victim_tick = e.tick
    end
  end
  if victim_key then self.by_key[victim_key] = nil end
end

function Cache:size() return vim.tbl_count(self.by_key) end

M.face_to_key = face_to_key
M.face_to_val = face_to_val
M.color_to_hl = color_to_hl

return M
