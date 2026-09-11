#!/usr/bin/env bash
# keybinds.sh — reassigning a keybind, for the settings menu's Keybindings page.
#
#   keybinds.sh set   <declared combo> <new combo>
#   keybinds.sh reset <declared combo> | --all
#
# ── What a reassignment actually is ───────────────────────────────────────
# A line in ~/.config/scripts/keybinds.conf, keyed by the combo hyprland.lua
# DECLARES, holding the combo to use instead:
#
#     KB_SUPER_Q="SUPER + T"
#
# hyprland.lua wraps hl.bind and substitutes at parse time; list-keybinds.sh
# applies the same table so the page shows what is really in force. All three
# derive the key the same way — upper-cased, every run of non-alphanumeric
# collapsed to one underscore, prefixed KB_ — and that agreement is the whole
# interface between them.
#
# The alternative was editing the hl.bind line in hyprland.lua directly, and it
# was rejected deliberately. That file is the one thing here that cannot take a
# bad edit: a config that fails to parse drops every bind after the failure and
# leaves Hyprland in emergency mode with three, which is a session you cannot
# use to repair it. A key=value file read at parse time has no such failure —
# a malformed line simply does not match.
#
# ── Why a reload and not an eval ──────────────────────────────────────────
# Window rules can be pushed into the running compositor with
# `hyprctl eval 'hl.config{...}'`. Binds cannot: there is no unbind for the old
# combo that does not need the dispatcher it was bound to, and re-registering
# one at runtime would leave the old one live as well. `hyprctl reload`
# re-parses the config, which is exactly one round of "everything the file says,
# including keybinds.conf", and it is the only way to make a reassignment total.

set -euo pipefail

CONF="${XDG_CONFIG_HOME:-$HOME/.config}/scripts/keybinds.conf"
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "keybinds: $*" >&2; exit 1; }

kb_key() {
    printf 'KB_%s' "$(printf '%s' "$1" \
        | tr '[:lower:]' '[:upper:]' \
        | sed 's/[^A-Z0-9]\{1,\}/_/g; s/^_*//; s/_*$//')"
}

# Every bind as "declared<TAB>in-force<TAB>description", straight from the
# listing the page itself is built from — so "is this combo taken" is answered
# by the same source that drew the row, and the two can never disagree.
listing() { "$here/list-keybinds.sh" 2>/dev/null | awk -F'\t' '$1 != "!"'; }

# ── validation ────────────────────────────────────────────────────────────
# Deliberately permissive about the KEY and strict about the SHAPE. Hyprland
# accepts key names this script has no business enumerating — every XKB keysym,
# mouse:NNN, mouse_up, and so on — so anything that looks structurally like a
# combo is allowed through and Hyprland is left to judge the key itself. What is
# rejected is what would break the config file rather than merely fail to bind.
valid_combo() {
    local c="$1"
    [ -n "$c" ] || return 1
    # No quote or backslash: the value is written into a "quoted" line, and one
    # of those in it would end the string early and corrupt the file.
    case "$c" in *'"'*|*'\'*) return 1 ;; esac
    printf '%s' "$c" | grep -qE '^[A-Za-z0-9_:+ ]+$' || return 1
    # Must end in something that is not a bare modifier — "SUPER + " or "SUPER"
    # alone is not a bind, and Hyprland would take it as a key named SUPER.
    local last; last="$(printf '%s' "$c" | sed 's/.*+ *//; s/ *$//')"
    [ -n "$last" ] || return 1
    local LAST; LAST="$(printf '%s' "$last" | tr '[:lower:]' '[:upper:]')"
    case "$LAST" in
        SUPER|ALT|CTRL|CONTROL|SHIFT) return 1 ;;
    esac

    # An ordinary key needs a modifier. Binding a bare Q means the letter stops
    # being typeable everywhere, and it is the kind of mistake you notice later
    # in another window, wondering why a key does nothing — the settings menu
    # should not be able to make it. It is also a backstop: if a modifier is
    # ever dropped between the capture box and here, the result is a refusal
    # rather than a bind that quietly eats a letter.
    #
    # FUNCTION and media keys are the exception, and they are why this is not
    # simply "must contain a +": they carry no character, nothing is lost by
    # claiming one, and this config already binds F1 to F12 and Print bare.
    case "$c" in *+*) return 0 ;; esac
    case "$LAST" in
        F[1-9]|F1[0-9]|F2[0-4]|PRINT|PAUSE|XF86*) return 0 ;;
    esac
    return 1
}

