#!/usr/bin/env bash
# apply-wallpaper.sh <path-to-existing-image>
#
# Sets the desktop wallpaper, and asks scripts/palette.sh what that should do
# to the colours. Run from finder's wallpaper mode (ALT+W, Wallpapers.qml) and
# by install.sh on a fresh machine.
#
# ── This file used to be 180 lines, and hyprpaper was all of them ─────────
# It wrote ~/.config/hypr/hyprpaper.conf, killed hyprpaper, waited for the old
# process to actually go, restarted it detached, polled `hyprctl hyprpaper
# listactive` until the new image was genuinely on an output, and retried once
# against hyprpaper's catch-all monitor if the recorded name matched nothing.
# Every one of those steps was a fix for a real, measured failure — the SIGPIPE
# death mid-session, the socket-release race, the silently-drawing-nothing
# case — and every one of those failures existed because the wallpaper was a
# SEPARATE PROCESS holding a layer surface.
#
# It is a Quickshell surface now (macshell/Wallpaper.qml, one per output via
# Variants), so there is no process to keep alive, no socket to race, and no
# monitor name to get wrong. What is left here is the part that was always the
# real work: record which image, and tell the colours.
#
# The full account of the three bugs is kept in the system map rather than
# deleted — they are the clearest worked example in this repo of the SIGPIPE
# rule, and the rule still governs everything else that spawns a process.
set -uo pipefail

WALLPAPER_PATH="${1:-}"
if [ -z "$WALLPAPER_PATH" ] || [ ! -f "$WALLPAPER_PATH" ]; then
    echo "usage: apply-wallpaper.sh <path-to-existing-image>" >&2
    exit 1
fi

# Absolute, because the readers are long-lived processes with no idea what
# directory finder happened to be in, and because the lock screen resolves it
# hours later.
WALLPAPER_PATH="$(realpath -- "$WALLPAPER_PATH")"

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/hyprahaan"
STATE="$STATE_DIR/wallpaper"

# ── record it ────────────────────────────────────────────────────────────
# One line, one absolute path. Two readers: macshell/Wallpaper.qml draws it,
# lockscreen/LockSurface.qml draws it behind the lock — which is the job
# hyprpaper.conf used to do, being the one file both agreed on.
#
# Written to a temp file and mv'd, like ui.conf and the dock's pin store, for
# the reason those are: a reader watching this directory WILL be woken by a
# partial write otherwise. The watch is on the directory precisely because this
# mv replaces the inode.
mkdir -p "$STATE_DIR"
tmp="$STATE.tmp.$$"
printf '%s\n' "$WALLPAPER_PATH" >"$tmp" && mv "$tmp" "$STATE"

# ── a stray hyprpaper would draw over it ─────────────────────────────────
# Nothing starts hyprpaper any more — it is out of hyprland.lua's autostart and
# out of the package manifest — but a session that has not been restarted since
# this change still has the old one running and holding its own background
# surface. Two backgrounds on one layer is a coin toss, and the losing one is
# the new wallpaper. Costs a failed pkill per wallpaper change forever after,
# which is cheaper than the bug report.
pkill -x hyprpaper 2>/dev/null

# ── and the colours ──────────────────────────────────────────────────────
# Resolved BESIDE this script rather than at a fixed path, the same rule as
# Settings.qml's scriptDir — from ~/.config/shell that is ~/.config/scripts,
# and from the repo it is the repo's own scripts/, so a repo instance exercises
# the repo's palette.sh with no deploy.
#
# palette.sh decides what a new wallpaper means: under the "pywal" palette the
# colours are re-derived from this image, under any chosen palette they stand.
PALETTE_SH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../scripts" 2>/dev/null && pwd)/palette.sh"
if [ -x "$PALETTE_SH" ]; then
    "$PALETTE_SH" wallpaper-changed "$WALLPAPER_PATH"
else
    echo "apply-wallpaper.sh: $PALETTE_SH missing, falling back to plain pywal" >&2
    wal -n -q -i "$WALLPAPER_PATH"
    hyprctl reload
fi
