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
