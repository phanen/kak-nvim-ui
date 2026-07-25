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

describe('codepoint width', function()
  before_each(function() end)

  it('returns 1 byte for ASCII', function()
    local r = h.exec_lua(function()
      local m = require('kak.ui.render')
      return { m.codepoint_width('a', 0), m.codepoint_width('hello', 2) }
    end)
    h.eq(1, r[1])
    h.eq(1, r[2])
  end)

  it('returns 2 bytes for Latin-1 supplementary', function()
    local r = h.exec_lua(
      function() return require('kak.ui.render').codepoint_width('héllo', 1) end
    )
    h.eq(2, r)
  end)

  it('returns 3 bytes for CJK', function()
    local r = h.exec_lua(function()
      local m = require('kak.ui.render')
      return { m.codepoint_width('中文', 0), m.codepoint_width('中文', 3) }
    end)
    h.eq(3, r[1])
    h.eq(3, r[2])
  end)

  it('returns 1 for past end-of-line', function()
    local r = h.exec_lua(function()
      local m = require('kak.ui.render')
      return { m.codepoint_width('', 0), m.codepoint_width('a', 5), m.codepoint_width('a', -1) }
    end)
    h.eq(1, r[1])
    h.eq(1, r[2])
    h.eq(1, r[3])
  end)
end)

describe('cursor extmark visual width', function()
  before_each(function() h.setup() end)

  it('covers 1 byte under ASCII cursor', function()
    local r = h.exec_lua(function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'abc' })
      vim.bo[buf].modifiable = false
      local render = require('kak.ui.render').new({ faces = require('kak.ui.faces').new() })
      render:set_buf(buf)
      render:draw({
        { { face = nil, contents = 'abc' } },
      }, { line = 0, column = 1 }, nil, nil)
      -- ns = -1 returns extmarks from every namespace.
      local marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
      local cursor = nil
      for _, m in ipairs(marks) do
        local hl = m[4] and m[4].hl_group
        if hl and hl:match('^KakFace_') then cursor = m end
      end
      return { count = cursor and 1 or 0, end_col = cursor and cursor[4].end_col or -1 }
    end)
    h.eq(1, r.count)
    h.eq(2, r.end_col)
  end)

  it('covers 3 bytes under CJK cursor', function()
    local r = h.exec_lua(function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '中文' })
      vim.bo[buf].modifiable = false
      local render = require('kak.ui.render').new({ faces = require('kak.ui.faces').new() })
      render:set_buf(buf)
      -- column 0 = before the first char, so cursor covers bytes 0..3.
      render:draw({
        { { face = nil, contents = '中文' } },
      }, { line = 0, column = 0 }, nil, nil)
      local marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
      local cursor = nil
      for _, m in ipairs(marks) do
        local hl = m[4] and m[4].hl_group
        if hl and hl:match('^KakFace_') then cursor = m end
      end
      return { count = cursor and 1 or 0, end_col = cursor and cursor[4].end_col or -1 }
    end)
    h.eq(1, r.count)
    h.eq(3, r.end_col)
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

