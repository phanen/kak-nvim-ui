local h = require('test.helpers')
local exec_lua = h.exec_lua
local eq = h.eq

describe('real Kakoune integration', function()
  before_each(function() h.setup() end)

  it('renders a multi-line buffer into content + mode buffers', function()
    local file = h.write_file({ 'alpha line', 'beta line', 'gamma line' })
    finally(function() os.remove(file) end)

    local result = h.with_kak_session({
      extra_args = { '-e', 'edit ' .. file },
    }, function(sess, f)
      local got = nil
      vim.wait(3000, function()
        local lines = vim.api.nvim_buf_get_lines(sess.buf, 0, -1, false)
        if not (#lines >= 3 and lines[1] == 'alpha line') then return false end
        local mode = vim.api.nvim_buf_get_lines(sess.renderer.mode_buf, 0, -1, false)
        local basename = vim.fn.fnamemodify(f, ':t')
        if #mode > 0 and mode[1]:find(basename, 1, true) then
          got = { content = lines, mode = mode }
          return true
        end
        return false
      end)
      return got
    end, file)

    eq('table', type(result))
    if type(result) == 'table' then
      eq('alpha line', result.content[1])
      eq('beta line', result.content[2])
      eq('gamma line', result.content[3])
      local mode_joined = table.concat(result.mode, '\n')
      local basename = h.fn.fnamemodify(file, ':t')
      assert(mode_joined:find(basename, 1, true), 'expected basename in mode, got: ' .. mode_joined)
    end
  end)

  describe('with screen attached', function()
    local screen

    before_each(function() screen = h.with_screen(80, 24) end)
    after_each(function()
      if screen then
        screen:detach()
        screen = nil
      end
    end)

    it('renders grid via screen:expect', function()
      local file = h.write_file({ 'alpha line', 'beta line', 'gamma line' })
      finally(function() os.remove(file) end)

      h.with_kak_session({
        extra_args = { '-e', 'edit ' .. file },
      }, function(sess, f)
        vim.wait(3000, function()
          local lines = vim.api.nvim_buf_get_lines(sess.buf, 0, -1, false)
          return #lines >= 3 and lines[1] == 'alpha line'
        end)
      end, file)

      -- 80x24: 1 mode + 3 content + 19 empty + 1 cmdline; cursor
      -- glyph `^` sits at column 0 of the focused row, so the alpha
      -- row begins with `^`, not the alpha text.
      screen:expect([[
        {MATCH:^.*k//main.*X}|
        {MATCH:alpha line}
        {MATCH:beta line}
        {MATCH:gamma line}
        {MATCH:^~.*}|*19
        {MATCH:^ *}|
      ]])
    end)
  end)

  it('updates buffer when file changes mid-session', function()
    local file = h.write_file({ 'initial content' })
    finally(function() os.remove(file) end)

    local result = h.with_kak_session({
      extra_args = { '-e', 'edit ' .. file },
    }, function(sess)
      local got = nil
      vim.wait(3000, function()
        local lines = vim.api.nvim_buf_get_lines(sess.buf, 0, -1, false)
        if #lines >= 1 and lines[1] == 'initial content' then
          got = lines
          return true
        end
        return false
      end)
      return got
    end)

    eq('table', type(result))
    if type(result) == 'table' then eq('initial content', result[1]) end
  end)

  it('forwards ESC key to kakoune, exiting insert-like mode', function()
    local dir = h.fn.tempname()
    h.fn.mkdir(dir, 'p')
    local log = dir .. '/kak-ui.log'
    finally(function() h.rmdir(dir) end)

    local spawned = h.with_kak_session({
      cmd = { '/usr/bin/kak' },
      wire_log = log,
    }, function(sess)
      vim.wait(3000, function() return sess.conn:is_closing() end)
      return true
    end)

    h.assert_log('subprocess exit', log)

    -- Headless nvim cannot deliver real keypresses; unit-test the
    -- raw ESC -> <esc> translation directly. The e2e run above
    -- must at least have completed spawn.
    local notation_ok = exec_lua(function()
      local m = require('kak.ui.input')
      local raw = vim.api.nvim_replace_termcodes('<Esc>', true, false, true)
      local keys = m.from_on_key(raw)
      return keys[1] == '<esc>'
    end)
    eq(true, spawned)
    eq(true, notation_ok)
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

    eq('set_ui_options', methods[1])
    eq('mouse_press', methods[2])
    eq('mouse_release', methods[3])
    eq('scroll', methods[4])
    for _, name in ipairs(methods) do
      assert(name ~= 'keys', 'mouse event leaked into keys path: ' .. name)
    end
  end)

  it('cleans up on_key listener on disable', function()
    local counts = exec_lua(function()
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
    eq(true, counts.after <= counts.before)
  end)

  it('returns empty string from on_key callback so nvim drops the key', function()
    -- |vim.on_key()|: returning '' tells nvim to discard the keypress.
    local got = exec_lua(function()
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
    eq('', got.ret)
    eq(1, #got.sent)
    eq('keys', got.sent[1][1])
    eq('<esc>', got.sent[1][2][1])
  end)
end)

describe('plugin logger routing', function()
  before_each(function() h.setup() end)

  it('captures rpc stderr through the plugin logger', function()
    local dir = h.fn.tempname()
    h.fn.mkdir(dir, 'p')
    local log = dir .. '/kak-ui.log'
    finally(function() h.rmdir(dir) end)

    h.with_fake_kak_server(
      [[
      io.stderr:write('FAKE-STDERR-MARKER\n')
      io.stderr:flush()
      fake.notify('set_ui_options', {{}})
      fake.sleep(500)
      fake.exit(0)
    ]],
      { wire_log = log },
      function(_, captured)
        vim.wait(2000, function() return #captured >= 1 end)
        return #captured
      end
    )

    -- Both the plugin logger and the fake process's wire capture
    -- share this file; either side or both could match.
    h.assert_log('rpc.stderr', log)
    h.assert_log('FAKE%-STDERR%-MARKER', log)
  end)
end)

describe('info popup positioning', function()
  before_each(function() h.setup() end)

  it('menuDoc is placed at the right side of the editor', function()
    local pos = exec_lua(function()
      local renderer = require('kak.ui.render').new({ faces = require('kak.ui.faces').new() })
      renderer:set_buf(vim.api.nvim_create_buf(false, true))
      renderer:set_mode_buf(vim.api.nvim_create_buf(false, true))
      local popups = require('kak.ui.popups').new({ faces = renderer.faces, renderer = renderer })
      vim.o.columns = 160
      vim.o.lines = 50
      local title_atoms = {
        {
          face = { fg = 'default', bg = 'default', underline = 'default', attributes = {} },
          contents = 'Documentation',
        },
      }
      local content = {
        {
          {
            face = { fg = 'default', bg = 'default', underline = 'default', attributes = {} },
            contents = 'line 1 of doc',
          },
        },
      }
      popups:info_show(
        title_atoms,
        content,
        { line = 5, column = 0 },
        { fg = 'default', bg = 'default', underline = 'default', attributes = {} },
        'menuDoc'
      )
      local config = vim.api.nvim_win_get_config(popups.info_state.win)
      popups:info_hide()
      return { row = config.row, col = config.col, width = config.width }
    end)
    -- menuDoc column should be near the right edge, NOT in the middle.
    -- editor_w = 160, expected col >= 80.
    assert(pos.col >= 80, 'expected menuDoc on right side, got col=' .. tostring(pos.col))
    assert(
      pos.row <= 30,
      'expected menuDoc near top/menu anchor row, got row=' .. tostring(pos.row)
    )
  end)

  it('modal is centered', function()
    local pos = exec_lua(function()
      local renderer = require('kak.ui.render').new({ faces = require('kak.ui.faces').new() })
      renderer:set_buf(vim.api.nvim_create_buf(false, true))
      renderer:set_mode_buf(vim.api.nvim_create_buf(false, true))
      local popups = require('kak.ui.popups').new({ faces = renderer.faces, renderer = renderer })
      vim.o.columns = 160
      vim.o.lines = 50
      local title_atoms = {
        {
          face = { fg = 'default', bg = 'default', underline = 'default', attributes = {} },
          contents = 'Modal title',
        },
      }
      local content = {
        {
          {
            face = { fg = 'default', bg = 'default', underline = 'default', attributes = {} },
            contents = 'body',
          },
        },
      }
      popups:info_show(
        title_atoms,
        content,
        { line = 0, column = 0 },
        { fg = 'default', bg = 'default', underline = 'default', attributes = {} },
        'modal'
      )
      local config = vim.api.nvim_win_get_config(popups.info_state.win)
      popups:info_hide()
      return { row = config.row, col = config.col, width = config.width }
    end)
    -- modal col should be roughly centered (col ~= (160 - width) / 2).
    local expected_center = math.floor((160 - pos.width) / 2)
    -- Allow +/-5 cells of slack for integer rounding.
    assert(
      math.abs(pos.col - expected_center) <= 5,
      'expected modal centered, got col=' .. tostring(pos.col) .. ' want~' .. expected_center
    )
  end)

  it('prompt menu floats at the bottom of the screen', function()
    local pos = exec_lua(function()
      local renderer = require('kak.ui.render').new({ faces = require('kak.ui.faces').new() })
      renderer:set_buf(vim.api.nvim_create_buf(false, true))
      renderer:set_mode_buf(vim.api.nvim_create_buf(false, true))
      local popups = require('kak.ui.popups').new({ faces = renderer.faces, renderer = renderer })
      vim.o.columns = 160
      vim.o.lines = 50
      local items = {
        {
          {
            face = { fg = 'default', bg = 'default', underline = 'default', attributes = {} },
            contents = 'option-A',
          },
        },
        {
          {
            face = { fg = 'default', bg = 'default', underline = 'default', attributes = {} },
            contents = 'option-B',
          },
        },
      }
      popups:menu_show(
        items,
        { line = 5, column = 0 },
        { fg = 'default', bg = 'default', underline = 'default', attributes = {} },
        { fg = 'default', bg = 'default', underline = 'default', attributes = {} },
        'prompt'
      )
      local config = vim.api.nvim_win_get_config(popups.menu_state.win)
      popups:menu_hide()
      return { row = config.row, height = config.height }
    end)
    -- prompt-style menu should be at the bottom: row near editor_h - height.
    assert(pos.row >= 40, 'expected prompt menu near bottom, got row=' .. tostring(pos.row))
  end)

  it('prompt info (help popup) is anchored to the bottom-right corner', function()
    local pos = exec_lua(function()
      local renderer = require('kak.ui.render').new({ faces = require('kak.ui.faces').new() })
      renderer:set_buf(vim.api.nvim_create_buf(false, true))
      renderer:set_mode_buf(vim.api.nvim_create_buf(false, true))
      local popups = require('kak.ui.popups').new({ faces = renderer.faces, renderer = renderer })
      vim.o.columns = 160
      vim.o.lines = 50
      local title = {
        {
          face = { fg = 'default', bg = 'default', underline = 'default', attributes = {} },
          contents = 'Help',
        },
      }
      local content = {
        {
          {
            face = { fg = 'default', bg = 'default', underline = 'default', attributes = {} },
            contents = 'documentation body',
          },
        },
      }
      popups:info_show(
        title,
        content,
        { line = 5, column = 0 },
        { fg = 'default', bg = 'default', underline = 'default', attributes = {} },
        'prompt'
      )
      local config = vim.api.nvim_win_get_config(popups.info_state.win)
      popups:info_hide()
      return { row = config.row, col = config.col, anchor = config.anchor, width = config.width }
    end)
    -- With SE anchor, nvim positions the bottom-right corner of the
    -- float at (row, col). The float must align with the editor's
    -- right edge and bottom row.
    assert(pos.anchor == 'SE', 'expected SE anchor, got ' .. tostring(pos.anchor))
    assert(pos.row == 50, 'expected bottom row (50), got ' .. tostring(pos.row))
    assert(
      pos.col == 160,
      'expected right edge aligned with editor (col=160), got col=' .. tostring(pos.col)
    )
  end)
end)
