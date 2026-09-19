#!/usr/bin/env bash
# wallpapers.sh  list [all|by-palette]
#
# The wallpaper listing behind Settings → Theme → Wallpapers. Two pages read
# it, and they read two different COLLECTIONS:
#
#   All          Ahaan's own wallpapers, then the themed tree.
#   By palette   the palette in force, and ONLY its own directory.
#
# Both collections live under ONE root, ~/Pictures/wallpapers, and are told
# apart by DEPTH rather than by which directory they are in: his own sit flat
# at the top, the themed tree is the <theme>/ subdirectories below it. See the
# two directory constants for why that line still has to be drawn, and
# files_themed()/theme_of() for the two things that only work because it is
# drawn on depth.
#
# ── "By palette" used to MEASURE, and now it just looks in a directory ────
# Until 2026-09-19 this file scored every image against the palette's
# background in CIE L*a*b*, weighted by the pixel count of each of its six
# dominant colours, and kept whatever fell under a tuned ΔE cut. That was ~200
# lines: an ImageMagick quantiser, an mtime-keyed colour cache, a gawk scorer
# implementing sRGB→XYZ→Lab, and two calibrated constants. All of it is gone.
#
# It is gone because it was answering a question nobody has any more. The
# scorer existed to find, among 92 downloaded images, the ones that happened to
# suit the palette — a guess, because nothing recorded what suited what. Ahaan
# now sorts his own wallpapers into the theme directories BY HAND, so the
# answer is stated rather than inferred: the directory a picture is in is the
# palette he chose it for. A measurement that estimates a fact you have been
# told is not a better answer, it is a worse one that costs 3 seconds of image
# decoding and a cache to hide the cost.
#
# So the page shows the palette's directory and nothing else — not his own
# images, not a near miss from another theme. Ahaan's words: "if i am on
# vantablack palette, wallpapers -> by-palette shows only ones in the
# vantablack folder."
#
# Two consequences worth stating, because both look like faults and are not:
#
#   An EMPTY directory means an empty page. That is now correct — it says the
#   palette has no wallpapers sorted into it yet. There is no rescue, no
#   widening and no fallback, because every one of those would put a picture on
#   the page that Ahaan did not choose for that palette.
#
#   Under "pywal" the page is ALWAYS empty. pywal is not a theme and has no
#   directory (palette.sh: PYWAL="pywal"), and under it the colours are derived
#   from whatever wallpaper is up — so there is no palette that a directory
#   could correspond to. "All" is the page for that case.
#
# Applying one is NOT here — shell/apply-wallpaper.sh has always been that, and
# Settings.qml calls it through Wallpapers.qml exactly as finder's own wallpaper
# mode used to. This file only decides what to offer, which is the same contract
# every other listing in that menu keeps (see Settings.qml's header).
set -uo pipefail

# ── two collections, one root, and they are still not interchangeable ────
# MINE is Ahaan's own, FLAT at the top of the directory, and it shows ONLY
# under "All".
#
# THEME_DIR is what "By palette" chooses from — one subdirectory per theme.
# The subdirectory name is DATA and not tidiness: the 22 directory names map
# 1:1 onto the 22 palettes in palettes/ (checked, exactly, no spares on either
# side), so the path says which palette each image was chosen for. That mapping
# is now the WHOLE of how the by-palette page works, rather than a hint that
# helped a scorer along — which is a good reason not to rename either side of
# it casually.
#
# They are filled BY HAND. They were downloaded by a fetch script until
# 2026-09-19; Ahaan dropped it, because omarchy's backgrounds looked poor on a
# 2x display and he is sorting his own images into these directories instead.
# So the 22 directories are the durable thing here and their contents are not:
# expect any of them to be EMPTY.
#
# ── They resolve to the SAME directory, and that is recent ───────────────
# Until 2026-09-19 the themed tree lived in ~/.local/share/hyprahaan/wallpapers
# and the split was by root. Ahaan moved it in beside his own — one place for
# wallpapers, which is what a person looking for a wallpaper expects. The two
# names stay because the DISTINCTION did not go away, only the second root: it
# is now "flat" versus "one level down", and two things below exist solely to
# hold that line where a shared root would blur it.
#
#   files_themed()  -mindepth 2, or the themed walk also returns the flat
#                   files — which would list all 17 of Ahaan's twice under
#                   "All".
#   theme_of()      a path under THEME_DIR with no slash left in it is one of
#                   his, not a theme. Without that check "dune.jpg" parses as a
#                   theme called "dune.jpg" and the row grows a nonsense trail.
#
# Both env seams stay, and are what tests/ exercise a two-collection tree
# through without needing two real directories.
#
# Named for what the directory IS rather than for who supplied it — which is
# what made the source swap above a no-op for this file. The thing this script
# needs from a path is the theme, and that is as true of Ahaan's own images as
# it was of a downloaded set.
WALL_DIR="${WALLPAPER_DIR:-$HOME/Pictures/wallpapers}"
THEME_DIR="${THEME_BG_DIR:-$WALL_DIR}"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/hyprahaan/wallpaper"

