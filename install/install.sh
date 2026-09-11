#!/usr/bin/env bash
#
# install.sh — rebuild this Hyprland/Quickshell desktop on a fresh Arch install.
#
# Designed to be run on a MINIMAL Arch system from a TTY: it installs the
# compositor, every package the configs actually call, the configs themselves,
# the systemd units, the root-level rules, and the theme. It is idempotent —
# re-running it is a supported way to repair a half-finished install.
#
#   ./install.sh                 full install
#   ./install.sh --dry-run       print every action, change nothing
#   ./install.sh --yes           take every default, no prompts
#   ./install.sh --only hardware run one phase
#   ./install.sh --skip virt     skip a phase
#   ./install.sh --list          list phases
#
# Package selection is not interactive. Every manifest in packages/ is
# installed, because a half-answered prompt produces a machine that is subtly
# not this one. The AUR list is deliberately four packages; install anything
# else afterwards with ~/.config/scripts/pkg-aur-install.sh.
#
# NVIDIA is set up only where the machine actually has an NVIDIA discrete GPU,
# and only in one shape: the iGPU draws the desktop, the dGPU renders nothing
# until `prime-run` asks it to. Where the machine does not fit that shape the
# phase refuses rather than guesses — getting hybrid graphics wrong costs a
# black screen, not an error message. See install/README.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTDIR="$(dirname "$SCRIPT_DIR")"     # the repo root: configs live beside install/

DRY_RUN=0
ASSUME_YES=0
NO_ROOT=0
ONLY=""
SKIP=""
LOGFILE="/tmp/hyprahaan-install-$(date +%Y%m%d-%H%M%S).log"

ALL_PHASES="preflight packages configs hardware nvidia apps usersystemd system network virt theming hibernation fingerprint verify"

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/detect.sh
source "$SCRIPT_DIR/lib/detect.sh"

usage() {
    # print the header comment block, stopping at the first non-comment line
    awk 'NR<3{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
    printf '\nPhases: %s\n' "$ALL_PHASES"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)      DRY_RUN=1 ;;
        --yes|-y)       ASSUME_YES=1 ;;
        --no-root)      NO_ROOT=1 ;;
        --only)         ONLY="${2:-}"; shift ;;
        --skip)         SKIP="${SKIP} ${2:-}"; shift ;;
        --list)         echo "$ALL_PHASES" | tr ' ' '\n'; exit 0 ;;
        -h|--help)      usage; exit 0 ;;
        *)              echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

want_phase() {
    local p="$1"
    [ -n "$ONLY" ] && { [ "$ONLY" = "$p" ]; return; }
    case " $SKIP " in *" $p "*) return 1 ;; esac
    return 0
}

# ═══════════════════════════════════════════════════════════════════════
# 1 · PREFLIGHT
# ═══════════════════════════════════════════════════════════════════════
phase_preflight() {
    phase "Preflight"

    [ -r /etc/arch-release ] || die "this installer is Arch-specific (/etc/arch-release not found)"
    [ "$(id -u)" -ne 0 ] || die "do not run this as root — it installs into \$HOME and calls sudo where it must"
    have sudo || die "sudo is required and not installed"
    have pacman || die "pacman not found"

    if [ ! -d "$DOTDIR/hypr" ]; then
        die "cannot find the configs. Expected them beside install/ at: $DOTDIR"
    fi
    ok "config source: $DOTDIR"

    if ! ping -c1 -W3 archlinux.org >/dev/null 2>&1 && ! curl -sfI https://archlinux.org >/dev/null 2>&1; then
        warn "no network reachable — package phases will fail"
        ask_yn "Continue anyway?" n || die "aborted at preflight"
    else
        ok "network reachable"
    fi

    detect_all
    printf '\n%sDetected hardware%s\n' "$C_B" "$C_RST"
    print_detection

    if [ "$HW_LIVE" = 0 ]; then
        printf '\n'
        info "No Hyprland session is running. The monitor is read from its EDID"
        info "and the refresh rate is left as 'highrr', so both are correct"
        info "without one. The touchpad name is the only fact that genuinely"
        info "needs a session — complete-hardware-profile.sh fills that in at"
        info "your first login, so this is still a single-run install."
    fi

    printf '\n'
    if [ "$DRY_RUN" = 1 ]; then
        info "DRY RUN — nothing will be changed."
    else
        ask_yn "Proceed with the install?" y || die "aborted by user"
        sudo_prime
    fi
    _log_raw "preflight complete"
}

# ═══════════════════════════════════════════════════════════════════════
# 2 · PACKAGES
# ═══════════════════════════════════════════════════════════════════════

# read_manifest <file> -> prints "repo <name>" or "aur <name>" per line
read_manifest() {
    local f="$1" line
    [ -r "$f" ] || return 0
    while IFS= read -r line; do
        line="${line%%#*}"
        line="$(printf '%s' "$line" | tr -d '[:space:]')"
        [ -z "$line" ] && continue
        case "$line" in
            aur:*) printf 'aur %s\n' "${line#aur:}" ;;
            *)     printf 'repo %s\n' "$line" ;;
        esac
    done <"$f"
}

