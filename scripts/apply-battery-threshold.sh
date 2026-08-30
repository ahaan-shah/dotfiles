#!/usr/bin/env bash
# apply-battery-threshold.sh [VALUE|--check]
#
# Single writer for BAT0's charge cap. Used by hyprland.lua at startup, by the
# taskbar battery panel on click, and by battery-threshold.timer as a watchdog.
#
# WHY THIS IS NOT JUST `echo N > sysfs`
#
# 1. Writing the value sysfs ALREADY holds can be a no-op at the driver level,
#    so it never reaches the EC. That is how the cap silently stops being
#    enforced after a hibernate: the kernel's cached value survives inside the
#    restored hibernation image while the EC itself has reset to 100. sysfs then
#    reads a perfectly correct "80" while the battery charges to 100, and
#    re-clicking 80 in the panel changes nothing because nothing is written.
#    Observed exactly that: threshold 80, capacity 100, status Full.
#    So when the target equals the current value we nudge DOWN first (never up —
#    a nudge upward would briefly permit MORE charging) to force a real EC
#    transaction, then set the target.
#
# 2. The EC ignores the cap outright sometimes — an upstream asus-wmi issue
#    where asus_wmi_set_devstate() can silently fail to reach the EC. There is
#    no error to check: the write succeeds and sysfs reads back correctly.
#    The only way to notice is behavioural, which is what --check does.
set -u

# Machine-specific names come from the profile install.sh generates. Sourcing
# it (rather than hardcoding) is what lets this script run unmodified on any
# machine; the fallback keeps it working if the profile has not been written.
HW_ENV="${XDG_CONFIG_HOME:-$HOME/.config}/scripts/hardware.env"
# shellcheck source=/dev/null
[ -r "$HW_ENV" ] && . "$HW_ENV"

BAT="/sys/class/power_supply/${BATTERY:-BAT0}"
THRESH="$BAT/charge_control_end_threshold"
STATE="$HOME/.config/battery-threshold"
LOG="${XDG_RUNTIME_DIR:-/tmp}/battery-threshold.log"

# Desktops, and laptops whose firmware exposes no cap, have nothing to do here.
[ -e "$THRESH" ] || exit 0

log() { printf '%s  %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

saved() {
    local v; v=$(cat "$STATE" 2>/dev/null)
    [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -ge 20 ] && [ "$v" -le 100 ] && { echo "$v"; return; }
    echo 100
}

apply() {
    local target=$1 cur nudge new
    [ -w "$THRESH" ] || { log "cannot write $THRESH (udev rule/group applied? needs a real relogin)"; return 1; }
    cur=$(cat "$THRESH" 2>/dev/null)

    if [ "$cur" = "$target" ]; then
        nudge=$(( target - 5 )); [ "$nudge" -lt 20 ] && nudge=20
        echo "$nudge" > "$THRESH" 2>/dev/null
        sleep 0.3
    fi

    echo "$target" > "$THRESH" 2>/dev/null
    sleep 0.3
    new=$(cat "$THRESH" 2>/dev/null)
    if [ "$new" = "$target" ]; then
        log "applied $target (was $cur)"
    else
        log "FAILED: wanted $target, sysfs reads $new"
        return 1
    fi
}

case "${1:-}" in
    --check)
        # Behavioural watchdog. sysfs reading the right number proves nothing —
        # only "still charging above the cap" reveals that the EC dropped it.
        t=$(cat "$THRESH" 2>/dev/null); want=$(saved)
        cap=$(cat "$BAT/capacity" 2>/dev/null); st=$(cat "$BAT/status" 2>/dev/null)
        [[ "$t" =~ ^[0-9]+$ && "$cap" =~ ^[0-9]+$ ]] || exit 0
        if [ "$t" != "$want" ]; then
            log "drift: sysfs=$t want=$want -> reapplying"; apply "$want"
        elif [ "$cap" -gt "$((want + 1))" ] && [ "$st" = "Charging" ]; then
            log "EC ignoring cap: capacity=$cap%% > $want%% and still Charging -> forcing"
            apply "$want"
        fi
        ;;
    "")
        apply "$(saved)"
        ;;
    *)
        if [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 20 ] && [ "$1" -le 100 ]; then
            mkdir -p "$(dirname "$STATE")"; echo "$1" > "$STATE"
            apply "$1"
        else
            echo "usage: $0 [20-100|--check]" >&2; exit 2
        fi
        ;;
esac
