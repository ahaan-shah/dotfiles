#!/usr/bin/env bash
# capture-wait.sh <command> [args...]
#
# Waits for the settings menu to actually be off the screen, then execs the
# command.  Every capture tool the menu offers goes out through this.
#
# ── The problem it exists for ────────────────────────────────────────────
# Settings -> Tools offers five things — screenshot, screen recording, the
# colour picker, OCR — and every one of them puts something over the whole
# screen: a slurp selection box, a hyprpicker freeze, or a capture.  The
# settings menu is ITSELF a full-screen layer surface on the overlay level
# (Launcher.qml, WlrLayershell.namespace "finder").
#
# Settings.activate() returning true calls requestClose() and the spawn goes
# out in the SAME frame, so without a gate the tool starts while the menu is
# still mapped.  What that looks like: a screenshot of the settings menu, a
# colour picked off the settings menu's own background, OCR of the menu's row
# labels, and a recording that opens on a shot of the panel.
#
# ── Why this is a poll and not a sleep ───────────────────────────────────
# Because "gone" is testable.  Launcher.qml binds that surface's visibility to
# finder.shown, so it genuinely unmaps rather than hiding — verified: the
# namespace is absent from `hyprctl layers` whenever the launcher is closed.
#
# A blind sleep would have to be sized for the worst case and would then be
# dead time every single time.  Measured here: one hyprctl round trip is ~14ms,
# and when there is no menu at all (the keybind path) that is the entire cost.
#
# ── Why a wrapper and not a function in each script ──────────────────────
# screenshot.sh, ocr-region.sh and hyprpicker already work and are already
# bound to keys.  None of them has any business knowing that a settings menu
# exists — the wait is a property of being launched FROM the menu, not a
# property of taking a screenshot.  Putting it here means those three are not
# touched at all, and there is one copy of the poll rather than four.
#
# The keybinds call the tools directly and never come through here, which is
# correct: there is no menu open on that path.
set -u

[ "$#" -ge 1 ] || { printf 'usage: %s <command> [args...]\n' "${0##*/}" >&2; exit 2; }

# 60 x 25ms = 1.5s ceiling.  The observed unmap is one or two frames; the
# ceiling only exists so that a launcher which somehow stays mapped cannot hang
# the capture forever.  Falling through after it rather than failing is
# deliberate — a menu in the shot is better than no screenshot at all.
i=0
while [ "$i" -lt 60 ]; do
    # grep -c, not grep -q.  -q exits on the first match and SIGPIPEs hyprctl,
    # which under `set -o pipefail` reports a SUCCESSFUL test as a failure.
    # This script does not set pipefail; the repo has been bitten by that five
    # times anyway and the safe form costs nothing.
    #
    # Matched as raw JSON text rather than through jq: hyprctl layers nests
    # namespaces under per-monitor, per-level objects, so the jq path is three
    # levels of iteration to answer a yes/no question, and jq is one more
    # process per poll.
    [ "$(hyprctl layers -j 2>/dev/null | grep -c '"namespace": "finder"')" -eq 0 ] && break
    sleep 0.025
    i=$((i + 1))
done

# ── The layer leaving hyprctl is not the menu leaving the SCREEN ─────────
# The loop above waits for the surface to unmap, and that is genuinely when
# the client is done with it -- but Hyprland animates layer surfaces closing,
# and `layersOut` is not overridden in hyprland.lua so it runs the built-in
# fade.  The compositor therefore keeps DRAWING the menu for the length of
# that animation after `hyprctl layers` has stopped listing it.
#
# Measured by sampling the screen with grim after a close: the surface leaves
# the layer list well before the pixels settle.  That gap is why the first
# full-screen screenshot taken from the menu still had the menu in it, faded
# but plainly there.
#
# Half a second, UNCONDITIONALLY.
#
# This was first written to sleep only if the poll above had actually SEEN the
# menu still mapped, on the reasoning that there is nothing to wait for
# otherwise.  That is wrong, and it is why the fix did not take: by the time
# the first `hyprctl layers` call returns -- ~14ms, one round trip -- the
# surface has usually already unmapped, because Settings.activate() sets
# finder.shown = false in the same frame it spawns this.  So the loop breaks on
# its FIRST iteration, never sets the flag, and the delay is skipped -- while
# the compositor is still drawing the close animation.
#
# It only appeared to work when tested by sending the close and launching this
# separately, which is slow enough to catch the surface still up.  The real
# path through the menu is faster than the test was.
#
# So the condition is gone.  Nothing reaches this script except the settings
# menu -- the keybinds call the tools directly -- so "was a menu open?" is
# always yes and asking was never buying anything.  A fixed number rather than
# a second poll because there is nothing left to poll: the compositor does not
# expose "this layer's close animation has finished", and what is being waited
# for is a fade whose duration is a config value, not an event.
sleep 0.5

# exec, so this wrapper does not sit in the process tree holding the tool's
# stdio open.  Settings._sh already put the whole thing behind
# `setsid … </dev/null >/dev/null 2>&1 &`, and a shell left waiting in the
# middle of that is one more process for no reason.
exec "$@"
