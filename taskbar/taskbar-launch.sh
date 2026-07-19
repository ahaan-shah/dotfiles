#!/usr/bin/env bash
# taskbar-launch.sh  —  place in ~/.config/taskbar/ and chmod +x

pkill -f "quickshell.*taskbar" 2>/dev/null
sleep 0.2
exec quickshell -c ~/.config/taskbar
