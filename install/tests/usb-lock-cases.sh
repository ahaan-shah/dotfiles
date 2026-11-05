#!/usr/bin/env bash
# usb-lock-cases.sh — drives install/system/bin/hyprahaan-usb-lock on a fake sysfs
# tree. Needs no root and touches no real USB. It proves the helper's decisions, NOT
# that the kernel honours authorized_default=2: that takes a real stick in a real
# port, with the screen unlocked.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
source "$HERE/../system/bin/hyprahaan-usb-lock"
set +e
PATH_REAL=$PATH
log() { :; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: expected '$3', got '$2'"; }

# Mounted disks are named in $T/mounted, replacing lsblk.
block_mounted() { grep -qsx "$1" "$T/mounted"; }

add_dev() { # name devnum class [block-name]
    local d=$USB_ROOT/$1
    mkdir -p "$d/$1:1.0"
    echo 1 >"$d/authorized"; echo "$2" >"$d/devnum"; echo "$3" >"$d/$1:1.0/bInterfaceClass"
    echo 1234 >"$d/idVendor"; echo 5678 >"$d/idProduct"; echo "dev $1" >"$d/product"
    [ -n "${4:-}" ] && mkdir -p "$d/$1:1.0/host0/block/$4"
}

add_kbd() { # event-number path-under-root
    mkdir -p "$INPUT_ROOT/event$1" "$T/devices/$2"
    echo "13:$1" >"$INPUT_ROOT/event$1/dev"
    ln -s "$T/devices/$2" "$INPUT_ROOT/event$1/device"
    echo "E:ID_INPUT_KEYBOARD=1" >"$UDEV_DATA/c13:$1"
}

fresh() {
    rm -rf "$T"/* ; : >"$T/mounted"
    USB_ROOT=$T/usb; USB_PARAM=$T/param; INPUT_ROOT=$T/input; UDEV_DATA=$T/udev; STATE=$T/state
    mkdir -p "$USB_ROOT/usb1" "$USB_ROOT/usb2" "$INPUT_ROOT" "$UDEV_DATA"
    echo 1 >"$USB_ROOT/usb1/authorized_default"; echo 1 >"$USB_ROOT/usb2/authorized_default"
    echo 1 >"$USB_PARAM"
}

# This machine's shape: PS/2 keyboard, a hardwired sensor, a hardwired card reader.
laptop() {
    fresh
    add_kbd 3 platform/i8042/serio0
    add_dev 3-5 2 ff
    add_dev 4-2 3 08
}

# ── blocking ──────────────────────────────────────────────────────────────
laptop; cmd_lock; rc=$?
eq "lock exit" "$rc" 0
eq "usb1 blocked to internal-only" "$(cat "$USB_ROOT/usb1/authorized_default")" 2
eq "usb2 blocked to internal-only" "$(cat "$USB_ROOT/usb2/authorized_default")" 2
eq "later controllers covered" "$(cat "$USB_PARAM")" 2
eq "fingerprint sensor untouched" "$(cat "$USB_ROOT/3-5/authorized")" 1
eq "unmounted card reader offline" "$(cat "$USB_ROOT/4-2/authorized")" 0

# ── lifting it ────────────────────────────────────────────────────────────
cmd_unlock; rc=$?
eq "unlock exit" "$rc" 0
eq "usb1 restored" "$(cat "$USB_ROOT/usb1/authorized_default")" 1
eq "module default restored" "$(cat "$USB_PARAM")" 1
eq "card reader back" "$(cat "$USB_ROOT/4-2/authorized")" 1
[ -e "$STATE" ] && bad "state left after unlock" || ok

# ── lock runs twice (suspend, then resume) and must not save its own 2 ───
laptop; cmd_lock; cmd_lock; cmd_unlock
eq "second lock keeps the original default" "$(cat "$USB_ROOT/usb1/authorized_default")" 1
eq "second lock keeps the module default" "$(cat "$USB_PARAM")" 1

# ── a default other than 1 comes back as it was ──────────────────────────
laptop; echo 0 >"$USB_ROOT/usb2/authorized_default"; cmd_lock; cmd_unlock
eq "non-default value restored" "$(cat "$USB_ROOT/usb2/authorized_default")" 0

# ── a card reader re-enumerated on resume is taken offline again ─────────
laptop; cmd_lock; echo 1 >"$USB_ROOT/4-2/authorized"; echo 9 >"$USB_ROOT/4-2/devnum"; cmd_lock
eq "re-enumerated reader offline" "$(cat "$USB_ROOT/4-2/authorized")" 0
cmd_unlock
eq "and restored at its new devnum" "$(cat "$USB_ROOT/4-2/authorized")" 1

# ── mounted storage stays up ──────────────────────────────────────────────
laptop; add_dev 1-1 7 08 sdb; echo sdb >"$T/mounted"; cmd_lock
eq "mounted disk stays" "$(cat "$USB_ROOT/1-1/authorized")" 1
cmd_unlock

laptop; add_dev 1-1 7 08 sdb; cmd_lock
eq "unmounted external disk offline" "$(cat "$USB_ROOT/1-1/authorized")" 0
cmd_unlock
eq "unmounted external disk back" "$(cat "$USB_ROOT/1-1/authorized")" 1

# ── an empty reader: sysfs dirs under block/ must not read as disks ──────
laptop; add_dev 1-1 7 08 sdb; mkdir -p "$USB_ROOT/1-1/1-1:1.0/host0/block/sdb/power" "$USB_ROOT/1-1/1-1:1.0/host0/block/sdb/queue"
echo power >"$T/mounted"; cmd_lock
eq "a sysfs subdir is not a mounted disk" "$(cat "$USB_ROOT/1-1/authorized")" 0
cmd_unlock

# ── a device plugged in while locked stays dead after unlock ─────────────
laptop; cmd_lock; add_dev 1-2 8 03; echo 0 >"$USB_ROOT/1-2/authorized"; cmd_unlock
eq "device plugged in while locked stays blocked" "$(cat "$USB_ROOT/1-2/authorized")" 0

# ── a different device swapped into a port we took offline gets nothing ──
laptop; add_dev 1-1 7 08; cmd_lock; echo 12 >"$USB_ROOT/1-1/devnum"; cmd_unlock
eq "swapped device does not inherit approval" "$(cat "$USB_ROOT/1-1/authorized")" 0

# ── never strand a machine with nothing to type on ───────────────────────
fresh; add_dev 1-1 7 03
mkdir -p "$USB_ROOT/1-1/port"; echo hotplug >"$USB_ROOT/1-1/port/connect_type"
add_kbd 4 pci/usb1/1-1/1-1:1.0/input
mkdir -p "$T/devices/pci/usb1/1-1/port"; echo hotplug >"$T/devices/pci/usb1/1-1/port/connect_type"
cmd_lock; rc=$?
eq "external-only keyboard: default left open" "$(cat "$USB_ROOT/usb1/authorized_default")" 1
eq "external-only keyboard: reported as failure" "$rc" 1

fresh; add_kbd 4 pci/usb1/1-1/1-1:1.0/input
mkdir -p "$T/devices/pci/usb1/1-1/port"; echo hardwired >"$T/devices/pci/usb1/1-1/port/connect_type"
cmd_lock
eq "hardwired USB keyboard counts as safe" "$(cat "$USB_ROOT/usb1/authorized_default")" 2

fresh; add_kbd 5 virtual/input/keyd
cmd_lock
eq "a virtual keyboard alone does not count" "$(cat "$USB_ROOT/usb1/authorized_default")" 1

fresh; cmd_lock; rc=$?
eq "no keyboard at all: default left open" "$(cat "$USB_ROOT/usb1/authorized_default")" 1
eq "no keyboard at all: reported" "$rc" 1

fresh; mkdir -p "$INPUT_ROOT/event6" "$T/devices/platform/asus-wmi"; echo "13:6" >"$INPUT_ROOT/event6/dev"
ln -s "$T/devices/platform/asus-wmi" "$INPUT_ROOT/event6/device"; echo "E:ID_INPUT_KEY=1" >"$UDEV_DATA/c13:6"
cmd_lock
eq "hotkey device is not a keyboard" "$(cat "$USB_ROOT/usb1/authorized_default")" 1

# ── blocking nothing must never read as success ──────────────────────────
laptop; rm -rf "$USB_ROOT/usb1" "$USB_ROOT/usb2"; cmd_lock; rc=$?
eq "no controller took the block: reported" "$rc" 1

# ── a write the kernel refuses is reported, never assumed ────────────────
laptop
controllers() { echo "$T/stuck"; }
mkdir -p "$T/stuck"; echo 1 >"$T/stuck/authorized_default"; chmod 444 "$T/stuck/authorized_default"
if [ "$(id -u)" -ne 0 ]; then
    cmd_lock; rc=$?
    eq "refused write is a failure" "$rc" 1
fi
chmod 644 "$T/stuck/authorized_default"
unset -f controllers
# shellcheck source=/dev/null
source "$HERE/../system/bin/hyprahaan-usb-lock"; set +e; log() { :; }; block_mounted() { grep -qsx "$1" "$T/mounted"; }

# ── status ────────────────────────────────────────────────────────────────
USB_ROOT=$T/usb; USB_PARAM=$T/param; INPUT_ROOT=$T/input; UDEV_DATA=$T/udev; STATE=$T/state
laptop; cmd_lock; out=$(cmd_status)
case "$out" in *"state: locked"*"usb1 authorized_default=2"*"blocked 4-2"*) ok ;; *) bad "status: $out" ;; esac
cmd_unlock

PATH=$PATH_REAL
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
