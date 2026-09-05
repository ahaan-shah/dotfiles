#!/usr/bin/env bash
# firewall.sh — what the settings menu's Security → Firewall page reads and
# writes. firewalld is the firewall here; install.sh's `network` phase installs
# it, enables it, and drops a localsend service into /etc/firewalld/services.
#
#   firewall.sh status                 KEY="value" lines, the whole page state
#   firewall.sh zones                  value/label/detail/current listing
#   firewall.sh services               value/label/detail/allowed listing
#   firewall.sh on | off               start/stop the daemon             (root)
#   firewall.sh set-zone <zone>        the ACTIVE zone, not the default  (root)
#   firewall.sh allow <svc> | block <svc>                                (root)
#
# ══ The polkit problem, measured exactly ═════════════════════════════════
# firewall-cmd talks to firewalld over D-Bus, and its actions split in two:
#
#     org.fedoraproject.FirewallD1.info          allow_active=yes
#     org.fedoraproject.FirewallD1.config        auth_admin_keep
#     org.fedoraproject.FirewallD1.config.info   auth_admin_keep
#
# Only `info` is free. Verified with pkcheck against this session, then by
# timing every read this page could want:
#
#     firewall-cmd --get-active-zones              253ms  rc=0
#     firewall-cmd --list-services                 hangs  rc=124
#     firewall-cmd --zone=public --list-services   hangs  rc=124
#     firewall-cmd --get-zone-of-interface=wlan0   hangs  rc=124
#     firewall-cmd --get-zones                     hangs  rc=124
#     firewall-cmd --get-default-zone              hangs  rc=124
#
# They HANG rather than fail: the call blocks while polkit waits for an
# authentication a background script can never supply, and one unanswered
# dialog queues every later call behind it. That is what made the settings menu
# prompt three times and then appear to freeze.
#
# auth_admin_keep also CACHES, which is why this was missed at first — once the
# user has authenticated for anything, every read sails through and the whole
# arrangement looks free. It returns the moment the cache lapses.
#
# ══ So: exactly one D-Bus call, and it is the safe one ═══════════════════
# `--get-active-zones` is the single `info` read needed, and it is time-boxed
# anyway, because a settings page must never be able to hang. Everything else
# comes from somewhere that cannot prompt at all:
#
#     running / enabled   systemctl is-active / is-enabled
#     zone list           {/usr/lib,/etc}/firewalld/zones/*.xml
#     zone services       that zone's XML, /etc winning over /usr/lib
#     fallback zone       NetworkManager's connection.zone, then "public"
#
# /etc/firewalld/firewalld.conf is 0600 root, so the default zone CANNOT be read
# from disk — and that was the bug that made this page insist the zone was
# "public" while it was really something else. The read fell through to the
# stock /usr/lib copy, which always says public, and said so with confidence.
#
# ══ Writes ═══════════════════════════════════════════════════════════════
# Root, obtained through finder's own password box (privileged-run.sh →
# SUDO_ASKPASS), never through polkit: FirewallD.conf's D-Bus policy carries an
# explicit <policy user="root"> allowing both interfaces, so root is not gated.
#
#   * The switch STARTS and STOPS the daemon and never disables it — Ahaan's
#     rule, because it must always come back at boot. `on` also enables the
#     unit, so a machine that ended up disabled is corrected rather than left.
#   * set-zone changes the ACTIVE zone only. DefaultZone stays public, always.
#     The zone is bound to the interface now and persisted on NetworkManager's
#     connection, so it survives a reconnect without rewriting firewalld's
#     default.
#   * Service toggles are permanent-and-reversible rather than runtime-only.
#     Reading runtime state is a config.info call — the one thing that can hang
#     — so the zone's XML is the truth, and a service turned off is REMEMBERED
#     here so it stays listed and can be turned back on. Anything added to the
#     zone from a terminal appears on its own.

set -uo pipefail

ETC=/etc/firewalld
LIB=/usr/lib/firewalld
OFFFILE="${XDG_CONFIG_HOME:-$HOME/.config}/scripts/firewall-off.conf"

