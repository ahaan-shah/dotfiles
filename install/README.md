# install/

Rebuilds this Hyprland + Quickshell desktop on a fresh Arch install, starting
from nothing but a TTY.

```sh
git clone https://github.com/ahaan-shah/dotfiles.git ~/.config/dotfiles
~/.config/dotfiles/install/install.sh
```

Run it as your normal user, not root. It calls `sudo` only in the one phase
that needs it, and those phases can be skipped with `--no-root`.

## Try it without committing to anything

```sh
./install.sh --dry-run       # print every single action, change nothing
./install.sh --list          # the phases
./install.sh --only hardware # re-run one phase
./install.sh --skip system   # skip one phase
./install.sh --yes           # no prompts, take every default
```

`--dry-run` is exhaustive: every package, file copy, symlink, `sudo` call and
`systemctl` invocation is printed. Read that before the real run.

## What the phases do

| Phase | |
|---|---|
| `preflight` | Arch check, network check, hardware detection report, confirm |
| `packages` | Every manifest in `packages/`, GPU userspace matched to the actual vendor, then the four AUR packages (bootstrapping `yay` first) |
| `configs` | Deploys config directories into `~/.config`, backing up anything it overwrites |
| `hardware` | Detects this machine and writes `~/.config/scripts/hardware.env` |
| `apps` | voxtype model + config, Spotify Wayland flag, battery cap preference, login shell |
| `usersystemd` | User units, enables the battery watchdog timer and voxtype |
| `system` | `/etc` rules, group membership, system services, greetd |
| `network` | Wifi (NetworkManager + iwd), Bluetooth, and the firewall with the LocalSend exception |
| `virt` | QEMU/KVM via libvirt: qemu.conf, the `libvirt` group, the modular daemons, and the default NAT network |
| `theming` | pywal templates, primes the colour scheme, generates `hyprpaper.conf`, GTK/cursor |
| `plugins` | Builds and enables `hyprbars` via `hyprpm` |
| `hibernation` | Opt-in. Swap file, `resume=` cmdline, resume hook — the only phase that edits your bootloader |
| `fingerprint` | Offers to enrol fingers, if a reader is detected. Interactive by nature |
| `verify` | Asserts the result, including that `hyprland.lua` actually parses |

## Packages

There is no interactive package picker. Answering "no" to a group produced a
machine that was subtly not this one, which defeats the point, so every
manifest in `packages/` is installed:

| Manifest | |
|---|---|
| `10-core.txt` | The compositor, the four Quickshell apps' runtime deps, the shell |
| `20-laptop.txt` | Battery, fingerprint, zram — installed only when a battery exists |
| `30-fonts.txt` | JetBrainsMono Nerd Font and friends |
| `40-apps.txt` | The applications. Deliberately excludes `r`, `steam`, `discord` |
| `50-aur.txt` | Exactly four: `bibata-cursor-theme`, `voxtype`, `localsend-bin`, `neofetch` |
| `60-virt.txt` | QEMU/libvirt — installed only when the CPU reports VT-x/AMD-V |
| `90-nvidia.txt` | Reference only. Never installed; see the NVIDIA note at the bottom |

The AUR list is short on purpose: an AUR build is slow and can fail, and which
browser or music player you want is a personal choice. Everything else — Zen,
Brave, Spotify, VSCodium, the TUI toys — is one fuzzy search away afterwards:

```sh
~/.config/scripts/pkg-aur-install.sh
```

Note `mimeapps.list` points `http`/`https` at `zen.desktop`. Until you install
Zen, those associations fall through to Chromium, which is in `10-core.txt`.

## Virtual machines

The `virt` phase exists because none of what libvirt needs is a default. After
it, opening virt-manager and pointing it at a downloaded ISO just works:

1. `qemu.conf` gets `user`/`group = "qemu"` — edited key-by-key, because the
   file is package-owned and shipping a whole copy would generate `.pacnew`
   noise on every libvirt update.
2. You are added to the `libvirt` group. **Not** `kvm` — systemd's own
   `50-udev-default.rules` already gives `/dev/kvm` mode 0666.
