-- Tests for `kak.ui.faces` (cache, color mapping, merge semantics).

local h = require('test.helpers')

describe('face cache', function()
  before_each(function() h.setup() end)

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
  before_each(function() h.setup() end)

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
