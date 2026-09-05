#!/usr/bin/env bash
# fingerprint.sh — what the settings menu's Security → Fingerprints page reads
# and writes. fprintd is the backend, the same one lockscreen/LockContext.qml
# calls `fprintd-verify` against; this adds the enrol and delete half.
#
#   fingerprint.sh status              KEY="value" lines, the whole page state
#   fingerprint.sh list                value/label/detail/current, one per finger
#   fingerprint.sh enroll <name>       claim a free slot and scan into it
#   fingerprint.sh delete <slot>       remove one enrolled finger
#   fingerprint.sh rename <slot> <name>
#
# ── fprintd has ten slots and no names ────────────────────────────────────
# fprintd does not store a label. A fingerprint IS one of ten fixed finger
# names — left-thumb … right-little-finger — and that is the whole identity it
# keeps. Ahaan asked to name a fingerprint when enrolling it, so the name lives
# here instead, in a file keyed by slot, and the slot itself is picked by this
# script rather than chosen by the user ("it selects any empty fingerprint
# slot"). Deleting a finger drops its name with it, so the two cannot drift.
#
# The store sits beside firewall-off.conf for the same reason that one does:
# it is a fact about this machine's security posture, not a config, so
# backup_configs.sh excludes it from the public mirror.
#
# ── Enrolment needs polkit; verification does not ─────────────────────────
# Measured with pkcheck on this machine:
#
#     net.reactivated.fprint.device.verify        allow_active = yes
#     net.reactivated.fprint.device.enroll        allow_active = auth_self_keep
#     net.reactivated.fprint.device.setusername   allow_active = auth_admin_keep
#
# That is why the lock screen can call fprintd-verify with no ceremony while
# enrolling and deleting cannot. `auth_self_keep` means the running polkit
# agent (lxqt-policykit-agent here) puts up a password dialog of its OWN —
# which is the thing this repo has deliberately engineered out everywhere else,
# and which would land in the middle of the enrol flow between the name box and
# the scan box.
#
# install/system/polkit-1/rules.d/49-fprintd-enroll.rules is the answer to
# that: it grants enrol to the local active user in wheel, exactly as `verify`
# already is, so finder's own password box is the only thing that ever asks.
# `status` reports ENROLL_READY, which is pkcheck's answer for that action, so
# the page can say the rule is missing instead of hanging behind a dialog
# nobody expected.

set -uo pipefail

STORE="${XDG_CONFIG_HOME:-$HOME/.config}/scripts/fingerprint-names.conf"

# Resolved once, and not simply trusted from the environment. Every fprintd
# call here names the user explicitly, and this is spawned from a Quickshell
# Process whose environment is inherited from the compositor — so an unset or
# tampered $USER would otherwise decide whose prints get deleted. id -un asks
# the kernel.
ME="$(id -un)"
[ -n "$ME" ] || { echo "fingerprint: cannot resolve the current user" >&2; exit 1; }

# The order slots are handed out in. Thumb and index first because they are the
# ones a press sensor is reachable with — the same list install.sh's fingerprint
# phase offers, reordered so the first free slot is a useful one.
FINGERS=(
    right-index-finger right-thumb  right-middle-finger right-ring-finger right-little-finger
    left-index-finger  left-thumb   left-middle-finger  left-ring-finger  left-little-finger
)

die() { echo "fingerprint: $*" >&2; exit 1; }

# Anything that reaches fprintd or the name store as a finger has to be one of
# the ten fprintd actually has. The values come from our own `list` output, so
# this is not expected to fire — it is here because the one argument that
# separates "delete this finger" from "delete EVERY finger" is `-f <slot>`, and
# a caller that fumbles it should be refused rather than interpreted.
valid_slot() {
    local f
    for f in "${FINGERS[@]}"; do [ "$f" = "$1" ] && return 0; done
    return 1
}

# "right-index-finger" -> "Right index finger". What the page shows when a
# slot has no name of its own.
pretty() {
    local s="${1//-/ }"
    printf '%s%s' "$(printf '%s' "${s:0:1}" | tr '[:lower:]' '[:upper:]')" "${s:1}"
}

# ── what fprintd currently holds ──────────────────────────────────────────
# One newline-delimited slot per line. fprintd-list needs no authorisation, so
# every read on this page is free — only changing something is gated.
enrolled_slots() {
    fprintd-list "$ME" 2>/dev/null | sed -n 's/^ *- #[0-9]*: *//p'
}

# Membership by case-matching a delimited string, never `printf | grep -q`:
# grep exits at its first match, the producer dies of SIGPIPE and `pipefail`
# turns that into a false failure. install.sh carries the same note; this repo
# has been bitten by it four times.
contains() {
    local hay=$'\n'"$1"$'\n' needle="$2"
    case "$hay" in *$'\n'"$needle"$'\n'*) return 0 ;; *) return 1 ;; esac
}

