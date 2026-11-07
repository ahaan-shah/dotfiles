#!/usr/bin/env bash
# ui-prefs.sh — the desktop's user-preference store, and everything that has to
# be told when one of them changes.
#
#   ui-prefs.sh get  <KEY>
#   ui-prefs.sh set  <KEY> <VALUE> [DETAIL]
#   ui-prefs.sh list fonts|icons|themes|palettes|browsers|terminals|editors|pdf
#
# KEYS: UI_FONT  ICON_THEME  GTK_THEME  PALETTE  DEFAULT_BROWSER
#       DEFAULT_TERMINAL  DEFAULT_EDITOR  DEFAULT_PDF
#       DOCK_AUTOHIDE (overlap|always)  DOCK_POSITION (bottom|left|right)
#       SWITCHER_SPECIAL (on|off|workspace) — Alt+Tab lists all windows,
#                        all but minimized, or only the focused workspace's
#       BAR_POSITION     (top|left|right) — Settings -> Shell -> Bar
#       BAR_HIDDEN       (none | comma list of module ids) — the bar's
#                        Modules page; ids are the ones Bar.qml's modOn() reads
#       BAR_STYLE        (islands|full) — three islands, or one full-length strip
#       BAR_AUTOHIDE     (off|on) — on: hidden until the pointer reaches its edge,
#                        reserving no space (the dock's "Always hide")
#       AI_ENABLED       (on|off)  — Settings -> AI; off disables EVE entirely
#       AI_MODEL         (sonnet|haiku|opus) — Settings -> AI -> Model; which
#                        Claude EVE talks to
#       AI_LEVEL         (basic|advanced) — Settings -> AI -> EVE's
#                        capabilities; advanced starts jarvis/broker.py
#       NOTIF_DND        (on|off) — Settings -> Setup -> Notifications; on: no
#                        island drop and no sound, the center still fills
#       NOTIF_SOUND      (on|off) — play NOTIF_SOUND_NAME on arrival
#       NOTIF_SOUND_NAME (chime|bell|message|complete|info|attention) — ids of
#                        NotifState.sounds, which maps them to .oga files
#       NOTIF_AUTODISMISS (on|off) — off: the drop stays until clicked
#       NOTIF_DURATION   (0.5|1|1.5 … 10, half-second steps) — seconds the drop shows for
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

VALID_KEYS="UI_FONT ICON_THEME GTK_THEME PALETTE DEFAULT_BROWSER DEFAULT_TERMINAL DEFAULT_EDITOR DEFAULT_BROWSER_DESKTOP DEFAULT_PDF DOCK_AUTOHIDE DOCK_POSITION SWITCHER_SPECIAL BAR_POSITION BAR_HIDDEN BAR_STYLE BAR_AUTOHIDE AI_ENABLED AI_MODEL AI_LEVEL NOTIF_DND NOTIF_SOUND NOTIF_SOUND_NAME NOTIF_AUTODISMISS NOTIF_DURATION"

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

