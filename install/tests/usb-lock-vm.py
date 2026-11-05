#!/usr/bin/env python3
"""usb-lock-vm.py — hyprahaan-usb-lock against a REAL kernel and REAL USB hotplug.

usb-lock-cases.sh proves the helper's decisions on a fake tree. Only a kernel can
prove the point of it: that a device plugged in while locked gets no driver. That
needs root and a stick in a port, or this: the running kernel in a throwaway QEMU
guest, where the helper is root and QEMU's monitor plugs virtual devices into a
virtual xHCI. No root on the host, no host USB, no disk images kept, no network.

    install/tests/usb-lock-vm.py      exits 0 if every case passed

What it CANNOT prove: authorized_default=2 letting a HARDWIRED device through.
QEMU reports its ports as "unknown", so everything in the guest counts as external.
That half rests on the kernel's own parameter text ("2 is authorized for internal
devices") and on a test on the real machine.

The guest is an initramfs built from this machine's own binaries, so it is the same
kernel, the same coreutils and the same lsblk the helper will really use.
"""
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
HELPER = HERE.parent / "system/bin/hyprahaan-usb-lock"
KVER = os.uname().release
KERNEL = Path(f"/usr/lib/modules/{KVER}/vmlinuz")
BINS = """bash cat ls mkdir rm find readlink lsblk logger flock id dirname grep sleep
          mount umount seq date tr sed basename insmod head wc""".split()
# Loaded by hand: the guest has no udev to autoload them. evdev gives /sys/class/input/event*.
MODULES = ["usb-storage", "usbhid", "hid-generic", "evdev"]

