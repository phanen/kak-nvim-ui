---
--- nvim-side windowing bridge.
---
--- When the user runs `:new`, `:tabnew` or `focus` inside a Kakoune
--- session attached to this nvim UI, Kakoune invokes a windowing-module
--- sub-command (`<windowing_module>-terminal-<placement>` etc). The
--- bundled `kak/nvim.kak` provides that module: each command shells
--- out to `nvim --server <listen> --remote-expr "execute('...')"`,
--- which is an RPC eval that bypasses the parent nvim's `vim.on_key`
--- hook (the kak content buffer drops every typed key and forwards
--- it to the child kak, so a `--remote-send` of `:KakNewWin ...`
--- would never reach the parent nvim's command line).
---
--- This module owns:
---   * `listen_socket()` -- cached `vim.fn.serverstart()` path passed
---     to the spawned kak child in env `NVIM` (mirrors Nvim's own
---     convention; Nvim sets `$NVIM` to `v:servername` for children,
---     `vim.system` does not, so we set it explicitly).
---   * `kak_script_path()` -- absolute path to `kak/nvim.kak` so the
---     child can source it on startup.
---   * `daemon_preamble()` -- the `-E` payload the daemon sources
---     ONCE at startup (`source <kak_script>; require-module nvim;
---     set global windowing_module nvim`). This MUST be applied
---     server-side, not per-client: kak options + commands are
---     session-wide, and requiring the module twice raises
---     `provide-module: module 'nvim' already defined`.
---   * `daemon_argv(session)` -- argv we pass to `kak -d -s
---     <session> -E <preamble>`. Exposed for tests; production
---     callers go through `kak.ui._ensure_daemon`.
---   * `inject_args(opts)` -- mutates an `opts` table for
---     `kak.ui.open` so EVERY open (`Kak`, `KakNewWin`, `KakNewTab`)
---     picks up the listen env. The client does NOT source the
---     preamble -- it inherits everything from the daemon. Caller
---     `extra_args` (including any `-e <payload>` the test/spec
---     passed) are preserved verbatim.
---   * `focus_active()` -- focus the content window of the live
---     session, used by the `nvim-focus` kak command.
---

---@class kak.ui.windowing

local M = {}

--- Cached nvim listen socket path returned by `vim.fn.serverstart()`.
---@type string?
local listen = nil

--- Ensure this nvim is listening on a UNIX socket and return the
--- path. The first call starts the server; subsequent calls reuse the
--- cached value.
---@return string
function M.listen_socket()
  if listen and listen ~= '' then
    -- `vim.fn.serverlist()` returns a list of active server socket
    -- paths. If our cached path is still in there the socket is alive
    -- and we can skip restarting. `vim.fn` returns a list-like table;
    -- we only need string entries so an untyped local is fine here.
    local servers = vim.fn.serverlist()
    for _, s in ipairs(servers) do
      if s == listen then return listen end
    end
  end
  local fresh = vim.fn.serverstart()
  assert(fresh ~= '', 'vim.fn.serverstart() returned empty path')
  listen = fresh
  return listen
end

--- Absolute path of the bundled `kak/nvim.kak` script.
---
--- Computed at module load via `debug.getinfo(1, 'S').source` so we
--- don't depend on `runtimepath` or `cwd`. This file lives at
--- `<repo>/lua/kak/ui/windowing.lua`; going up four `:h` levels gets
--- us to `<repo>`, then we append `kak/nvim.kak`.
---@return string
function M.kak_script_path()
  local info = debug.getinfo(1, 'S')
  assert(info and info.source, 'debug.getinfo returned no source')
  local src = info.source
  -- `src` is prefixed with '@' for files; strip it before fnamemodify.
  if src:sub(1, 1) == '@' then src = src:sub(2) end
  -- windowing.lua -> ui -> kak -> lua -> <repo root>; four `:h` to
  -- climb from the file to the repo root.
  local base = vim.fn.fnamemodify(src, ':p:h:h:h:h')
  return base .. '/kak/nvim.kak'
end

--- Build the kakoune startup preamble: source the nvim windowing
--- module so `:new`, `:tabnew`, `focus` inside this session shell
--- back into the parent nvim. Applied ONCE by the daemon (`-E`)
--- so all clients sharing the session inherit it for free; the
--- `require-module nvim` is mandatory because `provide-module`
--- only registers the module body for later execution, and
--- without the require the `define-command` calls inside
--- `kak/nvim.kak` never run.
---@return string
function M.daemon_preamble()
  return 'source '
    .. M.kak_script_path()
    .. '; require-module nvim; set global windowing_module nvim'
end

--- Argv we pass to `kak -d -s <session> -E <preamble>`. Exposed
--- so tests can assert the structure without spawning a process.
---@param session string
---@return string[]
function M.daemon_argv(session) return { 'kak', '-d', '-s', session, '-E', M.daemon_preamble() } end

--- Inject nvim-windowing scaffolding into an `opts` table for
--- `kak.ui.open`.
---
--- Adds `opts.env.NVIM` (so the child kak can shell back into us
--- via `%sh{ nvim --server $NVIM ... }`). Does NOT source the
--- windowing preamble -- the daemon does that with `-E` and the
--- client inherits everything session-wide. Caller `extra_args`
--- (including any `-e <payload>` they passed) are passed through
--- verbatim: no folding, no synthetic `-e`.
---
--- The previous design folded our preamble into the client's `-e`
--- payload. That triggered `provide-module: module 'nvim' already
--- defined` every time a second client joined, because the daemon
--- had already sourced + required the module server-side.
---@param opts? kak.ui.OpenOpts
---@return kak.ui.OpenOpts
function M.inject_args(opts)
  opts = opts or {}
  ---@type table<string,string>?
  local env_in = opts.env
  local env = env_in and vim.deepcopy(env_in) or {}
  env.NVIM = M.listen_socket()
  opts.env = env
  return opts
end

--- Map a kakoune windowing placement to an nvim split command.
--- Mirrors the `rc/windowing/detection.kak` contract:
---   horizontal = left-right side-by-side
---   vertical   = top-bottom stacked
---   window     = new OS window (nvim analog: a left-right split, so
---                 `:new` defaults to side-by-side as users expect)
---   tab        = new tabpage
---@param placement string?
---@return string
function M.split_for(placement)
  if placement == 'vertical' then return 'belowright split' end
  if placement == 'tab' then return 'tabnew' end
  return 'belowright vsplit'
end

--- Focus the content window of the active session (no-op if no
--- session is open). Used by the `nvim-focus` kak command.
function M.focus_active()
  local sess = require('kak.ui').current()
  if not sess then return end
  if sess.surface and sess.surface.focus then sess.surface:focus() end
end

return M
