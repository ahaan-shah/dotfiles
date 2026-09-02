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
| `configs` | Deploys config directories into `~/.config`, backing up anything it overwrites. Marks the launchers **and the extensionless agent collectors** executable |
| `hardware` | Detects this machine and writes `~/.config/scripts/hardware.env` |
| `nvidia` | Only where there is an NVIDIA dGPU: PRIME offload, or a documented refusal |
| `apps` | voxtype model + config, Spotify Wayland flag, battery cap preference, login shell |
| `usersystemd` | User units, enables the battery watchdog timer and voxtype |
| `system` | `/etc` rules, group membership, system services, greetd |
| `network` | Wifi (NetworkManager + iwd), Bluetooth, and the firewall with the LocalSend exception |
| `virt` | QEMU/KVM via libvirt: qemu.conf, the `libvirt` group, the modular daemons, and the default NAT network |
| `theming` | pywal templates, primes the colour scheme, generates `hyprpaper.conf`, GTK/cursor |
| `plugins` | **Builds** `hyprbars` via `hyprpm` and deliberately leaves it **disabled**. Never fatal — `hyprland.lua` gates its hyprbars block, so an absent plugin means no title bars and nothing else |
| `hibernation` | Opt-in. Swap file, `resume=` cmdline, resume hook — the only phase that edits your bootloader |
| `fingerprint` | Offers to enrol fingers, if a reader is detected. Interactive by nature |
| `verify` | Asserts the result, including that `hyprland.lua` actually parses and that the agent collectors really write a record |

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
| `90-nvidia.txt` | `nvidia-open`, `nvidia-utils`, `nvidia-prime` — only when the `nvidia` phase decides the machine fits |

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
DGPU_PCI="0000:01:00.0"
DGPU_VENDOR="nvidia"
```

`IGPU_PCI` is the GPU that owns the internal panel — detected from the connected
eDP/LVDS connector, not from "first Intel or AMD card found", because on a hybrid
laptop both GPUs expose connectors. Empty is a valid answer and means *do not
pin*. The two `DGPU_` lines are recorded for the installer and for scripts;
nothing in the running desktop reads them.

`hyprland.lua` parses it; `toggle-touchpad.sh`, `kbdbacklight_toggle.sh`,
`micmute-led.sh`, `apply-battery-threshold.sh` and the taskbar's battery reader
all source it. Every one of them falls back to something that works when the
file is missing, so a config copied somewhere by hand still runs.

After a TTY-only install the same file reads `MONITOR_MODE="highrr"`,
`MONITOR_POSITION="auto"` and a scale derived from EDID, with `TOUCHPAD_DEVICE`
empty until your first login fills it in. Both forms are fully working configs.

It is **excluded from the dotfiles backup on purpose** — committing this
laptop's touchpad name would hand the next fresh install the wrong hardware.

## The agents panel

The taskbar's seventh dropdown reports the plan, rate limits and token history
of whichever AI coding agent is running. It is an **extension point, not a
feature with a list**: nothing in `shell.qml` names an agent. Every executable
`~/.config/scripts/agent-usage-<id>` is a collector, it prints one JSON record
to stdout, `agent-usage-update.sh` writes that to
`~/.local/state/hyprahaan/agents/usage/<id>.json`, and the panel draws whatever
is in that directory. Adding an agent is adding one file.

Two ship: `agent-usage-claude` and `agent-usage-codex`, both Python, both
adapted from omarchy (MIT). The installer's part in this is small and entirely
about not breaking the contract:

- **`packages`** installs `python` and `jq`. `python` was previously implicit —
  `python-pywal` pulls it in — and is now named, because code in this repo calls
  it directly.
- **`configs`** deploys the collectors with the rest of `scripts/`, and
  `taskbar/assets/` alongside `shell.qml` (the panel hero resolves its mark with
  `Qt.resolvedUrl`, so the directory has to travel *with* the QML or the hero
  silently falls back to the bar glyph). It then marks every `agent-usage-*`
  executable — **not** covered by the old `*.sh` sweep, because a collector
  carries no extension by contract: the id is whatever follows `agent-usage-`.
- **`verify`** runs the writer for real and counts the records it left.

That last pair is worth stating plainly, because the failure is invisible. The
execute bit is not cosmetic here — it is the registration. Both
`agent-usage-update.sh` and the taskbar's own collector scan enumerate with
`[ -x ]`. Measured on a clone with the bits stripped: `update.sh` **exits 0**,
writes nothing, and the agents module simply never appears in the bar, with no
error in any log. Nothing else in the install would have caught it.

**Nothing is enabled by the installer, and nothing needs to be.** There is no
timer and no unit: the taskbar refreshes the records itself on a 15-minute
timer and probes for a live agent process every 2 s. Installing a CLI does
nothing on its own either — a collector that knows how to read it has to exist.
Both shipped collectors are safe on a machine where that agent is absent: they
exit 0 having written a zeroed record, which is how they report "nothing yet"
rather than failing, and the panel gates its tabs on the counters, so an unused
agent puts no empty tab in the bar. Measured at ~0.1 s for both, concurrently,
with nothing authenticated — which is why `verify` can afford to run them.

The records live outside both the repo and `~/.config` on purpose. They carry
token counts and plan tier, and `~/.config/scripts` is mirrored to a **public**
repo.

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

## NVIDIA

The `nvidia` phase runs only where detection finds an NVIDIA discrete GPU, and
it sets up exactly one thing:

> the iGPU draws every pixel, always. The dGPU renders nothing until a command
> asks for it by name — `prime-run <cmd>` — and drops back to D3cold by itself a
> few seconds after that command exits.

It runs **after** `configs` and `hardware` on purpose. The iGPU pin has to be
deployed, and `hardware.env` has to name the iGPU, before a driver exists that
could take the display. That ordering is the whole safety argument: with the pin
already in place, a broken NVIDIA install degrades to "offload doesn't work" and
never to a black screen, because eDP stays on the iGPU either way.

### Title bars

`hyprbars` draws the traffic-light buttons on each window. **A fresh install
comes up without them.** The `plugins` phase builds the plugin but leaves
hyprpm's enable flag off, so `hyprpm reload` in the startup hook loads nothing
and your first login is bare. Turning them on is a decision you make afterwards:

```sh
~/.config/scripts/hyprbars.sh on                 # this session
~/.config/scripts/hyprbars.sh on --persist       # ...and at every login
~/.config/scripts/hyprbars.sh toggle
~/.config/scripts/hyprbars.sh status
```

Building it during the install is still the point: `hyprbars.sh on` can only
work if the `.so` exists, and compiling it needs `hyprpm`, root and the Hyprland
headers — everything the installer already has and a keybind does not.

It uses `hyprctl plugin load/unload`, not `hyprpm enable/disable`: hyprpm writes
to root-owned `/var/cache/hyprpm/` and so prompts for a password, which is fine
in a terminal and useless from a keybind. `--persist` is the opt-in that does
ask. The same script's `minimize` subcommand is what the yellow button calls.

**Why the phase is not fatal.** `hyprland.lua` gates its whole hyprbars block on
the plugin actually being loaded. Before that gate existed, an absent plugin made
`hl.plugin.hyprbars.add_button(...)` raise, which aborted the config parse and
dropped every bind defined after it — Hyprland fell back to emergency mode with
three binds. Measured 2026-09-02. If you ever see `SUPER+Q`/`R`/`M` as your only
working keys, that is what happened; `hyprctl configerrors` names the line.

## What it will not do

It refuses, loudly and with the reason, rather than guessing:

| | |
|---|---|
| dGPU is AMD or Intel | Nothing to do — mesa drives it and `DRI_PRIME=1` is the switch |
| MUX not in hybrid mode | The panel is wired to the dGPU; pinning to the iGPU is a black screen |
| No integrated GPU at all | This repo has never run an NVIDIA-primary session and will not guess one |
| Pre-Turing card | `nvidia-open` needs GSP firmware. The proprietary driver needs the sleep services, and those do `chvt 63` before every suspend — straight at the lockscreen |
| Secure Boot enforcing | An unsigned out-of-tree module will not load. Warns, then asks |
| `/boot` under 300 MB free | The install rebuilds the initramfs; the image here is 147 MB |
| `hyprland.lua` pins by-path | **Hard stop.** See below — this is the black screen that actually happened |

It writes no module parameters and enables no units. On an Ampere-or-later
notebook with the open modules the defaults are already right, and three pieces
of standard advice are actively wrong here; `packages/90-nvidia.txt` records
which three and why. What it does after installing is *check* what the packages
placed: the nouveau blacklist, the suspend-notifier options, that all four
NVIDIA units are still disabled, and that no NVIDIA module can reach the
initramfs.

### The one that bit us

`AQ_DRM_DEVICES` is a **colon-separated list**, and a PCI by-path name is full of
colons. Passing `/dev/dri/by-path/pci-0000:00:02.0-card` shreds it into three
fragments, aquamarine finds no GPU, and Hyprland aborts at startup with
`drm: Found no gpus to use, cannot continue` — a black screen and a TTY
recovery. The phase greps the deployed `hyprland.lua` for that shape and stops
before installing anything if it finds it.

The pin in `hyprland.lua` is safe otherwise: it resolves the PCI address to a
plain `/dev/dri/cardN` **at parse time**, which is also what absorbs the card
renumbering the driver install causes (`nouveau` held `card1` here; `nvidia`
holds `card0` now). If it cannot resolve, it leaves the variable **unset**,
which is just the ordinary unpinned behaviour.

### Day to day

`prime-run <command>`. For a launcher entry, copy the `.desktop` into
`~/.local/share/applications/` and prefix `Exec=` with `prime-run`. Rolling the
whole thing back is `sudo pacman -R nvidia-open nvidia-utils nvidia-prime` and a
reboot — the nouveau blacklist lives inside the package, so removing it restores
the previous setup exactly.

## What it will not do

- Touch your bootloader, kernel, fstab or partitions — except `hibernation`,
  which asks first and shows you the exact edit.
- Install an NVIDIA driver on a machine that does not fit the hybrid-offload
  model above, or write any NVIDIA module parameter or unit of its own.
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
