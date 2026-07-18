#!/usr/bin/env bash
# lockscreen-launch.sh  —  place in ~/.config/lockscreen/ and chmod +x
#
# Unlike this project's other *-launch.sh scripts (finder, macdock,
# taskbar, macswitcher), this one must NEVER pkill an existing instance
# before relaunching. WlSessionLock's own docs warn that if the process is
# killed without setting `locked = false` first, the compositor leaves the
# screen permanently locked and painted solid — nothing left running to
# unlock it, recoverable only via a TTY switch, not by re-running this
# script. So this is a pure "launch only if not already running" guard,
# matching hyprlock's own original `pidof hyprlock || hyprlock` behavior
# (see hypridle.conf's old lock_cmd) — just matched on the launch command
# line instead of a distinct process name, since every Quickshell instance
# on this system (finder/macdock/taskbar/macswitcher/this) shows up as
# plain "quickshell" under `pidof`.
pgrep -f "quickshell -c $HOME/.config/lockscreen" >/dev/null || exec quickshell -c ~/.config/lockscreen
