---
--- Plugin logger singleton. Thin shim over `vim.log` (Neovim 0.12+
--- nightly). On older Neovim builds `vim.log.new` is missing, so the
--- shim falls back to a stub that forwards to `vim.notify` so messages
--- still surface via `:messages`.
---
--- Only the shared `M.log` instance and the `M.levels` constants are
--- exposed. Callers should not construct their own loggers; use the
--- singleton everywhere.
---

---@class kak.ui.log.Logger : vim.Log

local M = {}

---@enum kak.ui.log.Level
M.levels = {
  TRACE = 0,
  DEBUG = 1,
  INFO = 2,
  WARN = 3,
  ERROR = 4,
  OFF = 5,
}

---@type table<integer, string>
local LABEL = {
  [M.levels.TRACE] = 'TRACE',
  [M.levels.DEBUG] = 'DEBUG',
  [M.levels.INFO] = 'INFO',
  [M.levels.WARN] = 'WARN',
  [M.levels.ERROR] = 'ERROR',
}

local function has_real_log() return type(vim.log) == 'table' and type(vim.log.new) == 'function' end

local function make_logger()
  local threshold = M.levels.WARN
  local function emit(level, ...)
    if level < threshold then return end
    local msg = table.concat({ ... }, ' ')
    if msg == '' then return end
    vim.notify(string.format('[kak-ui][%s] %s', LABEL[level] or 'INFO', msg), level)
  end
  if has_real_log() then
    ---@diagnostic disable-next-line: param-type-mismatch
    local real = vim.log.new({ name = 'kak-ui', level = threshold })
    if type(real) == 'table' and type(real.set_level) == 'function' then
      real:set_level(threshold)
    end
    return real
  end
  ---@type kak.ui.log.Logger
  return {
    trace = function(...) emit(M.levels.TRACE, ...) end,
    debug = function(...) emit(M.levels.DEBUG, ...) end,
    info = function(...) emit(M.levels.INFO, ...) end,
    warn = function(...) emit(threshold, ...) end,
    error = function(...) emit(M.levels.ERROR, ...) end,
  }
end

---@type kak.ui.log.Logger
M.log = make_logger()

return M
