#!/usr/bin/env bash
# macshell-launch.sh — place in ~/.config/macshell/ and chmod +x
#
# Replaces macdock-launch.sh + macswitcher-launch.sh; both apps now run in a
# single Quickshell instance.

pkill -f "quickshell.*macshell" 2>/dev/null
# The switcher's socat listener is a child Process, so killing quickshell alone
# orphans it (it keeps holding /tmp/macswitcher.sock and would block the new
# instance's listener). Same class of orphan documented in toggle-shells.sh.
pkill -9 -f "socat UNIX-LISTEN:/tmp/macswitcher.sock" 2>/dev/null
sleep 0.2
exec quickshell -c ~/.config/macshell
