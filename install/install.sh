#!/usr/bin/env bash
#
# install.sh — rebuild this Hyprland/Quickshell desktop on a fresh Arch install.
#
# Designed to be run on a MINIMAL Arch system from a TTY: it installs the
# compositor, every package the configs actually call, the configs themselves,
# the systemd units, the root-level rules, and the theme. It is idempotent —
# re-running it is a supported way to repair a half-finished install.
#
#   ./install.sh                 full install, prompting for optional app groups
#   ./install.sh --dry-run       print every action, change nothing
#   ./install.sh --yes           take every default, no prompts
#   ./install.sh --only hardware run one phase
#   ./install.sh --skip system   skip a phase
#   ./install.sh --list          list phases
#
# NVIDIA is deliberately out of scope: not every machine has one, and getting
# hybrid graphics wrong costs a black screen. See install/README.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTDIR="$(dirname "$SCRIPT_DIR")"     # the repo root: configs live beside install/

DRY_RUN=0
ASSUME_YES=0
NO_ROOT=0
NO_OPTIONAL=0
ONLY=""
SKIP=""
LOGFILE="/tmp/hyprahaan-install-$(date +%Y%m%d-%H%M%S).log"

ALL_PHASES="preflight packages configs hardware apps usersystemd system network theming plugins hibernation verify"

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
        --no-optional)  NO_OPTIONAL=1 ;;
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
# 0 · PREFLIGHT
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
        info "No Hyprland session is running, so the monitor mode and touchpad"
        info "name cannot be read. Safe catch-all values will be used now; after"
        info "your first login run:"
        info "    ${C_B}$SCRIPT_DIR/install.sh --only hardware${C_RST}"
        info "to pin the exact values."
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
# 1 · PACKAGES
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

