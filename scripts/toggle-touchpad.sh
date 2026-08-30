#!/bin/bash

# Machine-specific names come from the profile install.sh generates. Sourcing
# it (rather than hardcoding) is what lets this script run unmodified on any
# machine; the fallback keeps it working if the profile has not been written.
HW_ENV="${XDG_CONFIG_HOME:-$HOME/.config}/scripts/hardware.env"
# shellcheck source=/dev/null
[ -r "$HW_ENV" ] && . "$HW_ENV"

DEVICE="${TOUCHPAD_DEVICE:-}"
STATEFILE="/tmp/hypr-touchpad-disabled"

if [ -z "$DEVICE" ]; then
    notify-send "Touchpad" "No touchpad in the hardware profile. Run: install.sh --only hardware"
    exit 0
fi

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
