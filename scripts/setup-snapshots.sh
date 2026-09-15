#!/usr/bin/env bash
# setup-snapshots.sh  [--dry-run] [--yes]
#
# Sets up pre-update system snapshots that appear as boot entries in limine:
# snapper for the snapshots, snap-pac for the pacman hook that takes one before
# every transaction, and limine-snapper-sync to put them in the boot menu.
#
# Exits 1 from --dry-run when this machine cannot do it, which is how
# install.sh's snapshots phase decides whether to offer it at all — the same
# contract setup-hibernation.sh has.
#
# ── Read this before changing anything here ──────────────────────────────
# This script has been exercised ONLY on its refusal paths, because the machine
# it was written on is ext4 and none of the rest of it can run there. Every
# decision below is guarded, dry-runnable and reversible; none of the btrfs half
# has been watched working end to end. Where something is asserted from
# documentation rather than from a measurement, it says so in the comment. Do
# not remove those admissions to make the file read more confidently — they are
# the difference between "this was tested" and "this should work", and on a
# script that can affect whether a machine boots, the distinction is the point.
#
# ── Why snapper and snap-pac rather than something written here ──────────
# "Snapshot before every update" is exactly what snap-pac is: a pacman
# ALPM hook that creates a pre snapshot before a transaction and a post
# snapshot after it. Hooking the desktop's own update script instead would
# cover `Settings → Update` and miss every `pacman -Syu` typed into a terminal,
# every `yay`, and every dependency pulled in by an unrelated install — which
# is the opposite of airtight. The hook sits below all of them.
#
# ── Why this refuses rather than adapts ─────────────────────────────────
# A snapshot you cannot boot into is worse than no snapshot, because it is
# discovered at the moment it is needed. Everything below either finds the
# layout it knows how to handle or stops and says which check failed.
set -uo pipefail

DRY=0
ASSUME_YES=0
for a in "$@"; do
    case "$a" in
        --dry-run) DRY=1 ;;
        --yes|-y)  ASSUME_YES=1 ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "setup-snapshots: unknown argument: $a" >&2; exit 2 ;;
    esac
done

# ── how many restore points to keep ──────────────────────────────────────
# Ahaan asked for three. snap-pac writes a PAIR per transaction — a `pre` taken
# before pacman touches anything and a `post` taken after — so three restore
# points is six snapshot objects, and snapper's NUMBER_LIMIT counts objects.
# The number below is therefore 2 x RESTORE_POINTS, and it is written that way
# rather than as a bare 6 so that changing one does not silently halve the
# other.
RESTORE_POINTS=3
NUMBER_LIMIT=$((RESTORE_POINTS * 2))

# ── two seams, and they exist so the decision tree can be TESTED ─────────
# Nothing that decides whether a machine can take snapshots can be exercised on
# a machine that cannot — and this one is ext4, so without these the whole
# btrfs half of this file would ship unrun. They are the same shape as
# wallpapers.sh's WALLPAPER_DIR and backup_configs.sh's DOTFILES_DIR, and
# tests/setup-snapshots-cases.sh drives every branch below through them.
# Unset in every real run, where they resolve to the real paths.
SNAP_DIR="${SNAPSHOTS_DIR:-/.snapshots}"
LIMINE_ROOT="${LIMINE_ROOT:-}"

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; }
die()  { bad "$*"; exit 1; }

# Every command with a side effect goes through this, so --dry-run is total
# rather than best-effort. Nothing in this file may call sudo directly.
run() {
    if [ "$DRY" = 1 ]; then printf '  \033[2mDRY\033[0m %s\n' "$*"; return 0; fi
    "$@"
}
run_sh() {
    if [ "$DRY" = 1 ]; then printf '  \033[2mDRY\033[0m sh -c %s\n' "$1"; return 0; fi
    bash -c "$1"
}

# ═════════════════════════════════════════════════════════════════════════
# The checks. Each one prints why it refused, because "it did not work" is
# not a thing anyone can act on.
# ═════════════════════════════════════════════════════════════════════════

ROOT_FSTYPE="$(findmnt -no FSTYPE / 2>/dev/null || true)"
ROOT_SOURCE="$(findmnt -no SOURCE / 2>/dev/null || true)"

check_btrfs() {
    if [ "$ROOT_FSTYPE" != btrfs ]; then
        bad "root (/) is ${ROOT_FSTYPE:-unknown}, not btrfs."
        say ""
        say "  Filesystem snapshots need btrfs subvolumes (or LVM thin volumes,"
        say "  which snapper also supports and this script does not set up). ext4"
        say "  has no snapshot mechanism at all, and a boot entry for a snapshot"
        say "  works by pointing at a subvolume — on ext4 there is nothing to"
        say "  point at."
        say ""
        say "  This is not something the installer can fix: it is decided when the"
        say "  disk is partitioned. Reinstall with a btrfs root and run this again."
        return 1
    fi
    ok "root is btrfs on $ROOT_SOURCE"
    return 0
}

