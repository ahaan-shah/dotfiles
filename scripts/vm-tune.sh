#!/usr/bin/env bash
# vm-tune.sh — point a libvirt guest's virtual display at THIS machine's panel,
# and turn on virgl so the guest renders on the iGPU instead of the CPU.
#
# Why this exists at all: QEMU's virtio-gpu synthesises the EDID the guest
# reads, and its defaults are literally `xres=1280 yres=800` (confirmed with
# `qemu-system-x86_64 -device virtio-vga,help`). The guest is not "failing to
# detect" the panel — there is nothing to detect, so it honours a monitor that
# claims to be 1280x800 and stays there. spice-vdagent normally papers over
# this by resizing on window resize, but that path needs compositor support
# that GNOME/mutter and X11 have and Hyprland does not — so on a Hyprland
# GUEST the resolution never moves. Setting the EDID makes native the
# *preferred* mode, so it applies at boot, in the TTY and at the greeter.
#
# Usage: vm-tune.sh <domain> [WIDTHxHEIGHT] [--no-gl]
set -euo pipefail
export LIBVIRT_DEFAULT_URI=qemu:///system

die() { printf 'vm-tune: %s\n' "$*" >&2; exit 1; }
[ $# -ge 1 ] || die "usage: vm-tune.sh <domain> [WIDTHxHEIGHT] [--no-gl]"

DOM=$1; shift
RES=""; NOGL=0
for a in "$@"; do
    case "$a" in
        --no-gl) NOGL=1 ;;
        *x*)     RES=$a ;;
        *)       die "unknown argument: $a" ;;
    esac
done

# Nothing machine-specific belongs in this script: the panel mode and the iGPU
# address are hardware facts, so they come from the generated profile and every
# lookup below falls back to something that works when it is missing.
# shellcheck disable=SC1091
[ -r "$HOME/.config/scripts/hardware.env" ] && . "$HOME/.config/scripts/hardware.env"

virsh dominfo "$DOM" >/dev/null 2>&1 || die "no such domain: $DOM"
[ "$(virsh domstate "$DOM")" = "shut off" ] || die "'$DOM' must be shut off first (virsh shutdown $DOM)"

# ── resolution ─────────────────────────────────────────────────────────
# MONITOR_MODE is "2880x1620@120"; the EDID takes only the WxH half. A TTY-
# written profile says "preferred", which carries no numbers — hence the live
# query behind it and the conservative literal behind that.
if [ -z "$RES" ]; then
    case "${MONITOR_MODE:-}" in
        [0-9]*x[0-9]*) RES=${MONITOR_MODE%@*} ;;
    esac
fi
if [ -z "$RES" ] && command -v hyprctl >/dev/null 2>&1; then
    RES=$(hyprctl monitors -j 2>/dev/null \
          | jq -r 'first(.[]|select(.disabled|not)) | "\(.width)x\(.height)"' 2>/dev/null) || RES=""
    [ "$RES" = "null" ] && RES=""
fi
[ -n "$RES" ] || RES=1920x1080

# ── render node ────────────────────────────────────────────────────────
# virgl must run on the GPU that drives the panel. On a hybrid laptop the
# discrete card also has a render node, and picking it would add a cross-GPU
# copy of every frame. Same by-path resolution hyprland.lua uses for
# AQ_DRM_DEVICES, for the same reason: renderD-numbering is not stable.
RNODE=""
if [ -n "${IGPU_PCI:-}" ]; then
    RNODE=$(readlink -f "/dev/dri/by-path/pci-$IGPU_PCI-render" 2>/dev/null || true)
    case "$RNODE" in /dev/dri/renderD[0-9]*) ;; *) RNODE="" ;; esac
fi
if [ -z "$RNODE" ]; then
    # No profile, or a machine whose by-path entry is missing: first node is
    # right on a single-GPU box and no worse than a guess on a hybrid one.
    RNODE=$(find /dev/dri -maxdepth 1 -name 'renderD*' | sort | head -1)
