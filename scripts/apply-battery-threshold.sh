#!/usr/bin/env bash
# apply-battery-threshold.sh [VALUE|--check|--state|--resume]
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
#
# 4. RE-ASSERTING AFTER A HIBERNATE IS NOT ENOUGH, AND NOTHING NOTICED.
#    Reported 2026-09-11: "when I wake from hibernation it charges to 100% even
#    though the limit says 90%". Every mechanism this file already had did fire.
#    From the journal and the log, around the 15:34:57 resume:
#      15:34:57  systemd-sleep: System returned from sleep operation 'hibernate'
#      15:34:58  applied 90 (was 90)            <- hypridle's after_sleep_cmd
#      15:35:17  AC connected -> re-arming cap 90%
#      15:35:18  applied 90 (was 90)            <- and the watchdog too
#    So the resume hook ran, the watchdog ran, the nudge-then-set ran, sysfs
#    read back 90 every time — and the pack still filled to 100%. That rules
#    out every "the hook did not fire" explanation and leaves only this: after
#    a hibernate the EC has been powered down and re-initialised, and a sysfs
#    write — nudge or not — does not reliably re-latch the cap in it. What does
#    re-latch it is the charger being pulled and put back.
#    The first attempt at this was to hit the EC harder from software: take the
#    cap to the floor, hold it, restore it — reproduce a replug's transition
#    without the charger. Measured the same evening: IT DOES NOT WORK. Nothing
#    written to sysfs restores enforcement. A physical unplug/replug does, every
#    time (confirmed 2026-09-11 22:14, with the pack charging through a 72% cap
#    beforehand and honouring 90% after).
#    So the only honest design is: assume the cap may be dead, TEST whether it
#    is, and when it is, tell the user the one thing that actually fixes it.
#    The old code could not test, because it only read the cache. observe() can.
#
# 5. THE EC HAS A WIDE START/STOP HYSTERESIS, AND THAT MAKES DIPS DANGEROUS.
#    Once this EC has stopped charging it does not resume until the charge falls
#    well below the cap, and RAISING THE CAP AGAIN DOES NOT RESTART IT.
#    Measured 2026-09-11: pack at 77%, cap written to 79 and then straight back
#    to 90, and it sat at "Not charging" for eighteen minutes plugged in.
#    Writing 100 restarted it within 4s — 100 disables limiting outright — and
#    90 written while it was already charging was honoured normally.
#    This is why nothing here ever writes a cap below the current charge any
#    more. Both places that did (apply()'s nudge, probe()'s dip) would park the
#    battery: plug in overnight at 77%, wake up at 77%. That is a worse bug than
#    the overcharge this file exists to prevent, and the routine re-arm did it
#    every three minutes. Both are gone; see apply() and probe().
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
# How long the pack must sit above the cap without measurably gaining before the
# cap is called healthy. Long enough that a slow trickle cannot hide inside it:
# at the ~0.6A taper measured near the cap, 1% of this pack takes about four
# minutes, so ten minutes is two clear steps' worth of headroom.
OBSERVE_WINDOW=600

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

# ---- sensing whether the cap is actually holding ---------------------------
#
# TWO SIGNALS, AND THE HISTORY OF GETTING THEM WRONG IS THE POINT.
#
# current_now IS trustworthy, and an earlier version of this comment said it was
# not. Measured 2026-09-11 23:27, pack stopped at 93% against a 90% cap, twelve
# samples over a minute: current_now = 0 on every one, status "Not charging".
# Measured again at 22:19, parked at 77%: 0. So it does fall cleanly to zero
# when the EC stops, and 0 vs ~600000 is a 12000x margin, not a tuning.
#
# The retracted claim was "current_now never falls to zero here", and the way it
# was arrived at is worth keeping, because it is a trap this file can fall into
# again. At 91% the reading was 601000 with status "Charging" while the cap was
# 90. That is REAL TAPERING CHARGE CURRENT — the pack genuinely was filling past
# the cap, and the detector was right to say so. It was misread as a false
# positive, and a hardware claim was then invented to explain a false positive
# that had never happened. Nothing was measured to support it.
#
#   The lesson, and it is the same one as note 1: do not explain away a reading
#   you did not want. Go and measure the state you are claiming.
#
# charge_now is the corroborating signal: direction-true, but QUANTIZED to
# exactly 1% of the pack (44040 uAh of 4404000) and flat between steps —
# measured flat for 48s, then a whole 44000 step. That quantization caused its
# own wrong call: charge_now flat across 40s was read as "not gaining" when the
# pack was merely between steps, and the next sample went 91% -> 92%. A sample
# window shorter than the quantum proves nothing.
#
# So: current_now answers "is charge flowing right now" in one read, and the
# charge_now window answers "has it actually gained" over ten minutes. The fast
# arm catches a fault within a check; the slow arm is what can positively
# declare the cap healthy, since a single zero reading is only an instant.
charge_ua() { read_int "$BAT/charge_now" || read_int "$BAT/energy_now" || echo -1; }
full_ua()   { read_int "$BAT/charge_full" || read_int "$BAT/energy_full" || echo -1; }

