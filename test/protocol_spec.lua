-- Tests for protocol parsing utilities (pure) and handler dispatch
-- (parsing + side effects). After the protocol.HANDLERS refactor,
-- the per-method dispatch lives in handlers.lua; this file exercises
-- both layers.

local h = require('test.helpers')

local function with_handlers(body_src)
  return h.exec_lua(function(src)
    local Handlers = require('kak.ui.handlers')
    local function rec(t, name, ...) t.calls[#t.calls + 1] = { name, ... } end
    local renderer = { calls = {}, content_buf = nil, mode_buf = nil }
    function renderer:draw(...) rec(self, 'draw', ...) end
    function renderer:draw_mode(...) rec(self, 'draw_mode', ...) end
    function renderer:set_prompt(...) rec(self, 'set_prompt', ...) end
    function renderer:set_buf(b) self.content_buf = b end
    function renderer:set_mode_buf(b) self.mode_buf = b end
    local popups = { calls = {} }
    function popups:menu_show(...) rec(self, 'menu_show', ...) end
    function popups:menu_select(...) rec(self, 'menu_select', ...) end
    function popups:menu_hide() rec(self, 'menu_hide') end
    function popups:info_show(...) rec(self, 'info_show', ...) end
    function popups:info_hide() rec(self, 'info_hide') end
    Handlers.renderer = renderer
    Handlers.popups = popups
    Handlers.ctx = { ui_options = {}, last_force = false }
    Handlers.ui_options = {}
    Handlers.surface = nil
    Handlers.faces = nil
    _G.Handlers = Handlers
    local body = assert(loadstring(src))
    body()
    _G.Handlers = nil
    return { renderer = renderer.calls, popups = popups.calls }
  end, body_src)
end

local function with_protocol(body_src)
  return h.exec_lua(function(src)
    local P = require('kak.ui.protocol')
    _G.P = P
    local body = assert(loadstring(src))
    local out = body()
    _G.P = nil
    return out
  end, body_src)
end

describe('protocol.parse_* utilities', function()
  before_each(function() h.setup() end)

  it('parse_face: absent (nil) -> nil', function()
    local out = with_protocol([[ return P.parse_face('t', nil, 1) ]])
    h.eq(nil, out)
  end)

  it('parse_face: vim.NIL -> nil (JSON null)', function()
    local out = with_protocol([[ return P.parse_face('t', vim.NIL, 1) ]])
    h.eq(nil, out)
  end)

  it('parse_face: "default" face fields -> nil', function()
    local out = with_protocol([[
      return P.parse_face('t', { fg = 'default', bg = 'default', underline = 'default', attributes = {} }, 1)
    ]])
    h.eq(nil, out.fg)
    h.eq(nil, out.bg)
    h.eq(nil, out.underline)
  end)

  it('parse_face: rgb: prefix -> #hex', function()
    local out = with_protocol([[
      return P.parse_face('t', { fg = 'rgb:ebdbb2', bg = 'default', underline = 'default', attributes = {} }, 1)
    ]])
    h.eq('#ebdbb2', out.fg)
  end)

  it('parse_line: each atom becomes { face=typed, contents=... }', function()
    local out = with_protocol([[
      return P.parse_line('t', {
        { face = { fg = 'default', bg = 'default', underline = 'default', attributes = {} }, contents = 'a' },
        { face = { fg = 'rgb:ebdbb2', bg = 'default', underline = 'default', attributes = {} }, contents = 'b' },
      }, 1)
    ]])
    h.eq(2, #out)
    h.eq('a', out[1].contents)
    h.eq('b', out[2].contents)
  end)

  it('parse_coord: validates line/column are numbers', function()
    local out = with_protocol([[ return P.parse_coord('t', { line = 0, column = 5 }, 1) ]])
    h.eq(0, out.line)
    h.eq(5, out.column)
  end)

  it('check_enum: rejects unknown values', function()
    local ok = pcall(
      function() with_protocol([[ P.check_enum('t', 'bogus', { ok = true }, 1) ]]) end
    )
    h.eq(false, ok)
  end)
end)

describe('handler dispatch (kakoune 2026.05+)', function()
  before_each(function() h.setup() end)

  it('draw parses lines, cursor, faces and dispatches to renderer:draw', function()
    local res = with_handlers([[
      Handlers:draw({
        { { { face = { fg = 'rgb:ebdbb2', bg = 'rgb:282828', underline = 'default', attributes = {} },
              contents = 'hello' } } },
        { line = 0, column = 5 },
        { fg = 'default', bg = 'default', underline = 'default', attributes = {} },
        { fg = 'default', bg = 'default', underline = 'default', attributes = {} },
        0,
      })
    ]])
    h.eq(1, #res.renderer)
    h.eq('draw', res.renderer[1][1])
    local lines = res.renderer[1][2]
    h.eq('#ebdbb2', lines[1][1].face.fg)
    h.eq('#282828', lines[1][1].face.bg)
    local cursor = res.renderer[1][3]
    h.eq(0, cursor.line)
    h.eq(5, cursor.column)
  end)

  it('draw_status dispatches draw_mode + set_prompt with typed args', function()
    local res = with_handlers([[
      Handlers:draw_status({
        { { face = { fg = 'rgb:ebdbb2', bg = 'default', underline = 'default', attributes = {} },
            contents = ':' } },
        { { face = { fg = 'default', bg = 'default', underline = 'default', attributes = {} },
            contents = 'hello' } },
        1,
        { { face = { fg = 'rgb:282828', bg = 'rgb:ebdbb2', underline = 'default', attributes = {} },
            contents = 'NORMAL' } },
        { fg = 'default', bg = 'default', underline = 'default', attributes = {} },
        'command',
      })
    ]])
    h.eq(2, #res.renderer)
    h.eq('draw_mode', res.renderer[1][1])
    h.eq('NORMAL', res.renderer[1][2][1].contents)
    h.eq('set_prompt', res.renderer[2][1])
    h.eq(':', res.renderer[2][2][1].contents)
    h.eq('hello', res.renderer[2][3][1][1].contents)
    h.eq(1, res.renderer[2][4])
    h.eq('command', res.renderer[2][6])
  end)

  it('menu_show dispatches to popups:menu_show with typed args', function()
    local res = with_handlers([[
      Handlers:menu_show({
        { { { face = { fg = 'default', bg = 'default', underline = 'default', attributes = {} },
              contents = 'opt' } } },
        { line = 3, column = 2 },
        { fg = 'rgb:000000', bg = 'rgb:ffffff', underline = 'default', attributes = {} },
        { fg = 'rgb:ffffff', bg = 'rgb:282828', underline = 'default', attributes = {} },
        'inline',
      })
    ]])
    h.eq(1, #res.popups)
    h.eq('menu_show', res.popups[1][1])
    h.eq(1, #res.popups[1][2])
    h.eq('#000000', res.popups[1][4].fg)
    h.eq('inline', res.popups[1][6])
  end)

  it(
    'refresh sets ctx.last_force from boolean',
    function()
      with_handlers([[
      Handlers.ctx.last_force = false
      Handlers:refresh({ true })
      assert(Handlers.ctx.last_force == true)
    ]])
    end
  )

  it('rejects bad status style', function()
    local ok = pcall(
      function()
        with_handlers([[
        Handlers:draw_status({
          {},
          {},
          -1,
          {},
          { fg = 'default', bg = 'default', underline = 'default', attributes = {} },
          'unknown-style',
        })
      ]])
      end
    )
    h.eq(false, ok)
  end)

  it('tolerates vim.NIL face fields (JSON null) in draw_status', function()
    local res = with_handlers([[
      Handlers:draw_status({
        { { face = vim.NIL, contents = '' } },
        { { face = vim.NIL, contents = '' } },
        -1,
        { { face = vim.NIL, contents = '' } },
        { fg = vim.NIL, bg = vim.NIL, underline = vim.NIL, attributes = vim.NIL },
        'status',
      })
    ]])
    h.eq(2, #res.renderer)
    h.eq('status', res.renderer[2][6])
  end)

  it('tolerates draw with vim.NIL face args (no crash, dispatch happens)', function()
    local res = with_handlers([[
      Handlers:draw({
        { { face = vim.NIL, contents = 'a' } },
        { line = 0, column = 0 },
        vim.NIL,
        vim.NIL,
        0,
      })
    ]])
    h.eq(1, #res.renderer)
    h.eq('draw', res.renderer[1][1])
  end)

  it('menu_select rejects non-int', function()
    local ok = pcall(function() with_handlers([[ Handlers:menu_select({ 'not an int' }) ]]) end)
    h.eq(false, ok)
  end)
end)
