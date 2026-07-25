-- Empirically verifies what the Kakoune JSON-UI protocol actually
-- carries about an opened file. The protocol is content-centric:
-- every atom is just {face, contents}. The only place the buffer
-- name appears is as plain text inside the mode_line atoms of
-- draw_status. These tests use h.read_log to dump the fake-kak
-- NDJSON wire and assert on it, so they fail loudly the moment
-- upstream changes the shape.

local h = require('test.helpers')

local SAMPLE = 'sample.kak'

-- Representative startup sequence: set_ui_options -> refresh(true)
-- -> draw (lines) -> draw_status (mode_line carries the buffer
-- name as text, exactly as kakoune does in real sessions).
-- Each `fake.notify` carries a *positional* array matching the
-- protocol's param order (see lua/kak/ui/protocol.lua). Lua tables
-- with sequential integer keys become JSON arrays.
local SPEC = ([[
  fake.notify('set_ui_options', {
    { ui_render = true },
  })
  fake.notify('refresh', { true })
  fake.notify('draw', {
    {
      { face = { fg = '#aaaaaa', bg = 'default', underline = { Color = 'default' }, attributes = {} }, contents = '# Sample kakoune script used by payload_spec' },
      { face = { fg = '#88aabb', bg = 'default', underline = { Color = 'default' }, attributes = {} }, contents = 'hook global WinSetOption filetype=kak %%{ ... }' },
    },
    { line = 0, column = 0 },
    { fg = 'default', bg = 'default', underline = { Color = 'default' }, attributes = {} },
    { fg = 'default', bg = 'default', underline = { Color = 'default' }, attributes = {} },
    0,
  })
  fake.notify('draw_status', {
    { { face = { fg = '#88c0d0' }, contents = ':' } },
    {},
    -1,
    {
      { face = { fg = '#a3be8c' }, contents = '%s ' },
      { face = { fg = '#a3be8c' }, contents = '1:1' },
      { face = { fg = '#a3be8c' }, contents = '  (top)' },
    },
    { fg = 'default', bg = 'default', underline = { Color = 'default' }, attributes = {} },
    'prompt',
  })
  fake.sleep(300)
  fake.exit(0)
]]):format(SAMPLE)

--- Walk a single Line (Array<Atom>) and tally atom shape into `out`.
---@param line any
---@param out table
local function tally_line(line, out, unknown_set)
  if type(line) ~= 'table' then return end
  for _, atom in ipairs(line) do
    if type(atom) == 'table' then
      out.atoms = out.atoms + 1
      if type(atom.face) == 'table' then out.with_face = out.with_face + 1 end
      if type(atom.contents) == 'string' then
        out.with_contents = out.with_contents + 1
        if atom.contents:find(SAMPLE, 1, true) then
          out.mentions_sample = out.mentions_sample + 1
        end
      end
      for k in pairs(atom) do
        if k ~= 'face' and k ~= 'contents' then unknown_set[k] = true end
      end
      for _, key in ipairs({ 'filename', 'file', 'buffer_name', 'bufname', 'filetype' }) do
        if atom[key] ~= nil then out.with_filename_field = out.with_filename_field + 1 end
      end
    end
  end
end

