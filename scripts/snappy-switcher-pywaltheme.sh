#!/bin/bash

readarray -t colors < ~/.cache/wal/colors

cat > ~/.config/snappy-switcher/themes/pywal.ini <<EOF
[colors]
background = ${colors[0]}
card_bg = ${colors[0]}
card_selected = ${colors[8]}
text_color = ${colors[7]}
subtext_color = ${colors[5]}
border_color = ${colors[4]}
EOF
