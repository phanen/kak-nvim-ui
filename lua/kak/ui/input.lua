---
--- Captures keyboard + mouse input inside the Kakoune render buffer and
--- forwards it to Kakoune over the JSON-RPC connection.
---
--- `vim.on_key(fn, ns_id)` delivers raw bytes; we pipe them through
--- `vim.fn.keytrans()` to obtain `<...>` notation, then translate to
--- Kakoune's notation (`<esc>`, `<up>`, `<c-a>`, ...).
---
--- Mouse translation follows Kakoune's wire protocol directly:
--- `mouse_move`, `mouse_press`, `mouse_release`, `scroll`.
---
--- Multi-client model: one GLOBAL `vim.on_key` listener + one
--- GLOBAL `vim.paste` override, both reference-counted across all
--- `Handler` instances. Each enable bumps the refcount; each
--- disable decrements; the install / tear-down happens once at
--- refcount 0/1. The closure routes per-buffer via
--- `kak.ui.session_for_buf`. Each session still owns its own
--- per-buffer mouse keymaps (they are trivially scoped via
--- `vim.keymap.set`).
---

---@alias kak.ui.input.MouseButton 'left' | 'right' | 'middle'
---@alias kak.ui.input.MouseKind 'press' | 'release' | 'scroll' | 'move'
---@alias kak.ui.input.MousePos { line: integer, column: integer }

---@class kak.ui.input.Connection : kak.ui.json_rpc.Connection

local M = {}

local log = require('kak.ui.log').log

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

---@type table<string, string>
local MOD_PREFIX = { C = 'c-', A = 'a-', M = 'a-', S = 's-', D = 'd-' }

--- Translate one nvim key notation (`<C-A>`, `<Up>`, `i`, ...) to a
--- single Kakoune key string. Returns `nil` if the input is not usable.
---@param key string
---@return string?
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
    if #body == 0 then return nil end
  end

  local mapped = NVIM_BODY_TO_KAK[body] or body
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
---@param raw string?
---@return string[]
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
---@param raw string?
---@return string[]
function M.from_on_key(raw)
  if not raw or #raw == 0 then return {} end
  local ok, notation = pcall(vim.fn.keytrans, raw)
  if not ok or type(notation) ~= 'string' or #notation == 0 then return {} end
  return M.raw_to_kak(notation)
end

--- `vim.fn.getmousepos()` returns { line, column, screenrow, screencol, winid }.
---@return integer?, integer?
local function mouse_payload()
  local pos = vim.fn.getmousepos()
  if not pos or not pos.winid or pos.winid == 0 then return nil end
  return pos.line, pos.column
end

--- Module-level state for the PROCESS-GLOBAL `vim.on_key` listener.
--- A single namespace + callback serves every session; the closure
--- routes the current buffer to its owning session via
--- `session_for_current_buf`. `on_key_refcount` is bumped on each
--- `Handler:enable()` and decremented on each `Handler:disable()`;
--- the listener is only torn down when the refcount hits 0.
---@type integer?
local on_key_ns = nil
---@type (fun(_, typed: string): string?)?
local on_key_fn = nil
local on_key_installed = false
local on_key_refcount = 0

--- Module-level state for the PROCESS-GLOBAL `vim.paste` override.
--- Same refcount scheme: first enable captures `vim.paste` and
--- installs the routed override; last disable restores the original.
--- `paste_orig` keeps its natural `vim.paste` signature; a local
--- `paste_orig_fn` with the narrowed phase union is bound in
--- `Handler:enable()` so the override closure can call it.
local paste_orig = nil
local paste_installed = false
local paste_refcount = 0

---@class kak.ui.input.Handler
---@field rpc? kak.ui.input.Connection
---@field buf integer?
---@field enabled boolean
---@field surface? kak.ui.surface.Surface
---@field mouse_maps string[]
local Handler = {}
Handler.__index = Handler

