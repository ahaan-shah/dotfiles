#!/usr/bin/env bash
# persist-monitor-scale.sh — record the scale a monitor is ACTUALLY running at
# into hardware.env, so a scale picked in the taskbar's display panel survives
# a `hyprctl reload` and a reboot.
#
# Why this exists: the panel changes scale with `hyprctl eval 'hl.monitor{...}'`,
# which is a RUNTIME change and nothing else. hyprland.lua reads MONITOR_SCALE
# out of hardware.env on every parse, so the next reload — or the next boot —
# silently put the old scale back. Measured 2026-09-02: the session had been
# running at 1.8 since Aug 31, hardware.env said 2, and one reload moved every
# window on the desktop by 11%. The scale had been chosen in the panel weeks
# earlier and was recorded nowhere.
#
# Reads the EFFECTIVE scale back out of hyprctl rather than taking it as an
# argument. Hyprland snaps a scale it cannot divide into an integer logical
# size to the nearest one it can — ask for 1.75 on 2880x1620 and you land on
# 1.8 — so the profile has to hold what the compositor settled on. Persisting
# the requested number instead would come up at a different size on the next
# boot than the one that was actually chosen.
#
# Usage:  persist-monitor-scale.sh [monitor-name]
# With no argument it uses PRIMARY_MONITOR from the profile. A name that is not
# the primary is ignored on purpose: hardware.env holds ONE monitor profile, and
# a second display's scale must never overwrite the internal panel's.
set -u

ENV_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/scripts/hardware.env"
LOG="${XDG_RUNTIME_DIR:-/tmp}/hardware-profile.log"
log() { printf '%s  persist-monitor-scale: %s\n' "$(date '+%F %T')" "$*" >>"$LOG"; }

[ -f "$ENV_FILE" ] || { log "no $ENV_FILE — run install.sh --only hardware"; exit 0; }
command -v hyprctl >/dev/null || exit 0
command -v jq      >/dev/null || { log "jq missing"; exit 0; }

# Read the profile's own idea of the primary and the recorded scale. Parsed the
# same way hyprland.lua parses it (KEY="value") rather than sourced, so a stray
# line in the file can never execute anything.
prof() { sed -n "s/^$1=\"\(.*\)\"\$/\1/p" "$ENV_FILE" | head -1; }
PRIMARY=$(prof PRIMARY_MONITOR)
RECORDED=$(prof MONITOR_SCALE)

WANT="${1:-$PRIMARY}"
if [ -n "$PRIMARY" ] && [ -n "$WANT" ] && [ "$WANT" != "$PRIMARY" ]; then
    log "ignoring $WANT — profile tracks $PRIMARY only"
    exit 0
fi

# Not `hyprctl ... | jq -e` under pipefail: this repo has been bitten four times
# by a producer in a pipeline. Capture first, then parse.
MONS=$(hyprctl monitors -j 2>/dev/null) || { log "hyprctl unavailable"; exit 0; }
if [ -n "$WANT" ]; then
    SCALE=$(printf '%s' "$MONS" | jq -r --arg n "$WANT" '[.[]|select(.disabled|not)|select(.name==$n)][0].scale // empty')
else
    SCALE=$(printf '%s' "$MONS" | jq -r '[.[]|select(.disabled|not)][0].scale // empty')
fi
[ -n "$SCALE" ] || { log "no scale reported for ${WANT:-first monitor}"; exit 0; }

# hyprctl reports the scale as a float that has been through a 32-bit round
# trip: 1.8 comes back as 1.7999999523162842. Writing that verbatim would put a
# number in the profile that hl.monitor then snaps AGAIN on the next parse. Four
# decimals is past any scale Hyprland will accept and rounds the noise away;
# trailing zeros are stripped so 2.0000 is recorded as the "2" a human wrote.
SCALE=$(awk -v s="$SCALE" 'BEGIN{ printf "%.4f", s }' | sed 's/0*$//; s/\.$//')
case "$SCALE" in ''|*[!0-9.]*) log "refusing to write non-numeric scale '$SCALE'"; exit 0 ;; esac

[ "$SCALE" = "$RECORDED" ] && exit 0   # nothing changed — the common case

# Atomic single-line rewrite, exactly as complete-hardware-profile.sh does it:
# a reader (hyprland.lua parses this on every reload) must never see a
# half-written profile.
TMP=$(mktemp "${ENV_FILE}.XXXXXX") || exit 0
if [ "$(grep -c '^MONITOR_SCALE=' "$ENV_FILE")" -gt 0 ]; then
    sed "s|^MONITOR_SCALE=.*|MONITOR_SCALE=\"$SCALE\"|" "$ENV_FILE" >"$TMP"
else
    cp "$ENV_FILE" "$TMP" && printf 'MONITOR_SCALE="%s"\n' "$SCALE" >>"$TMP"
fi
chmod 644 "$TMP"
mv -f "$TMP" "$ENV_FILE"
log "recorded MONITOR_SCALE=\"$SCALE\" for ${WANT:-first monitor} (was \"${RECORDED:-unset}\")"
