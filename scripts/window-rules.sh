#!/usr/bin/env bash
# window-rules.sh — the compositor's look: borders, gaps, rounding, opacity,
# blur, shadow and animation, as a preference store the settings menu drives.
#
#   window-rules.sh list
#   window-rules.sh get   <KEY>
#   window-rules.sh set   <KEY> <VALUE>
#   window-rules.sh reset <KEY> | --all
#
# ── Why a store at all, and why not just hyprctl ──────────────────────────
# `hyprctl eval 'hl.config{...}'` changes the running compositor and nothing
# else: the next `hyprctl reload` — a wallpaper change, a monitor being
# plugged in, ui-prefs.sh changing the font — re-parses hyprland.lua and throws
# every runtime change away. So a value has to live somewhere hyprland.lua
# READS, or it lasts until the next unrelated event and then silently reverts.
#
# That file is window.conf, and it is deliberately its own file rather than
# more keys in ui.conf. Same reasoning that separated ui.conf from
# hardware.env: different writer, different lifetime. ui.conf is watched by all
# four Quickshell shells through UiConfig.qml, and every write to it wakes four
# processes to re-read a font they do not care about — these keys are read by
# hyprland.lua alone.
#
# Same KEY="value" shape as both of those, parsed the same way by the same
# read_env_file() in hyprland.lua: by pattern, never sourced, so a stray line
# in it cannot execute anything.
#
# ── Both halves of a set, in this order ───────────────────────────────────
# A set WRITES the file and then applies the value live. The write is what
# survives; the eval is what makes it visible now, without the full-screen
# flicker of `hyprctl reload` and without dropping the rest of the session's
# runtime state. If the eval fails the file still holds the value, so the next
# reload brings it in — which is the right way round, since a value that
# applies but does not persist is the failure mode this file exists to prevent.
#
# ── Writes are atomic ─────────────────────────────────────────────────────
# Nothing watches this file today, but hyprland.lua reads it at parse time and
# a reload racing a half-written file would take the session down rather than
# merely look wrong. Temp file, then mv, exactly as ui-prefs.sh does.

set -euo pipefail

CONF="${XDG_CONFIG_HOME:-$HOME/.config}/scripts/window.conf"

