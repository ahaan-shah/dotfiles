#!/usr/bin/env bash

# Options
options="Sleep\nShutdown\nReboot\nLogout"

# Show rofi menu
choice=$(echo -e "$options" | rofi -dmenu -i -p "Power" \
    -theme-str 'window {width: 30%;} listview {lines: 8;}')

case "$choice" in
    Sleep)
        systemctl suspend
        ;;
    Shutdown)
        systemctl poweroff
        ;;
    Reboot)
        systemctl reboot
        ;;
    Logout)
        # Detect session and log out properly
        if [ "$XDG_CURRENT_DESKTOP" = "Hyprland" ]; then
            hyprctl dispatch exit
        elif [ "$DESKTOP_SESSION" = "plasma" ]; then
            qdbus org.kde.ksmserver /KSMServer logout 0 0 0
        else
            pkill -KILL -u "$USER"
        fi
        ;;
esac

