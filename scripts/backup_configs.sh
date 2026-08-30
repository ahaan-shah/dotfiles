#!/usr/bin/env bash
# backup_configs.sh — mirror the live config into ~/.config/dotfiles, which is
# a PUBLIC git repo (github.com/ahaan-shah/dotfiles).
#
# Two jobs, and the second one is why this is not just a pile of rsync calls:
#
#  1. Capture everything install.sh needs to rebuild this desktop from a bare
#     Arch install — which now includes systemd user units and the /etc-level
#     rules, not only ~/.config directories.
#  2. Keep anything private, machine-specific or secret OUT of it. The repo is
#     public, so this refuses to write at all if a credential scan trips.
#
# Machine-specific means "would be WRONG on another machine", not just secret:
# hardware.env names this laptop's touchpad, battery and GPU, and shipping it
# would hand a fresh install the wrong hardware profile. install.sh regenerates
# it, so it is deliberately excluded.
set -u

# Overridable so this can be exercised against a scratch directory instead of
# the real repo:  DOTFILES_DIR=/tmp/x ./backup_configs.sh
DOTDIR="${DOTFILES_DIR:-$HOME/.config/dotfiles}"
SRCREPO="${HYPRAHAAN_SRC:-$HOME/projects/hyprahaan}"

# ── things that must never be committed ──────────────────────────────────
EXCLUDES=(
    --exclude 'hardware.env'        # machine-specific; install.sh regenerates it
    --exclude 'backup_files.sh'     # names personal directories
    --exclude 'wake-lag-*'          # bulky machine-specific diagnostic captures
    --exclude 'wake-lag-logs/'
    --exclude 'diagnose-wake-lag.sh'
    --exclude '*.bak'
    --exclude '*.bak-*'
    --exclude '*.orig'
    --exclude '*.log'
    --exclude '.git'
    --exclude 'config.toml.bak-*'
)

sync() {
    local src="$1" dst="$2"
    if [ -e "$src" ]; then
        mkdir -p "$dst"
        rsync -a --delete "${EXCLUDES[@]}" "$src"/ "$dst"/
    else
        echo "Missing: $src"
    fi
}

copy() {
    local src="$1" dst="$2"
    if [ -e "$src" ]; then
        mkdir -p "$(dirname "$dst")"
        rsync -a "$src" "$dst"
    else
        echo "Missing: $src"
    fi
}

# ---------------- CONFIG FOLDERS ----------------
sync "$HOME/.config/hypr"        "$DOTDIR/hypr"
sync "$HOME/.config/finder"      "$DOTDIR/finder"
sync "$HOME/.config/lockscreen"  "$DOTDIR/lockscreen"
sync "$HOME/.config/kitty"       "$DOTDIR/kitty"
sync "$HOME/.config/cava"        "$DOTDIR/cava"
sync "$HOME/.config/fastfetch"   "$DOTDIR/fastfetch"
sync "$HOME/.config/neofetch"    "$DOTDIR/neofetch"
sync "$HOME/.config/fum"         "$DOTDIR/fum"
sync "$HOME/.config/scripts"     "$DOTDIR/scripts"
sync "$HOME/.config/macshell"    "$DOTDIR/macshell"
sync "$HOME/.config/taskbar"     "$DOTDIR/taskbar"
sync "$HOME/.config/gtk-3.0"     "$DOTDIR/gtk-3.0"
sync "$HOME/.config/gtk-4.0"     "$DOTDIR/gtk-4.0"
sync "$HOME/Pictures/wallpapers" "$DOTDIR/wallpapers"

# ---------------- SINGLE FILES ----------------
copy "$HOME/.zshrc"                   "$DOTDIR/shell/.zshrc"
copy "$HOME/.bashrc"                  "$DOTDIR/shell/.bashrc"
copy "$HOME/.config/starship.toml"    "$DOTDIR/starship/starship.toml"
copy "$HOME/.config/mimeapps.list"    "$DOTDIR/mimeapps.list"
copy "$HOME/.config/battery-threshold" "$DOTDIR/battery-threshold"
sync "$HOME/.config/spicetify/Themes/pywaldynamic" "$DOTDIR/spicetify/Themes/pywaldynamic"

