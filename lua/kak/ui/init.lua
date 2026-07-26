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

--- Daemon processes, keyed by kakoune session name. One daemon per
--- unique `<session>` argument; closing the last client for a given
--- session kills its daemon. The tracked value is the `vim.SystemObj`
--- returned by `vim.system` when we spawned `kak -d -s <name>` --
--- either the daemon itself (when we just created it) or a thin
--- `kak -d` client process that connected to an existing daemon
--- (when the session name was already in use).
---@type table<string, vim.SystemObj>
local DAEMONS = {}

--- Monotonically increasing counter for `gen_session`. Avoids the
--- same-second collision window when `vim.fn.getpid()` would otherwise
--- be the only differentiator.
---@type integer
local SEQ = 0

--- The most recently focused session; updates from the WinEnter
--- autocmd installed in `open()` and from `:KakNewWin`.
---@type kak.ui.Session?
local current_session = nil

-- Saved user `timeoutlen` so the kak content window can run with
-- `timeoutlen=0` (see the WinEnter/WinLeave autocmds in `open()`).
-- `timeoutlen` is a GLOBAL option (no buffer-local scope), so we
-- toggle it while a kak window is focused + restore on leave. Keys
-- like `g`, `s`, `<c-w>` are nvim mapping prefixes; with the default
-- `timeoutlen` (1000ms) nvim blocks in a mapping-wait before the
-- `vim.on_key` callback even fires, so the typed char reaches kakoune
-- only after the timeout -- perceived as `:s`/`:g` cmdline lag.
---@type integer?
local saved_timeoutlen = nil

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
--- Returns the 3-tuple `(iter, state, init)` from `pairs(SESSIONS)` so
--- `for _, s in m._iter() do ... end` works -- a plain `return it`
--- would only yield 1 value (the iterator), forcing the for loop's
--- state to nil and failing on the first call.
function M._iter()
  return pairs(SESSIONS) --[[@as fun(): integer?, kak.ui.Session, integer?, kak.ui.Session]]
end

--- Snapshot of the DAEMONS table for tests.
---@return table<string, vim.SystemObj>
function M._daemons() return DAEMONS end

--- Snapshot of the SESSIONS table for tests. Returns the live
--- reference so tests can write to it (`ui._sessions()[buf] =
--- fake_session`) to exercise per-buffer routing paths. Production
--- code must NOT use this handle; sessions are added/removed by
--- `open()` / `Session:close()` exclusively.
---@return table<integer, kak.ui.Session>
function M._sessions() return SESSIONS end

--- Generate a unique kakoune session name for `:Kak` calls that do
--- not pass `--session=<name>`. Combining pid + monotonic counter
--- guarantees uniqueness across rapid successive `:Kak` invocations
--- in a single nvim (same second, same pid -> counter differentiates).
---@return string
function M._gen_session()
  SEQ = SEQ + 1
  return string.format('kak-nvim-%d-%d', vim.fn.getpid(), SEQ)
end

--- Make sure a kakoune daemon exists for the given session name and
--- remember it for cleanup.
---
--- Spawns `kak -d -s <session> -E <preamble>` via `vim.system` so the
--- server process is independent of any single client. The parent
--- nvim does not own a pipe to it (stdout/stderr=false), so closing
--- the last client doesn't kill the daemon via inherited-pipe EOF.
--- The daemon is killed explicitly via `Session:close()` once the
--- last client for `<session>` goes away, and again on `VimLeavePre`
--- as belt-and-suspenders.
---
--- The `-E <preamble>` payload sources + requires the `nvim`
--- windowing module server-side; every client connecting to this
--- session inherits those commands + the `windowing_module nvim`
--- override. The client MUST NOT re-source the preamble
--- (`provide-module` errors with `module 'nvim' already defined`).
---
--- When the session name already exists (e.g. user runs `:Kak
--- --session=foo` against a running foo), `kak -d -s foo` does NOT
--- spawn a duplicate daemon -- it becomes a thin client connected to
--- the existing one. We still track that sysobj; killing it on our
--- close path just disconnects our half of the multiplex without
--- disturbing the foreign daemon.
---
--- Returns nothing; raises if the spawn itself fails (e.g. kak binary
--- not on PATH).
---@param session string
function M._ensure_daemon(session)
  if DAEMONS[session] and not DAEMONS[session]:is_closing() then return end
  local windowing = require('kak.ui.windowing')
  local argv = windowing.daemon_argv(session)
  local ok, sys_or_err = pcall(vim.system, argv, {
    stdout = false,
    stderr = false,
  }, nil)
  if not ok then
    ---@cast sys_or_err string
    local err = sys_or_err
    local sfx = err:match('ENOENT')
        and '. The command is either not installed, missing from PATH, or not executable.'
      or string.format(' with error message: %s', err)
    error(('Spawning kak daemon failed%s'):format(sfx))
  end
  ---@cast sys_or_err vim.SystemObj
  DAEMONS[session] = sys_or_err
  -- 200ms pragmatic delay for the daemon to bind its socket. A
  -- future revision could poll `kak -c <session>` for a successful
  -- connect; today the delay is short enough that interactive `:Kak`
  -- users won't notice but long enough that the client spawn that
  -- follows finds the session ready.
  vim.wait(200, function() return false end, 25)
