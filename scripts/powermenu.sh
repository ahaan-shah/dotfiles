#!/usr/bin/env bash

# Options
options="Sleep\nShutdown\nReboot\nLogout"

# Show rofi menu
choice=$(echo -e "$options" | rofi -dmenu -i -p "Power" \
    -theme-str 'window {width: 30%;} listview {lines: 8;}')

case "$choice" in
    Sleep)
        pkill rofi
        sleep 0.2
	hypridle & disown
	sleep 0.1
        loginctl lock-session
        sleep 0.2
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

