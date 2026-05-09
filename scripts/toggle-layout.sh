#!/usr/bin/env bash

CONFIG="$HOME/.config/hypr/hyprland.conf"
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

    # Turn OFF global float
    sed -i '/name = global-float/,/}/ s/float = on/float = off/' "$CONFIG"

    # Turn ON follow_mouse
    sed -i 's/follow_mouse = 0/follow_mouse = 1/' "$CONFIG"

    # Reload Hyprland
    hyprctl reload

    # Convert all current windows to tiled
    hyprctl clients -j | jq -r '.[].address' | while read -r addr; do
        hyprctl dispatch settiled address:"$addr"
    done

    notify-send "Tiling Mode 👽"

    echo "tile" > "$STATE_FILE"

else
    ########################################
    # TILED MODE -> FLOAT MODE
    ########################################

    # Turn ON global float
    sed -i '/name = global-float/,/}/ s/float = off/float = on/' "$CONFIG"

    # Turn OFF follow_mouse
    sed -i 's/follow_mouse = 1/follow_mouse = 0/' "$CONFIG"

    # Reload Hyprland
    hyprctl reload

    # Convert all current windows to floating
    hyprctl clients -j | jq -r '.[].address' | while read -r addr; do
        hyprctl dispatch setfloating address:"$addr"
    done

    notify-send "Floating Mode 👾"

    echo "float" > "$STATE_FILE"
fi
