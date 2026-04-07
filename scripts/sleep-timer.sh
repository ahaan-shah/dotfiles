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

# Wait and suspend
sleep "$seconds" && systemctl suspend
