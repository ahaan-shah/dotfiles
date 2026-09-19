#!/usr/bin/env bash
# screenrecord.sh  {start|stop|toggle} [--target=full|region|window] [--audio=none|desktop|both]
#
# Screen recording, via gpu-screen-recorder.  Bound to SUPER+Print (toggle) and
# reachable from Settings -> Tools -> Capture -> Screenrecord, which is where
# the target and the soundtrack are actually chosen; the keybind takes the
# defaults below.
#
# ── Why gpu-screen-recorder and not wf-recorder / wl-screenrec ────────────
# Two reasons, and the second one is the one that actually decided it.
#
# Capture path: both alternatives go through wlr-screencopy, which is a full
# framebuffer readback per frame.  This panel is 2880x1620 at 120Hz -- at 4
# bytes a pixel that is 2.2 GB/s off the GPU before anything is encoded.  gsr's
# kms backend reads the scanout plane directly and never makes that copy.
#
# Audio: the menu offers "video + audio + mic", and NEITHER alternative can do
# it.  wl-screenrec has no audio at all; wf-recorder takes one -a device, so
# desktop+mic means hand-building a PipeWire combined sink and tearing it down
# afterwards.  gsr takes  -a "default_output|default_input"  and merges them
# into one track.  See the MERGED comment in build_audio_args below for why one
# track and not two.
#
# ── The encoder, measured on this machine ────────────────────────────────
# `vainfo` on the Iris Xe (Raptor Lake-P, 0000:00:02.0 -- the iGPU that owns
# the internal panel; the RTX 3050 never renders this desktop) reports
# VAEntrypointEncSlice for H264 Main/High/ConstrainedBaseline and HEVC
# Main/Main10.  It does NOT report AV1: AV1 encode arrived with Arc and Meteor
# Lake, and Raptor Lake-P is neither.  So `-k h264` is a hardware path here and
# `-k av1` would silently fall back to the CPU, which at this resolution is the
# whole reason for using gsr in the first place.
#
# h264 over hevc deliberately, though hevc is also hardware here and about a
# third smaller: GitHub will not play HEVC, and the README preview video is the
# main thing these recordings get used for.
#
# ── 60fps on a 120Hz panel ───────────────────────────────────────────────
# Deliberate.  120fps at 2880x1620 roughly doubles the bitrate for something no
# player and no browser is going to show at 120.  It is also already the case
# that a 60fps recording at this resolution passes GitHub's 10 MB attachment
# limit in about eight seconds, so the README video needs an ffmpeg downscale
# regardless -- doubling the source framerate only makes that pass slower.
set -u

RECORDER=gpu-screen-recorder

# ── State, and why it is written the way it is ───────────────────────────
# The bar's indicator (Bar.qml, the `srec` block) watches this file with one
# inotify watch and never re-arms it.  That is copied from the voxtype
# indicator beside it, and it carries voxtype's constraint with it: the watch
# follows the INODE, so this file must be rewritten IN PLACE on every
# transition.  The usual write-a-temp-and-mv is exactly wrong -- mv swaps in a
# new inode, the watch stays pointed at the unlinked old one, and the indicator
# goes deaf after the first idle -> recording -> idle cycle.  `printf >` on the
# existing path truncates and rewrites, which is what is wanted.
#
# In the per-user runtime dir, which is 0700.  STATE_FILE holds a path that is
# read back on stop and handed to ffmpeg and mv, so a fixed name in
# world-writable /tmp is a name any other local account could create first and
# point wherever it liked.
RUNTIME_DIR="${XDG_RUNTIME_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}}/screenrecord"
STATE_FILE="$RUNTIME_DIR/state"          # idle | recording   (the bar reads this)
FILE_FILE="$RUNTIME_DIR/filename"        # path of the recording in flight
START_FILE="$RUNTIME_DIR/started-at"     # epoch seconds, for the bar's timer

OUT_DIR="${SCREENRECORD_DIR:-$HOME/Videos/Screencasts}"

