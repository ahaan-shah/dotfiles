#!/bin/bash

PID=$(pgrep -x hypridle)

if [ -n "$PID" ]; then
    pkill -x hypridle
    notify-send "Always Awake ☕️"
else
    # Detached with its own fds. Whatever spawns this script (a Hyprland
    # keybind, a shell) may hand it a pipe, and a hypridle that inherits one
    # dies of SIGPIPE the moment that pipe closes — taking its sleep inhibitor
    # with it, so the next suspend would proceed without locking. See
    # ensure-hypridle.sh for the measurement.
    setsid hypridle </dev/null >/dev/null 2>&1 &
    notify-send "Sorta Awake 😴"
fi

