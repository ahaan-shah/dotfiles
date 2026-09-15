#!/usr/bin/env bash
# wallpapers.sh  {list [by-palette] | scan}
#
# The wallpaper listing behind Settings → Theme → Wallpapers. Two pages read
# it, and since 2026-09-15 they read two different COLLECTIONS:
#
#   All          Ahaan's own ~/Pictures/wallpapers, then the themed tree.
#   By palette   the themed tree only — the palette in force leading with its
#                own backgrounds, then whatever else matches.
#
# See the two directory constants below for why they are separate and why only
# one of them is ranked.
#
# Applying one is NOT here — shell/apply-wallpaper.sh has always been that, and
# Settings.qml calls it through Wallpapers.qml exactly as finder's own wallpaper
# mode used to. This file only decides what to offer, which is the same contract
# every other listing in that menu keeps (see Settings.qml's header).
#
# ── What "goes with the palette" means, and how it is measured ────────────
# The wallpaper is the ground this desktop sits on, and the palette's
# `background` is what that ground is supposed to BE — it is the colour behind
# every bar, card and dropdown on screen. So an image goes with a palette when
# the colour it is mostly MADE of is already near that background.
#
# For each wallpaper, ImageMagick quantises a 48x48 sample down to its six
# dominant colours and reports how many pixels each one won. Both sides are
# converted to CIE L*a*b*, where a plain Euclidean distance (ΔE76) is roughly
# perceptual — which plain RGB is not, and that matters here: #000000 and
# #1a1a2e are 46 apart in RGB and 11 apart in Lab, and to the eye they are the
# same near-black. The score is then
#
#     Σ  weight(colour) × distance from it to the palette background
#
# over the six, weighted by pixel count. Weighting by AREA is what makes this
# work on the wallpapers that are one thing with a bright mark on it: the neon
# spider on atsv-spidey.png is 3% of the pixels, so the image scores as the
# black field it actually is.
#
# ── Scored against the background, and not against all sixteen slots ──────
# (The measurements in this section were taken on the original 18-image
# collection. The conclusion holds and the numbers are kept as they were
# measured; only the CUT below was recalibrated for the larger set.)
# The obvious version of this scores each dominant colour against its NEAREST
# palette colour over all eighteen (background, colors0-15, foreground). It was
# written, run over every palette and every wallpaper here, and it is wrong:
# eighteen slots span from near-black to near-white through every hue, so
# almost any image finds something near. Measured, that version admits an
# orange-and-teal river photo and a cream poster under `vantablack` — a palette
# whose every colour is a shade of grey — because the foreground is white and
# the mid greys cover everything neutral. Scoring against background alone
# separates the collection the way the eye does: `nord` selects the five cool
# dark images and nothing else, `vantablack` the six true blacks.
#
# Lightness therefore falls out for free rather than needing a term of its own,
# and so does the light-palette case: the five LIGHT palettes (rose-pine dawn,
# lupine, white, catppuccin-latte, flexoki-light) select exactly the one light
# wallpaper here and nothing else, which is the behaviour a hand-written
# "prefer dark under a dark theme" rule would have been written to produce.
#
# ── The cut ──────────────────────────────────────────────────────────────
#     keep if score <= max(CUT_ABS, best + CUT_NEAR)
#
# CUT_ABS was 18 and is 12, and the change is about the COLLECTION rather than
# about the rule. 18 is roughly where a colour stops reading as "the same
# colour, a bit off"; against Ahaan's 18 images that kept 0-11 per palette,
# median 9. Against the 92 omarchy backgrounds the same 18 keeps up to 38 —
# not because the matches got worse but because there are now five times as
# many images sitting in the neighbourhood of any given palette. Measured over
# all 22 palettes: 18 gives 15-38 (median 27), 14 gives 10-28, 12 gives 8-22
# (median 15), 10 gives 6-17 and starts leaving pages with three or four rows
# after their own backgrounds. 12 is the one that stays a shortlist without
# thinning out.
#
# The `best + CUT_NEAR` half exists for the 0 case, and now applies ONLY when
# the palette has no backgrounds of its own — i.e. under "pywal", which is not
# a theme and has no directory. Everywhere else the page is already non-empty
# before the scorer runs, so there is nothing to rescue and widening it would
# only add poor matches. See rank() and list_by_palette().
#
# ── The cache ────────────────────────────────────────────────────────────
# Quantising these 18 files costs ~3s of image decoding, and the settings menu
# fetches every listing each time it opens. So the six colours per file are
# cached, keyed on path + mtime + size: an edited or replaced wallpaper is
# re-read, an untouched one is not, and a warm run is a file read and one awk.
set -uo pipefail

