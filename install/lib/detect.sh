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
# Picks the Intel or AMD display controller. Deliberately ignores NVIDIA: this
# value only ever pins Hyprland to the iGPU, and hyprland.lua's own guard leaves
# AQ_DRM_DEVICES unset if the value does not resolve to a real /dev/dri/cardN.
detect_igpu_pci() {
    local dev vendor pci
    for dev in /sys/bus/pci/devices/*; do
        [ -d "$dev/drm" ] || continue
        vendor=$(cat "$dev/vendor" 2>/dev/null)
        case "$vendor" in
            0x8086|0x1002) ;;          # Intel / AMD
            *) continue ;;
        esac
        # must actually own a cardN node
        ls "$dev/drm" 2>/dev/null | grep -qE '^card[0-9]+$' || continue
        pci=$(basename "$dev")
        echo "$pci"; return 0
    done
    return 1
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
IGPU_PCI="${HW_IGPU_PCI:-}"
REOF
    chmod 644 "$out"
    ok "hardware.env written"
}