# desktop_name <foo.desktop> — the Name= a .desktop file carries, for the one
# place a value that IS a .desktop file has to be said out loud (the PDF
# notification). Empty if the file is not on the search path.
desktop_name() {
    local f
    for f in "$HOME/.local/share/applications/$1" "/usr/share/applications/$1"; do
        [ -f "$f" ] || continue
        sed -n 's/^Name=//p' "$f" | head -1
        return 0
    done
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
    # DEFAULT_PDF is the one key whose truth is NOT ui.conf. Everything else
    # here is a preference this desktop reads back out of ui.conf; a PDF
    # association lives in mimeapps.list, and anything on the system can move
    # it — a package's post-install `xdg-mime default`, a GTK app's "always
    # open with", a hand edit. Asking ui.conf first would then tick the row the
    # menu last set rather than the one that actually opens a PDF. The stored
    # key is a record of the choice, not the answer to this question.
    if [ "$key" = DEFAULT_PDF ]; then
        xdg-mime query default application/pdf 2>/dev/null || true
        return 0
    fi
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
            # Without $BROWSER, or it searches Exec lines for that word instead of
            # reading the database: chromium came back as chatgpt.desktop, a
            # webapp whose Exec is `chromium --app=...`.
            d="$(env -u BROWSER xdg-settings get default-web-browser 2>/dev/null || true)"
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
#
# Nothing here says what a row is DRAWN with. A listing briefly carried a fifth
# column naming each browser's icon-theme icon, so the row could show the app's
# own logo; Ahaan wanted the glyphs, which take the pywal accent like every
# other icon in the menu, and a themed PNG does not. Settings.qml owns that
# decision now and this file is drawing-free again.

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

# The PDF viewers. Same shape as list_browsers and for the same reason — the
# mime database can only be asked which handler is CURRENT, never which ones
# exist — but the value is the .desktop file name, not the Exec command.
#
# That difference is the whole of what DEFAULT_PDF is. A browser's value is a
# command because things RUN it: hyprland.lua's $BROWSER, finder's web search.
# Nothing anywhere runs a PDF command — FileSearch's Enter is `xdg-open` and
# every other app asks the mime database too — so the setting is an
# association, and an association is keyed by .desktop file. Resolving that to
# a command here would only mean resolving it back before it could be applied.
#
# Browsers appear in this list on purpose: Zen, Brave and Chromium all render
# PDFs and all register for them, and one of them is a legitimate answer to
# "what should open this". They are filtered from nothing but the webapp guard.
list_pdf_viewers() {
    local f name
    for f in /usr/share/applications/*.desktop "$HOME"/.local/share/applications/*.desktop; do
        [ -f "$f" ] || continue
        [ "$(grep -c '^MimeType=.*application/pdf' "$f" || true)" -gt 0 ] || continue
        # Same guard as list_browsers: a webapp installed by webapp-install.sh
        # inherits chromium's MimeType line, and "WhatsApp" is not a PDF
        # viewer. (Today's template writes no MimeType at all, so this catches
        # nothing here — it is one line against the day it does.)
        [ "$(grep -c '^Exec=.*--app=' "$f" || true)" -eq 0 ] || continue
        # Hidden=true is the spec's "this entry has been deleted by the user"
        # and means exactly that. NoDisplay=true is NOT filtered, and that is
        # a measurement rather than a preference: Arch's
        # org.pwmt.zathura-pdf-poppler.desktop sets it — NoDisplay only means
        # "keep me out of the app grid", and the spec still uses such an entry
        # as a mime handler. Filtering on it dropped Zathura, which is both
        # the most likely answer on this machine and the one thing
        # hyprland.lua already carries a window rule for.
        [ "$(grep -c '^Hidden=true' "$f" || true)" -eq 0 ] || continue
        name="$(sed -n 's/^Name=//p' "$f" | head -1)"
        [ -n "$name" ] || continue
        printf '%s\t%s\t%s\n' "$(basename "$f")" "$name" ""
    done | sort -u -t"$(printf '\t')" -k2,2
    return 0
}

# Terminals and editors have no equivalent of the http-handler marker, so these
# are probe lists: a fixed set of candidates, filtered down to what is actually
# installed. A candidate that is not installed is simply not offered.
#
# Each entry is  command:label.  The command is the value, because that is what
# DEFAULT_TERMINAL becomes and what every `$TERMINAL -e …` caller runs — which
# is also why this stays a probe list rather than a scan of the TerminalEmulator
# category: a desktop file's Exec is a path with flags on it
# ("/usr/bin/ghostty --gtk-single-instance=true"), and that is not a thing you
# can append `-e` to.
#
# No per-terminal icon. The font has no mark for kitty, ghostty, alacritty or
# any of the others — only generic console glyphs — and Ahaan's call is that one
# honest terminal glyph on every row beats a row of themed PNGs that ignore the
# palette. The page's own glyph is what they all wear.
list_terminals() {
    local t c name
    for t in kitty:Kitty alacritty:Alacritty foot:Foot wezterm:WezTerm \
             ghostty:Ghostty gnome-terminal:"GNOME Terminal" konsole:Konsole \
             xterm:xterm; do
        c="${t%%:*}"; name="${t#*:}"
        command -v "$c" >/dev/null 2>&1 && printf '%s\t%s\t%s\n' "$c" "$name" ""
    done
    return 0
}

# The label is the editor's NAME, not its command: "nvim" and "hx" are how you
# invoke them, not what they are called, and a list of binaries reads as a list
# of binaries. The value is still the command — that is what $EDITOR becomes —
# so the two halves of each entry are deliberately different strings.
list_editors() {
    local e c name
    for e in nvim:Neovim vim:Vim helix:Helix hx:Helix nano:Nano micro:Micro \
             emacs:Emacs code:"VS Code" codium:VSCodium zed:Zed gedit:gedit \
             kate:Kate; do
        c="${e%%:*}"; name="${e#*:}"
        command -v "$c" >/dev/null 2>&1 && printf '%s\t%s\t%s\n' "$c" "$name" ""
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
    local val="$1" d
    command -v gsettings >/dev/null &&
        gsettings set org.gnome.desktop.interface gtk-theme "$val" 2>/dev/null || true
    for d in gtk-3.0 gtk-4.0; do
        ini_set "${XDG_CONFIG_HOME:-$HOME/.config}/$d/settings.ini" gtk-theme-name "$val"
    done
    # color-scheme is NOT set here any more. It was, inferred from this name
    # (*dark* -> prefer-dark), because libadwaita apps ignore gtk-theme and
    # follow color-scheme instead. Since 2026-10-29 palette.sh sets it from the
    # palette's measured brightness: the browsers follow it too, and a light
    # palette under Adwaita-dark was getting dark browsers. One owner, or the
    # last of the two settings pages touched would win.
}

# PALETTE is the one preference this file does not implement. It is sixteen
# colours reaching nine consumers through pywal's cache, which is a script's
# worth of behaviour rather than two gsettings calls — and it has to be
# runnable on its own, because finder/apply-wallpaper.sh asks it what a
# wallpaper change should do to the colours. So palette.sh owns all of it and
# this file owns only the fact that a value was chosen.
apply_palette() {
    "$(dirname -- "${BASH_SOURCE[0]}")/palette.sh" apply "$1"
}

# desktop_for_cmd <command> — the .desktop file that runs <command>: <cmd>.desktop
# if there is one, else the first entry whose Exec's first word is <cmd> (by
# basename, so /usr/bin/kitty counts). Empty if nothing on the search path does.
desktop_for_cmd() {
    local c="$1" f e
    for f in "$HOME/.local/share/applications/$c.desktop" "/usr/share/applications/$c.desktop"; do
        [ -f "$f" ] && { basename "$f"; return 0; }
    done
    for f in "$HOME"/.local/share/applications/*.desktop /usr/share/applications/*.desktop; do
        [ -f "$f" ] || continue
        e="$(sed -n 's/^Exec=//p' "$f" | head -1)"; e="${e%% *}"
        [ "${e##*/}" = "$c" ] && { basename "$f"; return 0; }
    done
    return 0
}