choose_optional() {
    OPTIONAL_REPO=(); OPTIONAL_AUR=()
    [ "$NO_OPTIONAL" = 1 ] && { skip "optional groups skipped (--no-optional)"; return 0; }
    local f name desc kind pkg
    shopt -s nullglob
    for f in "$SCRIPT_DIR"/packages/optional/*.txt; do
        name="$(basename "$f" .txt)"; name="${name#*-}"
        desc="$(head -1 "$f" | sed 's/^# \{0,1\}//')"
        printf '\n  %s%s%s\n' "$C_B" "$desc" "$C_RST"
        printf '    %s\n' "$(read_manifest "$f" | awk '{print $2}' | tr '\n' ' ')"
        if ask_yn "Install this group?" y; then
            while read -r kind pkg; do
                [ "$kind" = aur ] && OPTIONAL_AUR+=("$pkg") || OPTIONAL_REPO+=("$pkg")
            done < <(read_manifest "$f")
        fi
    done
    shopt -u nullglob
}

phase_packages() {
    phase "Packages"

    info "refreshing package databases"
    run sudo pacman -Sy --noconfirm

    local repo=() aur=() kind pkg f
    for f in "$SCRIPT_DIR"/packages/10-core.txt "$SCRIPT_DIR"/packages/30-fonts.txt; do
        while read -r kind pkg; do
            [ "$kind" = aur ] && aur+=("$pkg") || repo+=("$pkg")
        done < <(read_manifest "$f")
    done

    if [ -n "${HW_BATTERY:-}" ]; then
        while read -r kind pkg; do
            [ "$kind" = aur ] && aur+=("$pkg") || repo+=("$pkg")
        done < <(read_manifest "$SCRIPT_DIR/packages/20-laptop.txt")
    else
        skip "no battery detected — laptop packages skipped"
    fi

    info "installing ${#repo[@]} repository packages"
    pac_install "${repo[@]}"
    ok "repository packages done"

    install_gpu_userspace

    bootstrap_yay
    while read -r kind pkg; do
        [ "$kind" = aur ] && aur+=("$pkg")
    done < <(read_manifest "$SCRIPT_DIR/packages/40-aur.txt")
    info "installing ${#aur[@]} AUR packages (this builds from source and is slow)"
    aur_install "${aur[@]}"
    ok "AUR packages done"

    choose_optional
    if [ "${#OPTIONAL_REPO[@]}" -gt 0 ]; then
        info "installing ${#OPTIONAL_REPO[@]} optional repository packages"
        pac_install "${OPTIONAL_REPO[@]}"
    fi
    if [ "${#OPTIONAL_AUR[@]}" -gt 0 ]; then
        info "installing ${#OPTIONAL_AUR[@]} optional AUR packages"
        aur_install "${OPTIONAL_AUR[@]}"
    fi
    ok "packages complete"
}

# ═══════════════════════════════════════════════════════════════════════
# 2 · CONFIGS
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
    deploy_file "$DOTDIR/mimeapps.list" "$HOME/.config/mimeapps.list" || true
    deploy_file "$DOTDIR/shell/.zshrc"  "$HOME/.zshrc"  || true
    deploy_file "$DOTDIR/shell/.bashrc" "$HOME/.bashrc" || true

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
    deploy_dir "$DOTDIR/wallpapers"           "$HOME/Pictures/wallpapers" || true
    deploy_dir "$DOTDIR/spicetify/Themes"     "$HOME/.config/spicetify/Themes" || true

    # Remove artefacts the mirror carries that must never reach a live config:
    # a pre-NVIDIA backup of hyprland.lua (Hyprland would not read it, but it is
    # confusing), and voxtype's generated hyprlang submap file, which is dead
    # here — nothing sources conf.d, the live config is Lua, and its contents use
    # the pre-0.55 positional `hyprctl dispatch` form that silently no-ops.
    run rm -f "$HOME/.config/hypr/hyprland.lua.bak-preNvidia"
    run rm -f "$HOME/.config/hypr/conf.d/voxtype-submap.conf"

    # Every launcher and script must be executable — rsync preserves the bit,
    # but a git checkout on a fresh clone may not.
    if [ "$DRY_RUN" = 0 ]; then
        find "$HOME/.config/scripts" "$HOME/.config"/{finder,macshell,taskbar,lockscreen} \
             -maxdepth 1 -name '*.sh' -exec chmod +x {} + 2>/dev/null || true
    fi
    ok "launch scripts marked executable"

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
# 3 · HARDWARE
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
# 4 · APPS  (per-application config that is not just a directory copy)
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
# 5 · USER SYSTEMD
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
# 6 · SYSTEM  (the only phase that needs root)
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
# 7 · NETWORK — wifi, bluetooth, firewall
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
        printf '  %sDRY%s firewall-cmd --permanent --zone=public --add-service={ssh,localsend} && --reload\n' "$C_DIM" "$C_RST"
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
# 8 · THEMING
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
# 8 · HYPRLAND PLUGINS
# ═══════════════════════════════════════════════════════════════════════
phase_plugins() {
    phase "Hyprland plugins (hyprbars)"
    have hyprpm || { skip "hyprpm not available"; return 0; }

    # hyprbars draws the title bar buttons hyprland.lua configures. A failure
    # here must not fail the install: Hyprland runs fine without it, the config
    # block is simply inert.
    if [ "$DRY_RUN" = 1 ]; then
        printf '  %sDRY%s hyprpm update && hyprpm add hyprland-plugins && hyprpm enable hyprbars\n' "$C_DIM" "$C_RST"
        return 0
    fi
    {
        hyprpm update || true
        hyprpm list 2>/dev/null | grep -q hyprbars || hyprpm add https://github.com/hyprwm/hyprland-plugins || true
        hyprpm enable hyprbars || true
    } || true
    if hyprpm list 2>/dev/null | grep -A1 'Plugin hyprbars' | grep -q 'enabled: true'; then
        ok "hyprbars enabled"
    else
        warn "hyprbars is not enabled — window title bars will be missing."
        warn "Retry after your first Hyprland login:  hyprpm update && hyprpm enable hyprbars"
    fi
}

# ═══════════════════════════════════════════════════════════════════════
# 9 · HIBERNATION  (opt-in — this one edits the bootloader)
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
# 10 · VERIFY
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
    local foreign
    foreign="$(grep -rhoI --exclude='*.bak*' -E '/home/[A-Za-z0-9_.-]+' \
                 "$HOME/.config"/{hypr,taskbar,macshell,finder,lockscreen,scripts} 2>/dev/null \
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
             gio qalc pdftoppm brightnessctl wal inotifywait nmcli bluetoothctl; do
        have "$b" || bad "missing runtime dependency: $b"
    done
    chk "runtime dependency sweep finished"

    # ── battery cap privilege model ────────────────────────────────────
    if [ "${HW_CHARGE_CAP:-0}" = 1 ]; then
        local th="/sys/class/power_supply/${HW_BATTERY}/charge_control_end_threshold"
        if [ -w "$th" ]; then
            chk "charge cap is writable without sudo"
        else
            warn "charge cap not yet writable — expected until you log out and back in"
            warn "(group membership does not apply to an already-running session)"
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
        case "$ONLY" in system|network|hibernation|packages) sudo_prime ;; esac
    fi

    want_phase preflight   && phase_preflight
    want_phase packages    && phase_packages
    want_phase configs     && phase_configs
    want_phase hardware    && phase_hardware
    want_phase apps        && phase_apps
    want_phase usersystemd && phase_usersystemd
    want_phase system      && phase_system
    want_phase network     && phase_network
    want_phase theming     && phase_theming
    want_phase plugins     && phase_plugins
    want_phase hibernation && phase_hibernation
    want_phase verify      && phase_verify

    phase_close
    printf '\n%s══ Done in %s ══%s\n' "$C_B$C_GRN" "$(total_elapsed)" "$C_RST"
    cat <<NEXT
  Next steps:

    1. ${C_B}Log out completely${C_RST} (or reboot). Group changes — the ones that let
       the battery panel write the charge cap without sudo — do not reach an
       already-running session.
    2. At the greeter, log in and start ${C_B}Hyprland${C_RST}.
    3. From inside the session, run:
         ${C_B}$SCRIPT_DIR/install.sh --only hardware${C_RST}
       to pin the real monitor mode and touchpad name, then log out and back in.

  Backups of anything overwritten: ${BACKUP_ROOT:-<nothing was overwritten>}
  Full log: $LOGFILE
NEXT
}

main "$@"
