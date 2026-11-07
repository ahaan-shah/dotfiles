#!/usr/bin/env bash
#
# bootstrap.sh — the one line. From a minimal Arch install (archinstall's
# "minimal" profile, a working network, a user with sudo), logged in as that
# user on a TTY:
#
#   curl -fsSL https://raw.githubusercontent.com/ahaan-shah/dotfiles/main/install/bootstrap.sh | bash
#
# It asks for the sudo password once and shows three numbered lists (the AUR
# packages, the web apps, the extras) to exclude from, all in the first minutes, then
# needs nothing else from you. Extra arguments go to install.sh:
# `| bash -s -- --no-aur` to exclude a list in advance, `--yes` to be asked nothing, or `--interactive` to be asked at
# each decision instead of taking its defaults.
#
# Everything lives in main(), called on the last line, so a download cut off
# halfway runs nothing rather than half of this. It also has to stay usable
# through a pipe: bash is reading this script from stdin, so nothing here may
# read stdin, and a child that does gets </dev/tty.
set -euo pipefail

REPO="${HYPRAHAAN_REPO:-https://github.com/ahaan-shah/dotfiles.git}"
BRANCH="${HYPRAHAAN_BRANCH:-main}"
DEST="${HYPRAHAAN_DEST:-$HOME/.config/dotfiles}"

say() { printf '\033[1;34m::\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m!!\033[0m %s\n' "$*" >&2; exit 1; }

main() {
    [ -r /etc/arch-release ] || die "this needs Arch Linux (no /etc/arch-release)"
    [ -d /run/archiso ] && die "this is the Arch ISO. Run archinstall first (profile: minimal), reboot, log in as your user, then run this line."
    [ "$(id -u)" -ne 0 ] || die "run this as your normal user, not root: it installs into \$HOME and calls sudo itself."
    command -v sudo >/dev/null 2>&1 || die "sudo is not installed. In archinstall, give your user sudo rights (or: su -c 'pacman -S sudo')."

    # Before anything slow. A sudo that cannot work should fail in the first
    # second, not after the clone. -v asks on /dev/tty, not stdin.
    say "sudo is needed for packages and system files"
    sudo -v || die "sudo refused. Is $USER in the wheel group, with wheel enabled in sudoers?"

    if ! curl -fsSI --max-time 15 https://archlinux.org >/dev/null 2>&1; then
        die "no network. On wifi: nmcli device wifi connect <ssid> --ask (or iwctl), then run this again."
    fi

    # A minimal install has no git, and pacman is the only thing that can fix
    # that. -Sy alone would be a partial upgrade, so only the name is fetched
    # when the package is absent; install.sh does the full -Syu right after.
    if ! command -v git >/dev/null 2>&1; then
        say "installing git"
        sudo pacman -Syu --needed --noconfirm git </dev/tty
    fi

    if [ -d "$DEST/.git" ]; then
        say "updating $DEST"
        git -C "$DEST" pull --ff-only || say "could not fast-forward; using it as it stands"
    else
        [ ! -e "$DEST" ] || die "$DEST exists and is not a git clone. Move it aside and run this again."
        say "cloning $REPO"
        mkdir -p "$(dirname "$DEST")"
        git clone --depth 1 --branch "$BRANCH" "$REPO" "$DEST"
    fi

    # --yes unless asked otherwise: the point of one line is that it finishes
    # while you are away. Every default is what this desktop is set up as. The one
    # thing still asked is what goes on the machine, and install.sh asks that before
    # the long part. Passing --yes here means not even that.
    local yes=(--yes --ask-sets) a
    local pass=()
    for a in "$@"; do
        case "$a" in
            --interactive) yes=() ;;
            --yes|-y) yes=(--yes) ;;
            *) pass+=("$a") ;;
        esac
    done
    exec "$DEST/install/install.sh" "${yes[@]}" ${pass[@]+"${pass[@]}"} </dev/tty
}

main "$@"
