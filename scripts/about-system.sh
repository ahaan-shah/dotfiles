#!/usr/bin/env bash
# about-system.sh — the settings menu's About page: fastfetch, held open until a
# key is pressed.
#
# The `read` at the end is the whole reason this is a script rather than
# `kitty -e fastfetch`. A kitty spawned with -e closes the instant its command
# exits, so plain fastfetch paints the window and destroys it in the same frame
# — measured as a flash of a window that never becomes readable.
#
# Sizing is not done here. The window is sized by the `about-float` rule in
# hyprland.lua, which matches on this window's title; see the comment there for
# where its numbers come from.

set -euo pipefail

command -v fastfetch >/dev/null || { echo "fastfetch is not installed" >&2; exit 1; }

fastfetch

if [[ -t 1 ]]; then
    DIM=$(tput dim); RESET=$(tput sgr0)
else
    DIM=""; RESET=""
fi

printf '\n%sPress any key to close…%s ' "$DIM" "$RESET"
read -rsn1 _ || true
echo
