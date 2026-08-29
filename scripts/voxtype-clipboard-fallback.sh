#!/usr/bin/env bash
# voxtype [output.post_process] hook — clipboard fallback + the transcription
# notification.
#
# Why this exists: voxtype's own `fallback_to_clipboard` only fires when the
# *typing driver fails*, and wtype does not fail with no keyboard focus. It
# hands its synthetic keys to the compositor, Hyprland has no focused surface
# to route them to, and wtype exits 0 — measured on this box:
#
#     (empty workspace) $ wtype "ZZTEST"; echo $?
#     0
#
# So a transcription dictated with no window focused was silently lost.
#
# This runs as voxtype's post_process command: the transcript arrives on stdin
# and whatever we print on stdout is what gets typed. We always echo it back
# unchanged, and additionally put it on the clipboard when `hyprctl
# activewindow -j` reports no focused window (it prints exactly `{}` then).
#
# It also owns the user-facing notification, because voxtype's built-in one
# cannot say which of the two things happened. `[output.notification]
# on_transcription` is therefore false in config.toml and we emit:
#
#     "Transcribed"          + the text   — typed at the cursor
#     "Copied to clipboard"  + the text   — nothing focused, text was not typed
#
# Failure is safe in both directions: on any error/timeout voxtype falls back
# to the original transcript, and the extra clipboard write is harmless.
set -uo pipefail

text=$(cat)

# Hand the transcript back first and close stdout, so nothing below can keep
# voxtype waiting on the pipe.
printf '%s' "$text"
exec 1>&-

[ -n "$text" ] || exit 0

# The taskbar renders notification bodies as Text.StyledText, so a stray & or <
# in a transcript would swallow the rest of the line.
body=${text//&/&amp;}
body=${body//</&lt;}
body=${body//>/&gt;}

# hyprctl needs HYPRLAND_INSTANCE_SIGNATURE. The voxtype daemon inherits it
# from the session, but fall back to the one live socket dir if it ever loses
# it (systemd user units do not always import the session env).
if [ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
    sig=$(ls -1 "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr" 2>/dev/null | head -1)
    [ -n "$sig" ] && export HYPRLAND_INSTANCE_SIGNATURE="$sig"
fi

active=$(hyprctl activewindow -j 2>/dev/null | tr -d '[:space:]')

# No focused window: `{}`. Anything else (or a failed hyprctl) means the text
# is about to be typed, so leave the clipboard alone.
if [ "$active" = "{}" ]; then
    # wl-copy forks a server that holds the selection; redirect its stdio so it
    # cannot inherit and hold open a descriptor voxtype is waiting on.
    printf '%s' "$text" | wl-copy >/dev/null 2>&1
    summary="Copied to clipboard"
else
    summary="Transcribed"
fi

command -v notify-send >/dev/null 2>&1 &&
    notify-send -a voxtype "$summary" "$body" >/dev/null 2>&1

exit 0
