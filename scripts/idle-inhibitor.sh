#!/bin/bash

PID=$(pgrep -x hypridle)

if [ -n "$PID" ]; then
    pkill -x hypridle
    notify-send "Hypridle Inactive"
else
    hypridle &
    disown
    notify-send "Hypridle Active"
fi

