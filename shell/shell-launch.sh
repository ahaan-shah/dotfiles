#!/usr/bin/env bash
# shell-launch.sh — place in ~/.config/shell/ and chmod +x
#
# Replaces macshell-launch.sh + taskbar-launch.sh + finder-launch.sh. All three
# apps are one Quickshell instance now (see shell.qml), so there is one launcher
# and one process to kill.
#
# ── The children are the whole reason this script exists ──────────────────
# Three long-lived helpers are spawned as Quickshell `Process` children, and
# killing quickshell alone ORPHANS them: they are reparented to init and keep
# running, holding exactly the resources the next instance needs.
#
#   socat /tmp/finder.sock      — the launcher's IPC listener. Finder.qml does
#                                 `rm -f` first so a new instance still binds,
#                                 but the stray holds the old inode and the
#                                 keybinds reach nothing.
#   socat /tmp/macswitcher.sock — the Alt-Tab switcher's, same story.
#   wl-paste --watch            — the clipboard watcher. Two of them each take
#                                 the flock in turn, both see the same entry as
#                                 "last", and a single copy lands in the history
#                                 twice. That duplicate-history bug is the
#                                 reason the flock exists in the first place.
#
# Same class of orphan documented in toggle-shells.sh, which kills the same
# three for the same reason.
pkill -f "quickshell -c .*/shell\$" 2>/dev/null
pkill -9 -f "socat UNIX-LISTEN:/tmp/finder.sock" 2>/dev/null
pkill -9 -f "socat UNIX-LISTEN:/tmp/macswitcher.sock" 2>/dev/null
pkill -9 -f "wl-paste --watch.*finder/clipboard" 2>/dev/null
sleep 0.2
exec quickshell -c ~/.config/shell
