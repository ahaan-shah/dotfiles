#!/bin/bash
# micmute-led.sh — keeps the keyboard's platform::micmute LED in sync with
# the actual mic mute state, with the polarity the user actually wants:
# lit = mic ON (unmuted), off = muted.
#
# The kernel's own snd_ctl_led module auto-drives this LED via the
# `audio-micmute` sysfs LED trigger (confirmed live: `cat
# /sys/class/leds/platform::micmute/trigger` had it active) — but that
# trigger's built-in polarity is lit-when-MUTED, the opposite of what's
# wanted here, and there's no sysfs knob to flip its polarity. Fixing this
# requires the trigger be set to "none" so the kernel stops fighting us —
# that write needs root (a one-time udev rule handles it at boot, see
# scripts/README or ask the repo owner for the exact rule). Once the
# trigger is "none", `brightness` itself is writable by a normal user via
# the same seat ACL brightnessctl already uses for asus::kbd_backlight
# (confirmed live: `brightnessctl -d platform::micmute set 0` succeeded
# unprivileged).
#
# Usage:
#   micmute-led.sh toggle   — toggles source mute, syncs the LED, fires the
#                              taskbar OSD (bound to F9 in hyprland.lua)
#   micmute-led.sh sync     — waits for the audio server, then syncs the LED
#                              to the current mute state, no toggle (run at
#                              Hyprland startup so the LED is correct
#                              immediately, not just after the next F9 press)

# Machine-specific names come from the profile install.sh generates. Sourcing
# it (rather than hardcoding) is what lets this script run unmodified on any
# machine; the fallback keeps it working if the profile has not been written.
HW_ENV="${XDG_CONFIG_HOME:-$HOME/.config}/scripts/hardware.env"
# shellcheck source=/dev/null
[ -r "$HW_ENV" ] && . "$HW_ENV"

LED="${MICMUTE_LED:-}"

set_led() {
    # No LED on this machine (or no profile yet): muting still works, there is
    # just nothing to light up.
    [ -n "$LED" ] && [ -e "/sys/class/leds/$LED" ] || return 0
    brightnessctl -d "$LED" set "$1" >/dev/null 2>&1
}

# Prints yes/no on success. Returns 1 — WITHOUT printing — if the audio server
# cannot answer, which is a genuinely different thing from "not muted": before
# PipeWire has sources, pactl exits 1 with "No such entity" and an empty
# stdout. Collapsing that into the unmuted branch is what used to light the
# LED for a mic that was in fact muted.
mute_state() {
    local out
    out=$(pactl get-source-mute @DEFAULT_SOURCE@ 2>/dev/null) || return 1
    case "$out" in
        *": yes"*) echo yes ;;
        *": no"*)  echo no ;;
        *)         return 1 ;;
    esac
}

# Syncs the LED once. Returns 1 and leaves the LED alone if the state could
# not be read.
sync_led() {
    local state
    state=$(mute_state) || return 1
    if [ "$state" = yes ]; then
        set_led 0    # muted -> LED off
    else
        set_led 1    # unmuted/on -> LED lit
    fi
}

# Startup sync. PipeWire is brought up by the systemd user session, which
# races Hyprland's autostart and loses: measured on this machine, Hyprland
# starts at 00:48:50 and fires hyprland.start straight away, while
# pipewire-pulse only starts at 00:48:53 and its ALSA sources land later
# still. So a plain sync at startup asks a server that has no sources yet.
# Poll until it answers, with a ceiling.
sync_wait() {
    local i
    for i in $(seq 1 120); do          # 120 * 0.25s = 30s ceiling
        if sync_led; then
            # wireplumber applies the saved mute state as it creates the node,
            # so the very first readable answer can still predate the restore.
            # One re-read after it has settled costs nothing and closes that gap.
            sleep 1
            sync_led
            return 0
        fi
        sleep 0.25
    done
    # Audio server never came up. Deliberately leave the LED untouched rather
    # than assert a mute state we were never able to read.
    return 1
}

case "$1" in
    toggle)
        pactl set-source-mute @DEFAULT_SOURCE@ toggle
        sync_led
        qs -p ~/.config/taskbar ipc call osd mic
        ;;
    sync)
        sync_wait
        ;;
    *)
        echo "usage: $0 {toggle|sync}" >&2
        exit 1
        ;;
esac