---@param opts { rpc?: kak.ui.input.Connection, surface?: kak.ui.surface.Surface }
---@return kak.ui.input.Handler
function M.new(opts)
  return setmetatable({
    rpc = opts.rpc,
    surface = opts.surface,
    buf = nil,
    enabled = false,
    mouse_maps = {},
  }, Handler)
end

--- Map a mouse event LHS to (button, kind, scroll_dir).
---@param lhs string
---@return kak.ui.input.MouseButton?, kak.ui.input.MouseKind, integer?
local function mouse_event_to_btn(lhs)
  if lhs:find('LeftMouse') then return 'left', 'press' end
  if lhs:find('RightMouse') then return 'right', 'press' end
  if lhs:find('MiddleMouse') then return 'middle', 'press' end
  if lhs:find('Release') then return nil, 'release' end
  if lhs == '<ScrollWheelUp>' then return nil, 'scroll', -1 end
  if lhs == '<ScrollWheelDown>' then return nil, 'scroll', 1 end
  if lhs == '<ScrollWheelLeft>' then return nil, 'scroll', -1 end
  if lhs == '<ScrollWheelRight>' then return nil, 'scroll', 1 end
  return nil, 'move'
end

--- Locate the session that owns the given content buffer, falling
--- back to the current session. Returns `nil` if no session is live
--- or the owning session's rpc has been closed.
---@param buf integer
---@return kak.ui.Session?
local function session_for_current_buf(buf)
  local m = require('kak.ui')
  local sess = m.session_for_buf(buf) or m.current()
  if not sess or not sess.conn or sess.conn:is_closing() then return nil end
  return sess
end

