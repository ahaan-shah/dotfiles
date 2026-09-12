#!/usr/bin/env bash
# Screenshot wrapper.  F11 = region, Print = whole screen, ALT+Print = window.
#
# It exists to replace hyprshot's own notification, which reads "Screenshot
# saved / Image saved in <full timestamped path> and copied to the clipboard."
# -- more than anyone wants to read off a corner of the screen.  `-s` silences
# it and the one at the bottom is sent instead.
#
# A script rather than three inline binds for the usual reason (the message
# would otherwise be written out three times) and for one specific to
# hyprshot: YOU CANNOT GATE IT WITH `&&`.  Its last line is
#
#     begin_grab $OPTION & checkRunning
#
# so the capture runs in the BACKGROUND, and the exit status is whatever
# `pkill hyprpicker` returned inside checkRunning -- which is 1 whenever
# hyprpicker is not running, i.e. always, since --freeze is not used here.
#
# Measured both ways: a cancelled region selection exits 1 and writes nothing,
# and a SUCCESSFUL capture also exits 1 and writes the file.  The code carries
# no information.  So success is decided by the file appearing -- and because
# the capture is backgrounded it may not be there the instant hyprshot
# returns, which is why this waits for it instead of testing once.
set -u

DIR="$HOME/Pictures/Screenshots"
FILE="$(date +'%Y-%m-%d-%H%M%S')_hyprshot.png"

case "${1:-region}" in
    region) MODE=(-m region)           ;;
    output) MODE=(-m active -m output) ;;
    window) MODE=(-m window)           ;;
    *) printf 'usage: %s {region|output|window}\n' "${0##*/}" >&2; exit 2 ;;
esac

# `|| true` because that exit status means nothing -- see above.
hyprshot -s "${MODE[@]}" -o "$DIR" -f "$FILE" || true

# hyprshot returns as soon as slurp does; the grim write behind it is still in
# flight.  4s is far longer than that write takes and short enough that a
# cancelled selection does not leave anyone waiting on a timeout.
i=0
while [ "$i" -lt 40 ]; do
    [ -s "$DIR/$FILE" ] && break
    sleep 0.1
    i=$((i + 1))
done

# Cancelled: say nothing.  hyprshot's own notification fires even on a
# cancelled selection, because send_notification is called unconditionally
# from save_geometry; this does not.
[ -s "$DIR/$FILE" ] || exit 0

notify-send "Screenshot Saved" \
            "Image saved in ~/Pictures/Screenshots/ and copied to clipboard" \
            -a Hyprshot -i "$DIR/$FILE"