pac_install() {
    [ $# -gt 0 ] || return 0
    run sudo pacman -S --needed --noconfirm "$@"
}

aur_install() {
    [ $# -gt 0 ] || return 0
    run yay -S --needed --noconfirm "$@"
}

bootstrap_yay() {
    have yay && { skip "yay already present"; return 0; }
    info "bootstrapping yay from the AUR"
    pac_install base-devel git
    local tmp="/tmp/yay-bootstrap-$$"
    run rm -rf "$tmp"
    run git clone --depth 1 https://aur.archlinux.org/yay-bin.git "$tmp"
    if [ "$DRY_RUN" = 1 ]; then
        printf '  %sDRY%s (cd %s && makepkg -si --noconfirm)\n' "$C_DIM" "$C_RST" "$tmp"
    else
        ( cd "$tmp" && makepkg -si --noconfirm ) || die "yay bootstrap failed"
    fi
    run rm -rf "$tmp"
    ok "yay installed"
}

# GPU userspace is vendor-dependent — installing Intel drivers on an AMD laptop
# is worse than installing nothing.
install_gpu_userspace() {
    local vendor="" dev
    for dev in /sys/bus/pci/devices/*; do
        [ -d "$dev/drm" ] || continue
        case "$(cat "$dev/vendor" 2>/dev/null)" in
            0x8086) vendor="intel"; break ;;
            0x1002) vendor="amd";   break ;;
        esac
    done
    case "$vendor" in
        intel) info "Intel graphics detected"; pac_install mesa vulkan-intel intel-media-driver libva-utils ;;
        amd)   info "AMD graphics detected";   pac_install mesa vulkan-radeon libva-mesa-driver libva-utils ;;
        *)     warn "no Intel/AMD integrated GPU detected — installing mesa only"; pac_install mesa ;;
    esac
    # CPU microcode, matched to the actual CPU
    if grep -qi 'GenuineIntel' /proc/cpuinfo; then pac_install intel-ucode
    elif grep -qi 'AuthenticAMD' /proc/cpuinfo; then pac_install amd-ucode; fi
}

# install_manifest <file...> — install every package listed, repo and AUR
# alike, in two batches. yay is bootstrapped lazily, only if an AUR entry is
# actually reached, so a machine that needs no AUR package never builds it.
install_manifest() {
    local repo=() aur=() kind pkg f
    for f in "$@"; do
        [ -r "$f" ] || { skip "$(basename "$f"): no such manifest"; continue; }
        while read -r kind pkg; do
            if [ "$kind" = aur ]; then aur+=("$pkg"); else repo+=("$pkg"); fi
        done < <(read_manifest "$f")
    done
    if [ "${#repo[@]}" -gt 0 ]; then
        info "installing ${#repo[@]} repository packages"
        pac_install "${repo[@]}"
    fi
    if [ "${#aur[@]}" -gt 0 ]; then
        bootstrap_yay
        info "installing ${#aur[@]} AUR packages (built from source — this is the slow part)"
        aur_install "${aur[@]}"
    fi
}

phase_packages() {
    phase "Packages"

    info "refreshing package databases"
    run sudo pacman -Sy --noconfirm

    # Core, fonts and applications go on every machine.
    install_manifest "$SCRIPT_DIR/packages/10-core.txt" \
                     "$SCRIPT_DIR/packages/30-fonts.txt" \
                     "$SCRIPT_DIR/packages/40-apps.txt"

    # Laptop-only: the battery panel, the charge cap and the fingerprint reader
    # have nothing to do on a desktop.
    if [ -n "${HW_BATTERY:-}" ]; then
        install_manifest "$SCRIPT_DIR/packages/20-laptop.txt"
    else
        skip "no battery detected — laptop packages skipped"
    fi

    # Virtualisation, only where the CPU can actually do it.
    if [ "${HW_KVM:-0}" = 1 ]; then
        install_manifest "$SCRIPT_DIR/packages/60-virt.txt"
    else
        skip "no VT-x/AMD-V support — virtualisation packages skipped"
    fi

    install_gpu_userspace

    # AUR last: it is the slow, fallible part, so everything that can succeed
    # has already succeeded by the time a build can fail.
    install_manifest "$SCRIPT_DIR/packages/50-aur.txt"

    ok "packages complete"
}

# ═══════════════════════════════════════════════════════════════════════
# 3 · CONFIGS
# ═══════════════════════════════════════════════════════════════════════
# Anything matching these never reaches ~/.config/scripts.
SCRIPT_EXCLUDES=(
    'wake-lag-*'            # diagnostics: bulky captures, hardcoded project path
    'diagnose-wake-lag.sh'
    'inject-scroll.c'       # test tooling, not runtime
    'wlr-*.xml'
    'backup_files.sh'       # names personal directories; not part of the desktop
)

deploy_scripts() {
    local src="$DOTDIR/scripts" dst="$HOME/.config/scripts" args=() e
    [ -d "$src" ] || { skip "scripts: not present in this checkout"; return 0; }
    for e in "${SCRIPT_EXCLUDES[@]}"; do args+=(--exclude "$e"); done
    backup_path "$dst"
    run mkdir -p "$dst"
    run rsync -a --exclude '.git' --exclude 'wake-lag-logs/' "${args[@]}" "$src"/ "$dst"/
    ok "scripts -> $dst (diagnostics and personal scripts excluded)"
}

phase_configs() {
    phase "Configs"

    local d
    # Quickshell apps + compositor. These exist in both the source repo and the
    # dotfiles mirror; anything absent is skipped rather than treated as an error.
    # hyprland.conf and hyprlock.conf are the dormant hyprlang originals, kept
    # in the repo as rollback references. Nothing reads them — the live config is
    # hyprland.lua and the lockscreen is the Quickshell app — so they are not
    # deployed. colors-hyprland.lua is likewise absent from the repo: it is
    # generated by pywal, and phase 7 links it into place.
    deploy_dir "$DOTDIR/hypr" "$HOME/.config/hypr" \
               --exclude 'hyprland.conf' --exclude 'hyprlock.conf' --exclude '*.bak-*' || true

    for d in taskbar macshell finder lockscreen \
             kitty cava fastfetch neofetch fum btop mpv yazi gtk-3.0 gtk-4.0; do
        deploy_dir "$DOTDIR/$d" "$HOME/.config/$d" || true
    done

    # scripts/ is deployed with exclusions. ~/.config/scripts is mirrored into a
    # PUBLIC dotfiles repo by backup_configs.sh, so the wake-lag diagnostics
    # (bulky, machine-specific, and hardcoding a project path) and the personal
    # file-backup script stay in the source repo and never land there.
    deploy_scripts

    # Single files, which live in differently-shaped places in the mirror.
    deploy_file "$DOTDIR/starship/starship.toml" "$HOME/.config/starship.toml" || \
        deploy_file "$DOTDIR/starship.toml" "$HOME/.config/starship.toml" || true
    # mimeapps.list decides which app opens which file type. The dotfiles
    # mirror carries the live copy (backup_configs.sh keeps it fresh); the
    # template beside install/ is the guaranteed fallback, so a run from the
    # source repo — where the mirror-shaped files do not exist — still gets it.
    deploy_file "$DOTDIR/mimeapps.list" "$HOME/.config/mimeapps.list" || \
        deploy_file "$SCRIPT_DIR/templates/mimeapps.list" "$HOME/.config/mimeapps.list" || true
    # The shell rc files carry ABSOLUTE /home/<user>/ paths in a few aliases —
    # they are hand-written files that live only in the mirror, so nothing has
    # ever expanded $HOME in them. Under a different username those aliases
    # point at a home that does not exist and fail with "no such file". This is
    # the same rewrite the webapp .desktop files get below, and for the same
    # reason; it is applied here rather than asked of the rc files themselves,
    # because for a mirror-only file the LIVE copy is the source of truth and
    # the installer does not get to edit it upstream.
    local rc
    for rc in .zshrc .bashrc; do
        deploy_file "$DOTDIR/shell/$rc" "$HOME/$rc" || continue
        [ "$DRY_RUN" = 0 ] && sed -i "s#/home/[A-Za-z0-9_.-]\+/#$HOME/#g" "$HOME/$rc"
    done
    ok "shell rc files repointed at $HOME"

    # Webapp .desktop files and their icons — the dock's ChatGPT/Claude/
    # TradingView entries point at ~/.local/share/icons/webapps.
    # Webapp launchers. Their `Icon=` lines are ABSOLUTE paths into the original
    # machine's home (a .desktop file cannot expand $HOME), so every one of them
    # would show a blank icon under a different username. Rewrite them to this
    # user's home after copying.
    if deploy_dir "$DOTDIR/webapps/applications" "$HOME/.local/share/applications"; then
        if [ "$DRY_RUN" = 0 ]; then
            # A generated cache must never be copied in from the repo — it is
            # rebuilt below and a stale one hides newly added entries.
            rm -f "$HOME/.local/share/applications/mimeinfo.cache"
            # Rewrite ANY reference to the original user's home, not just the
            # icon dir: claude-code-url-handler.desktop points its Exec= at
            # ~/.local/bin, and a .local/share-only pattern silently missed it.
            find "$HOME/.local/share/applications" -name '*.desktop' -exec \
                sed -i "s#/home/[A-Za-z0-9_.-]\+/#$HOME/#g" {} +
        fi
        ok "webapp launchers repointed at $HOME"
    fi
    deploy_dir "$DOTDIR/webapps/icons" "$HOME/.local/share/icons/webapps" || true

    # neofetch's config points image_source at a wallpaper by absolute path.
    # Same class as the rc files and the .desktop entries above: it is a
    # mirror-only file, so nothing ever expanded $HOME in it, and under a
    # different username it names a directory that does not exist. neofetch
    # then falls back to ASCII with no complaint, which is why this was never
    # noticed. Rewritten here rather than excluded, because the rest of the
    # file is a real config worth keeping.
    if [ "$DRY_RUN" = 0 ] && [ -f "$HOME/.config/neofetch/config.conf" ]; then
        sed -i "s#/home/[A-Za-z0-9_.-]\+/#$HOME/#g" "$HOME/.config/neofetch/config.conf"
    fi
    deploy_dir "$DOTDIR/wallpapers"           "$HOME/Pictures/wallpapers" || true
    deploy_dir "$DOTDIR/spicetify/Themes"     "$HOME/.config/spicetify/Themes" || true

    # Remove artefacts the mirror carries that must never reach a live config:
    # a pre-NVIDIA backup of hyprland.lua (Hyprland would not read it, but it is
    # confusing), and voxtype's generated hyprlang submap file, which is dead
    # here — nothing sources conf.d, the live config is Lua, and its contents use
    # the pre-0.55 positional `hyprctl dispatch` form that silently no-ops.
    run rm -f "$HOME/.config/hypr/hyprland.lua.bak-preNvidia"
    run rm -f "$HOME/.config/hypr/conf.d/voxtype-submap.conf"

    # Scripts that were merged into another script. deploy_scripts uses rsync
    # WITHOUT --delete (an install must never eat files it does not own), so a
    # superseded script would otherwise sit in ~/.config/scripts forever, still
    # executable and still findable. hyprbars-minimize.sh and
    # toggle-hyprbars.sh merged into hyprbars.sh on 2026-09-02; hyprbars.sh
    # itself is gone as of 2026-09-11, with the plugin. The one part of it a
    # keybind still reaches — SUPER+D's zoom — is window-zoom.sh now, so an
    # existing machine has to lose the old file or SUPER+D keeps finding it.
    run rm -f "$HOME/.config/scripts/hyprbars-minimize.sh"
    run rm -f "$HOME/.config/scripts/toggle-hyprbars.sh"
    run rm -f "$HOME/.config/scripts/hyprbars.sh"

    # Every launcher and script must be executable — rsync preserves the bit,
    # but a git checkout on a fresh clone may not.
    #
    # The agent-usage-* clause is NOT redundant with *.sh. A collector carries
    # no extension by contract — the id is what follows agent-usage-, so
    # agent-usage-claude and agent-usage-codex are Python files with no suffix
    # at all — and for them the execute bit is the registration, not a
    # convenience: agent-usage-update.sh and the taskbar's own collector scan
    # both enumerate with `[ -x ]`. Measured on a clone with the bits stripped:
    # update.sh exits 0, writes no record, and the agents module never appears
    # in the bar. A silent zero, which is why it is fixed here rather than
    # left to git.
    if [ "$DRY_RUN" = 0 ]; then
        find "$HOME/.config/scripts" "$HOME/.config"/{finder,macshell,taskbar,lockscreen} \
             -maxdepth 1 \( -name '*.sh' -o -name 'agent-usage-*' \) \
             -exec chmod +x {} + 2>/dev/null || true
    fi
    ok "launch scripts and agent collectors marked executable"

    run xdg-user-dirs-update

    # Without these, a freshly copied .desktop file is invisible to mime
    # handling and its icon does not resolve until something else happens to
    # trigger a refresh. (finder parses .desktop files itself so it is
    # unaffected, but `gio launch`, xdg-open and GTK all read these caches.)
    if have update-desktop-database; then
        run update-desktop-database "$HOME/.local/share/applications"
        ok "desktop database rebuilt"
    fi
    if have gtk-update-icon-cache && [ -d "$HOME/.local/share/icons/hicolor" ]; then
        run gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor"
    fi
    ok "configs deployed"
}

# ═══════════════════════════════════════════════════════════════════════
# 4 · HARDWARE
# ═══════════════════════════════════════════════════════════════════════
phase_hardware() {
    phase "Hardware profile"
    detect_all
    print_detection
    write_hardware_env

    if [ "$HW_LIVE" = 0 ]; then
        warn "written from a TTY: monitor mode is 'preferred' and the touchpad is unknown."
        warn "Re-run '--only hardware' from inside Hyprland to pin exact values."
    fi
    if [ -z "${HW_BATTERY:-}" ]; then
        skip "no battery — the charge-cap machinery will stay inert"
    elif [ "${HW_CHARGE_CAP:-0}" != 1 ]; then
        warn "$HW_BATTERY has no charge_control_end_threshold; the cap UI will read as unsupported"
    fi
}

# ═══════════════════════════════════════════════════════════════════════
# 5 · NVIDIA — hybrid graphics: the iGPU draws, the dGPU offloads
# ═══════════════════════════════════════════════════════════════════════
# Runs AFTER configs and hardware, deliberately. hyprland.lua's iGPU pin has to
# be deployed, and hardware.env has to name the iGPU, BEFORE a driver exists
# that could take the display. That ordering is the entire safety argument: with
# the pin already in place, a broken NVIDIA install degrades to "offload does
# not work" and never to a black screen, because eDP stays on i915 either way.
#
# The model this implements, and the only one it implements:
#
#   the iGPU draws every pixel, always. The dGPU renders nothing until a
#   command asks for it by name (`prime-run <cmd>`), and drops back to D3cold
#   by itself a few seconds after that command exits.
#
# It writes no module parameters and enables no units. On an Ampere-or-later
# notebook with the open modules the defaults are already right, and three
# pieces of standard wiki advice are actively wrong here — packages/90-nvidia.txt
# records which three and why. What this phase does instead is: refuse where the
# machine does not match the model, install, then CHECK what the packages
# placed. Nothing here edits hyprland.lua, mkinitcpio.conf or the bootloader.

# nvidia_intree_ko — is there an nvidia kernel module in a path the mkinitcpio
# `kms` hook globs (kernel/drivers/gpu/drm/)? That hook is the only thing that
# would pull one into the initramfs, and we do not want early KMS for a card
# that is supposed to stay asleep. Prints the offending path, or nothing.
#
# This replaces the obvious test. `lsinitcpio -l <img> | grep -ci nvidia` reads
# 663 on this laptop and means nothing at all: those are nouveau's firmware
# blobs from linux-firmware-nvidia (214 MB of them — it is why the UKI here is
# 147 MB), not modules. Count modules, and count them where they live.
nvidia_intree_ko() {
    find /usr/lib/modules -path '*/kernel/drivers/gpu/drm/*' -name 'nvidia*.ko*' \
         2>/dev/null | head -1
}

phase_nvidia() {
    phase "NVIDIA"

    # ── is there anything here to do? ──────────────────────────────────
    if [ -z "${HW_DGPU_PCI:-}" ]; then
        skip "no discrete GPU on this machine — nothing to set up"
        return 0
    fi
    if [ "${HW_DGPU_VENDOR:-}" != nvidia ]; then
        skip "discrete GPU is ${HW_DGPU_VENDOR:-unknown} (${HW_DGPU_NAME:-?}), not NVIDIA"
        info "mesa already drives it and DRI_PRIME=1 is the offload switch there,"
        info "so there is nothing vendor-specific left for this installer to do."
        return 0
    fi

    info "discrete   : ${HW_DGPU_NAME:-?}  (${HW_DGPU_PCI}, device ${HW_DGPU_DEVID:-?})"
    info "integrated : ${HW_IGPU_PCI:-<none — see below>}"

    # ── refusals, in the order they matter ─────────────────────────────
    # A MUX in discrete mode wires the internal panel straight to the dGPU. The
    # iGPU then has no outputs, so pinning Hyprland to it is a guaranteed black
    # screen. Nothing here ever writes the MUX back: flipping it from a running
    # session is a reboot into the unknown, and it is a firmware setting.
    if [ -n "${HW_GPU_MUX:-}" ] && [ "${HW_GPU_MUX}" != 1 ]; then
        warn "the GPU MUX reads ${HW_GPU_MUX} (discrete / \"Ultimate\"), not 1 (hybrid)."
        warn "The panel is wired to the dGPU, so it draws the desktop and never"
        warn "sleeps — the opposite of what this setup is for. Set the MUX back to"
        warn "hybrid in the firmware and re-run this phase."
        skip "NVIDIA phase skipped (MUX not in hybrid mode)"
        return 0
    fi

    if [ -z "${HW_IGPU_PCI:-}" ]; then
        warn "no integrated GPU owns the internal panel, so there is nothing to pin"
        warn "Hyprland to and no fallback if the driver misbehaves."
        warn "This installer only knows the hybrid model. An NVIDIA-only machine"
        warn "needs a different configuration — session-wide GBM_BACKEND and"
        warn "__GLX_VENDOR_LIBRARY_NAME, nvidia_drm.modeset — which nothing in"
        warn "this repo has ever run, so it is not going to be guessed at here."
        skip "NVIDIA phase skipped (no integrated GPU)"
        return 0
    fi

    # The open kernel modules need GSP firmware: Turing (RTX 20 / GTX 16) or
    # newer. Older cards are not a smaller version of this setup, they are a
    # different one — see the comment in dgpu_supports_nvidia_open().
    if ! dgpu_supports_nvidia_open "${HW_DGPU_DEVID:-}"; then
        warn "device ID ${HW_DGPU_DEVID:-?} is pre-Turing, and the open kernel modules"
        warn "need GSP firmware (Turing / RTX 20 / GTX 16 and newer)."
        warn "The proprietary 'nvidia' driver would drive it, but there VRAM does"
        warn "not survive suspend unless nvidia-suspend/-resume/-hibernate are"
        warn "enabled — and those run nvidia-sleep.sh, which does 'chvt 63' before"
        warn "every suspend. Putting a VT switch in the middle of this desktop's"
        warn "ext_session_lock_v1 lock path is the one failure this repo will not"
        warn "design in, so it is not automated."
        info "By hand, if you want it anyway:"
        info "    sudo pacman -Syu nvidia nvidia-utils nvidia-prime"
        info "and then do not suspend with an offloaded application running."
        skip "NVIDIA phase skipped (pre-Turing dGPU)"
        return 0
    fi

    if [ "${HW_SECUREBOOT:-0}" = 1 ]; then
        warn "Secure Boot is enforcing. nvidia-open is an out-of-tree module and"
        warn "nothing here signs it, so the kernel will refuse to load it and the"
        warn "dGPU simply stays dark. The desktop is unaffected either way — it"
        warn "never leaves the iGPU — but offload will not work until it is signed"
        warn "or Secure Boot is turned off."
        ask_yn "Install anyway?" n || { skip "NVIDIA phase skipped (Secure Boot)"; return 0; }
    fi

    # ── the black-screen regression guard ──────────────────────────────
    # AQ_DRM_DEVICES is a COLON-SEPARATED list (aquamarine parses it with
    # CVarList(..., ':', ...)), and a PCI by-path name is full of colons:
    # "/dev/dri/by-path/pci-0000:00:02.0-card" is shredded into three fragments,
    # aquamarine finds no GPU, and Hyprland aborts at startup with
    #     drm: Found no gpus to use, cannot continue
    # which is a black screen and a TTY recovery. That is exactly what happened
    # the first time this was set up here. It is only fatal once a driver exists
    # for the dGPU, which is what the next command installs — so it is checked
    # here, before, and it stops the phase rather than warning.
    local hl="$HOME/.config/hypr/hyprland.lua"
    if [ ! -f "$hl" ]; then
        warn "$hl is not deployed yet — run the configs phase first, so the iGPU"
        warn "pin is in place before a driver exists that could take the display."
        skip "NVIDIA phase skipped (configs not deployed)"
        return 0
    fi
    if [ "$(grep -c 'AQ_DRM_DEVICES.*by-path' "$hl" || true)" -gt 0 ]; then
        die "$hl passes a by-path name to AQ_DRM_DEVICES. That variable is
  colon-separated and a by-path name contains colons, so Hyprland would find no
  GPU and abort at startup once the NVIDIA driver is loaded. Deploy the current
  hypr/hyprland.lua, which resolves the PCI address to a plain /dev/dri/cardN."
    fi
    ok "the deployed hyprland.lua pins by resolved cardN, not by by-path name"

    local node
    node=$(readlink -f "/dev/dri/by-path/pci-${HW_IGPU_PCI}-card" 2>/dev/null || true)
    if [ -n "$node" ]; then
        info "iGPU is $node right now. hyprland.lua re-resolves that at parse time,"
        info "which is what absorbs the renumbering this driver install causes —"
        info "cardN ordering is probe-order dependent and it WILL move."
    fi

    # Installing the driver rebuilds the initramfs. The image on this laptop is
    # 147 MB, so a small ESP is a real failure mode: the rebuild half-writes and
    # the machine does not boot.
    local bootfree
    bootfree=$(df -Pm /boot 2>/dev/null | awk 'NR==2{print $4}')
    if [ -n "${bootfree:-}" ] && [ "$bootfree" -lt 300 ]; then
        warn "/boot has ${bootfree} MB free and this install rebuilds the initramfs."
        warn "That image is 147 MB on this hardware. Free some space first."
        ask_yn "Continue anyway?" n || { skip "NVIDIA phase skipped (low /boot space)"; return 0; }
    fi

    # ── say what will happen, then do it ───────────────────────────────
    printf '\n'
    info "This phase will:"
    info "  · pacman -Syu the packages in packages/90-nvidia.txt (a FULL upgrade)"
    info "  · check the nouveau blacklist and the suspend-notifier options that"
    info "    nvidia-utils ships, and write a fallback drop-in only if absent"
    info "  · make sure nvidia-suspend/-resume/-hibernate and nvidia-powerd stay"
    info "    disabled — 90-nvidia.txt records why all four are hazards here"
    info "  · check that no nvidia module can reach the initramfs"
    info "It does not touch hyprland.lua, mkinitcpio.conf or the bootloader."
    printf '\n'
    ask_yn "Set up NVIDIA PRIME offload now?" y || { skip "NVIDIA phase skipped by user"; return 0; }

    local kind pkg pkgs=()
    while read -r kind pkg; do pkgs+=("$pkg"); done < <(read_manifest "$SCRIPT_DIR/packages/90-nvidia.txt")
    [ "${#pkgs[@]}" -gt 0 ] || die "packages/90-nvidia.txt lists no packages"

    # A full -Syu, not the -S every other phase uses. nvidia-open is a PREBUILT
    # module with a hard dependency on one exact kernel: installing it after a
    # bare -Sy can leave the kernel and the module out of step, and a kernel
    # with no NVIDIA module is a machine that boots to no offload at best. The
    # pair must always move together. This is the one real cost of choosing a
    # prebuilt module over -dkms, and it is cheap as long as nothing ever
    # partial-syncs.
    info "installing: ${pkgs[*]}"
    run sudo pacman -Syu --needed --noconfirm "${pkgs[@]}"

    # 32-bit userspace, but only where multilib is actually on. The thing that
    # breaks without it is Steam, silently, with a GL error at launch — and a
    # machine with no multilib has nothing that could load it.
    if [ "$(pacman-conf --repo-list 2>/dev/null | grep -cx multilib || true)" -gt 0 ]; then
        info "multilib is enabled — installing the matching 32-bit userspace"
        pac_install lib32-nvidia-utils
    else
        skip "multilib not enabled — lib32-nvidia-utils skipped (Steam would want it)"
    fi

    # ── what the packages placed ───────────────────────────────────────
    # nvidia-utils ships both of these. They are CHECKED, not written: a future
    # packaging change then shows up here as a warning instead of later as
    # mystery behaviour, and this installer does not own files pacman owns.
    if grep -rqs '^blacklist nouveau' /usr/lib/modprobe.d /etc/modprobe.d; then
        ok "nouveau is blacklisted (shipped in nvidia-utils.conf)"
    else
        warn "no nouveau blacklist anywhere in modprobe.d — nouveau may bind the"
        warn "card before nvidia can, and offload will silently use zink instead."
    fi

    if grep -rqs 'NVreg_UseKernelSuspendNotifiers=1' /usr/lib/modprobe.d /etc/modprobe.d; then
        ok "kernel suspend notifiers on — VRAM preservation is automatic"
    else
        warn "NVreg_UseKernelSuspendNotifiers is not set anywhere. With the open"
        warn "modules that is what makes VRAM survive suspend; writing a drop-in."
        run_sh "sudo tee /etc/modprobe.d/zz-hyprahaan-nvidia.conf >/dev/null <<'MODEOF'
# Written by install.sh because nvidia-utils did not ship nvidia-sleep.conf.
#
# With the OPEN kernel modules, video memory preservation across suspend is
# handled automatically as long as the kernel suspend notifiers are enabled;
# NVreg_PreserveVideoMemoryAllocations is for the proprietary module and is
# deliberately NOT set here. The save file must not land on tmpfs — that is
# the RAM being saved — so /var/tmp, never /tmp.
options nvidia NVreg_UseKernelSuspendNotifiers=1
options nvidia NVreg_TemporaryFilePath=/var/tmp
MODEOF"
        ok "/etc/modprobe.d/zz-hyprahaan-nvidia.conf written"
    fi

    # ── the four units that must stay off ──────────────────────────────
    # nvidia-suspend, -resume and -hibernate all run nvidia-sleep.sh, which does
    # `chvt 63` before every suspend and switches back on resume. With the open
    # modules they buy nothing, and they put a VT switch in the middle of the one
    # path on this machine that can strand you at a permanently locked screen.
    # nvidia-powerd is a second arbitrator on the package power budget: harmless
    # in itself, but it confounds any power investigation, so it stays off until
    # enabling it is a deliberate experiment.
    local u state
    for u in nvidia-suspend nvidia-resume nvidia-hibernate nvidia-powerd; do
        state=$(systemctl is-enabled "$u.service" 2>/dev/null || true)
        case "$state" in
            enabled|enabled-runtime)
                warn "$u.service is enabled — disabling it"
                run sudo systemctl disable "$u.service" ;;
            "") skip "$u.service: not present" ;;
            *)  ok "$u.service: $state" ;;
        esac
    done

    # ── the initramfs must stay clean ──────────────────────────────────
    # Measured here: the open modules install to extramodules/, which the kms
    # hook cannot see (it globs the kernel tree's drivers/gpu/drm/), so no
    # nvidia module lands in the image. nouveau.ko DOES land — autodetect finds
    # the card — but the modconf hook copies modprobe.d in alongside it, so the
    # blacklist applies at early boot too and nouveau never binds.
    case "$(grep -E '^MODULES=' /etc/mkinitcpio.conf 2>/dev/null | head -1)" in
        *nvidia*)
            warn "mkinitcpio MODULES= contains nvidia. That is early KMS for a card"
            warn "that should stay asleep, and it bloats an already large image."
            warn "Remove it and re-run mkinitcpio -P." ;;
        *)  ok "mkinitcpio MODULES= has no nvidia entry (no early KMS)" ;;
    esac
    local intree
    intree=$(nvidia_intree_ko)
    if [ -n "$intree" ]; then
        warn "an nvidia module sits in a path the kms hook globs:"
        warn "  $intree"
        warn "it will be pulled into the initramfs. Look at the image before"
        warn "changing anything — dropping 'kms' from HOOKS is the usual fix, but"
        warn "that is not a change to make on a guess."
    else
        ok "no nvidia module in a kms-hook path — the initramfs stays clean"
    fi

    # ── what to check after the reboot ─────────────────────────────────
    printf '\n'
    printf '  %sNothing above is live until you reboot.%s Then, in order:\n\n' "$C_B" "$C_RST"
    cat <<GATES
    lsmod | grep -E 'nvidia|nouveau'      # nvidia* present, nouveau ABSENT
    cat /sys/bus/pci/devices/$HW_DGPU_PCI/power/runtime_status   # suspended
    cat /sys/bus/pci/devices/$HW_DGPU_PCI/power_state            # D3cold
    prime-run glxinfo -B | grep 'OpenGL renderer'                # names the dGPU

  The middle two are the gate that decides whether this was worth doing. If the
  card does not go back to sleep on an idle desktop, roll the whole thing back
  rather than tuning it — fine-grained RTD3 is supposed to work by default on an
  Ampere-or-later notebook, and if it does not, something is wrong that module
  parameters will not fix. The reversal is one command, and the nouveau
  blacklist lives inside the package, so removing it restores exactly today:

    sudo pacman -R ${pkgs[*]} && sudo reboot

  Give it a minute first: udev runs nvidia-modprobe on device add, so the stack
  initialises at boot and the card sits awake briefly before settling. And note
  that nvidia-smi is not a free query — it WAKES the GPU. Run it once if you
  want, then re-check runtime_status and confirm it goes back down.

  Day to day: prime-run <command>. For a launcher entry, copy the .desktop into
  ~/.local/share/applications/ and prefix Exec= with prime-run. Anything spawned
  from a Quickshell Process still needs the detach form
  (setsid ... </dev/null >/dev/null 2>&1 &) — more so offloaded, because the
  NVIDIA stack writes more to stderr at startup than mesa does.
GATES
    _log_raw "nvidia phase complete"
}

# ═══════════════════════════════════════════════════════════════════════
# 6 · APPS  (per-application config that is not just a directory copy)
# ═══════════════════════════════════════════════════════════════════════
phase_apps() {
    phase "Application config"

    # ── voxtype ────────────────────────────────────────────────────────
    if have voxtype; then
        # Order matters: `voxtype setup --download` rewrites `model =` in the
        # config file as a side effect, so download FIRST and write the config
        # afterwards, or the config silently ends up on the wrong model.
        info "downloading the base.en whisper model (skipped if already present)"
        run_sh "voxtype setup --download --model base.en >/dev/null 2>&1 || true"

        local vt="$HOME/.config/voxtype/config.toml"
        backup_path "$vt"
        run mkdir -p "$(dirname "$vt")"
        if [ "$DRY_RUN" = 0 ]; then
            sed "s|@HOME@|$HOME|g" "$SCRIPT_DIR/templates/voxtype-config.toml" >"$vt"
        fi
        ok "voxtype config written"

        # Validate with voxtype's own resolver rather than trusting the write.
        if [ "$DRY_RUN" = 0 ] && ! voxtype -c "$vt" config >/dev/null 2>&1; then
            warn "voxtype rejected its own config — check $vt"
        fi

        # The Vulkan build keeps the model in GPU memory: 477 MB RSS -> 62 MB,
        # and ~8x faster. Only wire it up if that binary actually shipped.
        if [ -x /usr/lib/voxtype/voxtype-vulkan ]; then
            deploy_file "$SCRIPT_DIR/user-systemd/voxtype.service.d/vulkan.conf" \
                        "$HOME/.config/systemd/user/voxtype.service.d/vulkan.conf"
        else
            skip "voxtype-vulkan not present — staying on the CPU build"
        fi
    else
        skip "voxtype not installed"
    fi

    # ── Spotify: native Wayland ────────────────────────────────────────
    # Without this Spotify runs on XWayland, which under a scaled monitor
    # renders a blurry cursor over its window only. It also changes Spotify's
    # class to lowercase "spotify", which is what the dock and window rule
    # already expect.
    deploy_file "$SCRIPT_DIR/templates/spotify-flags.conf" "$HOME/.config/spotify-flags.conf" || true

    # ── battery charge cap preference ──────────────────────────────────
    # apply-battery-threshold.sh reads this file and is the single writer for
    # the cap; without it the cap defaults to 100 (i.e. off).
    if [ "${HW_CHARGE_CAP:-0}" = 1 ]; then
        local pref="$HOME/.config/battery-threshold" cap
        if [ -s "$pref" ]; then
            skip "battery cap preference already set to $(cat "$pref")%"
        else
            cap="$(ask_val 'Battery charge cap in percent (100 = no cap)' 80)"
            if printf '%s' "$cap" | grep -qE '^[0-9]+$' && [ "$cap" -ge 20 ] && [ "$cap" -le 100 ]; then
                if [ "$DRY_RUN" = 0 ]; then printf '%s\n' "$cap" >"$pref"; fi
                ok "battery cap preference set to $cap%"
                run_sh "'$HOME/.config/scripts/apply-battery-threshold.sh' '$cap' || true"
            else
                warn "'$cap' is not a value between 20 and 100 — leaving the cap unset"
            fi
        fi
    fi

    # hyprshot's F11/Print binds write here; create it rather than let the first
    # screenshot of a fresh install fail.
    run mkdir -p "$HOME/Pictures/Screenshots"

    # ── default shell ──────────────────────────────────────────────────
    if have zsh && [ "$(getent passwd "$USER" | cut -d: -f7)" != "$(command -v zsh)" ]; then
        if ask_yn "Make zsh your login shell?" y; then
            run sudo chsh -s "$(command -v zsh)" "$USER"
            ok "login shell set to zsh"
        fi
    fi
}

# ═══════════════════════════════════════════════════════════════════════
# 7 · USER SYSTEMD
# ═══════════════════════════════════════════════════════════════════════
phase_usersystemd() {
    phase "User systemd units"
    local ud="$HOME/.config/systemd/user"
    run mkdir -p "$ud"

    deploy_file "$SCRIPT_DIR/user-systemd/hyprland-session.target" "$ud/hyprland-session.target"

    # The battery watchdog only makes sense where there is a cap to watch.
    if [ "${HW_CHARGE_CAP:-0}" = 1 ]; then
        deploy_file "$SCRIPT_DIR/user-systemd/battery-threshold.service" "$ud/battery-threshold.service"
        deploy_file "$SCRIPT_DIR/user-systemd/battery-threshold.timer"   "$ud/battery-threshold.timer"
        run systemctl --user daemon-reload
        run systemctl --user enable --now battery-threshold.timer
        ok "battery-threshold.timer enabled"
    else
        skip "no charge cap on this machine — battery watchdog not installed"
    fi

    if have voxtype; then
        run systemctl --user daemon-reload
        # Bound to graphical-session so it starts with Hyprland and stops with it.
        run systemctl --user enable voxtype.service
        ok "voxtype.service enabled"
    fi
    run systemctl --user daemon-reload
}

# ═══════════════════════════════════════════════════════════════════════
# 8 · SYSTEM  (root: /etc files, groups, system services)
# ═══════════════════════════════════════════════════════════════════════
enable_unit() {
    local u="$1"
    systemctl is-enabled "$u" >/dev/null 2>&1 && { skip "$u already enabled"; return 0; }
    run sudo systemctl enable "$u"
    ok "$u enabled"
}

phase_system() {
    phase "System configuration"
    if [ "$NO_ROOT" = 1 ]; then skip "--no-root given, whole phase skipped"; return 0; fi

    info "this phase writes files under /etc and enables system services"
    ask_yn "Continue with the root-level changes?" y || { warn "system phase skipped"; return 0; }

    sudo_prime

    # ── udev ───────────────────────────────────────────────────────────
    if [ "${HW_CHARGE_CAP:-0}" = 1 ]; then
        sudo_file "$SCRIPT_DIR/system/udev/99-battery-charge-threshold.rules" \
                  /etc/udev/rules.d/99-battery-charge-threshold.rules
    else
        skip "no charge cap — battery udev rule not installed"
    fi
    if [ -n "${HW_MICMUTE_LED:-}" ]; then
        sudo_file "$SCRIPT_DIR/system/udev/99-micmute-led.rules" \
                  /etc/udev/rules.d/99-micmute-led.rules
    else
        skip "no mic-mute LED — that udev rule not installed"
    fi
    run sudo udevadm control --reload-rules
    run sudo udevadm trigger --subsystem-match=power_supply --subsystem-match=leds

    # ── group membership ───────────────────────────────────────────────
    # `power` is what makes the charge cap writable without sudo; video/input
    # cover the backlight and libinput. NOTE: group changes do NOT apply to an
    # already-running session — this needs a real logout, or a reboot.
    local g added=0
    for g in power video input; do
        if getent group "$g" >/dev/null 2>&1 && ! id -nG "$USER" | tr ' ' '\n' | grep -qx "$g"; then
            run sudo usermod -aG "$g" "$USER"; added=1
            ok "added $USER to group $g"
        fi
    done
    [ "$added" = 1 ] && warn "group changes need a full logout (or reboot) to take effect"

    # ── keyd ───────────────────────────────────────────────────────────
    if have keyd; then
        sudo_file "$SCRIPT_DIR/system/keyd/default.conf" /etc/keyd/default.conf
        enable_unit keyd.service
    fi

    # ── zram + sysctl ──────────────────────────────────────────────────
    if pacman -Qq zram-generator >/dev/null 2>&1; then
        sudo_file "$SCRIPT_DIR/system/systemd/zram-generator.conf" /etc/systemd/zram-generator.conf
        sudo_file "$SCRIPT_DIR/system/sysctl.d/99-zram-swappiness.conf" /etc/sysctl.d/99-zram-swappiness.conf
    fi
    sudo_file "$SCRIPT_DIR/system/sysctl.d/20-quiet-printk.conf" /etc/sysctl.d/20-quiet-printk.conf
    run sudo sysctl --system >/dev/null

    # ── polkit ─────────────────────────────────────────────────────────
    # Lets the settings menu enrol and delete fingerprints without polkit
    # raising a password dialog of its own on top of finder's. Only where
    # there is actually a reader — on a machine with none the rule would be
    # loosening an action nothing can invoke. The file itself carries the
    # full reasoning and the trade it makes.
    if [ -n "${HW_FPRINT:-}" ]; then
        sudo_file "$SCRIPT_DIR/system/polkit-1/rules.d/49-fprintd-enroll.rules" \
                  /etc/polkit-1/rules.d/49-fprintd-enroll.rules
    else
        skip "no fingerprint reader — fprintd polkit rule not installed"
    fi

    # ── everyday services ──────────────────────────────────────────────
    # (wifi, bluetooth and the firewall are handled by the `network` phase.)
    have upower           && enable_unit upower.service
    have powerprofilesctl && enable_unit power-profiles-daemon.service
    enable_unit systemd-timesyncd.service
    enable_unit fstrim.timer
    pacman -Qq cups >/dev/null 2>&1 && enable_unit cups.service

    # ── flatpak ────────────────────────────────────────────────────────
    # Installing the package leaves it with NO remotes, so `flatpak install`
    # finds nothing at all. Add Flathub system-wide, matching this setup.
    # hyprland.lua already puts both flatpak export dirs on XDG_DATA_DIRS, so
    # installed apps show up in launchers once a remote exists.
    if have flatpak; then
        if flatpak remotes --system 2>/dev/null | grep -q '^flathub'; then
            skip "flathub remote already configured"
        else
            run sudo flatpak remote-add --if-not-exists --system \
                flathub https://dl.flathub.org/repo/flathub.flatpakrepo
            ok "flathub remote added"
        fi
    fi

    # ── fingerprint retry budget ───────────────────────────────────────
    # A fingerprint reader burns faillock attempts fast; the stock deny=3 locks
    # the account after three bad swipes. Edited key-by-key rather than by
    # replacing the file, which is package-owned.
    if [ -f /etc/security/faillock.conf ] && have fprintd; then
        if ask_yn "Loosen faillock for fingerprint retries (deny 20 / unlock 120s)?" y; then
            run sudo sed -i -E \
                -e 's|^#?\s*deny\s*=.*|deny = 20|' \
                -e 's|^#?\s*fail_interval\s*=.*|fail_interval = 600|' \
                -e 's|^#?\s*unlock_time\s*=.*|unlock_time = 120|' \
                /etc/security/faillock.conf
            ok "faillock.conf updated"
        fi
    fi

    # ── display manager ────────────────────────────────────────────────
    # Done last and gated: enabling a greeter before the session it launches
    # exists is how you end up staring at a login you cannot get past.
    if have hyprland && have tuigreet; then
        local other
        other="$(systemctl list-unit-files --state=enabled --no-legend 2>/dev/null \
                 | awk '{print $1}' | grep -E '^(gdm|sddm|lightdm|lxdm|ly)\.service$' || true)"
        if [ -n "$other" ]; then
            warn "another display manager is enabled: $other"
            warn "enable greetd only after disabling it, or you will get a conflict"
        elif ask_yn "Enable greetd (graphical login) on next boot?" y; then
            sudo_file "$SCRIPT_DIR/system/greetd/config.toml" /etc/greetd/config.toml
            enable_unit greetd.service
            info "at the greeter, log in and start the session with: Hyprland"
        fi
    else
        skip "hyprland or tuigreet missing — greetd not enabled"
    fi
}

# ═══════════════════════════════════════════════════════════════════════
# 9 · NETWORK — wifi, bluetooth, firewall
# ═══════════════════════════════════════════════════════════════════════
phase_network() {
    phase "Wifi, Bluetooth and firewall"
    if [ "$NO_ROOT" = 1 ]; then skip "--no-root given"; return 0; fi
    sudo_prime

    # ── wifi ───────────────────────────────────────────────────────────
    # NetworkManager owns the saved profiles; iwd is only the driver underneath.
    # That pairing is what the taskbar's wifi panel assumes — it talks to nmcli,
    # so NM has to be the thing that stores credentials. Talking to iwd directly
    # would create connections NM cannot see.
    if have nmcli; then
        pacman -Qq iwd >/dev/null 2>&1 && \
            sudo_file "$SCRIPT_DIR/system/NetworkManager/wifi_backend.conf" \
                      /etc/NetworkManager/conf.d/wifi_backend.conf
        enable_unit NetworkManager.service
        run sudo systemctl start NetworkManager.service
        # A fresh install can come up with the radio soft-blocked.
        if have rfkill; then
            run sudo rfkill unblock wifi
            run sudo rfkill unblock bluetooth
        fi
        ok "wifi ready — connect from the taskbar panel, or: nmcli device wifi list"
    else
        skip "NetworkManager not installed"
    fi

    # ── bluetooth ──────────────────────────────────────────────────────
    # No config file needed: BlueZ already defaults to AutoEnable=true (it is
    # present but commented in the shipped main.conf), so enabling the unit is
    # enough to have the adapter powered at boot. Editing a package-owned file
    # to restate its own default would only create .pacnew noise later.
    if have bluetoothctl; then
        enable_unit bluetooth.service
        run sudo systemctl start bluetooth.service
        ok "bluetooth ready"
    else
        skip "bluez-utils not installed"
    fi

    # ── firewall ───────────────────────────────────────────────────────
    if ! have firewall-cmd; then
        skip "firewalld not installed"
        return 0
    fi
    # The service definition has to exist before the zone can reference it.
    sudo_file "$SCRIPT_DIR/system/firewalld/services/localsend.xml" \
              /etc/firewalld/services/localsend.xml
    enable_unit firewalld.service
    run sudo systemctl start firewalld.service

    if [ "$DRY_RUN" = 1 ]; then
        printf '  %sDRY%s firewall-cmd --permanent --zone=public --add-service ssh/dhcpv6-client/localsend, then --reload\n' "$C_DIM" "$C_RST"
        return 0
    fi

    # Wait for the daemon to answer before configuring it — `systemctl start`
    # returns before firewalld has finished coming up, and firewall-cmd against a
    # not-yet-ready daemon fails in a way that looks like a real error.
    local i
    for i in $(seq 1 30); do
        sudo firewall-cmd --state >/dev/null 2>&1 && break
        command sleep 0.2
    done

    # Reload so the new service definition is visible, then add it to the zone.
    # Stock `public` already carries ssh and dhcpv6-client; localsend is the only
    # difference on this setup. --permanent writes the zone file, so the change
    # survives a reboot; the final --reload applies it to the running firewall.
    sudo firewall-cmd --reload >/dev/null 2>&1 || true
    local svc added=0
    for svc in ssh dhcpv6-client localsend; do
        if sudo firewall-cmd --permanent --zone=public --query-service="$svc" >/dev/null 2>&1; then
            skip "public zone already allows $svc"
        else
            run sudo firewall-cmd --permanent --zone=public --add-service="$svc"
            added=1
        fi
    done
    [ "$added" = 1 ] && run sudo firewall-cmd --reload

    info "public zone now allows: $(sudo firewall-cmd --zone=public --list-services 2>/dev/null)"
    ok "firewall configured (LocalSend: TCP+UDP 53317)"
}

# ═══════════════════════════════════════════════════════════════════════
# 10 · VIRTUALISATION — QEMU/KVM via libvirt
# ═══════════════════════════════════════════════════════════════════════
# Goal: after this phase, opening virt-manager and pointing it at a downloaded
# ISO just works — no group juggling, no "network 'default' is not active", no
# permission errors on the disk image.
#
# Four things are needed and none of them are defaults:
#   1. qemu.conf's user/group, or the qemu process cannot read files it owns
#   2. membership of the `libvirt` group, or every virsh call asks for a password
#   3. the modular virt*d sockets enabled (this is the modern split daemon;
#      the monolithic libvirtd is deliberately left alone)
#   4. the default NAT network marked autostart, or guests have no network
#      after the next reboot
phase_virt() {
    phase "Virtual machines"
    if [ "$NO_ROOT" = 1 ]; then skip "--no-root given"; return 0; fi

    if [ "${HW_KVM:-0}" != 1 ]; then
        skip "no hardware virtualisation on this CPU — nothing to configure"
        return 0
    fi
    if ! have virsh; then
        skip "libvirt not installed — run the packages phase first"
        return 0
    fi

    sudo_prime

    # ── 1 · qemu runs as the qemu user ─────────────────────────────────
    # qemu.conf is package-owned and ~45k of commented defaults, so it is
    # edited key-by-key rather than replaced: shipping a whole copy would
    # generate .pacnew noise on every libvirt update.
    local qc=/etc/libvirt/qemu.conf
    if [ -f "$qc" ]; then
        if [ "$(sudo -n grep -cE '^\s*(user|group)\s*=\s*"qemu"' "$qc" 2>/dev/null || echo 0)" = 2 ]; then
            skip "qemu.conf user/group already set"
        else
            run sudo cp -a "$qc" "$qc.bak-$BACKUP_STAMP"
            # Rewrite the key if present (commented or not), else append it.
            run sudo sed -i -E \
                -e 's|^#?\s*user\s*=.*|user = "qemu"|' \
                -e 's|^#?\s*group\s*=.*|group = "qemu"|' "$qc"
            run_sh "sudo grep -qE '^user = \"qemu\"'  $qc || echo 'user = \"qemu\"'  | sudo tee -a $qc >/dev/null"
            run_sh "sudo grep -qE '^group = \"qemu\"' $qc || echo 'group = \"qemu\"' | sudo tee -a $qc >/dev/null"
            ok "qemu.conf: user/group = qemu"
        fi
    fi

    # ── 2 · group membership ───────────────────────────────────────────
    # Same caveat as the `power` group in the system phase: this does NOT
    # reach an already-running session.
    # Only `libvirt`. NOT `kvm`: systemd's own 50-udev-default.rules gives
    # /dev/kvm mode 0666, so kvm membership buys nothing, and adding a group
    # the working reference machine does not have is a silent divergence.
    if getent group libvirt >/dev/null 2>&1 && ! id -nG "$USER" | tr ' ' '\n' | grep -qx libvirt; then
        run sudo usermod -aG libvirt "$USER"
        ok "added $USER to group libvirt"
        warn "log out and back in before virt-manager connects without a password prompt"
    else
        skip "$USER already in the libvirt group"
    fi

    # ── 3 · the modular libvirt daemons ────────────────────────────────
    # Sockets, not services: they are socket-activated, so nothing runs until
    # virt-manager actually connects.
    local u
    for u in virtqemud.socket virtnetworkd.socket virtstoraged.socket \
             virtnodedevd.socket virtsecretd.socket virtlogd.socket; do
        enable_unit "$u"
    done
    run sudo systemctl start virtqemud.socket virtnetworkd.socket

    # ── 4 · the default NAT network ────────────────────────────────────
    # Defined by the package but neither started nor autostarted, which is why
    # a fresh VM reports "Network not active". `virsh net-info` is the honest
    # check; both flags are set independently because either can be off.
    if [ "$DRY_RUN" = 1 ]; then
        info "DRY would mark libvirt's default network autostart and start it"
    elif sudo virsh net-info default >/dev/null 2>&1; then
        if [ "$(sudo virsh net-info default 2>/dev/null | awk '/^Autostart/{print $2}')" != "yes" ]; then
            run sudo virsh net-autostart default
            ok "default network set to autostart"
        else
            skip "default network already autostart"
        fi
        if [ "$(sudo virsh net-info default 2>/dev/null | awk '/^Active/{print $2}')" != "yes" ]; then
            run sudo virsh net-start default
            ok "default network started"
        else
            skip "default network already active"
        fi
    else
        warn "libvirt has no 'default' network defined — create one in virt-manager"
    fi

    # The default storage pool holds the disk images. Package-provided, but
    # start it so the New VM wizard has somewhere to put a qcow2.
    if [ "$DRY_RUN" != 1 ] && sudo virsh pool-info default >/dev/null 2>&1; then
        sudo virsh pool-autostart default >/dev/null 2>&1 || true
        sudo virsh pool-start default >/dev/null 2>&1 || true
        ok "default storage pool active ($(sudo virsh pool-dumpxml default 2>/dev/null | sed -n 's|.*<path>\(.*\)</path>.*|\1|p'))"
    fi

    # ── 5 · ISO library, and qemu's route to it ────────────────────────
    # A second pool so ISOs are not mixed in with the disk images, and so the
    # New VM wizard opens somewhere useful. $HOME, never a literal path: this
    # tree is mirrored to a public repo.
    local isodir="$HOME/iso files"
    run mkdir -p "$isodir"
    if [ "$DRY_RUN" = 1 ]; then
        info "DRY would define+autostart the iso_files pool at $isodir"
    elif have virsh; then
        if sudo virsh pool-info iso_files >/dev/null 2>&1; then
            skip "iso_files pool already defined"
        else
            run sudo virsh pool-define-as iso_files dir - - - - "$isodir"
            sudo virsh pool-build iso_files >/dev/null 2>&1 || true
            run sudo virsh pool-autostart iso_files
            sudo virsh pool-start iso_files >/dev/null 2>&1 || true
            ok "iso_files pool -> $isodir"
        fi
    fi

    # qemu.conf above makes guests run as the `qemu` user, and $HOME is 0710 on
    # this install — so qemu cannot traverse into it and every ISO kept in the
    # home tree fails to open with a bare permission error that names the file,
    # not the directory above it. One execute bit, no read: qemu can walk
    # through $HOME but still cannot list it.
    if getent passwd qemu >/dev/null 2>&1 && have setfacl; then
        # `getfacl | grep -q` under pipefail is the trap this repo has hit four
        # times; count into a variable instead.
        local qacl
        qacl=$(getfacl -p "$HOME" 2>/dev/null | grep -c '^user:qemu:' || true)
        if [ "$qacl" -gt 0 ]; then
            skip "qemu already has traverse on $HOME"
        else
            run setfacl -m u:qemu:--x "$HOME"
            ok "qemu granted traverse (--x, no read) on $HOME"
        fi
    fi

    # ── 6 · osinfo entries upstream does not carry ─────────────────────
    # virt-manager REFUSES to leave step 2 of the wizard when libosinfo cannot
    # name the media — "You must select an OS" — which reads like the VM failed
    # to build. It did not; the OS choice only seeds default device models.
    # Upstream detects Debian, NixOS, Ubuntu, Fedora, openSUSE and Windows
    # 10/11 unaided but has no entry at all for Mint or Omarchy. This is a
    # DIRECTORY, not a list in this script: adding a distro is adding a file.
    # libosinfo's user path is $XDG_CONFIG_HOME/osinfo, which pacman never
    # touches, so these survive an osinfo-db update.
    deploy_dir "$SCRIPT_DIR/osinfo" "$HOME/.config/osinfo" || true

    # ── 7 · the VM helper scripts on PATH ──────────────────────────────
    # They are deployed with everything else into ~/.config/scripts, which is
    # not on PATH; ~/.local/bin is (set by .zshrc). Symlinks, not copies, so a
    # later configs phase updates them without touching this one.
    local vs
    if [ "$DRY_RUN" = 1 ]; then
        info "DRY would link vm-create and vm-tune into $HOME/.local/bin"
    else
        mkdir -p "$HOME/.local/bin"
        for vs in vm-create vm-tune; do
            if [ -x "$HOME/.config/scripts/$vs.sh" ]; then
                ln -sfn "$HOME/.config/scripts/$vs.sh" "$HOME/.local/bin/$vs"
                ok "$vs on PATH"
            else
                warn "$vs.sh not deployed — run the configs phase first"
            fi
        done
    fi

    ok "VMs ready — 'vm-create <name> <iso>', or virt-manager for the wizard"
}

# ═══════════════════════════════════════════════════════════════════════
# 11 · THEMING
# ═══════════════════════════════════════════════════════════════════════
phase_theming() {
    phase "Theming"

    # pywal templates must exist before `wal` runs, or it emits nothing for them.
    run mkdir -p "$HOME/.config/wal/templates"
    local t
    for t in "$SCRIPT_DIR"/templates/wal/*; do
        deploy_file "$t" "$HOME/.config/wal/templates/$(basename "$t")"
    done

    # Pick a wallpaper: whatever the mirror's hyprpaper.conf named, else the
    # first image in the wallpapers directory.
    local wp="" wanted
    wanted="$(sed -n 's/^\s*path\s*=\s*//p' "$DOTDIR/hypr/hyprpaper.conf" 2>/dev/null | head -1)"
    if [ -n "$wanted" ] && [ -f "$HOME/Pictures/wallpapers/$(basename "$wanted")" ]; then
        wp="$HOME/Pictures/wallpapers/$(basename "$wanted")"
    else
        wp="$(find "$HOME/Pictures/wallpapers" -maxdepth 1 -type f \
              \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) 2>/dev/null | sort | head -1)"
    fi

    if [ -n "$wp" ]; then
        info "priming pywal from $(basename "$wp")"
        run_sh "wal -i '$wp' -n -q"
        ok "colour scheme generated"

        # hyprland.lua does require('colors-hyprland'), resolved relative to
        # ~/.config/hypr. pywal writes into ~/.cache/wal, so the two are joined
        # by a symlink — created here with the CURRENT $HOME, because the copy
        # carried in the dotfiles mirror is an absolute link to the original
        # machine's home and is dangling anywhere else.
        run ln -sfn "$HOME/.cache/wal/colors-hyprland.lua" "$HOME/.config/hypr/colors-hyprland.lua"
        ok "colors-hyprland.lua linked to the wal cache"

        # hyprpaper.conf is generated, not copied: it needs this machine's
        # monitor name and this user's wallpaper path.
        if [ "$DRY_RUN" = 0 ]; then
            cat >"$HOME/.config/hypr/hyprpaper.conf" <<HP
wallpaper {
monitor = ${MON_NAME:-}
path = $wp
fit_mode = cover
}
splash = false
HP
        fi
        ok "hyprpaper.conf generated for ${MON_NAME:-<any monitor>}"
    else
        warn "no wallpaper found in ~/Pictures/wallpapers — theming left at defaults"
        warn "add an image there and run: ~/.config/finder/apply-wallpaper.sh <path>"
    fi

    # GTK / cursor. Purely cosmetic, and only if the themes actually installed.
    if have gsettings; then
        local gs="gsettings set org.gnome.desktop.interface"
        [ -d /usr/share/icons/Bibata-Original-Ice ] && run_sh "$gs cursor-theme 'Bibata-Original-Ice'"
        run_sh "$gs cursor-size 28"
        [ -d /usr/share/icons/Papirus-Dark ] && run_sh "$gs icon-theme 'Papirus-Dark'"
        # The Arch package installs lowercase, suffixed directory names
        # (catppuccin-mocha-blue-standard+default). Only switch to it if it is
        # actually present; otherwise stay on Adwaita-dark, which is what this
        # setup actually runs.
        if [ -d '/usr/share/themes/catppuccin-mocha-blue-standard+default' ] && \
           [ "${USE_CATPPUCCIN:-0}" = 1 ]; then
            run_sh "$gs gtk-theme 'catppuccin-mocha-blue-standard+default'"
        else
            run_sh "$gs gtk-theme 'Adwaita-dark'"
        fi
        run_sh "$gs color-scheme 'prefer-dark'"
        ok "GTK/cursor settings applied"
    fi
}

# ═══════════════════════════════════════════════════════════════════════
# 12 · HYPRLAND PLUGINS
# ═══════════════════════════════════════════════════════════════════════
# 13 · HIBERNATION  (opt-in — this one edits the bootloader)
# ═══════════════════════════════════════════════════════════════════════
phase_hibernation() {
    phase "Hibernation"

    local sh="$HOME/.config/scripts/setup-hibernation.sh"
    [ -x "$sh" ] || { skip "setup-hibernation.sh not deployed"; return 0; }

    if [ "$NO_ROOT" = 1 ]; then skip "--no-root given"; return 0; fi
    if ! grep -qw disk /sys/power/state 2>/dev/null; then
        skip "this kernel cannot hibernate — nothing to do"
        return 0
    fi
    # NOTE: not `swapon | grep -q` — grep -q exits on first match, swapon dies of
    # SIGPIPE, and `set -o pipefail` turns that into a false negative. Capture
    # first, then test. (Same trap as the font check in the verify phase.)
    local nonzram
    nonzram=$(swapon --show=NAME --noheadings 2>/dev/null | grep -cv '^/dev/zram' || true)
    if [ "${nonzram:-0}" -gt 0 ] && grep -q 'resume=' /proc/cmdline 2>/dev/null; then
        ok "hibernation is already configured (real swap present, resume= on the running cmdline)"
        return 0
    fi

    info "Hibernation needs a real swap file (zram cannot hold the image — it"
    info "lives in the RAM being saved) and a resume= kernel parameter."
    info ""
    info "This is the ONLY part of the installer that edits your bootloader."
    info "Here is exactly what it would change on this machine:"
    printf '\n'
    if [ "$DRY_RUN" = 1 ]; then
        run_sh "'$sh' --dry-run"
        return 0
    fi
    "$sh" --dry-run || { warn "hibernation is not possible here — see the reason above"; return 0; }
    printf '\n'

    if ask_yn "Set up hibernation now? (edits fstab, mkinitcpio and the bootloader)" y; then
        if [ "$ASSUME_YES" = 1 ]; then
            run sudo -E "$sh" --yes
        else
            run sudo -E "$sh"
        fi
        ok "hibernation configured — it takes effect after a reboot"
    else
        skip "hibernation not configured. Run it later with:"
        skip "  sudo $sh"
    fi
}

# ═══════════════════════════════════════════════════════════════════════
# 14 · FINGERPRINT — enrolment, if there is a reader
# ═══════════════════════════════════════════════════════════════════════
# Runs late on purpose: it is the one phase that needs the user to physically
# touch the sensor, several times per finger, so everything that can be done
# without them is already done.
#
# Note this enrols fingerprints only — it does NOT wire fprintd into PAM.
# The lockscreen shells out to `fprintd-verify` directly (see
# lockscreen/LockContext.qml), so enrolment is all it needs, and editing
# /etc/pam.d/system-auth to add pam_fprintd is a well-known way to lock
# yourself out of your own machine.
FINGERS=(
    left-thumb  left-index-finger  left-middle-finger  left-ring-finger  left-little-finger
    right-thumb right-index-finger right-middle-finger right-ring-finger right-little-finger
)

phase_fingerprint() {
    phase "Fingerprint enrolment"

    if [ -z "${HW_FPRINT:-}" ]; then
        if have fprintd-enroll; then
            skip "fprintd is installed but no reader was detected — nothing to enrol"
        else
            skip "no fingerprint reader detected"
        fi
        return 0
    fi
    ok "reader: $HW_FPRINT"

    if [ "$DRY_RUN" = 1 ]; then
        info "DRY would offer to enrol fingerprints (interactive — needs the sensor)"
        return 0
    fi
    # A finger swipe cannot be automated, so an unattended run must not hang
    # here waiting for one.
    if [ "$ASSUME_YES" = 1 ]; then
        skip "--yes given: enrolment needs you at the sensor. Run later with:"
        info "    $SCRIPT_DIR/install.sh --only fingerprint"
        return 0
    fi

    # What is already enrolled, so the menu can say so rather than letting the
    # user silently overwrite a finger.
    local enrolled=""
    enrolled="$(fprintd-list "$USER" 2>/dev/null | sed -n 's/^ *- #[0-9]*: *//p' || true)"
    if [ -n "$enrolled" ]; then
        info "already enrolled: $(printf '%s' "$enrolled" | tr '\n' ' ')"
    fi

    ask_yn "Set up fingerprint login now?" y || { skip "fingerprint enrolment declined"; return 0; }

    while true; do
        # Rebuild the labels each pass so a finger just enrolled is marked.
        enrolled="$(fprintd-list "$USER" 2>/dev/null | sed -n 's/^ *- #[0-9]*: *//p' || true)"
        # Match against a delimited string rather than piping into `grep -q`:
        # grep exits on its first match, the producer dies of SIGPIPE, and
        # `set -o pipefail` then reports a false failure. This file has been
        # bitten by that four times.
        local elist=$'\n'"$enrolled"$'\n'
        local labels=() f mark
        for f in "${FINGERS[@]}"; do
            mark=""
            case "$elist" in
                *$'\n'"$f"$'\n'*) mark="   ${C_DIM}(enrolled — re-scanning replaces it)${C_RST}" ;;
            esac
            labels+=("${f//-/ }$mark")
        done

        local pick finger
        pick="$(ask_choice "Which finger?" 7 "${labels[@]}")"
        finger="${FINGERS[$((pick-1))]}"

        printf '\n  %sScanning %s.%s Lift and re-place the finger when prompted,\n' \
               "$C_B" "${finger//-/ }" "$C_RST"
        printf '  usually five to eight times, until it reports enroll-completed.\n\n'

        # fprintd-enroll drives the sensor and prints its own progress; it must
        # keep the terminal. A failed scan is not fatal — offer a retry.
        if fprintd-enroll -f "$finger" </dev/tty; then
            ok "$finger enrolled"
        else
            err "enrolment of $finger did not complete"
            ask_yn "Try that finger again?" y && continue
        fi

        ask_yn "Enrol another finger?" n || break
    done

    enrolled="$(fprintd-list "$USER" 2>/dev/null | sed -n 's/^ *- #[0-9]*: *//p' || true)"
    if [ -n "$enrolled" ]; then
        ok "enrolled fingers: $(printf '%s' "$enrolled" | tr '\n' ' ')"
        info "the lockscreen picks these up automatically — no PAM changes needed"
    fi
}

# ═══════════════════════════════════════════════════════════════════════
# 15 · VERIFY
# ═══════════════════════════════════════════════════════════════════════
V_PASS=0; V_FAIL=0
chk()  { V_PASS=$((V_PASS+1)); ok "$1"; }
bad()  { V_FAIL=$((V_FAIL+1)); err "$1"; }
check() { if eval "$2" >/dev/null 2>&1; then chk "$1"; else bad "$1"; fi; }

phase_verify() {
    phase "Verify"
    if [ "$DRY_RUN" = 1 ]; then skip "nothing was installed (dry run)"; return 0; fi

    local a
    # ── the four Quickshell apps ───────────────────────────────────────
    for a in taskbar macshell finder lockscreen; do
        check "$a/shell.qml deployed" "[ -f '$HOME/.config/$a/shell.qml' ]"
    done

    # ── the compositor config actually parses ──────────────────────────
    # A config that crashes partway through silently loses every bind after the
    # crash point, so this is checked rather than assumed.
    if have lua5.4; then
        if lua5.4 "$SCRIPT_DIR/lib/luastub.lua" "$HOME/.config/hypr/hyprland.lua" >/dev/null 2>&1; then
            chk "hyprland.lua parses cleanly ($(lua5.4 "$SCRIPT_DIR/lib/luastub.lua" \
                 "$HOME/.config/hypr/hyprland.lua" 2>/dev/null | grep -o '[0-9]*$') binds)"
        else
            bad "hyprland.lua FAILED to parse — binds would be silently lost"
        fi
    else
        skip "lua5.4 absent, config parse not checked"
    fi

    # ── no path from another machine survived ──────────────────────────
    # The rc files are in this sweep deliberately: they are deployed by the
    # configs phase, they are the one deployed surface that carries absolute
    # home paths in normal use, and leaving them out is how a broken alias
    # ships while this check reports clean.
    local foreign
    # --exclude backup_configs.sh, for the same reason its OWN greps exclude it:
    # a scanner cannot scan itself. That script performs the /home/USER
    # redaction, so the placeholder is necessarily written out in its source,
    # and this check matched it and reported the machine as carrying another
    # machine's home. Measured 2026-09-11: the single hit across every deployed
    # config was backup_configs.sh naming its own replacement string. The map
    # already records this trap for the script's internal greps; this check is
    # the same trap one layer out, and had never been given the same exclusion.
    #
    # Safe to exclude here in a way excluding an ordinary config would not be,
    # because the file is source in this repo and the one file whose whole
    # purpose is to be read before it is trusted.
    foreign="$(grep -rhoI --exclude='*.bak*' --exclude='backup_configs.sh' \
                 -E '/home/[A-Za-z0-9_.-]+' \
                 "$HOME/.config"/{hypr,taskbar,macshell,finder,lockscreen,scripts} \
                 "$HOME/.zshrc" "$HOME/.bashrc" 2>/dev/null \
               | sort -u | grep -vx "/home/$USER" || true)"
    if [ -n "$foreign" ]; then
        bad "deployed configs reference another machine's home: $(echo "$foreign" | tr '\n' ' ')"
    else
        chk "no foreign home paths in the deployed configs"
    fi

    # ── every script a keybind calls exists and is executable ──────────
    local missing=0 s
    while read -r s; do
        s="${s/#\~/$HOME}"
        [ -x "$s" ] || { bad "keybind target not executable: $s"; missing=1; }
    done < <(sed 's/--.*//' "$HOME/.config/hypr/hyprland.lua" \
             | grep -oE '~/\.config/[A-Za-z0-9_./-]+\.sh' | sort -u)
    [ "$missing" = 0 ] && chk "every keybind script exists and is executable"

    # ── the settings menu's back end ───────────────────────────────────
    # These are reached from QML, never from a keybind, so the sweep above
    # cannot see them: finder's settings pages shell out to them by absolute
    # path. A missing or non-executable one fails the same silent way the agent
    # collectors do — the page opens, the action does nothing, and there is no
    # error anywhere. Named individually rather than globbed, because the point
    # is to catch one that never got deployed, and a glob over what IS there
    # can only ever pass.
    local sm miss_sm=""
    # keybinds.sh and window-rules.sh joined this list on 2026-09-11 with the
    # pages they serve. Both are reached only from QML — Settings.qml calls
    # `window-rules.sh list` to draw the Window rules page at all, and
    # keybinds.sh is what writes a reassignment back — so both fail in exactly
    # the silent way this check exists for: the page opens, empty or inert, and
    # nothing is logged anywhere.
    for sm in ui-prefs.sh list-keybinds.sh keybinds.sh window-rules.sh \
              icon-index.sh about-system.sh \
              privileged-run.sh change-password.sh firewall.sh fingerprint.sh \
              webapp-install.sh webapp-remove.sh nightlight.sh ocr-region.sh; do
        [ -x "$HOME/.config/scripts/$sm" ] || miss_sm="$miss_sm $sm"
    done
    if [ -n "$miss_sm" ]; then
        bad "settings-menu back end missing or not executable:$miss_sm"
    else
        chk "settings-menu back end deployed and executable (14 scripts)"
    fi

    # ── the authentication surface ─────────────────────────────────────
    # Both the lock screen (lockscreen/LockContext.qml) and finder's password
    # box (finder/PasswordPrompt.qml) authenticate against the `vlock` PAM
    # service, chosen because it is plain pam_unix with no faillock — see the
    # note in PasswordPrompt.qml. It is a FILE from the kbd package, not
    # anything either app ships, and without it every password in this desktop
    # is rejected: the screen cannot be unlocked and no settings action can
    # authorise. systemd depends on kbd so this is expected to pass; it is
    # checked because the cost of it failing unnoticed is being locked out.
    if [ -r /etc/pam.d/vlock ]; then
        chk "/etc/pam.d/vlock present (the PAM service both password boxes use)"
    else
        bad "/etc/pam.d/vlock is MISSING — the lock screen and the settings password box will reject every password. Install it with: sudo pacman -S kbd"
    fi

    # ── polkit's password prompts ──────────────────────────────────────
    # Every prompt polkit raises on this desktop is drawn by finder's password
    # box, through scripts/polkit-agent.py. The failure mode if any piece of
    # this is missing is the worst kind: nothing appears and nothing errors —
    # the program that wanted a privilege simply waits, because polkit is
    # content to wait forever for an agent that never answers. Hence three
    # separate checks rather than one.
    if [ -x "$HOME/.config/scripts/polkit-agent.py" ]; then
        chk "polkit-agent.py deployed and executable"
    else
        bad "polkit-agent.py missing or not executable — NOTHING will answer a polkit prompt (no dialog, no error, the caller just waits)"
    fi
    # python-gobject and the two typelibs polkit ships. Imported rather than
    # asked of pacman: a typelib can be present and unloadable, and the agent's
    # very first statement is this import — it exits there, before it registers
    # anything, if it fails.
    if python3 -c "import gi; gi.require_version('Polkit','1.0'); gi.require_version('PolkitAgent','1.0'); from gi.repository import Polkit, PolkitAgent" >/dev/null 2>&1; then
        chk "python-gobject + the Polkit/PolkitAgent typelibs import"
    else
        bad "the polkit agent cannot import its bindings — install python-gobject (and polkit, which ships the typelibs)"
    fi
    # polkit-agent-helper-1 is the only thing on the machine allowed to answer
    # polkitd, and the agent drives it through PolkitAgent.Session.
    #
    # This used to assert the SETUID BIT, and that assertion is obsolete as of
    # polkit 127 — it failed on this very machine on 2026-09-11 while polkit was
    # working perfectly. Arch's polkit 127-3 ships the helper 0755 and starts it
    # through SOCKET ACTIVATION instead (polkit-agent-helper.socket and
    # polkit-agent-helper@.service, both in the package), so systemd launches it
    # as root and the setuid bit is no longer how it gains privilege.
    # `pacman -Qkk polkit` confirms the 0755 mode is the packaged one, and the
    # journal shows the helper running and doing PAM auth.
    #
    # So the check follows the mechanism: the executable must exist, and it must
    # be reachable EITHER way — setuid on older polkit, or via the socket on
    # 127+. Asserting only one of the two is what turned a working machine into
    # a red line, and a check that cries wolf is a check that gets switched off.
    if [ ! -x /usr/lib/polkit-1/polkit-agent-helper-1 ]; then
        bad "/usr/lib/polkit-1/polkit-agent-helper-1 is missing — no password can ever be accepted by polkit"
    elif [ -u /usr/lib/polkit-1/polkit-agent-helper-1 ]; then
        chk "polkit-agent-helper-1 present and setuid (pre-127 mechanism)"
    elif systemctl is-active --quiet polkit-agent-helper.socket; then
        chk "polkit-agent-helper-1 present, privileged by socket activation"
    else
        bad "polkit-agent-helper-1 is neither setuid nor socket-activated — no password can ever be accepted by polkit"
    fi
    # Running, finally — but only worth reporting inside a live session: on a
    # fresh rebuild from a TTY nothing has autostarted yet, and saying so would
    # be noise rather than a finding.
    if [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
        if pgrep -f "scripts/polkit-agent.py" >/dev/null 2>&1; then
            chk "the polkit agent is running in this session"
        else
            warn "the polkit agent is not running — it autostarts from hyprland.lua, so this session predates the change or it died. Start it with: setsid ~/.config/scripts/polkit-agent.py </dev/null >/dev/null 2>&1 &"
        fi
    fi

    # ── night light ────────────────────────────────────────────────────
    # The Display panel's night-light row is a hyprsunset front end, and it
    # reads "on" as "hyprsunset is running". With the binary absent the toggle
    # is not broken so much as permanently off, which looks identical.
    if have hyprsunset; then
        chk "hyprsunset present (the Display panel's night light)"
    else
        bad "hyprsunset not installed — the Display panel's night light can never turn on"
    fi

    # ── fingerprint enrolment authorisation ────────────────────────────
    # Enrolling and deleting check net.reactivated.fprint.device.enroll, which
    # upstream leaves at auth_self_keep — meaning the session's polkit agent
    # raises a password dialog of ITS own, on top of the one finder already
    # drew. The rule grants it to the local active user in wheel, matching the
    # `verify` action the lock screen already relies on. Without it the page
    # still works: fingerprint.sh reports ENROLL_READY="no" and the page says
    # so rather than hanging. So this is a warning, not a failure.
    #
    # Asked of polkit, NOT by looking for the file. /etc/polkit-1/rules.d is
    # 0750 root:polkitd, so `[ -r ... ]` is false for this user whether the
    # rule is there or not — measured: the first version of this check
    # reported the rule absent on a machine where pkcheck answered
    # "polkit.result=yes". Ask the thing that decides. pkcheck with no
    # --allow-user-interaction returns the verdict without raising a dialog,
    # which is the same call `fingerprint.sh status` makes for ENROLL_READY.
    if [ -n "${HW_FPRINT:-}" ] && have pkcheck; then
        if pkcheck --action-id net.reactivated.fprint.device.enroll --process $$ >/dev/null 2>&1; then
            chk "fingerprint enrolment is authorised without a second polkit dialog"
        else
            warn "enrolling a fingerprint is not authorised for this session, so Settings will report it as unavailable rather than hanging behind a dialog. Install the rule with: $SCRIPT_DIR/install.sh --only system"
        fi
    fi

    # ── hardware profile ───────────────────────────────────────────────
    check "hardware.env written" "[ -s '$HOME/.config/scripts/hardware.env' ]"

    # ── theming ────────────────────────────────────────────────────────
    check "pywal colours generated" "[ -s '$HOME/.cache/wal/colors.json' ]"
    check "colors-hyprland.lua resolves" "[ -f '$HOME/.config/hypr/colors-hyprland.lua' ]"
    # NOTE: do not use `fc-list | grep -q` here — grep -q exits on first match,
    # fc-list dies of SIGPIPE, and `set -o pipefail` then reports a false
    # failure. grep -c reads all of its input, so no signal is raised.
    check "JetBrainsMono Nerd Font installed" \
          "[ \"\$(fc-list | grep -ci 'JetBrainsMono Nerd Font')\" -gt 0 ]"

    # ── runtime dependencies the code shells out to ────────────────────
    local b
    for b in hyprctl quickshell qs socat jq fd fzf wl-copy wl-paste grim notify-send \
             gio qalc pdftoppm brightnessctl wal inotifywait nmcli bluetoothctl \
             python3 \
             slurp tesseract magick hyprsunset pkcheck busctl chpasswd; do
        have "$b" || bad "missing runtime dependency: $b"
    done
    chk "runtime dependency sweep finished"

    # ── battery cap privilege model ────────────────────────────────────
    if [ "${HW_CHARGE_CAP:-0}" = 1 ]; then
        local bp="/sys/class/power_supply/${HW_BATTERY}"
        local th="$bp/charge_control_end_threshold"
        if [ -w "$th" ]; then
            chk "charge cap is writable without sudo"
        else
            warn "charge cap not yet writable — expected until you log out and back in"
            warn "(group membership does not apply to an already-running session)"
        fi

        # The watchdog does not trust the cap it wrote — it watches the PACK to
        # decide whether the EC is honouring it, because sysfs only ever echoes
        # the last value written (see apply-battery-threshold.sh note 1, and
        # the charge-cap section of the system map). That test needs two
        # readings, and a battery that exposes neither pair leaves --check
        # permanently unable to conclude: no warning is ever raised, the panel
        # goes on looking correct, and the pack quietly fills. Precisely the
        # silent failure this phase exists for, so it is asserted rather than
        # assumed. Both are checked as a PAIR because the script accepts either
        # unit convention: charge_* in uAh, energy_* in uWh.
        if [ -r "$bp/charge_now" ] || [ -r "$bp/energy_now" ]; then
            chk "battery reports a charge level the cap watchdog can measure"
        else
            warn "no charge_now/energy_now on ${HW_BATTERY} — the watchdog can"
            warn "re-assert the cap but can never verify the EC is honouring it"
        fi
        if [ -r "$bp/current_now" ] || [ -r "$bp/power_now" ]; then
            chk "battery reports current flow, so a lapsed cap is caught in one check"
        else
            warn "no current_now/power_now on ${HW_BATTERY} — a lapsed cap is still"
            warn "caught, but from the slow charge-gain window rather than in one check"
        fi
    fi

    # ── network stack ──────────────────────────────────────────────────
    if have nmcli; then
        check "NetworkManager active" "systemctl is-active NetworkManager.service"
        # -n on a command substitution: no pipeline, so no pipefail/SIGPIPE
        # trap, and no dependency on bc (which is not installed by default).
        check "wifi backend is iwd" \
              "[ -n \"\$(grep -rhs 'wifi.backend=iwd' /etc/NetworkManager/conf.d/ 2>/dev/null)\" ]"
    fi
    have bluetoothctl && check "bluetooth active" "systemctl is-active bluetooth.service"

    if have firewall-cmd; then
        check "firewalld active" "systemctl is-active firewalld.service"
        # NOTE: not `... | grep -q`; see the SIGPIPE note on the font check.
        check "LocalSend allowed through the firewall" \
              "[ \"\$(firewall-cmd --permanent --zone=public --list-services 2>/dev/null | grep -c localsend)\" -gt 0 ]"
        check "LocalSend covers TCP and UDP 53317" \
              "[ \"\$(grep -c 'port=\"53317\"' /etc/firewalld/services/localsend.xml 2>/dev/null)\" = 2 ]"
    fi

    check "first-boot profile completer deployed" \
          "[ -x '$HOME/.config/scripts/complete-hardware-profile.sh' ]"

    # ── the agents panel ───────────────────────────────────────────────
    # The panel is an extension point, not a fixed feature: every executable
    # ~/.config/scripts/agent-usage-<id> is a collector, and a tab exists
    # because a collector wrote a record into the state dir. Nothing in
    # shell.qml names an agent, so there is no list to check against — the
    # only honest test is to run the writer and count what it left.
    #
    # Both halves of that contract fail SILENTLY. A collector without its
    # execute bit is simply not enumerated (by update.sh or by the taskbar's
    # own scan), and update.sh still exits 0 having written nothing; the
    # result is a module that never appears, with no error anywhere. That is
    # measured behaviour, not a worry, which is why this block exists.
    local usage_dir="${XDG_STATE_HOME:-$HOME/.local/state}/hyprahaan/agents/usage"
    local col cols=0 unexec=""
    for col in "$HOME/.config/scripts"/agent-usage-*; do
        [ -e "$col" ] || continue                       # nullglob is not set
        [ "${col##*/}" = agent-usage-update.sh ] && continue
        cols=$((cols + 1))
        [ -x "$col" ] || unexec="$unexec ${col##*/}"
    done
    if [ "$cols" = 0 ]; then
        warn "no agent-usage-* collectors installed — the agents panel will never appear"
    elif [ -n "$unexec" ]; then
        bad "agent collector(s) not executable, so nothing enumerates them:$unexec"
    elif [ ! -x "$HOME/.config/scripts/agent-usage-update.sh" ]; then
        bad "agent-usage-update.sh missing or not executable — no record ever gets written"
    else
        chk "$cols agent collector(s) installed and executable"
        # End to end, and cheap: the collectors run concurrently and a fresh
        # machine authenticates none of them, so they bail before any network
        # probe — 0.1 s measured for both. Safe with no agent installed, too:
        # a collector for an absent agent still writes a zeroed record, which
        # is how it reports "nothing yet" rather than failing, and the panel
        # gates its tabs on the counters rather than on the file existing.
        if "$HOME/.config/scripts/agent-usage-update.sh" >/dev/null 2>&1; then
            local recs
            # NOTE: `find | grep -c`, never `grep -q` — see the SIGPIPE note on
            # the font check. `|| echo 0` because grep -c exits 1 on no match.
            recs="$(find "$usage_dir" -maxdepth 1 -name '*.json' 2>/dev/null \
                    | grep -c . || echo 0)"
            if [ "${recs:-0}" -gt 0 ]; then
                chk "agent usage records written ($recs in ${usage_dir/#"$HOME"/\~})"
            else
                bad "the collectors ran but wrote no record to $usage_dir"
            fi
        else
            # Not fatal by design: a failed collector leaves the previous
            # record in place, so the panel shows stale numbers rather than none.
            warn "agent-usage-update.sh returned non-zero — a collector failed; the panel will show stale data"
        fi
    fi
    # The hero mark is resolved with Qt.resolvedUrl relative to shell.qml, so
    # assets/ has to travel WITH it. Missing, the panel still works and falls
    # back to the bar glyph — a degradation nothing else would ever report.
    local marks
    marks="$(find "$HOME/.config/taskbar/assets" -maxdepth 1 -name '*.svg' 2>/dev/null \
             | grep -c . || echo 0)"
    if [ "${marks:-0}" -gt 0 ]; then
        chk "taskbar agent marks deployed ($marks svg)"
    else
        warn "~/.config/taskbar/assets holds no agent mark — the panel hero falls back to the bar glyph"
    fi

    # ── default applications ───────────────────────────────────────────
    # mimeapps.list is what makes "open this file" pick the right app. A
    # default pointing at a .desktop that is not installed is not fatal (the
    # lookup falls through to the next association) but it is worth naming,
    # because it silently changes which app opens your files.
    if [ -s "$HOME/.config/mimeapps.list" ]; then
        chk "mimeapps.list deployed ($(grep -c '=' "$HOME/.config/mimeapps.list") associations)"
        local d dangling=""
        while read -r d; do
            [ -f "/usr/share/applications/$d" ] || \
            [ -f "$HOME/.local/share/applications/$d" ] || dangling="$dangling $d"
        done < <(sed -n '/^\[Default Applications\]/,/^\[/p' "$HOME/.config/mimeapps.list" \
                 | grep -oE '[A-Za-z0-9_.+-]+\.desktop' | sort -u)
        if [ -n "$dangling" ]; then
            warn "default apps not installed (openers fall through):$dangling"
        else
            chk "every default application is installed"
        fi
    else
        bad "mimeapps.list missing — file associations will be unset"
    fi

    # ── virtualisation ─────────────────────────────────────────────────
    if [ "${HW_KVM:-0}" = 1 ] && have virsh; then
        check "libvirt qemu daemon socket enabled" "systemctl is-enabled virtqemud.socket"
        # `id -nG` reads the CURRENT session, which will not show a group added
        # minutes ago; getent reads the on-disk database, which does.
        check "$USER is in the libvirt group" \
              "getent group libvirt | grep -q '[:,]$USER\(,\|\$\)'"
        # qemu.conf is world-readable (-rw-r--r--), so this needs no sudo —
        # and must not use it: a `sudo -n` that cannot authenticate would fail
        # the check on a file that is perfectly correct.
        check "qemu.conf sets user/group" \
              "[ \"\$(grep -cE '^(user|group) = \"qemu\"' /etc/libvirt/qemu.conf 2>/dev/null || echo 0)\" = 2 ]"
        # virsh against qemu:///system does need root. Rather than report a
        # false failure when sudo cannot authenticate non-interactively, say so.
        if sudo -n true 2>/dev/null; then
            if sudo -n virsh net-info default >/dev/null 2>&1; then
                check "libvirt default network autostarts" \
                      "[ \"\$(sudo -n virsh net-info default 2>/dev/null | awk '/^Autostart/{print \$2}')\" = yes ]"
                check "libvirt default network is active" \
                      "[ \"\$(sudo -n virsh net-info default 2>/dev/null | awk '/^Active/{print \$2}')\" = yes ]"
            else
                warn "libvirt has no 'default' network — new VMs will have no NAT networking"
            fi
        else
            skip "libvirt network state needs root; re-run the virt phase to check it"
        fi

        # The wizard dead-ends on an unrecognised ISO, so the local osinfo
        # entries are load-bearing, not cosmetic. grep -c, not grep -q: this
        # file runs under pipefail and a -q that exits early SIGPIPEs the
        # producer, which is the failure this repo has hit four times.
        if have osinfo-query; then
            check "osinfo carries the local Omarchy entry" \
                  "[ \"\$(osinfo-query os 2>/dev/null | grep -c omarchy)\" -gt 0 ]"
            check "osinfo carries the local Linux Mint entry" \
                  "[ \"\$(osinfo-query os 2>/dev/null | grep -c linuxmint)\" -gt 0 ]"
        fi
        # Guests run as the qemu user; without traverse on $HOME every ISO in
        # the home tree fails to open.
        if getent passwd qemu >/dev/null 2>&1 && have getfacl; then
            check "qemu can traverse \$HOME (ISOs are readable)" \
                  "[ \"\$(getfacl -p '$HOME' 2>/dev/null | grep -c '^user:qemu:')\" -gt 0 ]"
        fi
        # Reached by name from an interactive shell, never from a keybind, so
        # the keybind sweep above cannot see them.
        local vs
        for vs in vm-create vm-tune; do
            check "$vs is on PATH" "[ -x '$HOME/.local/bin/$vs' ]"
        done
    fi

    # ── fingerprint ────────────────────────────────────────────────────
    if [ -n "${HW_FPRINT:-}" ]; then
        local fcount
        fcount="$(fprintd-list "$USER" 2>/dev/null | grep -c '^ *- #' || true)"
        if [ "${fcount:-0}" -gt 0 ]; then
            chk "fingerprint reader with $fcount finger(s) enrolled"
        else
            warn "fingerprint reader present but nothing enrolled — run: $SCRIPT_DIR/install.sh --only fingerprint"
        fi
    fi

    # ── NVIDIA offload ─────────────────────────────────────────────────
    # Only where the phase actually ran. Everything here reads state that only
    # exists after a reboot, so on the first pass — installer, then reboot — the
    # module checks are expected to fail and say so rather than look like faults.
    if [ "${HW_DGPU_VENDOR:-}" = nvidia ] && have prime-run; then
        # NOTE: `lsmod | grep -c`, never `grep -q`: grep -q exits on the first
        # match, lsmod dies of SIGPIPE and pipefail reports a false failure.
        if [ "$(lsmod | grep -c '^nvidia ')" -gt 0 ]; then
            chk "nvidia module loaded"
            check "nouveau is not loaded" "[ \"\$(lsmod | grep -c '^nouveau ')\" = 0 ]"
        else
            warn "the nvidia module is not loaded — expected until you reboot"
        fi

        check "prime-run available" "have prime-run"
        local nu
        for nu in nvidia-suspend nvidia-resume nvidia-hibernate nvidia-powerd; do
            check "$nu.service is not enabled" \
                  "[ \"\$(systemctl is-enabled $nu.service 2>/dev/null || true)\" != enabled ]"
        done

        # The gate the whole thing turns on: an idle dGPU must be asleep.
        local rs="/sys/bus/pci/devices/${HW_DGPU_PCI}/power/runtime_status"
        local ps="/sys/bus/pci/devices/${HW_DGPU_PCI}/power_state"
        if [ -r "$rs" ]; then
            if [ "$(cat "$rs" 2>/dev/null)" = suspended ]; then
                chk "dGPU is runtime-suspended ($(cat "$ps" 2>/dev/null || echo '?'))"
            else
                warn "dGPU runtime_status is '$(cat "$rs" 2>/dev/null)', expected 'suspended'"
                warn "on an idle desktop. Anything that touched the card — nvidia-smi"
                warn "included — wakes it for ~20s, so re-check before calling it a fault."
            fi
        fi

        # And the compositor must hold none of the dGPU's KMS nodes. This is the
        # pin doing its job: AQ_DRM_DEVICES decides which cardN aquamarine opens
        # as a backend, so a dGPU cardN in Hyprland's fd table means the pin did
        # not take and the desktop can end up driven by the dGPU.
        #
        # KMS nodes only, deliberately. Measured here: Hyprland holds card1 and
        # renderD128 (both iGPU) and ONE fd on the dGPU's renderD129, with the
        # card sitting in D3cold at the same time. A render node fd is the
        # dma-buf/PRIME import path being enumerated, not the compositor
        # rendering — a card that is powered off is not drawing anything. Only
        # the cardN is load-bearing, so only the cardN fails this check.
        local hp n held="" rendered=""
        hp=$(pgrep -x Hyprland 2>/dev/null | head -1 || true)
        if [ -n "$hp" ] && [ -d "/sys/bus/pci/devices/${HW_DGPU_PCI}/drm" ]; then
            for n in $(ls "/sys/bus/pci/devices/${HW_DGPU_PCI}/drm" 2>/dev/null || true); do
                [ "$(ls -l "/proc/$hp/fd" 2>/dev/null | grep -c "/dev/dri/$n\$")" -gt 0 ] || continue
                case "$n" in
                    card[0-9]*)    held="$held $n" ;;
                    renderD[0-9]*) rendered="$rendered $n" ;;
                esac
            done
            if [ -z "$held" ]; then
                chk "Hyprland holds no KMS node of the dGPU — the iGPU pin is taking"
                [ -n "$rendered" ] && \
                    info "(it does hold$rendered, the dGPU render node: that is the PRIME"
                [ -n "$rendered" ] && \
                    info " import path, and is expected while the card stays suspended)"
            else
                bad "Hyprland has the dGPU's KMS node(s) open:$held — the iGPU pin is not taking"
            fi
        fi
    fi

    # ── systemd ────────────────────────────────────────────────────────
    if [ "${HW_CHARGE_CAP:-0}" = 1 ]; then
        check "battery-threshold.timer enabled" "systemctl --user is-enabled battery-threshold.timer"
    fi
    have voxtype && check "voxtype.service enabled" "systemctl --user is-enabled voxtype.service"

    printf '\n'
    if [ "$V_FAIL" -eq 0 ]; then
        printf '  %s%d checks passed, 0 failed.%s\n' "$C_GRN$C_B" "$V_PASS" "$C_RST"
    else
        printf '  %s%d passed, %d FAILED%s — see above.\n' "$C_RED$C_B" "$V_PASS" "$V_FAIL" "$C_RST"
    fi
}

