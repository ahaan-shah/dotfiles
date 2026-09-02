#!/usr/bin/env bash
# nightlight.sh  {status|on|off|toggle|set <KELVIN>}
#
# Blue-light filter for the taskbar's Display panel. Fronts hyprsunset 0.4,
# which is a daemon: it holds the compositor's colour transform matrix through
# hyprland-ctm-control-v1, and `hyprctl hyprsunset …` talks to it over
# $XDG_RUNTIME_DIR/hypr/<sig>/.hyprsunset.sock.
#
# WHY "ON" MEANS "THE DAEMON IS RUNNING"
#
# Measured on 0.4.0: `hyprctl hyprsunset identity` neutralises the tint but
# does NOT change what `hyprctl hyprsunset temperature` reports — after
# identity it still answered 4000, the last temperature set. So the daemon
# cannot be asked whether the filter is actually applied, and a state file
# would be one more thing to get out of sync with reality. Presence of the
# process is the one signal that cannot lie, so off kills it: dropping the
# CTM client hands the screen straight back to its normal colours, which is
# exactly what off should do.
#
# The daemon is started with -t <K> rather than started and then set, so the
# first frame after a toggle is already the chosen temperature instead of
# flashing hyprsunset's own 6000K default first.
#
# The temperature is persisted (so it survives a toggle, a shell restart and a
# reboot); the on/off state deliberately is not — a session that comes up with
# no hyprsunset in it is off, and that is the honest answer.
set -euo pipefail

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/hyprahaan"
STATE="$STATE_DIR/nightlight"

DEFAULT_TEMP=4000
MIN_TEMP=2500       # hyprsunset accepts lower, but below this it is orange soup
MAX_TEMP=6500       # daylight — the top of the panel slider, i.e. "no warmth"

running() { pgrep -x hyprsunset >/dev/null 2>&1; }

read_temp() {
    local t="$DEFAULT_TEMP" v=""
    if [ -r "$STATE" ]; then
        v=$(cat "$STATE" 2>/dev/null || true)
        # anything that is not a bare integer is treated as a corrupt state
        # file and ignored rather than fed to hyprsunset
        case "$v" in
            ''|*[!0-9]*) ;;
            *) t="$v" ;;
        esac
    fi
    echo "$t"
}

clamp() {
    local t="$1"
    if [ "$t" -lt "$MIN_TEMP" ]; then t="$MIN_TEMP"; fi
    if [ "$t" -gt "$MAX_TEMP" ]; then t="$MAX_TEMP"; fi
    echo "$t"
}

write_temp() {
    mkdir -p "$STATE_DIR"
    echo "$1" > "$STATE"
}

# Push to a daemon that is already up. A no-op when it is not — `on` is what
# starts it, and starting it here would turn a warmth drag into a toggle.
push() {
    if running; then
        hyprctl hyprsunset temperature "$1" >/dev/null 2>&1 || true
    fi
}

start() {
    # CLAUDE.md's SIGPIPE rule: this is spawned from a Quickshell Process, so
    # the daemon must be fully detached from the pipe its parent hands it or
    # it dies the moment that parent exits.
    setsid hyprsunset -t "$1" </dev/null >/dev/null 2>&1 &
}

cmd="${1:-status}"
temp=$(read_temp)

case "$cmd" in
    status)
        # "<on|off>|<kelvin>" — one line, one parse in the panel.
        if running; then echo "on|$temp"; else echo "off|$temp"; fi
        ;;
    on)
        if running; then push "$temp"; else start "$temp"; fi
        ;;
    off)
        pkill -x hyprsunset >/dev/null 2>&1 || true
        ;;
    toggle)
        if running; then
            pkill -x hyprsunset >/dev/null 2>&1 || true
        else
            start "$temp"
        fi
        ;;
    set)
        t="${2:-$temp}"
        case "$t" in
            ''|*[!0-9]*) echo "nightlight.sh: set needs a temperature in K" >&2; exit 2 ;;
        esac
        t=$(clamp "$t")
        write_temp "$t"
        push "$t"
        ;;
    *)
        echo "usage: nightlight.sh {status|on|off|toggle|set <KELVIN>}" >&2
        exit 2
        ;;
esac
