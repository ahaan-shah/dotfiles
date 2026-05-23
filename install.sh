#!/usr/bin/env bash

set -e

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "================================================"
echo "        Dotfiles Installer"
echo "================================================"

# ── Helpers ────────────────────────────────────────────────────────────────────

make_dir() {
    if [ ! -d "$1" ]; then
        mkdir -p "$1"
        echo "  Created directory: $1"
    fi
}

link() {
    local src="$1"
    local dst="$2"
    if [ -e "$dst" ] || [ -L "$dst" ]; then
        echo "  [skip] $dst already exists (remove it manually to re-link)"
    else
        ln -s "$src" "$dst"
        echo "  Linked: $src -> $dst"
    fi
}

# ── 1. Install yay ─────────────────────────────────────────────────────────────

echo ""
echo "[1/7] Installing yay (AUR helper) ..."

if command -v yay &> /dev/null; then
    echo "  yay already installed, skipping"
else
    echo "  Installing yay dependencies..."
    sudo pacman -S --needed --noconfirm git base-devel

    TMP_YAY=$(mktemp -d)
    git clone https://aur.archlinux.org/yay.git "$TMP_YAY"
    cd "$TMP_YAY"
    makepkg -si --noconfirm
    cd "$DOTFILES_DIR"
    rm -rf "$TMP_YAY"
    echo "  yay installed successfully"
fi

# ── 2. Install pacman packages ─────────────────────────────────────────────────

echo ""
echo "[2/7] Installing pacman packages ..."

PACMAN_PACKAGES=(
    # Shell & terminal
    zsh
    starship
    fastfetch
    neofetch
    yazi
    dysk

    # Hyprland ecosystem
    hypridle
    hyprlock
    hyprpaper

    # Wayland utilities
    waybar
    rofi
    swaync

    # Browsers & apps
    chromium
    nautilus
    gnome-text-editor

    # Scripting deps
    python
    socat
    jq
    go
)

sudo pacman -S --needed --noconfirm "${PACMAN_PACKAGES[@]}"

# ── 3. Install AUR packages ────────────────────────────────────────────────────

echo ""
echo "[3/7] Installing AUR packages ..."

AUR_PACKAGES=(
    # Elephant suite
    elephant
    elephant-desktopapplications
    elephant-symbols
    elephant-runner
    elephant-calc
    elephant-clipboard
    elephant-websearch
    elephant-files

    # Hyprland AUR extras
    quickshell
    swayosd

    # Other AUR
    fum
    walker
    librewolf-bin
    spotify
    spicetify-cli
)

yay -S --needed --noconfirm "${AUR_PACKAGES[@]}"

# ── 4. ~/.config — everything except the special cases ────────────────────────

echo ""
echo "[4/7] Linking config directories to ~/.config ..."
make_dir "$HOME/.config"

for item in "$DOTFILES_DIR"/*/; do
    name="$(basename "$item")"
    case "$name" in
        webapps|shell|wallpapers) continue ;;
    esac
    link "$item" "$HOME/.config/$name"
done

# Also link any loose files at repo root that belong in ~/.config
for item in "$DOTFILES_DIR"/*; do
    name="$(basename "$item")"
    if [ -f "$item" ]; then
        case "$name" in
            fprintstuff.txt|install.sh|README*|LICENSE*) continue ;;
        esac
        link "$item" "$HOME/.config/$name"
    fi
done

# ── 5. webapps ─────────────────────────────────────────────────────────────────

echo ""
echo "[5/7] Installing webapps ..."

WEBAPPS_SRC="$DOTFILES_DIR/webapps"

if [ -d "$WEBAPPS_SRC/applications" ]; then
    make_dir "$HOME/.local/share/applications"
    for entry in "$WEBAPPS_SRC/applications/"*; do
        [ -e "$entry" ] || continue
        link "$entry" "$HOME/.local/share/applications/$(basename "$entry")"
    done
fi

if [ -d "$WEBAPPS_SRC/icons" ]; then
    make_dir "$HOME/.local/share/icons/webapps"
    for icon in "$WEBAPPS_SRC/icons/"*; do
        [ -e "$icon" ] || continue
        link "$icon" "$HOME/.local/share/icons/webapps/$(basename "$icon")"
    done
fi

# ── 6. Misc home files ─────────────────────────────────────────────────────────

echo ""
echo "[6/7] Linking misc home files ..."

if [ -f "$DOTFILES_DIR/fprintstuff.txt" ]; then
    link "$DOTFILES_DIR/fprintstuff.txt" "$HOME/fprintstuff.txt"
else
    echo "  [warn] fprintstuff.txt not found, skipping"
fi

if [ -d "$DOTFILES_DIR/wallpapers" ]; then
    make_dir "$HOME/Pictures"
    link "$DOTFILES_DIR/wallpapers" "$HOME/Pictures/wallpapers"
else
    echo "  [warn] wallpapers directory not found, skipping"
fi

for rc in .bashrc .zshrc; do
    src="$DOTFILES_DIR/shell/$rc"
    dst="$HOME/$rc"
    if [ -f "$src" ]; then
        link "$src" "$dst"
    else
        echo "  [warn] $src not found, skipping"
    fi
done

# ── 7. chmod scripts ───────────────────────────────────────────────────────────

echo ""
echo "[7/7] Making scripts executable ..."

find "$DOTFILES_DIR" -type f -name "*.sh" | while read -r script; do
    chmod +x "$script"
    echo "  chmod +x $script"
done

for dir in bin scripts; do
    if [ -d "$DOTFILES_DIR/$dir" ]; then
        find "$DOTFILES_DIR/$dir" -type f | while read -r script; do
            chmod +x "$script"
            echo "  chmod +x $script"
        done
    fi
done

# ── Done ───────────────────────────────────────────────────────────────────────

echo ""
echo "================================================"
echo "  All done!"
echo "  Set zsh as your default shell with:"
echo "    chsh -s \$(which zsh)"
echo "  Then log out and back in."
echo "================================================"