# DEFAULT_EDITOR used to reach only $EDITOR (hyprland.lua), so a file opened
# from nautilus went wherever the mime database said — text/plain=vim.desktop
# here, set by nothing anyone remembers, while the menu read "Neovim". The
# association IS the setting for everything that is not a shell, the same
# relationship DEFAULT_PDF has with application/pdf. So the editor's own entry
# becomes the default for every type it declares, minus inode/* (VS Code claims
# directories, and taking inode/directory from the file manager would turn
# double-clicking a folder into opening an editor) and x-scheme-handler/*.
# No entry (a hand-installed binary) leaves the mime database alone.
apply_editor() {
    local d f types
    d="$(desktop_for_cmd "$1")"
    [ -n "$d" ] && command -v xdg-mime >/dev/null || return 0
    for f in "$HOME/.local/share/applications/$d" "/usr/share/applications/$d"; do
        [ -f "$f" ] && break
    done
    types="$(sed -n 's/^MimeType=//p' "$f" | head -1 | tr ';' '\n' \
             | grep -vE '^(inode/|x-scheme-handler/|$)' || true)"
    [ -n "$types" ] || return 0
    # shellcheck disable=SC2086 — one word per type, deliberately split
    xdg-mime default "$d" $types 2>/dev/null || true
}

# DEFAULT_BROWSER is a command for everything that RUNS a browser, and an
# association for everything that asks the mime database: a link in EVE or a
# chat app, an .html file in nautilus. Both have to follow the menu.
#
# Not `xdg-settings set default-web-browser`, which is what this used to be. It
# refuses outright while $BROWSER is set ("$BROWSER is set and can't be changed
# with xdg-settings", exit 4), hyprland.lua sets $BROWSER for the whole session,
# and the error went to /dev/null: picking Chromium on 2026-11-07 left http and
# https on zen.desktop with the notification saying it worked. It would not be
# enough anyway. Run with $BROWSER unset it moved only http and https (measured
# on a scratch mimeapps.list), leaving .xhtml and the x-extension-* types behind.
#
# A fixed list, unlike apply_editor's, because a browser's MimeType also claims
# application/pdf and image/*: those belong to DEFAULT_PDF and imv. The list is
# every web type in install/templates/mimeapps.list. Returns non-zero unless the
# database reads back as chosen, so the caller can say so instead of claiming it.
apply_browser() {
    local d="$1"
    command -v xdg-mime >/dev/null || return 1
    xdg-mime default "$d" \
        x-scheme-handler/http x-scheme-handler/https x-scheme-handler/chrome \
        x-scheme-handler/about x-scheme-handler/unknown \
        text/html application/xhtml+xml \
        application/x-extension-htm application/x-extension-html \
        application/x-extension-shtml application/x-extension-xhtml \
        application/x-extension-xht 2>/dev/null || return 1
    [ "$(xdg-mime query default x-scheme-handler/https 2>/dev/null)" = "$d" ]
}

