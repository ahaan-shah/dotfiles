#!/usr/bin/env bash
# window-zoom.sh — SUPER+D. Fills the focused monitor with the focused window.
#
# Was `hyprbars.sh zoom`, and is its own script now that hyprbars is gone. The
# rest of that file — on/off/toggle/persist/status, and a `minimize` that was
# only ever reachable from the plugin's yellow title-bar button — went with the
# plugin. Recover any of it from the history if the bars ever come back.
#
# ── Why a script and not a bind full of dispatchers ───────────────────────
# The numbers depend on the monitor, and the DISPATCHERS do not accept the
# "(monitor_w*0.99)" expressions that the window RULES do: measured 2026-09-03,
# `hl.dsp.window.resize({ x = '(monitor_w*0.5)' })` silently no-ops and the
# window keeps whatever size its rule gave it. So a bind has to arrive with
# pixels already in hand, which means asking hyprctl which monitor has focus
# and how big it is.
#
# LOGICAL pixels, which is width/scale: window geometry is in the same space
# `hyprctl clients` reports, not the physical mode. The FOCUSED monitor, so
# this still does the right thing with a second display attached.
#
# ── The geometry: exactly where a lone tiled window would sit ──────────────
# Ahaan, 2026-09-27: "fill the entire screen minus the bar and a really thin
# gap all around", then "the left, bottom and right gaps should be the same as
# the top gap from the bar", then the same thin gap for TILED windows.
#
# That last one is what made this simple. The bar's zone ends a few px below
# its islands (5px at `zone: 44` in Bar.qml), and hyprland.lua gives tiled windows
# gaps_out = { top = 0, others = WIN_GAPS_OUT }, so a tiled window's border
# starts on the zone's edge. This script computes the same box from the same
# three numbers, so a floating window sent here lines up with the tiled ones:
#
#   free area  the monitor minus its `reserved` insets (the bar's zone)
#   gap        gaps_out's LEFT value — the top is 0 by design, so not the first
#   border     general:border_size; content sits gap + border in, border
#              drawn inside that
#
# Measured on this panel before the bar's zone moved from 44 to 42: island
# edge ending at y=39, 3px of wallpaper, border at 42-44, content at 44.
# That is still where this lands — reserved 42 + border 2.
#
# Earlier versions, all 2026-09-26/27: fixed screen fractions (1425x733 at
# +7+69), then gaps_out from the reserved edge (7px on top, 2 at the sides),
# then a hardcoded INSET=5 measured off the 44px bar.

set -euo pipefail

die() { echo "window-zoom: $*" >&2; exit 1; }

command -v hyprctl >/dev/null 2>&1 || die "hyprctl unavailable"
command -v jq      >/dev/null 2>&1 || die "jq unavailable"

# ── The bar's edge is a setting (2026-10-31) ──────────────────────────────
# Settings -> Shell -> Bar puts the bar on the top, left or right. The edge it
# is on is the one with gap 0 (hyprland.lua, window-rules.sh apply_gaps), so
# that edge gets `border` and the other three `inset`. Which edge that is comes
# from `reserved` itself — the bar's zone is the only exclusive zone on this
# desktop (the dock reserves none), so the largest inset IS the bar — rather
# than from ui.conf, which the settings menu writes after it has already
# moved the bar.
#
# ── Zoomed windows follow the bar ─────────────────────────────────────────
# Ahaan: a window SUPER+D filled "should now take over the new empty space
# after the bar reposition (and should update instantly)". Tiled windows do
# that on their own — the layout re-runs on the new reserved area — but a
# floating window has only the pixels it was given.
#
# So `refit` (run by ui-prefs.sh when BAR_POSITION changes) looks for floating
# windows sitting EXACTLY on the zoom box of any of the three bar edges, and
# moves each to the box for the edge the bar is on now. "Exactly on a zoom
# box" is what being zoomed means, so there is no record to keep: a window
# zoomed before this existed, or one opened there by a rule (opentern's, in
# hyprland.lua), refits too, and one moved or resized by hand since is no
# longer on a box and is left alone. A runtime list of zoomed addresses was
# the first cut and missed exactly those two.
#
#   window-zoom.sh               zoom the focused window
#   window-zoom.sh refit [EDGE]  re-zoom zoomed windows; with EDGE, first wait
#                                (up to ~2 s) for the reserved inset to land on
#                                that edge, since the bar re-anchors async

# Reads the focused monitor once: mx my mw mh, the bar's thickness Z and edge,
# gap and border. Everything else is arithmetic on these.
read_monitor() {
    local mons rl rt rr rb
    mons="$(hyprctl monitors -j 2>/dev/null)" || die "hyprctl unavailable"
    # x y w h and the four reserved insets (left top right bottom), all logical.
    read -r MON mx my mw mh rl rt rr rb < <(printf '%s' "$mons" | jq -r '
        ([.[] | select(.disabled | not)] | (map(select(.focused)) + .)[0])
        | "\(.id) \(.x) \(.y) \(.width / .scale | round) \(.height / .scale | round) \(.reserved | map(tostring) | join(" "))"')
    [ -n "${mw:-}" ] && [ "${mw:-0}" -gt 0 ] || die "could not read monitor size"

    # The bar's zone is the only exclusive zone on this desktop (the dock
    # reserves none), so the largest inset is the bar, and its edge is the one
    # gaps_out holds at 0.
    BAR_EDGE=top; Z=$rt
    [ "$rl" -gt "$Z" ] && { BAR_EDGE=left;  Z=$rl; }
    [ "$rr" -gt "$Z" ] && { BAR_EDGE=right; Z=$rr; }
    # Always hide (BAR_AUTOHIDE) reserves nothing: no edge is the bar's, and
    # every side gets the outer gap (gaps_out has no 0 then).
    [ "$Z" -eq 0 ] && BAR_EDGE=none
    RB=$rb

    # gaps_out reads back as "css gap data: T R B L"; border_size as "int: N".
    # The BOTTOM value: it is never the bar's edge, so never the 0.
    gap="$(hyprctl getoption general:gaps_out 2>/dev/null | awk '/gap data/ { print $(NF-1); exit }')"
    border="$(hyprctl getoption general:border_size 2>/dev/null | awk '/^int:/ { print $2; exit }')"
    case "${gap:-}"    in ''|*[!0-9]*) gap=3 ;;    esac
    case "${border:-}" in ''|*[!0-9]*) border=2 ;; esac
}