# snapper takes snapshots OF a subvolume. A btrfs filesystem mounted at / with
# no subvol= — i.e. the top-level subvolid 5 mounted directly — cannot be
# snapshotted usefully: the snapshot would contain the snapshots.
#
# Measured-by-documentation, not by running it: this is why the Arch wiki's
# snapper page and every btrfs install guide put root on @ (or similar) rather
# than on the top level.
check_subvolume() {
    local subvol
    subvol="$(findmnt -no OPTIONS / 2>/dev/null | tr ',' '\n' | grep '^subvol=' | head -1 || true)"
    local subvolid
    subvolid="$(findmnt -no OPTIONS / 2>/dev/null | tr ',' '\n' | grep '^subvolid=' | head -1 || true)"

    if [ -z "$subvol" ] && [ -z "$subvolid" ]; then
        bad "root is btrfs but is not mounted from a subvolume."
        say "  The mount options carry no subvol= or subvolid=, which means the"
        say "  top level (subvolid 5) is mounted at /. Snapshotting that would"
        say "  produce snapshots that contain the previous snapshots."
        say "  A btrfs install wants root on its own subvolume, conventionally @."
        return 1
    fi
    # subvolid=5 is the top level even when a subvol= is also reported.
    if [ "$subvolid" = "subvolid=5" ]; then
        bad "root is mounted from the btrfs top level (subvolid 5)."
        say "  Same problem as above: put root on its own subvolume."
        return 1
    fi
    ok "root is a subvolume (${subvol:-$subvolid})"
    return 0
}

# /.snapshots is where snapper keeps them, and there are three valid states.
# The one that must not be guessed at is "a directory that is not a subvolume
# and not a mountpoint", because `snapper create-config` will refuse and the
# reason it gives is not obvious.
check_snapshots_dir() {
    if [ ! -e "$SNAP_DIR" ]; then
        ok "$SNAP_DIR does not exist yet — create-config will make it"
        return 0
    fi
    if findmnt -no TARGET "$SNAP_DIR" >/dev/null 2>&1; then
        ok "$SNAP_DIR is a mountpoint (an fstab-mounted subvolume)"
        return 0
    fi
    if btrfs subvolume show "$SNAP_DIR" >/dev/null 2>&1; then
        ok "$SNAP_DIR is already a btrfs subvolume"
        return 0
    fi
    bad "$SNAP_DIR exists but is neither a mountpoint nor a btrfs subvolume."
    say "  snapper will refuse to create its config against a plain directory."
    say "  Move it aside and re-run, or make it a subvolume deliberately."
    return 1
}

# limine is what puts a snapshot in front of you at boot. Without it the
# snapshots still exist and are still restorable from a live USB, so this is a
# WARNING and not a refusal — the difference matters, because a machine with
# snapshots and no boot menu is strictly better off than one with neither.
LIMINE_CONF=""
check_limine() {
    local c
    for c in "$LIMINE_ROOT"/boot/limine.conf "$LIMINE_ROOT"/boot/limine/limine.conf \
             "$LIMINE_ROOT"/boot/EFI/limine/limine.conf "$LIMINE_ROOT"/boot/limine.cfg; do
        [ -f "$c" ] && { LIMINE_CONF="$c"; break; }
    done
    if [ -z "$LIMINE_CONF" ]; then
        warn "no limine config found — snapshots will be created but will not"
        warn "appear as boot entries. They stay restorable from a live USB."
        return 0
    fi
    ok "limine config at $LIMINE_CONF"

    # The UKI case, which this repo's own machine is in. limine-snapper-sync
    # generates entries that select a snapshot with rootflags=subvol=…; a
    # unified kernel image carries its cmdline baked into the .efi, and which
    # of the two wins is a limine behaviour this script has NOT verified.
    # Flagged rather than worked around, because guessing here produces a boot
    # entry that silently boots the live system while claiming to be a snapshot
    # — the worst possible failure for this feature.
    if grep -qs 'path:.*\.efi' "$LIMINE_CONF" 2>/dev/null; then
        warn "this limine entry boots a UKI (a .efi with its cmdline baked in)."
        warn "Snapshot entries need the rootflags=subvol= of the snapshot to take"
        warn "effect. VERIFY after the first snapshot that the generated entry"
        warn "actually boots the snapshot and not the live system — check"
        warn "'btrfs subvolume get-default /' and the mounted subvol once booted."
    fi
    return 0
}

# ═════════════════════════════════════════════════════════════════════════
# The plan
# ═════════════════════════════════════════════════════════════════════════
say ""
say "System snapshots — checking this machine"
say ""

