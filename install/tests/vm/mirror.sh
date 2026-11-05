#!/usr/bin/env bash
# mirror.sh — build what the public dotfiles repo WOULD contain and serve it to
# the test VM, so the installer is tested from a mirror-shaped tree without
# anything being published.
#
# Runs backup_configs.sh with DOTFILES_DIR and HYPRAHAAN_SRC pointed at scratch
# copies (the override its header documents for exactly this). It never touches
# ~/.config/dotfiles, and because HYPRAHAAN_SRC is a copy, the mimeapps refresh it
# does on the source repo lands in the copy too. It has no git commands of its
# own; the git repo here is local, served on 127.0.0.1 only, which the guest
# reaches as 10.0.2.2.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
D="${VMTEST_DIR:-$HOME/.cache/hyprahaan-vmtest}"
M="$D/mirror"; S="$D/srccopy"
mkdir -p "$D"
rsync -a --delete --exclude .git --exclude __pycache__ --exclude system-map "$REPO"/ "$S"/
mkdir -p "$M"   # .git kept: history has to move forward, or a guest's --ff-only pull refuses
# A file changed in the repo but not yet deployed is what the real mirror would
# not have yet either. List them in VMTEST_OVERLAY (repo-relative) to test with
# the repo's copy anyway; the scan below still has to pass with them in place.
out="$(DOTFILES_DIR="$M" HYPRAHAAN_SRC="$S" bash "$S/scripts/backup_configs.sh" 2>&1)" && rc=0 || rc=$?
for f in ${VMTEST_OVERLAY:-}; do cp "$REPO/$f" "$M/$f"; done
if [ "$rc" -ne 0 ]; then
    left="$(grep -rIl --exclude-dir=.git --exclude=backup_configs.sh -e "/home/USER"'/projects/' "$M" || true)"
    if [ -n "$left" ] || ! grep -q 'private source-repo path' <<<"$out"; then
        printf '%s\n' "$out" | tail -12; exit 1
    fi
    echo "(the only refusal was the overlaid file, now fixed)"
fi
git -C "$M" init -q -b main
git -C "$M" add -A
git -C "$M" -c user.name=vmtest -c user.email=vmtest@localhost commit -qm "mirror snapshot for the VM test" --allow-empty
systemctl --user stop hyprahaan-vmtest-http hyprahaan-vmtest-git 2>/dev/null || true
systemd-run --user --unit=hyprahaan-vmtest-http --collect --quiet \
    python3 -m http.server 8765 --bind 127.0.0.1 --directory "$M"
systemd-run --user --unit=hyprahaan-vmtest-git --collect --quiet \
    git daemon --export-all --reuseaddr --listen=127.0.0.1 --port=9418 --base-path="$D" "$M"
du -sh --exclude=.git "$M"
echo "one-liner: curl -fsSL http://10.0.2.2:8765/install/bootstrap.sh | HYPRAHAAN_REPO=git://10.0.2.2:9418/mirror bash"
