#!/usr/bin/env bash
# toggle-layout.sh — SUPER+T: flip the whole desktop between floating and
# tiling, windows already open included.
#
# ── Why this file is four lines of work and not forty ─────────────────────
# It used to hold the flip itself: `globalFloatRule:set_enabled()` plus a walk
# over `hyprctl clients` converting each window, with the current mode kept in
# /tmp/hypr_float_mode. That state file was the problem. The settings menu's
# Window rules page now carries a Tiling Mode switch, and a second copy of the
# flip reading a second copy of the state would have drifted the first time
# either was used — press SUPER+T and the switch still says floating.
#
# So the mode is ONE key in window.conf, WIN_TILING_MODE, and window-rules.sh
# owns both reading and applying it. This script only decides which way to go.
# Two further things fall out of that, both worth having:
#
#   * It survives a reload. /tmp/hypr_float_mode did not — `hyprctl reload`
#     re-parses hyprland.lua, which re-enables globalFloatRule, so any wallpaper
#     change or monitor hotplug silently put the desktop back to floating while
#     the state file still claimed tiling. hyprland.lua reads WIN_TILING_MODE at
#     parse time now, so a reload restores the mode instead of dropping it.
#   * The notification stays HERE. window-rules.sh is silent for every other
#     rule because the switch you just moved is the feedback; a keybind has no
#     switch on screen, so this is the one caller that needs to say something.

set -euo pipefail

RULES="${XDG_CONFIG_HOME:-$HOME/.config}/scripts/window-rules.sh"

now="$("$RULES" get WIN_TILING_MODE 2>/dev/null)" || now="false"
if [ "$now" = "true" ]; then next="false"; else next="true"; fi

# stdout is the value it settled on and is not wanted; a refusal goes to stderr
# and is left alone, so a failed flip is visible in the journal rather than
# swallowed under a notification claiming it worked.
"$RULES" set WIN_TILING_MODE "$next" >/dev/null

if [ "$next" = "true" ]; then
    notify-send "Tiling Mode 👽"
else
    notify-send "Floating Mode 👾"
fi