FAILED=0
check_btrfs        || FAILED=1
if [ "$FAILED" = 0 ]; then
    check_subvolume     || FAILED=1
    check_snapshots_dir || FAILED=1
    check_limine        || true     # never fatal, by design
fi

if [ "$FAILED" = 1 ]; then
    say ""
    bad "snapshots cannot be set up on this machine"
    exit 1
fi

say ""
say "What this would do:"
say "  · install snapper, snap-pac and btrfs-progs (repo) and"
say "    limine-snapper-sync (AUR)"
say "  · create snapper's 'root' config for /"
say "  · keep $RESTORE_POINTS restore points ($NUMBER_LIMIT snapshots: snap-pac"
say "    writes a pre/post pair per pacman transaction)"
say "  · turn OFF timeline snapshots — snapshots are taken before updates and"
say "    by hand, not hourly"
say "  · enable snapper-cleanup.timer and limine-snapper-sync.service"
say ""

if [ "$DRY" = 1 ]; then
    exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
    die "this needs root — run it with sudo"
fi

if [ "$ASSUME_YES" != 1 ]; then
    printf '  \033[1mProceed?\033[0m [y/N] '
    read -r ans </dev/tty || ans=""
    case "${ans,,}" in y|yes) ;; *) say "nothing was changed"; exit 0 ;; esac
fi

# ── packages ─────────────────────────────────────────────────────────────
say ""
say "installing packages…"
run pacman -S --needed --noconfirm snapper snap-pac btrfs-progs \
    || die "could not install snapper/snap-pac"

# limine-snapper-sync is AUR, so it needs a helper and an unprivileged user to
# build as — makepkg refuses to run as root, which is exactly the kind of thing
# that turns a root script into a confusing failure. Left to the caller, with
# the command spelled out, rather than half-attempted here.
if ! pacman -Q limine-snapper-sync >/dev/null 2>&1; then
    warn "limine-snapper-sync is an AUR package and is not installed."
    warn "It is what turns snapshots into limine boot entries. Install it as"
    warn "your normal user (not root):"
    warn "    yay -S limine-snapper-sync"
fi

# ── snapper's config for root ────────────────────────────────────────────
if [ -f /etc/snapper/configs/root ]; then
    say "snapper 'root' config already exists — leaving it in place"
else
    say "creating snapper's root config…"
    run snapper -c root create-config / || die "snapper create-config failed"
    ok "snapper root config created"
fi

# Rewritten with sed against the keys snapper ships, each one set rather than
# appended: appending a duplicate key to a snapper config is accepted silently
# and the LAST one wins, which makes a hand-edited config behave differently
# from a freshly generated one for no visible reason.
set_snapper() {
    local key="$1" val="$2" f=/etc/snapper/configs/root
    if [ "$DRY" = 1 ]; then printf '  \033[2mDRY\033[0m set %s="%s"\n' "$key" "$val"; return 0; fi
    if grep -q "^${key}=" "$f"; then
        sed -i "s|^${key}=.*|${key}=\"${val}\"|" "$f"
    else
        printf '%s="%s"\n' "$key" "$val" >>"$f"
    fi
}

say "setting retention to $RESTORE_POINTS restore points…"
set_snapper TIMELINE_CREATE      "no"
set_snapper TIMELINE_CLEANUP     "yes"
set_snapper NUMBER_CLEANUP       "yes"
set_snapper NUMBER_MIN_AGE       "0"
set_snapper NUMBER_LIMIT         "$NUMBER_LIMIT"
set_snapper NUMBER_LIMIT_IMPORTANT "$NUMBER_LIMIT"
ok "retention set"

# ── services ─────────────────────────────────────────────────────────────
# snapper-timeline.timer is deliberately NOT enabled: TIMELINE_CREATE is off,
# so it would wake up regularly to do nothing.
say "enabling services…"
run systemctl enable --now snapper-cleanup.timer || warn "could not enable snapper-cleanup.timer"

if pacman -Q limine-snapper-sync >/dev/null 2>&1; then
    run systemctl enable --now limine-snapper-sync.service \
        || warn "could not enable limine-snapper-sync.service"
fi

# ── report honestly ──────────────────────────────────────────────────────
say ""
ok "snapshots configured"
say ""
say "Verify it before trusting it:"
say "  snapper -c root list                 # should list snapshots"
say "  sudo snapper -c root create -d test  # take one by hand"
say "  sudo pacman -S --needed snapper      # a no-op transaction; snap-pac"
say "                                       # should still write a pre/post pair"
say ""
say "Then REBOOT and check the limine menu actually offers the snapshot, and"
say "that booting it lands you in the snapshot rather than the live system."
say "Until that has been seen working once, treat the boot half as unproven."
