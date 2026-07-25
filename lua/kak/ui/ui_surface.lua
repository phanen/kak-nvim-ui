---
--- Tab/window lifecycle for the Kakoune JSON-UI render area.
---
--- A `Surface` owns the content buffer (the Kakoune edit area) and the
--- window that displays it. It also creates the status float -- a
--- 1-row floating window at the bottom of the editor that renders the
--- Kakoune statusline + cmdline (see `lua/kak/ui/statusbar.lua`).
---
--- To stop nvim from drawing its OWN statusline on top of ours we set
--- `laststatus=0` (was 2 with the `&statusline`-string approach).
--- `editor_dims()` reports `lines-1` rows to Kakoune so the editor
--- draws `lines-1` rows of content while the float overlays the last
--- screen row.
---
--- Kakoune is a single-window editor, so this plugin claims exactly one
--- tab + one window per session and never creates splits: a normal-mode
--- buffer editor expects a 1:1 mapping between its UI area and the nvim
--- render area. If the user runs `:Kak` while sitting on an empty,
--- unlisted buffer (the default starting point or a dismissed
--- completion popup), we reuse that window instead of opening a new tab.
--- Otherwise we open a new tab so the existing layout survives untouched.

---@alias kak.ui.surface.SurfaceOpenOpts
---|{ rpc?: kak.ui.json_rpc.Connection, session?: string }

---@class kak.ui.surface.Surface
---@field session? string
---@field rpc? kak.ui.json_rpc.Connection
---@field content_buf integer?
---@field content_win integer?
---@field status_buf integer?
---@field status_win integer?
---@field saved? { showtabline: integer, laststatus: integer, cmdheight: integer }
---@field open fun(self: kak.ui.surface.Surface, opts?: kak.ui.surface.SurfaceOpenOpts)
---@field close fun(self: kak.ui.surface.Surface)
---@field report_resize fun(self: kak.ui.surface.Surface)
---@field focus fun(self: kak.ui.surface.Surface)
---@field editor_dims fun(self: kak.ui.surface.Surface): { width: integer, height: integer }
---@field editor_row fun(self: kak.ui.surface.Surface, buf: integer, line: integer): integer?
---@field editor_col fun(self: kak.ui.surface.Surface, buf: integer, column: integer): integer?
---@field ensure_status_float fun(self: kak.ui.surface.Surface)

local M = {}

---@param session? string
---@return string
local function bufname(session) return session and ('kak://' .. session) or 'kak://main' end

local Surface = {}
Surface.__index = Surface

---@param opts? { session?: string }
---@return kak.ui.surface.Surface
function M.new(opts)
  opts = opts or {}
  return setmetatable({
    session = opts.session,
    rpc = nil,
    content_buf = nil,
    content_win = nil,
    status_buf = nil,
    status_win = nil,
  }, Surface)
end

---@param opts? kak.ui.surface.SurfaceOpenOpts
function Surface:open(opts)
  opts = opts or {}
  if opts.rpc then self.rpc = opts.rpc end
  if opts.session then self.session = opts.session end

  self.content_buf = vim.api.nvim_create_buf(false, true)

  vim.bo[self.content_buf].bufhidden = 'wipe'
  vim.bo[self.content_buf].swapfile = false
  vim.bo[self.content_buf].buftype = 'nofile'
  vim.bo[self.content_buf].filetype = 'kak-ui'

  -- TODO(preserve-existing-buffer): decide whether the current window
  -- already shows an empty, unlisted, ft-empty buffer. If so we reuse
  -- it so :Kak does not leave a stray empty split behind. The check
  -- requires peek at lines + buflisted + filetype; if any of them does
  -- not match we open a new tab so the user's layout is preserved.
  local cur_win = vim.api.nvim_get_current_win()
  local cur_buf = vim.api.nvim_win_get_buf(cur_win)
  local can_reuse = cur_buf ~= self.content_buf
  if can_reuse then
    local lines = vim.api.nvim_buf_get_lines(cur_buf, 0, -1, false)
    local listed = vim.bo[cur_buf].buflisted
    local ft = vim.bo[cur_buf].filetype
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

  self.content_win = keeper
  if vim.api.nvim_win_get_buf(keeper) ~= self.content_buf then
    vim.api.nvim_win_set_buf(keeper, self.content_buf)
  end

  -- The buffer was just created unlisted; nvim_buf_set_name is a
  -- straight setter and does not fail in normal flow.
  vim.api.nvim_buf_set_name(self.content_buf, bufname(self.session))

  -- laststatus=0: we render our OWN statusline in a float, so nvim
  -- must not draw its own statusline on top of it. cmdheight=0 keeps
  -- the nvim cmdline out of the way; showtabline=0 hides the tabline.
  self.saved = {
    showtabline = vim.o.showtabline,
    laststatus = vim.o.laststatus,
    cmdheight = vim.o.cmdheight,
  }
  vim.o.showtabline = 0
  vim.o.laststatus = 0
  vim.o.cmdheight = 0

  self:ensure_status_float()
end