die() { echo "window-rules: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# ── the table ─────────────────────────────────────────────────────────────
# One row per rule, and it is the ONLY place a rule is described. The settings
# menu renders whatever this prints, hyprland.lua reads whatever key this
# names, and `set` validates against the same bounds the menu shows — so
# adding a rule is adding a line here plus one lookup in hyprland.lua, and
# there is no second list to keep in step.
#
# Fields, tab-separated on output:
#   KEY  label  description  kind  hyprctl-option  unit  min  max  step  default
#
# `hyprctl-option` is what getoption is asked for, and it is the live truth:
# the menu shows what the compositor is ACTUALLY doing rather than what was
# last written here, so a value changed by any other means still reads back
# correctly. Two rows have no option and are reported from the store instead —
# ANIM_SPEED and WINDOW_MODE; see current().
#
# WINDOW_MODE is first because it is the only row here that changes what the
# desktop DOES rather than what it looks like, and because it is the one a
# reader is most likely to have come to this page for.
#
# It is the one `enum` row, and its kind field carries its own options:
# `enum:a|b|c`. Settings.qml draws that as a ‹ value › cycle row and `set`
# refuses anything not in the list, so the options are written down once.
# It replaced a `bool` WIN_TILING_MODE on 2026-10-29, when scrolling became a
# third mode; a window.conf that still holds only the old key is read through
# legacy_mode() and the old key is dropped on the first write.
RULES=$(cat <<'EOF'
WIN_WINDOW_MODE	Window mode	Floating, tiled side by side, or a scrolling strip of columns	enum:floating|tiling|scrolling						floating
WIN_BORDER_SIZE	Border thickness	Outline drawn around every window	int	general:border_size	px	0	12	1	2
WIN_ROUNDING	Corner rounding	Radius of every window corner	int	decoration:rounding	px	0	40	1	16
WIN_GAPS_IN	Inner gaps	Space between two tiled windows	css	general:gaps_in	px	0	60	1	3
WIN_GAPS_OUT	Outer gaps	Space between a window and the screen edge	css	general:gaps_out	px	0	100	1	5
WIN_ACTIVE_OPACITY	Active opacity	Opacity of the focused window	float	decoration:active_opacity		0.1	1	0.05	0.95
WIN_INACTIVE_OPACITY	Inactive opacity	Opacity of every unfocused window	float	decoration:inactive_opacity		0.1	1	0.05	0.85
WIN_BLUR_ENABLED	Blur	Blur whatever sits behind a transparent window	bool	decoration:blur:enabled					true
WIN_BLUR_SIZE	Blur size	Radius of one blur pass	int	decoration:blur:size	px	1	20	1	3
WIN_BLUR_PASSES	Blur passes	How many times the blur is applied — costs GPU	int	decoration:blur:passes		1	10	1	5
WIN_SHADOW_ENABLED	Shadow	Drop shadow under every window	bool	decoration:shadow:enabled					true
WIN_SHADOW_RANGE	Shadow size	How far the shadow reaches	int	decoration:shadow:range	px	0	50	1	5
WIN_ANIM_ENABLED	Animations	Every window and workspace animation at once	bool	animations:enabled					true
WIN_ANIM_SPEED	Animation speed	Multiplies every animation — higher is faster	float		×	0.2	5	0.1	1
EOF
)

row_for() {
    local k="$1"
    printf '%s\n' "$RULES" | awk -F'\t' -v k="$k" '$1 == k { print; found = 1 } END { exit !found }'
}

field() { printf '%s' "$1" | cut -d"$(printf '\t')" -f"$2"; }

# ── reading ───────────────────────────────────────────────────────────────
# From the file, for the two rules the compositor cannot be asked about.
stored() {
    [ -f "$CONF" ] || return 0
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\(.*\)\"[[:space:]]*$/\1/p" "$CONF" | tail -1
}

# The live value, which is the one worth showing. hyprctl answers with a typed
# field — int, float or bool — named after the type it holds, so the type in
# the table above is also the JSON key to read.
#
# ANIM_SPEED has no option of its own: it is a MULTIPLIER hyprland.lua applies
# to each animation leaf's own speed, and Hyprland only ever reports the
# products. Reading one leaf back and dividing would make the displayed value
# depend on which leaf was picked and drift as soon as a leaf's base speed
# changed, so this one is reported from the store, defaulting to 1.
#
# WINDOW_MODE has none either, for a harder reason: half of it is the enabled
# flag of a window RULE, not a config option, and HL.WindowRule is write-only
# from Lua. (The other half, general:layout, IS readable — but "dwindle" is
# both floating and tiling, so it cannot say which of the two is in force.)
# Measured on 0.56 — `set_enabled()` is the only method the object carries,
# `globalFloatRule.enabled` reads nil, and its metatable's __index is a C
# function with nothing enumerable behind it. So the store is the source of
# truth for this one, and the two things that can write it — this script and
# SUPER+SHIFT+L, which now comes through this script — are the only two that do.
# A hand-run `hyprctl eval 'globalFloatRule:set_enabled(...)'` would still
# drift the page from the compositor, and nothing here can detect that.
# One record of hyprctl's JSON, and the type to pull out of it.
extract_typed() {
    local raw="$1" kind="$2"
    case "$kind" in
        int)   printf '%s' "$raw" | sed -n 's/.*"int":[[:space:]]*\(-\?[0-9]*\).*/\1/p' ;;
        # "css": "3 3 3 3" — gaps carry one value per edge (top right bottom
        # left). This page offers ONE number, which Hyprland expands to all
        # four (measured: setting gaps_in = 8 reads back "8 8 8 8"). The LAST
        # is what to show, not the first: gaps_out's top is held at 0 so
        # windows meet the bar's edge (see hyprland.lua), and reading the
        # first would report the outer gap as 0 whatever it was set to.
        css)   printf '%s' "$raw" | sed -n 's/.*"css":[[:space:]]*"\([^"]*\)".*/\1/p' | awk '{ print $NF }' ;;
        float) printf '%s' "$raw" | sed -n 's/.*"float":[[:space:]]*\(-\?[0-9.]*\).*/\1/p' \
                 | awk '{ printf "%g", $1 }' ;;
        bool)  printf '%s' "$raw" | sed -n 's/.*"bool":[[:space:]]*\([a-z]*\).*/\1/p' ;;
    esac
}

