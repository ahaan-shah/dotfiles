#!/bin/bash

# Function to backup a configuration file
backup_file() {
    local src="$1"
    local dst="$2"

    if [ -f "$src" ]; then
        cp -p "$src" "$dst"
#        echo "Backed up $src to $dst"
    else
        echo "Warning: Source file $src does not exist."
    fi
}

# Backup configurations
backup_file "/home/ahaan/.config/cava/config" "/home/ahaan/.config/bkps/cava/configbkp"
backup_file "/home/ahaan/.config/fastfetch/config.jsonc" "/home/ahaan/.config/bkps/fastfetch/configbkp.jsonc"
backup_file "/home/ahaan/.config/hypr/hypridle.conf" "/home/ahaan/.config/bkps/hypr/hypridlebkp.conf"
backup_file "/home/ahaan/.config/hypr/hyprlock.conf" "/home/ahaan/.config/bkps/hypr/hyprlockbkp.conf"
backup_file "/home/ahaan/.config/hypr/hyprpaper.conf" "/home/ahaan/.config/bkps/hypr/hyprpaperbkp.conf"
backup_file "/home/ahaan/.config/hypr/hyprland.conf" "/home/ahaan/.config/bkps/hypr/hyprlandbkp.conf"
backup_file "/home/ahaan/.config/kitty/kitty.conf" "/home/ahaan/.config/bkps/kitty/kittybkp.conf"
backup_file "/home/ahaan/.config/neofetch/config.conf" "/home/ahaan/.config/bkps/neofetch/configbkp.conf"
backup_file "/home/ahaan/.config/rofi/config.rasi" "/home/ahaan/.config/bkps/rofi/configbkp.rasi"
backup_file "/home/ahaan/.config/swaync/config.json" "/home/ahaan/.config/bkps/swaync/configbkp.json"
backup_file "/home/ahaan/.config/swaync/style.css" "/home/ahaan/.config/bkps/swaync/stylebkp.css"
backup_file "/home/ahaan/.config/waybar/config.jsonc" "/home/ahaan/.config/bkps/waybar/configbkp.jsonc"
backup_file "/home/ahaan/.config/waybar/style.css" "/home/ahaan/.config/bkps/waybar/stylebkp.css"
backup_file "/home/ahaan/.config/wlogout/layout" "/home/ahaan/.config/bkps/wlogout/layoutbkp"
backup_file "/home/ahaan/.config/wlogout/style.css" "/home/ahaan/.config/bkps/wlogout/stylebkp.css"
backup_file "/home/ahaan/.bashrc" "/home/ahaan/.config/bkps/bash/bashrcbkp"

echo ""
echo "Backup process completed."
