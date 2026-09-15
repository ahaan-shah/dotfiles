#!/usr/bin/env bash
# power-profile.sh  {get | set <profile> | backend}
#
# One power-profile interface for the whole desktop, over whichever daemon this
# machine actually has. The bar's battery panel and finder's SUPER+B picker both
# go through here; neither of them knows which daemon is answering.
#
# Profiles are named the way power-profiles-daemon names them —
# power-saver / balanced / performance — in both directions, whatever the
# backend calls them. That is deliberate: the UI labels, the settings page and
# PowerProfiles.qml's `items` all predate this file and none of them had to
# change. A backend that renames things is a backend detail.
#
# ── Why a script instead of teaching the QML about two daemons ───────────
# There are two call sites (shell/Bar.qml and shell/PowerProfiles.qml) and they
# would each have needed the same branch, the same name mapping and the same
# fallback. That is the shape this repo already rejects everywhere else: the
# menu decides what to offer, a script decides what happens. It also means the
# backend can be exercised from a terminal with no Quickshell running, which is
# how the mapping below was checked.
#
# ── Which daemon, and why it is a generated fact ────────────────────────
# asusd (asusctl) and power-profiles-daemon both drive
# /sys/firmware/acpi/platform_profile. Running both is what made the profile
# appear to move on its own — see the system map. So one machine gets one
# owner, and WHICH one is a property of the hardware rather than of this repo:
# asusctl exists only on ASUS laptops.
#
# That is exactly what hardware.env is for, so POWER_PROFILE_BACKEND lives
# there, written by install.sh's hardware phase. And as with every other key in
# that file, this works when it is missing: the fallback below detects at
# runtime, so a machine that has never run the installer still gets a working
# picker.
set -uo pipefail

HW_ENV="${XDG_CONFIG_HOME:-$HOME/.config}/scripts/hardware.env"

# By pattern, never sourced — the same rule hyprland.lua and UiConfig.qml parse
# this file by. A stray line in it must not be able to execute anything.
_hw_backend() {
    [ -r "$HW_ENV" ] || return 0
    sed -n 's/^POWER_PROFILE_BACKEND="\(.*\)"$/\1/p' "$HW_ENV" | head -1
    return 0
}

# asusd has to be RUNNING, not merely installed. asusctl is a D-Bus client: with
# the daemon stopped it fails, and falling back to a daemon that is actually
# answering is better than reporting no profiles at all.
_asusd_ok() {
    command -v asusctl >/dev/null 2>&1 || return 1
    systemctl is-active --quiet asusd 2>/dev/null || return 1
    return 0
}
_ppd_ok() {
    command -v powerprofilesctl >/dev/null 2>&1 || return 1
    systemctl is-active --quiet power-profiles-daemon 2>/dev/null || return 1
    return 0
}

# The generated answer is a PREFERENCE, not an instruction: if it names a
# backend this machine cannot serve right now, the other one is still better
# than nothing. An unset or unknown value falls through to detection.
backend() {
    local want; want="$(_hw_backend)"
    case "$want" in
        asusd) _asusd_ok && { echo asusd; return 0; } ;;
        ppd)   _ppd_ok   && { echo ppd;   return 0; } ;;
    esac
    _asusd_ok && { echo asusd; return 0; }
    _ppd_ok   && { echo ppd;   return 0; }
    echo none
    return 0
}

# ── the name mapping ────────────────────────────────────────────────────
# asusd's platform profiles are Quiet / Balanced / Performance. Quiet is the
# one that is not a rename: it is the firmware's low-power profile, which is
# what power-saver selects through ppd as well, so the two are the same setting
# reached by two names rather than an approximation.
_to_asusd() {
    case "$1" in
        power-saver) echo Quiet ;;
        balanced)    echo Balanced ;;
        performance) echo Performance ;;
        *)           echo "" ;;
    esac
}
# Case-folded, because the only thing guaranteeing the capitalisation is
# asusctl's current output and that is not a contract. An unrecognised name
# yields nothing, which hides the picker row — see the parse below for why a
# loud blank is the failure worth having.
_from_asusd() {
    case "${1,,}" in
        quiet)       echo power-saver ;;
        balanced)    echo balanced ;;
        performance) echo performance ;;
        *)           echo "" ;;
    esac
}

get() {
    case "$(backend)" in
        asusd)
            # asusctl prints "Active profile: Quiet" and then a blank line.
            #
            # ANCHORED on the label and taking the rest of the line, not
            # `awk '{print $NF}'` — the last field is only correct while every
            # profile name is a single word. asusctl currently offers Quiet,
            # Balanced and Performance, but "Power Saver" would parse as
            # "Saver" and map to nothing, and the failure would be a picker
            # that is quietly wrong rather than one that is visibly broken.
            #
            # If the label itself ever changes this yields empty, the row
            # hides, and that is the failure worth having: a missing picker
            # gets reported, a picker showing the wrong profile does not.
            #
            # Captured before testing, never `asusctl … | grep -q`: that is the
            # pipefail trap this repo has been bitten by five times.
            local raw
            raw="$(asusctl profile get 2>/dev/null \
                   | sed -n 's/^[[:space:]]*Active profile:[[:space:]]*//p' \
                   | head -1)"
            # Trailing whitespace and a stray CR, in case the output is ever
            # not a bare LF-terminated line.
            raw="${raw%%$'\r'*}"
            raw="${raw%"${raw##*[![:space:]]}"}"
            _from_asusd "$raw"
            ;;
        ppd) powerprofilesctl get 2>/dev/null ;;
        *)   : ;;
    esac
    return 0
}

set_profile() {
    local p="${1:-}"
    case "$p" in
        power-saver|balanced|performance) ;;
        *) echo "power-profile: unknown profile: $p" >&2; return 2 ;;
    esac
    case "$(backend)" in
        asusd)
            # The bare positional form ONLY. `asusctl profile set -a/-b` does
            # something different and dangerous here: it rewrites which profile
            # asusd forces on AC or on battery, i.e. the automation, rather
            # than setting the profile now. Ahaan deliberately keeps the
            # battery half of that automation, so nothing here may touch it.
            asusctl profile set "$(_to_asusd "$p")" >/dev/null 2>&1
            ;;
        ppd) powerprofilesctl set "$p" >/dev/null 2>&1 ;;
        *)   return 1 ;;
    esac
}

case "${1:-}" in
    get)     get ;;
    set)     shift; set_profile "${1:-}" ;;
    backend) backend ;;
    *)
        echo "usage: $(basename "$0") {get | set <power-saver|balanced|performance> | backend}" >&2
        exit 2
        ;;
esac
