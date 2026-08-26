#!/usr/bin/env bash
# lockscreen-launch.sh  —  place in ~/.config/lockscreen/ and chmod +x
#
# Single entry point for starting the lock. hypridle calls it three ways:
# lock_cmd (idle timeout / loginctl lock-session), before_sleep_cmd (suspend),
# and after_sleep_cmd (resume, where it acts as the crash-recovery path).
#
# NEVER pkill an existing instance. Per WlSessionLock's docs, a lock process
# that dies without setting `locked = false` leaves the compositor locked and
# painted solid with nothing able to unlock it — recoverable only via a TTY.
# So this is launch-if-not-running, like hyprlock's old `pidof hyprlock ||
# hyprlock`.

set -u

# --instant: skip the lock surface's ~1s entrance animation, for locks raised
# because the machine is about to sleep/hibernate. systemd freezes user.slice
# ~100-200ms after the compositor confirms the lock, which strands those
# animations part-way; they then resume on wake, so the lock appears to load in
# two halves. Painting the final state immediately avoids that. hypridle's
# before_sleep_cmd/after_sleep_cmd pass this; lock_cmd (idle timeout) does not,
# so walking away still gets the full animation.
INSTANT=0
[ "${1:-}" = "--instant" ] && INSTANT=1

RUNTIME="${XDG_RUNTIME_DIR:-/tmp}"
PIDFILE="$RUNTIME/lockscreen.pid"
CONFIG="$HOME/.config/lockscreen"

running() {
    local pid
    pid=$(cat "$PIDFILE" 2>/dev/null) || return 1
    [ -n "$pid" ] && [ -d "/proc/$pid" ] || return 1
    tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF -- "-c $CONFIG"
}

# Serialize check-and-launch: an idle timeout landing at the same moment as a
# lid close would otherwise start two instances, and per WlSessionLock's docs
# only one can ever lock — the loser lingers as a stray process. Verified: 8
# concurrent invocations produce exactly 1 launch.
exec 9>"$RUNTIME/lockscreen-launch.lock"
flock -w 5 9 || exit 0

running && exit 0

# Detached with fds on /dev/null. This is what stops the lockscreen dying
# mid-session: hypridle spawns commands via CProcess with pipes, and a child
# that inherits one is killed by SIGPIPE as soon as the read end closes. That
# is the same mechanism documented in CLAUDE.md 2026-08-22 for Spotify, and
# here it would kill the lock while the compositor stayed locked — the
# unrecoverable case above. `9>&-` keeps the lock fd out of the child, or an
# orphaned grandchild would hold it forever and block all future locks.
# LOCKSCREEN_INSTANT is exported so it survives setsid+exec into quickshell,
# where LockSurface.qml reads it via Quickshell.env().
LOCKSCREEN_INSTANT=$INSTANT setsid bash -c 'echo $$ > "$1"; exec quickshell -c "$2"' \
    _ "$PIDFILE" "$CONFIG" </dev/null >/dev/null 2>&1 9>&- &

# Hold the lock until the new instance is identifiable, so a caller arriving
# right behind us cannot pass the check above and start a duplicate.
for _ in $(seq 1 200); do
    running && break
    sleep 0.01
done
