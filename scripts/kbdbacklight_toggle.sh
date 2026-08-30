#!/bin/bash

# Machine-specific names come from the profile install.sh generates. Sourcing
# it (rather than hardcoding) is what lets this script run unmodified on any
# machine; the fallback keeps it working if the profile has not been written.
HW_ENV="${XDG_CONFIG_HOME:-$HOME/.config}/scripts/hardware.env"
# shellcheck source=/dev/null
[ -r "$HW_ENV" ] && . "$HW_ENV"

device="${KBD_BACKLIGHT_LED:-}"
# Not every laptop has a backlit keyboard; exit quietly rather than erroring on
# a key press that simply has nothing to do here.
[ -n "$device" ] || exit 0
[ -e "/sys/class/leds/$device" ] || exit 0

current=$(brightnessctl -d "$device" get | tr -d '[:space:]')  # Remove any spaces/newlines

if [[ "$current" == "0" ]]; then
    brightnessctl -d "$device" set 3
else
    brightnessctl -d "$device" set 0
fi

