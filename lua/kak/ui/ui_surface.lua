---
--- Tab/window lifecycle for the Kakoune JSON-UI render area.
---
--- A `Surface` owns the two scratch buffers (content + mode) and the
--- window that displays them. It also handles the resize-reporting hook
--- so the render area stays in sync with `kak -ui json`.
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
---@field mode_buf integer?
---@field content_win integer?
---@field open fun(self: kak.ui.surface.Surface, opts?: kak.ui.surface.SurfaceOpenOpts)
---@field close fun(self: kak.ui.surface.Surface)
---@field report_resize fun(self: kak.ui.surface.Surface)
---@field focus fun(self: kak.ui.surface.Surface)
---@field editor_dims fun(self: kak.ui.surface.Surface): { width: integer, height: integer }
---@field editor_row fun(self: kak.ui.surface.Surface, buf: integer, line: integer): integer?
---@field editor_col fun(self: kak.ui.surface.Surface, buf: integer, column: integer): integer?

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
    mode_buf = nil,
    content_win = nil,
  }, Surface)
end

---@param opts? kak.ui.surface.SurfaceOpenOpts
function Surface:open(opts)
  opts = opts or {}
  if opts.rpc then self.rpc = opts.rpc end
  if opts.session then self.session = opts.session end

  self.content_buf = vim.api.nvim_create_buf(false, true)
  self.mode_buf = vim.api.nvim_create_buf(false, true)

  vim.bo[self.content_buf].bufhidden = 'wipe'
  vim.bo[self.content_buf].swapfile = false
  vim.bo[self.content_buf].buftype = 'nofile'
  vim.bo[self.content_buf].filetype = 'kak-ui'
  vim.bo[self.mode_buf].bufhidden = 'wipe'
  vim.bo[self.mode_buf].swapfile = false

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
end

function Surface:close()
  -- Detach: drop our references to the buffers/window. The window itself
  -- stays open so external code (e.g. screen tests) can keep observing
  -- the rendered buffer; bufhidden=wipe handles cleanup when nvim
  -- eventually unloads the buffers. Connection terminate is driven by
  -- the VimLeavePre autocmd installed in init.lua.
  self.content_win = nil
  self.content_buf = nil
  self.mode_buf = nil
  self.rpc = nil
end

function Surface:report_resize()
  local win = self.content_win
  if not win or not vim.api.nvim_win_is_valid(win) then return end
  if not self.rpc or self.rpc:is_closing() then return end
  local rows = vim.api.nvim_win_get_height(win)
  local cols = vim.api.nvim_win_get_width(win)
  self.rpc:notify('resize', { rows, cols })
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
    return { width = vim.o.columns or 120, height = vim.o.lines or 40 }
  end
  return {
    width = vim.api.nvim_win_get_width(win),
    height = vim.api.nvim_win_get_height(win),
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
