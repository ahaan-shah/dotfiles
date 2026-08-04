#!/usr/bin/env bash
# lockscreen-launch.sh  —  place in ~/.config/lockscreen/ and chmod +x
#
# lockscreen/shell.qml is now a PERSISTENT background process (same pattern
# as macdock/macswitcher/taskbar/finder), not spawned fresh per lock —
# spawning fresh every lock was the actual cause of "wakes up showing the
# desktop for 2-3 seconds before the lock appears": cold-starting Quickshell
# (QML compile, Wayland connect, wal-color/wallpaper loading, PAM/fprintd
# setup) took long enough that suspend/resume could complete well before the
# lock surface was even up. Now the process is already warm and idle from
# session start, and locking it is just an IPC call flipping
# WlSessionLock.locked, not a process spawn.
#
# Still never pkill an existing instance — WlSessionLock's own docs warn
# that killing the process while `locked` is still true leaves the
# compositor permanently locked with nothing left to unlock it, recoverable
# only via a TTY switch, not by re-running this script. So this remains a
# pure "launch only if not already running" guard, matched on the full
# launch command line since every Quickshell instance on this system
# (finder/macdock/taskbar/macswitcher/this) shows up as plain "quickshell"
# under a bare `pidof`.
#
# Usage:
#   lockscreen-launch.sh        — ensure the persistent instance is running
#                                  (unlocked). Called once from hyprland.lua's
#                                  autostart, and from the SUPER+L bind.
#   lockscreen-launch.sh lock   — ensure it's running, then tell it to lock
#                                  now over IPC. This is hypridle.conf's
#                                  lock_cmd.

running() { pgrep -f "quickshell -c $HOME/.config/lockscreen" >/dev/null; }

just_started=0
if ! running; then
    quickshell -c ~/.config/lockscreen &
    disown
    just_started=1
fi

if [ "$1" = "lock" ]; then
    # A freshly-spawned instance (the crashed/not-yet-started fallback case
    # — normally it's already running from autostart) needs a moment to
    # come up before it's listening on IPC.
    [ "$just_started" = "1" ] && sleep 1
    qs -p ~/.config/lockscreen ipc call lock engage
fi
