#!/usr/bin/env bash
# setup-hibernation.sh — enable hibernation (suspend-to-disk).
#
#   sudo ~/.config/scripts/setup-hibernation.sh            # do it
#   sudo ~/.config/scripts/setup-hibernation.sh --dry-run  # show the plan only
#   HIBERNATE_SWAP_GB=32 sudo -E ... setup-hibernation.sh  # override swap size
#
# WHY hibernation rather than deep S3 on the original machine: it offers
# "[s2idle] deep", but deep/S3 never wakes there — it needs a hard power-button
# reboot. Hibernation does not use that path: resume from disk is a full boot
# that restores an image, so the broken S3 wake path is never involved.
#
# EVERYTHING IS DETECTED, NOTHING IS ASSUMED. An earlier version of this script
# hardcoded this laptop's setup (Limine + UKI + ext4 + a 20G file) and would, on
# any other machine, edit /etc/fstab and mkinitcpio.conf and THEN abort when it
# could not find /boot/limine/limine.conf — leaving the system half-configured.
# So this version does all detection and validation FIRST, prints the plan, and
# only then touches anything.
#
# Idempotent: re-running changes nothing that is already correct.
set -euo pipefail

DRY=0; YES=0
case "${1:-}" in
    --dry-run) DRY=1 ;;
    --yes|-y)  YES=1 ;;   # skip the confirmation prompt (used by install.sh)
    "")        ;;
    *) echo "usage: $0 [--dry-run|--yes]" >&2; exit 2 ;;
esac
# --dry-run writes nothing, so it does not need root — which also means the
# detection can be checked on any machine before committing to a real run.
[ "$DRY" = 1 ] || [ "$(id -u)" = 0 ] || { echo "run as root: sudo $0 ${1:-}"; exit 1; }

SWAP="${HIBERNATE_SWAP_FILE:-/swapfile}"
STAMP=$(date +%Y%m%d-%H%M%S)

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\n\033[31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }
run()  { if [ "$DRY" = 1 ]; then printf '    DRY  %s\n' "$*"; else "$@"; fi; }

# ══════════════════════════════════════════════════════════════════════
# 0 · DETECT AND VALIDATE — no changes are made in this section
# ══════════════════════════════════════════════════════════════════════
say "0/6  checking this machine"

grep -qw disk /sys/power/state \
    || die "this kernel cannot hibernate (/sys/power/state has no 'disk'). Needs CONFIG_HIBERNATION=y."
info "kernel supports hibernation"

LOCKDOWN=$(cat /sys/kernel/security/lockdown 2>/dev/null || echo '[none]')
case "$LOCKDOWN" in
    *'[none]'*) info "kernel lockdown: none" ;;
    *) die "kernel lockdown is active ($LOCKDOWN) — it blocks hibernation. Usually means Secure Boot is on." ;;
esac

ROOTFS=$(findmnt -no FSTYPE /)
UUID=$(findmnt -no UUID /)
[ -n "$UUID" ] || die "could not determine the root filesystem UUID"
info "root: $ROOTFS, UUID=$UUID"

case "$ROOTFS" in
    ext4|xfs) OFFSET_METHOD=filefrag ;;
    btrfs)
        OFFSET_METHOD=btrfs
        btrfs inspect-internal map-swapfile --help >/dev/null 2>&1 \
            || die "btrfs root needs btrfs-progs >= 6.1 for 'inspect-internal map-swapfile'"
        info "btrfs detected — the swap file will be created nodatacow (chattr +C)"
        info "NOTE: it must live on a subvolume that is never snapshotted."
        ;;
    *) die "unsupported root filesystem '$ROOTFS' — set it up by hand" ;;
esac

# Swap must be able to hold the image. The image can grow to the whole of RAM in
# the worst case, so RAM size is the safe floor regardless of /sys/power/image_size
# (which is only a soft target the kernel tries to stay under).
RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
DEFAULT_GB=$(( (RAM_MB + 1023) / 1024 ))
[ "$DEFAULT_GB" -lt 2 ] && DEFAULT_GB=2
SIZE_GB="${HIBERNATE_SWAP_GB:-$DEFAULT_GB}"
info "RAM ${RAM_MB}M -> swap file target ${SIZE_GB}G"