--- Install the global on_key + paste + per-buffer mouse keymap hooks.
--- The on_key listener and the paste override are PROCESS-GLOBAL and
--- reference-counted, so multiple sessions share a single install.
function Handler:enable()
  if self.enabled then return end
  self.enabled = true

  -- `self.buf` is no longer owned exclusively by this handler (a
  -- window switch can move focus to a sibling session's content
  -- buffer), so we don't key the routing off it.
  local handler = self

  -- Install the global on_key listener ONCE per process and route
  -- every keypress to the session owning the current buffer. A
  -- second `Handler:enable()` only bumps the refcount.
  on_key_refcount = on_key_refcount + 1
  if not on_key_installed then
    on_key_ns = vim.api.nvim_create_namespace('kak.ui.input')
    on_key_fn = function(_, typed)
      -- Per |vim.on_key()|: `typed` is the pre-mapping bytes (what the
      -- user physically pressed). Fall back to nothing when empty.
      if type(typed) ~= 'string' or #typed == 0 then return '' end
      local cur = vim.api.nvim_get_current_buf()
      local sess = session_for_current_buf(cur)
      if not sess then
        -- ANTI-TRAP for the `:q` hang. `vim.system`'s `on_exit`
        -- fires only after stdout EOF (neovim #33627), so there is
        -- a window where the client process has already exited
        -- (`is_closing()` -> true, `session_for_current_buf` returns
        -- nil) but `on_exit` hasn't fired yet. During that gap the
        -- user is in a dead window with no live input routing --
        -- returning '' drops the key (the only legal on_key return;
        -- nvim throws "return string must be empty" otherwise), but
        -- the next keypress must still land somewhere sane. Detect
        -- the dead session from the still-resident SESSIONS entry
        -- (or `current()` if the buffer no longer belongs to a
        -- session) and schedule its close so `current_session`
        -- flips to a survivor synchronously via the Lua-var write
        -- in `Session:close` + the dead window is removed next
        -- tick. The user loses THIS keypress (it was going nowhere
        -- anyway), then the scheduled close fires, and the NEXT
        -- keypress routes to the survivor through the live on_key
        -- path. NOT trapped; the key is dropped not errored.
        local m = require('kak.ui')
        local dead = m.session_for_buf(cur)
        if not dead or dead.closed or not dead.conn or not dead.conn:is_closing() then
          local cur_sess = m.current()
          if cur_sess and not cur_sess.closed and cur_sess.conn and cur_sess.conn:is_closing() then
            dead = cur_sess
          else
            dead = nil
            for _, s in m._iter() do
              if not s.closed and s.conn and s.conn:is_closing() then
                dead = s
                break
              end
            end
          end
        end
        if dead and not dead.closed and dead.conn and dead.conn:is_closing() then
          log.debug('on_key: dead session, scheduling close + drop', {
            cur = cur,
            dead_id = dead.id,
          })
          local d = dead
          vim.schedule(function()
            pcall(function() d:close() end)
          end)
        end
        return ''
      end
      log.trace('on_key', {
        typed = typed:sub(1, 20),
        cur = cur,
        sess = sess.id,
        conn_closing = sess.conn and sess.conn:is_closing() or nil,
      })
      local keys = M.from_on_key(typed)
      if #keys > 0 then
        local ok, err = pcall(sess.conn.notify, sess.conn, 'keys', keys)
        if not ok then log.warn('keys notify error:', tostring(err)) end
      end
      -- Returning '' tells nvim to drop the key. Without this, nvim
      -- would also act on ESC, `:`, `/`, etc., causing double behavior.
      return ''
    end
    vim.on_key(on_key_fn, on_key_ns)
    on_key_installed = true
  end

  -- Mouse + scroll: dedicated keymap per button so each can read its
  -- own line/col via `vim.fn.getmousepos()`. The wire protocol uses
  -- dedicated `mouse_*` / `scroll` notifications, not `keys`.
  local function send_mouse_event(lhs)
    return function()
      -- nvim's default <LeftMouse> moves focus to the clicked window,
      -- but our buffer-local nowait keymap intercepts the click. Switch
      -- focus explicitly so clicking a sibling kak split routes input
      -- there (WinEnter -> set_current) before forwarding to kak.
      local pos = vim.fn.getmousepos()
      if pos and pos.winid and vim.api.nvim_win_is_valid(pos.winid) then
        if vim.api.nvim_get_current_win() ~= pos.winid then
          pcall(vim.api.nvim_set_current_win, pos.winid)
        end
      end
      local cur = vim.api.nvim_get_current_buf()
      local sess = session_for_current_buf(cur)
      if not sess then return end
      local line, col = mouse_payload()
      if not line or not col then return end
      local button, kind, scroll = mouse_event_to_btn(lhs)
      if kind == 'press' then
        sess.conn:notify('mouse_press', { button, line, col })
      elseif kind == 'release' then
        sess.conn:notify('mouse_release', { button, line, col })
      elseif kind == 'scroll' then
        sess.conn:notify('scroll', { scroll, line, col })
      elseif kind == 'move' then
        if button then sess.conn:notify('mouse_move', { line, col }) end
      end
    end
  end

  -- We install mouse keymaps in the content buffer once the surface
  -- has attached a window. `Surface:ensure_status_float` and friends
  -- all rely on `self.surface.content_buf`. Map on every call so a
  -- late-attaching surface still gets them.
  local function map(lhs, rhs)
    if not handler.surface or not handler.surface.content_buf then return end
    local buf = handler.surface.content_buf
    vim.keymap.set({ 'n', 'o', 'v', 'x' }, lhs, rhs, {
      buffer = buf,
      remap = false,
      silent = true,
      nowait = true,
    })
    handler.mouse_maps[#handler.mouse_maps + 1] = lhs
  end

  vim.o.mouse = 'a'

  ---@type string[]
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

  -- Paste hook: route `vim.paste` calls in the content buffer to
  -- this session's rpc. The hook is process-global; install it ONCE
  -- (first enable captures `vim.paste`, last disable restores it).
  -- The refcount ensures a sibling session's `:close()` doesn't
  -- clobber the override while others still rely on it.
  paste_refcount = paste_refcount + 1
  if not paste_installed then
    paste_orig = vim.paste
    ---@cast paste_orig fun(lines: string[], phase: -1|1|2|3): boolean
    local paste_orig_fn = paste_orig
    ---@param lines string[]
    ---@param phase -1|1|2|3
    ---@return boolean
    vim.paste = function(lines, phase)
      local cur = vim.api.nvim_get_current_buf()
      local sess = session_for_current_buf(cur)
      if not sess then return paste_orig_fn(lines, phase) end
      if phase == -1 or phase == 3 then
        for _, line in ipairs(lines) do
          pcall(sess.conn.notify, sess.conn, 'paste', { line })
        end
        return true
      end
      return paste_orig_fn(lines, phase)
    end
    paste_installed = true
  end
end

function Handler:disable()
  if not self.enabled then return end
  self.enabled = false

  -- on_key listener is process-global and refcounted; only the
  -- LAST enabled handler (refcount -> 0) tears it down.
  on_key_refcount = on_key_refcount - 1
  if on_key_refcount <= 0 then
    on_key_refcount = 0
    if on_key_ns and vim.on_key then vim.on_key(nil, on_key_ns) end
    on_key_ns = nil
    on_key_fn = nil
    on_key_installed = false
  end

  -- Same scheme for the paste override: only restore `vim.paste`
  -- once every handler has gone away, otherwise a sibling session's
  -- `disable()` would yank the override out from under it.
  paste_refcount = paste_refcount - 1
  if paste_refcount <= 0 then
    paste_refcount = 0
    if paste_orig then vim.paste = paste_orig end
    paste_orig = nil
    paste_installed = false
  end

  for _, lhs in ipairs(self.mouse_maps) do
    if self.surface and self.surface.content_buf then
      pcall(vim.keymap.del, { 'n', 'o', 'v', 'x' }, lhs, { buffer = self.surface.content_buf })
    end
  end
  self.mouse_maps = {}
end

--- Translate `vim.fn.getmousepos()`-like position to Kakoune draw
--- coordinates. Returns `nil` if the cursor is in a non-content window.
---@return integer?, integer?
function Handler.mouse_to_kak_coord() return mouse_payload() end

--- Report current nvim window dimensions to kakoune. The Surface
--- owns the resize logic (notify + reposition the status float).
function Handler:report_resize()
  if self.surface then
    self.surface:report_resize()
    return
  end
  if not self.surface or not self.surface.content_buf then return end
  local win = vim.fn.bufwinid(self.surface.content_buf)
  if not win or win == 0 then return end
  local rows = vim.api.nvim_win_get_height(win)
  local cols = vim.api.nvim_win_get_width(win)
  if self.rpc then pcall(self.rpc.notify, self.rpc, 'resize', { rows, cols }) end
end

M.nvim_to_kak_exposed = M.nvim_to_kak

--- Test-only handle on the module-level refcount state. Lets tests
--- assert that the global `vim.on_key` listener + `vim.paste`
--- override are installed exactly once even when several Handler
--- instances are enabled concurrently.
---@return { on_key_installed: boolean, on_key_refcount: integer, paste_installed: boolean, paste_refcount: integer }
function M._global_state()
  return {
    on_key_installed = on_key_installed,
    on_key_refcount = on_key_refcount,
    paste_installed = paste_installed,
    paste_refcount = paste_refcount,
  }
end

--- Test-only access to the (single, process-global) on_key
--- callback. Returns nil if no Handler has been enabled yet.
---@return (fun(_, typed: string): string?)?
function M._on_key_fn() return on_key_fn end

--- Test-only access to the cached original `vim.paste` (the
--- function we'd restore on the last `disable()`). Returns nil if
--- no Handler has captured it yet.
---@return (fun(lines: string[], phase: (-1|1|2|3)): boolean)?
function M._paste_orig() return paste_orig end

return M
