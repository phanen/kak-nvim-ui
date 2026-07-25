-- Tests for `kak.ui.popups` (per-atom highlighting + window positioning).

local h = require('test.helpers')

local function with_big_screen(body_src)
  return h.exec_lua(function(src)
    vim.o.columns = 160
    vim.o.lines = 50
    local body = assert(loadstring(src))
    return body()
  end, body_src)
end

local function renderer_and_popups()
  local renderer = require('kak.ui.render').new({ faces = require('kak.ui.faces').new() })
  renderer:set_buf(vim.api.nvim_create_buf(false, true))
  renderer:set_mode_buf(vim.api.nvim_create_buf(false, true))
  local popups = require('kak.ui.popups').new({ faces = renderer.faces, renderer = renderer })
  return renderer, popups
end

local DEFAULT_FACE = { fg = 'default', bg = 'default', underline = 'default', attributes = {} }

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

describe('popup window positioning', function()
  before_each(function() h.setup() end)

  it('menuDoc is placed at the right side of the editor', function()
    local pos = with_big_screen([[
      local renderer = require('kak.ui.render').new({ faces = require('kak.ui.faces').new() })
      renderer:set_buf(vim.api.nvim_create_buf(false, true))
      renderer:set_mode_buf(vim.api.nvim_create_buf(false, true))
      local popups = require('kak.ui.popups').new({ faces = renderer.faces, renderer = renderer })
      local df = { fg = 'default', bg = 'default', underline = 'default', attributes = {} }
      popups:info_show(
        { { face = df, contents = 'Documentation' } },
        { { { face = df, contents = 'line 1 of doc' } } },
        { line = 5, column = 0 },
        df,
        'menuDoc'
      )
      local config = vim.api.nvim_win_get_config(popups.info_state.win)
      popups:info_hide()
      return { row = config.row, col = config.col, width = config.width }
    ]])
    -- editor_w = 160, expected col >= 80 (right half).
    assert(pos.col >= 80, 'expected menuDoc on right side, got col=' .. tostring(pos.col))
    assert(
      pos.row <= 30,
      'expected menuDoc near top/menu anchor row, got row=' .. tostring(pos.row)
    )
  end)

  it('modal is centered', function()
    local pos = with_big_screen([[
      local renderer = require('kak.ui.render').new({ faces = require('kak.ui.faces').new() })
      renderer:set_buf(vim.api.nvim_create_buf(false, true))
      renderer:set_mode_buf(vim.api.nvim_create_buf(false, true))
      local popups = require('kak.ui.popups').new({ faces = renderer.faces, renderer = renderer })
      local df = { fg = 'default', bg = 'default', underline = 'default', attributes = {} }
      popups:info_show(
        { { face = df, contents = 'Modal title' } },
        { { { face = df, contents = 'body' } } },
        { line = 0, column = 0 },
        df,
        'modal'
      )
      local config = vim.api.nvim_win_get_config(popups.info_state.win)
      popups:info_hide()
      return { row = config.row, col = config.col, width = config.width }
    ]])
    -- col ~= (160 - width) / 2; allow +/-5 for rounding.
    local expected_center = math.floor((160 - pos.width) / 2)
    assert(
      math.abs(pos.col - expected_center) <= 5,
      'expected modal centered, got col=' .. tostring(pos.col) .. ' want~' .. expected_center
    )
  end)

  it('prompt menu floats at the bottom of the screen', function()
    local pos = with_big_screen([[
      local renderer = require('kak.ui.render').new({ faces = require('kak.ui.faces').new() })
      renderer:set_buf(vim.api.nvim_create_buf(false, true))
      renderer:set_mode_buf(vim.api.nvim_create_buf(false, true))
      local popups = require('kak.ui.popups').new({ faces = renderer.faces, renderer = renderer })
      local df = { fg = 'default', bg = 'default', underline = 'default', attributes = {} }
      popups:menu_show(
        { { { face = df, contents = 'option-A' } }, { { face = df, contents = 'option-B' } } },
        { line = 5, column = 0 },
        df,
        df,
        'prompt'
      )
      local config = vim.api.nvim_win_get_config(popups.menu_state.win)
      popups:menu_hide()
      return { row = config.row, height = config.height }
    ]])
    -- prompt menu should sit at the bottom: row near editor_h - height.
    assert(pos.row >= 40, 'expected prompt menu near bottom, got row=' .. tostring(pos.row))
  end)

  it('prompt info (help popup) is anchored to the bottom-right corner', function()
    local pos = with_big_screen([[
      local renderer = require('kak.ui.render').new({ faces = require('kak.ui.faces').new() })
      renderer:set_buf(vim.api.nvim_create_buf(false, true))
      renderer:set_mode_buf(vim.api.nvim_create_buf(false, true))
      local popups = require('kak.ui.popups').new({ faces = renderer.faces, renderer = renderer })
      local df = { fg = 'default', bg = 'default', underline = 'default', attributes = {} }
      popups:info_show(
        { { face = df, contents = 'Help' } },
        { { { face = df, contents = 'documentation body' } } },
        { line = 5, column = 0 },
        df,
        'prompt'
      )
      local config = vim.api.nvim_win_get_config(popups.info_state.win)
      popups:info_hide()
      return { row = config.row, col = config.col, anchor = config.anchor, width = config.width }
    ]])
    -- With SE anchor, nvim positions the bottom-right corner at (row, col).
    assert(pos.anchor == 'SE', 'expected SE anchor, got ' .. tostring(pos.anchor))
    assert(pos.row == 50, 'expected bottom row (50), got ' .. tostring(pos.row))
    assert(
      pos.col == 160,
      'expected right edge aligned with editor (col=160), got col=' .. tostring(pos.col)
    )
  end)
end)