# observe TARGET BASECHARGE BASEAGE PREVAC -> 0 holding, 1 ignoring, 2 no evidence
#
# BASECHARGE is charge_now as it was BASEAGE seconds ago, while the pack has
# been above the cap on AC the whole time. So the question asked is "has the
# pack measurably gained during this window", and the window rolls forward.
#
# The window matters as much as the threshold, and a fixed baseline was wrong:
# once the delta crossed the floor it could never come back down, so a warning
# would latch for ever even after charging had genuinely stopped. Rolling the
# baseline is what lets a fault clear itself.
#
# The floor is half of one reporting quantum. charge_now on this pack resolves
# to exactly 1% (44040 uAh of 4404000) and sits flat between steps — measured
# 2026-09-11: flat for 48s, then a whole 44000 step — so half a quantum cannot
# be reached by noise, and any single real step trips it. Deriving it from
# charge_full rather than hardcoding keeps it correct on a different pack.
observe() {
    local target=$1 base=$2 age=$3 prevac=$4 cap now full floor
    [ "$(ac_online)" = "1" ] || { echo 2; return; }
    [ "$prevac" = "1" ] || { echo 2; return; }   # the baseline must also be on AC
    cap=$(capacity); [ "$cap" -ge 0 ] || { echo 2; return; }
    [ "$cap" -ge "$target" ] || { echo 2; return; }   # below the cap: nothing to see
    now=$(charge_ua); [ "$now" -ge 0 ] || { echo 2; return; }
    [ "$base" -ge 0 ] || { echo 2; return; }          # no baseline yet

    full=$(full_ua)
    floor=$(( full / 200 )); [ "$full" -gt 0 ] || floor=20000

    # FAST ARM: above the cap on AC with current actually flowing in. One read,
    # so a fault is caught on the next check rather than after a whole window.
    # 50 mA is a noise floor, not a tuned threshold: the two states measured are
    # 0 and ~600000.
    if [ "$cap" -gt "$target" ]; then
        local i st
        i=$(read_int "$BAT/current_now" || echo -1)
        st=$(cat "$BAT/status" 2>/dev/null)
        [ "$i" -gt 50000 ] && [ "$st" != "Discharging" ] && { echo 1; return; }
    fi

    # SLOW ARM: it has measurably gained across the window. Kept even though the
    # fast arm is quicker, because it depends on nothing the fast arm depends on
    # — a machine whose current_now behaves differently still gets a verdict.
    if [ "$cap" -gt "$target" ] && [ $(( now - base )) -gt "$floor" ]; then
        echo 1; return
    fi
    # Only call it holding once the window has actually elapsed. Before that,
    # "no gain yet" is just "not enough time has passed", which is not evidence
    # and must not retire a standing warning.
    [ "$age" -ge "$OBSERVE_WINDOW" ] && { echo 0; return; }
    echo 2
}

# probe TARGET -> same three codes as observe(). It no longer probes.
#
# It used to earn an answer below the cap by dropping the cap under the current
# charge and watching whether charging stopped — Ahaan's "set it to 50 and
# back", turned into a measurement. It worked as a test, and it is gone anyway,
# because note 5 makes the cost unacceptable: every such dip parks the battery.
# Run at 77% it stopped charging, and the pack was still at 77% eighteen minutes
# later, plugged in, because raising the cap does not restart a stopped EC.
# A verification that strands the battery is worse than the overcharge it was
# verifying against.
#
# So below the cap there is no safe test, and this says so by returning 2 (no
# evidence) instead of inventing one. The fault is caught by observe() one
# percent above the cap instead: later than a probe, honest, and harmless.