3. The modular `virt*d` sockets are enabled (not the monolithic `libvirtd`).
   They are socket-activated, so nothing runs until virt-manager connects.
4. The `default` NAT network is marked autostart and started. The package
   defines it but leaves it stopped, which is why a fresh VM otherwise reports
   *"Network 'default' is not active"*.

`edk2-ovmf` and `swtpm` are included so UEFI and TPM 2.0 guests (Windows 11)
work without hunting for firmware.

## Fingerprint

If a reader is detected, the `fingerprint` phase offers to enrol fingers, one
at a time, from a menu of all ten, and asks after each whether you want
another. It runs second-to-last: it is the only phase that needs you physically
at the machine, so everything that can be done without you already has been.

It enrols fingerprints only — it does **not** wire `pam_fprintd` into
`/etc/pam.d`. The lockscreen calls `fprintd-verify` directly, so enrolment is
all it needs, and editing `system-auth` is a well-known way to lock yourself
out. `--yes` skips the phase rather than hanging on a swipe that cannot be
automated; run it later with `--only fingerprint`.

## One run, from a bare TTY

A single run produces a fully working desktop. That needed solving, because on a
TTY there is no compositor to ask about the display:

- **Refresh rate** — the monitor mode is set to `highrr`, Hyprland's own keyword
  for "use the highest supported refresh rate". A 120 Hz panel comes up at 120 Hz
  with nothing detected at all.
- **Scale** — read from the panel's **EDID**. Bytes 21 and 22 hold its physical
  size in cm; combined with the preferred resolution that gives DPI, and DPI
  decides 1x vs 2x. On this laptop that is 34x19 cm at 2880x1620 = 216 DPI = 2x,
  which is exactly the value that used to be hardcoded. Falls back to `auto` if
  the EDID cannot be read.
- **Touchpad device name** — genuinely impossible without a running compositor,
  and it is the *only* such fact. So `hyprland.lua` autostarts
  `complete-hardware-profile.sh`, which fills it into `hardware.env` at your
  first login and then returns in about 10 ms on every boot afterwards. No
  reload, no second command: the touchpad works either way, and the name is only
  needed by the F6 toggle, which reads the file fresh each time.

You can still re-run `--only hardware` from inside a session to pin the exact
current mode instead of `highrr`, but nothing requires it.

## `hardware.env`

Everything machine-specific lives in one generated file rather than being edited
into the configs:

```sh
PRIMARY_MONITOR="eDP-1"
MONITOR_MODE="2880x1620@120"
MONITOR_POSITION="0x0"
MONITOR_SCALE="2"
BATTERY="BAT0"
BATTERY_CHARGE_CAP="1"
KBD_BACKLIGHT_LED="asus::kbd_backlight"
MICMUTE_LED="platform::micmute"
TOUCHPAD_DEVICE="asup1204:00-093a:2642-touchpad"
IGPU_PCI="0000:00:02.0"
```

`hyprland.lua` parses it; `toggle-touchpad.sh`, `kbdbacklight_toggle.sh`,
`micmute-led.sh`, `apply-battery-threshold.sh` and the taskbar's battery reader
all source it. Every one of them falls back to something that works when the
file is missing, so a config copied somewhere by hand still runs.

After a TTY-only install the same file reads `MONITOR_MODE="highrr"`,
`MONITOR_POSITION="auto"` and a scale derived from EDID, with `TOUCHPAD_DEVICE`
empty until your first login fills it in. Both forms are fully working configs.

It is **excluded from the dotfiles backup on purpose** — committing this
laptop's touchpad name would hand the next fresh install the wrong hardware.

## Wifi, Bluetooth and the firewall

The `network` phase sets all three up so they work on first boot:

- **Wifi** — NetworkManager with `wifi.backend=iwd`. NetworkManager owns the
  saved profiles and iwd is only the driver underneath; the taskbar's wifi panel
  is nmcli-driven and depends on that split. Also unblocks the radio with
  `rfkill`, which a fresh install can leave soft-blocked.
