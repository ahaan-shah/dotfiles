#!/bin/bash

device="asus::kbd_backlight"
current=$(brightnessctl -d "$device" get | tr -d '[:space:]')  # Remove any spaces/newlines

if [[ "$current" == "0" ]]; then
    brightnessctl -d "$device" set 3
else
    brightnessctl -d "$device" set 0
fi

