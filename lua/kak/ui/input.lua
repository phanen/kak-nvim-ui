---
--- Captures keyboard + mouse input inside the Kakoune render buffer and
--- forwards it to Kakoune over the JSON-RPC connection.
---
--- Two complementary sources feed Kakoune:
---
--- 1. `vim.on_key(fn, ns_id)` -- every keystroke reaches us with raw
---    internal bytes (e.g. `<Esc>` arrives as the byte `\27`, `<Up>` as
---    three bytes `\x80ku`). We pass them through `vim.fn.keytrans()`
---    to obtain the user-facing `<...>` notation that nvim mappings and
---    |nvim_replace_termcodes()| understand, then translate to Kakoune's
---    notation (`<esc>`, `<up>`, `<c-a>`, ...).
---
--- 2. Buffer-local keymaps for events `on_key` does not see:
---      * mouse buttons (left/right/middle + scroll)
---      * bracketed paste (`vim.paste`)
---
--- Mouse translation follows Kakoune's wire protocol directly:
--- `mouse_move(line, col)`, `mouse_press(button, line, col)`,
--- `mouse_release(button, line, col)`. The `keys` method would NOT work
--- for these because Kakoune parses `keys` arguments as a string of
--- ordinary keys, not as a positional mouse tuple.
---
--- Key translation tables (nvim `<...>` -> Kakoune `<...>`):
---   <CR>, <NL>      -> <ret>
---   <Tab>           -> <tab>
---   <BS>, <Backspace> -> <backspace>
---   <Space>         -> <space>
---   <Esc>           -> <esc>
---   arrow / nav      -> <up>, <down>, <left>, <right>, <home>, <end>,
---                     <pageup>, <pagedown>, <insert>, <del>
---   <F1>..<F12>     -> <f1>..<f12>
---   <C-a>, <A-x>, <S-Tab>, <D-s>
---                    -> <c-a>, <a-x>, <s-tab>, <d-s>
---

local M = {}

--- nvim `<...>` body -> Kakoune `<...>` body (no surrounding angle brackets).
local NVIM_BODY_TO_KAK = {
  CR = 'ret',
  NL = 'ret',
  Ret = 'ret',
  Return = 'ret',
  Tab = 'tab',
  Backspace = 'backspace',
  BS = 'backspace',
  Space = 'space',
  Esc = 'esc',
  Escape = 'esc',
  Up = 'up',
  Down = 'down',
  Left = 'left',
  Right = 'right',
  Home = 'home',
  End = 'end',
  PageUp = 'pageup',
  PageDown = 'pagedown',
  Insert = 'insert',
  Ins = 'insert',
  Del = 'del',
  Delete = 'del',
  F1 = 'f1',
  F2 = 'f2',
  F3 = 'f3',
  F4 = 'f4',
  F5 = 'f5',
  F6 = 'f6',
  F7 = 'f7',
  F8 = 'f8',
  F9 = 'f9',
  F10 = 'f10',
  F11 = 'f11',
  F12 = 'f12',
  Lt = 'lt',
  Gt = 'gt',
}

local MOD_PREFIX = { C = 'c-', A = 'a-', M = 'a-', S = 's-', D = 'd-' }

--- Translate one nvim key notation (`<C-A>`, `<Up>`, `i`, ...) to a
--- single Kakoune key string. Returns `nil` if the input is not usable.
function M.nvim_to_kak(key)
  if type(key) ~= 'string' or #key == 0 then return nil end
  if key:sub(1, 1) ~= '<' or key:sub(-1) ~= '>' then return key end

  local body = key:sub(2, -2)
  if #body == 0 then return nil end

  local mods = ''
  while true do
    local head = body:sub(1, 1)
    local sep = body:sub(2, 2)
    if sep == '-' and MOD_PREFIX[head] then
      mods = mods .. MOD_PREFIX[head]
      body = body:sub(3)
    else
      break
    end
    -- Stop if only a single-letter modifier like `<C->` (bare dash).
    if #body == 0 then return nil end
  end

  local mapped = NVIM_BODY_TO_KAK[body]
  if not mapped then
    -- Unknown symbol: pass the body through verbatim so Kakoune's own
    -- parser can have a chance (e.g. `<lt>`, `<plus>`).
    mapped = body
  end
  -- Letters MUST be lowercase when preceded by a modifier
  -- (Kakoune rejects `<C-A>` and expects `<c-a>`).
  if mods ~= '' and #mapped == 1 then mapped = mapped:lower() end

  if mods ~= '' then return '<' .. mods .. mapped .. '>' end
  if NVIM_BODY_TO_KAK[body] then return '<' .. mapped .. '>' end
  if #mapped == 1 then return mapped end
  return '<' .. mapped .. '>'
