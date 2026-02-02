#!/bin/bash

BRIGHTNESS=$(brightnessctl get)
MAX_BRIGHTNESS=$(brightnessctl max)
PERCENT=$((BRIGHTNESS * 100 / MAX_BRIGHTNESS))

echo "{\"text\":\"󰃠\",\"tooltip\":\"Brightness: $PERCENT%\"}"
