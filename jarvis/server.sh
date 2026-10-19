#!/usr/bin/env bash
# server.sh {up|down|status} [model.gguf] — the jarvis model server, on the dGPU.
#
# `up` is called the moment the pill opens, NOT when Enter is pressed: loading
# the weights into VRAM takes a second or two, and that happens while the
# sentence is still being typed. It returns as soon as the server answers
# /health, and immediately if it already does.
#
# ── Why the NVIDIA card, and why that costs nothing when idle ─────────────
# The 3050 sits in D3cold (fully powered off; /sys/.../power_state) whenever
# nothing holds it open — the desktop never renders on it. Running the model
# there keeps the CPU out of it entirely, which is what Ahaan asked for. The
# price is that the card is awake while the server lives, so `down` is called
# as soon as the job is done (or the pill is dismissed) and the card drops back
# to D3cold — measured ~10 s after the server exits.
#
# ── Why the device is looked up by name ───────────────────────────────────
# Vulkan numbers devices in enumeration order: today the Iris Xe is Vulkan0 and
# the 3050 Vulkan1, but nothing promises that ordering. Grep the name instead.
#
# ── Quiet is lifted while the model is up, and put back after ─────────────
# Under the Quiet profile asusd caps the dGPU at 15 W and it sits at 210 MHz:
# measured 2.4 tok/s, a median of 11.3 s per command, on Vulkan AND on CUDA —
# the clock is the limit, not the backend. Balanced gives 38.8 tok/s and
# ~0.8 s. Ahaan chose (2026-10-05) to switch to Balanced only while jarvis
# works and return to Quiet after, rather than raise the GPU cap alone (that
# needs root per call) or live with 11 s.
#
# `up` records the profile it found ONLY when it changes it; `down` puts it
# back ONLY if the profile is still the one `up` set. If Ahaan picks a profile
# himself in between, his choice wins and nothing is restored over it.
#
# ── Detached, both halves ─────────────────────────────────────────────────
# Started from a Quickshell Process; see the SIGPIPE rule in the system map.
set -uo pipefail

PORT="${JARVIS_PORT:-8737}"
MODELS="${XDG_DATA_HOME:-$HOME/.local/share}/jarvis/models"
MODEL="${2:-${JARVIS_MODEL:-$MODELS/Qwen3-4B-Instruct-2507-Q5_K_M.gguf}}"
RUN="${XDG_RUNTIME_DIR:-/tmp}/jarvis"
PROFILE="${XDG_CONFIG_HOME:-$HOME/.config}/scripts/power-profile.sh"
mkdir -p "$RUN"

healthy() { curl -sf -m 1 "http://127.0.0.1:$PORT/health" >/dev/null; }

# The llama-server(s) serving THIS port, found from /proc rather than trusted
# from server.pid. Measured 2026-10-06: the pill's --warm and the request both
# saw "down" and both ran `up`; two servers raced for the port, the loser
# exited, but its pid had overwritten the winner's in server.pid. `down` then
# killed the dead pid and restored Quiet, and the real server ran orphaned for
# SIX HOURS with the 3050 awake — while every later request saw "up", skipped
# `up`, and so never lifted Quiet (which is what made it slow).
ours() {
    local p
    for p in $(pgrep -x llama-server); do
        # Captured, then matched: never `producer | grep -q` under pipefail.
        local c; c="$(tr '\0' ' ' </proc/$p/cmdline 2>/dev/null)"
        case "$c" in *"--port $PORT "*) echo "$p" ;; esac
    done
    return 0
}

# One `up` or `down` at a time: the lock is what makes the race above
# impossible rather than unlikely.
exec 9>"$RUN/server.lock"
flock -w 20 9 || { echo "jarvis server lock busy" >&2; exit 1; }

case "${1:-}" in
up)
    if [ -x "$PROFILE" ] && [ ! -f "$RUN/profile.prev" ]; then
        cur="$("$PROFILE" get 2>/dev/null || true)"
        if [ "$cur" = power-saver ] && "$PROFILE" set balanced >/dev/null 2>&1; then
            echo power-saver >"$RUN/profile.prev"
        fi
    fi
    healthy && exit 0
    # Capture first, then grep: `producer | grep` under pipefail has bitten
    # this repo four times.
    devs="$(llama-server --list-devices 2>&1)"
    # CUDA first: its kernels ship compiled, where Vulkan's pipelines were
    # rebuilt on the CPU at every start (31 s on Performance, 91 s on Quiet).
    dev="$(printf '%s\n' "$devs" | sed -n 's/^ *\(CUDA[0-9]*\): NVIDIA.*/\1/p' | head -1)"
    [ -n "$dev" ] || dev="$(printf '%s\n' "$devs" | sed -n 's/^ *\(Vulkan[0-9]*\): NVIDIA.*/\1/p' | head -1)"
    # No NVIDIA device (dGPU missing/disabled): fall back to whatever llama
    # picks rather than not working at all.
    setsid llama-server -m "$MODEL" ${dev:+--device "$dev"} -ngl 99 -c 8192 \
        --host 127.0.0.1 --port "$PORT" --jinja --no-webui \
        </dev/null >"$RUN/server.log" 2>&1 9>&- &
    # 9>&- above: the server must NOT inherit the lock's descriptor, or it holds
    # the lock for its whole life and every later up/down times out on it —
    # measured, the first version of this lock did exactly that. Same reason
    # lockscreen-launch.sh hands its child 9>&-.
    echo $! >"$RUN/server.pid"
    for _ in $(seq 100); do healthy && exit 0; sleep 0.1; done
    echo "jarvis server did not come up; see $RUN/server.log" >&2; exit 1 ;;
down)
    # Every llama-server on our port, by pid — never pkill -f, which matches
    # the calling shell — and waited for, so the card is free when this returns.
    for p in $(ours); do kill "$p" 2>/dev/null; done
    for _ in $(seq 50); do [ -z "$(ours)" ] && break; sleep 0.1; done
    for p in $(ours); do kill -9 "$p" 2>/dev/null; done
    rm -f "$RUN/server.pid"
    if [ -f "$RUN/profile.prev" ]; then
        [ "$("$PROFILE" get 2>/dev/null || true)" = balanced ] && "$PROFILE" set "$(cat "$RUN/profile.prev")" >/dev/null 2>&1
        rm -f "$RUN/profile.prev"
    fi ;;
status)
    healthy && echo up || echo down ;;
*)
    echo "usage: server.sh {up|down|status} [model.gguf]" >&2; exit 2 ;;
esac
