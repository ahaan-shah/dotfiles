#!/bin/bash

VOLUME=$(pactl get-sink-volume @DEFAULT_SINK@ | awk '{print $5}' | sed 's/%//')

# Cap the volume at 100%
if [[ "$VOLUME" -gt 100 ]]; then
    VOLUME=100
    pactl set-sink-volume @DEFAULT_SINK@ 100%
fi

MUTED=$(pactl get-sink-mute @DEFAULT_SINK@ | grep -oE 'Mute: yes')

if [[ "$MUTED" == "Mute: yes" ]]; then
    ICON=""  # Muted icon
    TOOLTIP="Muted"
else
    ICON=""  # Volume icon
    TOOLTIP="Volume: $VOLUME%"
fi

echo "{\"text\":\"$ICON\",\"tooltip\":\"$TOOLTIP\"}"