if [ -f "$SWAP" ]; then
    HAVE_GB=$(( $(stat -c %s "$SWAP") / 1024 / 1024 / 1024 ))
    info "$SWAP already exists (${HAVE_GB}G) — it will be kept"
    [ "$HAVE_GB" -lt "$DEFAULT_GB" ] && \
        info "WARNING: ${HAVE_GB}G is smaller than RAM (${DEFAULT_GB}G); a large image may not fit"
else
    FREE_GB=$(df -BG --output=avail "$(dirname "$SWAP")" | tail -1 | tr -dc '0-9')
    [ "$FREE_GB" -gt "$((SIZE_GB + 5))" ] \
        || die "only ${FREE_GB}G free on $(dirname "$SWAP") — need ${SIZE_GB}G plus headroom"
    info "$FREE_GB G free, enough for a ${SIZE_GB}G file"
fi

# Which places carry the kernel command line on THIS machine? All that exist
# must be updated: on a UKI + Limine setup the bootloader passes its own cmdline
# via EFI LoadOptions, which OVERRIDES the one baked into the UKI — editing only
# /etc/kernel/cmdline silently does nothing.
CMDLINE_TARGETS=()
[ -f /etc/kernel/cmdline ] && CMDLINE_TARGETS+=("uki:/etc/kernel/cmdline")
for f in /boot/limine/limine.conf /boot/limine.conf /boot/EFI/limine/limine.conf; do
    [ -f "$f" ] && CMDLINE_TARGETS+=("limine:$f")