# What counts as a wallpaper: what Qt can draw.
#
# It used to read "what ImageMagick can quantise AND Qt can draw", and the
# first half went with the scorer. The rule that is left is the one that
# mattered: this list may only name what the thumbnail and the desktop can
# actually render.
#
# Stock Qt6 ships decoders for png, jpeg, gif and bmp only, so hands.webp
# ranked perfectly well and then drew as nothing — in the settings row's
# thumbnail AND on the desktop, since Wallpaper.qml is an Image too. Ahaan
# installed qt6-imageformats, which puts libqwebp and libqtiff (plus icns, jp2,
# tga, mng, wbmp) into /usr/lib/qt6/plugins/imageformats/, so both formats
# below are genuinely drawable rather than merely listable. Checking that for
# the next format added here means looking in that plugin directory — `magick
# -list format` answers a different question and will happily say yes.
EXT_RE='\.(png|jpe?g|webp|bmp|gif|tiff?)$'

die() { echo "wallpapers: $*" >&2; exit 1; }

# ── the files ────────────────────────────────────────────────────────────
# -maxdepth 1 and no hidden files: the same flat single-directory listing
# Wallpapers.qml did with `ls -1`, which is what this replaces. `.comments`
# (a Dolphin sidecar directory that lives in there) is a directory, so -type f
# excludes it here; the themed walk below has to say so explicitly.
files_mine() {
    [ -d "$WALL_DIR" ] || return 0
    find "$WALL_DIR" -maxdepth 1 -type f -not -name '.*' \
         -regextype posix-extended -iregex ".*$EXT_RE" -print | sort
}

# -mindepth 2 -maxdepth 2: exactly one level down, because that is what a
# themed image IS — <theme>/<file>. The floor is not tidiness, it is the whole
# separation now that this shares a root with files_mine(); see the constants
# above for what a bare -maxdepth 2 would list twice.
#
# -not -path "$THEME_DIR/.*" keeps the walk out of hidden subdirectories —
# `.comments`, Dolphin's sidecar, which holds .xml files the extension filter
# would reject anyway. Excluded by INTENT rather than by luck, since that
# filter is a list of image formats and is going to grow.
#
# ANCHORED to $THEME_DIR, and that is not fussiness. The obvious spelling,
# -not -path '*/.*/*', tests the whole ABSOLUTE path, so it also matches every
# hidden component above the tree — which silently returned zero themed files
# for as long as this tree lived in ~/.local/share/hyprahaan/wallpapers, since
# `.local` is one. Measured: 17 rows instead of 57. The move to
# ~/Pictures/wallpapers would have hidden that by removing the only hidden
# component, so the seam is what has to stay correct, not the default.
# At -mindepth 2 -maxdepth 2 the only components below $THEME_DIR are
# <theme>/<file>, so -not -name '.*' covers the file and this covers the theme.
#
# Sorted as a whole, so themes come out alphabetically and the files within a
# theme keep any leading ordinals.
files_themed() {
    [ -d "$THEME_DIR" ] || return 0
    find "$THEME_DIR" -mindepth 2 -maxdepth 2 -type f \
         -not -name '.*' -not -path "$THEME_DIR/.*" \
         -regextype posix-extended -iregex ".*$EXT_RE" -print | sort
}

# One theme's directory, flat. This is the whole of the by-palette page now,
# and it is deliberately NOT expressed as "files_themed filtered by theme":
# asking the filesystem for one directory is both cheaper and impossible to
# get wrong when a theme name is a prefix of another one.
files_of_theme() {
    [ -d "$THEME_DIR/$1" ] || return 0
    find "$THEME_DIR/$1" -maxdepth 1 -type f -not -name '.*' \
         -regextype posix-extended -iregex ".*$EXT_RE" -print | sort
}