--- Walk every `->` (kak -> nvim) message in the wire dump and
--- count atoms by shape. Lets the assertions below reason about
--- "all atoms in the captured wire" rather than a single fixture.
---@param lines string[]
local function scan_atoms(lines)
  local out = {
    atoms = 0,
    with_face = 0,
    with_contents = 0,
    with_filename_field = 0,
    mentions_sample = 0,
    unknown_keys = {},
  }
  local unknown_set = {}
  for _, line in ipairs(lines) do
    local arrow, body = line:match('^(%S+)\t(.*)$')
    if arrow == '->' then
      local ok, msg = pcall(vim.json.decode, body)
      if ok and type(msg) == 'table' and type(msg.method) == 'string' then
        local params = msg.params
        if type(params) ~= 'table' then goto next end
        if msg.method == 'draw' then
          -- params[1] = lines: Array<Line>
          for _, l in ipairs(params[1] or {}) do
            tally_line(l, out, unknown_set)
          end
        elseif msg.method == 'draw_status' then
          -- params[4] = mode_line: Line (already a single array of atoms)
          tally_line(params[4], out, unknown_set)
        end
        ::next::
      end
    end
  end
  for k in pairs(unknown_set) do
    out.unknown_keys[#out.unknown_keys + 1] = k
  end
  table.sort(out.unknown_keys)
  return out
end

describe('read_log payload util', function()
  before_each(function() h.setup() end)

  it('returns every line for an NDJSON wire file', function()
    local log, dir = h.fresh_log()
    finally(function() h.rmdir(dir) end)

    local f = assert(io.open(log, 'w'))
    f:write('->\t{"a":1}\n<-\t{"b":2}\n->\t{"c":3}\n')
    f:close()

    local lines = h.read_log(log)
    h.eq(3, #lines)
    assert(lines[1]:match('^->'), 'first line is outbound')
    assert(lines[2]:match('^<-'), 'second line is inbound')
  end)

  it(
    'returns {} when the log file is missing',
    function() h.eq({}, h.read_log('/no/such/path/at/all')) end
  )

  it('honors opts.n to return only the last N lines', function()
    local log, dir = h.fresh_log()
    finally(function() h.rmdir(dir) end)
    local f = assert(io.open(log, 'w'))
    f:write('one\ntwo\nthree\nfour\n')
    f:close()
    local lines = h.read_log(log, { n = 2 })
    h.eq(2, #lines)
    h.eq('three', lines[1])
    h.eq('four', lines[2])
  end)
end)

describe('JSON-UI payload contents', function()
  before_each(function() h.setup() end)

  it('atoms only carry {face, contents}; no structured filename/filetype field', function()
    local log, dir = h.fresh_log()
    finally(function() h.rmdir(dir) end)

    h.with_fake_kak_server(SPEC, { wire_log = log }, function(_, captured)
      vim.wait(3000, function() return #captured >= 3 end)
      return #captured
    end)

    local lines = h.read_log(log)
    assert(#lines > 0, 'wire log empty; fake-kak-server recorded nothing')

    local counts = scan_atoms(lines)
    assert(counts.atoms > 0, 'expected at least one atom in the wire dump')
    h.eq(counts.atoms, counts.with_contents, 'every atom should declare "contents"')
    assert(counts.with_face > 0, 'expected at least one atom with a face')
    h.eq(
      0,
      counts.with_filename_field,
      'no atom should carry filename/filetype/buffer_name as a structured field'
    )
    -- Whatever other keys atoms have, they must not be one of the
    -- fields the plugin would need to identify the current file.
    assert(
      #counts.unknown_keys == 0,
      ('atoms should be exactly {face, contents}; got extra keys: %s'):format(
        table.concat(counts.unknown_keys, ',')
      )
    )
    assert(counts.mentions_sample > 0, ('expected "%s" text inside mode_line atoms'):format(SAMPLE))
  end)

  it('mode_line text concatenation is the only reliable source of buffer name', function()
    local log, dir = h.fresh_log()
    finally(function() h.rmdir(dir) end)

    h.with_fake_kak_server(SPEC, { wire_log = log }, function(_, captured)
      vim.wait(3000, function() return #captured >= 3 end)
      return #captured
    end)

    local lines = h.read_log(log)
    local recovered = nil
    for _, line in ipairs(lines) do
      local arrow, body = line:match('^(%S+)\t(.*)$')
      local candidate = nil
      if arrow == '->' then
        local ok, msg = pcall(vim.json.decode, body)
        if ok and msg.method == 'draw_status' and type(msg.params) == 'table' then
          local mode_line = msg.params[4]
          if type(mode_line) == 'table' then
            local parts = {}
            for _, atom in ipairs(mode_line) do
              parts[#parts + 1] = atom.contents or ''
            end
            local joined = table.concat(parts, '')
            local first_token = joined:match('^(%S+)')
            if first_token and first_token:match('%.kak$') then candidate = first_token end
          end
        end
      end
      if candidate then recovered = candidate end
    end

    assert(
      recovered == SAMPLE,
      ('expected to recover %q from mode_line text, got %q'):format(SAMPLE, tostring(recovered))
    )
  end)
end)
