#!/usr/bin/env bash
# detect.sh — work out what this machine actually is.
#
# Two detection contexts, and the difference matters:
#
#   TTY (first run, minimal Arch)  — no compositor, so monitor mode/refresh and
#                                    input device names are NOT knowable. We fall
#                                    back to Hyprland's own catch-all values
#                                    ("preferred"/"auto"), which always produce a
#                                    working display on unknown hardware.
#   Live Hyprland session (re-run) — hyprctl gives exact values, so `install.sh
#                                    --only hardware` from inside the session
#                                    pins the real mode, scale and touchpad name.
#
# Everything lands in ~/.config/scripts/hardware.env, which the shell scripts
# source and hyprland.lua parses. Nothing is sed-ed into a deployed file, so the
# detection is re-runnable and never corrupts a config.

# --- is a Hyprland session reachable from here? --------------------------
hypr_live() {
    have hyprctl || return 1
    have jq      || return 1
    hyprctl monitors -j >/dev/null 2>&1
}

# --- battery ------------------------------------------------------------
detect_battery() {
    local d
    for d in /sys/class/power_supply/*; do
        [ -r "$d/type" ] || continue
        [ "$(cat "$d/type" 2>/dev/null)" = "Battery" ] || continue
        # a UPS or a bluetooth device's battery also reports type=Battery;
        # a real laptop pack is the one exposing a charge/energy full value
        [ -r "$d/charge_full" ] || [ -r "$d/energy_full" ] || continue
        basename "$d"; return 0
    done
    return 1
}

# --- charge-cap support (not every laptop has it) -----------------------
detect_charge_cap() {
    local bat="$1"
    [ -n "$bat" ] || return 1
    [ -e "/sys/class/power_supply/$bat/charge_control_end_threshold" ]
}

# --- LEDs ---------------------------------------------------------------
detect_led() {
    local pat="$1" d
    for d in /sys/class/leds/*; do
        [ -e "$d" ] || continue
        case "$(basename "$d")" in
            *"$pat"*) basename "$d"; return 0 ;;
        esac
    done
    return 1
}

# --- integrated GPU PCI address ----------------------------------------
# Picks the Intel or AMD display controller THAT DRIVES THE BUILT-IN PANEL.
# Deliberately ignores NVIDIA: this value only ever pins Hyprland to the iGPU,
# and hyprland.lua's own guard leaves AQ_DRM_DEVICES unset if the value does not
# resolve to a real /dev/dri/cardN.
#
# Why "the one with the live eDP" and not "the first one found": on a hybrid
# laptop BOTH GPUs expose connectors — this machine's dGPU owns HDMI-A-1 and a
# dead eDP-2 — and cardN numbering is probe-order dependent, so the connected
# internal panel is the only stable way to name the GPU that actually draws the
# desktop. The old first-match loop is kept as the fallback for a machine with
# no internal panel at all (a desktop), where any Intel/AMD display controller
# is the right answer.
#
# The one case that must return NOTHING is a laptop whose MUX is in discrete
# mode: there the internal panel hangs off the dGPU, the iGPU has no outputs,
# and pinning Hyprland to it is a black screen. That is detected generically —
# internal panel connected, owned by neither Intel nor AMD — rather than by
# reading any vendor's mux attribute, and it returns failure so the pin stays
# unset (unpinned Hyprland enumerates every GPU, which is correct there).
detect_igpu_pci() {
    local conn dev pci

    for conn in /sys/class/drm/card*-eDP-* /sys/class/drm/card*-LVDS-*; do
        [ -r "$conn/status" ] || continue
        [ "$(cat "$conn/status" 2>/dev/null)" = "connected" ] || continue
        # $conn/device is the drm/cardN directory; the PCI device is two up.
        dev=$(readlink -f "$conn/device" 2>/dev/null) || continue
        dev=$(dirname "$(dirname "$dev")")
        [ -r "$dev/vendor" ] || continue
        case "$(cat "$dev/vendor" 2>/dev/null)" in
            0x8086|0x1002) basename "$dev"; return 0 ;;
            *) return 1 ;;             # panel is on the dGPU — do not pin
        esac
    done

    for dev in /sys/bus/pci/devices/*; do
        [ -d "$dev/drm" ] || continue
        case "$(cat "$dev/vendor" 2>/dev/null)" in
            0x8086|0x1002) ;;          # Intel / AMD
            *) continue ;;
        esac
        # must actually own a cardN node. NOT `ls | grep -q`: grep -q exits on
        # the first match, ls dies of SIGPIPE and pipefail turns that into a
        # false negative. grep -c reads all of its input. (Repo rule; it has
        # cost us four bugs.)
        [ "$(ls "$dev/drm" 2>/dev/null | grep -cE '^card[0-9]+$')" -gt 0 ] || continue
        pci=$(basename "$dev")
        echo "$pci"; return 0
    done
    return 1
}

# --- discrete GPU -------------------------------------------------------
# Any display-class PCI device that is not the integrated one.
#
# Deliberately does NOT require a drm/ subdirectory, unlike detect_igpu_pci: a
# dGPU with no driver bound owns no cardN node but is very much present, and the
# entire point of this detection is that it has to work BEFORE the driver is
# installed. Class is the reliable signal instead — 0x0300 (VGA controller) or
# 0x0302 (3D controller, the classic Optimus class for a card with no outputs).
#
# Sets HW_DGPU_* rather than echoing, because the caller needs four facts and a
# machine can have none of them.
detect_dgpu() {
    local igpu="${1:-}" dev pci
    HW_DGPU_PCI=; HW_DGPU_VENDOR=; HW_DGPU_DEVID=; HW_DGPU_NAME=
    for dev in /sys/bus/pci/devices/*; do
        case "$(cat "$dev/class" 2>/dev/null)" in
            0x0300*|0x0302*) ;;
            *) continue ;;
        esac
        pci=$(basename "$dev")
        [ -n "$igpu" ] && [ "$pci" = "$igpu" ] && continue
        HW_DGPU_PCI="$pci"
        HW_DGPU_DEVID=$(cat "$dev/device" 2>/dev/null)
        case "$(cat "$dev/vendor" 2>/dev/null)" in
            0x10de) HW_DGPU_VENDOR=nvidia ;;
            0x1002) HW_DGPU_VENDOR=amd ;;
            0x8086) HW_DGPU_VENDOR=intel ;;
            *)      HW_DGPU_VENDOR=unknown ;;
        esac
        # Human-readable name is a nicety, so it is gated on lspci rather than
        # making pciutils a hard dependency of detection.
        if have lspci; then
            HW_DGPU_NAME=$(lspci -s "$pci" 2>/dev/null \
                           | sed -n '1s/^[^ ]* [^:]*: //p' | sed 's/ (rev [^)]*)$//')
            # lspci reads "NVIDIA Corporation GA107BM / GN20-P0-R-K2 [GeForce RTX
            # 3050 6GB Laptop GPU]". The bracketed marketing name is the half a
            # human recognises, so prefer it when there is one.
            case "$HW_DGPU_NAME" in
                *\[*\]*) HW_DGPU_NAME="${HW_DGPU_NAME##*\[}"
                        HW_DGPU_NAME="${HW_DGPU_NAME%%\]*}" ;;
            esac
        fi
        [ -n "$HW_DGPU_NAME" ] || HW_DGPU_NAME="${HW_DGPU_VENDOR} ${HW_DGPU_DEVID}"
        return 0
    done
    return 1
}

# --- does nvidia-open support this card? --------------------------------
# The open kernel modules need a GSP-firmware GPU, i.e. Turing (RTX 20 / GTX 16)
# or newer. Nothing in sysfs says "Turing", so this goes by PCI device ID:
# every Turing and later part is >= 0x1e00, everything Pascal and earlier is
# below it. The only thing that misclassifies is Volta (0x1d80-0x1dbx), which
# has never shipped in a notebook — and this is only ever consulted for a
# laptop dGPU. Wrong here means "we offer to install a driver that then refuses
# to load", which is loud and reversible, not a black screen.
dgpu_supports_nvidia_open() {
    local id="${1:-}"
    [ -n "$id" ] || return 1
    [ $(( id )) -ge $(( 0x1e00 )) ]
}

# --- MUX state, where the firmware exposes one --------------------------
# ASUS is the vendor that exposes it as a plain sysfs attribute; 1 = hybrid
# (Optimus, what this desktop wants), 0 = discrete/"Ultimate" (dGPU drives the
# panel directly). Reported only — nothing here ever writes it, because flipping
# a MUX from a running session is a reboot-to-black-screen. Absent on every
# machine that has no switchable mux, which is the common case.
detect_gpu_mux() {
    local f
    for f in /sys/devices/platform/asus-nb-wmi/gpu_mux_mode \
             /sys/devices/platform/asus_nb_wmi/gpu_mux_mode; do
        [ -r "$f" ] || continue
        cat "$f" 2>/dev/null | tr -d ' '
        return 0
    done
    return 1
}

# --- Secure Boot --------------------------------------------------------
# An out-of-tree kernel module is unsigned, so with Secure Boot enforcing it
# will not load and the dGPU silently stays dark. The EFI variable's first four
# bytes are the attribute mask; the fifth is the value.
detect_secureboot() {
    local v
    v=$(od -An -tu1 -j4 -N1 /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null \
        | tr -d ' \n')
    [ -n "$v" ] || return 1
    [ "$v" = 1 ]
}

# --- scale from EDID, with no compositor running -------------------------
# The panel's physical size is in EDID bytes 21 and 22 (max horizontal / vertical
# image size, in cm). Combined with the preferred resolution that gives DPI, and
# DPI is what decides whether a display wants 1x or 2x.
#
# NOTE: sysfs reports the edid attribute as size 0 even when it has content, so
# never gate on `[ -s ... ]` — read it and check whether bytes came back.
edid_scale() {
    # NOTE: `local a="$1" b="...$a..."` does NOT work — bash expands every word
    # in the command before performing any of the assignments, so $a is still
    # empty when b is built. Assign on separate lines.
    local conn="$1"
    local edid="/sys/class/drm/$conn/edid"
    local h v res pw ph
    [ -r "$edid" ] || return 1
    h=$(od -An -tu1 -j21 -N1 "$edid" 2>/dev/null | tr -d ' ')
    v=$(od -An -tu1 -j22 -N1 "$edid" 2>/dev/null | tr -d ' ')
    [ -n "$h" ] && [ -n "$v" ] && [ "$h" -gt 0 ] && [ "$v" -gt 0 ] || return 1
    res=$(head -1 "/sys/class/drm/$conn/modes" 2>/dev/null)
    pw=${res%%x*}; ph=${res##*x}
    [ -n "$pw" ] && [ -n "$ph" ] || return 1
    # awk rather than python: a minimal Arch install may not have python yet.
    awk -v h="$h" -v v="$v" -v pw="$pw" -v ph="$ph" 'BEGIN{
        diag_in = sqrt(h*h + v*v) / 2.54
        if (diag_in <= 0) exit 1
        dpi = sqrt(pw*pw + ph*ph) / diag_in
        printf "%d\n", (dpi >= 170 ? 2 : 1)
    }'
}

# --- monitor ------------------------------------------------------------
# Live session: exact name/mode/scale. TTY: name from sysfs, safe generic mode.
detect_monitor() {
    if hypr_live; then
        local j
        j=$(hyprctl monitors -j 2>/dev/null) || return 1
        MON_NAME=$(printf '%s' "$j" | jq -r '[.[]|select(.disabled|not)][0].name // empty')
        MON_MODE=$(printf '%s' "$j" | jq -r '[.[]|select(.disabled|not)][0] | if .name then "\(.width)x\(.height)@\(.refreshRate|round)" else empty end')
        MON_SCALE=$(printf '%s' "$j" | jq -r '[.[]|select(.disabled|not)][0].scale // empty')
        MON_POS=$(printf '%s' "$j" | jq -r '[.[]|select(.disabled|not)][0] | if .name then "\(.x)x\(.y)" else empty end')
        MON_SOURCE="live Hyprland session"
        [ -n "$MON_NAME" ] && return 0
    fi

    # No compositor. Take the connected connector name from DRM sysfs and let
    # Hyprland choose the mode itself — the only safe choice on unknown hardware.
    local d n
    for d in /sys/class/drm/card*-*; do
        [ -r "$d/status" ] || continue
        [ "$(cat "$d/status" 2>/dev/null)" = "connected" ] || continue
        n=$(basename "$d"); MON_CONN="$n"; n="${n#card*-}"
        # prefer the internal panel; otherwise keep the first connected output
        case "$n" in eDP*|LVDS*) MON_NAME="$n"; MON_CONN="$(basename "$d")"; break ;; esac
        if [ -z "${MON_NAME:-}" ]; then MON_NAME="$n"; MON_CONN="$(basename "$d")"; fi
    done
    # "highrr" = highest supported refresh rate (confirmed against the wiki's
    # configuring/core/monitors/modes.md). That gets a 120Hz panel to 120Hz with
    # no compositor running, which "preferred" would not guarantee.
    MON_MODE="highrr"; MON_POS="auto"
    MON_SCALE=$(edid_scale "$MON_CONN" 2>/dev/null || true)
    if [ -n "${MON_SCALE:-}" ]; then
        MON_SOURCE="DRM sysfs + EDID (no compositor running)"
    else
        MON_SCALE="auto"
        MON_SOURCE="DRM sysfs, EDID unreadable (no compositor running)"
    fi
    [ -n "${MON_NAME:-}" ]
}

# --- touchpad -----------------------------------------------------------
detect_touchpad() {
    hypr_live || return 1
    hyprctl devices -j 2>/dev/null \
        | jq -r '.mice[]?|.name' \
        | grep -i -m1 touchpad
}

# --- run everything -----------------------------------------------------
# detect_fprint — is there a real fingerprint reader fprintd can talk to?
# Gated on the tool AND on an enumerated device: fprintd being installed proves
# nothing (20-laptop.txt installs it on every laptop), and `fprintd-list`
# exits non-zero with no device, so the call is guarded.
detect_fprint() {
    command -v fprintd-list >/dev/null 2>&1 || return 1
    local out
    out="$(fprintd-list "$USER" 2>/dev/null || true)"
    case "$out" in
        *"found "[1-9]*) ;;
        *) return 1 ;;
    esac
    # The device name, for the report. Falls back to a generic label.
    printf '%s\n' "$(printf '%s' "$out" | sed -n 's/^Fingerprints for user .* on \(.*\):$/\1/p' \
                      | head -1)" | grep . || echo "fingerprint reader"
}

# detect_kvm — hardware virtualisation, which gates the whole `virt` phase.
# /dev/kvm is the honest test but only exists once the module is loaded, so the
# CPU flags are checked too: a fresh TTY install may not have loaded kvm yet.
detect_kvm() {
    [ -e /dev/kvm ] && return 0
    grep -qE '^flags.*\b(vmx|svm)\b' /proc/cpuinfo
}

detect_all() {
    HW_BATTERY=$(detect_battery || true)
    HW_CHARGE_CAP=0
    if detect_charge_cap "${HW_BATTERY:-}"; then HW_CHARGE_CAP=1; fi
    HW_KBD_LED=$(detect_led kbd_backlight || true)
    HW_MICMUTE_LED=$(detect_led micmute || true)
    HW_IGPU_PCI=$(detect_igpu_pci || true)
    detect_dgpu "${HW_IGPU_PCI:-}" || true
    HW_GPU_MUX=$(detect_gpu_mux || true)
    HW_SECUREBOOT=0
    if detect_secureboot; then HW_SECUREBOOT=1; fi
    HW_TOUCHPAD=$(detect_touchpad || true)
    MON_NAME=; MON_MODE=; MON_SCALE=; MON_POS=; MON_SOURCE=
    detect_monitor || true
    HW_FPRINT=$(detect_fprint || true)
    HW_KVM=0
    if detect_kvm; then HW_KVM=1; fi
    HW_LIVE=0
    if hypr_live; then HW_LIVE=1; fi
}

print_detection() {
    local cap="no"; [ "$HW_CHARGE_CAP" = 1 ] && cap="yes"
    local mux=""; [ -n "${HW_GPU_MUX:-}" ] && mux="  mux=${HW_GPU_MUX} ($([ "${HW_GPU_MUX}" = 1 ] && echo hybrid || echo DISCRETE))"
    local kvm="no — the VM phase will be skipped"; [ "${HW_KVM:-0}" = 1 ] && kvm="yes"
    cat <<REPORT
  user / home        : $USER  ($HOME)
  monitor            : ${MON_NAME:-<none detected>}  ${MON_MODE:-} pos=${MON_POS:-} scale=${MON_SCALE:-}
                       ${C_DIM}source: ${MON_SOURCE:-unknown}${C_RST}
  battery            : ${HW_BATTERY:-<none — desktop?>}   charge cap supported: $cap
  kbd backlight LED  : ${HW_KBD_LED:-<none>}
  mic-mute LED       : ${HW_MICMUTE_LED:-<none>}
  touchpad device    : ${HW_TOUCHPAD:-<needs a live Hyprland session>}
  integrated GPU     : ${HW_IGPU_PCI:-<none detected — GPU pin will stay off>}
  discrete GPU       : ${HW_DGPU_NAME:-<none detected>}${HW_DGPU_PCI:+  ($HW_DGPU_PCI)}${mux}
  fingerprint reader : ${HW_FPRINT:-<none detected>}
  KVM virtualisation : $kvm
REPORT
}

# hardware.env is the single generated file every consumer reads.
write_hardware_env() {
    local out="$HOME/.config/scripts/hardware.env"
    info "writing $out"
    if [ "$DRY_RUN" = 1 ]; then
        printf '  %sDRY%s would write hardware.env\n' "$C_DIM" "$C_RST"
        return 0
    fi
    mkdir -p "$(dirname "$out")"
    # UNQUOTED heredoc (REOF, not 'REOF') — the values have to expand. So the
    # comment text below must contain no backticks and no bare $: a backtick
    # here is a command substitution that runs during the install, and it fails
    # silently, leaving a truncated sentence in the generated file. That has
    # happened once.
    cat >"$out" <<REOF
# Generated by install.sh on $(date '+%F %T') — do not edit by hand.
# Re-run:  ~/.config/dotfiles/install/install.sh --only hardware
#
# Detected from: ${MON_SOURCE:-unknown}. If this was written from a TTY the
# monitor mode/scale are Hyprland's safe catch-all values and the touchpad is
# unknown; re-run the line above from inside a Hyprland session to pin the
# real values.

PRIMARY_MONITOR="${MON_NAME:-}"
MONITOR_MODE="${MON_MODE:-preferred}"
MONITOR_POSITION="${MON_POS:-auto}"
MONITOR_SCALE="${MON_SCALE:-auto}"

BATTERY="${HW_BATTERY:-}"
BATTERY_CHARGE_CAP="${HW_CHARGE_CAP:-0}"
KBD_BACKLIGHT_LED="${HW_KBD_LED:-}"
MICMUTE_LED="${HW_MICMUTE_LED:-}"
TOUCHPAD_DEVICE="${HW_TOUCHPAD:-}"

# IGPU_PCI pins Hyprland to the GPU that owns the internal panel. Empty is a
# valid answer and means "do not pin" — hyprland.lua then leaves AQ_DRM_DEVICES
# unset and Hyprland enumerates every GPU, which is the old working behaviour.
IGPU_PCI="${HW_IGPU_PCI:-}"

# The dGPU is never rendered to by the desktop; it exists for prime-run.
# These are here so scripts and the installer's verify phase can name it
# without re-walking sysfs. Nothing in the running desktop reads them.
DGPU_PCI="${HW_DGPU_PCI:-}"
DGPU_VENDOR="${HW_DGPU_VENDOR:-}"
REOF
    chmod 644 "$out"
    ok "hardware.env written"
}
