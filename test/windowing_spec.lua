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
    it('sets NVIM env on a fresh opts table', function()
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
    end)

    it('does NOT emit any -e preamble (client inherits from daemon)', function()
      local result = h.exec_lua(function()
        local w = require('kak.ui.windowing')
        -- Both no-extra_args and explicit-empty cases must produce an
        -- empty extra_args list (or nil).
        local empty = w.inject_args({}).extra_args or {}
        local explicit_nil = w.inject_args({ extra_args = nil }).extra_args or {}
        local dash_e_in_empty = 0
        local dash_e_in_explicit = 0
        for _, a in ipairs(empty) do
          if a == '-e' or a:sub(1, 2) == '-e' then dash_e_in_empty = dash_e_in_empty + 1 end
        end
        for _, a in ipairs(explicit_nil) do
          if a == '-e' or a:sub(1, 2) == '-e' then dash_e_in_explicit = dash_e_in_explicit + 1 end
        end
        return {
          empty_n = #empty,
          explicit_n = #explicit_nil,
          empty_dash_e = dash_e_in_empty,
          explicit_dash_e = dash_e_in_explicit,
        }
      end)
      -- The client MUST NOT re-source the windowing module; the
      -- daemon did it once at startup. Injecting a 2nd `-e` here
      -- would cause `provide-module: module 'nvim' already defined`
      -- every time a second client joins.
      h.eq(0, result.empty_n)
      h.eq(0, result.explicit_n)
      h.eq(0, result.empty_dash_e)
      h.eq(0, result.explicit_dash_e)
    end)

    it('passes caller extra_args through verbatim (no folding)', function()
      local result = h.exec_lua(function()
        local w = require('kak.ui.windowing')
        local caller_args = { '-e', 'echo hi', '--foo', '-eset global kak_session baz' }
        local out = w.inject_args({ extra_args = caller_args }).extra_args
        return out
      end)
      h.eq(4, #result)
      h.eq('-e', result[1])
      h.eq('echo hi', result[2])
      h.eq('--foo', result[3])
      h.eq('-eset global kak_session baz', result[4])
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

    it('is idempotent across two consecutive calls (NVIM stable)', function()
      local result = h.exec_lua(function()
        local w = require('kak.ui.windowing')
        local first = w.inject_args({ extra_args = { '-e', 'echo first' } })
        local second = w.inject_args({ extra_args = { '-e', 'echo second' } })
        return {
          first_has_first = first.extra_args[2] == 'echo first',
          second_has_second = second.extra_args[2] == 'echo second',
          shared_NVIM = first.env.NVIM == second.env.NVIM,
        }
      end)
      h.eq(true, result.first_has_first)
      h.eq(true, result.second_has_second)
      h.eq(true, result.shared_NVIM)
    end)
  end)

  describe('daemon_preamble', function()
    it('contains source + require-module + windowing_module', function()
      local preamble = h.exec_lua(
        function() return require('kak.ui.windowing').daemon_preamble() end
      )
      assert(type(preamble) == 'string' and preamble ~= '', 'preamble should be non-empty')
      assert(preamble:find('source ', 1, true) ~= nil, 'preamble missing source: ' .. preamble)
      assert(
        preamble:find('kak/nvim.kak', 1, true) ~= nil,
        'preamble missing kak/nvim.kak path: ' .. preamble
      )
      -- Regression for the v1 bug: without `require-module nvim`,
      -- `provide-module` only registers the body and `define-command`
      -- never runs.
      assert(
        preamble:find('require-module nvim', 1, true) ~= nil,
        'preamble missing require-module nvim: ' .. preamble
      )
      assert(
        preamble:find('set global windowing_module nvim', 1, true) ~= nil,
        'preamble missing windowing_module override: ' .. preamble
      )
    end)
  end)

  describe('daemon_argv', function()
    it('emits kak -d -s <session> -E <preamble>', function()
      local argv = h.exec_lua(
        function() return require('kak.ui.windowing').daemon_argv('mysession') end
      )
      h.eq(6, #argv)
      h.eq('kak', argv[1])
      h.eq('-d', argv[2])
      h.eq('-s', argv[3])
      h.eq('mysession', argv[4])
      h.eq('-E', argv[5])
      assert(type(argv[6]) == 'string' and argv[6] ~= '', 'preamble should be non-empty')
      -- The preamble must contain the source + require-module
      -- hooks; the client relies on inheriting them.
      assert(argv[6]:find('source ', 1, true) ~= nil, 'daemon argv[6] missing source')
      assert(
        argv[6]:find('require-module nvim', 1, true) ~= nil,
        'daemon argv[6] missing require-module'
      )
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
