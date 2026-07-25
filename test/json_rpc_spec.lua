-- Tests for `kak.ui.json_rpc` (NDJSON framing + transport).

local h = require('test.helpers')

describe('ndjson framing', function()
  before_each(function() h.setup() end)

  local function feed(chunk)
    return h.exec_lua(function(c)
      local buf = vim.g._kak_test_buf or ''
      local r = {}
      buf = require('kak.ui.json_rpc')._ndjson_feed(buf, c, function(line) r[#r + 1] = line end)
      vim.g._kak_test_buf = buf
      return r
    end, chunk)
  end

  before_each(function() h.exec_lua(function() vim.g._kak_test_buf = '' end) end)

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

describe('rpc transport round-trip', function()
  before_each(function() h.setup() end)

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