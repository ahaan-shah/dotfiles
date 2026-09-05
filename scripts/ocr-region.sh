#!/usr/bin/env bash
# ocr-region.sh — drag a box, get the text inside it on the clipboard.
#
# Bound to ALT+F11 (hypr/hyprland.lua, next to the screenshot binds). F11 alone
# already screenshots a region; this is the same gesture with a different
# destination, which is why it sits on the same key.
#
# ── Why grim+slurp and not hyprshot ───────────────────────────────────────
# The screenshot binds use hyprshot, and reusing it here would have been the
# obvious move. It is wrong for this: hyprshot's job is to write a PNG to
# ~/Pictures/Screenshots AND put that image on the clipboard, and both are
# exactly what this must not do. Nothing wants a file, and the clipboard has to
# end up holding TEXT — an image landing there first would also push a junk
# entry into finder's clipboard history (ClipboardHistory.qml watches every
# change). grim writing to a pipe keeps the capture in memory from end to end.
#
# ── The upscale, and why it is not a fixed percentage ─────────────────────
# tesseract is trained on ~300 DPI scans. Text at native UI size is well under
# that, and fed as-is tesseract returns confident nonsense rather than nothing —
# which is worse, because it looks like it worked.
#
# The first version of this scaled by a flat 300%, measured on rendered 1x
# samples. That was wrong on this machine, and the reason is worth writing down:
# grim captures PHYSICAL pixels. A 900x260 region selected on this 2x display
# comes out of grim at 1800x520 — already upscaled twice before magick sees it,
# so a flat 300% was really 600%. Measured on one real capture of terminal text:
#
#     100%   "Verifying"   "genuinely"   "confirms it"     correct
#     150%   "Verifying"   "genuinely"   "confirms it"     correct
#     200%   "Verifying"   "genuinely"   "confirms 1t"
#     300%   "Verifyling"  "genulnely"   "confirms it"     degraded
#
# Too much upscale hurts: the interpolated edges stop looking like the strokes
# tesseract was trained on. And on a rendered 1x sample of 10pt text, where the
# capture is NOT pre-doubled, the same measurement runs the other way —
#
#     100%   "Kabel SGHz 92% battery 1407"  /  "Sudo pacman -Syu linuxfirmware:"
#     200%   both lines correct
#     300%   both lines correct
#
# — so neither a flat 100% nor a flat 300% is right for both. What is constant
# across displays is the LOGICAL size of what was selected, so that is what the
# target is pinned to: scale so the image handed to tesseract is 3x the region
# as the user saw it, whatever the monitor scale underneath happens to be. On
# this 2x display that lands at 150% of grim's output; on a 1x display it is
# 300%. Both are the measured-correct settings above, from one rule.
#
# Never downscale — if the capture is already bigger than the target, real
# pixels are the best input there is. Capped at 4000px wide so selecting half
# the screen does not build a needlessly enormous bitmap.
#
# Grayscale and no threshold: screen text is antialiased, and binarising it by
# hand throws away the subpixel edges tesseract's own Otsu pass uses. `-sharpen`
# was tried at every factor and dropped — it flipped "5GHz" to "SGHz" at some
# factors and changed nothing at others, which is noise, not an improvement.
#
# ── PSM 6 ─────────────────────────────────────────────────────────────────
# The default (3, "fully automatic") runs layout analysis to find columns and
# blocks. A hand-drawn box IS the block — there is nothing to segment — and on
# short selections that analysis is what produces dropped lines and reordered
# words. 6 ("a single uniform block of text") tells it what we already know.

set -euo pipefail

note() { command -v notify-send >/dev/null 2>&1 && notify-send -a OCR "$@"; }

need() {
    local missing=()
    for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
    [ ${#missing[@]} -eq 0 ] && return 0
    note "OCR unavailable" "Not installed: ${missing[*]}"
    exit 1
}
need slurp grim tesseract magick wl-copy

# The language pack is a SEPARATE package from tesseract itself (Arch splits it
# into tesseract-data-*), and tesseract's failure without it is a bare
# "Failed loading language 'eng'" on stderr with an empty result — which from
# the outside is indistinguishable from a region that had no text in it. Say
# which package is missing instead.
#
# `grep -c` on a captured string, never `tesseract --list-langs | grep -q`:
# grep exits at its first match, the producer dies of SIGPIPE, and pipefail
# above then reports a false failure. This repo has been bitten by that four
# times — see the hard rules in CLAUDE.md.
langs="$(tesseract --list-langs 2>/dev/null || true)"
if [ "$(printf '%s\n' "$langs" | grep -cx 'eng' || true)" -eq 0 ]; then
    note "OCR unavailable" "English data missing — sudo pacman -S tesseract-data-eng"
    exit 1
fi

# ── pick the region ───────────────────────────────────────────────────────
# Escape or right-click leaves slurp with a non-zero exit and nothing on
# stdout. That is a cancel, not a failure: it must be silent, because a
# notification saying "cancelled" every time you change your mind is noise.
geom="$(slurp -d 2>/dev/null || true)"
[ -n "$geom" ] || exit 0

# "X,Y WxH" — the W here is LOGICAL, which is exactly why it is the thing to
# scale against; grim's own output is in physical pixels and already carries
# the monitor scale. See the upscale note above.
logical_w="${geom##* }"
logical_w="${logical_w%%x*}"
case "$logical_w" in ''|*[!0-9]*) logical_w=0 ;; esac
target=$(( logical_w * 3 ))
[ "$target" -gt 4000 ] && target=4000
[ "$target" -lt 200 ] && target=200

# ── capture → upscale → recognise ─────────────────────────────────────────
# One pipeline, no temp file: the capture is a screenshot of whatever was on
# screen, which can be a password manager or a bank page, and it should never
# touch a disk that something else could read it off.
#
# tesseract's own progress chatter goes to stderr and is dropped; a real
# failure is caught by the empty-result check below rather than by its exit
# code, which is 0 even when it recognises nothing.
text="$(
    grim -g "$geom" - 2>/dev/null \
        | magick png:- -colorspace Gray -resize "${target}x<" png:- \
        | tesseract stdin stdout -l eng --psm 6 2>/dev/null \
        || true
)"

# Trim leading/blank and trailing blank lines. tesseract pads its output with
# a trailing newline and often a blank line, and copying those means pasting
# an extra line break into whatever you paste it into.
text="$(printf '%s' "$text" | sed -e '/./,$!d' -e :a -e '/^\n*$/{$d;N;};/\n$/ba')"

if [ -z "$text" ]; then
    note "No text found" "Nothing legible in that selection"
    exit 0
fi

# printf, not echo: the text is arbitrary and may begin with a dash or contain
# backslashes, both of which echo would eat.
printf '%s' "$text" | wl-copy

# The first line, so the notification confirms it grabbed the right thing
# without pasting a paragraph into the corner of the screen.
first="$(printf '%s' "$text" | head -n 1)"
lines="$(printf '%s\n' "$text" | wc -l)"
[ "${#first}" -gt 60 ] && first="${first:0:60}…"
if [ "$lines" -gt 1 ]; then
    note "Copied text" "$first  (+$((lines - 1)) more lines)"
else
    note "Copied text" "$first"
fi
