#!/bin/bash

WAL="$HOME/.cache/wal/colors.json"
THEME="$HOME/.config/spicetify/Themes/pywaldynamic/color.ini"

# Base + text
bg=$(jq -r '.colors.color0' $WAL | sed 's/#//')   # brighter background tone
fg=$(jq -r '.special.foreground' $WAL | sed 's/#//')

# Accent system
accent=$(jq -r '.colors.color4' $WAL | sed 's/#//')
accent2=$(jq -r '.colors.color5' $WAL | sed 's/#//')

# Surface layers
surface=$(jq -r '.colors.color0' $WAL | sed 's/#//')
surface2=$(jq -r '.colors.color1' $WAL | sed 's/#//')

# UI extras
subtext=$(jq -r '.colors.color7' $WAL | sed 's/#//')
error=$(jq -r '.colors.color1' $WAL | sed 's/#//')
notif=$(jq -r '.colors.color6' $WAL | sed 's/#//')

cat > "$THEME" <<EOF
[Pywal]

accent             = $accent
accent-active      = $accent2
accent-inactive    = $surface
banner             = $accent
border-active      = $accent
border-inactive    = $surface2
header             = $bg
highlight          = $accent2
main               = $bg
notification       = $notif
notification-error = $error
subtext            = $subtext
text               = $fg

EOF

#apply instantly if spotify is on otherwise apply and close spotify
if pgrep -x spotify > /dev/null; then
    spicetify apply
else
    spicetify apply
    pkill -x spotify 2>/dev/null
fi
