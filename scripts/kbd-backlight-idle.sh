#!/usr/bin/env bash
# kbd-backlight-idle.sh {save|off|restore} — the keyboard backlight half of
# hypridle's idle sequence.
#
# WHY THIS IS A SCRIPT AND NOT THREE LINES IN hypridle.conf
#
# hypridle.conf has no way to source a file: every on-timeout is handed
# straight to `sh -c`, with no place to put a variable that the next listener
# can also see. So the LED name was inlined as `asus::kbd_backlight` in three
# places — the only part of the session that would not survive being moved to
# another laptop. Every other consumer of an LED in this repo
# (kbdbacklight_toggle.sh, micmute-led.sh) reads its name out of the profile
# install.sh generates and exits quietly when there is nothing to light up.
# Routing hypridle through here does the same, so hypridle.conf itself no
# longer names any hardware.
#
# The three verbs mirror what the two listeners used to do inline:
#   save    — record the current brightness (179s, one second BEFORE `off`, so
#             the value captured is the pre-dim one)
#   off     — blank the backlight, but ONLY while the lockscreen is actually
#             up (180s). See hypridle.conf for why that gate exists: a
#             fingerprint unlock never touches a key or the touchpad, so it
#             does not reset Hyprland's input-idle clock, and without the gate
#             the backlight would blank on a session someone is sitting at.
#   restore — put back whatever `save` recorded, if it was non-zero (on-resume)
set -u

# Machine-specific names come from the profile install.sh generates. Sourcing
# it (rather than hardcoding) is what lets this script run unmodified on any
# machine; the fallback keeps it working if the profile has not been written.
HW_ENV="${XDG_CONFIG_HOME:-$HOME/.config}/scripts/hardware.env"
# shellcheck source=/dev/null
[ -r "$HW_ENV" ] && . "$HW_ENV"

LED="${KBD_BACKLIGHT_LED:-}"
# Unchanged path: this is where the inline version kept the value, and keeping
# it means a restore still works across the config change.
STATE="/tmp/kbd_brightness_before"

# Not every laptop has a backlit keyboard. Exit quietly rather than erroring on
# an idle timeout that simply has nothing to do here — the DPMS listener beside
# this one is unaffected either way.
[ -n "$LED" ] || exit 0
[ -e "/sys/class/leds/$LED" ] || exit 0

# Same pgrep the DPMS listener uses. lockscreen/shell.qml's onUnlocked sets
# locked = false and then Qt.quit()s, so once the session is genuinely unlocked
# this comes up empty.
locked() { pgrep -f "quickshell -c $HOME/.config/lockscreen" >/dev/null; }

case "${1:-}" in
    save)
        brightnessctl -d "$LED" get > "$STATE"
        ;;
    off)
        locked && brightnessctl -d "$LED" set 0
        ;;
    restore)
        val=$(cat "$STATE" 2>/dev/null || echo 0)
        # The inline version compared with `[ "$val" -gt 0 ]`, which errors on
        # an empty or truncated state file. Same behaviour for any real value,
        # minus the stderr noise.
        [[ "$val" =~ ^[0-9]+$ ]] && [ "$val" -gt 0 ] && brightnessctl -d "$LED" set "$val"
        ;;
    *)
        echo "usage: $0 {save|off|restore}" >&2
        exit 1
        ;;
esac

# `locked` returning false, or a zero saved value, is a normal no-op — never an
# error worth reporting back to hypridle.
exit 0
