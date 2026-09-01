#!/usr/bin/env bash
# finder-launch.sh — place in ~/.config/finder/ and chmod +x
#
# finder's IPC listener (socat) and its clipboard watcher (wl-paste) are child
# Processes of the quickshell instance, so killing quickshell alone orphans
# them: they are reparented to init and keep running. Both matter.
#   socat    — keeps holding /tmp/finder.sock. Finder.qml's own listener does
#              `rm -f` first so the new instance still binds, but the stray
#              process lingers for the rest of the session.
#   wl-paste — keeps writing into ~/.cache/finder/clipboard alongside the new
#              instance's watcher. The flock in ClipboardHistory.qml serialises
#              invocations of ONE watcher; two independent watchers each take
#              the lock in turn, both see the pre-existing entry as "last", and
#              a single copy lands twice — which is the duplicate-history bug
#              the flock was added to prevent in the first place.
# Same class of orphan documented in macshell-launch.sh and toggle-shells.sh.

pkill -f "quickshell.*finder" 2>/dev/null
pkill -9 -f "socat UNIX-LISTEN:/tmp/finder.sock" 2>/dev/null
pkill -9 -f "wl-paste --watch.*finder/clipboard" 2>/dev/null
sleep 0.2
exec quickshell -c ~/.config/finder
