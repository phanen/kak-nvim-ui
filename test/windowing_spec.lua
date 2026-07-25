-- Tests for `kak.ui.windowing`: the nvim-side bridge that lets
-- kak-nvim-ui act as its own windowing provider.
--
-- These stay in-process: we only exercise the lua helpers
-- (`inject_args`, `kak_script_path`, `focus_active`). The
-- cross-process `nvim --server --remote-expr` path that the bundled
-- `kak/nvim.kak` triggers is a shell command and is exercised by the
-- kak-script syntax-check + body grep below (when a `kak` binary is
-- available) rather than via a child nvim -- which nvim-test cannot
-- spawn recursively from within itself.

local h = require('test.helpers')

describe('kak.ui.windowing', function()
  before_each(function() h.setup() end)

  describe('listen_socket', function()
    it('returns a non-empty serverstart path', function()
      local sock = h.exec_lua(function() return require('kak.ui.windowing').listen_socket() end)
      assert(
        type(sock) == 'string' and sock ~= '',
        'expected non-empty socket path, got: ' .. vim.inspect(sock)
      )
      -- serverstart path lives under /run/user or /tmp; just sanity-check it's a string and not /dev/null.
      assert(not sock:match('/dev/null$'), 'socket path is /dev/null: ' .. sock)
    end)

    it('caches the path across calls', function()
      local a, b = h.exec_lua(function()
        local w = require('kak.ui.windowing')
        return w.listen_socket(), w.listen_socket()
      end)
      h.eq(a, b)
    end)
  end)

  describe('kak_script_path', function()
    it('returns an absolute path ending in kak/nvim.kak', function()
      local p = h.exec_lua(function() return require('kak.ui.windowing').kak_script_path() end)
      assert(type(p) == 'string', 'expected string, got ' .. type(p))
      assert(p:sub(1, 1) == '/', 'expected absolute path, got: ' .. p)
      assert(p:match('kak/nvim%.kak$') ~= nil, 'expected path to end in kak/nvim.kak, got: ' .. p)
      -- File must exist (we just wrote it in this commit).
      assert(h.fn.filereadable(p) == 1, 'kak script not found at ' .. p)
    end)
  end)

  describe('inject_args', function()
    it(
      'sets NVIM env and emits exactly one -e with source + require-module + windowing_module',
      function()
        local result = h.exec_lua(function()
          local w = require('kak.ui.windowing')
          local opts = w.inject_args({})
          return {
            env_NVIM = opts.env.NVIM,
            extra_args = opts.extra_args,
          }
        end)
        assert(
          type(result.env_NVIM) == 'string' and result.env_NVIM ~= '',
          'expected NVIM set, got: ' .. vim.inspect(result.env_NVIM)
        )
        -- Default path (no caller -e): we emit `-e` followed by the
        -- standalone preamble.
        h.eq(2, #result.extra_args)
        h.eq('-e', result.extra_args[1])
        local payload = result.extra_args[2]
        assert(type(payload) == 'string', 'expected payload to be a string')
        assert(payload:find('source ', 1, true) ~= nil, 'payload missing source: ' .. payload)
        assert(
          payload:find('kak/nvim.kak', 1, true) ~= nil,
          'payload missing kak/nvim.kak path: ' .. payload
        )
        -- Regression for the v1 bug: without `require-module nvim`,
        -- `provide-module` only registers the body and
        -- `define-command` never runs.
        assert(
          payload:find('require-module nvim', 1, true) ~= nil,
          'payload missing require-module nvim: ' .. payload
        )
        assert(
          payload:find('set global windowing_module nvim', 1, true) ~= nil,
          'payload missing windowing_module override: ' .. payload
        )
      end
    )

    it('folds the source preamble into a caller-supplied -e payload', function()
      local result = h.exec_lua(function()
        local w = require('kak.ui.windowing')
        local opts = w.inject_args({ extra_args = { '-e', 'echo hi', '--foo' } })
        return opts.extra_args
      end)
      h.eq('-e', result[1])
      assert(result[2]:find('source ', 1, true) ~= nil, '2nd entry should be the source payload')
      assert(
        result[2]:find('require-module nvim', 1, true) ~= nil,
        '2nd entry should require-module nvim'
      )
      assert(result[2]:find('echo hi', 1, true) ~= nil, 'caller payload should survive')
      -- Caller entries that aren't `-e` are preserved at the tail;
      -- the original `echo hi` arg (now folded into result[2]) is
      -- NOT duplicated.
      h.eq('--foo', result[3])
      h.eq(3, #result)
    end)

    it('folds the source preamble into a caller -e with no space (combined form)', function()
      local result = h.exec_lua(function()
        local w = require('kak.ui.windowing')
        local opts = w.inject_args({ extra_args = { '-eecho hi' } })
        return opts.extra_args
      end)
      h.eq(2, #result)
      h.eq('-e', result[1])
      assert(result[2]:find('source ', 1, true) ~= nil, 'payload missing source')
      assert(
        result[2]:find('require-module nvim', 1, true) ~= nil,
        'payload missing require-module'
      )
      assert(result[2]:find('echo hi', 1, true) ~= nil, 'caller payload should survive')
    end)

    it('emits a single -e even when caller passes no extra_args', function()
      local result = h.exec_lua(function()
        local w = require('kak.ui.windowing')
        local opts = w.inject_args({})
        local dash_e_count = 0
        for _, a in ipairs(opts.extra_args) do
          if a == '-e' or a:sub(1, 2) == '-e' then dash_e_count = dash_e_count + 1 end
        end
        return dash_e_count
      end)
      h.eq(1, result)
    end)

    it('does not mutate a caller-supplied env table', function()
      local result = h.exec_lua(function()
        local caller_env = { FOO = 'bar' }
        local w = require('kak.ui.windowing')
        local opts = w.inject_args({ env = caller_env })
        return {
          same_table = opts.env == caller_env,
          caller_foo = caller_env.NVIM,
          opts_foo = opts.env.FOO,
          opts_NVIM = opts.env.NVIM,
        }
      end)
      -- We deep-copy to avoid surprising the caller if they reuse the
      -- table; the inject returns a fresh table.
      h.eq(false, result.same_table)
      h.eq('bar', result.opts_foo)
      h.eq(nil, result.caller_foo)
      assert(result.opts_NVIM ~= nil and result.opts_NVIM ~= '', 'NVIM missing on returned opts')
    end)

    it('is idempotent across two consecutive calls (single -e, args survive)', function()
      local result = h.exec_lua(function()
        local w = require('kak.ui.windowing')
        local first = w.inject_args({ extra_args = { '-e', 'echo first' } })
        local second = w.inject_args({ extra_args = { '-e', 'echo second' } })
        local function count_dash_e(t)
          local n = 0
          for _, a in ipairs(t) do
            if a == '-e' or a:sub(1, 2) == '-e' then n = n + 1 end
          end
          return n
        end
        return {
          first_n = #first.extra_args,
          second_n = #second.extra_args,
          first_dash_e = count_dash_e(first.extra_args),
          second_dash_e = count_dash_e(second.extra_args),
          first_has_first = first.extra_args[2]
            and first.extra_args[2]:find('echo first', 1, true) ~= nil,
          second_has_second = second.extra_args[2]
            and second.extra_args[2]:find('echo second', 1, true) ~= nil,
          shared_NVIM = first.env.NVIM == second.env.NVIM,
        }
      end)
      -- Caller passes {-e, payload} (2 args); merged with our preamble
      -- it stays 2 args.
      h.eq(2, result.first_n)
      h.eq(2, result.second_n)
      h.eq(1, result.first_dash_e)
      h.eq(1, result.second_dash_e)
      h.eq(true, result.first_has_first)
      h.eq(true, result.second_has_second)
      h.eq(true, result.shared_NVIM)
    end)
  end)

  describe('focus_active', function()
    it('is a no-op when no session is active', function()
      local ok = h.exec_lua(function()
        local w = require('kak.ui.windowing')
        -- Reset ACTIVE in case a previous test left one behind.
        local m = require('kak.ui')
        -- We can't directly write the upvalue, but `active()` returns
        -- nil at fresh setup; just assert it does.
        if m.active() then return 'unexpected active session' end
        w.focus_active()
        return 'ok'
      end)
      h.eq('ok', ok)
    end)
  end)

  describe('kak script', function()
    it('uses --remote-expr + execute(...) + $kak_session (regression for v1.2 bug)', function()
      -- Regression for the "KakNewWin: no such command" bug caused
      -- by two things combined: (1) using `--remote-send` instead of
      -- `--remote-expr` (the kak content buffer's `vim.on_key` hook
      -- drops every typed key, including `:...`, so the `:KakNewWin`
      -- never reaches the parent nvim's command line), and (2)
      -- using `$kak_opt_session` (a non-existent option; evaluates
      -- to empty) instead of `$kak_session` (the actual session
      -- name kak exports in `%sh{}`).
      local script = h.fn.fnamemodify('./kak/nvim.kak', ':p')
      if h.fn.filereadable(script) ~= 1 then return end -- spec skipped
      local f = assert(io.open(script, 'r'))
      local raw = f:read('*a') or ''
      f:close()

      -- Drop `#` comment lines so the explanation comment at the
      -- top of the file (which legitimately names `--remote-send`
      -- to explain why we don't use it) doesn't trip the negative
      -- assertion below.
      local body_lines = {}
      for line in raw:gmatch('[^\n]+') do
        if not line:match('^%s*#') then body_lines[#body_lines + 1] = line end
      end
      local body = table.concat(body_lines, '\n')

      -- Must use the new bypass pattern.
      assert(
        body:find('--remote-expr', 1, true) ~= nil,
        'kak script does not use --remote-expr: ' .. script
      )
      assert(
        body:find("execute('KakNewWin window", 1, true) ~= nil,
        'kak script missing execute(KakNewWin window ...) form'
      )
      assert(
        body:find("execute('KakNewWin horizontal", 1, true) ~= nil,
        'kak script missing execute(KakNewWin horizontal ...) form'
      )
      assert(
        body:find("execute('KakNewWin vertical", 1, true) ~= nil,
        'kak script missing execute(KakNewWin vertical ...) form'
      )
      assert(
        body:find("execute('KakNewTab", 1, true) ~= nil,
        'kak script missing execute(KakNewTab ...) form'
      )
      assert(
        body:find("execute('KakFocus'", 1, true) ~= nil,
        'kak script missing execute(KakFocus) form'
      )
      -- Must use the real session value, not the non-existent
      -- `$kak_opt_session` (which would evaluate to "" and make
      -- KakNewWin spawn a brand-new session instead of attaching
      -- to the current one).
      assert(
        body:find('$kak_session', 1, true) ~= nil,
        'kak script does not use $kak_session: ' .. script
      )
      assert(
        body:find('$kak_opt_session', 1, true) == nil,
        'kak script still uses $kak_opt_session (typo for $kak_session)'
      )
      -- Must NOT use the old broken pattern (in executable code).
      assert(
        body:find('--remote-send', 1, true) == nil,
        'kak script still uses --remote-send in executable code (use --remote-expr instead)'
      )
    end)

    -- Optional syntax check; skip when `kak` is not available so the
    -- suite doesn't fail in bare environments.
    it('sources and requires the nvim module cleanly under kak', function()
      local kak = h.kak_path()
      -- The test runner is plain Lua (outside nvim), so we cannot
      -- rely on `vim.fn`; use `h.fn` (which delegates through the
      -- embedded session) for any path / filereadable probing. We
      -- capture stderr via a redirect into a temp file and assert
      -- the exit code + stderr are clean.
      --
      -- The payload mirrors what `inject_args` sends: `source` the
      -- script (registers `provide-module nvim`) AND `require-module`
      -- the module (executes the body so `define-command` calls run).
      -- The old payload only sourced, so the bug went undetected by
      -- this smoke test -- the commands simply were never defined.
      local script = h.fn.fnamemodify('./kak/nvim.kak', ':p')
      if h.fn.filereadable(script) ~= 1 then return end -- spec skipped
      local tmp = h.fn.tempname()
      local payload = 'source ' .. script .. '; require-module nvim; echo ok'
      local cmd = string.format('%s -e %q 2> %q 1> /dev/null', kak, payload, tmp)
      local ok = os.execute(cmd)
      local err = (function()
        local f = io.open(tmp, 'r')
        if not f then return '' end
        local s = f:read('*a') or ''
        f:close()
        return s
      end)()
      os.remove(tmp)
      assert(ok, 'kak invocation failed:\n' .. err)
      assert(not err:find('fail', 1, true), 'kak emitted a fail message:\n' .. err)
    end)
  end)

  describe('split_for', function()
    it('maps placements to the kakoune detection.kak contract', function()
      local m = h.exec_lua(function()
        local w = require('kak.ui.windowing')
        return {
          horizontal = w.split_for('horizontal'),
          vertical = w.split_for('vertical'),
          window = w.split_for('window'),
          tab = w.split_for('tab'),
          default = w.split_for(nil),
        }
      end)
      -- horizontal = left-right side-by-side (vsplit)
      h.eq('belowright vsplit', m.horizontal)
      -- vertical = top-bottom stacked (split)
      h.eq('belowright split', m.vertical)
      -- window (:new default) = left-right, matching user expectation
      h.eq('belowright vsplit', m.window)
      h.eq('belowright vsplit', m.default)
      h.eq('tabnew', m.tab)
    end)
  end)
end)
