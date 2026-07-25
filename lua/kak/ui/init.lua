---
--- The Kakoune JSON-UI plugin entry point.
---
--- Spawns `kak -ui json [...]` as a child process, opens an NDJSON
--- JSON-RPC connection over stdio, claims the current nvim window for
--- the render area, and wires Kakoune notifications to render / input
--- / popup handlers.
---
--- Layout: see `lua/kak/ui/ui_surface.lua` for the window lifecycle
--- and `lua/kak/ui/handlers.lua` for the notification dispatcher.
---
--- Multi-client model: each open() call spawns a fresh
--- `kak -ui json` process and a fresh Connection; sessions live in a
--- `SESSIONS` table keyed by their content buffer number. The
--- `current_session` slot tracks the most-recently-focused client and
--- gates statusbar cursor-move + autocmd-installed WinEnter focus
--- routing. Closing one session via `:q` terminates only that
--- session's child process; sibling clients are unaffected.

local json_rpc = require('kak.ui.json_rpc')
local surface_mod = require('kak.ui.ui_surface')
local handlers = require('kak.ui.handlers')
local input = require('kak.ui.input')
local log = require('kak.ui.log').log

---@alias kak.ui.OpenOpts { session?: string, cmd?: string[], extra_args?: string[], cwd?: string, env?: table<string, string> }

--- A Session owns the rpc + input bindings + close for one kak
--- client. Everything else (renderer, faces, popups, surface, handler
--- dispatch) lives on the per-session `kak.ui.Handlers` instance.
---@class kak.ui.Session
---@field id integer content buffer number
---@field conn kak.ui.json_rpc.Connection
---@field handlers kak.ui.Handlers
---@field surface kak.ui.surface.Surface
---@field input kak.ui.input.Handler
---@field augroup integer nvim augroup id
---@field closed boolean
---@field close fun(self: kak.ui.Session)

local M = {}

--- Registered sessions, keyed by content buffer number.
---@type table<integer, kak.ui.Session>
local SESSIONS = {}

--- The most recently focused session; updates from the WinEnter
--- autocmd installed in `open()` and from `:KakNewWin`.
---@type kak.ui.Session?
local current_session = nil

--- Locate the session that owns the content buffer `buf`, if any.
---@param buf integer
---@return kak.ui.Session?
function M.session_for_buf(buf)
  local session = SESSIONS[buf]
  if session and not session.closed then return session end
  return nil
end

---@return kak.ui.Session?
function M.current() return current_session end

--- Install `sess` as the current session. Safe to call from any
--- focus event; the registry is private so direct writes must go
--- through here. `nil` clears the slot (used by tests).
---@param sess kak.ui.Session?
function M.set_current(sess) current_session = sess end

--- Iterate every live session. Internal: only used by VimLeavePre.
---@return fun(): integer?, kak.ui.Session
function M._iter()
  local it = pairs(SESSIONS) --[[@as fun(): integer?, kak.ui.Session]]
  return it
end

