#!/usr/bin/env bash
# apply-battery-threshold.sh [VALUE|--check|--state]
#
# Single writer for the battery's charge cap. Used by hyprland.lua at startup,
# by the taskbar battery panel on click, by hypridle after a resume, and by
# battery-threshold.timer as a watchdog.
#
# WHY THIS IS NOT JUST `echo N > sysfs`
#
# 1. THE SYSFS VALUE IS THE DRIVER'S OWN CACHE, NOT THE EC's.
#    asus-wmi's charge_control_end_threshold_store() pushes the value at the EC
#    and then remembers it; _show() prints what it remembered. It never asks the
#    EC. So reading back "90" proves only that nothing else overwrote the file —
#    never that the cap is still being enforced. A resume, or an
#    asus_wmi_set_devstate() that silently fails to reach the EC (a known
#    upstream issue, no error reported), leaves exactly this state: sysfs says
#    90, the EC says 100, and the battery charges to 100.
#    Observed 2026-09-09: sysfs 90, capacity 93%, status Charging.
#    Nothing can be *read* to distinguish that, so the only safe move is to
#    re-assert on a schedule while it can matter — see --check.
#
# 2. WRITING THE VALUE SYSFS ALREADY HOLDS CAN BE A NO-OP.
#    The store path can short-circuit, so the write never reaches the EC. That
#    is why re-clicking 80 in the panel used to do nothing after a hibernate.
#    So when the target equals the current value we nudge DOWN first — never up,
#    a nudge upward would briefly permit MORE charging — to force a real EC
#    transaction, then set the target.
#
# 3. FOUR CALLERS RUN CONCURRENTLY AND USED TO CORRUPT EACH OTHER.
#    Each apply is a read-modify-write spanning ~0.6s of sleeps. Two overlapping
#    runs interleave their writes and the loser is silently discarded; worse, a
#    --check that sampled the saved value *before* a click updated it would then
#    actively revert the click. Caught in the act in the log on 2026-09-09:
#      23:42:26  FAILED: wanted 90, sysfs reads 80
#      23:42:26  applied 80 (was 90)
#    which is precisely the reported "I set 90 and the panel stayed on 80".
#    Everything below therefore runs under flock, and --check samples the saved
#    value only after it holds the lock.
set -u

# Machine-specific names come from the profile install.sh generates. Sourcing
# it (rather than hardcoding) is what lets this script run unmodified on any
# machine; the fallback keeps it working if the profile has not been written.
HW_ENV="${XDG_CONFIG_HOME:-$HOME/.config}/scripts/hardware.env"
# shellcheck source=/dev/null
[ -r "$HW_ENV" ] && . "$HW_ENV"

BAT="/sys/class/power_supply/${BATTERY:-BAT0}"
# An unset/wrong BATTERY must not leave us pointed at the parent directory,
# which is itself a valid directory and would pass a bare [ -d ] test.
[ -d "$BAT" ] || BAT=$(ls -d /sys/class/power_supply/BAT* 2>/dev/null | head -1)
THRESH="$BAT/charge_control_end_threshold"
STATE="$HOME/.config/battery-threshold"
LOG="${XDG_RUNTIME_DIR:-/tmp}/battery-threshold.log"
LOCK="${XDG_RUNTIME_DIR:-/tmp}/battery-threshold.lock"
# Watchdog bookkeeping, deliberately in the runtime dir: it describes this boot
# only, and starting a boot with no history is the correct starting point.
WSTATE="${XDG_RUNTIME_DIR:-/tmp}/battery-threshold.check"

# Desktops, and laptops whose firmware exposes no cap, have nothing to do here.
[ -n "$BAT" ] && [ -e "$THRESH" ] || exit 0

