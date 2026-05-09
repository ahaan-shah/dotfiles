#!/bin/bash

PID=$(pgrep -x hypridle)

if [ -n "$PID" ]; then
    pkill -x hypridle
    notify-send "Always Awake ☕️"
else
    hypridle &
    disown
    notify-send "Sorta Awake 😴"
fi