TARGET=full
AUDIO=none
ACTION="${1:-toggle}"
shift 2>/dev/null || true

for arg in "$@"; do
    case "$arg" in
        --target=*) TARGET="${arg#*=}" ;;
        --audio=*)  AUDIO="${arg#*=}"  ;;
        *) printf '%s: unknown option %s\n' "${0##*/}" "$arg" >&2; exit 2 ;;
    esac
done

case "$TARGET" in full|region|window) ;; *)
    printf '%s: --target must be full, region or window\n' "${0##*/}" >&2; exit 2 ;; esac
case "$AUDIO" in none|desktop|both) ;; *)
    printf '%s: --audio must be none, desktop or both\n' "${0##*/}" >&2; exit 2 ;; esac

note() { notify-send -a "Screen recording" "$@"; }

# ── Is one running? ──────────────────────────────────────────────────────
# `pgrep -f "^..."`, and both halves are the result of a measurement.
#
# NOT `pgrep -x`.  -x matches against the process NAME, which the kernel keeps
# in comm -- and comm is TASK_COMM_LEN, 16 bytes, so 15 characters plus a NUL.
# "gpu-screen-recorder" is 19.  The name on the process is therefore
# "gpu-screen-reco" and -x can never match the real one; pgrep says so out
# loud ("pattern that searches for process name longer than 15 characters will
# result in zero matches") and then returns nothing.
#
# That is not a cosmetic failure.  recording_active() would have answered
# "idle" while a recording was running, so `stop` would exit 0 having done
# nothing and `toggle` would start a SECOND recorder on top of the first --
# two encoders writing two files, and the bar stuck showing the first.
#
# -f matches the full command line, which is not truncated.  Anchoring it to
# ^ is what keeps it safe: this script's own command line is
# `bash .../screenrecord.sh stop`, which does not START with the pattern, so
# the anchored form cannot match the caller.  Verified -- an unanchored
# `pkill -f gpu-screen-recorder` from inside this script would match the
# script itself and kill the calling shell, which is a mistake this repo has
# made before and written down.
RECORDER_PAT="^gpu-screen-recorder"
recording_active() { pgrep -f "$RECORDER_PAT" >/dev/null; }

state_write() {
    mkdir -p "$RUNTIME_DIR" || return 1
    # XDG_STATE_HOME may sit outside a private home; protect the fallback too.
    [ -n "${XDG_RUNTIME_DIR:-}" ] || chmod 700 "$RUNTIME_DIR" 2>/dev/null
    printf '%s' "$1" > "$STATE_FILE"      # in place -- see the note above
}

# The wait-for-the-menu-to-close gate is NOT here. It lives in
# scripts/capture-wait.sh, which the settings menu wraps every capture tool in
# — see that file's header for why it is a poll on `hyprctl layers` and why it
# is a wrapper rather than a function copied into four scripts. The keybind
# path calls this script directly and needs no gate: there is no menu open.

# ── Picking what to record ───────────────────────────────────────────────
# Prints the gsr -w argument, or exits non-zero when the user cancelled.
#
# Full screen resolves to the MONITOR NAME, not to its geometry.  Same kms
# backend either way, but naming the monitor skips the scaling arithmetic
# entirely and gsr captures the panel at its native 2880x1620.  Handing it a
# region instead would mean getting that arithmetic right, and there is no
# reason to take the risk on the one case that does not need it.
focused_monitor() {
    hyprctl monitors -j | jq -r '.[] | select(.focused == true) | .name'
}

