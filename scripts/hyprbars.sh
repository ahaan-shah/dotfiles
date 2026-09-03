#!/usr/bin/env bash
#
# hyprbars.sh <command> — everything to do with the hyprbars title bars.
#
#   on | off | toggle [--persist]   load/unload the plugin in this session
#   status                          what is loaded now, and what happens at login
#   minimize                        the yellow button: hide/restore the active window
#   zoom                            SUPER+D: fill the screen, bar- and scale-aware
#
# Merged from toggle-hyprbars.sh and hyprbars-minimize.sh, which were two halves
# of the same feature: one turns the bars on, the other is wired to a button
# drawn on them. Splitting them meant the button's script could go missing while
# the bars still rendered it.
#
# ── Why the plugin has to be toggled carefully ────────────────────────────
# Disabling it by hand used to leave the desktop unusable. hyprland.lua called
# `hl.plugin.hyprbars.add_button(...)` unconditionally, and with the plugin
# unloaded that raises "attempt to index a nil value (field 'hyprbars')",
# aborting the config parse where it stands. Hyprland then trips EMERGENCY MODE
# and every bind is replaced by its own SUPER+Q / SUPER+R / SUPER+M.
# Measured 2026-09-02: `hyprctl binds` read 3, against 67 expected.
# hyprland.lua now gates the whole hyprbars block, so either state parses clean.
#
# ── Why hyprctl and not hyprpm ────────────────────────────────────────────
# `hyprpm enable/disable` writes to /var/cache/hyprpm/, which is root-owned, so
# it shells out to sudo and prompts for a password. Fine in a terminal, useless
# from a keybind, where there is no tty and the prompt just hangs invisibly.
#
# `hyprctl plugin load/unload` needs no privileges at all — the .so is
# world-readable (0755 root:root) and the compositor is ours. Measured: each
# takes effect immediately, Hyprland re-parses the config on its own (no
# `hyprctl reload` needed — bar_height read back as 22, "set: true", straight
# after a bare load), binds stay at 67 and `hyprctl configerrors` stays empty in
# both directions.
#
# The trade-off, and the reason for --persist: a runtime load/unload lasts until
# the next login. What hyprbars does at BOOT is decided by hyprpm's own state,
# which the startup hook applies via `hyprpm reload`. Pass --persist to change
# that too; it will ask for a password, so run it from a terminal.

set -euo pipefail

PLUGIN="hyprbars"
MIN_STATE="$HOME/.cache/hypr_minimize_state"
MIN_WS="special:magic"

die() { echo "hyprbars: $*" >&2; exit 1; }

# ── plugin state ──────────────────────────────────────────────────────────

# find_so — the plugin binary, located rather than hardcoded: the path contains
# both the username and the repository name, and hyprpm rebuilds it into a new
# directory whenever the plugin repo is re-added.
#
# -print -quit rather than `| head -1`: piping into head makes head exit on the
# first line, find dies of SIGPIPE, and `set -o pipefail` turns a successful
# search into a failure. Same trap as the font check in install.sh.
find_so() {
    find "/var/cache/hyprpm/$USER" -name "$PLUGIN.so" -print -quit 2>/dev/null
}

# is_loaded — reality: is it in the running compositor right now? This is what
# the gate in hyprland.lua keys off, and what on/off actually change.
is_loaded() {
    [ "$(hyprctl plugin list 2>/dev/null | grep -c "$PLUGIN")" -gt 0 ]
}

# is_enabled — intent: what hyprpm will do at the next login. Not the same
# question as is_loaded, and the two are allowed to disagree until then. hyprpm
# colours its output, so strip ANSI before matching, and use awk rather than
# `grep -q` for the SIGPIPE reason above.
is_enabled() {
    hyprpm list 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | awk -v p="$PLUGIN" '
        $0 ~ ("Plugin " p "$") { hit = 1; next }
        hit && /enabled:/      { if ($0 ~ /true/) found = 1; hit = 0 }
        END { exit !found }
    '
}

# report — always ends with the bind count. A count far below the real one means
# the config parse aborted early and Hyprland fell back to emergency binds,
# which is the one failure this script exists to make impossible.
report() {
    local binds
    binds="$(hyprctl binds 2>/dev/null | grep -c '^bind' || true)"
    printf 'hyprbars %s now · at login: %s · %s binds\n' \
        "$(is_loaded && echo on || echo off)" \
        "$(is_enabled && echo on || echo off)" \
        "$binds"
    if [ "${binds:-0}" -lt 10 ]; then
        echo "WARNING: only $binds binds — the config parse aborted early." >&2
        echo "         see: hyprctl configerrors" >&2
        return 1
    fi
}