current() {
    local key="$1" row kind opt raw
    row="$(row_for "$key")" || die "unknown rule: $key"
    kind="$(field "$row" 4)"
    opt="$(field "$row" 5)"

    if [ -z "$opt" ]; then
        raw="$(stored "$key")"
        [ -z "$raw" ] && [ "$key" = "WIN_WINDOW_MODE" ] && raw="$(legacy_mode)"
        [ -n "$raw" ] && { printf '%s' "$raw"; return; }
        field "$row" 10; return
    fi

    have hyprctl || { field "$row" 10; return; }
    raw="$(hyprctl getoption "$opt" -j 2>/dev/null)" || raw=""
    [ -n "$raw" ] || { field "$row" 10; return; }
    extract_typed "$raw" "$kind"
}

# The bool WIN_WINDOW_MODE replaced. A window.conf written before 2026-10-29
# says WIN_TILING_MODE="true" for a tiled desktop, and reading it here is what
# keeps that desktop tiled across the upgrade instead of quietly floating.
# Empty when the old key is absent too, so the table's default applies.
legacy_mode() {
    case "$(stored WIN_TILING_MODE)" in
        true)  printf 'tiling' ;;
        false) printf 'floating' ;;
    esac
}

# ── validation ────────────────────────────────────────────────────────────
# Refused rather than clamped. A box you typed 400 into and which quietly
# became 40 is worse than one that says no: the number on screen would not be
# the number you asked for, and nothing would tell you which.
# Complaints name the rule the way the MENU does — "Border thickness", not
# WIN_BORDER_SIZE. The caption lands under a list where that label is on screen
# a few rows up, and a key nobody chose is a worse thing to read there.
validate() {
    local key="$1" val="$2" row kind min max what
    row="$(row_for "$key")" || die "unknown rule: $key"
    kind="$(field "$row" 4)"; min="$(field "$row" 7)"; max="$(field "$row" 8)"
    what="$(field "$row" 2)"

    case "$kind" in
        bool)
            case "$val" in
                true|false) ;;
                *) die "$what takes true or false, not '$val'" ;;
            esac
            ;;
        enum:*)
            # Matched as a whole word of the list, so "tile" or "" is refused
            # rather than prefix-matching its way in.
            case "|${kind#enum:}|" in
                *"|$val|"*) [ -n "$val" ] || die "$what needs a value" ;;
                *) die "$what is one of ${kind#enum:}, not '$val'" ;;
            esac
            ;;
        int|css)
            printf '%s' "$val" | grep -qE '^-?[0-9]+$' || die "$what takes a whole number, not '$val'"
            awk -v v="$val" -v a="$min" -v b="$max" 'BEGIN{ exit !(v >= a && v <= b) }' \
                || die "$what must be between $min and $max"
            ;;
        float)
            printf '%s' "$val" | grep -qE '^-?[0-9]+(\.[0-9]+)?$' || die "$what takes a number, not '$val'"
            awk -v v="$val" -v a="$min" -v b="$max" 'BEGIN{ exit !(v >= a && v <= b) }' \
                || die "$what must be between $min and $max"
            ;;
    esac
}

# ── writing ───────────────────────────────────────────────────────────────
write_conf() {
    local key="$1" val="$2" tmp
    mkdir -p "$(dirname "$CONF")"
    tmp="$(mktemp "${CONF}.XXXXXX")"
    # Header rewritten every time rather than appended to, so the file cannot
    # accumulate a second one.
    {
        echo "# Written by scripts/window-rules.sh — the settings menu's Window rules page."
        echo "# Read by hyprland.lua at parse time. Delete a line to fall back to its default."
        [ -f "$CONF" ] && grep -vE "^[[:space:]]*(#|${key}[[:space:]]*=)" "$CONF" | grep -v '^[[:space:]]*$' || true
        [ -n "$val" ] && printf '%s="%s"\n' "$key" "$val"
    } > "$tmp"
    mv -f "$tmp" "$CONF"
}

