#!/usr/bin/env bash
# webapp-install.sh — turn a URL into a first-class desktop app: its own
# launcher entry, its own icon, its own window (no tabs, no browser chrome),
# and its own entry in finder and the dock.
#
# Modelled on Omarchy's omarchy-webapp-install, but writing the exact
# .desktop shape the eighteen webapps already in ~/.local/share/applications
# use, so a new one is indistinguishable from the hand-written ones.
#
# Run from a terminal (finder's settings menu opens one for it) — it is a form,
# not a picker, and needs a tty to read the answers.
#
# ── StartupWMClass is the load-bearing line ───────────────────────────────
# Without it the window belongs to "chromium" as far as the compositor is
# concerned: the dock groups every webapp under the browser icon, Alt-Tab
# labels them all "Chromium", and hyprland.lua's browsers-float rule resizes
# them like a browser window. Chromium derives the class from the URL in a
# fixed way, reproduced here and verified against the existing entries:
#
#     https://web.whatsapp.com   ->  chrome-web.whatsapp.com__-Default
#     https://claude.ai/new      ->  chrome-claude.ai__new-Default
#
# i.e.  chrome- <host> __ <path with / as _> -Default.

set -euo pipefail

APPDIR="$HOME/.local/share/applications"
ICONDIR="$HOME/.local/share/icons/webapps"

if [[ -t 1 ]]; then
    BOLD=$(tput bold); RESET=$(tput sgr0)
    CYAN=$(tput setaf 6); GREEN=$(tput setaf 2); RED=$(tput setaf 1); DIM=$(tput dim)
else
    BOLD=""; RESET=""; CYAN=""; GREEN=""; RED=""; DIM=""
fi

die() { printf '%s%s%s\n' "$RED" "$*" "$RESET" >&2; exit 1; }

# The browser that gets --app=. Chromium-family only: --app is a Chromium flag,
# and Firefox-family browsers (zen, librewolf) have no equivalent — asking zen
# for --app just opens a normal tabbed window, which defeats the whole point.
# So the configured default browser is used when it can do the job, and
# chromium is the fallback when it cannot.
pick_browser() {
    local configured cmd
    configured="$("$(dirname -- "${BASH_SOURCE[0]}")/ui-prefs.sh" get DEFAULT_BROWSER 2>/dev/null || true)"
    # The stored value comes from a .desktop Exec line, so it may be a bare name
    # ("brave") or an absolute path ("/usr/bin/chromium"). Match on the basename.
    cmd="${configured%% *}"
    case "$(basename -- "${cmd:-none}")" in
        chromium|chrome|google-chrome|google-chrome-stable|brave|brave-browser|vivaldi|vivaldi-stable|microsoft-edge)
            printf '%s' "$cmd"; return ;;
    esac
    command -v chromium >/dev/null && { printf 'chromium'; return; }
    command -v google-chrome-stable >/dev/null && { printf 'google-chrome-stable'; return; }
    command -v brave >/dev/null && { printf 'brave'; return; }
    die "no Chromium-family browser found — a web app needs --app, which only Chromium provides"
}

printf '%s%s══ Install a web app ══%s\n\n' "$BOLD" "$CYAN" "$RESET"

read -rp "Name (as it should appear in the launcher): " NAME
[ -n "${NAME// }" ] || die "a name is required"

read -rp "URL (e.g. https://app.example.com): " URL
[ -n "${URL// }" ] || die "a URL is required"
# A bare "example.com" would end up as a relative path in the Exec line and the
# window would never open, with no error anywhere.
case "$URL" in
    http://*|https://*) ;;
    *) URL="https://$URL"; printf '%s  -> assuming %s%s\n' "$DIM" "$URL" "$RESET" ;;
esac

# slug — the file name for both the .desktop and the icon. Lowercase and
# alphanumeric-or-dash only, because it also ends up in a path.
SLUG="$(printf '%s' "$NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]\+/-/g; s/^-//; s/-$//')"
[ -n "$SLUG" ] || die "could not derive a file name from '$NAME'"

DESKTOP="$APPDIR/$SLUG.desktop"
if [ -f "$DESKTOP" ]; then
    read -rp "$SLUG.desktop already exists. Overwrite? [y/N] " yn
    case "$yn" in [Yy]*) ;; *) die "cancelled" ;; esac
fi

# StartupWMClass, derived exactly as Chromium does — see the header.
STRIPPED="${URL#*://}"       # host[/path]
HOST="${STRIPPED%%/*}"
URLPATH="${STRIPPED#"$HOST"}"
URLPATH="${URLPATH#/}"       # leading slash off
URLPATH="${URLPATH%/}"       # and any trailing one
WMCLASS="chrome-${HOST}__${URLPATH//\//_}-Default"

BROWSER="$(pick_browser)"

# ── icon ─────────────────────────────────────────────────────────────────
mkdir -p "$ICONDIR" "$APPDIR"
ICON_PATH=""

# A path typed at this prompt arrives in whatever form the terminal produced.
# Drag-and-drop wraps the whole thing in quotes, tab-completion backslash-escapes
# the spaces, and a hand-typed one may start at ~ or at the cwd. All of those
# used to fall through to the URL branch and be handed to curl, which answered
# "Bad hostname" and left the app with the generic globe — so they are unpicked
# here before anything decides what the answer is.
normalise_src() {
    local p="$1"
    case "$p" in
        "'"*"'"|'"'*'"') p="${p:1:${#p}-2}" ;;   # a quoted paste
    esac
    p="${p//\\ / }"                              # "\ " from tab-completion
    case "$p" in "~") p="$HOME" ;; "~/"*) p="$HOME/${p#\~/}" ;; esac
    printf '%s' "$p"
}

