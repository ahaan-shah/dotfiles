#!/bin/bash
# micmute-led.sh — the F9 mic-mute toggle and the mute-on-login. Despite the
# name it no longer touches the LED.
#
# The keyboard's mic-mute LED belongs to the kernel again: snd_ctl_led drives
# it through the `audio-micmute` sysfs trigger, lit = MUTED, off = mic live,
# the stock polarity. From 2026-08-04 until 2026-11-07 this repo ran it the
# other way round (lit = live): a udev rule set the trigger to "none" and this
# script wrote the brightness itself after every mute change. Ahaan reversed
# that on 2026-11-07 ("I don't like the light being on when the mic is on"),
# so the udev rule is gone and the installer puts the trigger back. The name
# stays because hyprland.lua, the installer and the map all call it by it.
#
# Usage:
#   micmute-led.sh toggle   — toggles source mute and fires the bar's mic OSD
#                              (bound to F9 in hyprland.lua)
#   micmute-led.sh startup  — waits for the audio server, then forces the mic
#                              MUTED, whatever wireplumber restored
#                              (run from hyprland.start)

# Prints yes/no on success. Returns 1 — WITHOUT printing — if the audio server
# cannot answer, which is a genuinely different thing from "not muted": before
# PipeWire has sources, pactl exits 1 with "No such entity" and an empty
# stdout.
mute_state() {
    local out
    out=$(pactl get-source-mute @DEFAULT_SOURCE@ 2>/dev/null) || return 1
    case "$out" in
        *": yes"*) echo yes ;;
        *": no"*)  echo no ;;
        *)         return 1 ;;
    esac
}

# Startup. PipeWire is brought up by the systemd user session, which races
# Hyprland's autostart and loses: measured on this machine, Hyprland starts at
# 00:48:50 and fires hyprland.start straight away, while pipewire-pulse only
# starts at 00:48:53 and its ALSA sources land later still. So poll until the
# server answers, with a ceiling. wireplumber also restores whatever mute state
# the previous session ended with, so a fresh login can come up with the mic
# live; this machine should always start muted, so assert it.
mute_on_start() {
    local i
    for i in $(seq 1 120); do          # 120 * 0.25s = 30s ceiling
        if mute_state >/dev/null; then
            # The first readable answer can still predate wireplumber's restore
            # (it applies the saved state as it creates the node), so settle
            # before muting — otherwise the restore lands after us and wins.
            sleep 1
            pactl set-source-mute @DEFAULT_SOURCE@ 1 >/dev/null 2>&1
            return 0
        fi
        sleep 0.25
    done
    # Audio server never came up. Nothing to mute.
    return 1
}

case "$1" in
    toggle)
        pactl set-source-mute @DEFAULT_SOURCE@ toggle
        qs -p ~/.config/shell ipc call osd mic
        ;;
    startup)
        mute_on_start
        ;;
    *)
        echo "usage: $0 {toggle|startup}" >&2
        exit 1
        ;;
esac
