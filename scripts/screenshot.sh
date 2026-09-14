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
#
# ── "the preview is sometimes a magenta checkerboard" (2026-09-14) ────────
# WAITING FOR THE FILE TO EXIST IS NOT WAITING FOR IT TO BE WRITTEN.  grim
# streams a PNG out as it encodes it, so `[ -s ]` -- non-empty -- goes true on
# the first 8 KB.  Measured on a 2880x1620 capture: non-empty at 90ms, still
# growing at 400ms, final size 2.5 MB.  notify-send fired inside that window
# and handed the notification a path to a PARTIAL PNG.
#
# Qt does not reject one.  It decodes as far as the data goes and fills the
# rest with its missing-data pattern, so the card came up with a magenta and
# black checkerboard where the screenshot should be -- reproduced exactly by
# pointing notify-send at a PNG truncated to 8 KB by hand.  Reported as
# "sometimes", and it is not sometimes: it is every time the encode outruns
# the poll, which is a function of how big the capture is and how busy the
# machine is.
#
# So the wait is for the file to be COMPLETE.  A PNG's last chunk is IEND, so
# the test is whether the final 12 bytes carry it.
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

# True only once the whole PNG is on disk.  The IEND chunk is written last and
# is always the final 12 bytes (length 0, "IEND", CRC), so finding 49 45 4e 44
# in them means the encoder finished.
#
# Captured into a variable rather than `... | grep -q`: grep -q exits on its
# first match and kills the producer, which under `set -o pipefail` reports a
# SUCCESSFUL check as a failure.  This script does not set pipefail, but the
# repo has been bitten by that five times and the safe form costs nothing.
png_complete() {
    [ -s "$1" ] || return 1
    [ "$(tail -c 12 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n' | grep -c '49454e44')" -gt 0 ]
}

# hyprshot returns as soon as slurp does; the grim write behind it is still in
# flight.  4s is far longer than that write takes -- the 2.5 MB measurement
# above finished well inside a second -- and short enough that a cancelled
# selection does not leave anyone waiting on a timeout.
i=0
while [ "$i" -lt 40 ]; do
    png_complete "$DIR/$FILE" && break
    sleep 0.1
    i=$((i + 1))
done

# Cancelled: say nothing.  hyprshot's own notification fires even on a
# cancelled selection, because send_notification is called unconditionally
# from save_geometry; this does not.  Nothing on disk at all is the only
# reading of "cancelled" -- a file that exists but never completed is a write
# that went wrong, which is a different thing and says so below.
[ -s "$DIR/$FILE" ] || exit 0

# Deliberately still notifies.  If the encode has not finished after four
# seconds something is wrong with the write, and the preview will be the
# checkerboard again -- but a screenshot that was taken and saved and said
# nothing is worse than one that announces itself with a bad thumbnail.
png_complete "$DIR/$FILE" ||
    echo "screenshot.sh: $FILE still incomplete after 4s; preview may not render" >&2

notify-send "Screenshot Saved" \
            "Image saved in ~/Pictures/Screenshots/ and copied to clipboard" \
            -a Hyprshot -i "$DIR/$FILE"
