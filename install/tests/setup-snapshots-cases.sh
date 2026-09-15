#!/usr/bin/env bash
# setup-snapshots-cases.sh — drive every branch of scripts/setup-snapshots.sh
#
# The machine this was written on is ext4, so the btrfs half of that script
# cannot run here at all. Without this harness it would ship completely unrun,
# which on a script that can affect whether a machine boots is not acceptable.
#
# So the two things the script asks the SYSTEM about are faked:
#   findmnt / btrfs   a stub earlier on PATH, printing what a given layout would
#   /.snapshots       the SNAPSHOTS_DIR seam
#   the limine config the LIMINE_ROOT seam
#
# Everything else — the order of the checks, which ones are fatal, which only
# warn, and the exit status the installer reads — is the real script.
#
# This proves the DECISION TREE and nothing beyond it. It does not prove that
# snapper produces a bootable snapshot, and it cannot: that needs a btrfs root.
# Run it after any edit to setup-snapshots.sh.
set -uo pipefail

SELF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SELF/../../scripts/setup-snapshots.sh"
[ -x "$SCRIPT" ] || { echo "cannot find setup-snapshots.sh at $SCRIPT" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0

# Builds a stub findmnt/btrfs pair for one layout and puts them first on PATH.
#   $1 FSTYPE for /        $2 OPTIONS for /
#   $3 "mount" if $SNAPSHOTS_DIR should answer as a mountpoint
#   $4 "subvol" if `btrfs subvolume show` should succeed on it
make_stubs() {
    local fstype="$1" opts="$2" snapmount="$3" snapsubvol="$4"
    mkdir -p "$TMP/bin"
    cat >"$TMP/bin/findmnt" <<EOF
#!/usr/bin/env bash
# args: -no <cols> <target>
target="\${*: -1}"
cols="\$2"
if [ "\$target" = "/" ]; then
    case "\$cols" in
        FSTYPE)  printf '%s\n' "$fstype" ;;
        SOURCE)  printf '%s\n' "/dev/fake1" ;;
        OPTIONS) printf '%s\n' "$opts" ;;
        *)       printf '%s\n' "$fstype" ;;
    esac
    exit 0
fi
# anything else is the /.snapshots mountpoint probe
[ "$snapmount" = mount ] && { printf '%s\n' "\$target"; exit 0; }
exit 1
EOF
    cat >"$TMP/bin/btrfs" <<EOF
#!/usr/bin/env bash
[ "$snapsubvol" = subvol ] && exit 0
exit 1
EOF
    chmod +x "$TMP/bin/findmnt" "$TMP/bin/btrfs"
}

# expect <name> <want-exit> <want-grep-or-->
expect() {
    local name="$1" want="$2" grep_for="$3"; shift 3
    local out rc
    out="$(PATH="$TMP/bin:$PATH" "$@" "$SCRIPT" --dry-run 2>&1)"; rc=$?
    local why=""
    [ "$rc" = "$want" ] || why="exit $rc, wanted $want"
    if [ -z "$why" ] && [ "$grep_for" != "-" ]; then
        printf '%s' "$out" | grep -qF -- "$grep_for" || why="output did not mention: $grep_for"
    fi
    if [ -z "$why" ]; then
        printf '  \033[32m✓\033[0m %s\n' "$name"; PASS=$((PASS+1))
    else
        printf '  \033[31m✗\033[0m %s — %s\n' "$name" "$why"; FAIL=$((FAIL+1))
        printf '%s\n' "$out" | sed 's/^/      /'
    fi
}

echo
echo "setup-snapshots.sh — decision tree"
echo

# ── 1. the case this machine is actually in ─────────────────────────────
make_stubs ext4 "rw,relatime" no no
expect "ext4 root refuses, and says why" 1 "not btrfs" env

# ── 2. btrfs on the top level is refused, not adapted to ────────────────
make_stubs btrfs "rw,subvolid=5,subvol=/" no no
expect "btrfs top level (subvolid 5) refuses" 1 "top level" \
    env SNAPSHOTS_DIR="$TMP/none" LIMINE_ROOT="$TMP/empty"

# ── 3. btrfs with no subvol at all ──────────────────────────────────────
make_stubs btrfs "rw,relatime,compress=zstd" no no
expect "btrfs with no subvolume refuses" 1 "not mounted from a subvolume" \
    env SNAPSHOTS_DIR="$TMP/none" LIMINE_ROOT="$TMP/empty"

# ── 4. the good layout, nothing in the way ──────────────────────────────
mkdir -p "$TMP/limine/boot/limine"
cat >"$TMP/limine/boot/limine/limine.conf" <<'EOF'
timeout: 5
/Arch Linux
    protocol: linux
    path: boot():/vmlinuz-linux
    cmdline: root=UUID=x rootflags=subvol=@ rw
EOF
make_stubs btrfs "rw,relatime,compress=zstd,subvol=/@" no no
expect "btrfs on @ with a plain limine entry passes" 0 "What this would do" \
    env SNAPSHOTS_DIR="$TMP/none" LIMINE_ROOT="$TMP/limine"

# ── 5. /.snapshots already a subvolume, and already a mountpoint ────────
mkdir -p "$TMP/snapdir"
make_stubs btrfs "rw,subvol=/@" no subvol
expect "/.snapshots already a subvolume is accepted" 0 "already a btrfs subvolume" \
    env SNAPSHOTS_DIR="$TMP/snapdir" LIMINE_ROOT="$TMP/limine"

make_stubs btrfs "rw,subvol=/@" mount no
expect "/.snapshots already a mountpoint is accepted" 0 "is a mountpoint" \
    env SNAPSHOTS_DIR="$TMP/snapdir" LIMINE_ROOT="$TMP/limine"

# ── 6. /.snapshots as a plain directory is the trap, and is refused ─────
make_stubs btrfs "rw,subvol=/@" no no
expect "/.snapshots as a plain directory refuses" 1 "neither a mountpoint nor" \
    env SNAPSHOTS_DIR="$TMP/snapdir" LIMINE_ROOT="$TMP/limine"

# ── 7. no limine config WARNS but does not refuse ───────────────────────
# The distinction is deliberate: snapshots with no boot menu are still
# restorable from a live USB, so refusing would withhold something useful.
make_stubs btrfs "rw,subvol=/@" no no
expect "missing limine config warns, still proceeds" 0 "will not" \
    env SNAPSHOTS_DIR="$TMP/none" LIMINE_ROOT="$TMP/empty"

# ── 8. a UKI entry warns about the baked-in cmdline ─────────────────────
mkdir -p "$TMP/uki/boot/limine"
cat >"$TMP/uki/boot/limine/limine.conf" <<'EOF'
timeout: 5
/Arch Linux (linux)
    protocol: efi
    path: boot():/EFI/Linux/arch-linux.efi
    cmdline: root=PARTUUID=x rw rootfstype=btrfs
EOF
make_stubs btrfs "rw,subvol=/@" no no
expect "a UKI entry warns that the snapshot cmdline may not win" 0 "boots a UKI" \
    env SNAPSHOTS_DIR="$TMP/none" LIMINE_ROOT="$TMP/uki"

echo
if [ "$FAIL" = 0 ]; then
    printf '  \033[32m%d passed\033[0m\n\n' "$PASS"
else
    printf '  \033[31m%d failed\033[0m, %d passed\n\n' "$FAIL" "$PASS"
fi
exit $(( FAIL > 0 ))
