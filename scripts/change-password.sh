#!/usr/bin/env bash
# change-password.sh — change this user's login/sudo password.
#
# Reads TWO lines on stdin: the current password, then the new one. Prints
# nothing on success. Exit 77 means the current password was wrong; anything
# else non-zero means the change itself failed.
#
#   printf '%s\n%s\n' "$current" "$new" | change-password.sh
#
# ── Why not `passwd` ──────────────────────────────────────────────────────
# `passwd` reads its prompts from /dev/tty, not stdin, so it cannot be driven
# from a GUI without allocating a pseudo-terminal and playing expect. Feeding it
# a here-doc works on some systems and silently does nothing on others, and
# "silently does nothing" applied to a password change is the worst possible
# failure: the user believes their password changed and it did not.
#
# `chpasswd` takes user:password on stdin by design, is deterministic, and
# either succeeds or fails loudly. It needs root, which is why the current
# password is required here at all — not to authorise the change itself (root
# could change it without knowing the old one) but so that nobody who merely
# walks up to an unlocked session can lock the owner out.
#
# ── The current password is verified BEFORE anything is touched ───────────
# `sudo -A -v` with the askpass below both proves the password is right and
# primes the ticket for the chpasswd that follows. If it fails, this exits 77
# and /etc/shadow has not been opened. The caller (finder's password box) also
# validates against PAM before it ever runs this, so a typo never gets this far
# — but this script has to be safe on its own, because it is runnable from a
# terminal like everything else in this directory.
#
# The same askpass mechanism as privileged-run.sh: sudo invokes $SUDO_ASKPASS
# on its own when there is no tty (measured — no -A flag required), the password
# never appears in argv, and it lives only in a 0600 file on the per-user tmpfs
# that an EXIT trap destroys.

set -uo pipefail

RUNTIME="${XDG_RUNTIME_DIR:-/tmp}"
umask 077

# Sweep our own stale files before starting. The EXIT trap below covers every
# ordinary exit and TERM/INT/HUP/QUIT, but nothing can catch SIGKILL — and
# Quickshell kills the child when the menu closes, which is exactly how two
# 0-byte leftovers were found sitting in $XDG_RUNTIME_DIR. They were empty
# (the trap had truncated before it was cut short) so nothing leaked, but a
# file named like this should never outlive the run that made it.
find "$RUNTIME" -maxdepth 1 -name '.hyprahaan-chpw.*' -mmin +2 -delete 2>/dev/null || true
find "$RUNTIME" -maxdepth 1 -name '.hyprahaan-chpwask.*' -mmin +2 -delete 2>/dev/null || true
PASSFILE="$(mktemp "$RUNTIME/.hyprahaan-chpw.XXXXXX")"
ASKPASS="$(mktemp "$RUNTIME/.hyprahaan-chpwask.XXXXXX")"

cleanup() {
    [ -f "$PASSFILE" ] && : >"$PASSFILE"
    rm -f "$PASSFILE" "$ASKPASS"
}
trap cleanup EXIT INT TERM HUP QUIT

IFS= read -r CURRENT || true
IFS= read -r NEW     || true

[ -n "${CURRENT:-}" ] || { echo "no current password given" >&2; exit 2; }
# An empty new password would leave the account with no password at all —
# pam_unix is configured `nullok` here, so it would genuinely authenticate.
[ -n "${NEW:-}" ] || { echo "the new password cannot be empty" >&2; exit 2; }

printf '%s' "$CURRENT" >"$PASSFILE"
unset CURRENT

cat >"$ASKPASS" <<EOF
#!/usr/bin/env bash
cat "$PASSFILE"
EOF
chmod 700 "$ASKPASS"
export SUDO_ASKPASS="$ASKPASS"

# Drop any cached ticket, so a wrong password fails here rather than sailing
# through on someone else's authentication.
sudo -k 2>/dev/null || true

if ! sudo -A -v 2>/dev/null; then
    echo "current password is incorrect" >&2
    exit 77
fi

# chpasswd reads user:password on ITS stdin; the askpass helper is a separate
# program, so the two never contend for the same descriptor.
if ! printf '%s:%s\n' "$USER" "$NEW" | sudo -A chpasswd 2>/dev/null; then
    echo "the password could not be changed" >&2
    exit 1
fi
unset NEW
exit 0