# ── two collections, and they are not interchangeable ────────────────────
# MINE is Ahaan's own directory, flat, and it shows ONLY under "All". It used
# to be the whole of both pages, and that was the bug: eighteen images, most of
# them near-black, so "By palette" answered with the same eight whatever
# palette was in force. A shortlist that never changes is not a shortlist.
#
# THEME_DIR is what "By palette" chooses from — one subdirectory per theme,
# filled by fetch-omarchy-backgrounds.sh. The subdirectory name is DATA and not
# tidiness: the 22 theme names map 1:1 onto the 22 palettes in palettes/, so
# the path says which palette each image was chosen for, which is what lets the
# page lead with the current palette's own backgrounds instead of only with
# whatever happens to score well.
#
# Named for what the directory IS rather than for who supplied it. The images
# are omarchy's today and .source in that tree records it, but the thing this
# script needs from the path is the theme, and that would still be true of a
# set from anywhere else.
WALL_DIR="${WALLPAPER_DIR:-$HOME/Pictures/wallpapers}"
THEME_DIR="${THEME_BG_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/hyprahaan/wallpapers}"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/hyprahaan/wallpaper"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/hyprahaan"
CACHE="$CACHE_DIR/wallpaper-colors.tsv"
WAL_JSON="$HOME/.cache/wal/colors.json"

# What counts as a wallpaper: what ImageMagick can quantise AND Qt can draw.
#
# Those two sets were NOT the same here until 2026-09-15. Stock Qt6 ships
# decoders for png, jpeg, gif and bmp only, so hands.webp quantised and ranked
# perfectly well and then drew as nothing — in the settings row's thumbnail
# AND on the desktop, since Wallpaper.qml is an Image too. It was listed
# anyway, on the grounds that hiding the file would hide the cause. Ahaan
# installed qt6-imageformats, which puts libqwebp and libqtiff (plus icns, jp2,
# tga, mng, wbmp) into /usr/lib/qt6/plugins/imageformats/, so both formats
# below are now genuinely drawable rather than merely listable.
#
# The RULE survives the fix, because the next format added here will meet it
# again: this list may only name what the thumbnail and the desktop can
# actually render. Checking that means looking in that plugin directory —
# `magick -list format` answers a different question and will happily say yes.
EXT_RE='\.(png|jpe?g|webp|bmp|gif|tiff?)$'

CUT_ABS=12
CUT_NEAR=10

die() { echo "wallpapers: $*" >&2; exit 1; }

# ── the files ────────────────────────────────────────────────────────────
# -maxdepth 1 and no hidden files: the same flat single-directory listing
# Wallpapers.qml did with `ls -1`, which is what this replaces. `.comments`
# (a Dolphin sidecar directory that lives in there) is excluded by the
# extension filter rather than by name.
files_mine() {
    [ -d "$WALL_DIR" ] || return 0
    find "$WALL_DIR" -maxdepth 1 -type f -not -name '.*' \
         -regextype posix-extended -iregex ".*$EXT_RE" -print | sort
}

# -maxdepth 2, because this tree is one level deeper by design: <theme>/<file>.
# Sorted as a whole, so themes come out alphabetically and the files within a
# theme keep the leading ordinals omarchy numbers them with.
files_themed() {
    [ -d "$THEME_DIR" ] || return 0
    find "$THEME_DIR" -maxdepth 2 -type f -not -name '.*' \
         -regextype posix-extended -iregex ".*$EXT_RE" -print | sort
}

