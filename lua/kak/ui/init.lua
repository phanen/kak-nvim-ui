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
local protocol = require('kak.ui.protocol')
local surface_mod = require('kak.ui.ui_surface')
local handlers = require('kak.ui.handlers')
local input = require('kak.ui.input')
local log = require('kak.ui.log').log

---@alias kak.ui.OpenOpts { session?: string, cmd?: string[], extra_args?: string[], cwd?: string, env?: table<string, string> }

---@class kak.ui.Session
---@field conn kak.ui.json_rpc.Connection
---@field buf integer
---@field handlers table<string, function>
---@field renderer kak.ui.render.Renderer
---@field faces kak.ui.faces.Cache
---@field popups kak.ui.popups.Manager
---@field input kak.ui.input.Handler
---@field surface kak.ui.surface.Surface
---@field close fun(self: kak.ui.Session)

local M = {}

---@type kak.ui.Session?
local ACTIVE = nil

---@param opts kak.ui.OpenOpts?
---@return kak.ui.Session
function M.open(opts)
  if ACTIVE then return ACTIVE end
  opts = opts or {}
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

  local h = handlers.build(ctx, ui_options, surface, nil)

  local dispatchers = {
    on_notify = function(method, params)
      local fn = h.handlers[method]
      if fn then
        local ok, err = pcall(
          function()
            fn(protocol.decode({ jsonrpc = '2.0', method = method, params = params }).params)
          end
        )
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

  local buf = h.ensure_buf()
  local input_handler = input.new({ rpc = conn })
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
  sess = setmetatable({
    conn = conn,
    buf = buf,
    handlers = h.handlers,
    renderer = h.renderer,
    faces = h.faces,
    popups = h.popups,
    input = input_handler,
    surface = surface,
    close = function()
      conn:terminate()
      surface:close()
      if ACTIVE == sess then ACTIVE = nil end
    end,
  }, {})
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