# slurp returns LOGICAL coordinates -- 1440x810 on this 2x panel, not 2880x1620.
# gsr wants the region in the compositor's logical space too and scales to
# physical itself, so the numbers pass through untouched.  (grim does NOT work
# this way: it writes physical pixels, which is why ocr-region.sh has to divide
# and this does not.  The two are not interchangeable.)
#
# Rounded to even.  H.264 chroma subsampling needs even dimensions, and an odd
# logical width doubles to an even physical one only while the scale is exactly
# 2 -- which is true today and is not a thing to depend on.
#
# ── No screen freeze under the picker, unlike the screenshot path ────────
# omarchy freezes (hyprpicker -r -z) before every slurp, screenshots and
# recordings alike, and for a SCREENSHOT that is right: the thing being framed
# is the thing being captured, so it must not move between the drag and the
# grab.  A recording is the opposite case.  What is being framed is a region
# that is about to hold several seconds of MOVING content, and freezing it
# means choosing that region against a still of a moment that has already
# passed -- you cannot see the thing you are trying to fit in the box.  So the
# picker here runs over live content deliberately.
select_region() {
    local sel
    sel=$(slurp 2>/dev/null) || return 1
    [ -n "$sel" ] || return 1
    [[ $sel =~ ^(-?[0-9]+),(-?[0-9]+)[[:space:]]([0-9]+)x([0-9]+)$ ]] || return 1
    local x=${BASH_REMATCH[1]} y=${BASH_REMATCH[2]}
    local w=$(( BASH_REMATCH[3] - BASH_REMATCH[3] % 2 ))
    local h=$(( BASH_REMATCH[4] - BASH_REMATCH[4] % 2 ))
    [ "$w" -ge 2 ] && [ "$h" -ge 2 ] || return 1
    printf '%dx%d+%d+%d' "$w" "$h" "$x" "$y"
}

# ── Window capture is a fixed rectangle, and that is a real limitation ───
# gsr's kms backend cannot follow a window: only the xdg-desktop-portal backend
# (-w portal) can capture one as a window, and that path fails EGL DMA-BUF
# modifier import on some configurations and then cannot start recording at all
# -- which is why omarchy, where this approach came from, ships it off by
# default.  Not worth trading "records nothing" for "follows the window".
#
# So this reads the window's rectangle once and records that rectangle.  If the
# window is moved or resized mid-recording, the capture does not follow it; it
# keeps filming the patch of screen the window used to be on.  The notification
# on start says so, because a user who does not know that will only find out
# after the take.
select_window() {
    local sel
    sel=$(hyprctl clients -j | jq -r --arg ws "$(hyprctl monitors -j | jq -r '.[] | select(.focused == true) | .activeWorkspace.id')" \
        '[.[] | select(.workspace.id == ($ws | tonumber) and .hidden != true)
              | "\(.at[0]),\(.at[1]) \(.size[0])x\(.size[1])"] | unique[]' \
        | slurp -r 2>/dev/null) || return 1
    [ -n "$sel" ] || return 1
    [[ $sel =~ ^(-?[0-9]+),(-?[0-9]+)[[:space:]]([0-9]+)x([0-9]+)$ ]] || return 1
    local w=$(( BASH_REMATCH[3] - BASH_REMATCH[3] % 2 ))
    local h=$(( BASH_REMATCH[4] - BASH_REMATCH[4] % 2 ))
    printf '%dx%d+%d+%d' "$w" "$h" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

# ── The soundtrack ───────────────────────────────────────────────────────
# MERGED, with a pipe, into ONE track -- not two -a flags.  Two -a flags give
# gsr two separate audio STREAMS in the mp4, and most players (mpv included,
# and every browser) play the first one and ignore the rest.  A recording made
# with "video + audio + mic" would then play back with the microphone silent
# and look like the mic capture had failed.  The pipe tells gsr to mix them.
build_audio_args() {
    local devices=""
    case "$AUDIO" in
        none)    return 0 ;;
        desktop) devices="default_output" ;;
        both)    devices="default_output|default_input" ;;
    esac
    printf '%s' "$devices"
}

