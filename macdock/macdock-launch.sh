#!/usr/bin/env bash
# macdock-launch.sh  —  place in ~/.config/macdock/ and chmod +x

pkill -f "quickshell.*macdock" 2>/dev/null
sleep 0.2
exec quickshell -c ~/.config/macdock