# Applies to the RUNNING compositor. The option path in the table is
# "section:key" or "section:sub:key", which is exactly the nesting hl.config
# wants as tables — so the path is turned back into nested Lua rather than
# each rule carrying its own hand-written expression.
apply_live() {
    local opt="$1" val="$2" expr
    have hyprctl || return 0
    # `close` is an awk BUILT-IN and naming a variable that is a syntax error,
    # not a warning — the whole expression came out empty and every set looked
    # like it had worked while changing nothing.
    expr="$(printf '%s' "$opt" | awk -F: -v v="$val" '{
        pre = ""; post = "";
        for (i = 1; i < NF; i++) { pre = pre $i " = { "; post = post " }" }
        printf "hl.config({ %s%s = %s%s })", pre, $NF, v, post
    }')"
    [ -n "$expr" ] || return 1
    hyprctl eval "$expr" >/dev/null 2>&1 || return 1
}

# ── window mode ───────────────────────────────────────────────────────────
# Not a config option and so not apply_live()'s shape at all. Three modes, made
# of two switches:
#
#   floating   globalFloatRule ON,  layout dwindle
#   tiling     globalFloatRule OFF, layout dwindle
#   scrolling  globalFloatRule OFF, layout scrolling (Hyprland's built-in)
#
# globalFloatRule is the `class = ".*"` float rule hyprland.lua defines as a
# global for exactly this purpose. Floating keeps dwindle rather than leaving
# whatever the last mode set: a window SUPER+W drops out of floating has to
# tile SOMEWHERE, and dwindle is where it always went before scrolling existed.
#
# LAYOUT FIRST, then the windows. Converting each window to tiled inserts it
# into whatever layout is in force at that moment — measured in a nested
# 0.56.2, switching general.layout with windows already tiled re-lays them out
# (three kittys went from a dwindle split to a strip of columns at once), so
# either order ends up right, but this one never lays the screen out twice.
#
# TWO halves for the windows, and both are needed. Disabling the rule only
# decides what the NEXT window does; the ones already open keep whatever they
# were given when they opened, so each is converted by address. Toggling the
# rule alone looked like it had done nothing at all, because the screen in
# front of you is entirely made of windows that already exist.
#
# Tiling <-> scrolling touches no window's float state at all: both are tiled,
# so the layout switch is the whole change and the per-window walk below is a
# no-op `disable` on each.
#
# This body used to live in toggle-layout.sh, which SUPER+SHIFT+L runs. It is
# here now and that script calls this one, so the keybind and the settings
# switch cannot disagree about which mode the desktop is in — they are the same
# write to the same file.
apply_window_mode() {
    local mode="$1" layout action addrs addr
    have hyprctl || return 0

    case "$mode" in
        scrolling) layout="scrolling" ;;
        *)         layout="dwindle" ;;
    esac
    hyprctl eval "hl.config({ general = { layout = \"$layout\" } })" >/dev/null 2>&1 || return 1

    if [ "$mode" = "floating" ]; then
        hyprctl eval 'globalFloatRule:set_enabled(true)' >/dev/null 2>&1 || return 1
        action="enable"
    else
        hyprctl eval 'globalFloatRule:set_enabled(false)' >/dev/null 2>&1 || return 1
        action="disable"
    fi
    # enable/disable, NOT set/unset. Measured in a nested 0.56.2 on
    # 2026-10-29: "set" and "unset" are not values window.float knows, and an
    # unknown action falls through to TOGGLE with no error — `set` twice on one
    # window flipped it tiled, then floating again. enable/disable (and on/off)
    # are idempotent. This ran as set/unset from the start and looked right
    # only because every window usually starts in the other state; a window
    # SUPER+W had already moved got flipped the wrong way, and tiling ->
    # scrolling, where every window is already tiled, floated all of them.

    # Captured, not piped into the loop. `hyprctl | jq | while read` under
    # `set -o pipefail` takes the whole script down the moment either producer
    # has nothing to say — the fourth time this repo has been bitten by that.
    have jq || return 0
    addrs="$(hyprctl clients -j 2>/dev/null | jq -r '.[].address' 2>/dev/null)" || addrs=""
    while IFS= read -r addr; do
        [ -n "$addr" ] || continue
        # A Lua dispatcher expression, not the pre-0.55 positional
        # `dispatch settiled address:...`, which parses as nothing and no-ops.
        hyprctl dispatch "hl.dsp.window.float({ action = '$action', window = 'address:$addr' })" \
            >/dev/null 2>&1 || true
    done <<< "$addrs"
}

