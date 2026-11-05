#!/usr/bin/env bash
# downloads-list.sh <icon-theme> <downloads> <recents> — the most recently used files
# anywhere, and the newest files in the XDG download folder, for
# DownloadsStack.qml. Read-only; prints, in order:
#
#   D<TAB><folder>
#   R<TAB><used, epoch><TAB><icon file or empty><TAB><path>   most recent first
#   F<TAB><mtime><TAB><icon file or empty><TAB><name>         newest first
#
# Up to that many of each. Recents are GTK's recently-used.xbel — what
# Nautilus, the GTK file chooser, LibreOffice and the like record when a file
# is opened — kept only while the file still exists. The two lists overlap
# (an opened download is in both); the POPUP drops the overlap, not this
# script, because the dock's drawer and its badge want the true newest
# downloads whether or not they have been opened.
#
# The icon is the file's MIME-type icon as a FILE path, looked up here rather
# than in QML: DesktopEntryCache indexes application icons only, and Qt's own
# theme lookup (image://icon/) has none of these on this machine. Papirus names
# them by MIME with the slash turned into a dash (application/pdf ->
# application-pdf), with <type>-x-generic and `unknown` as fallbacks.
#
# In-progress downloads (.part, .crdownload) and dotfiles are skipped: a
# half-written file opens as garbage and is renamed a moment later.
theme=${1:-Papirus-Dark}
count=${2:-8}
recent=${3:-4}

d=$(xdg-user-dir DOWNLOAD 2>/dev/null)
[ -n "$d" ] || d="$HOME/Downloads"
printf 'D\t%s\n' "$d"

# Mimetype icon dirs, preferred theme first, at the largest raster size the
# popup needs (64 covers 32px at 2x) or scalable. -d follows the symlinked
# size dirs Papirus-Dark uses.
dirs=()
for t in "$theme" Papirus-Dark Papirus Adwaita hicolor; do
  for s in 64x64 scalable 48x48; do
    [ -d "/usr/share/icons/$t/$s/mimetypes" ] && dirs+=("/usr/share/icons/$t/$s/mimetypes")
  done
done

icon_for() {
  local mime=$1 n
  for n in "${mime//\//-}" "${mime%%/*}-x-generic" unknown; do
    for dir in "${dirs[@]}"; do
      [ -e "$dir/$n.svg" ] && { printf '%s' "$dir/$n.svg"; return; }
      [ -e "$dir/$n.png" ] && { printf '%s' "$dir/$n.png"; return; }
    done
  done
}

row() {  # row <kind> <time> <file> <shown as>
  local mime
  mime=$(file --mime-type -b -- "$3" 2>/dev/null)
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$(icon_for "${mime:-application/octet-stream}")" "$4"
}

skipped() { case ${1##*/} in .*|*.part|*.crdownload) return 0 ;; esac; return 1; }

# ── Recents ──────────────────────────────────────────────────────────────
# GLib writes each <bookmark ...> start tag on one line, attributes in the
# order href, added, modified, visited. `modified` is bumped every time an app
# re-records the file, so it is the "last used" time, and ISO-8601 in UTC
# sorts as text. The newest 200 are candidates enough: most of a long history
# (843 entries here, 2026-10-29) points at files since moved or deleted.
xbel=${XDG_DATA_HOME:-$HOME/.local/share}/recently-used.xbel
declare -A shown=()
marks=""
[ -r "$xbel" ] && marks=$(grep -o '<bookmark [^>]*>' "$xbel" 2>/dev/null \
  | sed -n 's|.*href="file://\([^"]*\)".*modified="\([^"]*\)".*|\2\t\1|p' \
  | sort -r | head -n 200)

n=0
while [ "$n" -lt "$recent" ] && IFS=$'\t' read -r when href; do
  [ -n "$href" ] || continue
  # Percent-decoding (%20 -> \x20, then printf %b), then the two XML entities
  # that can occur in a path. Unencoded backslashes don't: GLib escapes them.
  p=$(printf '%b' "${href//%/\\x}")
  p=${p//&amp;/&}; p=${p//&apos;/\'}
  [ -f "$p" ] || continue
  [ -z "${shown[$p]+x}" ] || continue
  skipped "$p" && continue
  shown[$p]=1
  row R "$(date -d "$when" +%s 2>/dev/null || echo 0)" "$p" "$p"
  n=$((n + 1))
done <<< "$marks"

# ── Downloads ────────────────────────────────────────────────────────────
# Captured first, then read: no `producer | head` race under the read loop.
list=$(find "$d" -maxdepth 1 -type f ! -name '.*' ! -name '*.part' ! -name '*.crdownload' \
         -printf '%T@\t%f\n' 2>/dev/null | sort -rn | head -n "$count")

while IFS=$'\t' read -r mt name; do
  [ -n "$name" ] || continue
  row F "$mt" "$d/$name" "$name"
done <<< "$list"