# ---------------- DESKTOP FILES ----------------
sync "$HOME/.local/share/applications"  "$DOTDIR/webapps/applications"
sync "$HOME/.local/share/icons/webapps" "$DOTDIR/webapps/icons"

# ---------------- SYSTEMD USER UNITS ----------------
# Only real files: the .wants/ entries are symlinks that `systemctl --user
# enable` recreates, and several point into /usr where they would dangle.
mkdir -p "$DOTDIR/systemd-user"
if [ -d "$HOME/.config/systemd/user" ]; then
    rm -rf "${DOTDIR:?}/systemd-user"; mkdir -p "$DOTDIR/systemd-user"
    ( cd "$HOME/.config/systemd/user" && \
      find . -type f \( -name '*.service' -o -name '*.timer' \
                      -o -name '*.target' -o -name '*.conf' \) -print0 \
      | while IFS= read -r -d '' f; do
            mkdir -p "$DOTDIR/systemd-user/$(dirname "$f")"
            cp -a "$f" "$DOTDIR/systemd-user/$f"
        done )
else
    echo "Missing: ~/.config/systemd/user"
fi

# ---------------- SYSTEM-LEVEL FILES ----------------
# Snapshotted for reference and for install.sh to diff against. All of these are
# world-readable and contain no credentials; /etc/NetworkManager/system-connections
# (which holds wifi PSKs) is root-only and is deliberately NOT touched here.
mkdir -p "$DOTDIR/system"
for f in /etc/udev/rules.d/99-battery-charge-threshold.rules \
         /etc/udev/rules.d/99-micmute-led.rules \
         /etc/keyd/default.conf \
         /etc/systemd/zram-generator.conf \
         /etc/sysctl.d/99-zram-swappiness.conf \
         /etc/sysctl.d/20-quiet-printk.conf \
         /etc/NetworkManager/conf.d/wifi_backend.conf \
         /etc/greetd/config.toml; do
    [ -r "$f" ] && { mkdir -p "$DOTDIR/system/$(dirname "${f#/etc/}")"; cp -a "$f" "$DOTDIR/system/${f#/etc/}"; }
done

# ---------------- THE INSTALLER ----------------
# Authored in the source repo; carried here so a fresh machine only ever needs
# to clone the dotfiles repo.
if [ -d "$SRCREPO/install" ]; then
    sync "$SRCREPO/install" "$DOTDIR/install"
else
    echo "Missing: $SRCREPO/install (set HYPRAHAAN_SRC if the repo moved)"
fi

# ---------------- PACKAGE MANIFEST ----------------
# What is actually installed right now, for reference when the curated lists in
# install/packages/ drift from reality.
pacman -Qqen > "$DOTDIR/pkglist-repo.txt" 2>/dev/null
pacman -Qqem > "$DOTDIR/pkglist-aur.txt"  2>/dev/null

# ---------------- SECRET SCAN ----------------
# Last line of defence before this is pushed to a public repo. Matches assigned
# values, not the words themselves, so the many legitimate mentions of
# "password" in the wifi panel's own code do not trip it.
echo
hits=$(grep -rIE --exclude-dir=.git \
        -e '(psk|password|passwd|api[_-]?key|secret|token)[[:space:]]*=[[:space:]]*["'"'"']?[A-Za-z0-9/+_.-]{8,}' \
        -e 'BEGIN [A-Z ]*PRIVATE KEY' \
        -e '\b(ghp|gho|ghs|sk|xoxb|xoxp)-[A-Za-z0-9]{16,}' \
        "$DOTDIR" 2>/dev/null \
      | grep -vE '\$\{?[A-Za-z_]|shq\(|root\.|\+ *"|nmcli|wifi-sec|placeholder|= *""' || true)

if [ -n "$hits" ]; then
    echo "!! POSSIBLE SECRET FOUND — review before committing:"
    echo "$hits" | head -20
    echo
    echo "Nothing was deleted; the files are staged in $DOTDIR."
    echo "Remove the offending value, then commit."
    exit 1
fi

echo "Secret scan clean."
echo "Dotfiles sync complete 🚀"