# Every leaf, because the multiplier is global. The base speeds are the ones
# hyprland.lua declares and they are repeated here — the one duplication in
# this file, and it is deliberate: the alternative is `hyprctl reload`, which
# re-parses the whole config and flickers the screen for what is one number.
# If a leaf's base speed changes in hyprland.lua, change it here too.
apply_anim_speed() {
    local m="$1"
    have hyprctl || return 0
    apply_anim_leaf windows            3 swirl  "popin 0%"        "$m"
    apply_anim_leaf windowsOut         3 linear "popin 0%"        "$m"
    apply_anim_leaf fade               2 linear ""                "$m"
    apply_anim_leaf workspaces         2 linear ""                "$m"
    apply_anim_leaf specialWorkspaceIn 6 swirl  "slidefadevert -50%" "$m"
    apply_anim_leaf specialWorkspaceOut 6 swirl "fade"            "$m"
}

apply_anim_leaf() {
    local leaf="$1" base="$2" curve="$3" style="$4" mult="$5" spd expr
    # Hyprland refuses a speed of 0 and the result is a dead animation rather
    # than an instant one, so the product is floored at a tenth.
    spd="$(awk -v b="$base" -v m="$mult" 'BEGIN{ s = b * m; if (s < 0.1) s = 0.1; printf "%g", s }')"
    expr="hl.animation({ leaf = \"$leaf\", enabled = true, speed = $spd, bezier = \"$curve\""
    [ -n "$style" ] && expr="$expr, style = \"$style\""
    expr="$expr })"
    hyprctl eval "$expr" >/dev/null 2>&1 || true
}

