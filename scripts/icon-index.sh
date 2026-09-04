#!/usr/bin/env bash
# icon-index.sh — one application-icon file path per line, in preference order.
#
# finder's AppIndex.qml and macshell's DesktopEntryCache.qml build their
# name -> path map from this, FIRST MATCH WINNING, so order is the whole
# contract: the chosen theme first, then what it inherits, then Papirus as the
# backstop, then the flatpak exports.
#
#   icon-index.sh [theme]     theme defaults to ICON_THEME from ui.conf
#
# ── Why this is a script and not a find inside the QML ────────────────────
# It started as an inline `find /usr/share/icons/$THEME/$sz/apps` over a
# hardcoded size list, and that was wrong twice over:
#
#   * Papirus's size directories are SYMLINKS (64x64 -> ../64x64 and friends),
#     and find does not follow symlinks without -L.
#   * Adwaita has no <size>/apps directories at all. Its layout is 16x16/,
#     scalable/ and symbolic/, and its index.theme lists 16x16/apps among its
#     Directories even though that directory does not exist on disk.
#
# So a hardcoded layout found NOTHING for Adwaita, every lookup fell through to
# the Papirus backstop, and picking a theme looked like it did nothing to the
# shells while GTK apps visibly changed. Measured 2026-09-05.
#
# Locating the `apps` directories instead of assuming where they are makes the
# index work for any theme layout, and having it here means it can be run and
# counted from a terminal — which is how the "does this theme even ship
# application icons?" question below gets answered.

set -uo pipefail

THEME="${1:-}"
if [ -z "$THEME" ]; then
    CONF="${XDG_CONFIG_HOME:-$HOME/.config}/scripts/ui.conf"
    THEME="$(sed -n 's/^ICON_THEME="\(.*\)"$/\1/p' "$CONF" 2>/dev/null | head -1)"
fi
THEME="${THEME:-Papirus-Dark}"

ROOTS=("/usr/share/icons" "$HOME/.local/share/icons" "$HOME/.icons")

# index.theme's Inherits= — a theme is allowed to say what it falls back to, and
# honouring it is why e.g. a Papirus variant still resolves icons that only the
# base Papirus ships.
inherits_of() {
    local t="$1" r
    for r in "${ROOTS[@]}"; do
        [ -f "$r/$t/index.theme" ] || continue
        sed -n 's/^Inherits=//p' "$r/$t/index.theme" | head -1 | tr ',' '\n' \
            | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$'
        return
    done
}

# Every `apps` directory a theme actually has, largest-first.
#
# -L because of the Papirus symlinks above. The sort key is the leading number
# of the parent directory, descending, so a 128x128 icon is preferred over a
# 24x24 one; `scalable` has no number, sorts as 0, and is appended last —
# deliberately, since an SVG that some themes ship alongside sized PNGs should
# not out-rank a correctly sized raster.
apps_dirs_of() {
    local t="$1" r d
    for r in "${ROOTS[@]}"; do
        [ -d "$r/$t" ] || continue
        find -L "$r/$t" -mindepth 1 -maxdepth 2 -type d -name apps 2>/dev/null
    done | while read -r d; do
        local parent size
        parent="$(basename "$(dirname "$d")")"
        size="${parent%%x*}"
        case "$size" in ''|*[!0-9]*) size=0 ;; esac
        # Skip the tiny variants. The shells draw these at 32-64px, so a 16x16
        # copy of an icon that also exists at 128 is dead weight — and Papirus
        # ships every icon at seven sizes, which is what made an unfiltered
        # scan take 1.2s at every shell startup. `scalable` (size 0) is kept.
        if [ "$size" -ne 0 ] && [ "$size" -lt 32 ]; then continue; fi
        printf '%s\t%s\n' "$size" "$d"
    done | sort -rn -k1,1 | cut -f2-
}

emit_theme() {
    local t="$1" d
    while read -r d; do
        [ -n "$d" ] || continue
        find -L "$d" -maxdepth 1 \( -name '*.svg' -o -name '*.png' \) 2>/dev/null
    done < <(apps_dirs_of "$t")
}

# ── the chain ─────────────────────────────────────────────────────────────
SEEN=" "
emit_chain() {
    local t="$1" p
    case "$SEEN" in *" $t "*) return ;; esac
    SEEN="$SEEN$t "
    emit_theme "$t"
    while read -r p; do
        [ -n "$p" ] && emit_chain "$p"
    done < <(inherits_of "$t")
}

# Deduplicated by icon NAME, keeping the first — which is what makes the
# preference order above mean anything, and keeps this from handing the shells
# a quarter of a million lines to parse. Measured before dedup: 234,521 paths
# for Papirus-Dark, because every size directory of an 8,000-icon theme is in
# the chain. After: one line per distinct icon name.
{
emit_chain "$THEME"

# Papirus as the backstop no matter what the chosen theme inherits. Adwaita
# ships no application icons at all, and a dock of blank tiles is worse than a
# dock whose icons did not change.
emit_chain "Papirus-Dark"
emit_chain "Papirus"

# Flatpak apps ship their own icons in the hicolor theme under the export dirs;
# no icon theme carries them.
for sz in 128x128 64x64 48x48 32x32 24x24 scalable; do
    find -L "/var/lib/flatpak/exports/share/icons/hicolor/$sz/apps" \
            "$HOME/.local/share/flatpak/exports/share/icons/hicolor/$sz/apps" \
            -maxdepth 1 \( -name '*.svg' -o -name '*.png' \) 2>/dev/null
done
} | awk '{ n = $0; sub(/.*\//, "", n); sub(/\.(svg|png)$/, "", n); if (!(n in seen)) { seen[n]; print } }'

exit 0