# ═══════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════
main() {
    printf '%s╭──────────────────────────────────────────────╮%s\n' "$C_B$C_BLU" "$C_RST"
    printf '%s│  hyprahaan — Hyprland + Quickshell installer │%s\n' "$C_B$C_BLU" "$C_RST"
    printf '%s╰──────────────────────────────────────────────╯%s\n' "$C_B$C_BLU" "$C_RST"
    printf '  log: %s\n' "$LOGFILE"

    if [ -n "$ONLY" ]; then
        case " $ALL_PHASES " in
            *" $ONLY "*) ;;
            *) die "unknown phase '$ONLY' (see --list)" ;;
        esac
        # Any single phase still needs the hardware facts in scope.
        [ "$ONLY" = preflight ] || detect_all
        # plugins is in this list because hyprpm shells out to sudo itself —
        # it writes to root-owned /var/cache/hyprpm. In a full run the preflight
        # prime covers it, but `--only plugins` skipped priming and hyprpm's own
        # prompt then had no tty to read from, so `hyprpm enable` failed silently
        # and the phase reported the plugin as not enabled. Measured 2026-09-02.
        case "$ONLY" in system|network|virt|hibernation|packages|nvidia) sudo_prime ;; esac
    fi

    want_phase preflight   && phase_preflight
    want_phase packages    && phase_packages
    want_phase configs     && phase_configs
    want_phase hardware    && phase_hardware
    want_phase nvidia      && phase_nvidia
    want_phase apps        && phase_apps
    want_phase usersystemd && phase_usersystemd
    want_phase system      && phase_system
    want_phase network     && phase_network
    want_phase virt        && phase_virt
    want_phase theming     && phase_theming
    want_phase hibernation && phase_hibernation
    want_phase fingerprint && phase_fingerprint
    want_phase verify      && phase_verify

    phase_close
    printf '\n%s══ Done in %s ══%s\n' "$C_B$C_GRN" "$(total_elapsed)" "$C_RST"
    cat <<NEXT
  Next steps:

    1. ${C_B}Log out completely${C_RST} (or reboot). Group changes — the ones that let
       the battery panel write the charge cap without sudo — do not reach an
       already-running session.
    2. At the greeter, log in and start ${C_B}Hyprland${C_RST}.
    3. Nothing else is required. The touchpad name is the one fact that needs
       a live session, and ${C_B}complete-hardware-profile.sh${C_RST} fills it in
       automatically at your first login.

  Install more from the AUR (browsers, Spotify, editors) with:
    ${C_B}~/.config/scripts/pkg-aur-install.sh${C_RST}

  Backups of anything overwritten: ${BACKUP_ROOT:-<nothing was overwritten>}
  Full log: $LOGFILE
NEXT
}

main "$@"