end

---@param opts kak.ui.OpenOpts?
---@return kak.ui.Session
function M.open(opts)
  log.debug('open start', { session = opts and opts.session, has_cmd = opts and opts.cmd ~= nil })
  opts = require('kak.ui.windowing').inject_args(opts)
  local cmd = opts.cmd or { 'kak' }
  local session = opts.session
  local is_fake = opts.cmd ~= nil

  -- Real-kak path: ensure a daemon exists for our session name. The
  -- fake-kak tests in `test/multi_client_spec.lua` pass a custom
  -- `opts.cmd` (the fake-kak-server fixture is both server + client
  -- in one process) -- spawning a `kak -d` for them would only
  -- confuse things, so we skip.
  if not is_fake then
    if not session or session == '' then session = M._gen_session() end
    local ok_d, err_d = pcall(M._ensure_daemon, session)
    if not ok_d then
      log.error('open: _ensure_daemon failed', { session = session, err = tostring(err_d) })
      error(err_d)
    end
    opts.session = session
  end

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
  do
    local ok, err = pcall(function() surface:open({ session = session }) end)
    if not ok then
      log.error('open: surface:open failed', { session = session, err = tostring(err) })
      error(err)
    end
  end
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
      log.info('on_exit fired', { code = code, signal = signal, session_id = sess and sess.id })
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
  local conn
  do
    local ok, err = pcall(
      function()
        conn = json_rpc.spawn(argv, {
          dispatchers = dispatchers,
          cwd = opts.cwd,
          env = opts.env,
        })
      end
    )
    if not ok then
      log.error('open: json_rpc.spawn failed', {
        argv = argv,
        session = session,
        err = tostring(err),
      })
      error(err)
    end
  end

  -- Hand the conn to the surface so `Surface:report_resize` can send
  -- `resize` to kak. `surface:open` ran BEFORE the conn existed (the
  -- conn needs the content_buf/window the surface just claimed), so
  -- `surface.rpc` is still nil here -- without this assignment every
  -- report_resize bails at the `not self.rpc` guard and kak never
  -- learns the window size, falling back to its default (half-height)
  -- layout.
  surface.rpc = conn

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
      log.debug('close start', { id = self.id })
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
      log.debug('close: survivor', { id = survivor and survivor.id })
      self.closed = true
      if self.conn and not self.conn:is_closing() then self.conn:terminate() end
      -- Drop any open menu/info popups BEFORE the surface tears down
      -- the content window. A `relative='win'` float whose anchor
      -- window is closed becomes orphaned -- nvim re-homes it to
      -- `relative='editor'` at its last screen coords, so the dead
      -- session's completion menu / info box sticks on screen and
      -- appears inside a sibling (survivor) window after `:q`.
      if self.handlers and self.handlers.popups then
        pcall(function() self.handlers.popups:close() end)
      end
      if self.surface then
        self.surface.rpc = nil
        self.surface:close()
      end
      log.debug('close: surface:close done')
      if self.input then self.input:disable() end
      log.debug('close: input disabled')
      pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
      SESSIONS[self.id] = nil
      -- Only clear `current_session` if it still refers to us. The
      -- survivor-switch above already replaced it, so this guard
      -- is what handles the no-survivor case.
      if current_session == self then current_session = nil end
      -- Kill the daemon for this session name when no other live
      -- session shares it. Iterating AFTER removing `self` from
      -- SESSIONS means a count of 0 means "self was the last client
      -- for this session name". Skip the kill entirely for fake-kak
      -- sessions (no daemon was ever spawned for them).
      if not is_fake and self.surface and self.surface.session then
        local session_name = self.surface.session
        local still_used = false
        for _, s in pairs(SESSIONS) do
          if s ~= self and not s.closed and s.surface and s.surface.session == session_name then
            still_used = true
            break
          end
        end
        if not still_used then
          local d = DAEMONS[session_name]
          if d and not d:is_closing() then pcall(function() d:kill(15) end) end
          DAEMONS[session_name] = nil
          log.debug('close: daemon killed', { session = session_name })
        end
      end
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
      log.debug('close: done', { id = self.id })
      -- Give the user's cursor shape back so a window that replaces
      -- this one (survivor focus or a plain :bd) does not inherit the
      -- insert/replace beam.
      require('kak.ui.render').restore_cursor_shape()
    end,
  }
  -- Now that `sess` exists, hook the handlers back to it so
  -- statusbar / input can find the session context.
  h.session = sess

  SESSIONS[content_bufnr] = sess

  -- Per-session autocmds: keep the registration scoped to the
  -- augroup so disabling/closing one session doesn't disturb others.
  local augroup
  do
    local ok, err = pcall(function()
      augroup =
        vim.api.nvim_create_augroup('KakUiSession' .. tostring(content_bufnr), { clear = true })
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
        callback = function()
          M.set_current(sess)
          if saved_timeoutlen == nil then saved_timeoutlen = vim.o.timeoutlen end
          vim.o.timeoutlen = 0
        end,
      })
      -- Restore the user's cursor shape when focus leaves the kak
      -- window so non-kak windows keep their own guicursor. The
      -- WinEnter -> draw_status path re-applies the beam on return.
      vim.api.nvim_create_autocmd('WinLeave', {
        group = augroup,
        buffer = content_bufnr,
        callback = function()
          require('kak.ui.render').restore_cursor_shape()
          if saved_timeoutlen ~= nil then
            vim.o.timeoutlen = saved_timeoutlen
            saved_timeoutlen = nil
          end
        end,
      })
    end)
    if not ok then
      log.error('open: autocmd install failed', {
        session = session,
        content_buf = content_bufnr,
        err = tostring(err),
      })
      error(err)
    end
  end
  sess.augroup = augroup

  M.set_current(sess)
  -- Defensive: after `:KakNewWin` opens a new session, every OTHER
  -- live session's window may have just been resized (the
  -- `vim.cmd('vsplit')` inside `:KakNewWin`). Their per-buffer
  -- `WinResized` autocmd should already have fired report_resize
  -- for them, but that's timing-sensitive: it runs from the
  -- `vim.cmd('vsplit')` event loop and can race with the new
  -- session's `vim.defer_fn(50)` (which sees the new session's
  -- window, not the existing one). Belt-and-suspenders: explicitly
  -- re-run report_resize on every OTHER live session right after
  -- the new session is registered, reading CURRENT dims from each
  -- window. Covers the case where a session's autocmd fired with
  -- stale dims (split not fully settled yet), and ensures the
  -- user sees the correct full-height rendering on BOTH sides of
  -- the split instead of half-height (the original `:new`
  -- symptom).
  for _, other in pairs(SESSIONS) do
    if other ~= sess and not other.closed and other.input then
      pcall(function() other.input:report_resize() end)
    end
  end
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

-- Iterate every live session + daemon on shutdown so the kak
-- processes get a chance to terminate cleanly. `Session:close()`
-- already kills its daemon when the last client for that session
-- name goes away, but the user might quit nvim without closing
-- each session individually -- in which case the daemons would
-- otherwise linger until their own `kak -d` parent (this nvim)
-- exits. Belt-and-suspenders: kill them here too.
vim.api.nvim_create_autocmd('VimLeavePre', {
  group = vim.api.nvim_create_augroup('KakUiShutdown', { clear = true }),
  callback = function()
    for _, s in pairs(SESSIONS) do
      if s.conn then s.conn:terminate() end
    end
    for _, d in pairs(DAEMONS) do
      pcall(function() d:kill(15) end)
    end
  end,
})

--- Back-compat alias for older tests that used `M.active()`.
---@return kak.ui.Session?
function M.active() return current_session end

return M
