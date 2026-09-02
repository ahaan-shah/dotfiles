#!/usr/bin/env bash
# Applies a wallpaper: hyprpaper restart, pywal colorscheme, Hyprland config
# reload. 1:1 port of the
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
#
# Dropped 2026-09-02: the Cava *restart* block only (pgrep/pkill cava, then
# `echo cava > /dev/pts/$CAVA_TTY`, else `cava & disown`). It carried two bugs
# of its own — the `cava & disown` had exactly the SIGPIPE exposure documented
# below, and CAVA_TTY is empty whenever cava has no controlling tty, so the
# echo went to /dev/pts/, a directory. The gradient sync stays: it only rewrites
# cava's config file, so a cava started later comes up on the new palette by
# itself, with nothing to restart and nothing to race.

WALLPAPER_PATH="$1"
if [ -z "$WALLPAPER_PATH" ] || [ ! -f "$WALLPAPER_PATH" ]; then
    echo "usage: apply-wallpaper.sh <path-to-existing-image>" >&2
    exit 1
fi

HYPERPAPER_CONFIG="$HOME/.config/hypr/hyprpaper.conf"
CAVA_CONFIG="$HOME/.config/cava/config"

# Machine-specific names come from the profile install.sh generates. Sourcing
# it (rather than hardcoding) is what lets this script run unmodified on any
# machine; the fallback keeps it working if the profile has not been written.
HW_ENV="${XDG_CONFIG_HOME:-$HOME/.config}/scripts/hardware.env"
# shellcheck source=/dev/null
[ -r "$HW_ENV" ] && . "$HW_ENV"

# ---------------------------------------------------------------- hyprpaper
#
# THE BUG THIS FIXES
# A wallpaper change would sometimes leave a bare grey background while pywal
# and the lockscreen updated correctly — because those two read *files*
# (~/.cache/wal, hyprpaper.conf) and only the background needs hyprpaper to
# still be alive and drawing. Three separate things could stop it, and the old
# `pkill hyprpaper; hyprpaper & disown` had all three:
#
#   1. `& disown` does not detach anything. It drops the job from bash's table
#      but the child keeps the stdout/stderr PIPE Quickshell handed this script
#      (Wallpapers.qml runs it as a bare Process with no StdioCollector). When
#      the script exits Quickshell closes the read end, and hyprpaper dies of
#      SIGPIPE on its next log write. Measured on a live session: the running
#      hyprpaper held fd/1 and fd/2 on pipe:[9923243] and pipe:[9923244] with
#      no reader left anywhere in /proc — one log line from death. Identical
#      mechanism to the hypridle bug in scripts/ensure-hypridle.sh and the
#      Spotify launch bug in finder/AppIndex.qml; same fix, the SIGPIPE rule
#      in CLAUDE.md: setsid + all three fds off the inherited pipe.
#   2. pkill returns when the signal is *sent*, not when the process is gone.
#      The old instance still owns $XDG_RUNTIME_DIR/hypr/*/.hyprpaper.sock for
#      a few ms, and a new one starting inside that window hits hyprpaper's
#      `couldn't open a socket (1)` and exits. Wait for the old pid instead of
#      assuming; this is the same "poll for the real thing, don't guess" that
#      ensure-hypridle.sh settled on.
#   3. Nothing ever checked the result. hyprpaper also comes up perfectly
#      healthy and draws nothing at all when `monitor =` names an output that
#      does not exist — one stale hardware.env, or one docked/undocked display,
#      away at any time. That is silent by construction: no crash, no log, just
#      the compositor's clear colour.

# Writes the whole config. $1 is the monitor name; EMPTY is hyprpaper's own
# catch-all ("every output"), and is what install.sh emits when detection comes
# up empty, so it is a safe degradation rather than a broken state.
write_hyprpaper_conf() {
    {
        echo "wallpaper {"
        echo "monitor = $1"
        echo "path = $WALLPAPER_PATH"
        echo "fit_mode = cover"
        echo "}"
        echo "splash = false"
    } > "$HYPERPAPER_CONFIG"
}

stop_hyprpaper() {
    pkill -x hyprpaper 2>/dev/null
    for _ in $(seq 1 50); do              # up to ~5s
        pgrep -x hyprpaper >/dev/null || return 0
        sleep 0.1
    done
    pkill -9 -x hyprpaper 2>/dev/null     # wedged on a GPU wait; take the socket back
    sleep 0.3
    return 0
}

start_hyprpaper() {
    setsid hyprpaper </dev/null >/dev/null 2>&1 &
}

# True once hyprpaper reports THIS image on at least one output. `listactive`
# is the only status verb 0.8.4 still answers (listloaded/preload/unload were
# removed in 0.8) and it is the one that distinguishes "running" from actually
# "drawing", which is the whole distinction bug 3 turns on.
# The result is captured and matched with `case` rather than piped into
# `grep -q`: see CLAUDE.md's pipefail rule, and a path may contain glob-ish
# characters that a regex grep would mis-handle.
wallpaper_is_live() {
    local active
    active=$(hyprctl hyprpaper listactive 2>/dev/null) || return 1
    case "$active" in
        *"$WALLPAPER_PATH"*) return 0 ;;
        *)                   return 1 ;;
    esac
}

wait_for_wallpaper() {
    for _ in $(seq 1 60); do              # up to ~6s. Deliberately generous and
        wallpaper_is_live && return 0     # NOT measured against a cold start on
        sleep 0.1                         # this hybrid-GPU laptop; the happy path
    done                                  # returns as soon as it is true anyway,
                                          # so the ceiling only costs the failures.
    return 1
}

write_hyprpaper_conf "${PRIMARY_MONITOR:-}"
stop_hyprpaper
start_hyprpaper

if ! wait_for_wallpaper; then
    if pgrep -x hyprpaper >/dev/null && [ -n "${PRIMARY_MONITOR:-}" ]; then
        # hyprpaper is alive but drawing nothing: bug 3. The monitor name is
        # the only thing in this config that can produce that, so retry once
        # against the catch-all. Keeping the fallback config is deliberate —
        # if the empty form is what works, the recorded name was wrong anyway.
        echo "apply-wallpaper.sh: no output matched '${PRIMARY_MONITOR}', retrying on all outputs" >&2
        write_hyprpaper_conf ""
        stop_hyprpaper
        start_hyprpaper
        wait_for_wallpaper
    fi
fi

# Report rather than exit: the rest of this script (pywal, the cava gradient
# sync) is independent of hyprpaper, and a caller that sees a grey background is better
# served by the colourscheme still updating. Matches the file's best-effort style.
wallpaper_is_live || echo "apply-wallpaper.sh: hyprpaper is not showing $WALLPAPER_PATH" >&2

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

# SwayOSD restart removed: swayosd is not installed and the taskbar draws its
# own OSD pill (see the OSD BACKEND section of taskbar/shell.qml).

# Reload Hyprland
hyprctl reload