# A terminal editor's entry says Terminal=true, and GLib — nautilus, gio open,
# every GTK "open with" — then has to find a terminal itself. Measured on glib2
# 2.90: its list is xdg-terminal-exec, ghostty, gnome-terminal, konsole … and
# not kitty, so with kitty alone `gio launch nvim.desktop f` fails with
# "Unable to find terminal required for application" and nautilus just does
# nothing. xdg-terminal-exec is the first thing it tries; this file is how that
# tool is told which terminal is wanted. Written atomically like ui.conf.
apply_terminal() {
    local d list tmp
    d="$(desktop_for_cmd "$1")"
    [ -n "$d" ] || return 0
    list="${XDG_CONFIG_HOME:-$HOME/.config}/xdg-terminals.list"
    tmp="$list.tmp.$$"
    printf '# Written by ui-prefs.sh (Settings -> Defaults -> Terminal).\n%s\n' "$d" >"$tmp"
    mv "$tmp" "$list"
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
        # The two dock keys are closed sets, and the dock reads whatever is
        # here verbatim — a typo would otherwise park it at no edge at all.
        case "$key=$val" in
            DOCK_AUTOHIDE=overlap|DOCK_AUTOHIDE=always) ;;
            DOCK_POSITION=bottom|DOCK_POSITION=left|DOCK_POSITION=right) ;;
            DOCK_*) die "bad value for $key: $val" ;;
            SWITCHER_SPECIAL=on|SWITCHER_SPECIAL=off|SWITCHER_SPECIAL=workspace) ;;
            SWITCHER_SPECIAL=*) die "bad value for $key: $val" ;;
            BAR_POSITION=top|BAR_POSITION=left|BAR_POSITION=right) ;;
            BAR_POSITION=*) die "bad value for $key: $val" ;;
            BAR_STYLE=islands|BAR_STYLE=full) ;;
            BAR_STYLE=*) die "bad value for $key: $val" ;;
            BAR_AUTOHIDE=on|BAR_AUTOHIDE=off) ;;
            BAR_AUTOHIDE=*) die "bad value for $key: $val" ;;
            # "none", never "": UiConfig ignores an empty value (it keeps
            # whatever it had), so un-hiding the last module would never
            # reach the bar. Ids are lower-case words, comma-separated.
            BAR_HIDDEN=none) ;;
            BAR_HIDDEN=*)
                case "$val" in
                    ''|*[!a-z,]*|,*|*,|*,,*) die "bad value for $key: $val" ;;
                esac ;;
            AI_ENABLED=on|AI_ENABLED=off) ;;
            AI_ENABLED=*) die "bad value for $key: $val" ;;
            AI_MODEL=sonnet|AI_MODEL=haiku|AI_MODEL=opus) ;;
            AI_MODEL=*) die "bad value for $key: $val" ;;
            AI_LEVEL=basic|AI_LEVEL=advanced) ;;
            AI_LEVEL=*) die "bad value for $key: $val" ;;
            # Closed sets, like the dock's: NotifState reads these verbatim.
            NOTIF_DND=on|NOTIF_DND=off|NOTIF_SOUND=on|NOTIF_SOUND=off) ;;
            NOTIF_AUTODISMISS=on|NOTIF_AUTODISMISS=off) ;;
            NOTIF_SOUND_NAME=chime|NOTIF_SOUND_NAME=bell|NOTIF_SOUND_NAME=message) ;;
            NOTIF_SOUND_NAME=complete|NOTIF_SOUND_NAME=info|NOTIF_SOUND_NAME=attention) ;;
            # 0.5 to 10 in half-second steps: 1..10, or 0.5..9.5.
            NOTIF_DURATION=*)
                [[ "$val" =~ ^([1-9]|10|[0-9]\.5)$ ]] || die "bad value for $key: $val" ;;
            NOTIF_*) die "bad value for $key: $val" ;;
        esac
        pref_set "$key" "$val"
        case "$key" in
            UI_FONT)          apply_font "$val";       notify "Font" "$val" ;;
            ICON_THEME)       apply_icon_theme "$val"; notify "Icon theme" "$val" ;;
            GTK_THEME)        apply_gtk_theme "$val";  notify "Theme" "$val" ;;
            PALETTE)          apply_palette "$val";    notify "Palette" "$val" ;;
            DEFAULT_TERMINAL) apply_terminal "$val"; reload_hyprland; notify "Default terminal" "$val" ;;
            DEFAULT_PDF)
                # The association is the setting; the ui.conf line is only the
                # record of having chosen it (effective() reads the mime
                # database back, not this key). No reload_hyprland — nothing in
                # the compositor config mentions a PDF viewer.
                if command -v xdg-mime >/dev/null; then
                    xdg-mime default "$val" application/pdf 2>/dev/null || true
                fi
                notify "Default PDF viewer" "$(desktop_name "$val" || true)"
                ;;
            # The bar moved edge. Two things outside the shell have to follow
            # it: gaps_out (0 on the bar's side, so a window's border meets the
            # strip — window-rules.sh owns gaps) and any window SUPER+D sized
            # to the old free area (window-zoom.sh refit waits for Hyprland to
            # move the reserved inset first). Detached: refit polls for up to
            # ~2 s and nobody should wait on it.
            #
            # Always hide reserves nothing, so then there is no bar edge: every
            # side gets the outer gap, and refit waits for the zone to go
            # ("none"). Either key can change which of the two applies.
            BAR_POSITION|BAR_AUTOHIDE)
                here="$(dirname -- "${BASH_SOURCE[0]}")"
                if [ "$(pref_get BAR_AUTOHIDE 2>/dev/null)" = on ]; then edge=none
                else edge="$(pref_get BAR_POSITION 2>/dev/null)"; fi
                case "$edge" in none|left|right) ;; *) edge=top ;; esac
                "$here/window-rules.sh" apply-gaps "$edge" >/dev/null 2>&1 || true
                setsid "$here/window-zoom.sh" refit "$edge" </dev/null >/dev/null 2>&1 &
                ;;
            DEFAULT_EDITOR)   apply_editor "$val";   reload_hyprland; notify "Default editor" "$val" ;;
            DEFAULT_BROWSER)
                # DETAIL is the .desktop file name. Recording only the command
                # in ui.conf would leave the two disagreeing: finder would
                # search in one browser and a click in a chat app would open
                # another. The menu always passes DETAIL; a bare `set` from a
                # shell does not, so look it up rather than half-apply.
                [ -n "$detail" ] || detail="$(desktop_for_cmd "$val")"
                reload_hyprland
                if [ -n "$detail" ] && apply_browser "$detail"; then
                    pref_set DEFAULT_BROWSER_DESKTOP "$detail"
                    notify "Default browser" "$val"
                else
                    notify "Default browser" "$val for shortcuts only: links and HTML files did not change"
                fi
                ;;
        esac
        ;;

    list)
        case "${2:-}" in
            fonts)     list_fonts     | mark "$(effective UI_FONT)" ;;
            icons)     list_icons     | mark "$(effective ICON_THEME)" ;;
            themes)    list_themes    | mark "$(effective GTK_THEME)" ;;
            # Not piped through `mark`: palette.sh marks its own current row,
            # because the answer is not only the stored value — "pywal" is
            # what a machine that has never chosen one is running, and that
            # rule lives with the palettes rather than here.
            palettes)  "$(dirname -- "${BASH_SOURCE[0]}")/palette.sh" list ;;
            browsers)  list_browsers  | mark "$(effective DEFAULT_BROWSER)" ;;
            terminals) list_terminals | mark "$(effective DEFAULT_TERMINAL)" ;;
            editors)   list_editors   | mark "$(effective DEFAULT_EDITOR)" ;;
            pdf)       list_pdf_viewers | mark "$(effective DEFAULT_PDF)" ;;
            *) die "usage: ui-prefs.sh list fonts|icons|themes|palettes|browsers|terminals|editors|pdf" ;;
        esac
        ;;

    *)
        echo "usage: $(basename "$0") get <KEY>" >&2
        echo "       $(basename "$0") set <KEY> <VALUE> [DETAIL]" >&2
        echo "       $(basename "$0") list fonts|icons|themes|palettes|browsers|terminals|editors|pdf" >&2
        exit 2
        ;;
esac
