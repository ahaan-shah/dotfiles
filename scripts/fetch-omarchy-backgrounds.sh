#!/usr/bin/env bash
# fetch-omarchy-backgrounds.sh  [--force]
#
# Downloads the background images omarchy ships with each of its themes into
#
#     ~/.local/share/hyprahaan/wallpapers/<theme>/<file>
#
# and warms the colour cache scripts/wallpapers.sh keeps, so the first opening
# of Settings → Theme → Wallpapers after a fetch is not a 26-second scan.
#
# One directory per theme and NO vendor directory above them — Ahaan's call.
# Where the images came from is recorded in .source at the root of that tree
# rather than in a path component, which is the better place for it anyway: the
# theme name is the part the picker reads, and it would go on meaning exactly
# the same thing if a second source ever added to the same tree.
#
# ── Why this exists ──────────────────────────────────────────────────────
# The "By palette" page was answering with the same eight wallpapers whatever
# palette was in force, and the cause was the collection rather than the rule:
# ~/Pictures/wallpapers is eighteen images and most of them are near-black, so
# against any dark palette the same near-blacks win every time. A shortlist
# that never changes is not a shortlist.
#
# omarchy states each theme as a palette AND a set of backgrounds chosen for
# it, and this repo already derives scripts/palettes/*.json from the same
# themes — the 22 theme names map 1:1 onto the 22 palettes we ship. So the
# images that make the page mean something already exist, one set per palette,
# which is also what lets "By palette" lead with the palette's OWN backgrounds
# rather than only with whatever scores well.
#
# Source: github.com/omacom/omarchy, branch quattro, pinned below. MIT, and
# the same provenance line palette.sh already carries for the colours.
#
# ── Why NOT into ~/Pictures/wallpapers ───────────────────────────────────
# That directory is rsynced wholesale into the PUBLIC dotfiles mirror
# (backup_configs.sh: `sync "$HOME/Pictures/wallpapers" "$DOTDIR/wallpapers"`).
# Dropping 52 MB of someone else's images there would republish all of them
# from Ahaan's repo on his next backup, which is a decision and not a side
# effect of a download. ~/.local/share/hyprahaan is not mirrored — the mirror
# takes only ~/.local/share/applications and ~/.local/share/icons/webapps — so
# this lands beside the machine's own data and travels nowhere.
#
# It also keeps the two sets apart for the reason the pages need them apart:
# ~/Pictures/wallpapers is Ahaan's own and shows only under "All"; this tree
# is what "By palette" chooses from. That split is by DIRECTORY and not by any
# marker inside the files, which is what makes "his own" and "themed" a
# property of where an image lives rather than of what it is.
set -uo pipefail

REPO="omacom/omarchy"
# PINNED, not `quattro`. A branch name would make two machines fetch different
# images and make this script's output unreproducible — the same reason
# palette.sh records the commit its colour data came from. Bump deliberately.
REF="f2b419d9a9d7e7821de2ddf9c42991e32cf06cdf"

DEST="${THEME_BG_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/hyprahaan/wallpapers}"
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

die() { echo "fetch-omarchy-backgrounds: $*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || die "curl is missing"
command -v jq   >/dev/null 2>&1 || die "jq is missing"

mkdir -p "$DEST" || die "cannot create $DEST"

# ── the listing ──────────────────────────────────────────────────────────
# One recursive tree call rather than one call per theme: 22 API calls against
# an unauthenticated 60/hour limit is most of the budget for a listing that is
# 600 KB in a single request. `.truncated` is checked because the API silently
# caps very large trees, and a truncated listing would look like a repo that
# had simply lost half its themes.
tree_json="$(mktemp)" || die "mktemp failed"
trap 'rm -f "$tree_json"' EXIT

echo "listing $REPO @ ${REF:0:7} …"
curl -sfL --max-time 60 \
     -H 'Accept: application/vnd.github+json' \
     "https://api.github.com/repos/$REPO/git/trees/$REF?recursive=1" \
     -o "$tree_json" || die "could not list the repository (network? rate limit?)"

[ "$(jq -r '.truncated' "$tree_json")" = "false" ] \
    || die "the tree listing came back truncated; refusing a partial fetch"

mapfile -t paths < <(jq -r '
    .tree[].path
    | select(test("^themes/[^/]+/backgrounds/[^/]+$"))
' "$tree_json")

[ "${#paths[@]}" -gt 0 ] || die "no theme backgrounds found at $REF"
echo "found ${#paths[@]} backgrounds across $(printf '%s\n' "${paths[@]}" | cut -d/ -f2 | sort -u | wc -l) themes"

# ── download ─────────────────────────────────────────────────────────────
# Skips a file that is already there at non-zero size, so a re-run after a
# half-finished fetch costs only what is missing. --force re-downloads.
#
# Written to a temp file and mv'd into place: a partial download left under the
# real name would be cached by wallpapers.sh as a valid image and then fail to
# decode in the picker, which is the "a file existing is not a file finished"
# trap this repo has already paid for once with hyprshot.
ok=0; skipped=0; failed=0
for path in "${paths[@]}"; do
    theme="$(printf '%s' "$path" | cut -d/ -f2)"
    file="$(printf '%s' "$path" | cut -d/ -f4-)"
    out="$DEST/$theme/$file"

    if [ "$FORCE" -eq 0 ] && [ -s "$out" ]; then
        skipped=$((skipped + 1))
        continue
    fi

    mkdir -p "$DEST/$theme"
    tmp="$out.part.$$"
    # The raw host, pinned to the same commit as the listing, so the bytes and
    # the file list cannot come from two different states of the repo.
    if curl -sfL --max-time 120 --retry 2 --retry-delay 1 \
            "https://raw.githubusercontent.com/$REPO/$REF/$path" -o "$tmp" \
       && [ -s "$tmp" ]; then
        mv "$tmp" "$out"
        ok=$((ok + 1))
        printf '  %s/%s\n' "$theme" "$file"
    else
        rm -f "$tmp"
        failed=$((failed + 1))
        echo "  FAILED $theme/$file" >&2
    fi
done

echo "downloaded $ok, already present $skipped, failed $failed"
[ "$failed" -eq 0 ] || die "$failed file(s) did not download; re-run to retry only those"

# A stamp, so a later session can tell which commit this tree came from
# without diffing 92 images against a repository.
printf '%s %s\n' "$REPO" "$REF" > "$DEST/.source"

# ── warm the colour cache ────────────────────────────────────────────────
# wallpapers.sh quantises every image it has not seen, and 92 of them is ~15s.
# Paying it here means the first settings open after a fetch is as fast as
# every other one, rather than being the one that looks broken.
if [ -x "$SELF_DIR/wallpapers.sh" ]; then
    echo "warming the colour cache …"
    "$SELF_DIR/wallpapers.sh" scan && echo "cache warm"
fi
