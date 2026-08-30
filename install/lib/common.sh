#!/usr/bin/env bash
# common.sh — logging, dry-run plumbing, prompts and safe file placement.
# Sourced by install.sh; not executable on its own.

# ── Colours (disabled when not a tty, so logs stay greppable) ─────────────
if [ -t 1 ]; then
    C_RST=$'\033[0m'; C_B=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YLW=$'\033[33m'; C_BLU=$'\033[34m'
else
    C_RST=; C_B=; C_DIM=; C_RED=; C_GRN=; C_YLW=; C_BLU=
fi

LOGFILE="${LOGFILE:-/tmp/hyprahaan-install.log}"

_ts() { date '+%F %T'; }
_log_raw() { printf '%s  %s\n' "$(_ts)" "$*" >>"$LOGFILE" 2>/dev/null || true; }

# ── Phase banner with a running counter and per-phase timing ──────────────
# The counter comes from ALL_PHASES so it stays right when phases are skipped.
PHASE_N=0
PHASE_START=0
PHASE_LAST=""
RUN_START=$(date +%s)

_fmt_secs() {
    local t=$1
    if [ "$t" -lt 60 ]; then printf '%ds' "$t"
    else printf '%dm%02ds' $((t/60)) $((t%60)); fi
}

# Close out the previous phase with its elapsed time.
phase_close() {
    [ "$PHASE_START" = 0 ] && return 0
    local el=$(( $(date +%s) - PHASE_START ))
    # Silent for instant phases; a wall of "finished in 0s" is noise, but on a
    # real install the package and AUR phases take minutes and the timing helps.
    [ "$el" -ge 2 ] && printf '  %s└ %s finished in %s%s\n' \
        "$C_DIM" "$PHASE_LAST" "$(_fmt_secs "$el")" "$C_RST"
    _log_raw "PHASE END $PHASE_LAST ${el}s"
    PHASE_START=0
}

phase() {
    phase_close
    PHASE_N=$((PHASE_N+1))
    PHASE_START=$(date +%s)
    PHASE_LAST="$*"
    local total; total=$(printf '%s' "$ALL_PHASES" | wc -w)
    printf '\n%s══ [%d/%d] %s ══%s\n' "$C_B$C_BLU" "$PHASE_N" "$total" "$*" "$C_RST"
    _log_raw "PHASE $*"
}

total_elapsed() { _fmt_secs $(( $(date +%s) - RUN_START )); }

# ── sudo, asked for once and kept warm ────────────────────────────────────
# The alternative is a password prompt appearing in the middle of a long pacman
# run, which is both surprising and easy to miss.
SUDO_KEEPALIVE_PID=""
sudo_prime() {
    [ "$DRY_RUN" = 1 ] && return 0
    [ "$NO_ROOT" = 1 ] && return 0
    [ -n "$SUDO_KEEPALIVE_PID" ] && return 0
    printf '\n  %sThis installer needs sudo for packages and system files.%s\n' "$C_B" "$C_RST"
    printf '  %sIt is asked for once, here, and kept alive for the rest of the run.%s\n' "$C_DIM" "$C_RST"
    sudo -v || die "sudo authentication failed"
    ( while true; do sudo -n true 2>/dev/null || exit; command sleep 50; done ) &
    SUDO_KEEPALIVE_PID=$!
    _log_raw "sudo primed, keepalive pid $SUDO_KEEPALIVE_PID"
}
sudo_release() {
    [ -n "$SUDO_KEEPALIVE_PID" ] || return 0
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    SUDO_KEEPALIVE_PID=""
}
trap 'sudo_release' EXIT
info()   { printf '  %s\n' "$*"; _log_raw "INFO  $*"; }
ok()     { printf '  %s✓%s %s\n' "$C_GRN" "$C_RST" "$*"; _log_raw "OK    $*"; }
warn()   { printf '  %s!%s %s\n' "$C_YLW" "$C_RST" "$*"; _log_raw "WARN  $*"; }
err()    { printf '  %s✗%s %s\n' "$C_RED" "$C_RST" "$*" >&2; _log_raw "ERR   $*"; }
skip()   { printf '  %s·%s %s\n' "$C_DIM" "$C_RST" "$*"; _log_raw "SKIP  $*"; }
die()    { err "$*"; printf '\n%sInstall aborted.%s Log: %s\n' "$C_RED" "$C_RST" "$LOGFILE" >&2; exit 1; }

