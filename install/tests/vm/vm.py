#!/usr/bin/env python3
"""vm.py — drive a throwaway QEMU guest for the installer's end-to-end test.

Exists because the failures that matter here only happen on a machine that has
none of this desktop on it (see the "What a VM run found" section of the map),
and because the machine doing the testing must not be able to be hurt by it.
So, on purpose:

  * QEMU runs as the invoking user in a transient systemd unit with a memory cap
    and low CPU/IO weight. No sudo, no libvirt, no bridge, no host mounts.
  * Networking is user-mode (SLIRP). The only forward is 127.0.0.1:2222 -> :22,
    and the guest reaches the host only as 10.0.2.2, i.e. host loopback.
  * Every file lives under $VMTEST_DIR (default ~/.cache/hyprahaan-vmtest), on
    disk rather than in tmpfs, because the image grows to tens of GB. Delete
    that directory and nothing is left.

  vm.py new                       fresh 100G disk, wipes the old one
  vm.py overlay <name>            freeze the disk as <name>, keep writing on top
  vm.py rollback <name>           drop everything since overlay <name>
  vm.py iso | disk                boot the Arch ISO / the installed disk
  vm.py stop                      power off (hard)
  vm.py serial '<command>'        type a line on the serial console
  vm.py expect '<regex>' [secs]   wait for output on the serial console
  vm.py ssh <user> '<command>'    run a command in the guest
  vm.py shot <file.png>           screenshot of the guest display
  vm.py keys <k> <k+k> ...        press keys (QEMU qcodes, e.g. ret, meta_l+q)
  vm.py type '<text>'             type text on the guest keyboard
"""
import json, os, re, shutil, socket, subprocess, sys, time
from pathlib import Path

D = Path(os.environ.get("VMTEST_DIR", Path.home() / ".cache/hyprahaan-vmtest"))
ISO = Path(os.environ.get("VMTEST_ISO", Path.home() / "iso files/archlinux-2026.08.01-x86_64.iso"))
UNIT = "hyprahaan-vmtest"
RAM, CPUS, CAP = os.environ.get("VMTEST_RAM", "6G"), os.environ.get("VMTEST_CPUS", "8"), "8G"
DISK, KEY = D / "disk.qcow2", D / "id_ed25519"
SER_LOG, SER_SOCK, QMP = D / "serial.log", D / "serial.sock", D / "qmp.sock"
SSH = ["ssh", "-i", str(KEY), "-p", "2222", "-o", "StrictHostKeyChecking=no",
       "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR",
       "-o", "ConnectTimeout=8", "-o", "ServerAliveInterval=20"]


def sh(*a, **k):
    return subprocess.run(a, check=True, **k)


def running():
    return subprocess.run(["systemctl", "--user", "is-active", "--quiet", UNIT]).returncode == 0