# The theme a path belongs to, or empty for anything outside the themed tree.
# Parsed off the path rather than kept in a sidecar file, so moving or deleting
# a theme's directory cannot leave a stale mapping behind.
#
# The second case is what makes this correct under a shared root: everything in
# WALL_DIR is "under THEME_DIR" now, so being under it is no longer the
# question — having a directory component left after the prefix comes off is.
# "nord/1-fjord.webp" has one and is a theme; "dune.jpg" has none and is one of
# Ahaan's. Expanded rather than cut(1) because emit() calls this once per file.
#
# ASSIGNS to THEME rather than printing it, because emit() calls this once per
# file and a command substitution is a fork. At 57 rows the printing version
# cost a third of the whole listing; see emit().
theme_of() {
    local rel
    THEME=""
    case "$1" in
        "$THEME_DIR"/*) rel="${1#"$THEME_DIR"/}" ;;
        *) return 0 ;;
    esac
    case "$rel" in
        */*) THEME="${rel%%/*}" ;;
    esac
    return 0
}

# The stem, with a leading ordinal dropped: "2-night-hawks" is "night-hawks",
# because the number orders a directory and says nothing about the picture.
# Applied to themed files only — Ahaan's own flat names are left exactly as he
# wrote them, the same rule the Fonts page keeps, that a listing shows what a
# thing is called and does not invent a prettier version of it.
#
# Pure expansion: ${x##*/} for basename and extglob ${x##+([0-9])-} for the
# ordinal, in place of a basename(1) and a sed(1) per row. Same reason as
# theme_of above — this runs once per file and forks dominated the listing.
# The theme is passed IN rather than re-derived, since emit() already has it,
# and the result is ASSIGNED to LABEL for the same reason theme_of assigns.
shopt -s extglob
label_of() {
    LABEL="${1##*/}"
    LABEL="${LABEL%.*}"
    [ -n "$2" ] && LABEL="${LABEL##+([0-9])-}"
    return 0
}

current_wallpaper() {
    [ -r "$STATE" ] && head -1 "$STATE"
    return 0
}

# ── the palette in force ─────────────────────────────────────────────────
# The palette's NAME, which since the scorer went is the ONLY thing this page
# needs: the name is the directory. Asked of palette.sh rather than re-read out
# of ui.conf here, so "absent means pywal" is decided in exactly one place.
# Resolved beside this script, the same rule as apply-wallpaper.sh's — from
# ~/.config/scripts that is the live palette.sh, from the repo it is the repo's.
palette_current() {
    local self_dir
    self_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
    [ -x "$self_dir/palette.sh" ] || return 0
    "$self_dir/palette.sh" current 2>/dev/null | head -1
    return 0
}

# ── the listing ──────────────────────────────────────────────────────────
# value <TAB> label <TAB> detail <TAB> current — ui-prefs.sh's one listing
# format, so Settings.qml's parser needs to know nothing about wallpapers. The
# value is the absolute path, which is both what apply-wallpaper.sh wants and
# what the row draws itself with.
#
# `detail` carries the THEME for a themed image and is empty for one of Ahaan's
# own. The panel draws it in the trailing slot, which is where that file
# already puts "something about the row that is not a description of it" — and
# here it is the one thing the filename cannot say, since two themes are free
# to hold a picture of the same name and several ship one called "1-something".
#
# Four forks per row is what this used to be — two command substitutions for
# the label and the theme, one for the `current` mark, one for basename inside
# label_of — and at 57 rows that was ~450ms of the ~520ms listing. None of them
# were doing anything bash cannot do in-process. Rewritten to zero forks per
# row; the only subshell left is the single current_wallpaper() read.
emit() {
    local cur; cur="$(current_wallpaper)"
    local f mark
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        theme_of "$f"                       # sets THEME
        label_of "$f" "$THEME"              # sets LABEL
        if [ "$f" = "$cur" ]; then mark=current; else mark=""; fi
        printf '%s\t%s\t%s\t%s\n' "$f" "$LABEL" "$THEME" "$mark"
    done
}

# Ahaan's own first and the themed tree after it, rather than one merged
# alphabetical run. His are the ones he chose and put at the top level; a list
# that interleaves them with every themed image buries them, and "All" is the
# page he goes to when he already knows which picture he wants.
list_all() { { files_mine; files_themed; } | emit; }

# ── by palette ───────────────────────────────────────────────────────────
# The palette in force, its directory, nothing else. See the header for why
# this is four lines and not two hundred, and for why both empty cases below
# are the right answer rather than a gap to be filled.
list_by_palette() {
    local cur; cur="$(palette_current)"
    [ -n "$cur" ] || return 0
    files_of_theme "$cur" | emit
}

case "${1:-}" in
    list)
        case "${2:-all}" in
            all)        list_all ;;
            by-palette) list_by_palette ;;
            *)          die "usage: wallpapers.sh list [all|by-palette]" ;;
        esac ;;
    *)
        echo "usage: $(basename "$0") list [all|by-palette]" >&2
        exit 2
        ;;
esac
