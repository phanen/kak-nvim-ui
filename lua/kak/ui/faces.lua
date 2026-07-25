---
--- Maps a Kakoune Face (fg / bg / underline / attributes) onto a nvim
--- highlight group registered via `nvim_set_hl`.
---
--- `underline` color maps to nvim `sp`. `final_*` / `blink` / `dim`
--- have no nvim analog and are dropped.

---@alias kak.ui.faces.Color string

---@class kak.ui.faces.Face
---@field fg kak.ui.faces.Color?
---@field bg kak.ui.faces.Color?
---@field underline kak.ui.faces.Color?
---@field attributes string[]?

---@class kak.ui.faces.CacheEntry
---@field name string
---@field key string
---@field tick integer

---@class kak.ui.faces.LRU
---@field tick integer?

local M = {}

---@type table<string, string>
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

---@type table<string, integer>
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

---@type table<integer, string>
local ATTR_NAMES = {}
for name, attr_bit in pairs(M._attr_bit) do
  ATTR_NAMES[attr_bit] = name
end
M._ATTR_NAMES = ATTR_NAMES

---@param attrs string[]?
---@return integer
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
---@param key string
---@return integer
local function fnv1a(key)
  local h = 2166136261
  for i = 1, #key do
    h = bit.band(bit.bxor(h, string.byte(key, i)) * 16777619, 0xffffffff)
  end
  return h
end

---@param face kak.ui.faces.Face?
---@param opts? { default?: boolean }
---@return table
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

---@param face kak.ui.faces.Face?
---@return string
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

local function attr_contains(attrs, name)
  if not attrs then return false end
  for _, a in ipairs(attrs) do
    if a == name then return true end
  end
  return false
end

--- Union of two attribute lists with stable dedup and sort. Mirrors
--- Kakoune's `merge_faces` attribute semantics for the common case.
---@param a string[]?
---@param b string[]?
---@return string[]
local function union_attrs(a, b)
  local set = {}
  for _, x in ipairs(a or {}) do
    set[x] = true
  end
  for _, x in ipairs(b or {}) do
    set[x] = true
  end
  local out = {}
  for k in pairs(set) do
    out[#out + 1] = k
  end
  table.sort(out)
  return out
end

--- Lua port of Kakoune's `merge_faces(base, face)` from `face.hh`. The
--- JSON UI sends atoms with raw faces and a separate line base (e.g.
--- menu `bg`/`fg`); the terminal UI merges these on render. We do the
--- same so per-atom highlights survive inside popups.
---@param base kak.ui.faces.Face?
---@param face kak.ui.faces.Face?
---@return kak.ui.faces.Face?
function M.merge(base, face)
  if not base then return face end
  if not face then return base end
  local function norm(v)
    if v == nil or v == 'default' then return nil end
    return v
  end
  base = {
    fg = norm(base.fg),
    bg = norm(base.bg),
    underline = norm(base.underline),
    attributes = base.attributes,
  }
  face = {
    fg = norm(face.fg),
    bg = norm(face.bg),
    underline = norm(face.underline),
    attributes = face.attributes,
  }
  local base_attrs = base.attributes or {}
  local face_attrs = face.attributes or {}
  local function choose(getter, final_name)
    local fv = getter(face)
    local bv = getter(base)
    local face_final = attr_contains(face_attrs, final_name)
    local base_final = attr_contains(base_attrs, final_name)
    if face_final then return fv end
    if base_final then return bv end
    if fv == nil then return bv end
    return fv
  end
  local attrs
  if attr_contains(face_attrs, 'final_attr') then
    -- face wins; only base's final_* flags survive alongside face attrs.
    local finals = {}
    for _, a in ipairs(base_attrs) do
      if a == 'final_fg' or a == 'final_bg' or a == 'final_attr' then finals[#finals + 1] = a end
    end
    attrs = union_attrs(face_attrs, finals)
  elseif attr_contains(base_attrs, 'final_attr') then
    -- base wins; face attrs are dropped.
    attrs = {}
    for _, a in ipairs(base_attrs) do
      attrs[#attrs + 1] = a
    end
  else
    attrs = union_attrs(base_attrs, face_attrs)
  end
  return {
    fg = choose(function(f) return f.fg end, 'final_fg'),
    bg = choose(function(f) return f.bg end, 'final_bg'),
    -- underline uses the simple "face wins if not default" rule because
    -- Kakoune passes Attribute{0} for the final-check on underline.
    underline = (face.underline ~= nil) and face.underline or base.underline,
    attributes = attrs,
  }
end

---@class kak.ui.faces.Cache
---@field cap integer
---@field counter integer
---@field by_key table<string, kak.ui.faces.CacheEntry>
---@field lru kak.ui.faces.LRU
local Cache = {}
Cache.__index = Cache

---@param opts? { cap?: integer }
---@return kak.ui.faces.Cache
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
---@param face kak.ui.faces.Face?
---@return string
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
  pcall(vim.api.nvim_set_hl, 0, name, face_to_val(face, { default = (face == nil) }))
  self.by_key[key] = {
    name = name,
    key = key,
    tick = (self.lru.tick or 0) + 1,
  }
  self.lru.tick = self.by_key[key].tick
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

---@type fun(face: kak.ui.faces.Face?): string
M.face_to_key = face_to_key
---@type fun(face: kak.ui.faces.Face?, opts?: { default?: boolean }): table
M.face_to_val = face_to_val
---@type fun(color: string?): string
M.color_to_hl = color_to_hl

return M
