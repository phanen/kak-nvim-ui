-- Tests that exercise real `kak -ui json` against a file with a real
-- `.lua` extension, so Kakoune's filetype detection fires and the
-- built-in lua highlighter attaches. Earlier specs used `tempname()`
-- paths that lacked an extension, so `BufCreate .*[.](lua|rockspec)`
-- never matched and every atom came back as `default/default` -- a
-- fixture bug, not a wire/protocol issue.
--
-- Run:
--   make test FILTER='real.kak.lua'

local h = require('test.helpers')

local LUA_BODY = table.concat({
  '-- Sample lua file for real-kak payload tests.',
  'local M = {}',
  '',
  'function M.greet(name)',
  "  return 'hello, ' .. name",
  'end',
  '',
  'return M',
  '',
}, '\n')

local NIL_VALUE = vim.NIL or setmetatable({}, { __tostring = function() return 'NIL' end })

local function nil_norm(v)
  if v == NIL_VALUE then return nil end
  if type(v) == 'table' then
    local out = {}
    for k, val in pairs(v) do
      out[k] = nil_norm(val)
    end
    return out
  end
  return v
end

local function face_eq(a, b)
  if a == b then return true end
  if type(a) ~= 'table' or type(b) ~= 'table' then return false end
  return vim.deep_equal(nil_norm(a), nil_norm(b))
end

local function has_color(face)
  if type(face) ~= 'table' then return false end
  local function colored(c) return type(c) == 'string' and c ~= 'default' end
  return colored(face.fg) or colored(face.bg)
end

---@param cap {{ method: string, params: any[] }}
---@return any[]?
local function first_draw_params(cap)
  for _, m in ipairs(cap) do
    if m.method == 'draw' and type(m.params) == 'table' and #m.params >= 5 then return m.params end
  end
end

---@param lines any[]
---@return integer total_atoms, integer atoms_with_rgb
local function count_atoms(lines)
  local total, with_color = 0, 0
  for _, line in ipairs(lines or {}) do
    for _, atom in ipairs(line or {}) do
      if type(atom) == 'table' then
        total = total + 1
        if has_color(atom.face) then with_color = with_color + 1 end
      end
    end
  end
  return total, with_color
end

local function write_sample_lua()
  local dir = h.fn.tempname()
  h.fn.mkdir(dir, 'p')
  local path = dir .. '/sample.lua'
  local f = assert(io.open(path, 'w'))
  f:write(LUA_BODY)
  f:close()
  return path, dir
end

describe('real kak lua filetype', function()
  before_each(function() h.setup() end)

  it('wire carries RGB faces for an opened .lua file', function()
    local file, dir = write_sample_lua()
    finally(function() h.rmdir(dir) end)

    local captured = h.with_kak_session({
      cmd = { h.kak_path() },
      extra_args = { '-e', 'edit ' .. file },
    }, function(sess)
      local cap = {}
      local orig = sess.conn.dispatchers.on_notify
      sess.conn.dispatchers.on_notify = function(method, params)
        cap[#cap + 1] = { method = method, params = params }
        return orig(method, params)
      end
      vim.wait(3000, function()
        for _, m in ipairs(cap) do
          if m.method == 'draw' then return true end
        end
        return false
      end)
      return cap
    end)

    local params = first_draw_params(captured)
    assert(params, 'expected at least one draw notification from real kak')

    local total, with_color = count_atoms(params[1])
    assert(total > 0, 'no atoms in the draw payload')
    assert(
      with_color > 0,
      (
        'lua highlighter did not attach: 0/%d atoms '
        .. 'carry non-default colors -- filetype detection likely did not fire '
        .. 'on the file path %q'
      ):format(total, file)
    )
  end)

  it('plugin registers hl_groups in the global namespace, not a private one', function()
    local file, dir = write_sample_lua()
    finally(function() h.rmdir(dir) end)

    local result = h.with_kak_session({
      cmd = { h.kak_path() },
      extra_args = { '-e', 'edit ' .. file },
    }, function(sess)
      local cap = {}
      local orig = sess.conn.dispatchers.on_notify
      sess.conn.dispatchers.on_notify = function(method, params)
        cap[#cap + 1] = { method = method, params = params }
        return orig(method, params)
      end
      vim.wait(3000, function()
        for _, m in ipairs(cap) do
          if m.method == 'draw' then return true end
        end
        return false
      end)

      local content_ns = vim.api.nvim_create_namespace('kak.ui.render.content')
      local marks = vim.api.nvim_buf_get_extmarks(sess.buf, content_ns, 0, -1, { details = true })

      local groups = {}
      for _, m in ipairs(marks) do
        local hl = (m[4] or {}).hl_group
        if hl and not groups[hl] then
          local def = vim.api.nvim_get_hl(0, { name = hl, link = false })
          groups[hl] = def
        end
      end

      return {
        extmarks = #marks,
        groups = groups,
      }
    end)

    local groups_with_color = 0
    for _, def in pairs(result.groups) do
      if (def.fg or def.foreground) or (def.bg or def.background) then
        groups_with_color = groups_with_color + 1
      end
    end

    assert(
      result.extmarks > 1,
      ('render.lua only set %d extmark(s); expected many for a multi-line ' .. 'lua file'):format(
        result.extmarks
      )
    )
    assert(
      groups_with_color > 0,
      (
        'no registered hl_group carries fg or bg; render.lua is writing '
        .. 'hl_groups to a non-global namespace so extmarks in '
        .. 'kak.ui.render.content cannot resolve them -- '
        .. 'extmarks=%d groups=%d'
      ):format(result.extmarks, vim.tbl_count(result.groups))
    )
  end)
end)
