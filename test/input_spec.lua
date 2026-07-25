-- Tests for `kak.ui.input` (key translation + handler routing).

local h = require('test.helpers')

describe('nvim_to_kak', function()
  before_each(function() h.setup() end)

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
end)

describe('raw_to_kak', function()
  before_each(function() h.setup() end)

  it('splits notation into per-key list', function()
    local r = h.exec_lua(function() return require('kak.ui.input').raw_to_kak('<CR>j') end)
    h.eq(2, #r)
    h.eq('<ret>', r[1])
    h.eq('j', r[2])
  end)

  it('converts <C-H>', function()
    local r = h.exec_lua(function() return require('kak.ui.input').raw_to_kak('<C-H>') end)
    h.eq(1, #r)
    h.eq('<c-h>', r[1])
  end)
end)

describe('from_on_key', function()
  before_each(function() h.setup() end)

  it('translates raw <Esc> byte to <esc>', function()
    local r = h.exec_lua(function() return require('kak.ui.input').from_on_key('\27') end)
    h.eq(1, #r)
    h.eq('<esc>', r[1])
  end)

  it('translates raw <CR> byte to <ret>', function()
    local r = h.exec_lua(function() return require('kak.ui.input').from_on_key('\r') end)
    h.eq(1, #r)
    h.eq('<ret>', r[1])
  end)

  it('translates raw <Tab> byte to <tab>', function()
    local r = h.exec_lua(function() return require('kak.ui.input').from_on_key('\t') end)
    h.eq(1, #r)
    h.eq('<tab>', r[1])
  end)

  it('translates raw <Up> bytes (<80>ku) to <up>', function()
    local r = h.exec_lua(function()
      local up_internal = vim.api.nvim_replace_termcodes('<Up>', true, false, true)
      return require('kak.ui.input').from_on_key(up_internal)
    end)
    h.eq(1, #r)
    h.eq('<up>', r[1])
  end)

  it('translates raw Ctrl-A (<1>) to <c-a>', function()
    local r = h.exec_lua(function() return require('kak.ui.input').from_on_key('\x01') end)
    h.eq(1, #r)
    h.eq('<c-a>', r[1])
  end)

  it('returns empty for nil/empty input', function()
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

describe('input handler routing', function()
  before_each(function() h.setup() end)

  it('maps mouse events to mouse_press / scroll (not keys)', function()
    local methods = h.with_fake_kak_server(
      [[
      fake.notify('set_ui_options', {{}})
      fake.notify('mouse_press', { 'left', 1, 5 })
      fake.notify('mouse_release', { 'left', 1, 5 })
      fake.notify('scroll', { 1, 1, 0 })
      fake.sleep(5000)
    ]],
      function(_, captured)
        vim.wait(3000, function() return #captured >= 4 end)
        local m = {}
        for _, e in ipairs(captured) do
          m[#m + 1] = e[1]
        end
        return m
      end
    )

    h.eq('set_ui_options', methods[1])
    h.eq('mouse_press', methods[2])
    h.eq('mouse_release', methods[3])
    h.eq('scroll', methods[4])
    for _, name in ipairs(methods) do
      assert(name ~= 'keys', 'mouse event leaked into keys path: ' .. name)
    end
  end)

  it('cleans up on_key listener on disable', function()
    local counts = h.exec_lua(function()
      local conn = {
        notify = function() end,
        is_closing = function() return false end,
      }
      local handler = require('kak.ui.input').new({ rpc = conn })
      local buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].buftype = 'nofile'
      handler:enable(buf)
      local before = vim.on_key and vim.on_key() or 0
      handler:disable()
      local after = vim.on_key and vim.on_key() or 0
      return { before = before, after = after }
    end)
    h.eq(true, counts.after <= counts.before)
  end)

  -- |vim.on_key()|: returning '' tells nvim to discard the keypress.
  -- Without this, nvim would also act on ESC, `:`, `/`, etc.
  it('returns empty string from on_key callback so nvim drops the key', function()
    local got = h.exec_lua(function()
      local sent = {}
      local conn = {}
      conn.is_closing = function() return false end
      conn.notify = function(self, method, params) sent[#sent + 1] = { method, params } end
      local handler = require('kak.ui.input').new({ rpc = conn })
      local buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].buftype = 'nofile'
      handler:enable(buf)
      vim.api.nvim_set_current_buf(buf)
      -- <Esc> arrives as a single \27 byte.
      local ret = handler.on_key_fn('', '\27')
      handler:disable()
      return { ret = ret, sent = sent }
    end)
    h.eq('', got.ret)
    h.eq(1, #got.sent)
    h.eq('keys', got.sent[1][1])
    h.eq('<esc>', got.sent[1][2][1])
  end)
end)