# box_for <edge> [zone] — "x y w h" with a bar zone of that thickness on that
# edge (default: the one reserved now). The bar's own edge gets `border` only
# (gap 0 there: the zone supplies it), the other three gap + border. "none" is
# an auto-hidden bar: no zone, gap + border all round.
box_for() {
    local inset=$(( gap + border )) l=0 t=0 r=0 il it ir z="${2:-$Z}"
    il=$inset; it=$inset; ir=$inset
    case "$1" in
        none)  ;;
        left)  l=$z; il=$border ;;
        right) r=$z; ir=$border ;;
        *)     t=$z; it=$border ;;
    esac
    echo "$(( mx + l + il )) $(( my + t + it )) $(( mw - l - r - il - ir )) $(( mh - t - RB - it - inset ))"
}

place() {   # place <address|""> x y w h — "" is the focused window
    local sel=""
    [ -n "$1" ] && sel=", window = 'address:$1'"
    # `hyprctl dispatch` takes a Lua expression since 0.55 — the old positional
    # form (`resizeactive exact W H`) parses as nothing and silently no-ops.
    hyprctl dispatch "hl.dsp.window.resize({ x = $4, y = $5$sel })" >/dev/null
    hyprctl dispatch "hl.dsp.window.move({ x = $2, y = $3$sel })"   >/dev/null
}

# Bar.qml's `zone`, the thickness the bar reserves when it reserves any. Only
# refit needs it, to recognise boxes from a state other than the current one.
BAR_ZONE="${BAR_ZONE:-42}"

if [ "${1:-}" = "refit" ]; then
    want="${2:-}"
    for _ in $(seq 40); do
        read_monitor
        [ -z "$want" ] || [ "$BAR_EDGE" = "$want" ] && break
        sleep 0.05
    done
    read -r x y w h < <(box_for "$BAR_EDGE")
    # Within 8 px of a box, not exactly on it. Measured 2026-10-31: moving
    # the bar right -> top, refit placed two windows at 1430 wide and Hyprland
    # left both at 1431; and under Always hide, the zone appearing on a reveal
    # had Hyprland clamp zoomed floating windows into the work area with no
    # gap (46,2 1392x806 against the 46,5 1389x800 box) before refit ran.
    # Exact or 1 px matching then stopped counting them as zoomed and they
    # were left behind. A window within 8 px of a full-screen box on all four
    # numbers is zoomed — nothing placed by hand sits that close. And a
    # second pass once the first has settled puts them on the pixel.
    near() {   # near "ax ay aw ah" "bx by bw bh"
        local a=($1) b=($2) i d
        for i in 0 1 2 3; do
            d=$(( a[i] - b[i] )); [ "${d#-}" -le 8 ] || return 1
        done
    }
    # ONE hyprctl call for every window, front-most first. Window by window
    # (two hyprctl execs each) a full workspace resized "a split instant
    # after each other" on a bar move — Ahaan: "a weird glitchy look". As a
    # --batch they land together; ordered by focusHistoryID, so if a frame
    # is drawn mid-batch the window on top is already done and the ones
    # changing are behind it.
    refit_pass() {
        local cmds=""
        while read -r a ox oy ow oh; do
            cur="$ox $oy $ow $oh"
            [ "$cur" = "$x $y $w $h" ] && continue
            # A zoomed window sits on the box of SOME bar state: any edge at
            # the bar's zone (BAR_ZONE, Bar.qml's `zone`), or no zone at all.
            # Not the zone reserved now — after Always hide goes on that is 0,
            # and the window is still on a 44 px box.
            hit=""
            for b in "$(box_for none)" "$(box_for top "$BAR_ZONE")" \
                     "$(box_for left "$BAR_ZONE")" "$(box_for right "$BAR_ZONE")"; do
                near "$cur" "$b" && { hit=1; break; }
            done
            [ -n "$hit" ] || continue
            cmds+="dispatch hl.dsp.window.resize({ x = $w, y = $h, window = 'address:$a' }) ; "
            cmds+="dispatch hl.dsp.window.move({ x = $x, y = $y, window = 'address:$a' }) ; "
        done < <(hyprctl clients -j 2>/dev/null | jq -r --argjson m "$MON" \
            '[.[] | select(.floating and .monitor == $m and (.workspace.id > 0))]
             | sort_by(.focusHistoryID) | .[]
             | "\(.address) \(.at[0]) \(.at[1]) \(.size[0]) \(.size[1])"')
        [ -n "$cmds" ] && hyprctl --batch "$cmds" >/dev/null
        return 0
    }
    refit_pass
    sleep 0.15
    refit_pass
    exit 0
fi

read_monitor
read -r x y w h < <(box_for "$BAR_EDGE")

# WINDOW_ZOOM_DRY=1 prints the geometry instead of applying it.
if [ -n "${WINDOW_ZOOM_DRY:-}" ]; then echo "$x $y $w $h"; exit 0; fi

place "" "$x" "$y" "$w" "$h"