describe('faces.merge', function()
  before_each(function() end)

  it('returns face when base is nil', function()
    local r = h.exec_lua(
      function() return require('kak.ui.faces').merge(nil, { fg = 'red', attributes = { 'bold' } }) end
    )
    h.eq('red', r.fg)
  end)

  it('returns base when face is nil', function()
    local r = h.exec_lua(
      function()
        return require('kak.ui.faces').merge({ bg = 'blue', attributes = { 'reverse' } }, nil)
      end
    )
    h.eq('blue', r.bg)
    h.eq(1, #r.attributes)
    h.eq('reverse', r.attributes[1])
  end)

  it('lets face override base colors when face is not default', function()
    local r = h.exec_lua(
      function()
        return require('kak.ui.faces').merge(
          { fg = 'red', bg = 'blue' },
          { fg = 'green', bg = 'default' }
        )
      end
    )
    h.eq('green', r.fg)
    h.eq('blue', r.bg)
  end)

  it('keeps base colors when face is default', function()
    local r = h.exec_lua(
      function()
        return require('kak.ui.faces').merge(
          { fg = 'red', bg = 'blue' },
          { fg = nil, bg = nil, attributes = { 'bold' } }
        )
      end
    )
    h.eq('red', r.fg)
    h.eq('blue', r.bg)
  end)

  it('unions attributes by default', function()
    local r = h.exec_lua(
      function()
        return require('kak.ui.faces').merge(
          { attributes = { 'bold' } },
          { attributes = { 'italic' } }
        )
      end
    )
    -- union sorted
    h.eq('bold', r.attributes[1])
    h.eq('italic', r.attributes[2])
  end)

  it('respects base final_fg', function()
    local r = h.exec_lua(
      function()
        return require('kak.ui.faces').merge(
          { fg = 'red', attributes = { 'final_fg' } },
          { fg = 'green', attributes = {} }
        )
      end
    )
    h.eq('red', r.fg)
  end)

  it('respects face final_fg (overrides base final)', function()
    local r = h.exec_lua(
      function()
        return require('kak.ui.faces').merge(
          { fg = 'red', attributes = { 'final_fg' } },
          { fg = 'green', attributes = { 'final_fg' } }
        )
      end
    )
    h.eq('green', r.fg)
  end)

  it('drops face attrs when base has final_attr', function()
    local r = h.exec_lua(
      function()
        return require('kak.ui.faces').merge(
          { attributes = { 'final_attr', 'bold' } },
          { attributes = { 'italic' } }
        )
      end
    )
    -- face attrs (italic) dropped, base attrs preserved in original order
    h.eq(2, #r.attributes)
    h.eq('final_attr', r.attributes[1])
    h.eq('bold', r.attributes[2])
  end)

  it('preserves base final_* when face has final_attr', function()
    local r = h.exec_lua(
      function()
        return require('kak.ui.faces').merge(
          { fg = 'red', attributes = { 'final_fg' } },
          { bg = 'green', attributes = { 'final_attr', 'italic' } }
        )
      end
    )
    -- face attrs win, base final_fg preserved
    h.eq('green', r.bg)
    h.eq(3, #r.attributes)
    assert(r.attributes[1] == 'final_attr', 'attr[1]=' .. tostring(r.attributes[1]))
    assert(r.attributes[2] == 'final_fg', 'attr[2]=' .. tostring(r.attributes[2]))
    assert(r.attributes[3] == 'italic', 'attr[3]=' .. tostring(r.attributes[3]))
  end)
end)

describe('popups per-atom highlighting', function()
  before_each(function() h.setup() end)

  it('builds chunks per atom merged with base face', function()
    local r = h.exec_lua(function()
      local faces = require('kak.ui.faces').new()
      local popups = require('kak.ui.popups')
      local line = {
        { face = { fg = 'red', bg = nil, underline = nil, attributes = {} }, contents = 'foo' },
        {
          face = { fg = 'blue', bg = nil, underline = nil, attributes = { 'bold' } },
          contents = 'bar',
        },
      }
      local chunks = popups._line_to_chunks(line, { bg = 'default' }, faces)
      return {
        count = #chunks,
        text1 = chunks[1][1],
        text2 = chunks[2][1],
        same_hl = chunks[1][2] == chunks[2][2],
      }
    end)
    h.eq(2, r.count)
    h.eq('foo', r.text1)
    h.eq('bar', r.text2)
    h.eq(false, r.same_hl)
  end)

  it('skips empty atoms in chunks', function()
    local r = h.exec_lua(function()
      local faces = require('kak.ui.faces').new()
      local popups = require('kak.ui.popups')
      local chunks = popups._line_to_chunks({
        { face = nil, contents = '' },
        { face = nil, contents = 'x' },
      }, nil, faces)
      return #chunks
    end)
    h.eq(1, r)
  end)

  it('applies extmarks for each atom byte range', function()
    local r = h.exec_lua(function()
      local faces = require('kak.ui.faces').new()
      local popups = require('kak.ui.popups')
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_option_value('modifiable', true, { buf = buf })
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'foobaz' })
      vim.api.nvim_set_option_value('modifiable', false, { buf = buf })
      local ns = vim.api.nvim_create_namespace('kak-test')
      popups._apply_atom_extmarks(buf, ns, 0, {
        { face = { fg = 'red', attributes = {} }, contents = 'foo' },
        { face = { fg = 'blue', attributes = { 'bold' } }, contents = 'baz' },
      }, nil, faces)
      local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
      table.sort(marks, function(a, b) return a[2] < b[2] end)
      -- mark tuple: {id, row, col, details}; details holds end_col / hl_group.
      return {
        count = #marks,
        end1 = marks[1][4].end_col,
        end2 = marks[2][4].end_col,
        hl1 = marks[1][4].hl_group,
        hl2 = marks[2][4].hl_group,
        same = marks[1][4].hl_group == marks[2][4].hl_group,
      }
    end)
    h.eq(2, r.count)
    h.eq(3, r.end1)
    h.eq(6, r.end2)
    h.eq(false, r.same)
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
    local recv = h.with_fake_kak_server(
      [[
      fake.notify('set_ui_options', {{foo='bar'}})
      fake.sleep(5000)
    ]],
      function(_, captured)
        local got = 'unset'
        vim.wait(3000, function()
          if captured[1] then
            got = captured[1][2]
            return true
          end
          return false
        end)
        return got
      end
    )
    h.eq('table', type(recv))
    if type(recv) == 'table' then h.eq('bar', recv[1] and recv[1].foo) end
  end)
end)
