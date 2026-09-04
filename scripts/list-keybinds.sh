#!/usr/bin/env bash
# list-keybinds.sh — every keybind, one per line, as
#   <combo> <TAB> <what it does> <TAB> <the call it makes>
# for finder's settings menu (Setup -> Keybindings).
#
# ── Why this parses the config and not `hyprctl binds` ────────────────────
# `hyprctl binds` is authoritative about WHAT IS BOUND, and useless about what
# any of it does. Under the Lua config every bind compiles to a callback, so
# all 67 come back looking like this:
#
#     SUPER + Q   dispatcher: __lua   arg: 6
#
# So the listing is built from the file. Each bind carries an explicit
#
#     -- desc: Opens the terminal
#
# line immediately above it, and that is what is shown. An ordinary comment is
# the fallback, and the Lua call itself is the last resort — which is what every
# bind used to show, and "SUPER + Q -> hl.dsp.exec_cmd(terminal)" tells you what
# the config says rather than what the key does.
#
# hyprctl is still consulted, for one thing it alone knows: the COUNT. A config
# that errors part-way through silently drops every bind after that point and
# Hyprland falls back to three emergency binds. If the compositor's count does
# not match the file's, that is reported as the first row rather than left for
# the user to discover by pressing a key that no longer works.
#
# ── The two shapes of bind in hyprland.lua ────────────────────────────────
#   hl.bind("ALT + S", ...)                       literal
#   hl.bind(mainMod .. " + Q", ...)               mainMod is "SUPER"
#   hl.bind(mainMod .. " + " .. key, ...)         inside the 1..10 workspace
#                                                 loop; expanded here the same
#                                                 way the loop expands it, so
#                                                 the twenty workspace binds are
#                                                 listed rather than missing.

set -euo pipefail

# The config BESIDE this script, never a fixed path — same rule as the taskbar's
# sideScriptDir. From ~/.config/scripts that resolves to ~/.config/hypr (the
# live config, which is what the running compositor parsed); from the repo's
# scripts/ it resolves to the repo's hypr/, so a dev instance launched out of
# the repo lists the repo's binds.
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONF="$here/../hypr/hyprland.lua"
[ -f "$CONF" ] || CONF="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/hyprland.lua"
[ -f "$CONF" ] || { echo "no hyprland.lua found" >&2; exit 1; }

parse() {
    awk '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }

    # The second argument of hl.bind(...). Used as the description when a bind
    # carries no comment, and always as the third column.
    function action_of(s,   p) {
        p = s
        sub(/^[^,]*,[[:space:]]*/, "", p)
        sub(/\)[[:space:]]*$/, "", p)
        return trim(p)
    }

    function emit(s,   t, combo, rest, act, desc, i, k, nl, a) {
        # mainMod is a local holding "SUPER"; substituting it and then joining
        # adjacent string literals turns  mainMod .. " + Q"  into  "SUPER + Q",
        # which is exactly the form `hyprctl binds` reports.
        gsub(/mainMod/, "\"SUPER\"", s)
        gsub(/" \.\. "/, "", s)
        if (match(s, /hl\.bind\("[^"]*"/) == 0) return
        t     = substr(s, RSTART, RLENGTH)
        combo = substr(t, 10, length(t) - 10)      # strip  hl.bind("  and  "
        rest  = substr(s, RSTART + RLENGTH)
        act   = action_of(s)

        # Four binds pass a multi-line Lua function rather than a dispatcher, so
        # the bind line itself ends at "function(" and says nothing. The first
        # non-blank line of the body is the dispatcher it actually fires, which
        # is the useful thing to show. getline consumes it from the main loop
        # too, which is correct — it belongs to this bind.
        if (act ~ /^function[[:space:]]*\(/) {
            while ((getline nl) > 0) if (nl ~ /[^[:space:]]/) break
            if (nl ~ /[^[:space:]]/) act = trim(nl)
        }

        desc = (descline != "") ? descline : ((comment != "") ? comment : act)

        if (rest ~ /^[[:space:]]*\.\.[[:space:]]*key/) {
            # The workspace loop:  for i = 1, 10 do  key = (i == 10) ? 0 : i
            # The comment above it describes the LOOP, not any one bind, so each
            # expansion is described by its own call with i resolved instead.
            for (i = 1; i <= 10; i++) {
                k = (i == 10) ? 0 : i
                a = act; gsub(/workspace = i/, "workspace = " i, a)
                # The desc above the loop describes the SHAPE of the bind, so
                # each expansion appends its own workspace number to it.
                print combo k "\t" (descline != "" ? descline " " i : a) "\t" a
            }
        } else {
            print combo "\t" desc "\t" act
        }
    }

    {
        raw = $0
        if (raw ~ /^[[:space:]]*--/) {
            t = raw
            sub(/^[[:space:]]*--[[:space:]]*/, "", t)
            # An explicit "desc:" line wins outright wherever one exists.
            if (t ~ /^desc:[[:space:]]*/) {
                sub(/^desc:[[:space:]]*/, "", t)
                descline = t
                next
            }
            # Otherwise keep the FIRST line of a comment run: these blocks open
            # with the one-line "what this is" and continue into the reasoning.
            # Rule-off separators and section banners are not descriptions.
            if (t != "" && t !~ /^[-=#*]+$/ && comment == "") comment = t
            next
        }
        if (raw ~ /hl\.bind\(/) { emit(raw); comment = ""; descline = ""; next }
        comment = ""; descline = ""     # a blank line ends the run too: a comment that far from
                         # a bind is describing something else
    }
    ' "$CONF"
}

ROWS="$(parse)"
FILE_N="$(printf '%s\n' "$ROWS" | grep -c . || true)"

# The count cross-check. Captured first, never piped straight into grep -c.
if command -v hyprctl >/dev/null; then
    BINDS="$(hyprctl binds 2>/dev/null || true)"
    LIVE_N="$(printf '%s' "$BINDS" | grep -c '^bind' || true)"
    if [ -n "$BINDS" ] && [ "${LIVE_N:-0}" -ne "$FILE_N" ]; then
        printf '!\tWARNING: compositor has %s binds, this config defines %s — see: hyprctl configerrors\t\n' \
            "$LIVE_N" "$FILE_N"
    fi
fi

printf '%s\n' "$ROWS"
