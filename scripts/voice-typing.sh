#!/usr/bin/env bash
# voice-typing.sh — what Settings -> Tools -> Voice typing reads and writes.
# The menu decides what to offer; everything that happens is here, so all of it
# works from a terminal with no Quickshell.
#
#   voice-typing.sh status            KEY="value" lines, the whole page's state
#   voice-typing.sh on | off          start+enable / stop+disable the daemon
#   voice-typing.sh set-model <id>    download if missing, then make it default
#
# <id> is voxtype's own download name, the `download_arg` of `voxtype info
# models --json`. The four offered are the MODELS table below, and they are the
# four measured here on 2026-11-04 (i9-13900H, 73 LibriSpeech clips, 1150 words,
# ~6.6 s each, model loaded fresh per clip, on AC):
#
#     errors /100 words      load+transcribe   CPU per clip
#     base.en        9.1     1.0 s             0.5 s + iGPU
#     small.en       5.7     2.1 s             1.0 s + iGPU
#     moonshine      6.9     1.1 s             1.5 s
#     parakeet int8  3.0     1.8 s             2.2 s
#
# Errors discount voxtype's "Mr." against the reference's "MISTER". Clean read
# speech only: nobody's accent, mic or jargon was tested.
#
# ── An engine is a different binary ───────────────────────────────────────
# voxtype ships one executable per backend and the unit's ExecStart picks one.
# whisper runs on voxtype-vulkan (install/user-systemd/.../vulkan.conf). Moonshine
# and Parakeet exist only in voxtype-onnx-*, and /usr/bin/voxtype (whisper,
# avx2) refuses even to DOWNLOAD them: "requires the 'parakeet' feature", exit 1.
# `config set` is the same, exit 2. So the ONNX binary does both of those jobs.
#
# The switch is zz-engine.conf, a drop-in that exists only while an ONNX engine
# is chosen. Systemd applies drop-ins in name order, so zz- beats vulkan.conf,
# and removing it leaves vulkan.conf exactly as it was. Hence never touching
# vulkan.conf: its CPU fallback and its VK_LOADER_DRIVERS_DISABLE (which keeps
# the dGPU asleep) are all still in force for whisper.
#
# The ONNX CUDA builds are not offered. `voxtype setup onnx --status` says they
# need AVX-512, which this CPU lacks, and the point here is to leave the dGPU
# asleep anyway. Which ONNX CPU build is decided by reading /proc/cpuinfo at
# switch time, so nothing machine-specific is written into the repo.
#
# Harder clip, 2026-11-04: 134 words of a non-native speaker's earnings call
# (figures, EMEA, EBITDA, TeamViewer, Manchester United), plus a copy with pink
# noise. Errors /100 words with figures normalised, then the wait from stop to
# text on a 20.5 s clip, live daemon: small.en 11.9, 3.12 s; parakeet 12.7,
# 0.82 s; moonshine 14.9, 0.92 s; base.en 16.4, 1.25 s. Parakeet's lead above
# does not survive this audio, and it writes "forty seven percent", not "47%".
#
# None of the four wakes the dGPU to dictate. Starting the daemon did, for 22 s;
# see install/user-systemd/voxtype.service.d/no-gpu-probe.conf.
#
# ── Nothing stays in RAM ──────────────────────────────────────────────────
# ONNX engines get on_demand_loading = true. Whisper already has gpu_isolation
# (system map, "voxtype: 325 MB resident -> 23 MB"). Throwaway daemon with
# parakeet int8, 4 s recording:
#
#     idle 24 MB -> recording 193 MB -> transcribing 728 MB -> idle 76 MB
#     -> 53 MB five seconds later. Load 1.82 s, inside the recording.
#
# That load overlapping speech is what makes the wait after stopping 0.16 s and
# not 2 s.
#
# ── Detach ────────────────────────────────────────────────────────────────
# Settings calls this through _sh (setsid, stdio on /dev/null) because a download
# outlives anything holding a pipe to it; see the SIGPIPE rule. It reports back
# through STATE_FILE, not stdout: the menu watches that, and re-reads `status`.
# It sits flat in $XDG_RUNTIME_DIR, because a FileView watch on a directory that
# does not exist yet is permanently deaf (system map, "It never appeared once").

set -uo pipefail

CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
VOX_CONF="$CONFIG_HOME/voxtype/config.toml"
DROPIN_DIR="$CONFIG_HOME/systemd/user/voxtype.service.d"
ENGINE_DROPIN="$DROPIN_DIR/zz-engine.conf"
STATE_FILE="$RUNTIME_DIR/voice-typing.state"
LOCK_FILE="$RUNTIME_DIR/voice-typing.lock"
VOX_STATE="$RUNTIME_DIR/voxtype/state"
UNIT=voxtype.service

