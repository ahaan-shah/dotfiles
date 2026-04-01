#!/bin/bash

# Define wallpaper directory
WALLPAPER_DIR="$HOME/Pictures/wallpapers"

# Select wallpaper using rofi
WALLPAPER=$(ls "$WALLPAPER_DIR" | rofi -dmenu -p "Select Wallpaper")

# Exit if no selection is made
[ -z "$WALLPAPER" ] && exit 1

# Full path to selected wallpaper
WALLPAPER_PATH="$WALLPAPER_DIR/$WALLPAPER"

# Config paths
HYPERPAPER_CONFIG="$HOME/.config/hypr/hyprpaper.conf"
HYPRLOCK_CONFIG="$HOME/.config/hypr/hyprlock.conf"
CAVA_CONFIG="$HOME/.config/cava/config"

# Update hyprpaper.conf (assuming single monitor setup)
echo "wallpaper {" > "$HYPERPAPER_CONFIG"
echo "monitor = eDP-1" >> $HYPERPAPER_CONFIG
echo "path = $WALLPAPER_PATH" >> $HYPERPAPER_CONFIG
echo "fit_mode = cover" >> $HYPERPAPER_CONFIG
echo "}" >> $HYPERPAPER_CONFIG
echo "splash = false" >> $HYPERPAPER_CONFIG

# Restart Hyprpaper
pkill hyprpaper
hyprpaper & disown

# Apply pywal colorscheme
wal -i "$WALLPAPER_PATH"

#Update Snappy-Switcher
#~/.config/scripts/snappy-switcher-pywaltheme.sh

#pkill snappy-switcher --daemon
#snappy-switcher --daemon & disown

# Update Spicetify theme from pywal colors
#~/.config/scripts/pywal-spicetify.sh

#Update pywalfox
pywalfox update

# Update Hyprlock background path while keeping other settings
sed -i "s|path = .*|path = $WALLPAPER_PATH|g" "$HYPRLOCK_CONFIG"

# Update Cava gradient colors
COLOR1=$(sed -n '2p' "$HOME/.cache/wal/colors")  # First pywal color
COLOR2=$(sed -n '3p' "$HOME/.cache/wal/colors")  # Second pywal color
COLOR3=$(sed -n '4p' "$HOME/.cache/wal/colors")  # Third pywal color

sed -i "s/^gradient_color_1 = .*/gradient_color_1 = '$COLOR1'/" "$CAVA_CONFIG"
sed -i "s/^gradient_color_2 = .*/gradient_color_2 = '$COLOR2'/" "$CAVA_CONFIG"
sed -i "s/^gradient_color_3 = .*/gradient_color_3 = '$COLOR3'/" "$CAVA_CONFIG"

# Restart Waybar to apply pywal colors
pkill waybar && waybar & disown

# Restart SwayNC (notification center)
pkill swaync && swaync & disown

# Handle Cava restart in the same terminal window using screen
if pgrep -f cava > /dev/null; then
    # Find the tty where cava is running
    CAVA_TTY=$(ps -o tty= -p $(pgrep -f cava))

    # Kill cava
    pkill cava

    # Wait for cava to fully terminate
    sleep 1

    # Attempt to send cava command to the same tty where it was running
    echo "cava" > /dev/pts/${CAVA_TTY##/dev/pts/}
else
    # If cava isn't running, start it normally
    cava & disown
fi

# Reload Hyprland (optional)
hyprctl reload

# Notify user
#notify-send "Wallpaper Updated"
