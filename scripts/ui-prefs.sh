#!/usr/bin/env bash
# ui-prefs.sh — the desktop's user-preference store, and everything that has to
# be told when one of them changes.
#
#   ui-prefs.sh get  <KEY>
#   ui-prefs.sh set  <KEY> <VALUE> [DETAIL]
#   ui-prefs.sh list fonts|icons|themes|browsers|terminals|editors
#
# KEYS: UI_FONT  ICON_THEME  GTK_THEME  DEFAULT_BROWSER  DEFAULT_TERMINAL
#       DEFAULT_EDITOR
#
# ── Why a plain file, and why this one ────────────────────────────────────
# Six different things need to agree on these values: the four Quickshell
# shells (taskbar, macshell, finder, lockscreen), hyprland.lua, and the shell
# scripts themselves. gsettings can't serve hyprland.lua — that config is
# parsed by Lua with no D-Bus and no subprocess budget — so the store has to be
# a file that everything can read cheaply.
#
# Same KEY="value" shape as hardware.env, and parsed the same way everywhere:
# with sed, never `source`d, so a stray line in it can never execute anything.
# The two files are deliberately separate, though. hardware.env is DETECTED
# (install.sh --only hardware rewrites it wholesale and would blow these away);
# ui.conf is CHOSEN, and nothing regenerates it.
#
# Every consumer falls back to a working default when the file or a key is
# missing — a fresh machine with no ui.conf must come up looking exactly like
# this repo's committed defaults, never blank.
#
# ── Writes are atomic ─────────────────────────────────────────────────────
# All four shells hold an inotify watch on the containing directory, so a
# half-written file WILL be read. Every write goes to a temp file and is then
# `mv`d into place. That is also why the watches are on the directory and not
# on ui.conf itself: `mv` replaces the inode, and a watch on the old inode
# stops firing after the first change.

set -euo pipefail

CONF="${XDG_CONFIG_HOME:-$HOME/.config}/scripts/ui.conf"

die() { echo "ui-prefs: $*" >&2; exit 1; }

VALID_KEYS="UI_FONT ICON_THEME GTK_THEME DEFAULT_BROWSER DEFAULT_TERMINAL DEFAULT_EDITOR DEFAULT_BROWSER_DESKTOP"

# ── store ────────────────────────────────────────────────────────────────

_seed() {
    mkdir -p "$(dirname "$CONF")"
    [ -f "$CONF" ] && return 0
    cat >"$CONF" <<'EOF'
# Written by ui-prefs.sh (finder's settings menu). Safe to edit by hand.
#
# Read by the four Quickshell shells, hyprland.lua and the scripts in this
# directory. Every reader has a fallback, so deleting a line here is the same
# as never having set it — it does not break anything.
EOF
}

pref_get() {
    [ -f "$CONF" ] || return 0
    sed -n "s/^$1=\"\(.*\)\"\$/\1/p" "$CONF" | head -1
}

# awk rather than sed: a font or theme name is arbitrary user text and could
# contain whatever character we picked as a sed delimiter. awk takes the value
# as a -v variable, so nothing in it is ever interpreted.
pref_set() {
    local key="$1" val="$2" tmp
    _seed
    tmp="$CONF.tmp.$$"
    awk -v k="$key" -v v="$val" '
        $0 ~ "^" k "=" { print k "=\"" v "\""; done = 1; next }
        { print }
        END { if (!done) print k "=\"" v "\"" }
    ' "$CONF" >"$tmp"
    mv "$tmp" "$CONF"
}

# ini_set <file> <key> <value> — for GTK's settings.ini, which is a real INI
# file rather than the KEY="value" shape used above.
ini_set() {
    local f="$1" k="$2" v="$3"
    mkdir -p "$(dirname "$f")"
    [ -f "$f" ] || printf '[Settings]\n' >"$f"
    if [ "$(grep -c "^$k=" "$f" || true)" -gt 0 ]; then
        local tmp="$f.tmp.$$"
        awk -v k="$k" -v v="$v" '
            $0 ~ "^" k "=" { print k "=" v; next }
            { print }
        ' "$f" >"$tmp"
        mv "$tmp" "$f"
    else
        [ "$(grep -c '^\[Settings\]' "$f" || true)" -gt 0 ] || printf '[Settings]\n' >>"$f"
        printf '%s=%s\n' "$k" "$v" >>"$f"
    fi
}

notify() {
    command -v notify-send >/dev/null || return 0
    notify-send -a "Settings" "$1" "${2:-}" 2>/dev/null || true
}