fi
[ -n "$RNODE" ] || die "no DRM render node found — is this a headless machine?"

BK="$HOME/.local/share/vm-backups"
mkdir -p "$BK"
virsh dumpxml "$DOM" > "$BK/$DOM-$(date +%Y%m%d-%H%M%S).xml"

python3 - "$DOM" "$RES" "$NOGL" "$RNODE" "$BK/.$DOM.new" <<'PY'
import sys, subprocess, xml.etree.ElementTree as ET

dom, res, nogl, rnode, outpath = sys.argv[1], sys.argv[2], sys.argv[3] == "1", sys.argv[4], sys.argv[5]
w, h = res.lower().split("x")
QNS = "http://libvirt.org/schemas/domain/qemu/1.0"
ET.register_namespace("qemu", QNS)

# --inactive, NOT the live dump. Dumping a running domain bakes runtime-resolved
# attributes into the XML; redefining from that pinned device='virtio-vga' onto
# the model, which overrides the accel3d device selection, so libvirt kept
# emitting the non-GL device while reporting acceleration as enabled. Measured:
# the first attempt produced virtio-vga with gl=on set and no virgl at all.
xml = subprocess.run(["virsh", "dumpxml", "--inactive", dom], check=True,
                     capture_output=True, text=True).stdout
root = ET.fromstring(xml)
devices = root.find("devices")

video = devices.find("video")
if video is None:
    sys.exit("domain has no <video> device")
model = video.find("model")
mtype = model.get("type", "")

# The override binds by alias. libvirt strips a user-set alias that is not
# "ua-"-prefixed, but the auto-generated name for the first video device is
# deterministically video0 and the override still binds to it — verified on the
# running QEMU command line.
alias = video.find("alias")
name = (alias.get("name") if alias is not None else None) or "video0"

# virgl needs a virtio-gpu driver in the guest. Windows has none, so a qxl
# guest gets the EDID fix alone rather than an acceleration it cannot use.
use_gl = (not nogl) and mtype == "virtio"

if use_gl:
    model.attrib.pop("device", None)          # see the --inactive note above
    accel = model.find("acceleration")
    if accel is None:
        accel = ET.SubElement(model, "acceleration")
    accel.set("accel3d", "yes")

    for g in devices.findall("graphics"):
        if g.get("type") != "spice":
            continue
        # SPICE GL is local-only — it cannot be consumed over a socket, and
        # libvirt refuses the combination. Drop any network listener.
        for attr in ("listen", "port", "tlsPort", "autoport"):
            g.attrib.pop(attr, None)
        for old in g.findall("listen"):
            g.remove(old)
        ET.SubElement(g, "listen").set("type", "none")
        gl = g.find("gl")
        if gl is None:
            gl = ET.SubElement(g, "gl")
        gl.set("enable", "yes")
        gl.set("rendernode", rnode)

# Re-runnable: replace our previous override rather than stacking a second one.
for old in root.findall(f"{{{QNS}}}override"):
    root.remove(old)
ov = ET.SubElement(root, f"{{{QNS}}}override")
dev = ET.SubElement(ov, f"{{{QNS}}}device"); dev.set("alias", name)
fe = ET.SubElement(dev, f"{{{QNS}}}frontend")
for prop, val in (("xres", w), ("yres", h)):
    p = ET.SubElement(fe, f"{{{QNS}}}property")
    p.set("name", prop); p.set("type", "unsigned"); p.set("value", val)

print(f"  video model : {mtype} (alias {name})", file=sys.stderr)
print(f"  EDID        : {w}x{h}", file=sys.stderr)
print(f"  virgl 3D    : {'on ' + rnode if use_gl else 'not enabled'}", file=sys.stderr)
open(outpath, "w").write(ET.tostring(root, encoding="unicode"))
PY

virsh define "$BK/.$DOM.new" >/dev/null
rm -f "$BK/.$DOM.new"
printf "  tuned '%s' — start it with: virsh start %s && virt-viewer %s\n" "$DOM" "$DOM" "$DOM"
