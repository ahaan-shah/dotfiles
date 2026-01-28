#!/bin/bash

# Battery notification script for Hyprland with SwayNC
# Dependencies: upower, libnotify

# Thresholds for low battery notifications
notify_levels=(20 10 5)
BAT0=$(ls /sys/class/power_supply | grep BAT0 | head -n 1)
last_notify=100
last_status="Unknown"
LOGFILE="/tmp/battery_notify.log"

# Check if BAT0 was found
if [ -z "$BAT0" ]; then
    echo "$(date): Error: No BAT0 found in /sys/class/power_supply" >> "$LOGFILE"
    exit 1
fi

# Check if required files exist
if [ ! -f "/sys/class/power_supply/$BAT0/capacity" ] || [ ! -f "/sys/class/power_supply/$BAT0/status" ]; then
    echo "$(date): Error: capacity or status file missing for $BAT0" >> "$LOGFILE"
    exit 1
fi

echo "$(date): Script started, monitoring $BAT0" >> "$LOGFILE"

while true; do
    # Get battery percentage and status
    bat_lvl=$(cat /sys/class/power_supply/$BAT0/capacity 2>/dev/null)
    status=$(cat /sys/class/power_supply/$BAT0/status 2>/dev/null)

    # Log current state
    echo "$(date): Battery: $bat_lvl%, Status: $status, Last Notify: $last_notify, Last Status: $last_status" >> "$LOGFILE"

    # Check if reading was successful
    if [ -z "$bat_lvl" ] || [ -z "$status" ]; then
        echo "$(date): Error: Failed to read battery level or status" >> "$LOGFILE"
        sleep 60
        continue
    fi

    # Check for charging status change
    if [ "$status" = "Charging" ] && [ "$last_status" != "Charging" ]; then
        notify-send -u normal -t 3000 "Charging Started ⚡️" "$bat_lvl% battery, now charging." -h string:x-canonical-private-synchronous:battery
        echo "$(date): Sent charging notification at $bat_lvl%" >> "$LOGFILE"
    fi

    # Only send low battery notifications when discharging
    if [ "$status" = "Discharging" ]; then
        # Check if battery level has increased above last_notify
        if [ "$bat_lvl" -gt "$last_notify" ]; then
            last_notify=$bat_lvl
        fi

        # Check each notification level
        for notify_level in "${notify_levels[@]}"; do
            if [ "$bat_lvl" -le "$notify_level" ] && [ "$notify_level" -lt "$last_notify" ]; then
                notify-send -u critical -t 3000 "Low Battery ❗" "$bat_lvl% battery remaining." -h string:x-canonical-private-synchronous:battery
                echo "$(date): Sent low battery notification at $bat_lvl%" >> "$LOGFILE"
                last_notify=$bat_lvl
            fi
        done
    else
        # Reset last_notify when not discharging to allow notifications when discharging again
        last_notify=100
    fi

    # Update last_status
    last_status=$status

    # Sleep for 60 seconds
    sleep 1
done
