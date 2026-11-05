#!/usr/bin/env bash
# toggle-layout.sh — SUPER+SHIFT+L: step the whole desktop to the next window
# mode, floating -> tiling -> scrolling -> floating, windows already open
# included.
#
# It was SUPER+T flipping two modes until 2026-10-29, when scrolling (Hyprland's
# built-in layout) became a third and the bind moved — Ahaan's call. The name
# stayed: the hyprland.lua bind points at it by path.
#
# ── Why this file is four lines of work and not forty ─────────────────────
# It used to hold the flip itself: `globalFloatRule:set_enabled()` plus a walk
# over `hyprctl clients` converting each window, with the current mode kept in
# /tmp/hypr_float_mode. That state file was the problem. The settings menu's
# Window rules page now carries a Window mode switch, and a second copy of the
# flip reading a second copy of the state would have drifted the first time
# either was used — press the bind and the switch still says floating.
#
# So the mode is ONE key in window.conf, WIN_WINDOW_MODE, and window-rules.sh
# owns both reading and applying it. This script only decides which way to go.
# Two further things fall out of that, both worth having:
#
#   * It survives a reload. /tmp/hypr_float_mode did not — `hyprctl reload`
#     re-parses hyprland.lua, which re-enables globalFloatRule, so any wallpaper
#     change or monitor hotplug silently put the desktop back to floating while
#     the state file still claimed tiling. hyprland.lua reads WIN_WINDOW_MODE at
#     parse time now, so a reload restores the mode instead of dropping it.
#   * The notification stays HERE. window-rules.sh is silent for every other
#     rule because the switch you just moved is the feedback; a keybind has no
#     switch on screen, so this is the one caller that needs to say something.

set -euo pipefail

RULES="${XDG_CONFIG_HOME:-$HOME/.config}/scripts/window-rules.sh"

# Anything unrecognised counts as floating, so the next press always lands on
# a real mode rather than on whatever the bad value would have stepped to.
now="$("$RULES" get WIN_WINDOW_MODE 2>/dev/null)" || now="floating"
case "$now" in
    floating) next="tiling" ;;
    tiling)   next="scrolling" ;;
    *)        next="floating" ;;
esac

# stdout is the value it settled on and is not wanted; a refusal goes to stderr
# and is left alone, so a failed flip is visible in the journal rather than
# swallowed under a notification claiming it worked.
"$RULES" set WIN_WINDOW_MODE "$next" >/dev/null

case "$next" in
    tiling)    notify-send "Tiling Mode 👽" ;;
    scrolling) notify-send "Scrolling Mode 🛸" ;;
    *)         notify-send "Floating Mode 👾" ;;
esac
