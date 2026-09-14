#!/usr/bin/env bash
# palette.sh  {list|current|apply <name>|wallpaper-changed <path>}
#
# The colour scheme every surface on this desktop follows. Settings → Theme →
# Palette is the front end; this is all of the behaviour.
#
# ── Why this goes through pywal rather than around it ─────────────────────
# Nine things read a colour on this machine and every one of them reads it out
# of ~/.cache/wal: the four Quickshell shells (colors.json, and colors-waybar.
# css for the taskbar), hyprland.lua (colors-hyprland.lua, for the window
# borders), kitty and ghostty (colors-kitty.conf / colors-ghostty.conf, both
# `include`d), fastfetch, the three fzf package pickers (colors.sh), and cava
# (sed'd below, because its config has no include). Writing that cache is a job
# pywal already does completely, including the escape sequences that repaint
# terminals that are ALREADY OPEN.
#
# So a palette is not a new mechanism. It is a static pywal colourscheme fed in
# with `wal --theme` instead of one derived from a wallpaper with `wal -i`, and
# every consumer above is untouched and unaware. "pywal" is therefore a palette
# like any other in the menu — it is simply the one that derives itself from
# whatever wallpaper is up.
#
# ── Where the palettes come from, and the one deliberate re-mapping ───────
# palettes/*.json are pywal colourscheme files derived from omarchy's theme set
# (github.com/omacom/omarchy, themes/<name>/colors.toml, branch quattro at
# b679363bed05, MIT). omarchy states a palette semantically — background,
# foreground, accent, red … bright_magenta — and this is how those become the
# sixteen slots pywal exports:
#
#   color0  background      color8   muted
#   color1  red             color9   ACCENT          <- see below
#   color2  green           color10  bright_green
#   color3  yellow          color11  bright_yellow
#   color4  blue            color12  bright_blue
#   color5  magenta         color13  bright_magenta
#   color6  cyan            color14  bright_cyan
#   color7  light_fg        color15  bright_fg
#
# color9 is ANSI bright red and it is the theme's accent here instead, because
# on this desktop slot 9 IS the accent: taskbar/shell.qml calls it ncAccent and
# finder/Theme.qml calls it Theme.accent, and between them it draws every
# selected row, toggle, slider and meter in the UI. Left as bright red, picking
# "Tokyo Night" would paint every selection salmon pink; measured across the 22
# themes, `accent` is the `blue` slot in 19 of them, so the UI would also have
# been the one part of the desktop not wearing the theme's own colour.
#
# The cost is that bright red is not red in a terminal, and it is smaller than
# it sounds: normal red (color1) is what "red means error" actually uses, and
# it is genuinely red here for the first time. Under a wallpaper-derived pywal
# palette — i.e. everything this machine has ever run — all sixteen slots are
# arbitrary image colours already, color1 included.
#
# Adding a palette is adding a file to palettes/, the same shape as an agent
# collector: nothing here or in Settings.qml holds a list of theme names.
set -euo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PAL_DIR="$SELF_DIR/palettes"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}/scripts/ui.conf"
CAVA_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/cava/config"
WALLPAPER_STATE="${XDG_STATE_HOME:-$HOME/.local/state}/hyprahaan/wallpaper"
# Only a fallback now, for a machine updated but not yet restarted: hyprpaper
# was replaced by macshell/Wallpaper.qml on 2026-09-14 and nothing writes this
# file any more.
HYPRPAPER_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/hyprpaper.conf"

# The wallpaper-derived palette. Not a file in palettes/ — it is the ONE entry
# that is a mechanism rather than a set of colours.
PYWAL="pywal"

die() { echo "palette: $*" >&2; exit 1; }

