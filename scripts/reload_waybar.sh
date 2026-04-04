#!/bin/bash

while true; do
    sleep 1800
    pkill -SIGUSR2 waybar
done