def setup():
    D.mkdir(parents=True, exist_ok=True)
    if not KEY.exists():
        sh("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(KEY))
    vars_ = D / "OVMF_VARS.fd"
    if not vars_.exists():
        shutil.copy("/usr/share/edk2/x64/OVMF_VARS.4m.fd", vars_)


def boot(extra):
    if running():
        sys.exit("already running")
    setup()
    for p in (SER_SOCK, QMP):
        p.unlink(missing_ok=True)
    SER_LOG.write_bytes(b"")
    # The serial pump: QEMU writes the socket; pump.py appends to the log.
    cmd = ["systemd-run", "--user", f"--unit={UNIT}", "--collect", "--quiet",
           "-p", f"MemoryMax={CAP}", "-p", "CPUWeight=40", "-p", "IOWeight=40", "-p", "Nice=5",
           "qemu-system-x86_64", "-enable-kvm", "-machine", "q35", "-cpu", "host",
           "-m", RAM, "-smp", CPUS, "-name", UNIT,
           "-drive", "if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd",
           "-drive", f"if=pflash,format=raw,file={D}/OVMF_VARS.fd",
           "-drive", f"file={DISK},if=virtio,format=qcow2,cache=writeback,discard=unmap",
           "-netdev", "user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22",
           "-device", "virtio-net-pci,netdev=n0",
           "-device", os.environ.get("VMTEST_GPU", "virtio-vga,xres=1920,yres=1080"),
           "-device", "qemu-xhci", "-device", "usb-kbd", "-device", "usb-tablet",
           "-display", os.environ.get("VMTEST_DISPLAY", "none"),
           "-chardev", f"socket,id=s0,path={SER_SOCK},server=on,wait=off,logfile={SER_LOG}",
           "-serial", "chardev:s0",
           "-qmp", f"unix:{QMP},server=on,wait=off"] + extra
    sh(*cmd)
    print("booted")


def boot_iso():
    kdir = D / "isoboot"
    if not (kdir / "arch/boot/x86_64/vmlinuz-linux").exists():
        kdir.mkdir(parents=True, exist_ok=True)
        sh("bsdtar", "-xf", str(ISO), "-C", str(kdir),
           "arch/boot/x86_64/vmlinuz-linux", "arch/boot/x86_64/initramfs-linux.img")
    # Direct kernel boot, because archiso's label search never armed under
    # QEMU's CD (map: "Driving a headless guest over serial").
    boot(["-cdrom", str(ISO),
          "-kernel", f"{kdir}/arch/boot/x86_64/vmlinuz-linux",
          "-initrd", f"{kdir}/arch/boot/x86_64/initramfs-linux.img",
          "-append", "archisobasedir=arch archisodevice=/dev/sr0 cow_spacesize=4G console=tty0 console=ttyS0,115200"])


def serial_send(text):
    s = socket.socket(socket.AF_UNIX)
    s.connect(str(SER_SOCK))
    s.sendall(text.encode() + b"\r")  # serial wants CR, not LF (map)
    time.sleep(0.3)
    s.close()


def expect(pat, secs=300):
    start = SER_LOG.stat().st_size if os.environ.get("VM_EXPECT_NEW") else 0
    t = time.time()
    while time.time() - t < secs:
        data = SER_LOG.read_bytes()[start:].decode("utf-8", "replace")
        if re.search(pat, data):
            print("matched")
            return
        time.sleep(1)
    print(SER_LOG.read_bytes()[-1500:].decode("utf-8", "replace"))
    sys.exit("timeout")


def qmp(*cmds):
    s = socket.socket(socket.AF_UNIX)
    s.connect(str(QMP))
    f = s.makefile("rw")
    f.readline()
    def do(c):
        f.write(json.dumps(c) + "\n"); f.flush()
        while True:
            r = json.loads(f.readline())
            if "return" in r or "error" in r:
                if "error" in r:
                    sys.exit(str(r))
                return r
    do({"execute": "qmp_capabilities"})
    for c in cmds:
        do(c)
    s.close()


def keys(combo):
    ks = [{"type": "qcode", "data": k} for k in combo.split("+")]
    qmp({"execute": "send-key", "arguments": {"keys": ks}})
    time.sleep(0.12)


SHIFT = {'!': '1', '@': '2', '#': '3', '$': '4', '%': '5', '^': '6', '&': '7', '*': '8', '(': '9', ')': '0',
         '_': 'minus', '+': 'equal', '{': 'bracket_left', '}': 'bracket_right', '|': 'backslash',
         ':': 'semicolon', '"': 'apostrophe', '<': 'comma', '>': 'dot', '?': 'slash', '~': 'grave_accent'}
PLAIN = {' ': 'spc', '-': 'minus', '=': 'equal', '[': 'bracket_left', ']': 'bracket_right', '\\': 'backslash',
         ';': 'semicolon', "'": 'apostrophe', ',': 'comma', '.': 'dot', '/': 'slash', '`': 'grave_accent'}


def typ(text):
    for c in text:
        if c.isupper():
            keys("shift+" + c.lower())
        elif c in SHIFT:
            keys("shift+" + SHIFT[c])
        else:
            keys(PLAIN.get(c, c))


def main():
    a = sys.argv[1:] or ["help"]
    c = a[0]
    if c == "new":
        if running():
            sys.exit("stop it first")
        setup()
        for p in D.glob("*.qcow2"):
            p.unlink()
        (D / "OVMF_VARS.fd").unlink(missing_ok=True)
        setup()
        sh("qemu-img", "create", "-q", "-f", "qcow2", str(DISK), "100G")
    elif c == "overlay":
        if running():
            sys.exit("stop it first")
        name = D / f"{a[1]}.qcow2"
        DISK.rename(name)
        shutil.copy(D / "OVMF_VARS.fd", D / f"{a[1]}.vars")
        sh("qemu-img", "create", "-q", "-f", "qcow2", "-F", "qcow2", "-b", str(name), str(DISK))
    elif c == "rollback":
        if running():
            sys.exit("stop it first")
        DISK.unlink(missing_ok=True)
        shutil.copy(D / f"{a[1]}.vars", D / "OVMF_VARS.fd")
        sh("qemu-img", "create", "-q", "-f", "qcow2", "-F", "qcow2", "-b", str(D / f"{a[1]}.qcow2"), str(DISK))
    elif c == "iso":
        boot_iso()
    elif c == "disk":
        boot([])
    elif c == "stop":
        subprocess.run(["systemctl", "--user", "stop", UNIT])
    elif c == "serial":
        serial_send(a[1])
    elif c == "expect":
        expect(a[1], int(a[2]) if len(a) > 2 else 300)
    elif c == "ssh":
        os.execvp("ssh", SSH + [f"{a[1]}@127.0.0.1", a[2]])
    elif c == "shot":
        png = Path(a[1]).resolve()
        ppm = png.with_suffix(".ppm")
        qmp({"execute": "screendump", "arguments": {"filename": str(ppm)}})
        time.sleep(0.5)
        sh("magick", str(ppm), str(png))
        ppm.unlink()
    elif c == "keys":
        for k in a[1:]:
            keys(k)
    elif c == "type":
        typ(a[1])
    else:
        print(__doc__)


main()