# ── what is in effect right now ──────────────────────────────────────────
# Not the same question as `get`. A key that has never been set has no line in
# ui.conf, but the desktop is still running SOME font and SOME icon theme — the
# one it was built with, or one set by hand years ago. Marking a list with
# `get` alone would show nothing as current until the user picked something,
# which reads as "none of these is selected" rather than "this is the default".
#
# So: the stored preference wins, and where there is none the value is read back
# out of whatever actually holds it.
effective() {
    local key="$1" v kconf d exec_line
    v="$(pref_get "$key")"
    if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
    case "$key" in
        UI_FONT)
            kconf="${XDG_CONFIG_HOME:-$HOME/.config}/kitty/kitty.conf"
            [ -f "$kconf" ] && v="$(sed -n 's/^font_family[[:space:]]\+//p' "$kconf" | head -1)"
            # kitty ships "monospace", which is a fontconfig alias rather than a
            # family and would match nothing in the list.
            case "${v:-}" in ''|monospace) v="JetBrainsMono Nerd Font Propo" ;; esac
            printf '%s' "$v" ;;
        ICON_THEME)
            gsettings get org.gnome.desktop.interface icon-theme 2>/dev/null | tr -d "'" || true ;;
        GTK_THEME)
            gsettings get org.gnome.desktop.interface gtk-theme 2>/dev/null | tr -d "'" || true ;;
        DEFAULT_TERMINAL) printf 'kitty' ;;
        DEFAULT_EDITOR)   printf 'vim' ;;
        DEFAULT_BROWSER)
            # xdg-settings answers with a .desktop name; the list is keyed by
            # command, so resolve one to the other or the current browser never
            # matches a row.
            d="$(xdg-settings get default-web-browser 2>/dev/null || true)"
            [ -n "$d" ] || return 0
            for f in "$HOME/.local/share/applications/$d" "/usr/share/applications/$d"; do
                [ -f "$f" ] || continue
                exec_line="$(sed -n 's/^Exec=//p' "$f" | head -1)"
                printf '%s' "$(printf '%s' "$exec_line" | sed 's/ *%[a-zA-Z]//g')"
                return 0
            done ;;
    esac
    return 0
}

# mark <effective-value> — appends the fourth column.
mark() {
    awk -F'\t' -v cur="$1" 'BEGIN { OFS = "\t" } { print $1, $2, $3, ($1 == cur ? "current" : "") }'
}

# ── listings ─────────────────────────────────────────────────────────────
# Every listing prints  value <TAB> label <TAB> detail <TAB> current  so finder
# can render a title, a subtitle and a "current" marker without knowing what
# kind of list it asked for. `detail` and `current` are allowed to be empty; the
# tabs are not.

list_fonts() {
    # `fc-list : family` prints one comma-separated alias set per font FILE:
    # "JetBrainsMono Nerd Font Propo,JetBrainsMono NF Propo". Keeping only the
    # part before the first comma gives the family's primary name and drops the
    # abbreviation/localised aliases that would otherwise triple the list.
    fc-list : family 2>/dev/null \
        | sed 's/,.*//; s/^ *//; s/ *$//' \
        | grep -v '^$' \
        | sort -u \
        | awk '{ print $0 "\t" $0 "\t" }'
    # A listing that matched nothing is an empty list, not a failure — and the
    # probe loops below end on whichever candidate happens to be last, which is
    # usually one that is NOT installed. Without this every `list` subcommand
    # exits 1 and finder reads that as "the command broke".
    return 0
}

list_icons() {
    # A directory under an icon path is an ICON theme only if its index.theme
    # has a Directories= key. Cursor themes (all fourteen Bibata variants here)
    # also ship an index.theme, but with no Directories — without this filter
    # they make up two thirds of the list and none of them can be selected
    # usefully.
    local d t name
    for d in /usr/share/icons "$HOME/.local/share/icons" "$HOME/.icons"; do
        [ -d "$d" ] || continue
        for t in "$d"/*/; do
            [ -f "$t/index.theme" ] || continue
            [ "$(grep -c '^Directories' "$t/index.theme" || true)" -gt 0 ] || continue
            name="$(basename "$t")"
            printf '%s\t%s\t%s\n' "$name" "$name" "$d"
        done
    done | sort -u -t"$(printf '\t')" -k1,1
    return 0
}

list_themes() {
    local d t name
    {
        # Adwaita and Adwaita-dark are compiled into GTK itself and have no
        # directory under /usr/share/themes, so a directory scan alone would
        # omit the theme this machine is actually running.
        printf 'Adwaita\tAdwaita\tbuilt-in\n'
        printf 'Adwaita-dark\tAdwaita-dark\tbuilt-in\n'
        for d in /usr/share/themes "$HOME/.themes" "$HOME/.local/share/themes"; do
            [ -d "$d" ] || continue
            for t in "$d"/*/; do
                # A GTK theme is one that actually carries a gtk-3.0 or gtk-4.0
                # subdir. /usr/share/themes also holds Emacs and Default, which
                # are Metacity/Emacs leftovers and do nothing for GTK apps.
                { [ -d "$t/gtk-3.0" ] || [ -d "$t/gtk-4.0" ]; } || continue
                name="$(basename "$t")"
                printf '%s\t%s\t%s\n' "$name" "$name" "$d"
            done
        done
    } | sort -u -t"$(printf '\t')" -k1,1
    return 0
}