# ── commands ──────────────────────────────────────────────────────────────
# ONE hyprctl for the whole page, not one per rule. `--batch` takes
# semicolon-separated commands and `j/` asks for JSON per command, so the reply
# is one self-describing record per line — mapped back by the option NAME each
# record carries rather than by position, which would break the first time a
# command in the batch answered with nothing.
#
# Measured against the twelve separate calls this replaces: 5ms against 120ms.
# That is the whole cost of the page refresh after a step, and it is why
# holding + used to feel like it was catching up rather than keeping up.
cmd_list() {
    local row opt batch="" json=""
    while IFS= read -r row; do
        opt="$(field "$row" 5)"
        [ -n "$opt" ] || continue
        batch="${batch}${batch:+ ; }j/getoption $opt"
    done <<< "$RULES"

    if have hyprctl && [ -n "$batch" ]; then
        json="$(hyprctl --batch "$batch" 2>/dev/null)" || json=""
    fi

    # ONE awk, over both inputs. The first version of this was a bash loop
    # calling `cut` eight times per row to split the table — 13 rows, ~104
    # subprocesses, and it measured 500ms for a page the user is holding a key
    # against. The batched hyprctl it already used was 5ms of that. Forking is
    # the cost here, not the compositor.
    awk -F'\t' -v store="$(stored_all)" '
        # ── pass 1: one self-describing JSON record per line ──────────────
        NR == FNR {
            if (!match($0, /"option": "[^"]*"/)) next
            o = substr($0, RSTART + 11, RLENGTH - 12)
            if (match($0, /"int": *-?[0-9]+/))
                val[o] = substr($0, RSTART + 7, RLENGTH - 7) + 0
            else if (match($0, /"float": *-?[0-9.]+/))
                val[o] = sprintf("%g", substr($0, RSTART + 9, RLENGTH - 9) + 0)
            else if (match($0, /"css": "[^"]*/)) {
                # The LAST edge — see extract_typed for why not the first.
                nc = split(substr($0, RSTART + 8, RLENGTH - 8), cv, " ")
                val[o] = cv[nc]
            }
            else if (match($0, /"bool": *(true|false)/)) {
                # From the MATCHED SUBSTRING, not the line. Every record also
                # carries "set": true, so index($0, "true") was true for every
                # bool ever read — blur, shadow and animations all reported
                # enabled whatever they actually were, and the switches could
                # therefore only ever compute "turn it off".
                b = substr($0, RSTART, RLENGTH)
                val[o] = (index(b, "true") ? "true" : "false")
            }
            next
        }
        # ── the stored file, for the rule with no option of its own ───────
        FNR == 1 && NR != FNR {
            n = split(store, kv, "\n")
            for (i = 1; i <= n; i++)
                if (split(kv[i], p, "=") == 2) saved[p[1]] = p[2]
            # legacy_mode(), for the page: a file that predates the window
            # mode still says which of the old two it was in.
            if (!("WIN_WINDOW_MODE" in saved) && ("WIN_TILING_MODE" in saved))
                saved["WIN_WINDOW_MODE"] = (saved["WIN_TILING_MODE"] == "true") ? "tiling" : "floating"
        }
        # ── pass 2: the table ─────────────────────────────────────────────
        NF >= 4 {
            v = ($5 != "" && $5 in val) ? val[$5] \
              : ($1 in saved)           ? saved[$1] \
              :                           $10
            print $1 "\t" $2 "\t" $3 "\t" $4 "\t" v "\t" $6 "\t" $7 "\t" $8 "\t" $9
        }
    ' <(printf '%s\n' "$json") <(printf '%s\n' "$RULES")
}

# KEY=value per line, for the awk above. Only the rules with no hyprctl option
# of their own are ever looked up in it.
stored_all() {
    [ -f "$CONF" ] || return 0
    sed -n 's/^[[:space:]]*\([A-Z_][A-Z0-9_]*\)[[:space:]]*=[[:space:]]*"\(.*\)"[[:space:]]*$/\1=\2/p' "$CONF"
}

cmd_set() {
    local key="$1" val="$2" row opt
    row="$(row_for "$key")" || die "unknown rule: $key"
    validate "$key" "$val"
    opt="$(field "$row" 5)"

    # APPLY FIRST, then persist. Both still happen, and the order is purely
    # about how soon the screen changes: the write is a mktemp, a grep and an
    # mv, and doing it first put all of that between a keypress and the border
    # actually moving. The file is what survives, so it cannot be skipped — but
    # nothing is waiting on it.
    if [ "$key" = "WIN_WINDOW_MODE" ]; then
        apply_window_mode "$val" || echo "window-rules: saved, but the live apply failed" >&2
    elif [ -z "$opt" ]; then
        apply_anim_speed "$val"
    elif [ "$key" = "WIN_GAPS_OUT" ]; then
        # Three edges, not four: the bar's edge stays 0 so windows meet the
        # bar's strip, the same shape hyprland.lua gives it at parse time.
        apply_gaps "$val" || echo "window-rules: saved, but the live apply failed" >&2
    else
        apply_live "$opt" "$val" || echo "window-rules: saved, but the live apply failed" >&2
    fi

    write_conf "$key" "$val"
    # The bool this key replaced goes with the first write of the new one, so
    # the file cannot hold two answers to the same question.
    [ "$key" = "WIN_WINDOW_MODE" ] && write_conf WIN_TILING_MODE ""
    printf '%s\n' "$val"
}

