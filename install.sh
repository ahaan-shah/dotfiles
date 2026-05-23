#!/usr/bin/env bash

set -e

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Installing dotfiles from: $DOTFILES_DIR"

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

# ── 1. ~/.config — everything except the special cases ────────────────────────

echo ""
echo "[1/5] Linking config directories to ~/.config ..."
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

# ── 2. webapps ─────────────────────────────────────────────────────────────────

echo ""
echo "[2/5] Installing webapps ..."

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

# ── 3. fprintstuff.txt → ~ ─────────────────────────────────────────────────────

echo ""
echo "[3/5] Linking fprintstuff.txt ..."
if [ -f "$DOTFILES_DIR/fprintstuff.txt" ]; then
    link "$DOTFILES_DIR/fprintstuff.txt" "$HOME/fprintstuff.txt"
else
    echo "  [warn] fprintstuff.txt not found, skipping"
fi

# ── 4. wallpapers → ~/Pictures/ ───────────────────────────────────────────────

echo ""
echo "[4/5] Linking wallpapers ..."
if [ -d "$DOTFILES_DIR/wallpapers" ]; then
    make_dir "$HOME/Pictures"
    link "$DOTFILES_DIR/wallpapers" "$HOME/Pictures/wallpapers"
else
    echo "  [warn] wallpapers directory not found, skipping"
fi

# ── 5. shell — .bashrc and .zshrc → ~ ─────────────────────────────────────────

echo ""
echo "[5/5] Linking shell files ..."

for rc in .bashrc .zshrc; do
    src="$DOTFILES_DIR/shell/$rc"
    dst="$HOME/$rc"
    if [ -f "$src" ]; then
        link "$src" "$dst"
    else
        echo "  [warn] $src not found, skipping"
    fi
done

# ── chmod any scripts ──────────────────────────────────────────────────────────

echo ""
echo "[+] Making scripts executable ..."

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
echo "Done! You may need to restart your shell for changes to take effect."
echo "  source ~/.bashrc   # if using bash"
echo "  source ~/.zshrc    # if using zsh"