# ---- serialisation ---------------------------------------------------------
# Re-exec under flock so every path below — including the read-modify-write in
# apply() and the sample-then-decide in --check — is atomic against the other
# three callers. See note 3 above.
if [ -z "${BT_LOCKED:-}" ]; then
    export BT_LOCKED=1
    if [ "${1:-}" = "--state" ]; then
        # A pure reader. It must never block the panel's 2s poll behind a
        # 0.6s apply, and it never writes, so it does not take the lock at all.
        :
    elif [ "${1:-}" = "--check" ]; then
        # The watchdog is the one caller that may be skipped: a held lock means
        # a setter is applying the value right now, which is the watchdog's own
        # job, and it runs again in 60s. -E 0 so a skip is not an error.
        exec flock -n -E 0 "$LOCK" "$0" "$@"
    else
        # Every other caller waits. Dropping a user's click is the bug this
        # whole arrangement exists to prevent, so a click never gives up its
        # turn; the wait is bounded only so a wedged holder cannot hang the
        # detached shell forever.
        exec flock -w 15 "$LOCK" "$0" "$@"
    fi
fi

log() { printf '%s  %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

read_int() { local v; v=$(cat "$1" 2>/dev/null); [[ "$v" =~ ^[0-9]+$ ]] && echo "$v"; }

saved() {
    local v; v=$(cat "$STATE" 2>/dev/null)
    [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -ge 20 ] && [ "$v" -le 100 ] && { echo "$v"; return; }
    echo 100
}

capacity() { read_int "$BAT/capacity" || echo -1; }

# On AC? The adapter is ADP1 here and AC/AC0/ACAD elsewhere, so it is found by
# type rather than by name. "unknown" (-1) is treated as not-on-AC by callers,
# which only ever makes the watchdog quieter, never more destructive.
ac_online() {
    local d t
    for d in /sys/class/power_supply/*/; do
        t=$(cat "$d/type" 2>/dev/null)
        [ "$t" = "Mains" ] || continue
        read_int "$d/online" && return
    done
    echo -1
}

# apply TARGET [quiet]
# quiet suppresses the success line: the watchdog re-arms on a schedule and
# would otherwise bury the interesting lines under a log entry every few minutes.
apply() {
    local target=$1 quiet=${2:-} cur cap nudge new
    [ -w "$THRESH" ] || { log "cannot write $THRESH (udev rule/group applied? needs a real relogin)"; return 1; }
    cur=$(cat "$THRESH" 2>/dev/null)
    cap=$(capacity)

    # Force a real EC transaction (note 2). The nudge must be a value the EC
    # will actually act on, so it goes below the CURRENT CHARGE as well as below
    # the target — a cap the pack is already under is a limit the EC has nothing
    # to do about. 20 is the driver's floor.
    nudge=$(( target - 5 ))
    [ "$cap" -ge 0 ] && [ "$nudge" -gt $(( cap - 2 )) ] && nudge=$(( cap - 2 ))
    [ "$nudge" -lt 20 ] && nudge=20
    if [ "$nudge" -lt "$target" ]; then
        echo "$nudge" > "$THRESH" 2>/dev/null
        sleep 0.3
    fi

    echo "$target" > "$THRESH" 2>/dev/null
    sleep 0.3
    new=$(cat "$THRESH" 2>/dev/null)
    if [ "$new" = "$target" ]; then
        [ -n "$quiet" ] || log "applied $target (was $cur)"
    else
        log "FAILED: wanted $target, sysfs reads $new"
        return 1
    fi
}

case "${1:-}" in
    --state)
        # One line of ground truth for the taskbar panel.
        #
        # `want` is what the user asked for and is what the picker highlights.
        # It deliberately does NOT come from sysfs: sysfs is the driver's cache
        # (note 1), so a lost write, a resume, or an EC that dropped the cap
        # would silently move the highlight off the box the user clicked — which
        # is exactly how "I set 90 and it stayed on 80" looked from the panel.
        # `enforced` is the honest answer to "is the cap actually holding", and
        # is the only thing the panel should warn on. Sitting ABOVE the cap is
        # not by itself a fault — lowering the cap to 70 with the pack at 95%
        # leaves it there until something discharges it, and warning about that
        # would be crying wolf. Only the watchdog can tell the two apart, by
        # watching whether the charge is still climbing, so its verdict is
        # reused here rather than re-derived from a single sample.
        want=$(saved); t=$(cat "$THRESH" 2>/dev/null); cap=$(capacity)
        st=$(cat "$BAT/status" 2>/dev/null); ac=$(ac_online)
        lastcap=-1 lastac=-1 lastarm=0 warned=0
        # shellcheck source=/dev/null
        [ -r "$WSTATE" ] && . "$WSTATE"

        # The one write this otherwise read-only path makes, and it is
        # deliberate: seeing the machine off AC RETIRES a standing verdict.
        #
        # Without it the panel's line survives a quick unplug-and-replug, which
        # is precisely the gesture the line asks for. --check runs once a
        # minute, so a round trip shorter than that is never sampled off AC:
        # `lastac` stays 1, the AC-connect arm does not fire, and the warning
        # from before the unplug comes straight back. The panel polls this every
        # 2s while it is open — i.e. exactly while someone is doing the
        # unplugging — so this is the reader that can actually see it.
        #
        # Safe without the lock because it only ever moves the flag 1 -> 0 and
        # --check re-derives it from scratch anyway; the worst a race can do is
        # lose the clear for one tick. `lastac` is written with it so the next
        # --check still sees the edge and re-arms.
        if [ "$warned" = "1" ] && [ "$ac" != "1" ] && [ -w "$WSTATE" ]; then
            warned=0
            printf 'lastcap=%s\nlastac=%s\nlastarm=%s\nwarned=0\n' \
                   "$lastcap" "$ac" "$lastarm" > "$WSTATE"
        fi
        # And it only means anything while plugged in: off AC nothing is being
        # enforced or failing to be, and "replug to re-arm" is not advice you
        # can act on with the charger already out. So unplugging clears the
        # panel's line immediately rather than waiting on the next --check.
        # Faults only. Being above the cap is deliberately NOT one: lowering
        # the limit under the current charge leaves the pack there until
        # something discharges it, and captioning that would fire on an
        # ordinary click. So the panel speaks only when sysfs does not hold the
        # value, or the watchdog actually caught the EC dropping it.
        enforced=1
        [ "$t" = "$want" ] || enforced=0
        [ "$warned" = "1" ] && [ "$ac" = "1" ] && enforced=0
        printf 'want=%s sysfs=%s cap=%s status=%s ac=%s enforced=%s\n' \
               "$want" "${t:-?}" "$cap" "${st:-?}" "$ac" "$enforced"
        ;;

    --check)
        # Behavioural watchdog, running once a minute.
        #
        # The old version only acted when sysfs disagreed with the saved value,
        # or when capacity had already climbed 2% past the cap AND status still
        # read "Charging". Both tests miss the failure that actually loses a
        # battery: sysfs agrees (it is only a cache), and by the time capacity
        # is over the cap the EC has usually stopped reporting "Charging" — it
        # reads "Not charging" or "Full" while the pack keeps filling. That is
        # how a 90% cap ended a session at 100%: one violation was caught at
        # 93%, and every check after it was silent all the way up.
        #
        # So: re-assert on a schedule instead of only on detected drift, and
        # gate on AC rather than on the status string.
        want=$(saved); t=$(cat "$THRESH" 2>/dev/null); cap=$(capacity); ac=$(ac_online)
        [[ "$t" =~ ^[0-9]+$ ]] || exit 0
        [ "$cap" -ge 0 ] || exit 0

        lastcap=-1 lastac=-1 lastarm=0 warned=0
        # shellcheck source=/dev/null
        [ -r "$WSTATE" ] && . "$WSTATE"
        now=$(date +%s)
        rearm="" ; why=""

        if [ "$t" != "$want" ]; then
            # Someone else wrote the file, or it reset (sysfs resets to 100 on
            # boot). Unambiguous, and worth a log line.
            why="drift: sysfs=$t want=$want"
        elif [ "$ac" = "1" ]; then
            # AC has just come back. This is the moment the cap has to be
            # real, and the moment it is most likely to be stale — a resume or a
            # boot leaves the driver's cache intact while the EC has reset.
            # Cheap, precise, and covers the case where hypridle is toggled off
            # and its after_sleep_cmd never runs.
            #
            # Clearing `warned` here is what makes the panel's line go away on a
            # replug: this is a new attempt, and claiming failure again before
            # having watched the charge climb would be reporting the verdict of
            # the previous plug-in. It is tested BEFORE the over-cap case and
            # not as another arm of the same if/elif, because the two are true
            # together in exactly the situation that matters — replugging while
            # the pack is already above the cap, which is what someone does
            # after being told to replug. Written as an elif the AC-connect arm
            # was unreachable there and the line never cleared. Measured.
            if [ "$lastac" != "1" ]; then
                rearm=1; warned=0; why="AC connected -> re-arming cap $want%"
            fi

            if [ "$cap" -gt $(( want + 1 )) ]; then
                # Over the cap on AC. Either the EC dropped it, or the user
                # lowered the cap below where the pack already sits. Re-arm
                # every check while it lasts — this is the state that costs
                # cycle life, and re-arming is one WMI call.
                rearm=1
                # Still climbing past the cap across two checks a minute apart:
                # the EC is not honouring it and re-asserting is not winning.
                # Both samples have to be on AC — a capacity read from before
                # the charger came out says nothing about what is happening now.
                #
                # No notification. A toast was the first attempt and was wrong
                # for this: it is a standing condition, not an event, so the
                # popup fired once and left nothing behind while the panel that
                # could have shown it permanently went on looking correct.
                # `warned` is the whole report — --state hands it to the battery
                # panel, which draws one line under the picker.
                if [ "$lastcap" -ge 0 ] && [ "$lastac" = "1" ] \
                   && [ "$cap" -gt "$lastcap" ] && [ "$warned" = "0" ]; then
                    why="EC ignoring cap: capacity $lastcap%->$cap% with cap $want%"
                    warned=1
                fi
            else
                # Back under the cap: nothing to report, whatever came before.
                warned=0
                # Otherwise re-assert every 3 minutes on AC. Nothing readable
                # says whether the EC still holds the cap (note 1), so the only
                # defence is to keep telling it. Off AC there is nothing to
                # enforce, so we stay quiet and leave the EC alone.
                [ -z "$rearm" ] && [ $(( now - lastarm )) -ge 180 ] && rearm=1
            fi
        else
            warned=0
        fi

        if [ -n "$why" ]; then
            log "$why"
            apply "$want"
            lastarm=$now
        elif [ -n "$rearm" ]; then
            apply "$want" quiet
            lastarm=$now
        fi

        printf 'lastcap=%s\nlastac=%s\nlastarm=%s\nwarned=%s\n' \
               "$cap" "$ac" "$lastarm" "$warned" > "$WSTATE"
        ;;

    "")
        apply "$(saved)"
        ;;

    *)
        if [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 20 ] && [ "$1" -le 100 ]; then
            mkdir -p "$(dirname "$STATE")"
            # Record the intent before touching the hardware. The panel reads
            # this file (via --state), so the click is reflected even if the EC
            # write below fails — and a failure is then visible as "not
            # enforced" rather than as the highlight silently jumping back.
            echo "$1" > "$STATE" || { log "cannot write $STATE"; exit 1; }
            # A fresh choice invalidates the watchdog's history: the pack may
            # legitimately sit above a newly lowered cap, and that must not be
            # reported as the EC ignoring it.
            rm -f "$WSTATE"
            apply "$1"
        else
            echo "usage: $0 [20-100|--check|--state]" >&2; exit 2
        fi
        ;;
esac
