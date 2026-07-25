-- Tests for the Kakoune JSON-UI protocol decoder.
-- Uses `exec_lua(fn)` form so we pass a Lua function rather than a
-- serialized string. nvim-test supports passing a function and
-- captures simple return values.

local helpers = require('nvim-test.helpers')
local exec_lua = helpers.exec_lua
local eq = helpers.eq
local clear = helpers.clear

describe('protocol decode (kakoune 2026.05+)', function()
  before_each(function()
    clear()
    exec_lua(function() vim.opt.rtp:append(vim.fn.getcwd()) end)
  end)

  it('decodes draw with cursor_pos and widget_columns', function()
    local res = exec_lua(
      function()
        return require('kak.ui.protocol').decode({
          jsonrpc = '2.0',
          method = 'draw',
          params = {
            {
              {
                {
                  face = {
                    fg = 'rgb:ebdbb2',
                    bg = 'rgb:282828',
                    underline = 'default',
                    attributes = {},
                  },
                  contents = 'hello',
                },
              },
            },
            { line = 0, column = 5 },
            { fg = 'default', bg = 'default', underline = 'default', attributes = {} },
            { fg = 'default', bg = 'default', underline = 'default', attributes = {} },
            0,
          },
        })
      end
    )
    eq('draw', res.method)
    eq(0, res.params.cursor_pos.line)
    eq(5, res.params.cursor_pos.column)
    eq(0, res.params.widget_columns)
    eq('#ebdbb2', res.params.lines[1][1].face.fg)
    eq('#282828', res.params.lines[1][1].face.bg)
  end)

  it(
    'decodes draw_status with prompt, content, cursor_pos, mode_line, default_face, style',
    function()
      local res = exec_lua(
        function()
          return require('kak.ui.protocol').decode({
            jsonrpc = '2.0',
            method = 'draw_status',
            params = {
              {
                {
                  face = {
                    fg = 'rgb:ebdbb2',
                    bg = 'default',
                    underline = 'default',
                    attributes = {},
                  },
                  contents = ':',
                },
              },
              {
                {
                  face = { fg = 'default', bg = 'default', underline = 'default', attributes = {} },
                  contents = 'hello',
                },
              },
              1,
              {
                {
                  face = {
                    fg = 'rgb:282828',
                    bg = 'rgb:ebdbb2',
                    underline = 'default',
                    attributes = {},
                  },
                  contents = 'NORMAL',
                },
              },
              { fg = 'default', bg = 'default', underline = 'default', attributes = {} },
              'command',
            },
          })
        end
      )
      eq('command', res.params.style)
      eq(':', res.params.prompt[1].contents)
      eq('hello', res.params.content[1].contents)
      eq(1, res.params.cursor_pos)
      eq('NORMAL', res.params.mode_line[1].contents)
    end
  )

  it('decodes menu_show', function()
    local res = exec_lua(
      function()
        return require('kak.ui.protocol').decode({
          jsonrpc = '2.0',
          method = 'menu_show',
          params = {
            {
              {
                {
                  face = { fg = 'default', bg = 'default', underline = 'default', attributes = {} },
                  contents = 'opt',
                },
              },
            },
            { line = 3, column = 2 },
            { fg = 'rgb:000000', bg = 'rgb:ffffff', underline = 'default', attributes = {} },
            { fg = 'rgb:ffffff', bg = 'rgb:282828', underline = 'default', attributes = {} },
            'inline',
          },
        })
      end
    )
    eq('inline', res.params.style)
    eq(1, #res.params.items)
    eq('#000000', res.params.fg.fg)
  end)

  it('decodes refresh', function()
    local res = exec_lua(
      function()
        return require('kak.ui.protocol').decode({
          jsonrpc = '2.0',
          method = 'refresh',
          params = { true },
        })
      end
    )
    eq(true, res.params.force)
  end)

  it('rejects unknown method', function()
    local ok = pcall(function()
      exec_lua(
        function()
          require('kak.ui.protocol').decode({
            jsonrpc = '2.0',
            method = 'set_cursor',
            params = { 'buffer', { line = 0, column = 0 } },
          })
        end
      )
    end)
    -- `set_cursor` was removed in kakoune 2026.
    eq(false, ok)
  end)

  it('rejects bad status style', function()
    local ok = pcall(function()
      exec_lua(
        function()
          require('kak.ui.protocol').decode({
            jsonrpc = '2.0',
            method = 'draw_status',
            params = {
              {},
              {},
              -1,
              {},
              { fg = 'default', bg = 'default', underline = 'default', attributes = {} },
              'unknown-style',
            },
          })
        end
      )
    end)
    eq(false, ok)
  end)

  it('rejects bad jsonrpc version', function()
    local ok = pcall(function()
      exec_lua(
        function()
          require('kak.ui.protocol').decode({
            jsonrpc = '1.0',
            method = 'draw',
            params = {},
          })
        end
      )
    end)
    eq(false, ok)
  end)

  it('tolerates vim.NIL face fields (JSON null)', function()
    local res = exec_lua(
      function()
        return require('kak.ui.protocol').decode({
          jsonrpc = '2.0',
          method = 'draw_status',
          params = {
            { { face = vim.NIL, contents = '' } },
            { { face = vim.NIL, contents = '' } },
            -1,
            { { face = vim.NIL, contents = '' } },
            { fg = vim.NIL, bg = vim.NIL, underline = vim.NIL, attributes = vim.NIL },
            'status',
          },
        })
      end
    )
    eq('status', res.params.style)
    eq(nil, res.params.default_face.fg)
    eq(nil, res.params.default_face.bg)
    eq(0, #res.params.default_face.attributes)
  end)

  it('tolerates draw with vim.NIL faces', function()
    local res = exec_lua(
      function()
        return require('kak.ui.protocol').decode({
          jsonrpc = '2.0',
          method = 'draw',
          params = {
            { { { face = vim.NIL, contents = 'a' } } },
            { line = 0, column = 0 },
            vim.NIL,
            vim.NIL,
            0,
          },
        })
      end
    )
    eq(nil, res.params.default_face)
    eq(nil, res.params.padding_face)
  end)
end)