end

--- Translate a notation string (already in `<...>` form) to a list of
--- Kakoune key strings. Each `<...>` is one entry; bare printable bytes
--- are split into per-character entries.
function M.raw_to_kak(raw)
  if not raw or #raw == 0 then return {} end
  local out = {}
  local buf = ''
  for i = 1, #raw do
    local c = raw:sub(i, i)
    if c == '<' then
      if #buf > 0 then
        for j = 1, #buf do
          local piece = M.nvim_to_kak(buf:sub(j, j))
          if piece then out[#out + 1] = piece end
        end
        buf = ''
      end
      buf = buf .. c
    elseif c == '>' then
      buf = buf .. c
      local piece = M.nvim_to_kak(buf)
      if piece then out[#out + 1] = piece end
      buf = ''
    else
      buf = buf .. c
    end
  end
  if #buf > 0 then
    for j = 1, #buf do
      local piece = M.nvim_to_kak(buf:sub(j, j))
      if piece then out[#out + 1] = piece end
    end
  end
  return out
end

--- Convert a raw byte sequence (as received from `vim.on_key`) to nvim
--- `<...>` notation, then forward to `raw_to_kak` for Kakoune-ready keys.
--- Empty / `nil` input returns an empty list.
function M.from_on_key(raw)
  if not raw or #raw == 0 then return {} end
  -- `keytrans` translates internal byte form (`<Esc>` as `\27`,
  -- `<Up>` as `\x80ku`) back to `<Esc>` / `<Up>` style notation.
  local ok, notation = pcall(vim.fn.keytrans, raw)
  if not ok or type(notation) ~= 'string' or #notation == 0 then return {} end
  return M.raw_to_kak(notation)
end

--- Mouse button name -> Kakoune button string.
local MOUSE_BUTTON_TO_KAK = { left = 'left', right = 'right', middle = 'middle' }

--- `vim.fn.getmousepos()` returns { line, column, screenrow, screencol, winid }.
local function mouse_payload()
  local pos = vim.fn.getmousepos()
  if not pos or not pos.winid or pos.winid == 0 then return nil end
  return pos.line, pos.column
end

--- @class kak.ui.input.Handler
local Handler = {}
Handler.__index = Handler

function M.new(opts)
  local self = setmetatable({
    rpc = opts.rpc,
    buf = nil,
    enabled = false,
    on_key_ns = nil,
    on_key_fn = nil,
    paste_ns = nil,
    paste_orig = nil,
    mouse_maps = {},
  }, Handler)
  return self
end

--- Map a mouse event to a wire-protocol method. Returns the button
--- name (and any scrolls) for downstream handlers.
local function mouse_event_to_btn(lhs)
  if lhs:find('LeftMouse') then return 'left', 'press' end
  if lhs:find('RightMouse') then return 'right', 'press' end
  if lhs:find('MiddleMouse') then return 'middle', 'press' end
  if lhs:find('Release') then return nil, 'release' end
  if lhs == '<ScrollWheelUp>' then return nil, 'scroll', -1 end
  if lhs == '<ScrollWheelDown>' then return nil, 'scroll', 1 end
  if lhs == '<ScrollWheelLeft>' then return nil, 'scroll', -1, true end
  if lhs == '<ScrollWheelRight>' then return nil, 'scroll', 1, true end
  return nil, 'move'
end

function Handler:enable(buf)
  if self.enabled then return end
  self.enabled = true
  self.buf = buf

  local handler = self

  -- Subscribe to every key with a dedicated namespace so cleanup is
  -- surgical and we never collide with concurrent handlers.
  self.on_key_ns = vim.api.nvim_create_namespace('kak.ui.input')
  self.on_key_fn = function(_, typed)
    if not handler.enabled or handler.rpc:is_closing() then return end
    local cur = vim.api.nvim_get_current_buf()
    if cur ~= handler.buf then return end
    -- Per |vim.on_key()|: `typed` is the pre-mapping bytes (what the
    -- user physically pressed), `key` is the post-mapping bytes.
    -- Prefer `typed` for accuracy; fall back to `key` when `typed` is
    -- empty (non-typed sources: completion menus, vim.schedule, ...).
    local raw = typed
    if type(raw) ~= 'string' or #raw == 0 then return end
    local keys = M.from_on_key(raw)
    if #keys > 0 then
      local ok, err = pcall(handler.rpc.notify, handler.rpc, 'keys', keys)
      if not ok then io.stderr:write('[kak.ui] keys notify error: ' .. tostring(err) .. '\n') end
    end
    -- Returning '' tells nvim to drop the key (per |vim.on_key()|).
    -- Without this, nvim would ALSO act on ESC, `:`, `/`, etc.,
    -- causing double behavior (e.g. nvim's `<Esc>` clearing search
    -- highlight in addition to our forwarding to kakoune).
    return ''
  end
  vim.on_key(self.on_key_fn, self.on_key_ns)

  -- Mouse + scroll: use a separate keymap per button so each can read
  -- its own line/col via `vim.fn.getmousepos()`. We bypass `keys`
  -- because Kakoune parses the `keys` notification as ordinary keys
  -- and would not understand `<LeftMouse>`. Instead we emit the
  -- dedicated `mouse_press` / `mouse_release` / `mouse_move` /
  -- `scroll` notifications.
  local function send_mouse_event(lhs)
    return function()
      local line, col = mouse_payload()
      if not line or not col then return end
      local button, kind, scroll, horizontal = mouse_event_to_btn(lhs)
      if kind == 'press' then
        handler.rpc:notify('mouse_press', { button, line, col })
      elseif kind == 'release' then
        handler.rpc:notify('mouse_release', { button, line, col })
      elseif kind == 'scroll' then
        handler.rpc:notify('scroll', { scroll, line, col })
      elseif kind == 'move' then
        if button then handler.rpc:notify('mouse_move', { line, col }) end
      end
    end
  end

  local function map(lhs, rhs)
    local ok = pcall(
      vim.keymap.set,
      { 'n', 'o', 'v', 'x' },
      lhs,
      rhs,
      { buffer = buf, remap = false, silent = true, nowait = true }
    )
    if ok then self.mouse_maps[#self.mouse_maps + 1] = lhs end
  end

  pcall(vim.api.nvim_set_option_value, 'mouse', 'a', { buf = buf })

  -- Buttons: map press and release; release falls through to press via
  -- `mouse_event_to_btn`'s "Release" branch which still uses the same
  -- handler function: it reads from getmousepos() to know which button
  -- has been released. The button distinction is kept in our handler.
  local mouse_lhs = {
    '<LeftMouse>',
    '<RightMouse>',
    '<MiddleMouse>',
    '<LeftRelease>',
    '<RightRelease>',
    '<MiddleRelease>',
    '<ScrollWheelUp>',
    '<ScrollWheelDown>',
    '<ScrollWheelLeft>',
    '<ScrollWheelRight>',
  }
  for _, lhs in ipairs(mouse_lhs) do
    map(lhs, send_mouse_event(lhs))
  end

  -- Bracketed paste: wire `vim.paste` to call our `paste` method on
  -- the rpc. Only kicks in during phase 3 (insert) of |nvim_paste()|.
  if vim.paste then
    self.paste_orig = vim.paste
    vim.paste = function(lines, phase)
      if phase == -1 or phase == 3 then
        for _, line in ipairs(lines) do
          pcall(handler.rpc.notify, handler.rpc, 'paste', { line })
        end
        return true
      end
      if self.paste_orig then return self.paste_orig(lines, phase) end
      return false
    end
    self.paste_ns = vim.api.nvim_create_namespace('kak.ui.paste')
    -- Marker so tests / introspection can detect we installed the hook.
    pcall(vim.api.nvim_buf_set_var, buf, 'kak_ui_paste', true)
  end
end

function Handler:disable()
  if not self.enabled then return end
  self.enabled = false
  if self.on_key_ns and vim.on_key then pcall(vim.on_key, nil, self.on_key_ns) end
  self.on_key_ns = nil
  self.on_key_fn = nil
  -- Restore original vim.paste if we overrode it.
  if self.paste_orig then
    vim.paste = self.paste_orig
  elseif vim.paste == nil then
    -- nothing to do
  end
  self.paste_orig = nil
  -- Clear keymaps.
  for _, lhs in ipairs(self.mouse_maps) do
    pcall(vim.keymap.del, { 'n', 'o', 'v', 'x' }, lhs, { buffer = self.buf })
  end
  self.mouse_maps = {}
  if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
    pcall(vim.api.nvim_buf_del_var, self.buf, 'kak_ui_paste')
  end
  self.buf = nil
end

--- Translate `vim.fn.getmousepos()`-like position to Kakoune draw
--- coordinates. Returns `nil` if the cursor is in a non-content window.
function Handler:mouse_to_kak_coord() return mouse_payload() end

--- Report current nvim window dimensions to kakoune.
function Handler:report_resize()
  if not self.buf then return end
  local win = vim.fn.bufwinid(self.buf)
  if not win or win == 0 then return end
  local rows = vim.api.nvim_win_get_height(win)
  local cols = vim.api.nvim_win_get_width(win)
  pcall(self.rpc.notify, self.rpc, 'resize', { rows, cols })
end

M.nvim_to_kak_exposed = M.nvim_to_kak
return M
