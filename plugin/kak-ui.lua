--- vim/lua plugin entry: defines user commands and autocmds.

if vim.g.loaded_kak_ui == 1 then return end
vim.g.loaded_kak_ui = 1

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

vim.api.nvim_create_user_command(
  'KakClose',
  function() require('kak.ui').close() end,
  { desc = 'Close the active Kakoune UI session.' }
)

-- Bridge for the `nvim` kak windowing module. When Kakoune calls
-- `:new` / `:tabnew` / `focus`, the bundled `kak/nvim.kak` shells
-- `nvim --server <listen> --remote-send ':KakNewWin ...'` (see
-- `lua/kak/ui/windowing.lua`). The commands below do the nvim-side
-- half: open a split / tab and call `kak.ui.open()` to spawn a new
-- json-ui client against the same session.
vim.api.nvim_create_user_command('KakNewWin', function(opts)
  local placement = opts.fargs[1]
  local session = opts.fargs[2]
  local split_cmd
  if placement == 'vertical' then
    split_cmd = 'vsplit'
  elseif placement == 'horizontal' then
    split_cmd = 'split'
  else
    split_cmd = 'split'
  end
  vim.cmd('belowright ' .. split_cmd)
  require('kak.ui').open({ session = session })
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