# ── what runs inside the guest ───────────────────────────────────────────
INIT = r'''#!/usr/bin/bash
export PATH=/usr/bin
mkdir -p /proc /sys /dev /run /mnt /tmp
mount -t proc proc /proc; mount -t sysfs sys /sys; mount -t devtmpfs dev /dev
ln -s /proc/self/fd /dev/fd
for m in /modules/*; do insmod "$m" 2>/dev/null; done
pass=0; fail=0
t() { if eval "$2"; then pass=$((pass+1)); echo "PASS $1"; else fail=$((fail+1)); echo "FAIL $1   [$2]"; fi; }
want() { echo "@@WANT $1"; }           # asks the host to plug or unplug something
waitfor() { local i; for i in $(seq 1 100); do eval "$1" && return 0; sleep 0.1; done; return 1; }
D=/sys/bus/usb/devices
auth() { cat "$D/$1/authorized" 2>/dev/null; }
hasblock() { ls "$D/$1/$1:1.0/"host*/target*/*/block 2>/dev/null | grep -q sd; }
bound() { [ -e "$D/$1/$1:1.0/driver" ]; }
blockname() { ls "$D/$1/$1:1.0/"host*/target*/*/block 2>/dev/null | head -1; }

# QEMU's sticks are SuperSpeed, so bus 2; its keyboard is full speed, so bus 1.
# Sticks at boot: 2-1 unmounted, 2-2 to be mounted. Hot-plugged: 2-3, keyboard 1-4.
waitfor 'hasblock 2-1 && hasblock 2-2' || echo "FAIL boot sticks never appeared"
t "before lock: controller open" '[ "$(cat $D/usb1/authorized_default)$(cat $D/usb2/authorized_default)" = 11 ]'
t "before lock: stick 2-1 has a disk" 'hasblock 2-1'
mount "/dev/$(blockname 2-2)" /mnt; t "before lock: stick 2-2 mounted" 'grep -q " /mnt " /proc/mounts'

# The helper refuses a machine with no keyboard outside USB, and udev is not running
# here, so hand it the record udev would have written for the PS/2 keyboard.
mkdir -p /run/udev/data
for e in /sys/class/input/event*; do
    case "$(readlink -f $e/device)" in */i8042/*) echo "E:ID_INPUT_KEYBOARD=1" >"/run/udev/data/c$(cat $e/dev)" ;; esac
done

hyprahaan-usb-lock lock; t "lock exits 0" "[ $? = 0 ]"
t "locked: controller is internal-only" '[ "$(cat $D/usb1/authorized_default)$(cat $D/usb2/authorized_default)" = 22 ]'
t "locked: module default is internal-only" '[ "$(cat /sys/module/usbcore/parameters/authorized_default)" = 2 ]'
t "locked: unmounted stick went offline" '[ "$(auth 2-1)" = 0 ] && ! hasblock 2-1'
t "locked: mounted stick stayed up" '[ "$(auth 2-2)" = 1 ] && hasblock 2-2'
t "locked: its files still read" 'ls /mnt >/dev/null'
t "status reports locked" 'hyprahaan-usb-lock status | grep -q "state: locked"'

want plug-stick; waitfor '[ -e $D/2-3/authorized ]' || echo "FAIL stick never seen by the kernel"
sleep 1
t "NEW STICK while locked: seen, not authorised" '[ "$(auth 2-3)" = 0 ]'
t "NEW STICK while locked: no driver bound" '! bound 2-3'
t "NEW STICK while locked: no disk exists" '! hasblock 2-3'
n=$(lsblk -nd -o NAME | grep -c "^sd"); t "NEW STICK while locked: only the mounted disk is visible" '[ "$n" = 1 ]'

i0=$(ls /sys/class/input | grep -c event)
want plug-keyboard; waitfor '[ -e $D/1-4/authorized ]' || echo "FAIL keyboard never seen by the kernel"
sleep 1
t "NEW KEYBOARD while locked: not authorised" '[ "$(auth 1-4)" = 0 ]'
t "NEW KEYBOARD while locked: no driver bound" '! bound 1-4'
t "NEW KEYBOARD while locked: no input device" '[ "$(ls /sys/class/input | grep -c event)" = "$i0" ]'

# Suspend then resume runs lock twice.
hyprahaan-usb-lock lock; t "second lock exits 0" "[ $? = 0 ]"
hyprahaan-usb-lock unlock; t "unlock exits 0" "[ $? = 0 ]"
t "unlocked: controller restored" '[ "$(cat $D/usb1/authorized_default)$(cat $D/usb2/authorized_default)" = 11 ]'
t "unlocked: module default restored" '[ "$(cat /sys/module/usbcore/parameters/authorized_default)" = 1 ]'
waitfor 'hasblock 2-1'; t "unlocked: the stick lock took offline is back" '[ "$(auth 2-1)" = 1 ] && hasblock 2-1'
t "unlocked: stick plugged in while locked STAYS dead" '[ "$(auth 2-3)" = 0 ] && ! hasblock 2-3'
t "unlocked: keyboard plugged in while locked STAYS dead" '[ "$(auth 1-4)" = 0 ] && ! bound 1-4'
t "status reports open" 'hyprahaan-usb-lock status | grep -q "state: open"'
t "state removed" '[ ! -e /run/hyprahaan-usb-lock ]'

want unplug-stick; waitfor '[ ! -e $D/2-3 ]'; want replug-stick
waitfor 'hasblock 2-3'; t "replugged after unlock: works normally" '[ "$(auth 2-3)" = 1 ] && hasblock 2-3'
want unplug-keyboard; waitfor '[ ! -e $D/1-4 ]'; want plug-keyboard
waitfor 'bound 1-4'; t "keyboard replugged after unlock: works normally" '[ "$(auth 1-4)" = 1 ] && bound 1-4'

# A different device in a port lock took offline must not inherit the approval.
want unplug-keyboard; waitfor '[ ! -e $D/1-4 ]'
hyprahaan-usb-lock lock
waitfor '[ "$(auth 2-1)" = 0 ]'
want unplug-first; waitfor '[ ! -e $D/2-1 ]'; want plug-first
waitfor '[ -e $D/2-1/authorized ]'; sleep 1
t "swapped into a blocked port: not authorised" '[ "$(auth 2-1)" = 0 ]'
hyprahaan-usb-lock unlock
sleep 1
t "swapped into a blocked port: stays dead after unlock" '[ "$(auth 2-1)" = 0 ] && ! hasblock 2-1'

# No safe keyboard: it must refuse to block, and say so.
rm -rf /run/udev/data
hyprahaan-usb-lock lock 2>/dev/null; rc=$?
t "no safe keyboard: reported as failure" "[ $rc = 1 ]"
t "no safe keyboard: new USB stays allowed" '[ "$(cat $D/usb1/authorized_default)$(cat $D/usb2/authorized_default)" = 11 ]'
hyprahaan-usb-lock unlock

umount /mnt
echo "@@DONE pass=$pass fail=$fail"
sleep 1  # or the kernel's power-off line lands inside the result line above
echo o >/proc/sysrq-trigger
sleep 5
'''

PLUG = {
    "plug-stick": "device_add usb-storage,bus=xhci.0,port=3,drive=d3,id=s3,removable=on",
    "unplug-stick": "device_del s3",
    # device_del takes a -drive with it, so a replug needs a drive of its own.
    "replug-stick": "device_add usb-storage,bus=xhci.0,port=3,drive=d4,id=s4,removable=on",
    "plug-keyboard": "device_add usb-kbd,bus=xhci.0,port=4,id=k4",
    "unplug-keyboard": "device_del k4",
    "plug-first": "device_add usb-storage,bus=xhci.0,port=1,drive=d5,id=s5",
    "unplug-first": "device_del s1",
}