# id | engine | value for <engine>.model | what a notification calls it
MODELS='base.en|whisper|base.en|Whisper base.en
small.en|whisper|small.en|Whisper small.en
moonshine-base|moonshine|base|Moonshine base
parakeet-tdt-0.6b-v2-int8|parakeet|parakeet-tdt-0.6b-v2-int8|Parakeet v2'

note() { command -v notify-send >/dev/null 2>&1 && notify-send -a "Voice typing" "$@"; return 0; }
die()  { echo "voice-typing: $*" >&2; note "$*"; publish idle; exit 1; }

# mv, because the watcher reads on every event and must never see half a file.
publish() {
    local tmp="$STATE_FILE.tmp.$$"
    printf '%s\n' "$1" >"$tmp" && mv -f "$tmp" "$STATE_FILE"
}

# "Read me again", with no news of its own. The switch can move while a download
# runs, and publishing "idle" then would claim the download had finished.
poke() { publish "$(cat "$STATE_FILE" 2>/dev/null || echo idle)"; }

row_of() { printf '%s\n' "$MODELS" | awk -F'|' -v id="$1" '$1 == id'; }
field()  { printf '%s' "$1" | cut -d'|' -f"$2"; }

# AVX-512 first because the docs measure it fastest, but only when the CPU has
# it: on this i9-13900H the flag is absent and that build could not run.
onnx_bin() {
    local b
    if [ "$(grep -c -m1 avx512f /proc/cpuinfo 2>/dev/null)" = 1 ]; then
        b=/usr/lib/voxtype/voxtype-onnx-avx512
    else
        b=/usr/lib/voxtype/voxtype-onnx-avx2
    fi
    [ -x "$b" ] && printf '%s' "$b"
}

# The id currently in the config file, whichever engine that is. voxtype's own
# resolver and not a sed: `engine` is absent from a stock config, and the
# resolver is what supplies the default. A model outside the table comes back
# as its bare name, which the menu shows without ticking anything.
current_model() {
    local engine model
    engine=$(voxtype -c "$VOX_CONF" config get engine 2>/dev/null) || engine=whisper
    model=$(voxtype -c "$VOX_CONF" config get "$engine.model" 2>/dev/null) || model=
    # Moonshine's config value (base) is not its download name (moonshine-base),
    # and whisper has a "base" too, so match on engine and value together.
    local id
    id=$(printf '%s\n' "$MODELS" | awk -F'|' -v e="$engine" -v m="$model" '$2 == e && $3 == m { print $1 }')
    printf '%s' "${id:-$model}"
}

# Whether a download is finished is voxtype's answer: an interrupted curl leaves
# a .part, which a test for the file's existence would not catch for ONNX's
# multi-file directories.
installed_ids() {
    voxtype info models --json 2>/dev/null \
        | jq -r '[.engines[].models[] | select(.installed == true) | .download_arg] | join(",")' 2>/dev/null
}

is_installed() {
    case ",$(installed_ids)," in *",$1,"*) return 0 ;; esac
    return 1
}

# A restart would throw away whatever is being dictated.
vox_busy() {
    local s
    s=$(cat "$VOX_STATE" 2>/dev/null) || return 1
    [ -n "$s" ] && [ "$s" != idle ]
}

cmd_status() {
    local busy
    busy=$(cat "$STATE_FILE" 2>/dev/null) || busy=idle
    # A crash mid-download leaves "downloading x" behind. Whoever is really doing
    # that work holds the lock, so a free lock means the file is out of date.
    if [ "$busy" != idle ] && ( flock -n 9 ) 9>"$LOCK_FILE" 2>/dev/null; then
        busy=idle
    fi
    if systemctl --user is-active "$UNIT" >/dev/null 2>&1; then
        printf 'ENABLED="yes"\n'
    else
        printf 'ENABLED="no"\n'
    fi
    printf 'MODEL="%s"\n'     "$(current_model)"
    printf 'INSTALLED="%s"\n' "$(installed_ids)"
    printf 'BUSY="%s"\n'      "$busy"
}

cmd_on() {
    if ! systemctl --user enable --now "$UNIT" >/dev/null 2>&1; then
        note "Could not start voice typing"; poke; exit 1
    fi
    poke
}

cmd_off() {
    # The daemon deletes its state file on a clean exit, and the bar's FileView
    # keeps the last thing it read when that happens (measured: throwaway daemon,
    # SIGTERM, state gone). Stopping mid-recording would leave the indicator
    # showing a recording that no longer exists, so end the recording first.
    if vox_busy; then
        voxtype record cancel >/dev/null 2>&1
        local i
        for i in 1 2 3 4 5 6 7 8 9 10; do vox_busy || break; sleep 0.2; done
    fi
    if ! systemctl --user disable --now "$UNIT" >/dev/null 2>&1; then
        note "Could not stop voice typing"; poke; exit 1
    fi
    poke
}

