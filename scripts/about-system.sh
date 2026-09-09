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

# fastfetch's Shell row is not $SHELL — it walks up the process tree and reports
# the first shell it finds. Run bare from here that is *this script's* bash, so
# the About page read "bash 5.3.15" on a box whose login shell is zsh.
#
# So give fastfetch the login shell as its real parent. The trailing `; exit`
# is load-bearing: both zsh and bash exec-replace themselves with the last
# command of a -c string, which would hand fastfetch straight back to this
# bash and print "bash" again — measured. A second command defeats that
# optimisation, and `exit` (a builtin, so still no exec) carries fastfetch's
# status out. $SHELL over a hardcoded name because nothing machine-specific
# belongs in here; getent covers $SHELL being unset or stale.
login_shell=${SHELL:-}
[[ -x ${login_shell:-/nonexistent} ]] || login_shell=$(getent passwd "$(id -u)" | cut -d: -f7)

if [[ -x ${login_shell:-/nonexistent} ]]; then
    "$login_shell" -c 'fastfetch; exit'
else
    fastfetch
fi

if [[ -t 1 ]]; then
    DIM=$(tput dim); RESET=$(tput sgr0)
else
    DIM=""; RESET=""
fi

printf '\n%sPress any key to close…%s ' "$DIM" "$RESET"
read -rsn1 _ || true
echo
