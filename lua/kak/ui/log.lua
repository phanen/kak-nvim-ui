---
--- File-backed plugin logger. Env vars read at module load:
---   KAK_UI_LOG_FILE  - override destination
---   KAK_UI_LOG_LEVEL - TRACE/DEBUG/INFO/WARN/ERROR/OFF
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

local function ensure_parent_dir(path)
  local dir = vim.fn.fnamemodify(path, ':h')
  if dir and dir ~= '' and dir ~= '.' then vim.fn.mkdir(dir, 'p') end
end

---@param name string
---@return string?
local function resolve_log_path(name)
  local override = os.getenv('KAK_UI_LOG_FILE')
  if override and override ~= '' then return override end
  if has_real_log() then
    return vim.fs.joinpath(vim.fn.stdpath('log'), name:lower() .. '.log')
  end
  return nil
end

---@return integer
local function resolve_level()
  local raw = os.getenv('KAK_UI_LOG_LEVEL')
  if raw and raw ~= '' then
    local upper = raw:upper()
    if M.levels[upper] ~= nil then return M.levels[upper] end
  end
  return M.levels.WARN
end

local function make_logger()
  local threshold = resolve_level()
  local path = resolve_log_path('kak-ui')

  if has_real_log() then
    local real = vim.log.new({ name = 'kak-ui', level = threshold })
    -- vim.log.new hard-codes stdpath('log')/<name>.log; reroute by
    -- clearing the cached handle so the next write opens the new path.
    if path and real.filename ~= path then
      real.filename = path
      real.logfile = nil
      real.openerr = nil
      ensure_parent_dir(path)
    end
    if type(real.set_level) == 'function' then real:set_level(threshold) end
    return real
  end

  -- Legacy: raw io.open sink. Handle stays open; flush per write.
  if not path then path = vim.fn.tempname() .. '-kak-ui.log' end
  ensure_parent_dir(path)
  local fh = assert(io.open(path, 'a'))

  local function emit(level, ...)
    if level < threshold then return end
    local argc = select('#', ...)
    if argc == 0 then return end
    local info = debug.getinfo(3, 'Sl')
    local header = string.format(
      '[%s][%s] %s:%s',
      LABEL[level] or 'INFO',
      os.date('%F %H:%M:%S'),
      info.short_src or '?',
      tostring(info.currentline or '?')
    )
    local parts = { header }
    for i = 1, argc do
      local arg = select(i, ...)
      parts[#parts + 1] = arg == nil and 'nil' or vim.inspect(arg, { newline = ' ', indent = '' })
    end
    fh:write(table.concat(parts, '\t') .. '\n')
    fh:flush()
  end

  ---@type kak.ui.log.Logger
  return {
    trace = function(...) emit(M.levels.TRACE, ...) end,
    debug = function(...) emit(M.levels.DEBUG, ...) end,
    info = function(...) emit(M.levels.INFO, ...) end,
    warn = function(...) emit(M.levels.WARN, ...) end,
    error = function(...) emit(M.levels.ERROR, ...) end,
  }
end

---@type kak.ui.log.Logger
M.log = make_logger()

return M
