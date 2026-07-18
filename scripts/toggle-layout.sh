#!/usr/bin/env bash

STATE_FILE="/tmp/hypr_float_mode"

# Default state
if [[ ! -f "$STATE_FILE" ]]; then
    echo "float" > "$STATE_FILE"
fi

STATE=$(cat "$STATE_FILE")

if [[ "$STATE" == "float" ]]; then
    ########################################
    # FLOAT MODE -> TILED MODE
    ########################################

    # Turn OFF global float for future windows (was: sed-editing
    # hyprland.conf's global-float windowrule + hyprctl reload — dead now
    # that hyprland.lua is the live config. globalFloatRule is a global
    # defined in hyprland.lua for exactly this runtime toggle.)
    hyprctl eval 'globalFloatRule:set_enabled(false)'

    # Turn ON follow_mouse
    hyprctl eval 'hl.config({ input = { follow_mouse = 1 } })'

    # Convert all current windows to tiled.
    # (was: `hyprctl dispatch settiled address:...` — pre-0.55 positional
    # syntax; hyprctl dispatch is now shorthand for `eval 'hl.dispatch(...)'`
    # and needs a Lua dispatcher expression.)
    hyprctl clients -j | jq -r '.[].address' | while read -r addr; do
        hyprctl dispatch "hl.dsp.window.float({ action = 'unset', window = 'address:$addr' })"
    done

    notify-send "Tiling Mode 👽"

    echo "tile" > "$STATE_FILE"

else
    ########################################
    # TILED MODE -> FLOAT MODE
    ########################################

    # Turn ON global float for future windows
    hyprctl eval 'globalFloatRule:set_enabled(true)'

    # Turn OFF follow_mouse
    hyprctl eval 'hl.config({ input = { follow_mouse = 0 } })'

    # Convert all current windows to floating
    hyprctl clients -j | jq -r '.[].address' | while read -r addr; do
        hyprctl dispatch "hl.dsp.window.float({ action = 'set', window = 'address:$addr' })"
    done

    notify-send "Floating Mode 👾"

    echo "float" > "$STATE_FILE"
fi
