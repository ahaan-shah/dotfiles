#!/bin/bash
# Re-applies the saved charge-threshold cap on every Hyprland start, since
# BAT0/charge_control_end_threshold resets to 100 on boot. The taskbar
# battery panel writes the chosen value to $state_file directly (no root —
# see hypr/scripts udev rule that group-writes the sysfs attribute).

threshold_file="/sys/class/power_supply/BAT0/charge_control_end_threshold"
state_file="$HOME/.config/battery-threshold"

value=$(cat "$state_file" 2>/dev/null)
[[ "$value" =~ ^[0-9]+$ ]] || value=100

echo "$value" > "$threshold_file" 2>/tmp/apply-battery-threshold.err
