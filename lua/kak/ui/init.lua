---
--- The Kakoune JSON-UI plugin entry point.
---
--- Spawns `kak -ui json [...]` as a child process, opens an NDJSON
--- JSON-RPC connection over stdio, allocates a scratch buffer for the
--- main render area, and wires Kakoune notifications to render / input
--- / popup handlers.

local json_rpc = require('kak.ui.json_rpc')
local protocol = require('kak.ui.protocol')
local faces = require('kak.ui.faces')
local render = require('kak.ui.render')
local popups = require('kak.ui.popups')
local input = require('kak.ui.input')

local M = {}

local ACTIVE = nil

local function bufname(session) return session and ('kak://' .. session) or 'kak://main' end

local function make_handlers(ctx, ui_options)
  local face_cache =
    faces.new({ cap = (ui_options and tonumber(ui_options.face_cache_size)) or 512 })
  local renderer = render.new({ faces = face_cache })
  local popup_mgr = popups.new({ faces = face_cache, renderer = renderer })

  local function ensure_buf()
    if not renderer.content_buf or not vim.api.nvim_buf_is_valid(renderer.content_buf) then
      renderer:set_buf(vim.api.nvim_create_buf(false, true))
      vim.api.nvim_set_option_value('bufhidden', 'wipe', { buf = renderer.content_buf })
      vim.api.nvim_set_option_value('swapfile', false, { buf = renderer.content_buf })
      if not renderer.mode_buf then renderer:set_mode_buf(vim.api.nvim_create_buf(false, true)) end
    end
    return renderer.content_buf
  end

  local h = {}
  h.draw = function(p)
    ensure_buf()
    renderer:draw(p.lines, p.cursor_pos, p.default_face, p.padding_face)
  end
  h.draw_status = function(p)
    ensure_buf()
    renderer:draw_mode(p.mode_line, p.default_face)
    renderer:set_prompt(p.prompt, p.content, p.cursor_pos, p.default_face, p.style)
  end
  h.menu_show = function(p) popup_mgr:menu_show(p.items, p.anchor, p.fg, p.bg, p.style) end
  h.menu_select = function(p) popup_mgr:menu_select(p.selected) end
  h.menu_hide = function() popup_mgr:menu_hide() end
  h.info_show = function(p) popup_mgr:info_show(p.title, p.content, p.anchor, p.face, p.style) end
  h.info_hide = function() popup_mgr:info_hide() end
  h.refresh = function(p) ctx.last_force = p.force and true or false end
  h.set_ui_options = function(p)
    ctx.ui_options = p.options
    for k, v in pairs(p.options) do
      ui_options[k] = v
    end
  end

  return {
    handlers = h,
    renderer = renderer,
    faces = face_cache,
    popups = popup_mgr,
    ensure_buf = ensure_buf,
  }
end

--- @param opts { session?: string, cmd?: string[], extra_args?: string[], cwd?: string, env?: table }
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
  local ctx = { ui_options = ui_options, last_force = false }
  local sess

  local h = make_handlers(ctx, ui_options)
  local conn

  local dispatchers = {
    on_notify = function(method, params)
      local fn = h.handlers[method]
      if fn then
        local ok, err = pcall(
          function()
            fn(protocol.decode({ jsonrpc = '2.0', method = method, params = params }).params)
          end
        )
        if not ok then
          io.stderr:write('[kak.ui] handler ' .. method .. ' error: ' .. tostring(err) .. '\n')
        end
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
    on_error = function(code, err)
      io.stderr:write(string.format('[kak.ui] rpc error %d: %s\n', code, vim.inspect(err)))
    end,
  }

  conn = json_rpc.spawn(argv, {
    dispatchers = dispatchers,
    cwd = opts.cwd,
    env = opts.env,
    log_level = opts.log_level or 'warn',
  })

  local buf = h.ensure_buf()
  local input_handler = input.new({ rpc = conn, renderer = h.renderer })
  input_handler:enable(buf)

  -- Send initial `resize` once Kakoune has had a chance to write back.
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

  pcall(vim.api.nvim_buf_set_name, buf, bufname(session))
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].filetype = 'kak-ui'

  -- Kakoune is single-window: claim the current tab so resize reports
  -- a consistent area. Reuse the current window if it already shows an
  -- empty unnamed buffer (so :Kak does not leave a stray empty split).
  local cur_win = vim.api.nvim_get_current_win()
  local cur_buf = vim.api.nvim_win_get_buf(cur_win)
  local can_reuse = cur_buf ~= buf
  if can_reuse then
    local lines = vim.api.nvim_buf_get_lines(cur_buf, 0, -1, false)
    local listed = vim.api.nvim_buf_get_option(cur_buf, 'buflisted')
    local ft = vim.api.nvim_buf_get_option(cur_buf, 'filetype')
    can_reuse = not listed
      and #lines <= 1
      and (lines[1] or '') == ''
      and (ft == '' or ft == 'kak-ui')
  end
  if not can_reuse then vim.cmd('tabnew') end

  local keeper = vim.api.nvim_get_current_win()
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(vim.api.nvim_get_current_tabpage())) do
    if w ~= keeper then pcall(vim.api.nvim_win_close, w, true) end
  end

  if vim.api.nvim_win_get_buf(keeper) ~= buf then vim.api.nvim_win_set_buf(keeper, buf) end

  sess = setmetatable({
    conn = conn,
    buf = buf,
    handlers = h.handlers,
    renderer = h.renderer,
    faces = h.faces,
    popups = h.popups,
    input = input_handler,
    close = function()
      conn:terminate()
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

function M.active() return ACTIVE end

return M
