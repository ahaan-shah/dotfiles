#!/usr/bin/env bash
# machine-mark.sh — what the About sigil draws, as one JSON object on stdout.
#
#   machine-mark.sh        everything (once, when About opens)
#   machine-mark.sh live   memory, uptime, battery, dGPU power state (every 4 s
#                          while About is open — /proc and sysfs only)
#
# Read-only, apart from one cache file (below). Shape and idea from
# github.com/erikrjohansson/omarchy-machine-mark (MIT); the Omarchy reads
# (omarchy-version, theme folders, plugin list) are replaced by this desktop's
# own: scripts/palettes, the wallpaper record, the battery,
# and the P/E core split.
#
# ── The GPU core count costs a dGPU wake ─────────────────────────────────
# fastfetch's plain GPU module reads names and drivers from sysfs and leaves
# the RTX 3050 in D3cold (measured: 30/30 samples `suspended`). Its
# `driverSpecific` mode is what yields a core count, and it gets there through
# NVML — measured 2026-10-21: suspended -> resuming -> active within 0.4 s.
# Upstream polls exactly that every 4 s while its window is open, which on this
# laptop would hold the dGPU awake for as long as About is on screen.
#
# Core counts are hardware constants, so they are read ONCE, only at a moment
# the read is free — the dGPU already active (someone else woke it), or no
# dGPU at all — and cached. Until that moment the GPU ring draws one dot per
# GPU and says why. Nothing here ever wakes the card.
set -uo pipefail

log=/var/log/pacman.log
cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/hyprahaan"
gpu_cache="$cache_dir/machine-mark-gpu.json"
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# ~/.config/scripts when deployed, the repo's scripts/ when run from there;
# either way palettes/ sits beside this file.
pal_dir="$here/palettes"
wall_state="${XDG_STATE_HOME:-$HOME/.local/state}/hyprahaan/wallpaper"
wall_dir="${WALLPAPER_DIR:-$HOME/Pictures/wallpapers}"

for tool in fastfetch jq gawk; do
    command -v "$tool" >/dev/null || { echo "$tool is not installed" >&2; exit 2; }
done

# The discrete GPU's runtime power state, by class rather than by a pinned
# address (nothing machine-specific in here): the first display-class PCI
# device that is not the boot VGA. "none" when there is no second GPU.
dgpu_state() {
    local d
    for d in /sys/bus/pci/devices/*; do
        [[ $(<"$d/class") == 0x03* ]] || continue
        [[ -r $d/boot_vga && $(<"$d/boot_vga") == 1 ]] && continue
        cat "$d/power/runtime_status" 2>/dev/null || echo unknown
        return
    done
    echo none
}

battery() {
    local b
    for b in /sys/class/power_supply/*; do
        [[ $(<"$b/type") == Battery ]] || continue
        # charge_* on this ASUS, energy_* on most others: same ratio either way.
        local full design now
        full=$(cat "$b/charge_full" 2>/dev/null || cat "$b/energy_full" 2>/dev/null || echo 0)
        design=$(cat "$b/charge_full_design" 2>/dev/null || cat "$b/energy_full_design" 2>/dev/null || echo 0)
        now=$(cat "$b/capacity" 2>/dev/null || echo 0)
        jq -cn --argjson cap "$now" --argjson full "$full" --argjson design "$design" \
            --argjson cycles "$(cat "$b/cycle_count" 2>/dev/null || echo 0)" \
            --argjson limit "$(cat "$b/charge_control_end_threshold" 2>/dev/null || echo 100)" \
            --arg status "$(cat "$b/status" 2>/dev/null)" \
            '{ capacity: $cap, health: (if $design > 0 then $full / $design else null end),
               cycles: $cycles, limit: $limit, status: $status }'
        return
    done
    echo null
}

memory() {
    awk '/^MemTotal:/ { t = $2 } /^MemAvailable:/ { a = $2 }
         END { printf "{\"total\":%d,\"used\":%d}", t * 1024, (t - a) * 1024 }' /proc/meminfo
}

if [[ ${1:-} == live ]]; then
    read -r up _ </proc/uptime
    jq -cn --argjson mem "$(memory)" --argjson bat "$(battery)" --arg dgpu "$(dgpu_state)" \
        --argjson up "${up%.*}" --argjson now "$(date +%s)" \
        '{ memory: $mem, battery: $bat, dgpu: $dgpu, uptime: $up, now: $now }'
    exit 0
fi

ff=$(timeout -k 1 5 fastfetch --format json -c "$here/machine-mark.jsonc" 2>/dev/null)
jq -e 'type == "array" and length > 0' <<<"$ff" >/dev/null 2>&1 \
    || { echo "fastfetch gave no readings" >&2; exit 3; }

# ── GPU core counts: the cache, refreshed only when it is free ────────────
state=$(dgpu_state)
if [[ ! -s $gpu_cache && ( $state == active || $state == none ) ]]; then
    counts=$(timeout -k 1 5 fastfetch --format json -c "$here/machine-mark-gpu.jsonc" 2>/dev/null |
        jq -c '[.[0].result[] | { name, cores: .coreCount, vram: .memory.dedicated.total }]' 2>/dev/null)
    if [[ -n $counts && $counts != "[]" ]]; then
        mkdir -p "$cache_dir" && printf '%s\n' "$counts" >"$gpu_cache"
    fi
fi
gpucounts=$(cat "$gpu_cache" 2>/dev/null || echo '[]')
jq -e 'type == "array"' <<<"$gpucounts" >/dev/null 2>&1 || gpucounts='[]'

# ── P/E cores ─────────────────────────────────────────────────────────────
# Intel hybrid parts list their efficient CPUs in /sys/devices/cpu_atom/cpus.
# A physical core is one distinct core_cpus_list; counting those that start
# inside the atom range gives E, the rest P. Absent on every non-hybrid CPU,
# where this prints null and the ring draws plain cores.
split=null
if [[ -r /sys/devices/cpu_atom/cpus ]]; then
    split=$(gawk -v atom="$(</sys/devices/cpu_atom/cpus)" '
        BEGIN { n = split(atom, parts, ","); for (i = 1; i <= n; i++) {
                  m = split(parts[i], ab, "-"); for (c = ab[1]; c <= (m > 1 ? ab[2] : ab[1]); c++) isE[c] = 1 } }
        { if (seen[$0]++) next; split($0, first, /[-,]/); if (first[1] in isE) e++; else p++ }
        END { printf "{\"p\":%d,\"e\":%d}", p, e }' \
        /sys/devices/system/cpu/cpu[0-9]*/topology/core_cpus_list 2>/dev/null) || split=null
    [[ -n $split ]] || split=null
