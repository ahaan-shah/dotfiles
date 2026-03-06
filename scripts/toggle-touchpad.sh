#!/bin/bash

DEVICE="asup1204:00-093a:2642-touchpad"
STATEFILE="/tmp/hypr-touchpad-disabled"

if [ -f "$STATEFILE" ]; then
    hyprctl keyword "device[$DEVICE]:enabled" true
    rm "$STATEFILE"
    notify-send "Touchpad Enabled"
else
    hyprctl keyword "device[$DEVICE]:enabled" false
    touch "$STATEFILE"
    notify-send "Touchpad Disabled"
fi
