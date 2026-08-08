#!/usr/bin/env bash
# toggle-shells.sh — SUPER+K: kill every Quickshell shell if any of them are
# alive, otherwise relaunch all of them. Bound in hyprland.lua as a single
# key: state is read from actual running processes each press (not a stored
# flag), so a press always matches what's really on screen.
#
# lockscreen/ is deliberately NOT included here — per its own launch script's
# warning, killing a live WlSessionLock process leaves the compositor
# permanently locked with nothing listening to unlock it. Never pkill it.
SHELLS=(macdock macswitcher taskbar finder)

alive=false
for s in "${SHELLS[@]}"; do
    if pgrep -f "quickshell -c .*/${s}\$" >/dev/null 2>&1; then
        alive=true
        break
    fi
done

if $alive; then
    for s in "${SHELLS[@]}"; do
        pkill -f "quickshell -c .*/${s}\$"
    done
    sleep 0.3
    # finder (socat + wl-paste) and macswitcher (socat) each spawn a
    # persistent child process for their IPC socket / clipboard watcher.
    # Killing the quickshell process above only kills quickshell itself —
    # these children get reparented to init and keep running (and, for
    # wl-paste, keep racing the next launch's clipboard dedup) unless
    # killed explicitly here too.
    pkill -9 -f "socat UNIX-LISTEN:/tmp/finder.sock" 2>/dev/null
    pkill -9 -f "socat UNIX-LISTEN:/tmp/macswitcher.sock" 2>/dev/null
    pkill -9 -f "wl-paste --watch.*finder/clipboard" 2>/dev/null
else
    for s in "${SHELLS[@]}"; do
        "$HOME/.config/${s}/${s}-launch.sh" &
        disown
    done
fi
