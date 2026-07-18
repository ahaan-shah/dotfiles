#!/bin/bash

DEVICE="asup1204:00-093a:2642-touchpad"
STATEFILE="/tmp/hypr-touchpad-disabled"

# `hyprctl keyword` is gone in 0.55+ (no live hyprlang keywords to patch under
# the Lua config format). The equivalent live update is calling hl.device()
# again at runtime via `hyprctl eval`.
if [ -f "$STATEFILE" ]; then
    hyprctl eval "hl.device({ name = '$DEVICE', enabled = true })"
    rm "$STATEFILE"
    notify-send "Touchpad Enabled"
else
    hyprctl eval "hl.device({ name = '$DEVICE', enabled = false })"
    touch "$STATEFILE"
    notify-send "Touchpad Disabled"
fi