stored() {
    [ -f "$CONF" ] || return 0
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\(.*\)\"[[:space:]]*$/\1/p" "$CONF" | tail -1
}

write_conf() {
    local key="$1" val="$2" tmp
    mkdir -p "$(dirname "$CONF")"
    tmp="$(mktemp "${CONF}.XXXXXX")"
    {
        echo "# Written by scripts/keybinds.sh — the settings menu's Keybindings page."
        echo "# KB_<declared combo>=\"combo to use instead\". Delete a line to restore it."
        [ -f "$CONF" ] && grep -vE "^[[:space:]]*(#|${key}[[:space:]]*=)" "$CONF" | grep -v '^[[:space:]]*$' || true
        [ -n "$val" ] && printf '%s="%s"\n' "$key" "$val"
    } > "$tmp"
    mv -f "$tmp" "$CONF"
}

reload() { command -v hyprctl >/dev/null 2>&1 && hyprctl reload >/dev/null 2>&1 || true; }

# A combo already in use is TAKEN, not refused. The bind that had it is left
# with nothing — "@unbound", which hyprland.lua reads as "do not register this
# one at all" — and the displacement is reported so the page can say what just
# happened. Refusing was the first behaviour and it is the wrong one: the person
# choosing the key knows what they want it for, and being told "no" leaves them
# to go and free the key by hand before trying again.
#
# What is NOT silent about it is the report. Losing a keybind without being told
# is the failure worth designing against here, so the displaced bind is named on
# stderr with a `warn:` prefix — the page styles that differently from a refusal
# and keeps it up until it is acknowledged.
cmd_set() {
    local decl="$1" want="$2" rows holder_decl holder_desc mine

    valid_combo "$want" || die "'$want' is not a usable combo"

    rows="$(listing)"
    printf '%s\n' "$rows" | awk -F'\t' -v d="$decl" 'BEGIN{f=1} $1 == d {f=0} END{exit f}' \
        || die "no bind declared as '$decl'"

    mine="$(printf '%s\n' "$rows" | awk -F'\t' -v d="$decl" '$1 == d { print $3; exit }')"

    # Whoever holds it now, compared against the combo IN FORCE rather than the
    # declared one, because that is what would actually be pressed — and never
    # this bind itself, since re-setting one to what it already has displaces
    # nothing.
    holder_decl="$(printf '%s\n' "$rows" | awk -F'\t' -v d="$decl" -v w="$want" \
        '$1 != d && $2 != "" && $2 == w { print $1; exit }')"
    holder_desc="$(printf '%s\n' "$rows" | awk -F'\t' -v d="$decl" -v w="$want" \
        '$1 != d && $2 != "" && $2 == w { print $3; exit }')"

    # The displaced bind FIRST. If only one of the two writes can land, the one
    # to keep is the one that frees the key — two binds on one combo is a
    # conflict the compositor resolves by whichever it parsed last, which is not
    # a thing this should ever create.
    [ -n "$holder_decl" ] && write_conf "$(kb_key "$holder_decl")" "@unbound"
    write_conf "$(kb_key "$decl")" "$want"
    reload

    if [ -n "$holder_decl" ]; then
        printf 'warn: %s reassigned from %s to %s — rebind %s\n' \
            "$want" "$holder_desc" "$mine" "$holder_desc" >&2
    fi
    printf '%s\n' "$want"
}

cmd_reset() {
    if [ "$1" = "--all" ]; then rm -f "$CONF"
    else write_conf "$(kb_key "$1")" ""
    fi
    reload
}

case "${1:-}" in
    set)   [ $# -ge 3 ] || die "set needs a declared combo and a new one"; cmd_set "$2" "$3" ;;
    reset) [ $# -ge 2 ] || die "reset needs a combo or --all"; cmd_reset "$2" ;;
    key)   [ $# -ge 2 ] || die "key needs a combo"; kb_key "$2" ;;
    *)
        echo "usage: $(basename "$0") set <declared combo> <new combo>" >&2
        echo "       $(basename "$0") reset <declared combo>|--all" >&2
        exit 2
        ;;
esac