# The theme a path belongs to, or empty for anything outside the themed tree.
# Parsed off the path rather than kept in a sidecar file, so moving or deleting
# a theme's directory cannot leave a stale mapping behind.
theme_of() {
    case "$1" in
        "$THEME_DIR"/*) printf '%s' "${1#"$THEME_DIR"/}" | cut -d/ -f1 ;;
        *) : ;;
    esac
    return 0
}

# The stem, with omarchy's leading ordinal dropped: "2-night-hawks" is
# "night-hawks", because the number orders a directory and says nothing about
# the picture. Ahaan's own names are left exactly as he wrote them — the same
# rule the Fonts page keeps, that a listing shows what a thing is called and
# does not invent a prettier version of it.
label_of() {
    local b; b="$(basename -- "$1")"
    b="${b%.*}"
    [ -n "$(theme_of "$1")" ] && b="$(printf '%s' "$b" | sed -E 's/^[0-9]+-//')"
    printf '%s' "$b"
}

current_wallpaper() {
    [ -r "$STATE" ] && head -1 "$STATE"
    return 0
}

# ── the colour cache ─────────────────────────────────────────────────────
# One line per wallpaper:  path <TAB> mtime <TAB> size <TAB> r,g,b,weight;…
#
# The THEMED tree only. "All" needs no colours at all — it is a directory
# listing — and Ahaan's own images are never ranked against a palette, so
# quantising them would be ~3s of decoding for an answer nothing reads.
#
# -sample rather than -resize: this is a colour census, and box-sampling is
# three times cheaper than a filtered resize while giving the same six
# dominant colours (checked against -resize on all 18 — identical to within a
# couple of 8-bit levels). jpeg:size hands libjpeg a DCT-scaled decode, which
# is most of what is left; a PNG has no such shortcut and is the slow case.
#
# -alpha remove: a transparent PNG otherwise reports RGBA tuples that the
# parser below would read as a colour plus a weight, silently.
# [0] takes the first frame, so an animated GIF is one image and not fifty.
quantise() {
    magick -define jpeg:size=160x160 "$1[0]" -alpha remove -alpha off \
           -sample 48x48\! -colors 6 -depth 8 -format "%c" histogram:info: 2>/dev/null \
        | sed -n 's/^ *\([0-9]*\): *(\([0-9]*\),\([0-9]*\),\([0-9]*\)).*/\2,\3,\4,\1/p' \
        | paste -sd';'
}

scan() {
    command -v magick >/dev/null 2>&1 || return 1
    mkdir -p "$CACHE_DIR"

    # The existing cache, keyed by path. Read with `read -r` rather than awk so
    # a path containing a tab is impossible to confuse with a field break.
    declare -A cached=()
    if [ -r "$CACHE" ]; then
        while IFS=$'\t' read -r p mt sz cols; do
            [ -n "${p:-}" ] && cached["$p"]="$mt	$sz	$cols"
        done <"$CACHE"
    fi

    local tmp; tmp="$(mktemp "$CACHE.XXXXXX")" || return 1
    local f stat mt sz hit cols
    while IFS= read -r f; do
        # One stat per file, not two.
        stat="$(stat -c '%Y %s' -- "$f" 2>/dev/null)" || continue
        mt="${stat%% *}"; sz="${stat##* }"
        hit="${cached[$f]:-}"
        if [ -n "$hit" ] && [ "${hit%%	*}" = "$mt" ]; then
            # mtime matched; check the size field too before trusting it.
            local rest="${hit#*	}"
            if [ "${rest%%	*}" = "$sz" ]; then
                printf '%s\t%s\n' "$f" "$hit" >>"$tmp"
                continue
            fi
        fi
        cols="$(quantise "$f")"
        # An unreadable or zero-colour file is skipped rather than cached as
        # empty — a cached empty would never be retried.
        [ -n "$cols" ] && printf '%s\t%s\t%s\t%s\n' "$f" "$mt" "$sz" "$cols" >>"$tmp"
    done < <(files_themed)

    # Replaced by mv, like every other file this desktop writes: a second
    # settings menu opening mid-scan must never read half a cache.
    mv "$tmp" "$CACHE"
    return 0
}

# ── the palette in force ─────────────────────────────────────────────────
# Read from the live pywal cache and not from palettes/<name>.json, and that is
# deliberate: applying a palette WRITES that cache (palette.sh), so the cache is
# the one answer that is right under a static palette and under "pywal" alike.
# Under pywal the palette is derived from the wallpaper that is up, so "by
# palette" there means "wallpapers that look like the one on screen" — which is
# the same question, asked of the same colours.
#
# One colour, and which one is the whole of the matching rule — see the header
# for the sixteen-slot version that was measured and rejected. It is printed as
# a space-separated LIST because the scorer takes the nearest of a set, and
# leaving that shape means widening the reference set later is a change to this
# one line rather than to the maths.
# The palette's NAME, which is the other half of what this page needs: the
# colours say what matches, the name says which directory of backgrounds was
# chosen for it. Asked of palette.sh rather than re-read out of ui.conf here,
# so "absent means pywal" is decided in exactly one place. Resolved beside this
# script, the same rule as apply-wallpaper.sh's — from ~/.config/scripts that
# is the live palette.sh, from the repo it is the repo's.
palette_current() {
    local self_dir
    self_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
    [ -x "$self_dir/palette.sh" ] || return 0
    "$self_dir/palette.sh" current 2>/dev/null | head -1
    return 0
}

