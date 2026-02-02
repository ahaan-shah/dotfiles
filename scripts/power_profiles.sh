#!/usr/bin/env bash

# Get current profile
current=$(powerprofilesctl get)

# Options (mark current one)
options="Power Saver\nBalanced\nPerformance"

choice=$(echo -e "$options" | rofi -dmenu -i -p "Current: ($current)" \
-theme-str 'window {width: 30%;} listview {lines: 8;}')

case "$choice" in
    "Power Saver")
        powerprofilesctl set power-saver
        ;;
    "Balanced")
        powerprofilesctl set balanced
        ;;
    "Performance")
        powerprofilesctl set performance
        ;;
esac

