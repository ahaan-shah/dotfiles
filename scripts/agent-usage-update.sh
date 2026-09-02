#!/usr/bin/env bash
# agent-usage-update.sh [--force] [--limits-only] [agent...]
#
# Regenerates the AI-agent usage records the taskbar's agent panel reads.
#
# THE CONTRACT, because this is the whole extension point:
#
#   Every executable sibling named `agent-usage-<id>` is a collector. It prints
#   ONE display-ready JSON record on stdout and exits 0. This script writes that
#   record to  $XDG_STATE_HOME/hyprahaan/agents/usage/<id>.json  and the panel
#   draws whatever appears in that directory.
#
# So adding an agent never touches shell.qml: drop in `agent-usage-codex`, and
# the panel gains a tab at the next refresh. That is the "autodetect" — the set
# of agents is the set of collectors that produced a record, not a hard-coded
# list. Only `claude` ships here because it is the only agent on this machine;
# the record shape is documented in the panel's comment block in shell.qml, and
# omarchy's codex/fireworks collectors are drop-in if anyone wants them.
#
# A collector is expected to be cheap and to cache its own expensive work — it
# runs on the panel's refresh timer. --force asks collectors to bypass those
# caches, --limits-only asks for a fresh rate-limit probe over a reused scan.
set -u

SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
USAGE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/hyprahaan/agents/usage"
mkdir -p "$USAGE_DIR" || exit 1

flags=()
only=()
for arg in "$@"; do
  case "$arg" in
  --force | --limits-only) flags+=("$arg") ;;
  -*) ;;                                     # ignore unknown flags rather than pass them on
  *) only+=("$arg") ;;
  esac
done

wanted() {
  (( ${#only[@]} == 0 )) && return 0
  local candidate
  for candidate in "${only[@]}"; do
    [[ $candidate == "$1" ]] && return 0
  done
  return 1
}

collect() {
  local collector=$1 agent=$2 record tmp
  # A collector that fails, prints nothing, or prints something that is not
  # JSON leaves the PREVIOUS record in place. A momentary failure (no network,
  # a half-written transcript) should not blank the panel — the record carries
  # its own updatedAt, so stale data is visibly stale rather than absent.
  record=$("$collector" "${flags[@]}" 2>/dev/null) || return 1
  [[ -n $record ]] || return 1
  jq -e . >/dev/null 2>&1 <<<"$record" || return 1

  # mktemp inside the target dir so the mv is a same-filesystem rename, i.e.
  # atomic: the panel's FileView watch never sees a half-written record.
  tmp=$(mktemp "$USAGE_DIR/.$agent.XXXXXX") || return 1
  printf '%s\n' "$record" >"$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$USAGE_DIR/$agent.json" && return 0
  rm -f "$tmp"
  return 1
}

# Collectors run concurrently: each one is dominated by its own network probe,
# and one slow agent must not hold up the others' records.
pids=()
for collector in "$SELF_DIR"/agent-usage-*; do
  [[ -x $collector ]] || continue
  [[ ${collector##*/} == "${BASH_SOURCE[0]##*/}" ]] && continue   # this script
  # A collector may or may not carry an extension, and the extension is not
  # part of the agent id: agent-usage-codex and agent-usage-codex.py both
  # write codex.json. Strip one trailing extension, never more, so an id with
  # a dot in it survives.
  agent=${collector##*/agent-usage-}
  agent=${agent%.[!.]*}
  [[ -n $agent ]] || continue
  wanted "$agent" || continue
  collect "$collector" "$agent" &
  pids+=($!)
done

status=0
for pid in "${pids[@]}"; do
  wait "$pid" || status=1
done
exit $status