--- Open the status float (1 row at the bottom of the editor). Safe to
--- call repeatedly: bails out if the window + buffer are still valid.
function Surface:ensure_status_float()
  if
    self.status_win
    and vim.api.nvim_win_is_valid(self.status_win)
    and self.status_buf
    and vim.api.nvim_buf_is_valid(self.status_buf)
  then
    return
  end

  self.status_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[self.status_buf].bufhidden = 'wipe'
  vim.bo[self.status_buf].swapfile = false
  vim.bo[self.status_buf].buftype = 'nofile'
  vim.bo[self.status_buf].filetype = 'kak-ui-status'
  vim.bo[self.status_buf].modifiable = true

  local cols = vim.o.columns or 120
  local lines = vim.o.lines or 40

  -- Determine the float's row from the content window when available
  -- (its height equals the editor area when laststatus=0/cmdheight=0);
  -- fall back to the screen height otherwise.
  local row
  if self.content_win and vim.api.nvim_win_is_valid(self.content_win) then
    row = vim.api.nvim_win_get_height(self.content_win) - 1
    cols = vim.api.nvim_win_get_width(self.content_win)
  else
    row = lines - 1
  end
  if row < 0 then row = 0 end

  self.status_win = vim.api.nvim_open_win(self.status_buf, false, {
    relative = 'editor',
    row = row,
    col = 0,
    width = cols,
    height = 1,
    border = 'none',
    focusable = false,
    style = 'minimal',
    noautocmd = true,
  })
end

function Surface:close()
  -- Restore global options that `open` mutated. Guard nil so close is
  -- safe to call before open (or twice).
  if self.saved then
    vim.o.showtabline = self.saved.showtabline
    vim.o.laststatus = self.saved.laststatus
    vim.o.cmdheight = self.saved.cmdheight
    self.saved = nil
  end
  -- Tear down the status float first; the buffer's bufhidden=wipe
  -- handles cleanup once its only window closes.
  if self.status_win and vim.api.nvim_win_is_valid(self.status_win) then
    pcall(vim.api.nvim_win_close, self.status_win, true)
  end
  self.status_win = nil
  self.status_buf = nil
  -- Detach: drop our references to the buffers/window. The window itself
  -- stays open so external code (e.g. screen tests) can keep observing
  -- the rendered buffer; bufhidden=wipe handles cleanup when nvim
  -- eventually unloads the buffers. Connection terminate is driven by
  -- the VimLeavePre autocmd installed in init.lua.
  self.content_win = nil
  self.content_buf = nil
  self.rpc = nil
end

--- Notify Kakoune of the current editor area and reposition the
--- status float to track the new dimensions.
function Surface:report_resize()
  local win = self.content_win
  if not win or not vim.api.nvim_win_is_valid(win) then return end
  if not self.rpc or self.rpc:is_closing() then return end
  local cols = vim.api.nvim_win_get_width(win)
  -- The status float overlays the last content row; the editor area
  -- reported to kak is therefore content_win height minus 1.
  local rows = vim.api.nvim_win_get_height(win) - 1
  if rows < 1 then rows = 1 end
  self.rpc:notify('resize', { rows, cols })
  self:ensure_status_float()
  if self.status_win and vim.api.nvim_win_is_valid(self.status_win) then
    pcall(vim.api.nvim_win_set_config, self.status_win, {
      relative = 'editor',
      row = rows,
      col = 0,
      width = cols,
      height = 1,
    })
  end
end

function Surface:focus()
  local win = self.content_win
  if not win or not vim.api.nvim_win_is_valid(win) then return end
  vim.api.nvim_set_current_win(win)
end

---@return { width: integer, height: integer }
function Surface:editor_dims()
  local win = self.content_win
  if not win or not vim.api.nvim_win_is_valid(win) then
    return { width = vim.o.columns or 120, height = (vim.o.lines or 40) - 1 }
  end
  return {
    width = vim.api.nvim_win_get_width(win),
    height = math.max(1, vim.api.nvim_win_get_height(win) - 1),
  }
end

--- Translate a buffer-relative row to a 0-based screen row inside the
--- content window. Returns `nil` if the row is off-screen or the window
--- is gone.
---@param buf integer
---@param line integer 0-based buffer line
---@return integer?
function Surface:editor_row(buf, line)
  local win = self.content_win
  if not win or not vim.api.nvim_win_is_valid(win) then return nil end
  if vim.api.nvim_win_get_buf(win) ~= buf then return nil end
  local firstline = vim.api.nvim_win_firstline(win)
  local row_offset = vim.api.nvim_win_get_position(win)[1]
  return math.floor(row_offset + line - (firstline - 1))
end

---@param buf integer
---@param column integer
---@return integer?
function Surface:editor_col(buf, column)
  local win = self.content_win
  if not win or not vim.api.nvim_win_is_valid(win) then return nil end
  if vim.api.nvim_win_get_buf(win) ~= buf then return nil end
  local col_offset = vim.api.nvim_win_get_position(win)[2]
  return col_offset + column
end

return M