- **Bluetooth** — enables and starts `bluetooth.service`. No config file is
  written: BlueZ already defaults to `AutoEnable=true`, so restating it in a
  package-owned file would only create `.pacnew` noise later.
- **Firewall** — firewalld, default `public` zone, with a **LocalSend** service
  definition opening **TCP and UDP 53317**. Both protocols matter: TCP carries
  the transfer, UDP carries multicast discovery. With UDP missing, transfers work
  only if you type in an address by hand and devices never find each other.

Stock firewalld already allows `ssh` and `dhcpv6-client` in `public`, so
LocalSend is the only real difference. Re-running the phase is a no-op: it
queries each service first and only reloads if something actually changed.

## Hibernation

The `hibernation` phase sets it up, and it is the **only** part of the installer
that edits your bootloader. It is skipped automatically when the machine already
has a real swap file and `resume=` on its running command line, and it shows you
the exact plan before asking.

It is portable, unlike the script it replaced. It detects:

- **whether hibernation is possible at all** — `CONFIG_HIBERNATION`, and kernel
  lockdown (which Secure Boot turns on, and which blocks hibernation outright);
- **the root filesystem** — `ext4`/`xfs` use `filefrag` for the resume offset,
  `btrfs` uses `btrfs inspect-internal map-swapfile` and gets a `chattr +C`
  nodatacow swap file. Anything else refuses rather than guessing;
- **swap size** — from RAM, not a hardcoded number, since the image can grow to
  the whole of RAM. Override with `HIBERNATE_SWAP_GB=32`;
- **where the kernel command line lives**, and updates *every* place it finds:
  `/etc/kernel/cmdline` (UKI), Limine, systemd-boot entries, GRUB. On a UKI +
  Limine machine both must be changed — Limine passes its own cmdline via EFI
  LoadOptions, which **overrides** the one baked into the UKI, so editing only
  `/etc/kernel/cmdline` silently does nothing.

If it finds no command line it can edit, it aborts in the detection stage having
changed nothing, and prints the parameter to add by hand. That ordering matters:
the previous version edited `fstab` and `mkinitcpio.conf` *first* and would abort
partway on any non-Limine machine, leaving it half-configured.

Run it standalone any time:

```sh
sudo ~/.config/scripts/setup-hibernation.sh --dry-run   # plan only, no root needed
sudo ~/.config/scripts/setup-hibernation.sh             # do it
```

It takes effect on the next reboot. Re-running is a no-op.

## No NVIDIA here, deliberately

Not every machine has one, and pinning the compositor to the wrong GPU is a
black screen and a TTY recovery, not a warning. `install/packages/90-nvidia.txt`
lists what this laptop uses, but nothing calls it. The hybrid-graphics notes in
the top-level `CLAUDE.md` are the real procedure — read them before installing
a driver, particularly the part about `AQ_DRM_DEVICES` being colon-separated.

The GPU pin in `hyprland.lua` is safe regardless: it resolves a PCI address to a
plain `/dev/dri/cardN`, and if that fails for any reason it leaves the variable
**unset**, which is just the ordinary unpinned behaviour.

## What it will not do

- Touch your bootloader, kernel, fstab or partitions.
- Install NVIDIA drivers.
- Restore documents. It is a desktop installer, not a backup restore.

## If something goes wrong

Everything overwritten is copied to `~/.config-backup-<timestamp>/` first, and
`/etc` files get a `.bak-<timestamp>` sibling. The full log is at
`/tmp/hyprahaan-install-<timestamp>.log`.

If Hyprland will not start after install, get to a TTY with `Ctrl+Alt+F2` and:

```sh
cat ~/.cache/hyprland/hyprlandCrashReport*.txt   # persists across reboots
lua5.4 ~/.config/dotfiles/install/lib/luastub.lua ~/.config/hypr/hyprland.lua
```

The second one parses the config offline and reports the first error. A config
that crashes partway through silently drops every keybind after that point, so
a clean parse is worth confirming.
