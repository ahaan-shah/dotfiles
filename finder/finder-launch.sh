#!/usr/bin/env bash
pkill -f "quickshell.*finder" 2>/dev/null
sleep 0.2
exec quickshell -c ~/.config/finder
