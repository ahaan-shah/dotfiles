#!/bin/bash

DOTDIR="$HOME/.config/dotfiles"

sync() {
    local src="$1"
    local dst="$2"

    if [ -e "$src" ]; then
        mkdir -p "$dst"
        rsync -a --delete "$src"/ "$dst"/
        #echo "Synced $src → $dst"
    else
        echo "Missing: $src"
    fi
}

# ---------------- CONFIG FOLDERS ----------------
sync "$HOME/.config/hypr"        "$DOTDIR/hypr"
sync "$HOME/.config/waybar"      "$DOTDIR/waybar"
sync "$HOME/.config/rofi"        "$DOTDIR/rofi"
sync "$HOME/.config/walker"      "$DOTDIR/walker"
sync "$HOME/.config/elephant"    "$DOTDIR/elephant"
sync "$HOME/.config/kitty"       "$DOTDIR/kitty"
sync "$HOME/.config/cava"        "$DOTDIR/cava"
sync "$HOME/.config/fastfetch"   "$DOTDIR/fastfetch"
sync "$HOME/.config/neofetch"    "$DOTDIR/neofetch"
sync "$HOME/.config/fum"         "$DOTDIR/fum"
sync "$HOME/.config/swaync"      "$DOTDIR/swaync"
sync "$HOME/.config/swayosd"     "$DOTDIR/swayosd"
sync "$HOME/.config/scripts"     "$DOTDIR/scripts"

# ---------------- SINGLE FILES ----------------
mkdir -p "$DOTDIR/shell"
rsync -a "$HOME/.zshrc" "$DOTDIR/shell/.zshrc"
rsync -a "$HOME/.bashrc" "$DOTDIR/shell/.bashrc"

mkdir -p "$DOTDIR/spicetify/Themes"
rsync -a "$HOME/.config/spicetify/Themes/pywaldynamic" "$DOTDIR/spicetify/Themes"

mkdir -p "$DOTDIR"
rsync -a "$HOME/.config/starship.toml" "$DOTDIR/starship/starship.toml"

# ---------------- DESKTOP FILES ----------------
sync "$HOME/.local/share/applications" "$DOTDIR/webapps/applications"
sync "$HOME/.local/share/icons/webapps" "$DOTDIR/webapps/icons"

echo ""
echo "Dotfiles sync complete 🚀"

