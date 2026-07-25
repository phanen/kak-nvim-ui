# nvim windowing provider for kak-nvim-ui.
#
# This module lets Kakoune reuse the running nvim instance for
# `:new`, `:tabnew` and `focus` instead of spawning a fresh terminal
# that runs another nvim + kak-ui pair.
#
# How it works:
#
#   1. `kak-nvim-ui` starts an nvim listen socket via
#      `vim.fn.serverstart()` and passes the path to the spawned
#      kak child in env `NVIM` (mirrors Nvim's own convention; `vim.system`
#      does NOT auto-set `$NVIM` so the plugin sets it explicitly).
#   2. The child sources this file on startup (see
#      `lua/kak/ui/windowing.lua` `inject_args`), which REGISTERS the
#      `provide-module nvim` body. The injected `-e` then calls
#      `require-module nvim` to actually run that body -- `provide-module`
#      alone only registers; without the require the `define-command`
#      calls below never execute and `:new` reports
#      `nvim-terminal-window: no such command`.
#   3. Kakoune calls `<windowing_module>-terminal-<placement>` for
#      `:new` (see `rc/windowing/new-client.kak`). Each command shells
#      `nvim --server "$NVIM" --remote-send ':KakNewWin <placement>
#      %val{session}<CR>'`, which creates a split / tab in the SAME
#      nvim and calls `kak.ui.open()` to attach a fresh json-ui
#      client to the current session.
#
# V1 LIMITATION:
#
#   The `terminal` invocation includes `kak -c <session> -e "<cmds>"`
#   where `<cmds>` are the args of the user's `:new ...` call. We
#   DROP the `-e "<cmds>"` part: the spawned client is just a json-ui
#   against the same session, so the user's commands would either be
#   redundant (`:new` with no args) or unwanted (`:new :w` would
#   silently no-op on the JSON-UI client). Run `:new` without
#   arguments for the typical "fresh client" behavior; if you need
#   to pre-seed commands in the new client, do it after the client
#   is up (e.g. `:new<ret>:w<ret>`).
#
# This module is loaded by `kak/ui/windowing.lua:inject_args`, not by
# the stock windowing-module loader (`detection.kak`'s
# `windowing_modules` list), so it doesn't interfere with tmux /
# kitty / etc. autodetection.

provide-module nvim %{

    # Fail loudly at module-require time if the parent nvim did not
    # export its listen socket. Commands below read $NVIM directly so
    # they work in any buffer scope. We intentionally do NOT declare
    # a `nvim_listen` buffer-scope option: at startup there is no
    # buffer context yet and `set-option buffer` would error.
    evaluate-commands %sh{
        if [ -z "$NVIM" ]; then
            echo 'fail NVIM not set; the nvim that spawned this kak client did not export its listen socket'
        fi
    }

    define-command nvim-terminal-window -params 1.. -docstring '
nvim-terminal-window <program> [<arguments>]: open <program> as a new split in the running nvim
The current session is reused; the new window hosts a fresh json-ui client via kak-nvim-ui' \
    %{
        evaluate-commands %sh{
            listen="$NVIM"
            if [ -z "$listen" ]; then
                echo 'fail %{nvim-terminal-window: NVIM not set}'
                exit 0
            fi
            # Drop the placeholder `kak -c <session> -e "<cmds>"` we
            # receive via `$@`; we drive the new client from nvim
            # directly. See V1 LIMITATION at top of file.
            nvim --server "$listen" --remote-send ":KakNewWin window $kak_opt_session<CR>" \
                >/dev/null 2>&1 \
                || echo "fail %{nvim-terminal-window: nvim --remote-send exited $?}"
        }
    }

    define-command nvim-terminal-horizontal -params 1.. -docstring '
nvim-terminal-horizontal <program> [<arguments>]: open <program> as a horizontal split in the running nvim
The current session is reused; the new window hosts a fresh json-ui client via kak-nvim-ui' \
    %{
        evaluate-commands %sh{
            listen="$NVIM"
            if [ -z "$listen" ]; then
                echo 'fail %{nvim-terminal-horizontal: NVIM not set}'
                exit 0
            fi
            nvim --server "$listen" --remote-send ":KakNewWin horizontal $kak_opt_session<CR>" \
                >/dev/null 2>&1 \
                || echo "fail %{nvim-terminal-horizontal: nvim --remote-send exited $?}"
        }
    }

    define-command nvim-terminal-vertical -params 1.. -docstring '
nvim-terminal-vertical <program> [<arguments>]: open <program> as a vertical split in the running nvim
The current session is reused; the new window hosts a fresh json-ui client via kak-nvim-ui' \
    %{
        evaluate-commands %sh{
            listen="$NVIM"
            if [ -z "$listen" ]; then
                echo 'fail %{nvim-terminal-vertical: NVIM not set}'
                exit 0
            fi
            nvim --server "$listen" --remote-send ":KakNewWin vertical $kak_opt_session<CR>" \
                >/dev/null 2>&1 \
                || echo "fail %{nvim-terminal-vertical: nvim --remote-send exited $?}"
        }
    }

    define-command nvim-terminal-tab -params 1.. -docstring '
nvim-terminal-tab <program> [<arguments>]: open <program> as a new tab in the running nvim
The current session is reused; the new tab hosts a fresh json-ui client via kak-nvim-ui' \
    %{
        evaluate-commands %sh{
            listen="$NVIM"
            if [ -z "$listen" ]; then
                echo 'fail %{nvim-terminal-tab: NVIM not set}'
                exit 0
            fi
            nvim --server "$listen" --remote-send ":KakNewTab $kak_opt_session<CR>" \
                >/dev/null 2>&1 \
                || echo "fail %{nvim-terminal-tab: nvim --remote-send exited $?}"
        }
    }

    define-command nvim-focus -params ..1 -docstring '
nvim-focus [<client>]: focus the running nvim''s window hosting the active json-ui session
The optional <client> argument is ignored (always focuses the live session)' \
    %{
        evaluate-commands %sh{
            listen="$NVIM"
            if [ -z "$listen" ]; then
                echo 'fail %{nvim-focus: NVIM not set}'
                exit 0
            fi
            nvim --server "$listen" --remote-send ':KakFocus<CR>' \
                >/dev/null 2>&1 \
                || echo "fail %{nvim-focus: nvim --remote-send exited $?}"
        }
    }

    alias global focus nvim-focus

}