die() { echo "firewall: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# ── reads: never able to prompt, never able to hang ──────────────────────

# The one D-Bus call, always time-boxed. Output looks like:
#     public (default)
#       interfaces: wlan0
active_zone() {
    local out z con
    out="$(timeout 3 firewall-cmd --get-active-zones 2>/dev/null)" || out=""
    z="$(printf '%s' "$out" | head -1 | sed 's/ .*//')"
    if [ -z "$z" ]; then
        con="$(nmcli -t -f NAME connection show --active 2>/dev/null | head -1)"
        [ -n "$con" ] && z="$(nmcli -t -f connection.zone connection show "$con" 2>/dev/null | cut -d: -f2)"
    fi
    printf '%s' "${z:-public}"
}

active_iface() { nmcli -t -f DEVICE connection show --active 2>/dev/null | grep -v '^lo$' | head -1; }
active_con()   { nmcli -t -f NAME   connection show --active 2>/dev/null | head -1; }

zone_file() {
    local z="$1"
    [ -f "$ETC/zones/$z.xml" ] && { printf '%s' "$ETC/zones/$z.xml"; return; }
    [ -f "$LIB/zones/$z.xml" ] && { printf '%s' "$LIB/zones/$z.xml"; return; }
}

zone_services() {
    local zf
    zf="$(zone_file "$1")"
    [ -n "$zf" ] || return 0
    sed -n 's/.*<service name="\([^"]*\)".*/\1/p' "$zf"
}

# Services turned off from this menu, "<zone> <service>" per line. They stay
# listed so they can be turned back on — otherwise switching one off would make
# it vanish, which is the opposite of a toggle.
remembered_off() {
    [ -f "$OFFFILE" ] || return 0
    awk -v z="$1" '$1 == z { print $2 }' "$OFFFILE"
}
remember_off() {
    mkdir -p "$(dirname "$OFFFILE")"
    printf '%s %s\n' "$1" "$2" >>"$OFFFILE"
    sort -u -o "$OFFFILE" "$OFFFILE"
}
forget_off() {
    [ -f "$OFFFILE" ] || return 0
    local tmp="$OFFFILE.tmp.$$"
    awk -v z="$1" -v s="$2" '!($1 == z && $2 == s)' "$OFFFILE" >"$tmp" && mv "$tmp" "$OFFFILE"
}

cmd_status() {
    if [ ! -d "$LIB" ] && [ ! -d "$ETC" ]; then printf 'AVAILABLE="no"\n'; return 0; fi
    printf 'AVAILABLE="yes"\n'

    # Captured first, then tested — never a producer piped into a test.
    local active enabled zone on off
    active="$(systemctl is-active firewalld 2>/dev/null)"
    [ "$active" = "active" ] && printf 'RUNNING="yes"\n' || printf 'RUNNING="no"\n'

    enabled="$(systemctl is-enabled firewalld 2>/dev/null)"
    [ "$enabled" = "enabled" ] && printf 'ENABLED="yes"\n' || printf 'ENABLED="no"\n'

    zone="$(active_zone)"
    printf 'ZONE="%s"\n' "$zone"
    printf 'IFACE="%s"\n' "$(active_iface)"

    on="$(zone_services "$zone" | grep -c . || true)"
    off="$(remembered_off "$zone" | grep -c . || true)"
    printf 'ALLOWED="%s"\n' "${on:-0}"
    printf 'BLOCKED="%s"\n' "${off:-0}"
    return 0
}

# The same four-column format every ui-prefs.sh listing prints.
cmd_zones() {
    local cur z f
    cur="$(active_zone)"
    for f in "$LIB"/zones/*.xml "$ETC"/zones/*.xml; do
        [ -f "$f" ] || continue
        f="${f##*/}"
        printf '%s\n' "${f%.xml}"
    done | sort -u | while read -r z; do
        printf '%s\t%s\t\t%s\n' "$z" "$z" "$([ "$z" = "$cur" ] && printf current)"
    done
    return 0
}

# ONLY the services this zone manages: the ones allowed in it, plus the ones
# turned off from here. Not all 265 firewalld ships — Ahaan's rule is that
# adding a new one is a deliberate act done from a terminal, after which it
# appears here to be toggled.
cmd_services() {
    local zone allowed s
    zone="$(active_zone)"
    allowed=" $(zone_services "$zone" | tr '\n' ' ') "
    { zone_services "$zone"; remembered_off "$zone"; } | sort -u | while read -r s; do
        [ -n "$s" ] || continue
        case "$allowed" in
            *" $s "*) printf '%s\t%s\t\tcurrent\n' "$s" "$s" ;;
            *)        printf '%s\t%s\t\t\n'        "$s" "$s" ;;
        esac
    done
    return 0
}

