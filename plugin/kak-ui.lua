--- vim/lua plugin entry: defines user commands and autocmds.

if vim.g.loaded_kak_ui == 1 then return end
vim.g.loaded_kak_ui = 1

local log = require('kak.ui.log').log

vim.api.nvim_create_user_command('Kak', function(opts)
  local session = nil
  local args = {}
  for _, arg in ipairs(opts.fargs) do
    if arg:match('^%-%-session=') then
      session = arg:sub(#'--session=' + 1)
    elseif arg == '--close' then
      require('kak.ui').close()
      return
    else
      args[#args + 1] = arg
    end
  end
  -- First call claims the current nvim window. Later sessions may
  -- be opened via `:KakNewWin` / `:KakNewTab`.
  require('kak.ui').open({
    session = session,
    extra_args = args,
  })
end, {
  nargs = '*',
  desc = 'Open or attach to a Kakoune JSON-UI session.',
  complete = function(arglead)
    local opts = { '--session=', '--close' }
    local out = {}
    for _, o in ipairs(opts) do
      if arglead == '' or o:find(arglead, 1, true) then out[#out + 1] = o end
    end
    return out
  end,
})

vim.api.nvim_create_user_command('KakClose', function(opts)
  -- Allow an optional buffer number: close that session if known.
  local arg = opts.fargs[1]
  if arg and arg ~= '' then
    local buf = tonumber(arg)
    if buf then
      ---@cast buf integer
      require('kak.ui').close(buf)
      return
    end
  end
  require('kak.ui').close()
end, { nargs = '?', desc = 'Close the active Kakoune UI session.' })

-- Bridge for the `nvim` kak windowing module. When Kakoune calls
-- `:new` / `:tabnew` / `focus`, the bundled `kak/nvim.kak` shells
-- `nvim --server <listen> --remote-expr "execute('KakNewWin ...')"` (see
-- `lua/kak/ui/windowing.lua`). The commands below do the nvim-side
-- half: open a split / tab and call `kak.ui.open()` to spawn a new
-- json-ui client against the same session. `--remote-expr` is required:
-- `--remote-send` keys are dropped by the kak content buffer's
-- `vim.on_key` hook and never reach the parent nvim command line.
vim.api.nvim_create_user_command('KakNewWin', function(opts)
  local placement = opts.fargs[1]
  local session = opts.fargs[2]
  -- Capture every error here so it lands in the kak-ui log file.
  -- When `:new` is invoked from inside kak, the nvim-side trigger is
  -- a `nvim --remote-expr "execute('KakNewWin window <sess>')"`;
  -- an unhandled error from `open()` becomes `--remote-expr`'s
  -- exit code 2 with no error message reaching the user. Catching
  -- + logging + re-raising gives us the error string in the log
  -- AND keeps the non-zero exit code (so --remote-expr still
  -- reports failure).
  local ok, err = pcall(function()
    vim.cmd(require('kak.ui.windowing').split_for(placement))
    require('kak.ui').open({ session = session })
  end)
  if not ok then
    log.error('KakNewWin failed', {
      placement = placement,
      session = session,
      err = tostring(err),
    })
    error(err)
  end
end, {
  nargs = '+',
  desc = 'Open a new split hosting a Kakoune json-ui client for <session>.',
})

vim.api.nvim_create_user_command('KakNewTab', function(opts)
  vim.cmd('tabnew')
  require('kak.ui').open({ session = opts.fargs[1] })
end, {
  nargs = 1,
  desc = 'Open a new tab hosting a Kakoune json-ui client for <session>.',
})

vim.api.nvim_create_user_command(
  'KakFocus',
  function() require('kak.ui.windowing').focus_active() end,
  { desc = 'Focus the active Kakoune json-ui session content window.' }
)
