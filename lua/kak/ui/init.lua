---
--- The Kakoune JSON-UI plugin entry point.
---
--- Spawns `kak -ui json [...]` as a child process, opens an NDJSON
--- JSON-RPC connection over stdio, claims one nvim tab + window for
--- the render area, and wires Kakoune notifications to render / input
--- / popup handlers.
---
--- Layout: see `lua/kak/ui/ui_surface.lua` for the tab/window
--- lifecycle and `lua/kak/ui/handlers.lua` for the notification
--- dispatcher.

local json_rpc = require('kak.ui.json_rpc')
local surface_mod = require('kak.ui.ui_surface')
local handlers = require('kak.ui.handlers')
local input = require('kak.ui.input')
local log = require('kak.ui.log').log

---@alias kak.ui.OpenOpts { session?: string, cmd?: string[], extra_args?: string[], cwd?: string, env?: table<string, string> }

--- A Session owns the rpc + input bindings + close; everything else
--- (renderer, faces, popups, surface, handlers dispatch) lives on the
--- `kak.ui.Handlers` module and is reached via `__index` so this
--- class does not have to enumerate the actor's fields.
---@class kak.ui.Session
---@field conn kak.ui.json_rpc.Connection
---@field buf integer
---@field input kak.ui.input.Handler
---@field close fun(self: kak.ui.Session)
---@field __index kak.ui.Handlers

local M = {}

---@type kak.ui.Session?
local ACTIVE = nil

---@param opts kak.ui.OpenOpts?
---@return kak.ui.Session
function M.open(opts)
  if ACTIVE then return ACTIVE end
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
  local sess

  -- Surface claims the nvim tab + window and creates the scratch
  -- buffers before we spawn the child process, so handlers can attach
  -- the renderer to buffers that already have a home.
  local surface = surface_mod.new({ session = session })
  surface:open({ session = session })

  handlers.setup({ ctx = ctx, ui_options = ui_options, surface = surface })

  local dispatchers = {
    on_notify = function(method, params)
      local fn = handlers[method]
      if fn then
        local ok, err = pcall(function() fn(handlers, params or {}) end)
        if not ok then log.warn('handler', method, 'error:', tostring(err)) end
      end
    end,
    -- Kakoune never sends inbound requests; this stub is required by
    -- the rpc dispatcher signature.
    on_request = function(method)
      return nil, { code = -32601, message = 'method not found: ' .. method }
    end,
    on_exit = function(code, signal)
      if ACTIVE == sess then ACTIVE = nil end
      vim.schedule(
        function()
          vim.notify(
            'Kakoune exited (code=' .. tostring(code) .. ', signal=' .. tostring(signal) .. ')',
            vim.log.levels.INFO
          )
        end
      )
    end,
    on_error = function(code, err) log.warn('rpc error', code, vim.inspect(err)) end,
  }

  ---@type kak.ui.json_rpc.Connection
  local conn = json_rpc.spawn(argv, {
    dispatchers = dispatchers,
    cwd = opts.cwd,
    env = opts.env,
  })
  surface.rpc = conn

  local buf = handlers:ensure_buf()
  local input_handler = input.new({ rpc = conn, surface = surface })
  input_handler:enable(buf)

  vim.defer_fn(function()
    if not conn:is_closing() then input_handler:report_resize() end
  end, 50)

  local augroup = vim.api.nvim_create_augroup('KakUi' .. tostring(buf), { clear = true })
  vim.api.nvim_create_autocmd({ 'VimResized', 'WinResized' }, {
    group = augroup,
    buffer = buf,
    callback = function() input_handler:report_resize() end,
  })
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = augroup,
    callback = function() conn:terminate() end,
  })

  ---@type kak.ui.Session
  -- `handlers` is the dispatch surface (module-as-actor). Fall
  -- through to it via __index so this table doesn't have to enumerate
  -- its fields -- adding a new field on `Handlers` makes it reachable
  -- here without touching this file.
  sess = setmetatable({
    conn = conn,
    buf = buf,
    input = input_handler,
    close = function()
      conn:terminate()
      if handlers.surface then handlers.surface:close() end
      if ACTIVE == sess then ACTIVE = nil end
    end,
  }, { __index = handlers })
  ACTIVE = sess
  return sess
end

function M.close()
  if not ACTIVE then return end
  ACTIVE:close()
end

---@return kak.ui.Session?
function M.active() return ACTIVE end

return M
