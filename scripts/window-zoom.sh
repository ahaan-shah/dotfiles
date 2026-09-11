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
# The fractions are the ones the old hyprbars-less branch used — 0.9896 wide
# and 0.93 tall, offset 0.005 and 0.063 — which land on 1425x733 at +7+69
# against this panel's 1440x810 logical screen. That is the geometry the
# original bind hardcoded, kept so the key does exactly what it always did.

set -euo pipefail

die() { echo "window-zoom: $*" >&2; exit 1; }

command -v hyprctl >/dev/null 2>&1 || die "hyprctl unavailable"
command -v jq      >/dev/null 2>&1 || die "jq unavailable"

mons="$(hyprctl monitors -j 2>/dev/null)" || die "hyprctl unavailable"
read -r mw mh < <(printf '%s' "$mons" | jq -r '
    ([.[] | select(.disabled | not)] | (map(select(.focused)) + .)[0])
    | "\(.width / .scale | round) \(.height / .scale | round)"')
[ -n "${mw:-}" ] && [ "${mw:-0}" -gt 0 ] || die "could not read monitor size"

# awk, not $(( )): bash has no floating point.
w=$(awk -v m="$mw" 'BEGIN{ printf "%d", m*0.9896 + 0.5 }')
x=$(awk -v m="$mw" 'BEGIN{ printf "%d", m*0.005  + 0.5 }')
h=$(awk -v m="$mh" 'BEGIN{ printf "%d", m*0.93   + 0.5 }')
y=$(awk -v m="$mh" 'BEGIN{ printf "%d", m*0.063  + 0.5 }')

# `hyprctl dispatch` takes a Lua expression since 0.55 — the old positional
# form (`resizeactive exact W H`) parses as nothing and silently no-ops.
hyprctl dispatch "hl.dsp.window.resize({ x = $w, y = $h })" >/dev/null
hyprctl dispatch "hl.dsp.window.move({ x = $x, y = $y })"   >/dev/null