device_path() {
    fprintd-list "$ME" 2>/dev/null | sed -n 's/^Device at *//p' | head -n 1
}

# How many presses this sensor wants. NOT a constant: measured here it is 21
# (Egis Technology Match-on-Chip, scan-type "press"), where the five-to-eight
# that press sensors usually ask for would have made the progress ring finish
# a quarter of the way through the enrolment. Read it, do not assume it.
stage_count() {
    local dev n
    dev="$(device_path)"
    [ -n "$dev" ] || { echo 0; return; }
    n="$(busctl get-property net.reactivated.Fprint "$dev" \
             net.reactivated.Fprint.Device num-enroll-stages 2>/dev/null \
         | awk '{print $2}')"
    case "$n" in ''|*[!0-9]*) echo 0 ;; *) echo "$n" ;; esac
}

# ── the name store ────────────────────────────────────────────────────────
# slot<TAB>name, one per line. Read with a plain loop rather than sourced —
# the name is user-typed text and must never be evaluated as shell.
name_of() {
    [ -r "$STORE" ] || return 0
    local slot name
    while IFS=$'\t' read -r slot name; do
        [ "$slot" = "$1" ] && { printf '%s' "$name"; return 0; }
    done <"$STORE"
}

set_name() {
    local slot="$1" name="$2" tmp
    # The store is TAB-separated and line-oriented, and the name is whatever
    # was typed into the box — so a tab or a newline in it would not corrupt
    # one entry, it would silently shift every field after it. Flattened to
    # spaces and capped, rather than rejected: a name is a label, and nothing
    # downstream is worse off for it being 48 characters of one line.
    name="$(printf '%s' "$name" | tr '\t\n\r' '   ' | cut -c1-48)"
    mkdir -p "$(dirname "$STORE")"
    # 0600, and created that way rather than chmod'd after: the names are not
    # secrets, but they are a list of which of this person's fingers unlock the
    # machine, and there is no reason for any other account to read it. mktemp
    # already makes 0600; the umask covers the mv'd result.
    local oldmask; oldmask="$(umask)"
    umask 077
    tmp="$(mktemp "${STORE}.XXXXXX")" || { umask "$oldmask"; return 1; }
    if [ -r "$STORE" ]; then
        # Drop any existing line for this slot, keep the rest in order.
        awk -F'\t' -v s="$slot" '$1 != s' "$STORE" >"$tmp"
    fi
    [ -n "$name" ] && printf '%s\t%s\n' "$slot" "$name" >>"$tmp"
    # Atomic, for the same reason ui-prefs.sh is: a reader must never see a
    # half-written file.
    mv -f "$tmp" "$STORE"
    umask "$oldmask"
}

# ── commands ──────────────────────────────────────────────────────────────
cmd_status() {
    local slots count dev
    if ! command -v fprintd-enroll >/dev/null 2>&1; then
        echo 'AVAILABLE="no"'; echo 'REASON="fprintd is not installed"'; return 0
    fi
    dev="$(device_path)"
    if [ -z "$dev" ]; then
        echo 'AVAILABLE="no"'; echo 'REASON="no fingerprint reader"'; return 0
    fi
    slots="$(enrolled_slots)"
    count=0
    [ -n "$slots" ] && count="$(printf '%s\n' "$slots" | wc -l)"
    echo 'AVAILABLE="yes"'
    printf 'COUNT="%s"\n'  "$count"
    printf 'FREE="%s"\n'   "$(( ${#FINGERS[@]} - count ))"
    printf 'STAGES="%s"\n' "$(stage_count)"
    # Whether an enrol will be able to run without a polkit dialog in the way.
    # pkcheck answers this without attempting anything, so asking is free.
    if pkcheck --action-id net.reactivated.fprint.device.enroll --process $$ >/dev/null 2>&1; then
        echo 'ENROLL_READY="yes"'
    else
        echo 'ENROLL_READY="no"'
    fi
}

cmd_list() {
    local slots slot name
    slots="$(enrolled_slots)"
    [ -n "$slots" ] || return 0
    while IFS= read -r slot; do
        [ -n "$slot" ] || continue
        name="$(name_of "$slot")"
        # value / label / detail / current. The label is what the user called
        # it; the detail is the slot, so a fingerprint named "Work" still says
        # which finger it actually is — without that the delete list is a
        # column of names with no way to tell them apart at the sensor.
        printf '%s\t%s\t%s\t\n' "$slot" "${name:-$(pretty "$slot")}" "$(pretty "$slot")"
    done <<<"$slots"
}