# ── Dry run ───────────────────────────────────────────────────────────────
# run  — a command with side effects. Printed but not executed under --dry-run.
run() {
    if [ "$DRY_RUN" = 1 ]; then
        printf '  %sDRY%s %s\n' "$C_DIM" "$C_RST" "$*"
        _log_raw "DRY   $*"
        return 0
    fi
    _log_raw "RUN   $*"
    "$@"
}

# run_sh — same, for a string that genuinely needs a shell (pipes, redirects).
run_sh() {
    if [ "$DRY_RUN" = 1 ]; then
        printf '  %sDRY%s sh -c %s\n' "$C_DIM" "$C_RST" "$1"
        _log_raw "DRY   sh -c $1"
        return 0
    fi
    _log_raw "RUN   sh -c $1"
    bash -c "$1"
}

# ── Prompts ───────────────────────────────────────────────────────────────
# ask_yn <question> <default y|n>  — honours --yes (takes the default).
ask_yn() {
    local q="$1" def="${2:-n}" ans prompt
    [ "$def" = y ] && prompt="[Y/n]" || prompt="[y/N]"
    if [ "$ASSUME_YES" = 1 ]; then
        _log_raw "ASK   $q -> $def (--yes)"
        printf '  %s %s %s(auto: %s)%s\n' "$q" "$prompt" "$C_DIM" "$def" "$C_RST"
        [ "$def" = y ]; return
    fi
    while true; do
        printf '  %s%s%s %s ' "$C_B" "$q" "$C_RST" "$prompt"
        read -r ans </dev/tty || ans=""
        ans="${ans:-$def}"
        case "${ans,,}" in
            y|yes) _log_raw "ASK   $q -> y"; return 0 ;;
            n|no)  _log_raw "ASK   $q -> n"; return 1 ;;
            *) printf '    please answer y or n\n' ;;
        esac
    done
}

# ask_val <question> <default>  — echoes the answer on stdout.
ask_val() {
    local q="$1" def="$2" ans
    if [ "$ASSUME_YES" = 1 ]; then echo "$def"; return; fi
    printf '  %s%s%s [%s] ' "$C_B" "$q" "$C_RST" "$def" >&2
    read -r ans </dev/tty || ans=""
    echo "${ans:-$def}"
}

# ── File placement ────────────────────────────────────────────────────────
BACKUP_STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_ROOT=""   # set lazily on first backup

# backup_path <path> — move an existing path aside, once, before overwriting.
backup_path() {
    local p="$1"
    [ -e "$p" ] || return 0
    if [ -z "$BACKUP_ROOT" ]; then
        BACKUP_ROOT="$HOME/.config-backup-$BACKUP_STAMP"
        run mkdir -p "$BACKUP_ROOT"
        info "existing files are being backed up to $BACKUP_ROOT"
    fi
    local rel="${p#"$HOME"/}"
    rel="${rel//\//_}"
    run cp -a "$p" "$BACKUP_ROOT/$rel"
}

# deploy_dir <src> <dst> [extra rsync args...] — mirror a config directory.
# Uses rsync WITHOUT --delete: an install must never eat files it does not own.
# That also means a file the repo has stopped shipping (e.g. the generated
# colors-hyprland.lua, which lives as a symlink into the wal cache) is left
# alone rather than clobbered.
deploy_dir() {
    local src="$1" dst="$2"; shift 2
    if [ ! -d "$src" ]; then
        skip "$(basename "$dst"): not present in this checkout"
        return 1
    fi
    backup_path "$dst"
    run mkdir -p "$dst"
    run rsync -a --exclude '.git' "$@" "$src"/ "$dst"/
    ok "$(basename "$dst") -> $dst"
}

# deploy_file <src> <dst> [mode]
deploy_file() {
    local src="$1" dst="$2" mode="${3:-644}"
    [ -f "$src" ] || { skip "$(basename "$src"): not present"; return 1; }
    backup_path "$dst"
    run mkdir -p "$(dirname "$dst")"
    run install -m "$mode" "$src" "$dst"
    ok "$(basename "$dst")"
}

# sudo_file <src> <dst> [mode] — root-owned system file.
sudo_file() {
    local src="$1" dst="$2" mode="${3:-644}"
    [ -f "$src" ] || { skip "$(basename "$src"): not present"; return 1; }
    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
        skip "$dst already current"
        return 0
    fi
    [ -f "$dst" ] && run sudo cp -a "$dst" "$dst.bak-$BACKUP_STAMP"
    run sudo install -D -m "$mode" "$src" "$dst"
    ok "$dst"
}

have() { command -v "$1" >/dev/null 2>&1; }
