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
---   * `inject_args(opts)` -- mutates an `opts` table for
---     `kak.ui.open` so EVERY open (`Kak`, `KakNewWin`, `KakNewTab`)
---     picks up the listen env and a leading
---     `-e 'source ...; require-module nvim; set global windowing_module nvim'`
---     argument. The `require-module nvim` is required: `provide-module`
---     only registers the module body for later execution, and without
---     the require the `nvim-terminal-*` commands are never defined.
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

--- Inject nvim-windowing scaffolding into an `opts` table for
--- `kak.ui.open`.
---
--- Adds `opts.env.NVIM` (so the child kak can shell back into us)
--- and folds `source <kak_script>; require-module nvim; set global
--- windowing_module nvim` into the FIRST `-e` payload so the child
--- registers AND executes the `nvim-*` windowing commands and
--- overrides the default module.
---
--- `require-module nvim` is required because `provide-module` only
--- registers the module body for later execution; without the
--- explicit require the `define-command` calls inside `kak/nvim.kak`
--- never run and `:new` reports `nvim-terminal-window: no such
--- command`.
---
--- Kakoune accepts exactly one `-e` flag, so we cannot append a
--- second one -- we must merge into whatever the caller passed (or
--- introduce our own `-e` if they didn't pass one). Caller-supplied
--- `extra_args` that don't touch `-e` (e.g. `-foo`, `--session=...`)
--- are preserved in place.
---@param opts? kak.ui.OpenOpts
---@return kak.ui.OpenOpts
function M.inject_args(opts)
  opts = opts or {}
  ---@type table<string,string>?
  local env_in = opts.env
  local env = env_in and vim.deepcopy(env_in) or {}
  env.NVIM = M.listen_socket()
  opts.env = env
  local preamble = 'source '
    .. M.kak_script_path()
    .. '; require-module nvim; set global windowing_module nvim; '
  ---@type string[]
  local user = opts.extra_args or {}
  local merged = false
  ---@type string[]
  local out = {}
  local i = 1
  while i <= #user do
    local a = user[i]
    ---@cast a string
    local is_combined = a:sub(1, 2) == '-e' and #a > 2
    if not merged and a == '-e' and i < #user then
      -- `-e <payload>` (separate-arg) form: fold the payload into
      -- our preamble; consume both entries.
      out[#out + 1] = '-e'
      out[#out + 1] = preamble .. user[i + 1]
      merged = true
      i = i + 2
    elseif not merged and is_combined then
      -- `-e<payload>` (combined) form: split into `-e` flag +
      -- folded payload.
      out[#out + 1] = '-e'
      out[#out + 1] = preamble .. a:sub(3)
      merged = true
      i = i + 1
    else
      out[#out + 1] = a
      i = i + 1
    end
  end
  if not merged then
    -- Caller passed no `-e` at all: introduce one with just our
    -- preamble (drop the trailing '; ') so the windowing module is
    -- registered even when there is no caller payload to merge into.
    out[#out + 1] = '-e'
    out[#out + 1] = preamble:sub(1, -3)
  end
  opts.extra_args = out
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
