---
--- Kakoune daemon (`kak -d -s <name>`) lifecycle.
---
--- Each `:Kak` opens a separate daemon so the Kakoune SERVER lives
--- independently of any single client. `:q` then kills only the
--- JSON-UI client while the daemon survives for sibling clients.
---
--- Split out from `kak.ui.init` so the spawn / dedup / kill / GC
--- logic lives in one place instead of three separate call sites
--- (open, close, VimLeavePre). `daemon.lua` owns the `DAEMONS`
--- table; init.lua only consumes `M.spawn`, `M.kill_if_last`,
--- `M.kill_all`.
---

---@class kak.ui.daemon.Registry
---@field _entries table<string, vim.SystemObj>
local Registry = {}

---@type table<string, vim.SystemObj>
Registry._entries = {}

--- Spawn a `kak -d -s <session>` daemon if one is not already tracked
--- for `<session>`. Idempotent: a second call with the same session
--- is a no-op (returns the cached sysobj).
---
--- When the session name already exists server-side, `kak -d -s foo`
--- becomes a thin client connected to the existing daemon; we still
--- track that sysobj so we can disconnect on close.
---
--- Raises if the spawn itself fails (e.g. kak binary not on PATH).
---@param session string
---@return vim.SystemObj sysobj
function Registry.spawn(session)
  local existing = Registry._entries[session]
  if existing and not existing:is_closing() then return existing end
  local argv = require('kak.ui.windowing').daemon_argv(session)
  local ok, sys_or_err = pcall(vim.system, argv, { stdout = false, stderr = false }, nil)
  if not ok then
    ---@cast sys_or_err string
    local err = sys_or_err
    local sfx = err:match('ENOENT')
        and '. The command is either not installed, missing from PATH, or not executable.'
      or string.format(' with error message: %s', err)
    error(('Spawning kak daemon failed%s'):format(sfx))
  end
  ---@cast sys_or_err vim.SystemObj
  Registry._entries[session] = sys_or_err
  -- 200ms pragmatic delay for the daemon to bind its socket. A
  -- future revision could poll `kak -c <session>` for a successful
  -- connect; today the delay is short enough that interactive
  -- `:Kak` users won't notice but long enough that the client
  -- spawn that follows finds the session ready.
  vim.wait(200, function() return false end, 25)
  return sys_or_err
end

--- Iterate tracked daemons. Yield `(session, sysobj)` pairs.
---@return fun(): string, vim.SystemObj
function Registry.iter()
  return pairs(Registry._entries) --[[@as fun(): string, vim.SystemObj]]
end

--- Lookup the sysobj for `<session>` if any. Returns nil when no
--- daemon was tracked for the name (e.g. fake-kak clients).
---@param session string?
---@return vim.SystemObj?
function Registry.lookup(session)
  if not session then return nil end
  return Registry._entries[session]
end

--- Kill the daemon for `<session>` and drop it from the registry.
--- Idempotent: a second call on a missing/closing daemon is a no-op.
---@param session string
function Registry.kill(session)
  local d = Registry._entries[session]
  if d and not d:is_closing() then pcall(function() d:kill(15) end) end
  Registry._entries[session] = nil
end

--- Snapshot of the underlying storage. Exposed for tests only;
--- production callers must NOT mutate this.
---@return table<string, vim.SystemObj>
function Registry.entries() return Registry._entries end

--- Return true iff `session` is shared by other live sessions
--- (`session_name == s.surface.session`). `self_session` is the
--- caller -- the new client for the same name -- so we exclude it
--- from the count: count of 0 means "self is the last client".
---
--- Why a hand-rolled count: the close path iterates SESSIONS AFTER
--- removing `self` from the registry, so the count it observes IS
--- "everyone else". Encapsulating the rule here keeps init.lua
--- free of the iteration detail.
---@param session_name string
---@param self_session any opaque session handle the caller ignores
---@param iter fun(): integer?, any session table iteration function
function Registry.is_shared(session_name, self_session, iter)
  for _, s in iter() do
    if s ~= self_session and not s.closed and s.surface and s.surface.session == session_name then
      return true
    end
  end
  return false
end

--- Kill every tracked daemon. Used by `VimLeavePre` as
--- belt-and-suspenders so client-less daemons don't outlive the
--- host nvim. Tolerates already-closing processes.
function Registry.kill_all()
  for _, d in Registry.iter() do
    pcall(function() d:kill(15) end)
  end
end

return Registry