# persist — change what happens at the NEXT login. Needs root, so it is opt-in
# and never on the path a keybind takes.
persist() {
    local want="$1"
    if [ "$want" = on ]; then
        is_enabled && return 0
        hyprpm enable "$PLUGIN" >/dev/null || die "hyprpm enable failed"
    else
        is_enabled || return 0
        hyprpm disable "$PLUGIN" >/dev/null || die "hyprpm disable failed"
    fi
}

set_plugin() {
    local action="$1" persist_too="$2" so
    so="$(find_so)"
    [ -n "$so" ] || die "no $PLUGIN.so under /var/cache/hyprpm/$USER — run: hyprpm add https://github.com/hyprwm/hyprland-plugins"
    if [ "$action" = on ]; then
        is_loaded || hyprctl plugin load "$so" >/dev/null || die "plugin load failed"
    else
        ! is_loaded || hyprctl plugin unload "$so" >/dev/null || die "plugin unload failed"
    fi
    [ "$persist_too" = 1 ] && persist "$action"
    report
}

# ── minimize ──────────────────────────────────────────────────────────────
# The yellow button. Sends the active window to a special workspace and
# remembers where it came from, so a second press puts it back.
#
# The state file is append-only lines of "<address> <workspace-id>". It is in
# ~/.cache deliberately: losing it costs a restored window landing on workspace
# 1 instead of its original, which is recoverable by dragging it.
# prune_state — drop lines whose window no longer exists.
#
# The file was append-only and never shrank. Measured 2026-09-02: 111 lines, and
# every single one referred to a window that had already been closed. Mostly
# that is just waste, but it is also a correctness risk — a Hyprland window
# address is a heap pointer, the allocator reuses them, and a stale line will
# happily restore a brand-new window to some long-dead window's workspace.
#
# Takes the client list as an argument rather than re-querying: minimize()
# already has it, and two `hyprctl clients` round trips would be two chances for
# the answer to change underneath us.
prune_state() {
    local clients="$1" live
    [ -f "$MIN_STATE" ] || return 0
    live="$(printf '%s' "$clients" | jq -r '.[].address')"
    # An empty client list means the query failed, not that every window closed.
    # Without this guard that mistake truncates the whole file.
    [ -n "$live" ] || return 0
    if awk 'NR==FNR { seen[$1]; next } ($1 in seen)' \
           <(printf '%s\n' "$live") "$MIN_STATE" >"$MIN_STATE.tmp"; then
        mv "$MIN_STATE.tmp" "$MIN_STATE"
    else
        rm -f "$MIN_STATE.tmp"
    fi
}

minimize() {
    local info addr ws current old clients

    info="$(hyprctl activewindow -j 2>/dev/null || true)"
    addr="$(printf '%s' "$info" | jq -r '.address // empty')"
    # No focused window — the button cannot be clicked without one, but the
    # command is also reachable from a shell, and 'address:null' would be
    # dispatched at whatever the compositor made of it.
    [ -n "$addr" ] || die "no active window"
    ws="$(printf '%s' "$info" | jq -r '.workspace.id // empty')"

    # Queried once and reused, by prune_state too.
    clients="$(hyprctl clients -j 2>/dev/null || echo '[]')"
    current="$(printf '%s' "$clients" \
               | jq -r --arg a "$addr" '.[] | select(.address == $a) | .workspace.name')"

    if [ "$current" = "$MIN_WS" ]; then
        # Restore. awk rather than `grep "$addr" | awk '{print $2}'`: grep exits
        # 1 when the cache has been wiped, which under `set -o pipefail` aborts
        # the script instead of falling through to workspace 1. awk matches on
        # field 1 anchored, so a substring of another address cannot match either.
        old=""
        if [ -f "$MIN_STATE" ]; then
            old="$(awk -v a="$addr" '$1 == a { print $2 }' "$MIN_STATE" | tail -1 || true)"
        fi
        # hyprctl dispatch takes a Lua dispatcher expression since 0.55
        # (shorthand for `eval 'hl.dispatch(...)'`), not the old positional
        # `dispatchname arg1,arg2` string — which parses as nothing and no-ops.
        hyprctl dispatch "hl.dsp.window.move({ workspace = ${old:-1}, window = 'address:$addr' })" >/dev/null
        # `if`, not `[ -f ... ] && sed`: as the last command in this branch a
        # false test becomes the function's exit status, so restoring a window
        # whose state line had been wiped reported failure. An `if` with no
        # else returns 0.
        if [ -f "$MIN_STATE" ]; then
            sed -i "\|^$addr |d" "$MIN_STATE"
        fi
    else
        [ -n "$ws" ] || die "active window has no workspace id"
        mkdir -p "$(dirname "$MIN_STATE")"
        prune_state "$clients"
        printf '%s %s\n' "$addr" "$ws" >>"$MIN_STATE"
        # follow = false: send it away without switching the view to it.
        hyprctl dispatch "hl.dsp.window.move({ workspace = '$MIN_WS', follow = false, window = 'address:$addr' })" >/dev/null
    fi
}

