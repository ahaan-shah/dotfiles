#!/usr/bin/env bash
# ensure-hypridle.sh — make certain hypridle is running AND already holding its
# logind sleep inhibitor, before the caller suspends or hibernates.
#
# THE BUG THIS FIXES
# hypridle is what runs before_sleep_cmd (raising the lockscreen) and what holds
# the delay inhibitor that keeps the machine awake until the session is really
# locked. When it has been toggled off via idle-inhibitor.sh ("Always Awake"),
# the sleep paths respawned it with `hypridle & disown` — from a Quickshell
# Process in finder's PowerMenu. A Quickshell Process gives its child a PIPE for
# stdout/stderr, and closes the read end the moment the spawned command exits.
# hypridle inherited that pipe and was killed by SIGPIPE on its next log write —
# measured: fd/1 and fd/2 both `pipe:[...]`, and hypridle was gone the instant
# the read end closed. Its inhibitor died with it, so logind suspended with
# nothing holding it and nothing having locked the screen. The lockscreen had
# been started but was frozen part-way, which is why it only appeared on wake.
# Same mechanism as the Spotify launch bug (CLAUDE.md 2026-08-22 final).
#
# Two things are therefore required, and the old code did neither reliably:
#   1. Launch hypridle detached with its own fds, so nothing can SIGPIPE it.
#   2. Wait for the inhibitor to actually exist, not a fixed guess.
#      `sleep 0.5` happened to be enough (measured: 40-46ms to acquire it) but
#      only on an idle machine — right after a resume this laptop is clamped at
#      400MHz for minutes, where a 10x slower start would blow that budget.
#      Polling for the real thing costs nothing and cannot be raced.
set -u

pgrep -x hypridle >/dev/null || setsid hypridle </dev/null >/dev/null 2>&1 &

for _ in $(seq 1 60); do          # up to ~3s
    if systemd-inhibit --list --no-pager 2>/dev/null | grep -q hypridle; then
        exit 0
    fi
    sleep 0.05
done

# Never block the caller's suspend on this: a late lock is better than a machine
# that will not sleep at all.
exit 0