list_browsers() {
    # Anything that registers itself as an http(s) handler. Reading the desktop
    # files directly rather than asking xdg-settings, which only reports the
    # ONE current default and cannot enumerate the alternatives.
    local f name exec_line cmd
    for f in /usr/share/applications/*.desktop "$HOME"/.local/share/applications/*.desktop; do
        [ -f "$f" ] || continue
        [ "$(grep -c '^MimeType=.*x-scheme-handler/http' "$f" || true)" -gt 0 ] || continue
        # --app= entries are the webapps installed by webapp-install.sh; they
        # inherit chromium's MimeType line but are not browsers.
        [ "$(grep -c '^Exec=.*--app=' "$f" || true)" -eq 0 ] || continue
        name="$(sed -n 's/^Name=//p' "$f" | head -1)"
        exec_line="$(sed -n 's/^Exec=//p' "$f" | head -1)"
        # Strip .desktop field codes (%U, %F, …) — they are placeholders the
        # launcher substitutes, and passing them through literally would make
        # hyprland.lua's exec bind open a file named "%U".
        cmd="$(printf '%s' "$exec_line" | sed 's/ *%[a-zA-Z]//g')"
        [ -n "$name" ] && [ -n "$cmd" ] || continue
        printf '%s\t%s\t%s\n' "$cmd" "$name" "$(basename "$f")"
    done | sort -u -t"$(printf '\t')" -k2,2
    return 0
}

# Terminals and editors have no equivalent of the http-handler marker, so these
# are probe lists: a fixed set of candidates, filtered down to what is actually
# installed. A candidate that is not installed is simply not offered.
list_terminals() {
    local c
    for c in kitty alacritty foot wezterm ghostty gnome-terminal konsole xterm; do
        command -v "$c" >/dev/null 2>&1 && printf '%s\t%s\t%s\n' "$c" "$c" ""
    done
    return 0
}

list_editors() {
    local c
    for c in nvim vim helix hx nano micro emacs code codium zed gedit kate; do
        command -v "$c" >/dev/null 2>&1 && printf '%s\t%s\t%s\n' "$c" "$c" ""
    done
    return 0
}

# ── applying ─────────────────────────────────────────────────────────────

apply_font() {
    local val="$1" kconf cur size
    kconf="${XDG_CONFIG_HOME:-$HOME/.config}/kitty/kitty.conf"
    if [ -f "$kconf" ]; then
        if [ "$(grep -c '^font_family' "$kconf" || true)" -gt 0 ]; then
            local tmp="$kconf.tmp.$$"
            awk -v v="$val" '/^font_family/ { print "font_family      " v; next } { print }' \
                "$kconf" >"$tmp"
            mv "$tmp" "$kconf"
        else
            printf 'font_family      %s\n' "$val" >>"$kconf"
        fi
        # kitty re-reads its config on SIGUSR1, so open terminals pick the font
        # up without being restarted. -x so this cannot match `kitty --title …`
        # in some other process's command line.
        pkill -USR1 -x kitty 2>/dev/null || true
    fi

    # Keep whatever point size is already configured; only the family changes.
    # gsettings' font-name is "Family Size" as one string, so the size has to be
    # split off and put back rather than overwritten with a guess.
    if command -v gsettings >/dev/null; then
        cur="$(gsettings get org.gnome.desktop.interface font-name 2>/dev/null | tr -d "'" || true)"
        size="${cur##* }"
        case "$size" in ''|*[!0-9]*) size=11 ;; esac
        gsettings set org.gnome.desktop.interface font-name "$val $size" 2>/dev/null || true
    fi
    # The four Quickshell shells need no push: they watch this directory and
    # repaint when ui.conf lands.
}

apply_icon_theme() {
    local val="$1" d
    command -v gsettings >/dev/null &&
        gsettings set org.gnome.desktop.interface icon-theme "$val" 2>/dev/null || true
    for d in gtk-3.0 gtk-4.0; do
        ini_set "${XDG_CONFIG_HOME:-$HOME/.config}/$d/settings.ini" gtk-icon-theme-name "$val"
    done
}

apply_gtk_theme() {
    local val="$1" d scheme
    command -v gsettings >/dev/null &&
        gsettings set org.gnome.desktop.interface gtk-theme "$val" 2>/dev/null || true
    for d in gtk-3.0 gtk-4.0; do
        ini_set "${XDG_CONFIG_HOME:-$HOME/.config}/$d/settings.ini" gtk-theme-name "$val"
    done
    # libadwaita apps ignore gtk-theme entirely and follow color-scheme instead,
    # so a dark theme that does not also set this leaves half the GTK apps on
    # the desktop light. Inferred from the name because there is no other signal
    # a theme directory carries.
    case "$val" in
        *dark*|*Dark*|*mocha*|*macchiato*|*frappe*) scheme="prefer-dark" ;;
        *) scheme="default" ;;
    esac
    command -v gsettings >/dev/null &&
        gsettings set org.gnome.desktop.interface color-scheme "$scheme" 2>/dev/null || true
}

# hyprland.lua reads DEFAULT_TERMINAL/EDITOR/BROWSER at CONFIG-PARSE time, so a
# new value does nothing to SUPER+Q or $TERMINAL until the config is re-parsed.
reload_hyprland() {
    command -v hyprctl >/dev/null || return 0
    hyprctl reload >/dev/null 2>&1 || true
}

# ── dispatch ─────────────────────────────────────────────────────────────

cmd="${1:-}"
case "$cmd" in
    get)
        [ $# -ge 2 ] || die "usage: ui-prefs.sh get <KEY>"
        pref_get "$2"
        ;;

    set)
        [ $# -ge 3 ] || die "usage: ui-prefs.sh set <KEY> <VALUE> [DETAIL]"
        key="$2"; val="$3"; detail="${4:-}"
        case " $VALID_KEYS " in *" $key "*) ;; *) die "unknown key: $key" ;; esac
        pref_set "$key" "$val"
        case "$key" in
            UI_FONT)          apply_font "$val";       notify "Font" "$val" ;;
            ICON_THEME)       apply_icon_theme "$val"; notify "Icon theme" "$val" ;;
            GTK_THEME)        apply_gtk_theme "$val";  notify "Theme" "$val" ;;
            DEFAULT_TERMINAL) reload_hyprland;         notify "Default terminal" "$val" ;;
            DEFAULT_EDITOR)   reload_hyprland;         notify "Default editor" "$val" ;;
            DEFAULT_BROWSER)
                # DETAIL is the .desktop file name. xdg-settings is what every
                # OTHER app on the system consults when it opens a link, so
                # recording the command in ui.conf alone would leave the two
                # disagreeing — finder would search in one browser and a click
                # in a chat app would open another.
                if [ -n "$detail" ] && command -v xdg-settings >/dev/null; then
                    pref_set DEFAULT_BROWSER_DESKTOP "$detail"
                    xdg-settings set default-web-browser "$detail" 2>/dev/null || true
                fi
                reload_hyprland
                notify "Default browser" "$val"
                ;;
        esac
        ;;

    list)
        case "${2:-}" in
            fonts)     list_fonts     | mark "$(effective UI_FONT)" ;;
            icons)     list_icons     | mark "$(effective ICON_THEME)" ;;
            themes)    list_themes    | mark "$(effective GTK_THEME)" ;;
            browsers)  list_browsers  | mark "$(effective DEFAULT_BROWSER)" ;;
            terminals) list_terminals | mark "$(effective DEFAULT_TERMINAL)" ;;
            editors)   list_editors   | mark "$(effective DEFAULT_EDITOR)" ;;
            *) die "usage: ui-prefs.sh list fonts|icons|themes|browsers|terminals|editors" ;;
        esac
        ;;

    *)
        echo "usage: $(basename "$0") get <KEY>" >&2
        echo "       $(basename "$0") set <KEY> <VALUE> [DETAIL]" >&2
        echo "       $(basename "$0") list fonts|icons|themes|browsers|terminals|editors" >&2
        exit 2
        ;;
esac