start_recording() {
    if ! command -v "$RECORDER" >/dev/null; then
        note -u critical "gpu-screen-recorder is not installed" \
             "sudo pacman -S gpu-screen-recorder"
        exit 1
    fi

    mkdir -p "$OUT_DIR" || { note -u critical "Cannot create $OUT_DIR"; exit 1; }
    mkdir -p "$RUNTIME_DIR"

    local w_arg
    case "$TARGET" in
        full)   w_arg=$(focused_monitor) ;;
        region) w_arg=$(select_region) || exit 0 ;;   # cancelled: say nothing
        window) w_arg=$(select_window) || exit 0 ;;
    esac
    [ -n "$w_arg" ] || { note -u critical "Nothing to record"; exit 1; }

    local file="$OUT_DIR/recording-$(date +'%Y-%m-%d_%H-%M-%S').mp4"
    local audio_args=()
    local devices
    devices=$(build_audio_args)
    [ -n "$devices" ] && audio_args=(-a "$devices" -ac aac)

    # -fm cfr: constant framerate.  gsr's default is variable, and a VFR mp4 is
    # what makes an otherwise fine recording stutter in browsers and refuse to
    # scrub cleanly in most editors.
    # -fallback-cpu-encoding yes: if VAAPI init fails for any reason, produce a
    # recording anyway rather than exiting.  It will be slow; it will exist.
    "$RECORDER" -w "$w_arg" -k h264 -f 60 -fm cfr -fallback-cpu-encoding yes \
                -o "$file" "${audio_args[@]}" >/dev/null 2>&1 &
    local pid=$!

    # gsr creates the output file once it has actually opened the encoder, so
    # the file appearing is the signal that the recording really started --
    # checking only that the process is alive would call a VAAPI failure a
    # success for the second or so it takes to die.
    local i=0
    while [ "$i" -lt 50 ] && kill -0 "$pid" 2>/dev/null && [ ! -f "$file" ]; do
        sleep 0.1
        i=$((i + 1))
    done

    if ! kill -0 "$pid" 2>/dev/null; then
        note -u critical "Screen recording failed to start" \
             "gpu-screen-recorder exited immediately"
        state_write idle
        exit 1
    fi

    printf '%s' "$file"        > "$FILE_FILE"
    printf '%s' "$(date +%s)"  > "$START_FILE"
    state_write recording

    # No "recording started" notification.  The bar indicator appears in the
    # same moment this returns and says the same thing without covering a
    # corner of the screen you may be about to record.  It is also the only one
    # of the two that is still there ten seconds later, when the question is
    # "am I still recording?" rather than "did it start?".
}

stop_recording() {
    # SIGINT, not SIGTERM: gsr finalises the mp4 container on SIGINT and simply
    # dies on SIGTERM, leaving a file with no moov atom that nothing will play.
    pkill -SIGINT -f "$RECORDER_PAT"

    local i=0
    while pgrep -f "$RECORDER_PAT" >/dev/null && [ "$i" -lt 50 ]; do
        sleep 0.1
        i=$((i + 1))
    done

    state_write idle

    local file
    file=$(cat "$FILE_FILE" 2>/dev/null)
    rm -f "$FILE_FILE" "$START_FILE"

    if pgrep -f "$RECORDER_PAT" >/dev/null; then
        pkill -9 -f "$RECORDER_PAT"
        note -u critical "Screen recording error" \
             "Had to be force-killed after 5s — the video may be unplayable"
        return 1
    fi

    [ -n "$file" ] && [ -f "$file" ] || { note -u critical "Recording not saved"; return 1; }

    finalize "$file"

    # ── No thumbnail, deliberately ───────────────────────────────────────
    # An earlier version pulled a still out of the recording with ffmpeg and
    # passed it as -i.  Ahaan asked for text only, on both this and the
    # screenshot notification, and that removes a whole class of problem
    # rather than just some work: the thumbnail had to be written somewhere,
    # kept alive for as long as any card might re-resolve it, and cleaned up
    # afterwards.  Getting the lifetime wrong is what put Qt's broken-image
    # checkerboard in the toast -- Bar.qml's card is a plain `Image` bound to
    # iconFor(notif) and the same card is reused by the history list, so the
    # source is read again long after the toast appeared.  No image, no
    # lifetime, nothing to clean up.
    #
    # The body is the DURATION and the directory, and it is short because the
    # card wraps and then clips: the first version put the full timestamped
    # basename plus the directory in there and lost the end of it off the
    # bottom of the box.  The duration is also the one fact worth reading --
    # it is what says the take was the one you meant.
    local secs
    secs=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$file" 2>/dev/null)
    secs=${secs%.*}
    local dur="${secs:-0}s"
    [ "${secs:-0}" -ge 60 ] 2>/dev/null && dur="$((secs / 60))m $((secs % 60))s"

    note "Recording saved" "$dur · ~/Videos/Screencasts"
}

