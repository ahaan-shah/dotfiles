#!/usr/bin/env bash
# Applies a wallpaper: hyprpaper reload, pywal colorscheme, Cava gradient
# sync, SwayOSD restart, Hyprland config reload. 1:1 port of the
# post-selection half of scripts/set_wallpaper.sh (the picker itself is now
# Wallpapers.qml's list, activated from Finder.qml) — same steps, same
# order, no `set -e`/`pipefail`, matching the original's best-effort style
# where one failing restart shouldn't abort the rest.
#
# Dropped from the original: the walker-restart block
# (update-walker-theme.sh, `gapplication quit dev.quoteme.Walker`,
# `walker --gapplication-service`) — walker is already fully replaced by
# finder/ project-wide, so those calls are dead code now. Also dropped the
# already-commented-out waybar/swaync/spicetify/notify-send lines from the
# original — they were inert there too, just noise here.

WALLPAPER_PATH="$1"
if [ -z "$WALLPAPER_PATH" ] || [ ! -f "$WALLPAPER_PATH" ]; then
    echo "usage: apply-wallpaper.sh <path-to-existing-image>" >&2
    exit 1
fi

HYPERPAPER_CONFIG="$HOME/.config/hypr/hyprpaper.conf"
CAVA_CONFIG="$HOME/.config/cava/config"

# Update hyprpaper.conf (assuming single monitor setup)
echo "wallpaper {" > "$HYPERPAPER_CONFIG"
echo "monitor = eDP-1" >> "$HYPERPAPER_CONFIG"
echo "path = $WALLPAPER_PATH" >> "$HYPERPAPER_CONFIG"
echo "fit_mode = cover" >> "$HYPERPAPER_CONFIG"
echo "}" >> "$HYPERPAPER_CONFIG"
echo "splash = false" >> "$HYPERPAPER_CONFIG"

# Restart Hyprpaper
pkill hyprpaper
hyprpaper & disown

# Apply pywal colorscheme
wal -i "$WALLPAPER_PATH"

# Update pywalfox
pywalfox update

# Hyprlock is gone (replaced by the Quickshell lockscreen/ app), which reads
# its background path live from $HYPERPAPER_CONFIG (already rewritten
# above), so there's no second config to keep in sync here anymore.

# Update Cava gradient colors
COLOR1=$(sed -n '2p' "$HOME/.cache/wal/colors")  # First pywal color
COLOR2=$(sed -n '3p' "$HOME/.cache/wal/colors")  # Second pywal color
COLOR3=$(sed -n '4p' "$HOME/.cache/wal/colors")  # Third pywal color

sed -i "s/^gradient_color_1 = .*/gradient_color_1 = '$COLOR1'/" "$CAVA_CONFIG"
sed -i "s/^gradient_color_2 = .*/gradient_color_2 = '$COLOR2'/" "$CAVA_CONFIG"
sed -i "s/^gradient_color_3 = .*/gradient_color_3 = '$COLOR3'/" "$CAVA_CONFIG"

# Restart SwayOSD
pkill swayosd-server
swayosd-server & disown

# Handle Cava restart in the same terminal window using screen
if pgrep -f cava > /dev/null; then
    CAVA_TTY=$(ps -o tty= -p "$(pgrep -f cava)")
    pkill cava
    sleep 1
    echo "cava" > "/dev/pts/${CAVA_TTY##/dev/pts/}"
else
    cava & disown
fi

# Reload Hyprland
hyprctl reload