# Writes the config and the drop-in, nothing else. Also the way back when a new
# model will not start, so it takes no decisions about restarting.
write_engine() {
    local engine=$1 value=$2 bin=$3
    # `config set` edits in place and keeps the file's comments. For whisper the
    # ordinary binary would do, but the ONNX one takes every key, and it is the
    # only one that takes the moonshine and parakeet keys.
    local setter=$bin
    [ -n "$setter" ] || setter=$(onnx_bin)
    [ -n "$setter" ] || setter=voxtype
    "$setter" -c "$VOX_CONF" config set engine "$engine" >/dev/null 2>&1 || return 1
    "$setter" -c "$VOX_CONF" config set "$engine.model" "$value" >/dev/null 2>&1 || return 1
    if [ "$engine" != whisper ]; then
        "$setter" -c "$VOX_CONF" config set "$engine.on_demand_loading" true >/dev/null 2>&1 || return 1
    fi
    if [ "$engine" = whisper ]; then
        rm -f "$ENGINE_DROPIN"
    else
        mkdir -p "$DROPIN_DIR" || return 1
        cat >"$ENGINE_DROPIN" <<EOF || return 1
# Written by scripts/voice-typing.sh (Settings -> Tools -> Voice typing): the
# chosen model's engine exists only in the ONNX build. Removed again when a
# whisper model is chosen, which leaves vulkan.conf in force. zz- so that it
# sorts after vulkan.conf; systemd applies drop-ins in name order.
[Service]
ExecStart=
ExecStart=$bin -q daemon
EOF
    fi
    return 0
}

restart_if_on() {
    systemctl --user daemon-reload >/dev/null 2>&1
    # Off stays off: picking a model is not asking for dictation to start.
    [ "$1" = yes ] || return 0
    systemctl --user restart "$UNIT" >/dev/null 2>&1 || return 1
    # restart returns once the process is spawned, and a bad config exits a
    # moment later, so look again rather than trust that.
    sleep 1
    systemctl --user is-active "$UNIT" >/dev/null 2>&1
}

cmd_set_model() {
    local id=${1:-}
    local row engine value label
    row=$(row_of "$id")
    [ -n "$row" ] || { echo "voice-typing: unknown model: $id" >&2; exit 2; }
    engine=$(field "$row" 2); value=$(field "$row" 3); label=$(field "$row" 4)

    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        note "Still working" "Wait for the current model change to finish."
        exit 0
    fi

    [ "$(current_model)" = "$id" ] && { publish idle; exit 0; }

    local bin=
    if [ "$engine" != whisper ]; then
        bin=$(onnx_bin)
        [ -n "$bin" ] || die "This voxtype has no ONNX build, so $label cannot run"
    fi

    # Checked now AND after the download: that can take minutes, and dictating
    # again in the meantime is exactly what somebody waiting for it would do.
    vox_busy && die "Finish dictating first, then pick $label again"

    if ! is_installed "$id"; then
        publish "downloading $id"
        note "Downloading $label" "It becomes the default when the download finishes."
        # --activate left off: this script does the selecting, once, afterwards.
        if ! "${bin:-voxtype}" setup --download --model "$id" --no-post-install --quiet </dev/null >/dev/null 2>&1 \
           || ! is_installed "$id"; then
            die "Could not download $label. The default has not changed."
        fi
    fi

    vox_busy && die "$label is downloaded. Finish dictating, then pick it again."

    publish "switching $id"
    local was_on=no previous_row previous_id
    systemctl --user is-active "$UNIT" >/dev/null 2>&1 && was_on=yes
    previous_id=$(current_model)
    previous_row=$(row_of "$previous_id")

    write_engine "$engine" "$value" "$bin" || die "Could not write the voxtype config"

    if restart_if_on "$was_on"; then
        publish idle
        note "$label is now the default"
        return 0
    fi

    # Dictation being dead is worse than the old model, so go back if we can.
    if [ -n "$previous_row" ]; then
        local pe pv pb=
        pe=$(field "$previous_row" 2); pv=$(field "$previous_row" 3)
        [ "$pe" = whisper ] || pb=$(onnx_bin)
        write_engine "$pe" "$pv" "$pb" && restart_if_on "$was_on"
    fi
    die "$label would not start, so voice typing stayed on the previous model"
}

case "${1:-}" in
    status)    cmd_status ;;
    on)        cmd_on ;;
    off)       cmd_off ;;
    set-model) shift; cmd_set_model "${1:-}" ;;
    *)         echo "usage: voice-typing.sh status | on | off | set-model <id>" >&2; exit 2 ;;
esac
