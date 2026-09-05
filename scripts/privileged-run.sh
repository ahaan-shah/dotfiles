#!/usr/bin/env bash
# privileged-run.sh <command> [args…] — run something that needs root, taking
# the password on STDIN instead of from a terminal.
#
# This is what finder's password box talks to. The box collects the password,
# writes it to this script's stdin, and this script makes sudo find it.
#
# ── Why SUDO_ASKPASS, and not `sudo -S` ───────────────────────────────────
# `sudo -S` reads the password on stdin, which would be simpler — but it only
# feeds OUR sudo. The command that actually needs this is `hyprpm enable`, and
# hyprpm shells out to sudo ITSELF. Priming a ticket first does not reach that
# one either: Arch's sudo defaults to tty tickets, and with no terminal at all
# the ticket is keyed to the PARENT PID — which is this shell for our sudo and
# hyprpm for hyprpm's, so they never match.
#
# SUDO_ASKPASS is inherited, so it covers every sudo in the process tree.
# Measured 2026-09-04 on this machine: with no tty, sudo invokes $SUDO_ASKPASS
# on its own — the -A flag is NOT required. Probed with an askpass that marks
# that it ran and then exits non-zero, so no authentication was attempted:
#
#     setsid env SUDO_ASKPASS=… sudo -v </dev/null
#     → sudo: no password was provided       (and the marker was written)
#
# ── Where the password lives ──────────────────────────────────────────────
# In $XDG_RUNTIME_DIR, which is a per-user tmpfs mounted 0700 — it never
# touches a disk and no other user can traverse it. Created under `umask 077`
# and removed by an EXIT trap that fires on every path out of this script,
# including a signal. It has to be a file rather than a pipe because askpass is
# a separate process spawned by sudo, and hyprpm's run may ask more than once.
#
# The password is never passed as an argument: argv is world-readable in /proc.

set -euo pipefail

[ $# -ge 1 ] || { echo "usage: privileged-run.sh <command> [args…]" >&2; exit 2; }

RUNTIME="${XDG_RUNTIME_DIR:-/tmp}"
umask 077

# Sweep our own stale files before starting. The EXIT trap below covers every
# ordinary exit and TERM/INT/HUP/QUIT, but nothing can catch SIGKILL — and
# Quickshell kills the child when the menu closes, which is exactly how two
# 0-byte leftovers were found sitting in $XDG_RUNTIME_DIR. They were empty
# (the trap had truncated before it was cut short) so nothing leaked, but a
# file named like this should never outlive the run that made it.
find "$RUNTIME" -maxdepth 1 -name '.hyprahaan-auth.*' -mmin +2 -delete 2>/dev/null || true
find "$RUNTIME" -maxdepth 1 -name '.hyprahaan-askpass.*' -mmin +2 -delete 2>/dev/null || true
PASSFILE="$(mktemp "$RUNTIME/.hyprahaan-auth.XXXXXX")"
ASKPASS="$(mktemp "$RUNTIME/.hyprahaan-askpass.XXXXXX")"

cleanup() {
    # Overwrite before unlinking. On tmpfs the pages are freed either way, but
    # the file is readable for as long as it exists and this run may take
    # minutes (a plugin rebuild), so it should not sit there holding a password
    # any longer than the command needs it.
    [ -f "$PASSFILE" ] && : >"$PASSFILE"
    rm -f "$PASSFILE" "$ASKPASS" "${PASSFILE}.armed"
}
trap cleanup EXIT INT TERM HUP QUIT

# read -r, no -s: stdin is a pipe from the caller, not a terminal, so there is
# nothing to echo. IFS= and -r keep the password exactly as typed, spaces and
# backslashes included.
IFS= read -r PASSWORD || true
printf '%s' "$PASSWORD" >"$PASSFILE"
unset PASSWORD

# ── one-shot while validating, unlimited afterwards ───────────────────────
# sudo retries a wrong password `passwd_tries` times (3, and not overridable
# from the command line). With a plain `cat` askpass it hands the SAME wrong
# password back three times: measured, a wrong password took ~8 s to be
# rejected and left three faillock entries instead of one.
#
# So the helper is one-shot to begin with — it prints once, disarms, and then
# FAILS, which makes sudo abort before attempting a second authentication. Once the password is
# known to be RIGHT it is rearmed unconditionally, because the command may
# contain nested sudo calls (hyprpm makes its own) and each needs it.
ARMED="$PASSFILE.armed"
: >"$ARMED"
cat >"$ASKPASS" <<EOF
#!/usr/bin/env bash
if [ -e "$ARMED" ]; then
    rm -f "$ARMED"
    cat "$PASSFILE"
    exit 0
fi
# Disarmed: FAIL rather than print nothing. An empty answer is still an
# authentication attempt (and another faillock entry); a non-zero askpass makes
# sudo abort with "no password was provided" without asking PAM at all.
exit 1
EOF
chmod 700 "$ASKPASS"

export SUDO_ASKPASS="$ASKPASS"

# -k first: drop any cached ticket so a wrong password fails HERE rather than
# silently succeeding on a ticket someone else primed, which would make the box
# look like it accepted a password it never checked.
sudo -k 2>/dev/null || true

# Validate the password before running anything. Two reasons: the caller gets a
# clean exit code to show "wrong password" against, and a command that is
# half-privileged (hyprpm rebuilds, then fails to write) is worse than one that
# never started.
if ! sudo -A -v 2>/dev/null; then
    # 77, not 1: the caller has to tell "you typed the wrong password" apart
    # from "the command itself failed", and they want different words on
    # screen. Nothing else in this script exits 77.
    echo "authentication failed" >&2
    exit 77
fi

# Right password — rearm for good, so nested sudo calls inside the command can
# authenticate as many times as they need to.
cat >"$ASKPASS" <<EOF
#!/usr/bin/env bash
cat "$PASSFILE"
EOF
chmod 700 "$ASKPASS"

"$@"