---@param opts kak.ui.OpenOpts?
---@return kak.ui.Session
function M.open(opts)
  opts = require('kak.ui.windowing').inject_args(opts)
  local cmd = opts.cmd or { 'kak' }
  local session = opts.session

  local argv = {}
  for _, a in ipairs(cmd) do
    argv[#argv + 1] = a
  end
  argv[#argv + 1] = '-ui'
  argv[#argv + 1] = 'json'
  for _, a in ipairs(opts.extra_args or {}) do
    argv[#argv + 1] = a
  end
  if session then
    argv[#argv + 1] = '-c'
    argv[#argv + 1] = session
  end

  local ui_options = {}
  ---@type kak.ui.HandlerContext
  local ctx = { ui_options = ui_options, last_force = false }

  -- Surface claims the current nvim window and creates the scratch
  -- buffers before we spawn the child process, so handlers can attach
  -- the renderer to buffers that already have a home.
  local surface = surface_mod.new({ session = session })
  surface:open({ session = session })
  local content_bufnr = assert(surface.content_buf, 'Surface:open did not produce a content_buf')

  local h = handlers.new({
    ctx = ctx,
    ui_options = ui_options,
    surface = surface,
  })
  -- Back-reference so statusbar / close hooks can find the owning
  -- session without traversing a registry from inside the call chain.
  h.session = nil -- assigned after `sess` exists, see below

  local sess
  local function close_session()
    if not sess then return end
    sess:close()
  end

  local dispatchers = {
    on_notify = function(method, params)
      local fn = h[method]
      if fn then
        local ok, err = pcall(function() fn(h, params or {}) end)
        if not ok then log.warn('handler', method, 'error:', tostring(err)) end
      end
    end,
    -- Kakoune never sends inbound requests; this stub is required by
    -- the rpc dispatcher signature.
    on_request = function(method)
      return nil, { code = -32601, message = 'method not found: ' .. method }
    end,
    on_exit = function(code, signal)
      vim.schedule(
        function()
          vim.notify(
            'Kakoune exited (code=' .. tostring(code) .. ', signal=' .. tostring(signal) .. ')',
            vim.log.levels.INFO
          )
        end
      )
      close_session()
    end,
    on_error = function(code, err) log.warn('rpc error', code, vim.inspect(err)) end,
  }

  ---@type kak.ui.json_rpc.Connection
  local conn = json_rpc.spawn(argv, {
    dispatchers = dispatchers,
    cwd = opts.cwd,
    env = opts.env,
  })

  local input_handler = input.new({ rpc = conn, surface = surface })
  input_handler:enable()
  h.session = nil -- final assignment below

  vim.defer_fn(function()
    if not conn:is_closing() then input_handler:report_resize() end
  end, 50)

  ---@type kak.ui.Session
  sess = {
    id = content_bufnr,
    conn = conn,
    handlers = h,
    surface = surface,
    input = input_handler,
    augroup = 0,
    closed = false,
    close = function(self)
      if self.closed then return end
      -- Find a survivor BEFORE tearing down. When the closing
      -- session is the current one and other live sessions exist,
      -- we must switch `current_session` synchronously so the
      -- global on_key listener (which consults `current_session`
      -- for routing) immediately points at the survivor. Without
      -- this, the user sits in the dead window with no input
      -- routing. `M.set_current` is a Lua-var write -- safe even
      -- from an off-thread on_exit callback.
      ---@type kak.ui.Session?
      local survivor = nil
      if current_session == self then
        for _, s in pairs(SESSIONS) do
          if
            s ~= self
            and not s.closed
            and s.surface
            and s.surface.content_win
            and vim.api.nvim_win_is_valid(s.surface.content_win)
          then
            survivor = s
            break
          end
        end
        if survivor then M.set_current(survivor) end
      end
      self.closed = true
      if self.conn and not self.conn:is_closing() then self.conn:terminate() end
      if self.surface then
        self.surface.rpc = nil
        self.surface:close()
      end
      if self.input then self.input:disable() end
      pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
      SESSIONS[self.id] = nil
      -- Only clear `current_session` if it still refers to us. The
      -- survivor-switch above already replaced it, so this guard
      -- is what handles the no-survivor case.
      if current_session == self then current_session = nil end
      -- Focus move + dead-window removal are nvim API calls that
      -- may run from `on_exit` (off the main loop). The
      -- synchronous Lua-var write above already restored input
      -- routing; this schedule takes care of the visible focus so
      -- the user lands in the survivor's window, not the dead
      -- frozen frame.
      if survivor then
        vim.schedule(function()
          if
            survivor.surface
            and survivor.surface.content_win
            and vim.api.nvim_win_is_valid(survivor.surface.content_win)
          then
            pcall(vim.api.nvim_set_current_win, survivor.surface.content_win)
          end
        end)
      end
    end,
  }
  -- Now that `sess` exists, hook the handlers back to it so
  -- statusbar / input can find the session context.
  h.session = sess

  SESSIONS[content_bufnr] = sess

  -- Per-session autocmds: keep the registration scoped to the
  -- augroup so disabling/closing one session doesn't disturb others.
  local augroup =
    vim.api.nvim_create_augroup('KakUiSession' .. tostring(content_bufnr), { clear = true })
  sess.augroup = augroup

  vim.api.nvim_create_autocmd({ 'VimResized', 'WinResized' }, {
    group = augroup,
    buffer = content_bufnr,
    callback = function() input_handler:report_resize() end,
  })
  vim.api.nvim_create_autocmd({ 'BufWipeout', 'BufDelete' }, {
    group = augroup,
    buffer = content_bufnr,
    callback = function() sess:close() end,
  })
  vim.api.nvim_create_autocmd('WinClosed', {
    group = augroup,
    pattern = tostring(surface.content_win),
    callback = function() sess:close() end,
  })
  vim.api.nvim_create_autocmd('WinEnter', {
    group = augroup,
    buffer = content_bufnr,
    callback = function() M.set_current(sess) end,
  })

  M.set_current(sess)
  return sess
end

--- Close the given session (by `buf`/`Session` arg) or the current
--- session if no arg supplied.
---@param buf_or_sess? integer|kak.ui.Session
function M.close(buf_or_sess)
  if not buf_or_sess then
    if not current_session then return end
    current_session:close()
    return
  end
  if type(buf_or_sess) == 'table' then
    ---@cast buf_or_sess kak.ui.Session
    buf_or_sess:close()
    return
  end
  ---@cast buf_or_sess integer
  local s = SESSIONS[buf_or_sess]
  if s then s:close() end
end

-- Iterate every live session on shutdown so the kak-child processes
-- get a chance to terminate cleanly. VimLeavePre fires in reverse
-- insertion order, but iteration is independent of order here.
vim.api.nvim_create_autocmd('VimLeavePre', {
  group = vim.api.nvim_create_augroup('KakUiShutdown', { clear = true }),
  callback = function()
    for _, s in pairs(SESSIONS) do
      if s.conn then s.conn:terminate() end
    end
  end,
})

--- Back-compat alias for older tests that used `M.active()`.
---@return kak.ui.Session?
function M.active() return current_session end

return M