cmd_enroll() {
    local name="${1:-}"
    [ -n "$name" ] || die "enroll needs a name"

    local slots slot="" f
    slots="$(enrolled_slots)"
    for f in "${FINGERS[@]}"; do
        contains "$slots" "$f" || { slot="$f"; break; }
    done
    [ -n "$slot" ] || { echo "FAIL no-free-slot"; exit 0; }

    echo "SLOT $slot"
    echo "LABEL $(pretty "$slot")"
    echo "STAGES $(stage_count)"

    # ── streaming fprintd-enroll ──────────────────────────────────────────
    # Two things this needs that a bare call does not give:
    #
    #   stdbuf -oL   fprintd-enroll prints with glib's g_print, which is plain
    #                libc stdio — and stdio switches to 4K block buffering the
    #                moment stdout is a pipe rather than a tty. Without this
    #                every "Enroll result:" line arrives at once when the
    #                process exits, so the scan UI would sit at zero for the
    #                whole enrolment and then jump to done.
    #
    #   exec 3< <(…) rather than a `cmd | while read` pipeline, for two
    #                reasons. The loop runs in THIS shell so it can keep state,
    #                and `$!` gives the child's pid, which the trap below needs
    #                — Quickshell terminates this script when the box is
    #                dismissed, and a foreground pipeline would leave
    #                fprintd-enroll holding the sensor with nothing reading it.
    #                That is not cosmetic: a claimed device makes the LOCK
    #                SCREEN's fprintd-verify fail, so an abandoned enrolment
    #                would quietly cost fingerprint unlock until it timed out.
    #
    # Verified that the pid is reachable: `stdbuf` execs rather than forks, so
    # $! from the substitution is fprintd-enroll itself (checked with
    # `stdbuf -oL sleep 20` — ps reports comm=sleep for that pid, and a kill on
    # it lands), and fprintd-enroll is a single ELF binary with no children of
    # its own for a kill to miss.
    exec 3< <(stdbuf -oL fprintd-enroll -f "$slot" 2>&1)
    local child=$!
    trap 'kill "$child" 2>/dev/null; exit 0' INT TERM HUP

    # `failed` exists so exactly ONE outcome line is ever printed. Without it a
    # refused enrolment emitted "FAIL unauthorized" from the loop and then
    # "FAIL incomplete" from the tail below, and the box showed whichever the
    # parser happened to keep — which was the second one, the useless one.
    local line stage=0 done=0 failed=0
    # `read` is a builtin and is interruptible, so the trap above fires while
    # this is blocked waiting for the next press.
    while IFS= read -r line <&3; do
        case "$line" in
            *"enroll-completed"*)   done=1; break ;;
            *"enroll-stage-passed"*) stage=$((stage + 1)); echo "STAGE $stage" ;;
            # Everything else fprintd reports mid-scan is a bad press, not a
            # failure: finger moved, lifted too early, sensor saw nothing. The
            # UI says "try again" and the stage counter deliberately does not
            # move, because the sensor did not accept that press either.
            *"enroll-retry-scan"*)          echo "RETRY move" ;;
            *"enroll-swipe-too-short"*)     echo "RETRY short" ;;
            *"enroll-finger-not-centered"*) echo "RETRY centre" ;;
            *"enroll-remove-and-retry"*)    echo "RETRY lift" ;;
            *"enroll-duplicate"*)           failed=1; echo "FAIL duplicate";    break ;;
            *"enroll-failed"*)              failed=1; echo "FAIL failed";       break ;;
            *"not authorized"*|*"NotAuthorized"*|*"Not Authorized"*)
                                            failed=1; echo "FAIL unauthorized"; break ;;
            *"No devices available"*)       failed=1; echo "FAIL nodevice";     break ;;
        esac
    done
    exec 3<&-
    wait "$child" 2>/dev/null

    if [ "$done" = 1 ]; then
        # Only now is the name recorded. Writing it up front would leave a name
        # attached to a slot that an abandoned enrolment never filled.
        set_name "$slot" "$name"
        echo "DONE"
    elif [ "$failed" = 0 ]; then
        # The stream ended without either a completion or a reason. fprintd
        # exiting quietly is what a disconnected sensor looks like from here.
        echo "FAIL incomplete"
    fi
}

cmd_delete() {
    local slot="${1:-}"
    [ -n "$slot" ] || die "delete needs a finger"
    valid_slot "$slot" || die "not a finger fprintd knows: $slot"
    # ALWAYS -f. `fprintd-delete <user>` with no finger deletes every enrolled
    # print on the device, and the difference between the two is one argument.
    if fprintd-delete "$ME" -f "$slot" >/dev/null 2>&1; then
        set_name "$slot" ""
        exit 0
    fi
    die "could not delete $slot"
}

cmd_rename() {
    local slot="${1:-}" name="${2:-}"
    [ -n "$slot" ] || die "rename needs a finger"
    valid_slot "$slot" || die "not a finger fprintd knows: $slot"
    set_name "$slot" "$name"
}

case "${1:-}" in
    status) cmd_status ;;
    list)   cmd_list ;;
    enroll) shift; cmd_enroll "$@" ;;
    delete) shift; cmd_delete "$@" ;;
    rename) shift; cmd_rename "$@" ;;
    *) die "usage: fingerprint.sh status|list|enroll <name>|delete <slot>|rename <slot> <name>" ;;
esac