done
if [ -d /boot/loader/entries ]; then
    for f in /boot/loader/entries/*.conf; do
        [ -f "$f" ] && CMDLINE_TARGETS+=("sdboot:$f")
    done
fi
[ -f /etc/default/grub ] && CMDLINE_TARGETS+=("grub:/etc/default/grub")

[ "${#CMDLINE_TARGETS[@]}" -gt 0 ] \
    || die "found no kernel command line to edit (no /etc/kernel/cmdline, Limine, systemd-boot or GRUB config).
       Add 'resume=UUID=$UUID resume_offset=<offset>' to your bootloader by hand."
info "kernel cmdline lives in:"
for t in "${CMDLINE_TARGETS[@]}"; do info "  - ${t#*:}  (${t%%:*})"; done

command -v mkinitcpio >/dev/null || die "mkinitcpio not found — this script only supports mkinitcpio systems"
[ -f /etc/mkinitcpio.conf ] || die "/etc/mkinitcpio.conf not found"

if [ "$DRY" = 1 ]; then
    say "dry run — the plan above is everything that would change. Nothing was written."
    exit 0
fi

if [ "$YES" = 1 ]; then
    info "--yes given, proceeding without a prompt"
else
    printf '\n\033[1mProceed with these changes? [y/N] \033[0m'
    read -r ans </dev/tty || ans=""
    case "${ans,,}" in y|yes) ;; *) echo "aborted, nothing changed."; exit 0 ;; esac
fi

# ══════════════════════════════════════════════════════════════════════
say "1/6  swap file"
if [ -f "$SWAP" ]; then
    info "keeping the existing $SWAP"
else
    if [ "$OFFSET_METHOD" = btrfs ]; then
        # A btrfs swap file must be nodatacow and uncompressed. chattr +C only
        # takes effect on an EMPTY file, so set it before writing any data.
        truncate -s 0 "$SWAP"
        chattr +C "$SWAP"
    fi
    # fallocate leaves holes, which hibernation cannot write into. dd gives real
    # allocated blocks.
    info "allocating ${SIZE_GB}G (takes a minute)…"
    dd if=/dev/zero of="$SWAP" bs=1M count=$((SIZE_GB*1024)) status=progress
    chmod 600 "$SWAP"
    mkswap "$SWAP"
fi
swapon --show=NAME --noheadings | grep -qx "$SWAP" || swapon "$SWAP" --priority 10
# priority 10 sits BELOW zram's default 100, so ordinary swapping still prefers
# zram and this file is reserved for the hibernation image.
if ! grep -q "^$SWAP[[:space:]]" /etc/fstab; then
    cp /etc/fstab "/etc/fstab.bak-$STAMP"
    echo "$SWAP none swap defaults,pri=10 0 0" >> /etc/fstab
    info "fstab entry added (backup: /etc/fstab.bak-$STAMP)"
fi

# ══════════════════════════════════════════════════════════════════════
say "2/6  resume offset"
if [ "$OFFSET_METHOD" = btrfs ]; then
    OFFSET=$(btrfs inspect-internal map-swapfile -r "$SWAP")
else
    # extent 0's physical_offset
    OFFSET=$(filefrag -v "$SWAP" | awk '/ 0:/{gsub(/\./,"",$4); print $4; exit}')
fi
[ -n "$OFFSET" ] || die "could not determine the resume offset for $SWAP"
RESUME_ARGS="resume=UUID=$UUID resume_offset=$OFFSET"
info "$RESUME_ARGS"

# ══════════════════════════════════════════════════════════════════════
say "3/6  mkinitcpio resume hook"
if grep -qE '^HOOKS=.*\bresume\b' /etc/mkinitcpio.conf; then
    info "already present"
else
    cp /etc/mkinitcpio.conf "/etc/mkinitcpio.conf.bak-$STAMP"
    # `resume` is a pre-mount hook and needs block devices available, so it goes
    # after `block` (confirmed with `mkinitcpio -H resume`).
    sed -i -E 's/^(HOOKS=\(.*\bblock\b)/\1 resume/' /etc/mkinitcpio.conf
    grep -E '^HOOKS=' /etc/mkinitcpio.conf | sed 's/^/    /'
    grep -qE '^HOOKS=.*\bresume\b' /etc/mkinitcpio.conf \
        || die "failed to add the resume hook — add it after 'block' in /etc/mkinitcpio.conf by hand"
fi

# ══════════════════════════════════════════════════════════════════════
say "4/6  kernel command line"
NEED_GRUB_REGEN=0
for target in "${CMDLINE_TARGETS[@]}"; do
    kind="${target%%:*}"; f="${target#*:}"
    if grep -q 'resume=' "$f"; then info "$f already has resume="; continue; fi
    cp "$f" "$f.bak-$STAMP"
    case "$kind" in
        uki)    sed -i "1s|\$| $RESUME_ARGS|" "$f" ;;
        limine) sed -i -E "s|^(\s*cmdline:.*)\$|\1 $RESUME_ARGS|" "$f" ;;
        sdboot) sed -i -E "s|^(options\s+.*)\$|\1 $RESUME_ARGS|" "$f" ;;
        grub)   sed -i -E "s|^(GRUB_CMDLINE_LINUX_DEFAULT=\")(.*)(\")\$|\1\2 $RESUME_ARGS\3|" "$f"
                NEED_GRUB_REGEN=1 ;;
    esac
    grep -q 'resume=' "$f" && info "updated $f" \
        || info "WARNING: could not insert into $f — add '$RESUME_ARGS' by hand"
done

# ══════════════════════════════════════════════════════════════════════
say "5/6  rebuild initramfs"
mkinitcpio -P
if [ "$NEED_GRUB_REGEN" = 1 ] && command -v grub-mkconfig >/dev/null; then
    info "regenerating grub.cfg"
    grub-mkconfig -o /boot/grub/grub.cfg
fi

# ══════════════════════════════════════════════════════════════════════
say "6/6  done — reboot, then test"
cat <<MSG
    Reboot first: the resume hook and the cmdline only take effect next boot.

    After rebooting, verify:
        cat /proc/cmdline           # must show resume= and resume_offset=
        cat /proc/swaps             # must list $SWAP
        sudo systemctl hibernate

    It should power off COMPLETELY — fans silent, lights out, power button
    needed. Press power: you should land back in your session, not a fresh boot.

    Reading the log afterwards is misleading; a SUCCESSFUL hibernate shows:
      - no "PM: Image saved" lines (they are printed after the snapshot, so they
        cannot survive into the resumed system)
      - "Preparing to enter system sleep state S4" immediately followed by
        "Waking up from system sleep state S4" — that pair is create_image()'s
        internal dpm_suspend/dpm_resume, not a failure
      - a ~minute gap with an unchanged boot_id (both are by design)
    The decisive check is physical: did the machine actually power off?

    If it powers off but returns as a FRESH boot, the image was written but not
    found — recheck /proc/cmdline and that the resume hook made it into the
    initramfs.

    If hibernating misbehaves, try the non-ACPI path:
        echo shutdown | sudo tee /sys/power/disk
    "shutdown" skips ACPI S4 and just powers off, which is safer on firmware
    with a broken sleep path.

    To undo: restore the .bak-$STAMP files this script made, then
        swapoff $SWAP && rm $SWAP && mkinitcpio -P
MSG