# Persist the watchdog's bookkeeping. One writer for it so the field list cannot
# drift between the four places that used to open-code this printf.
save_wstate() {
    printf 'lastcap=%s\nlastac=%s\nlastarm=%s\nwarned=%s\nlastseen=%s\nunplugged=%s\nbasecharge=%s\nbasetime=%s\n' \
           "$lastcap" "$lastac" "$lastarm" "$warned" "$lastseen" "$unplugged" "$basecharge" "$basetime" > "$WSTATE"
}

# apply TARGET [quiet]
# quiet suppresses the success line: the watchdog re-arms on a schedule and
# would otherwise bury the interesting lines under a log entry every few minutes.
#
# There is no "deep" mode any more. It dipped the cap to the floor to force a
# charging -> stopped -> charging transition, on the theory that this was the
# shape of the replug that re-latches the EC. Measured: it is not. A physical
# replug restores enforcement and no sequence of sysfs writes does, so the deep
# dip bought nothing at all — while stopping charging outright, which the
# hysteresis in note 5 then makes sticky. It was the most dangerous line here.
apply() {
    local target=$1 quiet=${2:-} cur cap nudge new
    [ -w "$THRESH" ] || { log "cannot write $THRESH (udev rule/group applied? needs a real relogin)"; return 1; }
    cur=$(cat "$THRESH" 2>/dev/null)
    cap=$(capacity)

    # Force a real EC transaction (note 2) WITHOUT ever telling the EC to stop.
    #
    # This used to nudge DOWN past the current charge, reasoning that a cap the
    # pack is already under is a limit the EC has nothing to do about. Measured
    # 2026-09-11, that reasoning is backwards on this hardware and the nudge was
    # actively harmful. See note 5: the EC has a wide start/stop hysteresis, so
    # a cap dropped below the pack stops charging and RAISING IT AGAIN DOES NOT
    # RESTART IT. The routine re-arm was doing that every three minutes.
    #
    # The nudge only ever had to make the DRIVER perform a real store instead of
    # short-circuiting an unchanged value. Any different value does that, so it
    # goes just below the target and stays ABOVE the pack — here, a limit the EC
    # has nothing to do about is exactly what we want. With no headroom between
    # the two there is no safe nudge, and the target is written alone.
    nudge=$(( target - 1 ))
    [ "$cap" -ge 0 ] && [ "$nudge" -le "$cap" ] && nudge=$target
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
        # would be crying wolf. Only the watchdog can tell the two apart, so its
        # verdict is reused here rather than re-derived from a single sample.
        #
        # `reason` is new, and it exists because "not enforced" is not one
        # situation but three, and they want different words on screen. See the
        # caption block in taskbar/shell.qml.
        want=$(saved); t=$(cat "$THRESH" 2>/dev/null); cap=$(capacity)
        st=$(cat "$BAT/status" 2>/dev/null); ac=$(ac_online)
        lastcap=-1 lastac=-1 lastarm=0 warned=0 lastseen=0 unplugged=0 basecharge=-1 basetime=0
        # shellcheck source=/dev/null
        [ -r "$WSTATE" ] && . "$WSTATE"

        # The one write this otherwise read-only path makes, and it is
        # deliberate: it records that the user has done the FIRST HALF of the
        # gesture the caption asks for.
        #
        # This used to clear `warned` outright on seeing the machine off AC, so
        # that a quick unplug-and-replug could not be outrun by the once-a-
        # minute --check and leave the old warning standing. That worked, but it
        # threw away the fact that the cap was known bad the instant the plug
        # came out — so the caption vanished mid-gesture and the user had no
        # idea whether the replug had achieved anything. Now the flag is kept
        # and `unplugged` is raised instead: the caption switches to the second
        # half of the instruction, and the AC-connect arm in --check MEASURES
        # whether the replug worked before deciding to clear anything. Nothing
        # is cleared on hope any more.
        #
        # Safe without the lock for the same reason as before: it only ever
        # moves a flag 0 -> 1, --check re-derives the whole state from scratch,
        # and the worst a race can do is lose it for one tick. The panel polls
        # this every 2s — i.e. exactly while someone is doing the unplugging —
        # so it is the reader that can actually see a short round trip.
        if [ "$warned" = "1" ] && [ "$ac" != "1" ] && [ "$unplugged" != "1" ] && [ -w "$WSTATE" ]; then
            unplugged=1
            lastac="$ac"
            save_wstate
        fi

        # Faults only. Being above the cap is deliberately NOT one: lowering the
        # limit under the current charge leaves the pack there until something
        # discharges it, and captioning that would fire on an ordinary click.
        enforced=1; reason=ok
        if [ "$t" != "$want" ]; then
            # sysfs does not even hold the value — someone else wrote the file,
            # or it reset. The watchdog fixes this within 60s, but say so while
            # it stands rather than showing a picker that is lying.
            enforced=0; reason=drift
        fi
        if [ "$warned" = "1" ]; then
            enforced=0
            # Which half of the instruction to show. On AC: pull the charger.
            # Off AC: put it back. A message that asks for a two-step gesture
            # has to follow the user through it, or the second step looks
            # optional — and off AC the old code said nothing at all, which read
            # as "unplugging fixed it" when it had done no such thing.
            if [ "$ac" = "1" ]; then reason=replug; else reason=plugback; fi
        fi
        printf 'want=%s sysfs=%s cap=%s status=%s ac=%s enforced=%s reason=%s\n' \
               "$want" "${t:-?}" "$cap" "${st:-?}" "$ac" "$enforced" "$reason"
        ;;

    --resume)
        # Called by hypridle's after_sleep_cmd, by hyprland.lua at startup, and
        # by --check whenever it finds time it cannot account for.
        #
        # The premise is note 4: after a hibernate the cap must be assumed dead
        # until proven otherwise, because every cheaper assumption has already
        # been measured wrong. Re-assert it, and do NOT pretend to a verdict —
        # observe() needs the pack at or above the cap plus a baseline, and a
        # fresh resume has neither. The watchdog concludes later.
        # Idempotent and safe to call from all three places.
        want=$(saved)
        # Carry the previous verdict in: a resume proves nothing either way, so
        # a standing warning must keep standing rather than be silently retired
        # by the act of waking up. Everything else about the old bookkeeping is
        # meaningless across a resume and is replaced below.
        lastcap=-1 lastac=-1 lastarm=0 warned=0 lastseen=0 unplugged=0 basecharge=-1 basetime=0
        # shellcheck source=/dev/null
        [ -r "$WSTATE" ] && . "$WSTATE"
        log "resume/boot: re-asserting cap ${want}%"
        apply "$want"
        log "re-asserted; verdict deferred to the watchdog (needs the pack at the cap)"
        lastcap=$(capacity); lastac=$(ac_online)
        lastarm=$(date +%s); lastseen=$lastarm; unplugged=0; basecharge=-1; basetime=0
        save_wstate
        ;;

    --check)
        # Behavioural watchdog, running once a minute.
        #
        # The old version only acted when sysfs disagreed with the saved value,
        # or when capacity had already climbed 2% past the cap AND status still
        # read "Charging". Both tests miss the failure that actually loses a
        # battery: sysfs agrees (it is only a cache), and by the time capacity
        # is over the cap the EC has usually stopped reporting "Charging" — it
        # reads "Not charging" or "Full" while the pack keeps filling.
        #
        # So: re-assert on a schedule instead of only on detected drift, gate on
        # AC rather than on the status string, and — since note 4 — actually
        # measure the EC instead of inferring from what was written to it.
        want=$(saved); t=$(cat "$THRESH" 2>/dev/null); cap=$(capacity); ac=$(ac_online)
        [[ "$t" =~ ^[0-9]+$ ]] || exit 0
        [ "$cap" -ge 0 ] || exit 0

        lastcap=-1 lastac=-1 lastarm=0 warned=0 lastseen=0 unplugged=0 basecharge=-1 basetime=0
        # shellcheck source=/dev/null
        [ -r "$WSTATE" ] && . "$WSTATE"
        now=$(date +%s)
        rearm="" ; why=""

        # ---- did we lose time? ------------------------------------------
        # This runs every 60s, so a gap much larger than that means it was not
        # running: the machine was suspended, hibernated or off, or the timer
        # was restarted. Every one of those leaves the EC's cap unproven —
        # hibernate and boot both re-initialise the EC while asus-wmi's cached
        # sysfs value survives intact (note 1).
        #
        # This is the resume signal, and it is the only one available to a USER
        # unit. Checked on this machine: systemd 261 exposes sleep.target,
        # suspend.target and hibernate.target to the system manager only — the
        # user manager reports them not-found — and /usr/lib/systemd/system-sleep
        # is root-owned, so a hook there is a system-level change rather than
        # something this repo's per-user install can drop in.
        #
        # It is also a better signal than it first looks, because it does not
        # care WHY the gap happened and all of the causes want the same
        # response. hypridle's after_sleep_cmd calls --resume directly and gets
        # there first when it is running; this is what covers hypridle being
        # toggled off, which Ahaan does deliberately.
        #
        # A missing lastseen — a fresh $XDG_RUNTIME_DIR, i.e. the first check
        # after a boot — counts as a gap for exactly the same reason.
        # 150s: a normal gap is at most the 60s interval plus 15s of
        # AccuracySec, so this is two clear intervals of headroom and cannot
        # fire on ordinary scheduling jitter.
        if [ "$lastseen" -le 0 ]; then
            log "no history this boot -> treating as a cold start"
            exec "$0" --resume
        elif [ $(( now - lastseen )) -gt 150 ]; then
            log "unaccounted gap of $(( now - lastseen ))s since last check (resume, boot, or timer restart)"
            # exec, not a call: --resume writes the whole bookkeeping file
            # itself, including lastseen, so there is nothing left for this
            # invocation to do afterwards. The flock is held by the parent
            # `flock` process, so exec keeps it rather than dropping it.
            exec "$0" --resume
        fi

        if [ "$t" != "$want" ]; then
            # Someone else wrote the file, or it reset (sysfs resets to 100 on
            # boot). Unambiguous, and worth a log line.
            why="drift: sysfs=$t want=$want"
        elif [ "$ac" = "1" ]; then
            if [ "$lastac" != "1" ]; then
                # AC has just come back — either an ordinary plug-in or the
                # second half of the gesture the caption asked for. This is the
                # moment the cap has to be real, and the moment it is most
                # likely to be stale.
                #
                # It used to clear `warned` unconditionally here, on the
                # grounds that a warning the user cannot dismiss by obeying it
                # is worse than no warning. That grounds is still right, but
                # clearing was the wrong way to honour it: it made the caption
                # disappear on a replug that had fixed nothing, which is the
                # same lie in the opposite direction and is what let a 90% cap
                # reach 100% with a clean-looking panel. There is no instant
                # measurement to put in its place — see the note above observe()
                # — so the honest arrangement is the one below: clear, re-arm,
                # and let the watchdog re-accuse within a minute or two if the
                # EC is still dropping the cap.
                log "AC connected -> re-arming cap ${want}%"
                apply "$want"
                # A replug cannot be judged on the spot: observe() needs the
                # pack above the cap and a baseline to compare against, and a
                # fresh plug has neither. So clear the verdict and start a new
                # baseline. This is the one place a warning is retired without
                # proof, and it is deliberate — the user has just done the thing
                # the caption asked for, and a warning that survives being
                # obeyed teaches them to ignore the panel. If the EC is still
                # dropping the cap, observe() says so again within a minute or
                # two of the pack reaching the cap.
                warned=0; basecharge=-1; basetime=0
                unplugged=0
                rearm=""; lastarm=$now
            else
                # ---- the read-only test, every single check ---------------
                # The baseline is charge_now as it was when the pack first went
                # above the cap on this stretch of AC, so what is measured is
                # the whole time it has been over the line rather than one 60s
                # window. Reset it whenever the pack is not above the cap, so a
                # later excursion starts fresh rather than inheriting a stale
                # reading from before a discharge.
                if [ "$cap" -ge "$want" ] && [ "$ac" = "1" ]; then
                    [ "$basecharge" -ge 0 ] || { basecharge=$(charge_ua); basetime=$now; }
                else
                    basecharge=-1; basetime=0
                    # Below the cap on AC, a standing verdict is STALE, not
                    # merely unconfirmed, so retire it. The fault this file
                    # reports is "above the cap and still gaining"; with the
                    # pack under the cap that sentence describes nothing.
                    #
                    # It also closes a hole that keeps reappearing. The replug
                    # that retires a warning is detected from an AC EDGE, and
                    # that edge can be missed entirely: --check samples once a
                    # minute and --state only while the dropdown is open, so an
                    # unplug and replug done in a few seconds with the panel
                    # closed is never once observed off AC. The caption then
                    # survives the very gesture it asked for, which teaches the
                    # user to ignore the panel — and below the cap there is now
                    # no evidence with which to clear it, so it would stand for
                    # ever. Costs nothing: if the EC really is dropping the cap,
                    # the fast arm re-accuses within one check of the pack
                    # climbing back over it.
                    [ "$ac" = "1" ] && warned=0
                fi
                case "$(observe "$want" "$basecharge" "$(( now - basetime ))" "$lastac")" in
                    0) # a full window above the cap with no measurable gain
                       warned=0; basecharge=$(charge_ua); basetime=$now ;;
                    1) [ "$warned" = "1" ] || \
                           log "EC ignoring cap: pack gained while above ${want}% (now ${cap}%)"
                       warned=1; rearm=1
                       basecharge=$(charge_ua); basetime=$now ;;
                    *) : ;;   # below the cap, off AC, or the window is still open
                esac

                if [ "$cap" -gt $(( want + 1 )) ]; then
                    # Over the cap on AC. Either the EC dropped it, or the user
                    # lowered the cap below where the pack already sits. Re-arm
                    # every check while it lasts — this is the state that costs
                    # cycle life, and re-arming is one WMI call.
                    rearm=1
                fi
                # ---- a standing warning re-tests itself -------------------
                # The AC-connect arm above is how a replug normally retires the
                # caption, and it is reached from an EDGE: lastac was 0 and now
                # it is 1. That edge can be missed entirely. --check samples
                # once a minute and --state only while the panel is open, so an
                # unplug-and-replug done in a few seconds with the dropdown
                # closed is never observed off AC at all, and the caption then
                # stands after the very gesture that fixed it. Caught by the
                # regression sweep, which is also where the equivalent bug in
                # the old code was found: a warning the user cannot dismiss by
                # obeying it teaches them to ignore the panel.
                #
                # Waiting for an edge is the wrong shape for it. A verdict this
                # sticky should be re-earned on a schedule instead, so while the
                # caption is up and the machine is on AC, re-probe every 5
                # minutes and let the measurement decide. Self-healing whatever
                # was missed, and bounded: the probe interrupts charging for
                # ~1.5s, which is only spent while something is already wrong.
                # A standing warning needs no separate re-test any more: observe()
                # runs on every check and clears `warned` the moment the pack is
                # at or above the cap and no longer gaining. The 5-minute
                # re-probe that used to live here existed only because the probe
                # was expensive; the read-only test is not.

                # Otherwise re-assert every 3 minutes on AC. Nothing readable
                # says whether the EC still holds the cap (note 1), so the only
                # defence is to keep telling it. Off AC there is nothing to
                # enforce, so we stay quiet and leave the EC alone.
                [ -z "$rearm" ] && [ $(( now - lastarm )) -ge 180 ] && rearm=1
            fi
        fi

        if [ -n "$why" ]; then
            log "$why"
            apply "$want"
            lastarm=$now
        elif [ -n "$rearm" ]; then
            apply "$want" quiet
            lastarm=$now
        fi

        lastcap=$cap; lastac=$ac; lastseen=$now
        save_wstate
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
            apply "$1"
            # A fresh choice invalidates the watchdog's history: the pack may
            # legitimately sit above a newly lowered cap, and that must not be
            # reported as the EC ignoring it. This used to `rm -f "$WSTATE"`,
            # which is no longer safe — an absent file now reads as a lost-time
            # gap to --check, so the next tick would re-assert and probe a cap
            # the user had just set by hand. Writing a clean slate says the same
            # thing without faking a resume.
            lastcap=$(capacity); lastac=$(ac_online); lastarm=$(date +%s)
            warned=0 lastseen=$lastarm unplugged=0 basecharge=-1 basetime=0
            save_wstate
        else
            echo "usage: $0 [20-100|--check|--state|--resume]" >&2; exit 2
        fi
        ;;
esac
