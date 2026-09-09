#!/usr/bin/env bash
# vm-create.sh — create a libvirt VM from ANY ISO, tuned for this machine.
#
# The virt-manager wizard hard-stops at "You must select an OS" when libosinfo
# cannot identify the media, which reads like the VM failed to build. It did
# not: the OS selection only picks default device models, and never affects
# whether the ISO boots. osinfo-db carries ~970 entries and detects Debian,
# NixOS, Ubuntu, Fedora, openSUSE and Windows 10/11 unaided; Mint, Kali,
# EndeavourOS, Zorin, Garuda, CachyOS, Bazzite and Omarchy are simply absent.
# install/osinfo/ fills the gaps this machine cares about, and the fallback
# below covers everything else, so no ISO can dead-end.
#
# Usage: vm-create.sh <name> <iso> [ram_MB] [vcpus] [disk_GB]
#   VM_RES=1920x1080   override the guest EDID (default: this machine's panel)
set -euo pipefail
export LIBVIRT_DEFAULT_URI=qemu:///system

die() { printf 'vm-create: %s\n' "$*" >&2; exit 1; }

[ $# -ge 2 ] || die "usage: vm-create.sh <name> <iso> [ram_MB] [vcpus] [disk_GB]"
NAME=$1; ISO=$2; RAM=${3:-8192}; CPUS=${4:-6}; DISK=${5:-60}

[ -r "$ISO" ] || die "cannot read ISO: $ISO"
virsh dominfo "$NAME" >/dev/null 2>&1 && die "domain '$NAME' already exists"

virsh net-info default >/dev/null 2>&1 || die "libvirt 'default' network is not defined"
# An inactive default network is what produces "Network not active" at the last
# step of the wizard — the single most common reason a VM refuses to be created.
[ "$(virsh net-info default | awk '/^Active:/{print $2}')" = yes ] || virsh net-start default

# ── identify the guest ─────────────────────────────────────────────────
# ISO 9660 primary volume descriptor: sector 16, volume-id at +40, publisher
# at +318. Read directly because it is also what libosinfo matches on, so a
# failure here explains a failure there.
pvd() { dd if="$ISO" bs=1 skip=$((32768+$1)) count="$2" 2>/dev/null | tr -d '\0' | sed 's/ *$//'; }
VOLID=$(pvd 40 32); PUBID=$(pvd 318 128)

# timeout, because osinfo-detect hangs FOREVER on a truncated or corrupt ISO
# (libosinfo asserts 'buffer != NULL' in g_input_stream_read_async and never
# returns). An incomplete download must yield a fallback, not a frozen shell.
DETECTED=$(timeout 25 osinfo-detect -f plain "$ISO" 2>/dev/null \
           | sed -n "s/.*for OS '\(.*\)'.*/\1/p" | head -1 || true)

if printf '%s %s' "$VOLID" "$PUBID" | grep -qi 'microsoft\|CCCOMA\|CCSA_\|_X64FRE\|_A64FRE'; then
    GUEST=windows; FALLBACK=win11
else
    GUEST=linux;   FALLBACK=linux2024
fi

printf '  ISO        : %s\n' "$ISO"
printf '  volume-id  : %s\n' "${VOLID:-<none>}"
printf '  detected   : %s\n' "${DETECTED:-none — falling back to '$FALLBACK'}"
printf '  guest type : %s\n\n' "$GUEST"

# ── device profile ─────────────────────────────────────────────────────
# A Windows installer ships no virtio drivers, so it must be given devices it
# can already see or setup finds no disk and no network. Linux gets full virtio.
if [ "$GUEST" = windows ]; then
    DISK_BUS=sata; NET_MODEL=e1000e; VIDEO=qxl
    BOOT="uefi,loader=/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd,loader.secure=yes,firmware.feature0.name=enrolled-keys,firmware.feature0.enabled=no"
    # TPM 2.0 + SMM are Windows 11 install requirements, not preferences.
    EXTRA=(--tpm backend.type=emulator,backend.version=2.0 --features smm.state=on)
    for d in /usr/share/virtio-win/virtio-win.iso "$HOME/iso files/virtio-win.iso"; do
        [ -r "$d" ] && EXTRA+=(--disk "$d",device=cdrom,bus=sata) && break
    done
else
    DISK_BUS=virtio; NET_MODEL=virtio; VIDEO=virtio
    BOOT=uefi
    EXTRA=(--channel unix,target.type=virtio,target.name=org.qemu.guest_agent.0)
fi

set -x
virt-install \
    --name "$NAME" \
    --memory "$RAM" --vcpus "$CPUS" --cpu host-passthrough \
    --machine q35 --boot "$BOOT" \
    --osinfo "detect=on,name=$FALLBACK" \
    --disk "size=$DISK,format=qcow2,bus=$DISK_BUS,cache=writeback,discard=unmap,pool=default" \
    --cdrom "$ISO" \
    --network "network=default,model=$NET_MODEL" \
    --graphics spice --video "$VIDEO" \
    --sound ich9 --rng /dev/urandom \
    --noautoconsole \
    "${EXTRA[@]}"
set +x

# Tune before the guest's FIRST boot, so the installer itself comes up at the
# panel's resolution rather than 1280x800. virt-install has already started the
# domain by this point; it is seconds into firmware and nothing has been
# written, so stopping it costs nothing.
TUNE="$HOME/.config/scripts/vm-tune.sh"
if [ -z "${VM_CREATE_DRYRUN:-}" ] && [ -x "$TUNE" ]; then
    echo
    virsh destroy "$NAME" >/dev/null 2>&1 || true
    "$TUNE" "$NAME" ${VM_RES:+"$VM_RES"}
    virsh start "$NAME" >/dev/null
fi

echo
echo "Created '$NAME'. Open the console with:  virt-viewer $NAME"