# ── outer gaps follow the bar ─────────────────────────────────────────────
# gaps_out is 0 on the bar's edge and the outer-gap value on the other three,
# so a window's border starts on the bar's reserved strip and the gap under
# the islands is set by the bar's zone alone (hyprland.lua has the history).
# The bar's edge is a ui.conf key since 2026-10-31 (BAR_POSITION, Settings ->
# Shell -> Bar), so which edge is 0 is no longer always the top. hyprland.lua
# does the same at parse time; this is the live half.
#
#   apply_gaps <outer px> [top|left|right]
#
# The edge is an argument when the caller knows it: ui-prefs.sh calls this
# BEFORE its own write of ui.conf can be relied on (the settings menu moves
# the bar optimistically), so reading the file here would get the old edge.
bar_edge() {
    local ui="${XDG_CONFIG_HOME:-$HOME/.config}/scripts/ui.conf" v
    v="$(sed -n 's/^[[:space:]]*BAR_POSITION[[:space:]]*=[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$ui" 2>/dev/null | tail -n 1)"
    case "$v" in left|right) ;; *) v=top ;; esac
    # Always hide (BAR_AUTOHIDE) reserves no zone, so no edge is the bar's.
    grep -qE '^[[:space:]]*BAR_AUTOHIDE[[:space:]]*=[[:space:]]*"on"' "$ui" 2>/dev/null && v=none
    printf '%s' "$v"
}
apply_gaps() {
    local g="$1" edge="${2:-}" t r l
    [ -n "$edge" ] || edge="$(bar_edge)"
    t="$g"; r="$g"; l="$g"
    case "$edge" in
        left)  l=0 ;;
        right) r=0 ;;
        none)  ;;                     # an auto-hidden bar: the gap on all four
        *)     t=0 ;;
    esac
    have hyprctl || return 1
    hyprctl eval "hl.config({ general = { gaps_out = { top = $t, right = $r, bottom = $g, left = $l } } })" >/dev/null 2>&1
}

cmd_reset() {
    local key="$1" row was_mode
    # Read BEFORE the file is touched — after it, the store says "floating"
    # whatever the desktop is actually doing.
    was_mode="$(current WIN_WINDOW_MODE 2>/dev/null)" || was_mode="floating"

    if [ "$key" = "--all" ]; then
        rm -f "$CONF"
    else
        row="$(row_for "$key")" || die "unknown rule: $key"
        write_conf "$key" ""
        [ "$key" = "WIN_WINDOW_MODE" ] && write_conf WIN_TILING_MODE ""
    fi
    # A reset is the one path that DOES reload: the default it falls back to is
    # whatever hyprland.lua hardcodes, and this script does not know those —
    # re-parsing the config is what produces them.
    have hyprctl && hyprctl reload >/dev/null 2>&1 || true

    # The reload restores globalFloatRule and dwindle for the NEXT window,
    # since hyprland.lua re-reads a window.conf that no longer names the key.
    # It does nothing to the windows already open — a reload does not re-run
    # rules over them — so a reset out of tiling or scrolling would otherwise
    # leave a tiled screen under a page that says floating. Only on the way OUT
    # of a tiled mode: the default is floating, so resetting while already
    # floating has nothing to undo.
    if [ "$was_mode" != "floating" ] && { [ "$key" = "--all" ] || [ "$key" = "WIN_WINDOW_MODE" ]; }; then
        apply_window_mode floating || true
    fi
}

case "${1:-}" in
    list)  cmd_list ;;
    get)   [ $# -ge 2 ] || die "get needs a key"; current "$2" ;;
    set)   [ $# -ge 3 ] || die "set needs a key and a value"; cmd_set "$2" "$3" ;;
    reset) [ $# -ge 2 ] || die "reset needs a key or --all"; cmd_reset "$2" ;;
    # ui-prefs.sh, when the bar changes edge: the stored outer gap, re-applied
    # with the new edge at 0. Falls back to the table's default.
    apply-gaps)
        g="$(stored WIN_GAPS_OUT)"
        [ -n "$g" ] || g="$(field "$(row_for WIN_GAPS_OUT)" 10)"
        apply_gaps "$g" "${2:-}" ;;
    *)
        echo "usage: $(basename "$0") list" >&2
        echo "       $(basename "$0") get <KEY>" >&2
        echo "       $(basename "$0") set <KEY> <VALUE>" >&2
        echo "       $(basename "$0") reset <KEY>|--all" >&2
        exit 2
        ;;
esac
