---
--- Shared test helpers. Re-exports everything from `nvim-test.helpers`
--- so callers can `local h = require('test.helpers')` and access
--- `h.exec_lua`, `h.eq`, `h.clear`, etc. without a second require.
---
--- Adds project-specific conveniences: rtp setup for the test target
--- and tmp file helpers used by the fake-kak server tests.
---

local helpers = require('nvim-test.helpers')

local M = helpers

local exec_lua = helpers.exec_lua

--- Reset the test target nvim and append the project root to its
--- runtimepath so `require('kak.ui.*')` resolves in the child.
--- Call from `before_each`.
function M.setup()
  M.clear()
  exec_lua(function() vim.opt.rtp:append(vim.fn.getcwd()) end)
end

--- Write `body` to a fresh tmp file and chmod it executable. Used for
--- fake-kak shell scripts in rpc + integration tests. Caller is
--- responsible for `os.remove(path)` cleanup.
--- @param body string
--- @return string path
function M.write_executable(body)
  local path = M.fn.tempname()
  local f = assert(io.open(path, 'w'))
  f:write(body)
  f:close()
  assert(vim.uv.fs_chmod(path, tonumber('755', 8)))
  return path
end

--- Write `lines` joined with `\n` to a fresh tmp file. Caller is
--- responsible for `os.remove(path)` cleanup.
--- @param lines string[]
--- @return string path
function M.write_file(lines)
  local path = M.fn.tempname()
  local f = assert(io.open(path, 'w'))
  f:write(table.concat(lines, '\n') .. '\n')
  f:flush()
  f:close()
  return path
end

return M