# ── what is in effect ────────────────────────────────────────────────────
# Same rule as ui-prefs.sh's `effective`: a key that was never set still has an
# answer, and here the answer is what this desktop did before palettes existed.
current() {
    local v=""
    [ -f "$CONF" ] && v="$(sed -n 's/^PALETTE="\(.*\)"$/\1/p' "$CONF" | head -1)"
    [ -n "$v" ] || v="$PYWAL"
    printf '%s' "$v"
}

# ── the listing ──────────────────────────────────────────────────────────
# value <TAB> label <TAB> detail <TAB> current — ui-prefs.sh's one listing
# format, so finder's parser needs to know nothing about palettes.
#
# `detail` carries three hexes, background/accent/foreground, and the settings
# panel draws them as dots. That is data and not a drawing decision: which
# three roles a palette is previewed by is a fact about this desktop's palette
# (ground, selection, text), and a list of 22 theme names with no colour in it
# is the same list-of-smudges problem the Fonts page solves by drawing each
# family in its own face.
list() {
    local cur; cur="$(current)"
    local bg accent fg

    # pywal first: it is the default and the one anybody lands back on.
    #
    # Its swatch is the live cache — but ONLY while pywal is what is in effect,
    # because then the cache IS what this wallpaper yields. Under a static
    # palette the cache holds that palette, and drawing it on the pywal row
    # would promise the user the colours they are already looking at. What
    # pywal would produce from this image is not knowable without running it,
    # so the row shows nothing rather than something false. Every other row
    # states its own colours and is never in this position.
    if [ "$cur" = "$PYWAL" ]; then
        bg="$(_cache_color special background '#1a1a1a')"
        accent="$(_cache_color colors color9 '#888888')"
        fg="$(_cache_color special foreground '#cccccc')"
        printf '%s\t%s\t%s\tcurrent\n' "$PYWAL" "Pywal — from the wallpaper" "$bg,$accent,$fg"
    else
        printf '%s\t%s\t\t\n' "$PYWAL" "Pywal — from the wallpaper"
    fi

    [ -d "$PAL_DIR" ] || return 0
    # One jq over every file rather than one per palette: 22 processes to draw
    # a menu is a menu that opens slowly. input_filename is what keeps the
    # value (the file's stem) attached to its own row.
    jq -r --arg cur "$cur" '
        [ (input_filename | sub(".*/";"") | sub("\\.json$";"")),
          .name,
          (.special.background + "," + .colors.color9 + "," + .special.foreground)
        ] as $r
        | $r[0] as $slug
        | [ $slug, ($r[1] // $slug), $r[2], (if $slug == $cur then "current" else "" end) ]
        | @tsv
    ' "$PAL_DIR"/*.json 2>/dev/null | sort -t"$(printf '\t')" -k2,2f
    return 0
}

# One colour out of the live pywal cache, with a fallback for a machine that
# has never run wal at all. jq and not sed: colors.json is JSON.
_cache_color() {
    local sect="$1" key="$2" fallback="$3" v=""
    [ -r "$HOME/.cache/wal/colors.json" ] &&
        v="$(jq -r --arg k "$key" ".${sect}[\$k] // empty" "$HOME/.cache/wal/colors.json" 2>/dev/null || true)"
    printf '%s' "${v:-$fallback}"
}

# ── applying ─────────────────────────────────────────────────────────────

# Which image is up. One line in one state file, written by
# finder/apply-wallpaper.sh and read by everything that needs it — the desktop
# surface, the lock screen, and this.
#
# This used to ask `hyprctl hyprpaper listactive` and fall back to parsing
# hyprpaper.conf, because the file could name an output that did not exist and
# the daemon was the only thing that knew what was really on screen. There is
# no daemon and no monitor name to be wrong about now; the recorded path IS the
# wallpaper. The hyprpaper.conf read survives only as a migration fallback, for
# a machine that has taken this update without restarting its session.
wallpaper_path() {
    local p=""
    [ -r "$WALLPAPER_STATE" ] && p="$(head -1 "$WALLPAPER_STATE")"
    if [ -z "$p" ] || [ ! -f "$p" ]; then
        [ -r "$HYPRPAPER_CONF" ] &&
            p="$(sed -n 's/^path = //p' "$HYPRPAPER_CONF" | head -1)"
    fi
    [ -n "$p" ] && [ -f "$p" ] && printf '%s' "$p"
    return 0
}

# Everything that does NOT read ~/.cache/wal on its own. Runs after any change
# to the palette and after nothing else.
fanout() {
    # Firefox, through pywalfox's own extension bridge.
    command -v pywalfox >/dev/null 2>&1 && pywalfox update >/dev/null 2>&1 || true

    # cava's config has no include directive, so its three gradient stops are
    # rewritten in place. A cava started later comes up on the new palette by
    # itself — this is why nothing here restarts it (see apply-wallpaper.sh,
    # where restarting it was a bug twice over).
    if [ -f "$CAVA_CONFIG" ] && [ -r "$HOME/.cache/wal/colors" ]; then
        local c1 c2 c3
        c1="$(sed -n '2p' "$HOME/.cache/wal/colors")"
        c2="$(sed -n '3p' "$HOME/.cache/wal/colors")"
        c3="$(sed -n '4p' "$HOME/.cache/wal/colors")"
        [ -n "$c1" ] && sed -i "s/^gradient_color_1 = .*/gradient_color_1 = '$c1'/" "$CAVA_CONFIG"
        [ -n "$c2" ] && sed -i "s/^gradient_color_2 = .*/gradient_color_2 = '$c2'/" "$CAVA_CONFIG"
        [ -n "$c3" ] && sed -i "s/^gradient_color_3 = .*/gradient_color_3 = '$c3'/" "$CAVA_CONFIG"
    fi

    # hyprland.lua require()s colors-hyprland.lua at PARSE time for the window
    # border colours, so the new file does nothing until the config is re-read.
    # The four shells need no push at all: they watch the cache themselves.
    command -v hyprctl >/dev/null 2>&1 && hyprctl reload >/dev/null 2>&1 || true
    return 0
}

# -n: never let pywal touch the wallpaper. macshell/Wallpaper.qml owns that,
# and a scheme file carries "wallpaper": "None" which pywal would otherwise
# try to set.
apply() {
    local name="$1" wp
    if [ "$name" = "$PYWAL" ]; then
        wp="$(wallpaper_path)"
        [ -n "$wp" ] || die "no wallpaper to read a palette from"
        wal -n -q -i "$wp"
    else
        [ -f "$PAL_DIR/$name.json" ] || die "no such palette: $name"
        wal -n -q --theme "$PAL_DIR/$name.json"
    fi
    fanout
}

# Called by finder/apply-wallpaper.sh once the new wallpaper is up. This is the
# whole of the palette's relationship with the wallpaper, and it is one branch:
# a static palette is a CHOICE and a new wallpaper does not overrule it, which
# is the entire point of having chosen one. Under "pywal" the colours are a
# function of the image, so they are re-derived exactly as they always were.
wallpaper_changed() {
    local wp="$1" cur
    cur="$(current)"
    [ "$cur" = "$PYWAL" ] || return 0
    [ -n "$wp" ] && [ -f "$wp" ] || die "wallpaper-changed: no such file: $wp"
    wal -n -q -i "$wp"
    fanout
}

case "${1:-}" in
    list)    list ;;
    current) current; echo ;;
    apply)   [ $# -ge 2 ] || die "usage: palette.sh apply <name>"; apply "$2" ;;
    wallpaper-changed)
             [ $# -ge 2 ] || die "usage: palette.sh wallpaper-changed <path>"
             wallpaper_changed "$2" ;;
    *)
        echo "usage: $(basename "$0") list" >&2
        echo "       $(basename "$0") current" >&2
        echo "       $(basename "$0") apply <name>" >&2
        echo "       $(basename "$0") wallpaper-changed <path>" >&2
        exit 2
        ;;
esac