def run(*a):
    return subprocess.run(a, check=True, capture_output=True, text=True).stdout


def build(root: Path):
    """Initramfs from this machine's binaries and their libraries."""
    (root / "usr/bin").mkdir(parents=True)
    (root / "usr/lib").mkdir()
    (root / "modules").mkdir()
    os.symlink("usr/lib", root / "lib")
    os.symlink("usr/lib", root / "lib64")
    os.symlink("usr/bin", root / "bin")
    libs = set()
    for b in BINS:
        p = shutil.which(b)
        if not p:
            sys.exit(f"missing {b}")
        shutil.copy2(os.path.realpath(p), root / "usr/bin" / b)
        # copy2 keeps mount's setuid bit, and as our file it would drop the guest's
        # root to this uid ("must be superuser to use mount").
        (root / "usr/bin" / b).chmod(0o755)
        for m in re.finditer(r"(/\S+\.so\S*)", run("ldd", p)):
            libs.add(m.group(1))
    for lib in libs:
        shutil.copy2(os.path.realpath(lib), root / "usr/lib" / os.path.basename(lib))
    shutil.copy2(HELPER, root / "usr/bin/hyprahaan-usb-lock")
    n = 0
    for m in MODULES:
        path = subprocess.run(["modinfo", "-n", m], capture_output=True, text=True).stdout.strip()
        if path and path != "(builtin)":
            n += 1
            shutil.copy2(path, root / "modules" / f"{n}-{os.path.basename(path)}")
    (root / "init").write_text(INIT)
    (root / "init").chmod(0o755)
    (root / "usr/bin/hyprahaan-usb-lock").chmod(0o755)
    listing = subprocess.run(["find", ".", "-print0"], cwd=root, capture_output=True, check=True).stdout
    img = root.parent / "init.cpio"
    with open(img, "wb") as f:
        subprocess.run(["cpio", "--null", "-o", "-H", "newc", "--quiet", "--owner=0:0"], cwd=root,
                       input=listing, stdout=f, check=True)
    return img


def main():
    tmp = Path(tempfile.mkdtemp(prefix="usb-lock-vm-"))
    proc = None
    try:
        img = build(tmp / "root")
        for d in ("d1", "d2", "d3", "d4", "d5"):
            with open(tmp / d, "wb") as f:
                f.truncate(32 << 20)
        subprocess.run(["mke2fs", "-q", "-F", str(tmp / "d2")], check=True)
        mon = tmp / "mon"
        serial = tmp / "serial"
        cmd = ["qemu-system-x86_64", "-m", "1024", "-smp", "2", "-display", "none", "-no-reboot",
               "-nic", "none", "-kernel", str(KERNEL), "-initrd", str(img),
               "-append", "console=ttyS0 rdinit=/init panic=-1 quiet sysrq_always_enabled=1",
               "-serial", f"file:{serial}", "-monitor", f"unix:{mon},server,nowait",
               "-device", "qemu-xhci,id=xhci"]
        if os.access("/dev/kvm", os.W_OK):
            cmd += ["-enable-kvm", "-cpu", "host"]
        for d in ("d1", "d2", "d3", "d4", "d5"):
            cmd += ["-drive", f"if=none,id={d},file={tmp / d},format=raw"]
        cmd += ["-device", "usb-storage,bus=xhci.0,port=1,drive=d1,id=s1,removable=on",
                "-device", "usb-storage,bus=xhci.0,port=2,drive=d2,id=s2"]
        proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        for _ in range(100):
            if mon.exists():
                break
            time.sleep(0.1)
        s = socket.socket(socket.AF_UNIX)
        s.connect(str(mon))
        seen, done, buf = 0, None, ""
        deadline = time.time() + 150
        while time.time() < deadline and proc.poll() is None:
            text = serial.read_text(errors="replace") if serial.exists() else ""
            new, seen = text[seen:], len(text)
            buf += new
            *lines, buf = buf.split("\n")
            for line in lines:
                line = line.strip()
                if line.startswith(("PASS ", "FAIL ")):
                    print(line)
                elif line.startswith("@@WANT "):
                    s.sendall((PLUG[line.split()[1]] + "\n").encode())
                elif line.startswith("@@DONE"):
                    done = line
            if done:
                break
            time.sleep(0.05)
        if not done:
            print("guest did not finish. Last output:")
            print("\n".join((serial.read_text(errors="replace") if serial.exists() else "").splitlines()[-15:]))
            return 1
        print(done.replace("@@DONE ", "guest: "))
        return 0 if done.endswith("fail=0") else 1
    finally:
        if proc and proc.poll() is None:
            proc.kill()
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
