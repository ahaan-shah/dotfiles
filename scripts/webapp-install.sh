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

printf '%sIcon: a URL or a local file. Leave blank to fetch the site'"'"'s favicon.%s\n' "$DIM" "$RESET"
read -rp "Icon: " ICON_SRC

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

# ── icon ──────────────────────────────────────────────────────────────────
mkdir -p "$ICONDIR" "$APPDIR"
ICON_PATH=""
fetch_icon() {
    local src="$1" ext out
    case "$src" in
        "") # No icon given: the site's own favicon, upscaled. Google's service
            # is used rather than /favicon.ico directly because that is usually
            # a 16px .ico, which renders as a smear in a 128px dock slot.
            src="https://www.google.com/s2/favicons?domain=${HOST}&sz=256"
            ext="png" ;;
        /*|~*) # a local file
            src="${src/#\~/$HOME}"
            [ -f "$src" ] || die "no such file: $src"
            ext="${src##*.}"
            cp -f "$src" "$ICONDIR/$SLUG.$ext"
            ICON_PATH="$ICONDIR/$SLUG.$ext"
            return 0 ;;
        *)  ext="${src##*.}"
            case "$ext" in png|svg|jpg|jpeg|ico|webp) ;; *) ext="png" ;; esac ;;
    esac
    command -v curl >/dev/null || die "curl is needed to download an icon"
    out="$ICONDIR/$SLUG.$ext"
    if curl -fsSL --max-time 20 -o "$out" "$src"; then
        # A zero-length file is what a 200-with-empty-body looks like, and it
        # would leave a .desktop pointing at an icon that renders as nothing.
        if [ -s "$out" ]; then ICON_PATH="$out"; else rm -f "$out"; fi
    fi
}
fetch_icon "$ICON_SRC"

if [ -z "$ICON_PATH" ]; then
    printf '%s  icon could not be fetched — falling back to the generic web icon%s\n' "$DIM" "$RESET"
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
