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

mons="$(hyprctl monitors -j 2>/dev/null)" || die "hyprctl unavailable"
# x y w h and the four reserved insets (left top right bottom), all logical.
read -r mx my mw mh rl rt rr rb < <(printf '%s' "$mons" | jq -r '
    ([.[] | select(.disabled | not)] | (map(select(.focused)) + .)[0])
    | "\(.x) \(.y) \(.width / .scale | round) \(.height / .scale | round) \(.reserved | map(tostring) | join(" "))"')
[ -n "${mw:-}" ] && [ "${mw:-0}" -gt 0 ] || die "could not read monitor size"

# gaps_out reads back as "css gap data: T R B L"; border_size as "int: N".
gap="$(hyprctl getoption general:gaps_out 2>/dev/null | awk '/gap data/ { print $NF; exit }')"
border="$(hyprctl getoption general:border_size 2>/dev/null | awk '/^int:/ { print $2; exit }')"
case "${gap:-}"    in ''|*[!0-9]*) gap=3 ;;    esac
case "${border:-}" in ''|*[!0-9]*) border=2 ;; esac
inset=$(( gap + border ))

x=$(( mx + rl + inset ))
y=$(( my + rt + border ))             # top gap 0: the bar's zone supplies it
w=$(( mw - rl - rr - 2 * inset ))
h=$(( mh - rt - rb - border - inset ))

# WINDOW_ZOOM_DRY=1 prints the geometry instead of applying it.
if [ -n "${WINDOW_ZOOM_DRY:-}" ]; then echo "$x $y $w $h"; exit 0; fi

# `hyprctl dispatch` takes a Lua expression since 0.55 — the old positional
# form (`resizeactive exact W H`) parses as nothing and silently no-ops.
hyprctl dispatch "hl.dsp.window.resize({ x = $w, y = $h })" >/dev/null
hyprctl dispatch "hl.dsp.window.move({ x = $x, y = $y })"   >/dev/null
