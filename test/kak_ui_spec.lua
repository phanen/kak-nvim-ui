local h = require('test.helpers')

describe('ndjson framing', function()
  before_each(function() h.setup() end)

  --- Drive `_ndjson_feed` directly. `h.exec_lua` returns both the parsed
  --- line list and the trailing partial buffer, so we can chain feeds.
  local function feed(chunk)
    return h.exec_lua(function(c)
      local buf = vim.g._kak_test_buf or ''
      local r = {}
      buf = require('kak.ui.json_rpc')._ndjson_feed(buf, c, function(line) r[#r + 1] = line end)
      vim.g._kak_test_buf = buf
      return r
    end, chunk)
  end

  before_each(function()
    h.exec_lua(function() vim.g._kak_test_buf = '' end)
  end)

  it('splits single complete line', function()
    local r = feed('{"a":1}\n')
    h.eq(1, #r)
    h.eq('{"a":1}', r[1])
  end)

  it('splits multiple lines in one chunk', function()
    local r = feed('{"a":1}\n{"b":2}\n')
    h.eq(2, #r)
    h.eq('{"a":1}', r[1])
    h.eq('{"b":2}', r[2])
  end)

  it('handles partial line completion', function()
    local r = feed('{"a":')
    h.eq(0, #r)
    r = feed('1}\n')
    h.eq(1, #r)
    h.eq('{"a":1}', r[1])
  end)

  it('handles \\r\\n', function()
    local r = feed('{"a":1}\r\n')
    h.eq(1, #r)
    h.eq('{"a":1}', r[1])
  end)

  it('ignores empty lines', function()
    local r = feed('\n\n{"a":1}\n\n')
    h.eq(1, #r)
    h.eq('{"a":1}', r[1])
  end)

  it('handles UTF-8 split across chunks', function()
    local r = feed('{"s":"hé')
    h.eq(0, #r)
    r = feed('llo"}\n')
    h.eq(1, #r)
    h.eq('{"s":"héllo"}', r[1])
  end)
end)

describe('column to byte', function()
  before_each(function() end)

  it('converts codepoint column to byte offset (ASCII)', function()
    local r = h.exec_lua(
      function()
        return {
          require('kak.ui.render').column_to_byte('hello', 0),
          require('kak.ui.render').column_to_byte('hello', 3),
          require('kak.ui.render').column_to_byte('hello', 5),
          require('kak.ui.render').column_to_byte('hello', 99),
        }
      end
    )
    h.eq(0, r[1])
    h.eq(3, r[2])
    h.eq(5, r[3])
    h.eq(5, r[4])
  end)

  it('converts codepoint column to byte offset (UTF-8 2-byte)', function()
    local r = h.exec_lua(
      function()
        return {
          require('kak.ui.render').column_to_byte('héllo', 1),
          require('kak.ui.render').column_to_byte('héllo', 2),
          require('kak.ui.render').column_to_byte('héllo', 3),
          require('kak.ui.render').column_to_byte('héllo', 5),
        }
      end
    )
    h.eq(1, r[1])
    h.eq(3, r[2])
    h.eq(4, r[3])
    h.eq(6, r[4])
  end)

  it('handles CJK 3-byte codepoints', function()
    local r = h.exec_lua(
      function()
        return {
          require('kak.ui.render').column_to_byte('中文', 0),
          require('kak.ui.render').column_to_byte('中文', 1),
          require('kak.ui.render').column_to_byte('中文', 2),
        }
      end
    )
    h.eq(0, r[1])
    h.eq(3, r[2])
    h.eq(6, r[3])
  end)
end)

describe('face cache', function()
  before_each(function() end)

  it('returns stable names for equal faces', function()
    local a, b = h.exec_lua(function()
      local faces = require('kak.ui.faces').new()
      return faces:get({
        fg = 'red',
        bg = 'default',
        underline = 'default',
        attributes = { 'bold' },
      }),
        faces:get({
          fg = 'red',
          bg = 'default',
          underline = 'default',
          attributes = { 'bold' },
        })
    end)
    h.eq(a, b)
  end)

  it('returns different names for different faces', function()
    local a, b = h.exec_lua(function()
      local faces = require('kak.ui.faces').new()
      return faces:get({
        fg = 'red',
        bg = 'default',
        underline = 'default',
        attributes = { 'bold' },
      }),
        faces:get({
          fg = 'red',
          bg = 'blue',
          underline = 'default',
          attributes = { 'bold' },
        })
    end)
    assert(a ~= b, 'expected different groups')
  end)

  it('maps Kakoune attributes to nvim hl', function()
    local v = h.exec_lua(
      function()
        return require('kak.ui.faces').face_to_val({
          fg = 'red',
          bg = 'blue',
          underline = 'green',
          attributes = { 'underline', 'italic', 'reverse' },
        })
      end
    )
    h.eq('#cc0000', v.fg)
    h.eq('#3465a4', v.bg)
    h.eq('#00cc00', v.sp)
    h.eq(true, v.underline)
    h.eq(true, v.italic)
    h.eq(true, v.reverse)
  end)
end)

describe('input key translation', function()
  before_each(function() end)

  it('passes bare printable', function()
    local r = h.exec_lua(
      function()
        return {
          require('kak.ui.input').nvim_to_kak('j'),
          require('kak.ui.input').nvim_to_kak('a'),
        }
      end
    )
    h.eq('j', r[1])
    h.eq('a', r[2])
  end)

  it('translates special keys', function()
    local r = h.exec_lua(
      function()
        return {
          require('kak.ui.input').nvim_to_kak('<CR>'),
          require('kak.ui.input').nvim_to_kak('<Tab>'),
          require('kak.ui.input').nvim_to_kak('<Esc>'),
          require('kak.ui.input').nvim_to_kak('<Up>'),
        }
      end
    )
    h.eq('<ret>', r[1])
    h.eq('<tab>', r[2])
    h.eq('<esc>', r[3])
    h.eq('<up>', r[4])
  end)

  it('lowercases modifier prefix', function()
    local r = h.exec_lua(
      function()
        return {
          require('kak.ui.input').nvim_to_kak('<C-A>'),
          require('kak.ui.input').nvim_to_kak('<c-a>'),
          require('kak.ui.input').nvim_to_kak('<S-Tab>'),
        }
      end
    )
    h.eq('<c-a>', r[1])
    h.eq('<c-a>', r[2])
    h.eq('<s-tab>', r[3])
  end)

  it('raw_to_kak with on_key-style typed string', function()
    local r = h.exec_lua(function() return require('kak.ui.input').raw_to_kak('<CR>j') end)
    h.eq(2, #r)
    h.eq('<ret>', r[1])
    h.eq('j', r[2])
  end)

  it('raw_to_kak converts <C-H>', function()
    local r = h.exec_lua(function() return require('kak.ui.input').raw_to_kak('<C-H>') end)
    h.eq(1, #r)
    h.eq('<c-h>', r[1])
  end)

  it('from_on_key translates raw <Esc> byte to <esc>', function()
    local r = h.exec_lua(function() return require('kak.ui.input').from_on_key('\27') end)
    h.eq(1, #r)
    h.eq('<esc>', r[1])
  end)

  it('from_on_key translates raw <CR> byte to <ret>', function()
    local r = h.exec_lua(function() return require('kak.ui.input').from_on_key('\r') end)
    h.eq(1, #r)
    h.eq('<ret>', r[1])
  end)

  it('from_on_key translates raw <Tab> byte to <tab>', function()
    local r = h.exec_lua(function() return require('kak.ui.input').from_on_key('\t') end)
    h.eq(1, #r)
    h.eq('<tab>', r[1])
  end)

  it('from_on_key translates raw <Up> bytes (<80>ku) to <up>', function()
    local r = h.exec_lua(function()
      local up_internal = vim.api.nvim_replace_termcodes('<Up>', true, false, true)
      return require('kak.ui.input').from_on_key(up_internal)
    end)
    h.eq(1, #r)
    h.eq('<up>', r[1])
  end)

  it('from_on_key translates raw Ctrl-A (<1>) to <c-a>', function()
    local r = h.exec_lua(function() return require('kak.ui.input').from_on_key('\x01') end)
    h.eq(1, #r)
    h.eq('<c-a>', r[1])
  end)

  it('from_on_key returns empty for nil/empty input', function()
    local r = h.exec_lua(function()
      local m = require('kak.ui.input')
      return { #m.from_on_key(nil), #m.from_on_key(''), #m.from_on_key(' ') }
    end)
    h.eq(0, r[1])
    h.eq(0, r[2])
    h.eq(1, r[3])
  end)

  it('end-to-end: keytrans + raw_to_kak yields correct kak keys', function()
    local r = h.exec_lua(function()
      local m = require('kak.ui.input')
      -- The actual user-typing scenario: typed bytes come from on_key,
      -- get passed through keytrans, then translated to kak.
      local out = {}
      for _, k in ipairs({ '<Esc>', '<CR>', '<Tab>', '<C-a>', '<Up>', '<Down>', '<Backspace>' }) do
        local raw = vim.api.nvim_replace_termcodes(k, true, false, true)
        local notation = vim.fn.keytrans(raw)
        local kak = m.raw_to_kak(notation)
        out[#out + 1] = { input = k, notation = notation, kak = kak }
      end
      return out
    end)
    h.eq('<esc>', r[1].kak[1])
    h.eq('<ret>', r[2].kak[1])
    h.eq('<tab>', r[3].kak[1])
    h.eq('<c-a>', r[4].kak[1])
    h.eq('<up>', r[5].kak[1])
    h.eq('<down>', r[6].kak[1])
    h.eq('<backspace>', r[7].kak[1])
  end)
end)

describe('end-to-end rpc over uv pipe', function()
  before_each(function() end)

  it('round-trips a notification from fake-server', function()
    local fake_path = h.write_executable([[
      printf '{"jsonrpc":"2.0","method":"set_ui_options","params":[{"foo":"bar"}]}\n'
      sleep 5
    ]])

    local ok, recv = pcall(function()
      return h.exec_lua(function(fake)
        local rpc = require('kak.ui.json_rpc')
        local recv = 'unset'
        local conn = rpc.spawn({ fake }, {
          log_level = 'error',
          dispatchers = {
            on_notify = function(method, params)
              if method == 'set_ui_options' then recv = params end
            end,
            on_request = function() end,
            on_exit = function() end,
            on_error = function() end,
          },
        })
        vim.wait(3000, function() return recv ~= 'unset' or conn:is_closing() end)
        conn:terminate()
        vim.wait(100)
        return recv
      end, fake_path)
    end)
    os.remove(fake_path)
    h.eq(true, ok)
    h.eq('table', type(recv))
    if type(recv) == 'table' then h.eq('bar', recv[1] and recv[1].foo) end
  end)
end)