# ── writes (root, via the caller's SUDO_ASKPASS) ─────────────────────────

# Errors are NOT swallowed: whatever this prints reaches the password box, which
# shows it instead of a bare "the command failed".
fwcmd() {
    sudo timeout 10 firewall-cmd "$@" 2>&1
}

# `on` enables as well: the firewall must be up at every boot, so a unit that
# ended up disabled is corrected rather than quietly left that way.
cmd_on() {
    sudo systemctl enable firewalld >/dev/null 2>&1 || true
    sudo systemctl start  firewalld >/dev/null 2>&1 || die "could not start firewalld"
}

# Stop only. NEVER disable — it has to come back at the next boot.
cmd_off() {
    sudo systemctl stop firewalld >/dev/null 2>&1 || die "could not stop firewalld"
}

cmd_set_zone() {
    local z="${1:-}" iface con out
    [ -n "$z" ] || die "no zone given"
    [ -n "$(zone_file "$z")" ] || die "no such zone: $z"
    iface="$(active_iface)"
    con="$(active_con)"

    # Runtime first, so it takes effect now. As root, firewalld's D-Bus policy
    # allows this outright and polkit is never consulted — but it is still
    # time-boxed, because a write that hangs is as bad as a read that does.
    if [ -n "$iface" ]; then
        out="$(fwcmd --zone="$z" --change-interface="$iface")" \
            || die "${out:-could not move $iface into $z}"
    fi
    # Then persist it on the CONNECTION, not as firewalld's default — the
    # default zone stays public by policy.
    if [ -n "$con" ]; then
        sudo nmcli connection modify "$con" connection.zone "$z" >/dev/null 2>&1 \
            || die "could not persist the zone on $con"
    fi
}

# ── why firewall-cmd here and not firewall-offline-cmd ───────────────────
# The first version used firewall-offline-cmd, and toggling a service failed
# with nothing to show for it but "the command failed" — because the error was
# redirected to /dev/null. offline-cmd is documented for configuring firewalld
# while it is NOT running, and this daemon is running.
#
# `sudo firewall-cmd` is the right tool and is already proven in this very
# script: set-zone uses it and works, which is the practical demonstration that
# root is not gated by polkit (FirewallD.conf carries an explicit
# <policy user="root">).
#
# Runtime AND permanent, both explicitly, rather than --permanent followed by
# --reload: a reload rebuilds the runtime configuration from the permanent one
# and would discard anything else that had been added at runtime — by
# NetworkManager or libvirt, for instance.
cmd_service() {
    local action="$1" svc="${2:-}" zone out
    [ -n "$svc" ] || die "no service given"
    zone="$(active_zone)"
    [ -n "$zone" ] || die "could not determine the active zone"

    out="$(fwcmd --zone="$zone" --"$action"-service="$svc")" \
        || die "runtime: ${out:-could not $action $svc in $zone}"
    out="$(fwcmd --permanent --zone="$zone" --"$action"-service="$svc")" \
        || die "permanent: ${out:-could not $action $svc in $zone}"

    if [ "$action" = "remove" ]; then remember_off "$zone" "$svc"
    else                              forget_off  "$zone" "$svc"; fi
}

case "${1:-}" in
    status)    cmd_status ;;
    zones)     cmd_zones ;;
    services)  cmd_services ;;
    on)        cmd_on ;;
    off)       cmd_off ;;
    set-zone)  cmd_set_zone "${2:-}" ;;
    allow)     cmd_service add    "${2:-}" ;;
    block)     cmd_service remove "${2:-}" ;;
    *)
        echo "usage: $(basename "$0") {status|zones|services}" >&2
        echo "       $(basename "$0") {on|off}" >&2
        echo "       $(basename "$0") set-zone <zone>" >&2
        echo "       $(basename "$0") {allow|block} <service>" >&2
        exit 2
        ;;
esac