fi

# ── pacman: upgrades, last upgrade, per-week counts, package sizes ───────
upgrades=0 last_upgrade=0
if [[ -r $log ]]; then
    # Captured, never `| grep -q` (CLAUDE.md: pipefail has bitten this repo).
    upgraded=$(grep '\[ALPM\] upgraded' "$log")
    upgrades=$(grep -c . <<<"$upgraded")
    stamp=$(tail -1 <<<"$upgraded" | sed -E 's/^\[([^]]+)\].*/\1/')
    [[ -n $stamp ]] && last_upgrade=$(date -d "$stamp" +%s 2>/dev/null || echo 0)
fi

# The root filesystem's birth time, the nearest thing to an install date.
installed=$(stat -c %W / 2>/dev/null || echo 0)
[[ $installed =~ ^[0-9]+$ ]] || installed=0

weekly=null
if [[ -n ${upgraded:-} ]] && (( installed > 0 )); then
    weekly=$(gawk -v inst="$installed" -v now="$(date +%s)" '
        match($0, /^\[([0-9]{4})-([0-9]{2})-([0-9]{2})[T ]([0-9]{2}):([0-9]{2})/, a) {
            w = int((mktime(a[1] " " a[2] " " a[3] " " a[4] " " a[5] " 0") - inst) / 604800); if (w >= 0) c[w]++ }
        END { n = int((now - inst) / 604800); if (n > 2600) n = 2600
              printf "["; for (i = 0; i <= n; i++) printf "%s%d", (i ? "," : ""), c[i] + 0; print "]" }' \
        <<<"$upgraded" 2>/dev/null)
    [[ -n $weekly ]] || weekly=null
fi

# Each package's installed size in KiB, in last-install order.
sizes=$(shopt -s nullglob; files=(/var/lib/pacman/local/*/desc)
    (( ${#files[@]} )) && gawk '/^%INSTALLDATE%$/ { getline; d = $0 } /^%SIZE%$/ { getline; s = $0 }
        ENDFILE { print d + 0 "\t" s + 0; d = 0; s = 0 }' "${files[@]}" 2>/dev/null |
    sort -s -n -k1,1 | cut -f2 | jq -sc 'map(. / 1024 | floor)' 2>/dev/null)
[[ -n $sizes ]] || sizes=null

# ── this desktop's look: palette, palettes, wallpapers ───────────────────
pal_current=$("$here/palette.sh" current 2>/dev/null || true)
palettes=$(shopt -s nullglob; for f in "$pal_dir"/*.json; do f=${f##*/}; echo "${f%.json}"; done |
    { cat; echo pywal; } | sort -u |
    jq -Rsc --arg cur "$pal_current" '[split("\n")[] | select(length > 0)] as $n
        | { count: ($n | length), current: ($n | index($cur)) }')
wall_cur=$(head -1 "$wall_state" 2>/dev/null || true)
walls=$(find "$wall_dir" -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' \) \
        -not -path '*/.*' 2>/dev/null | sort |
    jq -Rsc --arg cur "$wall_cur" '[split("\n")[] | select(length > 0)] as $n
        | { count: ($n | length), current: ($n | index($cur)),
            name: ($cur | split("/") | last | sub("\\.[^.]+$"; "")) }')

host=$(hostnamectl hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || uname -n)
read -r up _ </proc/uptime

clean='def clean: gsub("\\((R|TM|tm)\\)"; "") | gsub("^(AMD|Intel|NVIDIA) "; "") | gsub(" (with|w/) .*$"; "")
             | gsub(" [0-9]+-Core Processor$"; "") | gsub("^[0-9]+th Gen "; "") | gsub("Core i"; "i")
             | gsub("  +"; " ") | ltrimstr(" ") | rtrimstr(" ");'

jq -n --argjson ff "$ff" --argjson counts "$gpucounts" --arg dgpu "$state" \
    --arg host "$host" --argjson split "$split" \
    --argjson upgrades "${upgrades:-0}" --argjson lastUpgrade "${last_upgrade:-0}" \
    --argjson installed "$installed" --argjson now "$(date +%s)" --argjson uptime "${up%.*}" \
    --argjson weekly "$weekly" --argjson sizes "$sizes" \
    --argjson palettes "$palettes" --arg palette "$pal_current" \
    --argjson walls "$walls" --argjson mem "$(memory)" --argjson bat "$(battery)" "$clean"'
    def mod($t): try ($ff | map(select(type == "object" and .type == $t)) | first | .result) catch null;
    def num: if type == "number" then . else null end;
    def obj: if type == "object" then . else {} end;
    (mod("CPU") | obj) as $cpu | (mod("Kernel") | obj) as $kernel | (mod("WM") | obj) as $wm
    | (mod("Packages") | obj) as $pkg | (mod("OS") | obj) as $os
    | ((try (mod("Disk") | map(select(.mountpoint == "/")) | first) catch null) | obj) as $disk
    | ((try (mod("Display") | sort_by(-(.output.width * .output.height), -(.output.refreshRate // 0)) | first) catch null) | obj) as $dsp
    | {
        host: $host, os: ($os.prettyName // "Linux"), kernel: ($kernel.release // ""),
        wm: { name: ($wm.prettyName // ""), version: ($wm.version // "") },
        cpu: { name: (($cpu.cpu // "") | clean), cores: ($cpu.cores.physical? | num),
               threads: ($cpu.cores.logical? | num), mhz: (($cpu.frequency.max? // $cpu.frequency.base?) | num),
               split: $split },
        # Every GPU, integrated first (it draws the desktop), each with the
        # cached core count matched by name.
        gpus: [ (mod("GPU") // [])[] | select(type == "object")
                | . as $g | ($counts | map(select(.name | endswith($g.name))) | first // {}) as $c
                | { name: (.name | clean), type: (.type // ""),
                    driver: ((.driver // "") | split(" ") | first),
                    cores: ($c.cores | num), vram: ($c.vram | num) } ]
              | sort_by(.type != "Integrated"),
        dgpu: $dgpu,
        memory: $mem,
        disk: { total: ($disk.bytes.total? | num), fs: ($disk.filesystem // ""),
                used: (($disk.bytes.used? | num) // ((($disk.bytes.total? | num) // null) as $t
                       | (($disk.bytes.free? | num) // null) as $f | if $t and $f then $t - $f else null end)) },
        display: { width: ($dsp.output.width? | num), height: ($dsp.output.height? | num),
                   hz: ($dsp.output.refreshRate? | num),
                   inches: (($dsp.physical.width? | num) as $w | ($dsp.physical.height? | num) as $h
                            | if ($w // 0) > 0 and ($h // 0) > 0 then (($w * $w + $h * $h) | sqrt / 25.4) else null end) },
        battery: $bat,
        packages: { pacman: ($pkg.pacman | num), flatpak: ((($pkg.flatpakSystem // 0) + ($pkg.flatpakUser // 0)) | num),
                    sizes: $sizes },
        upgrades: $upgrades, lastUpgrade: $lastUpgrade, installed: $installed, upgradesByWeek: $weekly,
        uptime: $uptime, now: $now,
        palette: $palette, palettes: $palettes, wallpapers: $walls
      }'
