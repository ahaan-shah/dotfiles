#!/bin/bash

# Ask user for minutes
read -p "Enter sleep timer (in minutes): " minutes

# Validate input (must be a number)
if ! [[ "$minutes" =~ ^[0-9]+$ ]]; then
    echo "Please enter a valid number."
    exit 1
fi

# Convert minutes to seconds
seconds=$((minutes * 60))

echo "System will suspend in $minutes minutes..."
notify-send "Arch will sleep soon 🌙"
# Run everything detached
(
    sleep "$seconds"

    # Make sure hypridle is actually running — it's the thing that catches
    # the logind Lock signal and runs lock_cmd (lockscreen-launch.sh) via
    # before_sleep_cmd in hypridle.conf. It's already autostarted by
    # hyprland.lua, so only spawn it if it's somehow dead (e.g. killed via
    # idle-inhibitor.sh's "Always Awake" toggle and never turned back on) —
    # spawning it unconditionally piled up duplicate/orphaned hypridle
    # processes on every single sleep-timer run.
    pgrep -x hypridle >/dev/null || { hypridle & disown; sleep 0.5; }

    # Suspend system. hypridle.conf's before_sleep_cmd already runs
    # `loginctl lock-session` itself (systemd holds a sleep inhibitor until
    # that finishes), so a second manual loginctl call here was redundant —
    # and racing it against a fixed `sleep 0.2` before suspend was the
    # actual bug: 200ms isn't guaranteed enough for the lock surface to
    # finish coming up, so suspend could occasionally win the race and the
    # system would resume unlocked.
    systemctl suspend

) >/dev/null 2>&1 & disown

# Exit immediately so terminal closes
exit