palette_colors() {
    [ -r "$WAL_JSON" ] || return 1
    jq -r '[ .special.background ] | map(select(. != null)) | join(" ")' \
       "$WAL_JSON" 2>/dev/null
}

# ── scoring ──────────────────────────────────────────────────────────────
# gawk, for strtonum. It is in Arch's base group and every other awk in this
# repo is gawk too.
#
# Prints the surviving paths, best first. The score itself is not printed: it
# is a means of ordering, and a ΔE on a settings row would be a number nobody
# can act on.
# rank <palette hexes> [exclude dir] [have-own 0|1]
rank() {
    local pal excl haveOwn
    pal="$1"; excl="${2:-}"; haveOwn="${3:-0}"
    gawk -F'\t' -v pal="$pal" -v excl="$excl" -v haveOwn="$haveOwn" \
         -v cutAbs="$CUT_ABS" -v cutNear="$CUT_NEAR" '
    function srgb2lin(c,   v) { v = c / 255; return (v <= 0.04045) ? v / 12.92 : ((v + 0.055) / 1.055) ^ 2.4 }
    # The CIE f(t), with the linear segment below the knee — without it the
    # cube root of a near-zero Y sends every dark colour off to its own corner
    # of the space, and this collection is mostly dark.
    function fxyz(t) { return (t > 0.008856) ? t ^ (1/3) : (7.787 * t + 16 / 116) }
    function toLab(r, g, b, out,   R, G, B, X, Y, Z) {
        R = srgb2lin(r); G = srgb2lin(g); B = srgb2lin(b)
        # D65, and X and Z divided through by the white point so the reference
        # white lands at L*=100, a*=b*=0.
        X = (0.4124 * R + 0.3576 * G + 0.1805 * B) / 0.95047
        Y = (0.2126 * R + 0.7152 * G + 0.0722 * B)
        Z = (0.0193 * R + 0.1192 * G + 0.9505 * B) / 1.08883
        out[0] = 116 * fxyz(Y) - 16
        out[1] = 500 * (fxyz(X) - fxyz(Y))
        out[2] = 200 * (fxyz(Y) - fxyz(Z))
    }
    function hex2lab(h, out,   r, g, b) {
        gsub(/^#/, "", h)
        r = strtonum("0x" substr(h, 1, 2))
        g = strtonum("0x" substr(h, 3, 2))
        b = strtonum("0x" substr(h, 5, 2))
        toLab(r, g, b, out)
    }
    BEGIN {
        np = split(pal, hexes, " ")
        for (i = 1; i <= np; i++) { hex2lab(hexes[i], L); pL[i] = L[0]; pA[i] = L[1]; pB[i] = L[2] }
        n = 0
    }
    {
        # NOTE: no apostrophes in this awk program. It is a single-quoted
        # shell string, so one would close the quote and hand the rest of the
        # scorer to bash.
        #
        # The backgrounds belonging to the palette in force are already listed
        # above this, in full and in their own order. Scoring them again would
        # print each of them twice, which is the one thing a picker must not
        # do.
        if (excl != "" && index($1, excl "/") == 1) next
        m = split($4, parts, ";")
        if (m == 0) next
        tw = 0; score = 0
        for (i = 1; i <= m; i++) {
            split(parts[i], c, ",")
            toLab(c[1] + 0, c[2] + 0, c[3] + 0, L)
            w = c[4] + 0
            best = 1e9
            for (j = 1; j <= np; j++) {
                d = sqrt((L[0] - pL[j]) ^ 2 + (L[1] - pA[j]) ^ 2 + (L[2] - pB[j]) ^ 2)
                if (d < best) best = d
            }
            score += w * best
            tw += w
        }
        if (tw <= 0) next
        n++; path[n] = $1; sc[n] = score / tw
    }
    END {
        if (n == 0) exit 0
        # Insertion sort. n is the number of files in one directory.
        for (i = 2; i <= n; i++) {
            ks = sc[i]; kp = path[i]; j = i - 1
            while (j >= 1 && sc[j] > ks) { sc[j+1] = sc[j]; path[j+1] = path[j]; j-- }
            sc[j+1] = ks; path[j+1] = kp
        }
        cut = cutAbs
        # The relative floor rescues a page that would otherwise answer with
        # nothing. With the theme own backgrounds already on it there is
        # nothing to rescue, so the absolute cut stands alone — otherwise a
        # palette whose other-theme matches are all poor would widen the page
        # to include them anyway, which is the opposite of a shortlist.
        if (!haveOwn && sc[1] + cutNear > cut) cut = sc[1] + cutNear
        for (i = 1; i <= n; i++) if (sc[i] <= cut) print path[i]
    }' "$CACHE"
}

# ── the listing ──────────────────────────────────────────────────────────
# value <TAB> label <TAB> detail <TAB> current — ui-prefs.sh's one listing
# format, so Settings.qml's parser needs to know nothing about wallpapers. The
# value is the absolute path, which is both what apply-wallpaper.sh wants and
# what the row draws itself with.
#
# `detail` carries the THEME for an omarchy background and is empty for one of
# Ahaan's own. The panel draws it in the trailing slot, which is where that
# file already puts "something about the row that is not a description of it" —
# and here it is the one thing the filename cannot say, since four themes ship
# a background called "omarchy" and nine call their first one "1-something".
emit() {
    local cur; cur="$(current_wallpaper)"
    local f
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        printf '%s\t%s\t%s\t%s\n' "$f" "$(label_of "$f")" "$(theme_of "$f")" \
               "$([ "$f" = "$cur" ] && printf 'current')"
    done
}

# Ahaan's own first and the themed tree after it, rather than one merged
# alphabetical run. His are the ones he chose and put there; a list that
# interleaves them with 92 downloaded images buries them, and "All" is the page
# he goes to when he already knows which picture he wants.
list_all() { { files_mine; files_themed; } | emit; }

# ── by palette ───────────────────────────────────────────────────────────
# Two parts, in this order:
#
#   1. the backgrounds shipped with the palette in force, all of them, always.
#      omarchy chose those FOR those colours, which is a better answer than any
#      distance this script can compute — and it is the part that fixes the
#      reported bug, since it is different for every palette by construction.
#   2. everything else under the cut, best first, by the colour rule at the top
#      of this file.
#
# Ahaan's own directory is deliberately absent from both. That is his call:
# "keep [my own] only in the all branch".
list_by_palette() {
    local pal cur own_dir
    pal="$(palette_colors)" || pal=""
    cur="$(palette_current)"
    own_dir=""
    [ -n "$cur" ] && [ -d "$THEME_DIR/$cur" ] && own_dir="$THEME_DIR/$cur"

    # No palette to compare against means no comparison was made, and the page
    # must not claim one. Falling back to the whole omarchy tree is the honest
    # failure: it shows what exists rather than asserting that all of it
    # matches. Only reachable on a machine where pywal has never run, or one
    # where the fetch script has not been run and there is nothing to rank.
    if [ -z "$pal" ] || ! scan; then
        files_themed | emit
        return 0
    fi

    if [ -n "$own_dir" ]; then
        find "$own_dir" -maxdepth 1 -type f -not -name '.*' \
             -regextype posix-extended -iregex ".*$EXT_RE" -print | sort | emit
    fi
    # haveOwn tells the scorer whether the page is already non-empty. The
    # `best + CUT_NEAR` floor exists ONLY to stop a page answering with
    # nothing; with the palette's own backgrounds already listed there is
    # nothing to rescue, so the absolute cut stands alone and the page does not
    # widen itself for a palette whose matches are all poor.
    rank "$pal" "$own_dir" "$([ -n "$own_dir" ] && printf 1 || printf 0)" | emit
}

case "${1:-}" in
    list)
        case "${2:-all}" in
            all)        list_all ;;
            by-palette) list_by_palette ;;
            *)          die "usage: wallpapers.sh list [all|by-palette]" ;;
        esac ;;
    scan) scan || die "imagemagick is missing" ;;
    *)
        echo "usage: $(basename "$0") list [all|by-palette]" >&2
        echo "       $(basename "$0") scan" >&2
        exit 2
        ;;
esac
