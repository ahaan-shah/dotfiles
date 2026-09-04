#!/usr/bin/env bash
# webapp-remove.sh — the other half of webapp-install.sh: pick an installed web
# app and delete its .desktop entry and the icon that was downloaded for it.
#
# Only entries under ~/.local/share/applications whose Exec line carries --app=
# are offered. That is what makes something a web app rather than a real
# installed program, and it is why this cannot uninstall e.g. chromium itself by
# accident — chromium's own entry has no --app=.
#
# Layout/keybinds mirror pkg-remove.sh (fzf + a pywal-coloured preview), so the
# three "remove something" flows in the settings menu look and behave the same.

set -euo pipefail

APPDIR="$HOME/.local/share/applications"
ICONDIR="$HOME/.local/share/icons/webapps"

wal="$HOME/.cache/wal/colors.sh"
if [ -f "$wal" ]; then
  set +u
  source "$wal"
  set -u
fi

foreground="${foreground:-#eae1e3}"
background="${background:-#000000}"
color1="${color1:-#A84234}"
color2="${color2:-#DC4223}"
color4="${color4:-#946E6B}"
color8="${color8:-#a39d9e}"

fzf_colors="fg:$foreground,bg:$background,hl:$color1"
fzf_colors+=",info:$color4,prompt:$color2,pointer:$color2,marker:$color2,spinner:$color1,gutter:$color8"
fzf_colors+=",border:$color8,list-border:$color8,input-border:$color8,preview-border:$color8"
fzf_colors+=",label:$color4,list-label:$color4,preview-label:$color4,input-label:$color4"
fzf_colors+=",scrollbar:$color8,preview-scrollbar:$color8,separator:$color8"

# name<TAB>path, so fzf shows the launcher name and hands back the file.
# `grep -l ... | while read` rather than a glob loop so a directory with no web
# apps in it produces no rows instead of one row reading "*.desktop".
listing=""
for f in "$APPDIR"/*.desktop; do
    [ -f "$f" ] || continue
    [ "$(grep -c '^Exec=.*--app=' "$f" || true)" -gt 0 ] || continue
    name="$(sed -n 's/^Name=//p' "$f" | head -1)"
    [ -n "$name" ] || name="$(basename "$f" .desktop)"
    listing+="$name	$f"$'\n'
done

[ -n "$listing" ] || { echo "No web apps installed."; printf '\nPress any key to close… '; read -rsn1 _ || true; exit 0; }

fzf_args=(
  --multi
  --delimiter='\t'
  --with-nth=1
  --preview 'cat {2}'
  --preview-label='tab: multi-select · enter: remove'
  --preview-label-pos='bottom'
  --preview-window 'down:55%:wrap'
  --color "$fzf_colors"
)

selected="$(printf '%s' "$listing" | fzf "${fzf_args[@]}")" || true
[ -n "$selected" ] || exit 0

while IFS=$'\t' read -r name path; do
    [ -n "$path" ] || continue
    # The icon is deleted only when it lives in the webapps icon dir, i.e. only
    # when webapp-install.sh put it there. An entry pointing at a shared theme
    # icon ("web-browser") or at something elsewhere on disk must not have that
    # file removed out from under everything else using it.
    icon="$(sed -n 's/^Icon=//p' "$path" | head -1)"
    rm -f "$path"
    case "$icon" in
        "$ICONDIR"/*) rm -f "$icon"; echo "removed $name (entry + icon)" ;;
        *)            echo "removed $name (entry; icon left alone)" ;;
    esac
done <<<"$selected"

command -v update-desktop-database >/dev/null &&
    update-desktop-database "$APPDIR" 2>/dev/null || true

printf '\nPress any key to close… '
read -rsn1 _ || true
echo
