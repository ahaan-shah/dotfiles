#!/bin/bash

STATE_FILE="$HOME/.cache/hypr_minimize_state"

# Get active window info
WIN_INFO=$(hyprctl activewindow -j)
ADDR=$(echo "$WIN_INFO" | jq -r '.address')
WS=$(echo "$WIN_INFO" | jq -r '.workspace.id')

# Check if window is already in special workspace
IS_SPECIAL=$(hyprctl clients -j | jq -r ".[] | select(.address == \"$ADDR\") | .workspace.name")

if [[ "$IS_SPECIAL" == "special:magic" ]]; then
    # Restore
    OLD_WS=$(grep "$ADDR" "$STATE_FILE" | awk '{print $2}')

    # hyprctl dispatch now takes a Lua dispatcher expression (shorthand for
    # `eval 'hl.dispatch(...)'`), not the old `dispatchname arg1,arg2` string.
    if [[ -n "$OLD_WS" ]]; then
        hyprctl dispatch "hl.dsp.window.move({ workspace = $OLD_WS, window = 'address:$ADDR' })"
        sed -i "/$ADDR/d" "$STATE_FILE"
    else
        hyprctl dispatch "hl.dsp.window.move({ workspace = 1, window = 'address:$ADDR' })"
    fi
else
    # Save state
    echo "$ADDR $WS" >> "$STATE_FILE"

    # Move to special workspace (silent = don't follow/switch to it)
    hyprctl dispatch "hl.dsp.window.move({ workspace = 'special:magic', follow = false, window = 'address:$ADDR' })"
fi