# ── zoom ──────────────────────────────────────────────────────────────────
# SUPER+D: fill the usable screen without going fullscreen.
#
# The geometry depends on whether the title bars are loaded, which is why it
# lives here and not as two literal numbers in hyprland.lua. A hyprbar adds its
# own height above the window, so geometry placed for a bare desktop pushes the
# window up under the taskbar the moment the bars come back:
#
#   bars off :  1425x753 at 7,51
#   bars on  :  1425x733 at 7,69     (20px shorter, 18px lower)
#
# The bind cannot make this choice itself. hyprland.lua is parsed when the
# config loads, while the plugin is loaded and unloaded underneath it at
# runtime by this very script — so the decision has to happen at keypress time,
# which means in the thing the keypress runs.
#
# is_loaded is the right question rather than is_enabled: what matters is
# whether a bar is being drawn on the window right now, not what hyprpm intends
# to do at the next login.
# The geometry is a FRACTION of the monitor, not the pixel numbers it used to
# be, so SUPER+D fills the screen the same way at any resolution or scale. The
# fractions are the pixels it was tuned at over the 1440x810 logical screen
# this panel gives at scale 2, and each one rounds back to that exact pixel
# value there.
#
# Computed here rather than handed to Hyprland as the "(monitor_w*0.99)"
# expression the window RULES use: measured 2026-09-03, the dispatchers do not
# accept those strings. `hl.dsp.window.resize({ x = '(monitor_w*0.5)' })`
# silently no-ops — the window kept the size its rule had given it — so a bind
# has to arrive with numbers already in hand.
#
# LOGICAL pixels, which is width/scale: window geometry is in the same space
# `hyprctl clients` reports, not the physical mode. The focused monitor, so
# this still does the right thing with a second display attached — the active
# window is on the monitor that has focus.
zoom() {
    local mons w h x y mw mh h_f y_f
    mons="$(hyprctl monitors -j 2>/dev/null)" || die "hyprctl unavailable"
    read -r mw mh < <(printf '%s' "$mons" | jq -r '
        ([.[] | select(.disabled | not)] | (map(select(.focused)) + .)[0])
        | "\(.width / .scale | round) \(.height / .scale | round)"')
    [ -n "${mw:-}" ] && [ "${mw:-0}" -gt 0 ] || die "could not read monitor size"

    if is_loaded; then h_f=0.905 y_f=0.085
    else               h_f=0.93 y_f=0.063
    fi
    # awk, not $(( )): bash has no floating point.
    w=$(awk -v m="$mw" 'BEGIN{ printf "%d", m*0.9896 + 0.5 }')
    x=$(awk -v m="$mw" 'BEGIN{ printf "%d", m*0.005 + 0.5 }')
    h=$(awk -v m="$mh" -v f="$h_f" 'BEGIN{ printf "%d", m*f + 0.5 }')
    y=$(awk -v m="$mh" -v f="$y_f" 'BEGIN{ printf "%d", m*f + 0.5 }')

    # `hyprctl dispatch` takes a Lua expression since 0.55 — the old positional
    # form (`resizeactive exact W H`) parses as nothing and silently no-ops.
    hyprctl dispatch "hl.dsp.window.resize({ x = $w, y = $h })" >/dev/null
    hyprctl dispatch "hl.dsp.window.move({ x = $x, y = $y })" >/dev/null
}

# ── dispatch ──────────────────────────────────────────────────────────────
# No default command on purpose: a bare `hyprbars.sh` used to mean "toggle the
# whole plugin", which is a surprising thing to get from a typo now that this
# script also drives a window button.
PERSIST=0
[ "${2:-}" = "--persist" ] && PERSIST=1

case "${1:-}" in
    on|off)   set_plugin "$1" "$PERSIST" ;;
    toggle)   if is_loaded; then set_plugin off "$PERSIST"; else set_plugin on "$PERSIST"; fi ;;
    status)   report ;;
    minimize) minimize ;;
    zoom)     zoom ;;
    *)
        echo "usage: $(basename "$0") {on|off|toggle|status} [--persist]" >&2
        echo "       $(basename "$0") {minimize|zoom}" >&2
        exit 2
        ;;
esac
