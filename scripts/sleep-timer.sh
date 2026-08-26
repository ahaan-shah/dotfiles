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

    # hypridle runs before_sleep_cmd (which raises the lockscreen) and holds
    # the delay inhibitor that keeps the machine awake until the session is
    # really locked. It is autostarted by hyprland.lua, but can be off if it
    # was toggled via idle-inhibitor.sh's "Always Awake". ensure-hypridle.sh
    # starts it detached and waits for the inhibitor to actually exist — see
    # that script for why `hypridle & disown; sleep 0.5` was not safe.
    ~/.config/scripts/ensure-hypridle.sh

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
