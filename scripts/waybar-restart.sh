#!/usr/bin/env bash
# waybar-restart.sh
# Restarts Waybar every 30 minutes indefinitely.
# Launch via Hyprland: exec-once = ~/.config/hypr/waybar-restart.sh

INTERVAL=$((30 * 60))  # 30 minutes in seconds

while true; do
    sleep "$INTERVAL"
    pkill waybar
    sleep 1          # brief pause so the old process is fully gone
    waybar &
    disown
done
