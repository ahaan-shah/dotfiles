#!/bin/bash

# open hymission
hyprctl dispatch hymission:open

# wait until focus actually changes
prev=$(hyprctl activewindow -j | jq -r '.address')

while true; do
    sleep 0.05
    curr=$(hyprctl activewindow -j | jq -r '.address')

    if [ "$curr" != "$prev" ]; then
        break
    fi
done

# give it a tiny moment to settle
sleep 0.05

# force it to top
hyprctl dispatch bringactivetotop
