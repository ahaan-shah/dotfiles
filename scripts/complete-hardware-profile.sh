#!/usr/bin/env bash
# complete-hardware-profile.sh — fill in the one hardware fact that cannot be
# known without a running compositor.
#
# install.sh detects everything else straight from sysfs, so a single run on a
# bare TTY produces a fully working desktop: the monitor gets "highrr" (highest
# supported refresh rate) and a scale computed from the panel's EDID. The
# touchpad's libinput device name is the exception — it only exists once
# Hyprland has enumerated input devices.
#
# So hyprland.lua autostarts this. It writes TOUCHPAD_DEVICE into hardware.env
# and exits. No `hyprctl reload` is needed: the device block in hyprland.lua only
# sets enabled = true, which is already the default, and toggle-touchpad.sh reads
# hardware.env fresh on every invocation.
#
# Idempotent and self-disabling: once the name is recorded it returns immediately.
set -u

ENV_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/scripts/hardware.env"
LOG="${XDG_RUNTIME_DIR:-/tmp}/hardware-profile.log"
log() { printf '%s  %s\n' "$(date '+%F %T')" "$*" >>"$LOG"; }

[ -f "$ENV_FILE" ] || { log "no $ENV_FILE — run install.sh --only hardware"; exit 0; }

# Already recorded? Nothing to do. This is the normal path on every boot after
# the first, so it must be cheap and silent.
if grep -qE '^TOUCHPAD_DEVICE="[^"]+"' "$ENV_FILE"; then
    exit 0
fi

command -v hyprctl >/dev/null || exit 0

# Input devices are not enumerated the instant the compositor starts. Poll
# briefly rather than sleeping a guessed interval.
DEVICE=""
for _ in $(seq 1 30); do
    if hyprctl devices -j >/dev/null 2>&1; then
        DEVICE=$(hyprctl devices -j 2>/dev/null | jq -r '.mice[]?|.name' | grep -i -m1 touchpad || true)
        [ -n "$DEVICE" ] && break
    fi
    sleep 0.5
done

if [ -z "$DEVICE" ]; then
    log "no touchpad found after 15s — this machine probably has none"
    # Record the fact so we stop looking on every boot.
    DEVICE=""
fi

# Rewrite the single line, preserving everything else. A temp file plus mv keeps
# the replacement atomic, so a reader can never see a half-written profile.
TMP=$(mktemp "${ENV_FILE}.XXXXXX") || exit 0
if grep -q '^TOUCHPAD_DEVICE=' "$ENV_FILE"; then
    sed "s|^TOUCHPAD_DEVICE=.*|TOUCHPAD_DEVICE=\"$DEVICE\"|" "$ENV_FILE" >"$TMP"
else
    cp "$ENV_FILE" "$TMP"
    printf 'TOUCHPAD_DEVICE="%s"\n' "$DEVICE" >>"$TMP"
fi
chmod 644 "$TMP"
mv -f "$TMP" "$ENV_FILE"

if [ -n "$DEVICE" ]; then
    log "recorded TOUCHPAD_DEVICE=\"$DEVICE\""
else
    log "recorded TOUCHPAD_DEVICE=\"\" (none present)"
fi