# ── The post-pass ────────────────────────────────────────────────────────
# Two fixes, one ffmpeg run, and it only touches what needs touching.
#
# The first frame is dropped.  gsr's first GOP can carry discardable warmup
# packets; a stream copy cannot trim those, because -ss on a copy rewinds to
# the keyframe and brings them back.  So the video is re-encoded ONLY when
# ffprobe actually finds a discardable packet in the first 200ms -- a clean
# recording stays on the fast copy path and finishes in well under a second.
#
# The audio, when there is any, gets the first 400ms hard-muted.  Opening a
# PipeWire capture makes a near-clipping transient around 130-200ms in, and it
# is loud enough that a fade-in cannot attenuate it; it has to be zeroed.  The
# 50ms fade after it is there so the step back to full gain is not itself a
# click.  loudnorm then brings the rest to -14 LUFS, which is roughly what
# every platform normalises to anyway.
finalize() {
    local file="$1"
    [ -f "$file" ] || return

    local vcodec=(-c:v copy)
    if [ "$(ffprobe -v error -select_streams v:0 -read_intervals %+0.2 \
                    -show_entries packet=flags -of csv=p=0 "$file" 2>/dev/null \
            | grep -c D)" -gt 0 ]; then
        vcodec=(-c:v libx264 -preset veryfast -crf 20)
    fi

    # +faststart moves the moov atom to the FRONT of the file.  gsr writes it
    # at the end, which is correct for a recorder (the index is not known until
    # the recording stops) but means a player has to seek to the end of the
    # file before it can start.  Locally that costs one seek and is invisible;
    # over HTTP it means a browser downloads the whole file before the first
    # frame, which is exactly what these recordings are for -- the README
    # preview video is served by GitHub.  Verified on a recording here: ftyp,
    # mdat, then moov at the very end.
    #
    # (It is NOT the reason mpv feels slow to open one.  Measured: mpv reaches
    # the first frame of a full 2880x1620 recording in 0.32s, and its window
    # takes ~1.1s to map for ANY file -- a 1280x720 clip measured slightly
    # slower than the big recording.  That is mpv's own startup, not the
    # container.)
    local args=(-y -ss 0.1 -i "$file" "${vcodec[@]}" -movflags +faststart)
    if [ "$(ffprobe -v error -select_streams a -show_entries stream=codec_type \
                    -of csv=p=0 "$file" 2>/dev/null | grep -c audio)" -gt 0 ]; then
        args+=(-af "volume=enable='lt(t,0.4)':volume=0,afade=t=in:st=0.4:d=0.05,loudnorm=I=-14:TP=-1.5:LRA=11")
    fi

    local tmp="${file%.mp4}-processed.mp4"
    if ffmpeg "${args[@]}" "$tmp" -loglevel quiet 2>/dev/null; then
        mv "$tmp" "$file"
    else
        # The unprocessed recording is a real recording.  A failed post-pass
        # must not cost the user the take.
        rm -f "$tmp"
    fi
}

case "$ACTION" in
    start)  recording_active && exit 0; start_recording ;;
    stop)   recording_active || exit 0; stop_recording  ;;
    toggle) if recording_active; then stop_recording; else start_recording; fi ;;
    status) recording_active && echo recording || echo idle ;;
    *) printf 'usage: %s {start|stop|toggle|status} [--target=full|region|window] [--audio=none|desktop|both]\n' \
              "${0##*/}" >&2; exit 2 ;;
esac
