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
#   micmute-led.sh sync     — just syncs the LED to current mute state, no
#                              toggle (run at Hyprland startup so the LED is
#                              correct immediately, not just after the next
#                              F9 press)

# Machine-specific names come from the profile install.sh generates. Sourcing
# it (rather than hardcoding) is what lets this script run unmodified on any
# machine; the fallback keeps it working if the profile has not been written.
HW_ENV="${XDG_CONFIG_HOME:-$HOME/.config}/scripts/hardware.env"
# shellcheck source=/dev/null
[ -r "$HW_ENV" ] && . "$HW_ENV"

LED="${MICMUTE_LED:-}"

sync_led() {
    # No LED on this machine (or no profile yet): muting still works, there is
    # just nothing to light up.
    [ -n "$LED" ] && [ -e "/sys/class/leds/$LED" ] || return 0
    if pactl get-source-mute @DEFAULT_SOURCE@ | grep -q yes; then
        brightnessctl -d "$LED" set 0 >/dev/null 2>&1   # muted -> LED off
    else
        brightnessctl -d "$LED" set 1 >/dev/null 2>&1   # unmuted/on -> LED lit
    fi
}

case "$1" in
    toggle)
        pactl set-source-mute @DEFAULT_SOURCE@ toggle
        sync_led
        qs -p ~/.config/taskbar ipc call osd mic
        ;;
    sync)
        sync_led
        ;;
    *)
        echo "usage: $0 {toggle|sync}" >&2
        exit 1
        ;;
esac