# The name is not evidence of what a file is: the favicon service URL has no
# suffix at all, and a file saved as "logo" is still a PNG — the old code built
# "$SLUG.$src" out of a whole path in that case and cp died mid-script. So ask
# file(1) what the bytes are. This also catches the download that isn't an
# image: a 404 page comes back from curl as a perfectly non-empty file, passed
# the -s test, and rendered as a blank slot in the dock.
image_ext() {
    case "$(file -b --mime-type -- "$1" 2>/dev/null || true)" in
        image/png)                          printf 'png' ;;
        image/svg+xml)                      printf 'svg' ;;
        image/jpeg)                         printf 'jpg' ;;
        image/x-icon|image/vnd.microsoft.icon) printf 'ico' ;;
        image/webp)                         printf 'webp' ;;
        image/gif)                          printf 'gif' ;;
        *) return 1 ;;
    esac
}

warn() { printf '%s  %s%s\n' "$DIM" "$*" "$RESET"; }

# Both installers clear "$SLUG".* first: re-installing an app whose icon was a
# .png with an .svg would otherwise leave the old file behind for good, since
# nothing afterwards ever looks at it again.
install_local_icon() {
    local src="$1" ext
    [ -f "$src" ] || { warn "not a readable file: $src"; return 1; }
    ext="$(image_ext "$src")" || { warn "not an image file: $src"; return 1; }
    rm -f "$ICONDIR/$SLUG".*
    cp -f "$src" "$ICONDIR/$SLUG.$ext"
    chmod 644 "$ICONDIR/$SLUG.$ext"
    ICON_PATH="$ICONDIR/$SLUG.$ext"
}

# Downloads land in the same place under the same name, so a web app's icon is
# always $ICONDIR/$SLUG.<ext> however it was supplied, which is what lets
# webapp-remove.sh delete it by the Icon= line and know it is ours.
download_icon() {
    local src="$1" tmp ext
    command -v curl >/dev/null || { warn "curl is needed to download an icon"; return 1; }
    tmp="$(mktemp "${TMPDIR:-/tmp}/webapp-icon.XXXXXX")"
    if ! curl -fsSL --max-time 20 -o "$tmp" "$src"; then
        rm -f "$tmp"; warn "could not download $src"; return 1
    fi
    ext="$(image_ext "$tmp")" || {
        rm -f "$tmp"; warn "what came back from $src is not an image"; return 1
    }
    rm -f "$ICONDIR/$SLUG".*
    mv -f "$tmp" "$ICONDIR/$SLUG.$ext"
    chmod 644 "$ICONDIR/$SLUG.$ext"
    ICON_PATH="$ICONDIR/$SLUG.$ext"
}

printf '%sIcon: a path to a local file (tab completes), or a URL.\n      Leave blank to fetch the site'"'"'s favicon.%s\n' "$DIM" "$RESET"
while [ -z "$ICON_PATH" ]; do
    # -e for readline, so a path can be tab-completed rather than typed out in
    # full and got wrong. Only with a tty on stdin: fed from a pipe (a test
    # harness) readline has nothing to drive it.
    if [ -t 0 ]; then read -erp "Icon: " ICON_SRC || ICON_SRC=""
    else            read -rp  "Icon: " ICON_SRC || ICON_SRC=""; fi
    ICON_SRC="$(normalise_src "$ICON_SRC")"

    case "$ICON_SRC" in
        "") # No icon given: the site's own favicon, upscaled. Google's service
            # is used rather than /favicon.ico directly because that is usually
            # a 16px .ico, which renders as a smear in a 128px dock slot. A
            # failure here is not worth re-prompting over — the generic icon
            # below is the answer.
            download_icon "https://www.google.com/s2/favicons?domain=${HOST}&sz=256" || true
            break ;;
        http://*|https://*)
            download_icon "$ICON_SRC" || true ;;
        *)  if [ -e "$ICON_SRC" ]; then
                install_local_icon "$ICON_SRC" || true
            # A host typed without a scheme, matching what the URL prompt above
            # does with one. Only when it isn't a file and can't be a path:
            # "example.com/i.png" yes, "icons/i.png" no.
            elif [[ "$ICON_SRC" != /* && "$ICON_SRC" != .* && "$ICON_SRC" == *.*/* ]]; then
                warn "-> assuming https://$ICON_SRC"
                download_icon "https://$ICON_SRC" || true
            else
                warn "no such file: $ICON_SRC"
            fi ;;
    esac
    [ -n "$ICON_PATH" ] || warn "try again, or leave it blank for the site's favicon"
done

if [ -z "$ICON_PATH" ]; then
    warn "icon could not be fetched — falling back to the generic web icon"
    ICON_PATH="web-browser"
fi

# ── the entry ─────────────────────────────────────────────────────────────
cat >"$DESKTOP" <<EOF
[Desktop Entry]
Name=$NAME
Exec=$BROWSER --app=$URL
StartupWMClass=$WMCLASS
Icon=$ICON_PATH
Type=Application
Categories=Network;
Keywords=$SLUG;webapp;
EOF

command -v update-desktop-database >/dev/null &&
    update-desktop-database "$APPDIR" 2>/dev/null || true

printf '\n%s==>%s Installed %s%s%s\n' "$GREEN" "$RESET" "$BOLD" "$NAME" "$RESET"
printf '    %s\n    class %s\n    icon  %s\n' "$DESKTOP" "$WMCLASS" "$ICON_PATH"
printf '\n%sfinder and the dock rescan .desktop files at startup, so press SUPER+K\n(toggle shells) if it does not show up straight away.%s\n' "$DIM" "$RESET"
printf '\nPress any key to close… '
read -rsn1 _ || true
echo
