//============================================================//
//  Quickshell bar — 1:1 port of the Waybar config            //
//  Target: Quickshell 0.3.0 (Arch)                           //
//                                                            //
//  Install: put this file at  ~/.config/quickshell/shell.qml //
//  Run:      qs      (or `quickshell`)                       //
//  Autostart (hyprland.lua): hl.exec_cmd("qs")               //
//                                                            //
//  Interactions (clicks/scrolls) reuse your EXACT waybar     //
//  commands, and volume/brightness reuse your existing       //
//  scripts, so behaviour is identical.                       //
//                                                            //
//  >>> TO VERIFY ON YOUR MACHINE (search VERIFY)             //
//      1. homeDir (below) if your user isn't "ahaan"         //
//      2. Bluetooth property names (BluetoothDevice.*)       //
//      wifi essid/signal tooltip reads it via `nmcli` — needs //
//      NetworkManager running (icon works regardless).       //
//============================================================//

import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Services.Mpris
import Quickshell.Services.UPower
import Quickshell.Bluetooth
import Quickshell.Services.Pipewire
import Quickshell.Services.Notifications
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Effects

Scope {
    id: root

    // ---- VERIFY: home directory (used for pywal colors + scripts) -------------
    property string homeDir: "/home/ahaan"
    property string scriptsDir: homeDir + "/.config/waybar/scripts"

    // ---- fonts (from style.css: 15px, CodeNewRoman Nerd Font Propo) -----------
    readonly property string fontFamily: "CodeNewRoman Nerd Font Propo"
    readonly property int fontSize: 16

    // ---- pywal palette (parsed from ~/.cache/wal/colors-waybar.css) -----------
    // style.css did:  @import '../../.cache/wal/colors-waybar.css'
    // We parse its @define-color lines instead, and reload live when pywal runs.
    property var palette: ({})
    readonly property color colBg:   palette["background"] !== undefined ? palette["background"] : "#1e1e1e"
    readonly property color colFg:   palette["foreground"] !== undefined ? palette["foreground"] : "#dddddd"
    readonly property color colText: palette["text"]       !== undefined ? palette["text"]       : colFg
    readonly property color col7:    palette["color7"]     !== undefined ? palette["color7"]     : "#ffffff"
    readonly property color col9:    palette["color9"]     !== undefined ? palette["color9"]     : "#9aa0a6"
    readonly property color col15:   palette["color15"]    !== undefined ? palette["color15"]    : colFg

    // ---- notification-center theme (mirrors your swaync style.css) ------------
    //   text=@color15 · bg=alpha(bg,.93) · bg-strong=alpha(bg,.95)
    //   mycolor=@color9 · border-color=alpha(@color7,.8)
    readonly property color ncText:   col15
    readonly property color ncBg:     alpha(colBg, 0.93)
    readonly property color ncBgStrong: alpha(colBg, 0.95)
    readonly property color ncAccent: col9
    readonly property color ncBorder: alpha(col7, 0.8)
    readonly property string ncFont: "UbuntuMono Nerd Font"

    // Gap between the bar and any dropdown beneath it. These windows are layer
    // surfaces whose top already begins below the bar's 44px exclusive zone, so
    // this is the visible gap on top of that — one knob for all six dropdowns
    // (control center, calendar, battery, wifi, bluetooth, audio) so they stay
    // aligned with each other.
    // 0 is as tight as this can go: these are layer surfaces, and the bar's
    // 44px exclusive zone is a hard floor they cannot cross (a negative margin
    // just clamps). The bar's visible island ends at y=38, so the gap bottoms
    // out at 6px. Going tighter would mean trimming the bar's exclusive zone,
    // which moves every tiled window up by the same amount.
    readonly property int panelTopMargin: 0

    // control center open/closed (toggled by the arch button in the bar)
    property bool ccVisible: false

    // calendar dropdown open/closed (toggled by the clock in the bar), and
    // which month it's currently showing (independent of "today")
    property bool calVisible: false
    property int calYear: new Date().getFullYear()
    property int calMonth: new Date().getMonth()          // 0 = January
    readonly property var monthNames: ["January", "February", "March", "April",
        "May", "June", "July", "August", "September", "October", "November", "December"]

    function calDaysInMonth(y, m) { return new Date(y, m + 1, 0).getDate(); }
    function calFirstWeekday(y, m) { return new Date(y, m, 1).getDay(); }   // 0 = Sunday
    function calPrevMonth() { if (calMonth === 0) { calMonth = 11; calYear--; } else calMonth--; }
    function calNextMonth() { if (calMonth === 11) { calMonth = 0; calYear++; } else calMonth++; }
    // pick black/white text for a filled circle so "today" stays legible
    // regardless of how light/dark the current wallpaper's accent color is
    function contrastText(c) { return (0.299 * c.r + 0.587 * c.g + 0.114 * c.b) > 0.6 ? "black" : "white"; }

    // Drives calCells' re-evaluation across midnight. `new Date()` inside a
    // QML property binding is NOT a dependency the binding engine can see, so
    // without reading an actual QML property here, calCells only ever
    // recomputed when calYear/calMonth changed (i.e. month nav) — the "today"
    // dot would silently go stale for the rest of the day the machine stayed
    // up. Minutes precision is cheap and gets the day rollover within a
    // minute of midnight instead of requiring a month-nav round trip.
    SystemClock { id: dayClock; precision: SystemClock.Minutes }

    // 6 weeks x 7 days, including muted leading/trailing days from adjacent
    // months so the grid is always a full rectangle. Recomputes whenever
    // calYear/calMonth change since it reads them directly, and whenever
    // dayClock ticks so the "today" highlight follows a real day rollover.
    readonly property var calCells: {
        var first = calFirstWeekday(calYear, calMonth);
        var days = calDaysInMonth(calYear, calMonth);
        var prevDays = calDaysInMonth(calMonth === 0 ? calYear - 1 : calYear, calMonth === 0 ? 11 : calMonth - 1);
        var today = dayClock.date;
        var cells = [];
        for (var i = 0; i < 42; i++) {
            var dayNum = i - first + 1;
            var inMonth = dayNum >= 1 && dayNum <= days;
            var num = dayNum < 1 ? prevDays + dayNum : (dayNum > days ? dayNum - days : dayNum);
            var isToday = inMonth && num === today.getDate()
                          && calMonth === today.getMonth() && calYear === today.getFullYear();
            cells.push({ num: num, inMonth: inMonth, weekday: i % 7, isToday: isToday });
        }
        return cells;
    }

    // battery hard-coded colours (these were literal hex in style.css)
    readonly property color colCharging: "#26A65B"
    readonly property color colWarning:  "#ffbe61"
    readonly property color colCritical: "#f53c3c"

    // ---- battery threshold panel state -----------------------------------
    property bool batVisible: false
    readonly property var batDev: UPower.displayDevice
    readonly property int batCap: batDev ? Math.round(batDev.percentage * 100) : 0
    readonly property bool batCharging: batDev && batDev.state === UPowerDeviceState.Charging
    // Quickshell's own UPowerDevice.healthSupported reports false on this
    // hardware even though `upower -i` reports a real capacity figure — read
    // charge_full/charge_full_design directly instead (same ratio upower
    // itself uses under the hood).
    property real batHealthPct: -1
    Process {
        id: batHealthRead
        command: ["bash", "-c",
            "cat /sys/class/power_supply/BAT0/charge_full 2>/dev/null; echo '|'; " +
            "cat /sys/class/power_supply/BAT0/charge_full_design 2>/dev/null"]
        stdout: StdioCollector { onStreamFinished: {
            var p = (this.text || "").trim().split("|");
            var full = parseFloat(p[0]); var design = parseFloat(p[1]);
            root.batHealthPct = (!isNaN(full) && !isNaN(design) && design > 0) ? (full / design * 100) : -1;
        } }
    }
    Timer { interval: 5000; running: root.batVisible; repeat: true; triggeredOnStart: true
            onTriggered: batHealthRead.running = true }

    readonly property real batSizeWh: batDev ? batDev.energyCapacity : 0
    readonly property real batTimeSeconds: root.batCharging ? (batDev ? batDev.timeToFull : 0) : (batDev ? batDev.timeToEmpty : 0)
    readonly property string batTimeLabel: root.batCharging ? "Time to Full Charge" : "Time Remaining"

    // current charge_control_end_threshold, polled from sysfs while the panel is open
    property int batThreshold: 100
    Process {
        id: batThresholdRead
        command: ["cat", "/sys/class/power_supply/BAT0/charge_control_end_threshold"]
        stdout: StdioCollector { onStreamFinished: {
            var v = parseInt((this.text || "").trim()); if (!isNaN(v)) root.batThreshold = v; } }
    }
    Timer { interval: 2000; running: root.batVisible; repeat: true; triggeredOnStart: true
            onTriggered: batThresholdRead.running = true }

    // Writes the new cap directly (no sudo — see hypr/scripts udev rule that
    // group-writes this sysfs attribute to the "power" group) and persists it
    // to ~/.config/battery-threshold so scripts/apply-battery-threshold.sh can
    // re-apply it on the next boot (the sysfs value itself resets to 100).
    function setBatteryThreshold(v) {
        // update the highlighted box immediately — don't wait on the shell
        // round-trip (write + notify-send) before the UI reflects the click.
        // The periodic batThresholdRead poll re-syncs from real sysfs state
        // shortly after anyway, so this optimistic set self-corrects if the
        // write actually failed (e.g. permission denied pre-relogin).
        root.batThreshold = v;
        root.run("echo " + v + " > /sys/class/power_supply/BAT0/charge_control_end_threshold 2>/tmp/batthr_err " +
                  "&& mkdir -p ~/.config && echo " + v + " > ~/.config/battery-threshold " +
                  "&& notify-send 'Battery' 'Charging capped at " + v + "%' " +
                  "|| notify-send -u critical 'Battery' 'Failed to set charge threshold (check /tmp/batthr_err)'");
        batThresholdReapply.restart();
    }
    // re-read shortly after a click to confirm/correct the optimistic update
    // above against the real sysfs value
    Timer { id: batThresholdReapply; interval: 400; onTriggered: batThresholdRead.running = true }


    //========================================================================//
    //  PANEL MUTUAL EXCLUSION                                                //
    //  Every dropdown (control center, calendar, battery, wifi, bluetooth,   //
    //  audio) is its own PanelWindow; only one may be open at a time.        //
    //========================================================================//
    property bool netVisible: false
    property bool btVisible:  false
    property bool audVisible: false

    function closePanels() {
        root.ccVisible = false; root.calVisible = false; root.batVisible = false;
        root.netVisible = false; root.btVisible = false; root.audVisible = false;
    }
    function panelOpen(which) {
        return which === "cc"  ? root.ccVisible  : which === "cal" ? root.calVisible
             : which === "bat" ? root.batVisible : which === "net" ? root.netVisible
             : which === "bt"  ? root.btVisible  : which === "aud" ? root.audVisible : false;
    }
    function togglePanel(which) {
        var wasOpen = root.panelOpen(which);
        root.closePanels();
        if (wasOpen) return;
        if      (which === "cc")  root.ccVisible  = true;
        else if (which === "cal") root.calVisible = true;
        else if (which === "bat") root.batVisible = true;
        else if (which === "net") root.netVisible = true;
        else if (which === "bt")  root.btVisible  = true;
        else if (which === "aud") root.audVisible = true;
    }

    //========================================================================//
    //  SHELL-QUOTING + nmcli TERSE-OUTPUT PARSING                            //
    //========================================================================//
    // Everything below feeds SSIDs straight into `sh -c`, and this machine's
    // saved networks include spaces and emoji ("Pancake 🥞✨"), so nothing may
    // ever be interpolated unquoted.
    function shq(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'"; }

    // `nmcli -t` joins fields with ':' and backslash-escapes any ':' (or '\')
    // that occurs *inside* a field — so a naive .split(":") corrupts every SSID
    // containing a colon. Splits on unescaped ':' only, unescapes as it goes,
    // and (when `n` > 0) stops splitting after n-1 separators so the final
    // field keeps any colons it legitimately contains. Put the free-form field
    // (SSID / connection NAME) LAST in every -f field list so this works.
    function nmSplit(line, n) {
        var parts = [], cur = "", i = 0;
        while (i < line.length) {
            var ch = line.charAt(i);
            if (ch === "\\" && i + 1 < line.length) { cur += line.charAt(i + 1); i += 2; continue; }
            if (ch === ":" && (n <= 0 || parts.length < n - 1)) { parts.push(cur); cur = ""; i++; continue; }
            cur += ch; i++;
        }
        parts.push(cur);
        return parts;
    }

    function fmtBytes(b) {
        if (!b || b < 0) return "—";
        var u = ["B", "KB", "MB", "GB", "TB"], i = 0;
        while (b >= 1024 && i < u.length - 1) { b /= 1024; i++; }
        return (i === 0 ? b.toFixed(0) : b.toFixed(b < 10 ? 2 : 1)) + " " + u[i];
    }
    function fmtRate(b) { return b > 0 ? root.fmtBytes(b) + "/s" : "0 B/s"; }

    //========================================================================//
    //  WI-FI  (NetworkManager via nmcli)                                     //
    //========================================================================//
    // Backend choice: this machine runs NetworkManager with `wifi.backend=iwd`
    // (/etc/NetworkManager/conf.d), i.e. NM drives iwd over D-Bus and owns the
    // saved-profile list (`nmcli connection show` has all 10 of them, and the
    // live link is an NM profile). Talking to iwd directly (iwctl/impala's own
    // backend) would create credentials NM doesn't know about and NM would
    // fight it on the next autoconnect — so every read and write here goes
    // through nmcli, which then hands the PSK down to iwd anyway. impala stays
    // reachable from the panel's gear button and sees the same networks.
    property string wifiIface: ""
    property bool   wifiEnabled: true
    property string wifiSsid: ""
    property int    wifiSignal: 0
    property string wifiIp: ""
    property string wifiGw: ""
    property string wifiBand: ""
    property string wifiRate: ""
    property real   wifiRxTotal: 0
    property real   wifiTxTotal: 0
    property real   wifiRxRate: 0
    property real   wifiTxRate: 0
    property string wifiPing: ""
    property string wifiLoss: ""
    property var    wifiNets: []          // [{ssid, signal, secure, known, active}]
    property string wifiPromptSsid: ""    // "" = no password prompt showing
    property string wifiBusySsid: ""      // SSID a connect/disconnect is in flight for
    property string wifiError: ""
    property bool   wifiScanning: false
    property string wifiMenuSsid: ""      // SSID whose right-click menu is open
    property string wifiPwSsid: ""        // SSID whose saved password is revealed
    property string wifiPwText: ""
    property string _wifiNewProfile: ""   // profile to roll back if a first-time connect fails
    property var    wifiProfiles: ({})    // real SSID -> saved profile UUID
    readonly property bool wifiConnected: root.wifiSsid !== ""

    // previous rx/tx sample, for the receiving/sending rate deltas
    property real _wifiPrevRx: -1
    property real _wifiPrevTx: -1
    property real _wifiPrevT: 0

    Process {
        id: wifiInfoProc
        command: ["bash", "-c",
            "IF=$(nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '$2==\"wifi\"{print $1; exit}'); " +
            "echo \"iface=$IF\"; " +
            "echo \"radio=$(nmcli radio wifi 2>/dev/null)\"; " +
            "echo \"ssid=$(nmcli -t -f ACTIVE,SSID dev wifi 2>/dev/null | sed -n 's/^yes://p' | head -1)\"; " +
            "echo \"signal=$(nmcli -t -f ACTIVE,SIGNAL dev wifi 2>/dev/null | sed -n 's/^yes://p' | head -1)\"; " +
            "echo \"freq=$(nmcli -t -f ACTIVE,FREQ dev wifi 2>/dev/null | sed -n 's/^yes://p' | head -1)\"; " +
            "echo \"rate=$(nmcli -t -f ACTIVE,RATE dev wifi 2>/dev/null | sed -n 's/^yes://p' | head -1)\"; " +
            "echo \"ip=$(ip -4 -o addr show $IF 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)\"; " +
            "echo \"gw=$(ip route show default dev $IF 2>/dev/null | awk '{print $3}' | head -1)\"; " +
            "echo \"rx=$(cat /sys/class/net/$IF/statistics/rx_bytes 2>/dev/null)\"; " +
            "echo \"tx=$(cat /sys/class/net/$IF/statistics/tx_bytes 2>/dev/null)\""]
        stdout: StdioCollector { onStreamFinished: {
            var kv = {}, lines = (this.text || "").split("\n");
            for (var i = 0; i < lines.length; i++) {
                var e = lines[i].indexOf("=");
                if (e > 0) kv[lines[i].substring(0, e)] = lines[i].substring(e + 1);
            }
            root.wifiIface   = kv["iface"] || "";
            root.wifiEnabled = (kv["radio"] || "").trim() === "enabled";
            root.wifiSsid    = kv["ssid"] || "";
            root.wifiSignal  = parseInt(kv["signal"]) || 0;
            root.wifiIp      = kv["ip"] || "";
            root.wifiGw      = kv["gw"] || "";
            root.wifiRate    = kv["rate"] || "";
            var mhz = parseInt(kv["freq"]) || 0;
            root.wifiBand = mhz >= 5900 ? "6 GHz" : mhz >= 4900 ? "5 GHz" : mhz > 0 ? "2.4 GHz" : "";

            var rx = parseFloat(kv["rx"]), tx = parseFloat(kv["tx"]);
            var now = Date.now();
            if (!isNaN(rx) && !isNaN(tx)) {
                root.wifiRxTotal = rx; root.wifiTxTotal = tx;
                // Guard the counter going *backwards* (interface reset / a
                // different device becoming the wifi iface) — a negative delta
                // would otherwise render as a nonsense negative rate.
                var dt = (now - root._wifiPrevT) / 1000;
                if (root._wifiPrevRx >= 0 && dt > 0.2 && rx >= root._wifiPrevRx && tx >= root._wifiPrevTx) {
                    root.wifiRxRate = (rx - root._wifiPrevRx) / dt;
                    root.wifiTxRate = (tx - root._wifiPrevTx) / dt;
                }
                root._wifiPrevRx = rx; root._wifiPrevTx = tx; root._wifiPrevT = now;
            }
        } }
    }

    Process {
        id: wifiPingProc
        command: ["bash", "-c",
            "G=$(ip route show default 2>/dev/null | awk '{print $3; exit}'); " +
            "[ -z \"$G\" ] && { echo '|'; exit 0; }; " +
            "o=$(ping -c 3 -i 0.2 -W 1 -q \"$G\" 2>/dev/null); " +
            "l=$(echo \"$o\" | sed -n 's/.*, \\([0-9.]*\\)% packet loss.*/\\1/p'); " +
            "r=$(echo \"$o\" | awk -F/ '/^rtt|round-trip/{printf \"%.0f\", $5}'); " +
            "echo \"$r|$l\""]
        stdout: StdioCollector { onStreamFinished: {
            var p = (this.text || "").trim().split("|");
            root.wifiPing = p[0] || ""; root.wifiLoss = p[1] || "";
        } }
    }

    // A saved profile's NAME is only the SSID by default — it can be renamed,
    // and nothing keeps the two in sync. Matching the scan list against names
    // therefore mislabels a renamed profile as an unknown network and prompts
    // for a password it already has. Resolve each wifi profile's real
    // 802-11-wireless.ssid instead, and carry its UUID so forget/show-password
    // address it unambiguously rather than by a name that may not match.
    //
    // This needs one nmcli call per profile (the field is not available from the
    // bulk `connection show` list), so it is deliberately NOT on the list poll:
    // saved profiles only change when something here adds or deletes one, so it
    // refreshes on panel open and after each action instead.
    Process {
        id: wifiProfilesProc
        command: ["sh", "-c",
            "nmcli -t -f TYPE,UUID,NAME connection show 2>/dev/null | sed -n 's/^802-11-wireless://p' | " +
            "while IFS= read -r line; do uuid=${line%%:*}; " +
            "s=$(nmcli -g 802-11-wireless.ssid connection show uuid \"$uuid\" 2>/dev/null); " +
            "[ -n \"$s\" ] && printf '%s\\t%s\\n' \"$uuid\" \"$s\"; done"]
        stdout: StdioCollector { onStreamFinished: {
            var map = {}, lines = (this.text || "").split("\n");
            for (var i = 0; i < lines.length; i++) {
                var t = lines[i].indexOf("\t");
                if (t <= 0) continue;
                var uuid = lines[i].substring(0, t);
                var ssid = lines[i].substring(t + 1);
                // Several profiles can share an SSID; the first is good enough,
                // and is the one nmcli itself would activate.
                if (ssid !== "" && map[ssid] === undefined) map[ssid] = uuid;
            }
            root.wifiProfiles = map;
            wifiListProc.running = true;     // re-mark the list against the new set
        } }
    }

    Process {
        id: wifiListProc
        // SSID goes last in the -f list so nmSplit() can keep any ':' it
        // contains (see nmSplit's comment).
        command: ["bash", "-c",
            "nmcli -t -f IN-USE,SIGNAL,SECURITY,SSID dev wifi list 2>/dev/null"]
        stdout: StdioCollector { onStreamFinished: {
            var scanned = (this.text || "").split("\n");
            var known = root.wifiProfiles;

            var seen = {}, out = [];
            for (var i = 0; i < scanned.length; i++) {
                if (scanned[i].trim() === "") continue;
                var f = root.nmSplit(scanned[i], 4);
                var ssid = f[3] || "";
                if (ssid === "") continue;                  // hidden network, nothing to click
                var sig = parseInt(f[1]) || 0;
                // The same SSID shows up once per BSSID (mesh / band-steering);
                // collapse to the strongest so the list isn't full of repeats.
                if (seen[ssid] !== undefined) {
                    if (sig > out[seen[ssid]].signal) out[seen[ssid]].signal = sig;
                    continue;
                }
                seen[ssid] = out.length;
                out.push({ ssid: ssid, signal: sig,
                           secure: (f[2] || "").trim() !== "",
                           known: known[ssid] !== undefined,
                           active: f[0] === "*" });
            }
            out.sort(function (a, b) {
                if (a.active !== b.active) return a.active ? -1 : 1;
                return b.signal - a.signal;
            });
            root.wifiNets = out;
        } }
    }

    Process { id: wifiScanProc; command: ["nmcli", "dev", "wifi", "rescan"] }

    // Scanning is user-initiated, mirroring the bluetooth panel: nothing
    // re-scans on a timer, so the list stops churning under you. Saved networks
    // stay listed regardless (they are the ones you actually pick from); only
    // unknown networks are gated on an active scan.
    function wifiSetScanning(on) {
        if (on && !root.wifiEnabled) { root.wifiError = "Wi-Fi is off"; return; }
        root.wifiScanning = on;
        if (on) {
            root.wifiError = "";
            wifiScanProc.running = true;
            wifiListProc.running = true;
            wifiScanStop.restart();
        } else wifiScanStop.stop();
    }
    // Backstop only; closing the panel stops scanning anyway.
    Timer { id: wifiScanStop; interval: 120000; onTriggered: root.wifiSetScanning(false) }

    // Split into the two rendered sections here rather than inferring group
    // boundaries while walking a single list — wifiNets is ordered by signal,
    // not grouped by `known`, so a per-row "did the flag change since the
    // previous row" test emitted a fresh heading every time the two kinds
    // interleaved, which is why both headings appeared more than once.
    readonly property var wifiKnown: {
        var o = [], n = root.wifiNets;
        for (var i = 0; i < n.length; i++) if (n[i].known) o.push(n[i]);
        return o;
    }
    readonly property var wifiOther: {
        var o = [], n = root.wifiNets;
        for (var i = 0; i < n.length; i++) {
            if (n[i].known) continue;
            // Only while a scan is running — except a network already being
            // connected to or prompting for a password, which must stay put or
            // its row (and the prompt attached to it) would vanish mid-flow.
            if (!root.wifiScanning && n[i].ssid !== root.wifiBusySsid
                && n[i].ssid !== root.wifiPromptSsid) continue;
            o.push(n[i]);
        }
        return o;
    }

    // Connect / disconnect / forget all land here so the panel can show a
    // spinner on the row and surface nmcli's own error text on failure.
    Process {
        id: wifiActionProc
        property string errText: ""
        stderr: StdioCollector { onStreamFinished: wifiActionProc.errText = (this.text || "").trim(); }
        onExited: (code) => {
            root.wifiBusySsid = "";
            var rollback = root._wifiNewProfile;
            root._wifiNewProfile = "";

            if (code === 0) { root.wifiPromptSsid = ""; root.wifiError = ""; }
            else {
                root.wifiError = root.wifiFriendlyError(wifiActionProc.errText) || "Connection failed";
                // A failed `device wifi connect` still leaves behind the profile
                // nmcli created for the attempt — so a network you mistyped the
                // password for becomes "known", and the next click connects
                // without prompting, fails again, and offers no way back in.
                // Roll the profile back so it returns to the unknown list and
                // asks for the password again. Only for a network that was not
                // already saved, so a transient failure never destroys a real
                // stored profile.
                if (rollback !== "") {
                    root.run("nmcli connection delete " + root.wifiProfileRef(rollback));
                    wifiRollbackRefresh.restart();
                }
            }
            wifiInfoProc.running = true;
            wifiListProc.running = true;
        }
    }
    // nmcli's own wording for a rejected key is "Secrets were required, but not
    // provided", which reads like a bug rather than "you typed it wrong".
    function wifiFriendlyError(raw) {
        if (!raw || raw === "") return "";
        var e = String(raw).replace(/^Error: */, "");
        if (/Secrets were required|no secrets provided|802-1X supplicant/i.test(e)) return "Incorrect password";
        if (/No network with SSID/i.test(e))     return "Network not found — scan again";
        if (/Timeout expired|timed out/i.test(e)) return "Timed out — the network did not respond";
        if (/not authorized|not permitted/i.test(e)) return "Not permitted";
        return e.split("\n")[0];
    }

    function wifiRun(cmd, busySsid) {
        root.wifiBusySsid = busySsid || "";
        root.wifiError = "";
        wifiActionProc.errText = "";
        wifiActionProc.running = false;      // a re-assigned command is ignored while still running
        wifiActionProc.command = ["sh", "-c", cmd];
        wifiActionProc.running = true;
    }
    // `nmcli device wifi connect` reuses an existing saved profile when one
    // matches the SSID, so this is the single entry point for both known and
    // brand-new networks. -w bounds the wait (default is ~90s of a frozen row).
    function wifiIsKnown(ssid) {
        for (var i = 0; i < root.wifiNets.length; i++)
            if (root.wifiNets[i].ssid === ssid) return root.wifiNets[i].known;
        return false;
    }
    function wifiConnect(ssid, password) {
        // Remember whether this network was already saved, so a failure can tell
        // a profile nmcli just invented from one that was already there.
        root._wifiNewProfile = root.wifiIsKnown(ssid) ? "" : ssid;
        var c = "nmcli -w 25 device wifi connect " + root.shq(ssid);
        if (password && password.length > 0) c += " password " + root.shq(password);
        root.wifiRun(c, ssid);
    }
    function wifiDisconnect() {
        if (root.wifiIface === "") return;
        root._wifiNewProfile = "";
        root.wifiRun("nmcli -w 15 device disconnect " + root.shq(root.wifiIface), root.wifiSsid);
    }
    // Reading a saved PSK back needs no privilege escalation here — nmcli hands
    // it over for a connection this user owns, so no polkit agent is involved
    // (there is none running on this session anyway).
    Process {
        id: wifiPwProc
        stdout: StdioCollector { onStreamFinished: {
            // Two lines: key-mgmt, then the psk. A secured network whose secret
            // simply is not stored locally is a different thing from an open
            // one, and saying "no password" for both is misleading — one of the
            // saved profiles here is exactly that case.
            var lines = (this.text || "").split("\n");
            var keyMgmt = (lines[0] || "").trim();
            var psk = (lines[1] || "").trim();
            root.wifiPwText = psk !== "" ? psk
                            : (keyMgmt === "" ? "(open network — no password)"
                                              : "(no password saved for this network)");
        } }
    }
    // Every profile-targeted command addresses `uuid <id>` rather than `id
    // <name>`: the name is user-editable and need not equal the SSID.
    function wifiProfileRef(ssid) {
        var uuid = root.wifiProfiles[ssid];
        return uuid !== undefined ? "uuid " + root.shq(uuid) : "id " + root.shq(ssid);
    }
    function wifiTogglePassword(ssid) {
        if (root.wifiPwSsid === ssid) { root.wifiPwSsid = ""; root.wifiPwText = ""; return; }
        root.wifiPwSsid = ssid;
        root.wifiPwText = "…";
        wifiPwProc.running = false;      // a reassigned command is ignored while running
        wifiPwProc.command = ["sh", "-c",
            "nmcli -s -g 802-11-wireless-security.key-mgmt,802-11-wireless-security.psk connection show "
            + root.wifiProfileRef(ssid)];
        wifiPwProc.running = true;
    }

    function wifiForget(ssid) {
        root.wifiMenuSsid = ""; root.wifiPwSsid = ""; root.wifiPwText = "";
        root._wifiNewProfile = "";
        root.wifiRun("nmcli connection delete " + root.wifiProfileRef(ssid), ssid);
    }
    function wifiSetEnabled(on) {
        root.wifiEnabled = on;               // optimistic; the poll below corrects it
        root.run("nmcli radio wifi " + (on ? "on" : "off"));
        wifiEnabledRecheck.restart();
    }
    Timer { id: wifiEnabledRecheck; interval: 700; onTriggered: wifiInfoProc.running = true }
    // The rollback delete is detached, so re-read the list once it has landed —
    // otherwise the row can sit in "known" until the next poll.
    Timer { id: wifiRollbackRefresh; interval: 900; onTriggered: wifiProfilesProc.running = true }

    // Two cadences: the live counters/rates want to tick fast, the AP list is
    // a much heavier nmcli call and only needs to keep up with a rescan.
    Timer { interval: 1500; running: root.netVisible; repeat: true; triggeredOnStart: true
            onTriggered: wifiInfoProc.running = true }
    Timer { interval: 3000; running: root.netVisible && root.wifiConnected; repeat: true; triggeredOnStart: true
            onTriggered: wifiPingProc.running = true }
    // The AP list still refreshes while the panel is open — that is what keeps
    // the connected row and the signal figures honest — but it only reads
    // NetworkManager's existing scan cache. An actual rescan happens solely
    // while scanning is switched on.
    Timer { interval: 4000; running: root.netVisible; repeat: true; triggeredOnStart: true
            onTriggered: wifiListProc.running = true }
    Timer { interval: 10000; running: root.netVisible && root.wifiScanning && root.wifiEnabled
            repeat: true; onTriggered: wifiScanProc.running = true }

    onNetVisibleChanged: {
        if (!netVisible) {
            root.wifiPromptSsid = ""; root.wifiError = ""; root.wifiSetScanning(false);
            root.wifiMenuSsid = ""; root.wifiPwSsid = ""; root.wifiPwText = "";
        }
        else {
            root._wifiPrevRx = -1; root.wifiRxRate = 0; root.wifiTxRate = 0;
            wifiProfilesProc.running = true;
        }
    }

    //========================================================================//
    //  NERD-FONT GLYPHS                                                      //
    //========================================================================//
    // Built from codepoints rather than pasted literals: every icon these
    // panels use lives in the Material Design range (U+F0000+), which is
    // outside the BMP, so a pasted glyph is a surrogate pair that any tool
    // touching this file (sed, a heredoc, a diff viewer) can silently mangle.
    // Codepoints below were read out of UbuntuMonoNerdFont-Regular.ttf's own
    // cmap by glyph name (md-wifi_strength_4 etc.), not recalled.
    function nf(cp) { return String.fromCodePoint(cp); }
    readonly property var g: ({
        wifi0:    String.fromCodePoint(0xf092f),   // md-wifi_strength_outline
        wifi1:    String.fromCodePoint(0xf091f),
        wifi2:    String.fromCodePoint(0xf0922),
        wifi3:    String.fromCodePoint(0xf0925),
        wifi4:    String.fromCodePoint(0xf0928),
        wifiOff:  String.fromCodePoint(0xf05aa),   // md-wifi_off
        lock:     String.fromCodePoint(0xf023),    // fa-lock
        bt:       String.fromCodePoint(0xf00af),   // md-bluetooth
        btOff:    String.fromCodePoint(0xf00b2),   // md-bluetooth_off
        btConn:   String.fromCodePoint(0xf00b1),   // md-bluetooth_connect
        headphones: String.fromCodePoint(0xf02cb),
        earbuds:  String.fromCodePoint(0xf184f),
        speaker:  String.fromCodePoint(0xf04c3),
        mic:      String.fromCodePoint(0xf036c),
        micOff:   String.fromCodePoint(0xf036d),
        volume:   String.fromCodePoint(0xf057e),   // md-volume_high
        volumeOff:String.fromCodePoint(0xf0581),   // md-volume_off
        mouse:    String.fromCodePoint(0xf037d),
        keyboard: String.fromCodePoint(0xf030c),
        phone:    String.fromCodePoint(0xf011c),   // md-cellphone
        laptop:   String.fromCodePoint(0xf0322),
        watch:    String.fromCodePoint(0xf0589),
        printer:  String.fromCodePoint(0xf042a),
        camera:   String.fromCodePoint(0xf0100),
        gamepad:  String.fromCodePoint(0xf02b4),   // md-google_controller
        hdmi:     String.fromCodePoint(0xf0841),   // md-video_input_hdmi
        radioOn:  String.fromCodePoint(0xf043e),   // md-radiobox_marked
        radioOff: String.fromCodePoint(0xf043d),   // md-radiobox_blank
        battery:  String.fromCodePoint(0xf0079),
        cog:      String.fromCodePoint(0xf0493),   // md-cog  (advanced settings)
        radar:    String.fromCodePoint(0xf0437),   // md-radar (scan for devices)
        loading:  String.fromCodePoint(0xf0772)
    })

    function wifiIcon(sig) {
        if (!root.wifiEnabled) return root.g.wifiOff;
        return sig >= 75 ? root.g.wifi4 : sig >= 55 ? root.g.wifi3
             : sig >= 35 ? root.g.wifi2 : sig >= 15 ? root.g.wifi1 : root.g.wifi0;
    }

    //========================================================================//
    //  BLUETOOTH  (Quickshell.Bluetooth / BlueZ — no bluetoothctl shelling)  //
    //========================================================================//
    readonly property var btAdapter: Bluetooth.defaultAdapter
    readonly property bool btOn: btAdapter ? btAdapter.enabled : false
    readonly property bool btReady: root.btAdapter !== null
                                    && root.btAdapter.state === BluetoothAdapterState.Enabled

    property bool   btScanning: false
    property string btBusyPath: ""     // dbusPath of the device an action is running for
    property string btError: ""
    property string btMenuPath: ""     // dbusPath of the device whose context menu is open
    property string btRenamePath: ""   // dbusPath of the device being renamed
    property string _btPairThenConnect: ""   // dbusPath to connect once a pair lands
    property string _btBondCheckPath: ""     // dbusPath to confirm actually bonded

    readonly property var btAllDevices: {
        var m = root.btAdapter ? root.btAdapter.devices : null;
        return m ? m.values : [];
    }

    // BlueZ distinguishes Name (what the device advertises, immutable) from
    // Alias (the user-facing name, writable — "Blueberry" for a Bose Flex).
    // Quickshell maps Alias to the writable `name` and Name to the read-only
    // `deviceName`, so the alias is what must be shown, and setting `name` is
    // all a rename needs — no bluetoothctl round trip.
    function btLabel(dev) {
        if (!dev) return "";
        if (dev.name && dev.name !== "") return dev.name;
        if (dev.deviceName && dev.deviceName !== "") return dev.deviceName;
        return dev.address;
    }
    // A BLE scan turns up a lot of nameless beacons whose only "name" is their
    // MAC with dashes; float anything with a real name above them.
    function btHasRealName(dev) {
        var n = root.btLabel(dev);
        return (n !== "" && n !== String(dev.address).replace(/:/g, "-")) ? 1 : 0;
    }

    readonly property var btPaired: {
        var o = [], d = root.btAllDevices;
        for (var i = 0; i < d.length; i++) if (d[i].paired || d[i].bonded) o.push(d[i]);
        o.sort(function (a, b) { return (b.connected ? 1 : 0) - (a.connected ? 1 : 0); });
        return o;
    }
    readonly property var btAvailable: {
        var o = [], d = root.btAllDevices;
        for (var i = 0; i < d.length; i++) {
            var x = d[i];
            if (x.paired || x.bonded) continue;
            // Only listed while a scan is actually running. The one exception is
            // a device an action is already in flight for: pairing stops the
            // scan as its first step, so without this its row (and its spinner)
            // would vanish the instant it was clicked.
            if (!root.btScanning && x.dbusPath !== root.btBusyPath) continue;
            o.push(x);
        }
        o.sort(function (a, b) { return root.btHasRealName(b) - root.btHasRealName(a); });
        return o;
    }
    readonly property int btConnectedCount: {
        var n = 0, d = root.btAllDevices;
        for (var i = 0; i < d.length; i++) if (d[i].connected) n++;
        return n;
    }

    //---- discovery: manual only ------------------------------------------------
    // Scanning is user-initiated rather than running for as long as the panel is
    // open. Two reasons beyond the obvious battery cost: BlueZ rejects a
    // discovery start with "Resource Not Ready" if the adapter has not finished
    // powering up (which is what happened when this auto-started on panel open),
    // and an active scan is a well-known cause of connection attempts failing
    // with le-connection-abort-by-local — so every action below stops it first.
    function btSetScanning(on) {
        if (on && !root.btReady) { root.btError = "Adapter not ready"; return; }
        root.btScanning = on;
        // Only write when it actually differs — BlueZ logs a warning if asked to
        // stop a discovery that was never started, which happens every time the
        // panel closes without anyone having pressed scan.
        if (root.btAdapter && root.btAdapter.discovering !== on) root.btAdapter.discovering = on;
        if (on) { root.btError = ""; btScanTimeout.restart(); } else btScanTimeout.stop();
    }
    // Plain on/off toggle — this is only a backstop against a scan left running
    // unattended. Closing the panel stops discovery anyway (below), so it very
    // rarely fires.
    // "Paired but not bonded" means no key was written to disk, so the pairing
    // will not survive a power cycle. That failure is otherwise completely
    // silent until the device mysteriously vanishes from the paired list days
    // later, so say so at the time.
    Timer {
        id: btBondCheck
        interval: 3000
        onTriggered: {
            var path = root._btBondCheckPath; root._btBondCheckPath = "";
            if (path === "") return;
            for (var i = 0; i < root.btAllDevices.length; i++) {
                var d = root.btAllDevices[i];
                if (d.dbusPath !== path) continue;
                if ((d.paired || d.bonded) && !d.bonded)
                    root.btError = "Paired, but the key was not saved — this may not survive a restart";
                return;
            }
        }
    }

    Timer { id: btScanTimeout; interval: 120000; onTriggered: root.btSetScanning(false) }

    onBtVisibleChanged: if (!btVisible) {
        root.btSetScanning(false);
        root.btMenuPath = ""; root.btRenamePath = ""; root.btError = "";
        root._btPairThenConnect = "";
    }
    onBtOnChanged: if (!btOn) root.btSetScanning(false)

    //---- actions ---------------------------------------------------------------
    // Pairing goes through bluetoothctl instead of Quickshell's own dev.pair():
    // BlueZ will not complete a pairing without a registered agent to answer its
    // authentication callbacks, and the Quickshell binding registers none — which
    // is exactly why pairing a new device previously only worked from bluetui.
    // bluetoothctl registers its own default agent for the life of the command.
    // Connect/disconnect/remove go the same route purely so their failure text
    // (br-connection-page-timeout etc.) can be shown instead of only logged.
    Process {
        id: btActionProc
        property string errText: ""
        stdout: StdioCollector { onStreamFinished: {
            // bluetoothctl reports failures on stdout and still exits 0, so the
            // exit code alone can't be trusted here.
            var m = (this.text || "").match(/Failed to [^\n]*/);
            btActionProc.errText = m ? m[0] : "";
        } }
        stderr: StdioCollector { onStreamFinished: {
            if (btActionProc.errText === "") btActionProc.errText = (this.text || "").trim();
        } }
        onExited: (code) => {
            root.btBusyPath = "";
            var err = code === 124 ? "Timed out — is the device on and in range?"
                                   : root.btFriendlyError(btActionProc.errText);
            root.btError = err;

            var next = root._btPairThenConnect;
            root._btPairThenConnect = "";
            if (code !== 0 || err !== "" || next === "") return;

            // Pairing landed. Discovery has done its job and an active scan is a
            // known cause of connection attempts aborting, so stop it now — the
            // device is persistent from here on — and connect.
            root.btSetScanning(false);
            for (var i = 0; i < root.btAllDevices.length; i++)
                if (root.btAllDevices[i].dbusPath === next) {
                    root._btBondCheckPath = next;
                    btBondCheck.restart();
                    root.btConnect(root.btAllDevices[i]);
                    return;
                }
        }
    }
    // BlueZ's raw errors say nothing about what to actually do — the common one
    // here, AuthenticationFailed, means the remote end refused the pairing,
    // which is almost always "it is not in pairing mode", not a fault on this
    // side. Translate the ones that have a real user action attached.
    function btFriendlyError(raw) {
        if (!raw || raw === "") return "";
        var e = String(raw);
        if (/Authentication(Failed|Rejected|Canceled)/.test(e))
            return "Device refused pairing — hold its pairing button until it flashes, then try again";
        if (/AuthenticationTimeout/.test(e))
            return "Pairing timed out — put the device in pairing mode and try again";
        if (/page-timeout|Host is down|ConnectionAttemptFailed/.test(e))
            return "Device not responding — is it on and in range?";
        if (/abort-by-local|Operation already in progress/.test(e))
            return "Connection interrupted — try again";
        if (/not available|Does Not Exist|NotAvailable/.test(e))
            return "Device is out of range — scan again";
        if (/resource busy|Busy/.test(e))
            return "Device busy — try again in a moment";
        if (/NotReady|Resource Not Ready/.test(e))
            return "Adapter not ready";
        return e.replace(/^Failed to \w+: */, "").replace(/^org\.bluez\.Error\./, "");
    }

    // `keepScanning` matters for pairing specifically: BlueZ discards a
    // temporary (discovered-but-unpaired) device almost as soon as discovery
    // stops, so stopping the scan first — as connect/disconnect want, to avoid
    // le-connection-abort-by-local — deletes the very device being paired out
    // from under the command. Paired devices are persistent and unaffected.
    // btBusyPath is also set *before* touching the scan, or the row would be
    // filtered out of btAvailable for the frame between the two.
    function btRun(cmd, dev, keepScanning) {
        root.btBusyPath = dev ? dev.dbusPath : "";
        if (!keepScanning) root.btSetScanning(false);
        root.btError = "";
        btActionProc.errText = "";
        btActionProc.running = false;       // a reassigned command is ignored while running
        btActionProc.command = ["sh", "-c", cmd];
        btActionProc.running = true;
    }

    // NB: never pass bluetoothctl's own --timeout here. It does not bound how
    // long the command waits — it keeps the process alive for the full period
    // regardless, so a pair that resolved instantly still pinned the row's
    // spinner for 45s under Quickshell's Process (measured: 45.05s with the
    // flag, 0.017s without). With no --timeout it exits the moment BlueZ
    // replies, so coreutils `timeout` provides the upper bound instead.
    // stdin is redirected from /dev/null because Process hands the child a
    // pipe it will never write to.
    function btCmd(seconds, args) {
        return "timeout " + seconds + " bluetoothctl " + args + " </dev/null 2>&1";
    }
    // `bluetoothctl connect` on an address BlueZ no longer knows does not fail —
    // it prints "not available" and then sits there until something kills it
    // (measured: exit 124 after the full timeout, versus pair/remove/trust which
    // all exit 1 immediately). A device can disappear from BlueZ's list between
    // being drawn and being clicked, so guard every action with an existence
    // check, which fails in ~6ms, and turn a 30s frozen spinner into an instant
    // and accurate "out of range".
    function btGuard(mac) {
        return root.btCmd(5, "info " + mac) + " >/dev/null || " +
               "{ echo 'Device is not available'; exit 1; }; ";
    }
    function btPair(dev) {
        if (!dev) return;
        var mac = root.shq(dev.address);
        // Pairing MUST go through an interactive bluetoothctl session, not the
        // `bluetoothctl pair <mac>` argv form. In non-interactive mode BlueZ
        // completes the pairing but the kernel is told store_hint 0, so no link
        // key is ever written to /var/lib/bluetooth — the device comes up
        // "Paired: yes, Bonded: no" and the pairing silently evaporates on the
        // next adapter power cycle or reboot. Known upstream, closed as not
        // planned: https://github.com/bluez/bluez/issues/748
        //
        // Feeding the same commands on stdin keeps bluetoothctl in interactive
        // mode, which sets store_hint 1 and persists the key. The poll is so
        // this takes as long as the pairing actually takes rather than a fixed
        // sleep, and so `trust` is not sent before pairing has landed.
        root._btPairThenConnect = dev.dbusPath;
        root.btRun(root.btGuard(mac) +
                   "M=" + mac + "; { " +
                   "echo 'agent NoInputNoOutput'; echo 'default-agent'; echo \"pair $M\"; " +
                   "for i in $(seq 1 40); do sleep 0.5; " +
                   "bluetoothctl info \"$M\" 2>/dev/null | grep -q 'Paired: yes' && break; done; " +
                   "echo \"trust $M\"; sleep 1; echo quit; } | timeout 60 bluetoothctl 2>&1",
                   dev, true);
    }

    function btConnect(dev) {
        if (!dev) return;
        var mac = root.shq(dev.address);
        root.btRun(root.btGuard(mac) + root.btCmd(25, "connect " + mac), dev);
    }
    function btDisconnect(dev) {
        if (!dev) return;
        root.btRun(root.btCmd(20, "disconnect " + root.shq(dev.address)), dev);
    }
    function btUnpair(dev) {
        if (!dev) return;
        root.btMenuPath = "";
        root.btRun(root.btCmd(15, "remove " + root.shq(dev.address)), dev);
    }
    function btRename(dev, newName) {
        if (!dev) return;
        var n = String(newName).trim();
        if (n !== "") dev.name = n;         // writable — sets BlueZ's Alias
        root.btRenamePath = "";
        root.btMenuPath = "";
    }

    // Left-click semantics: an unpaired device pairs (then trusts and connects),
    // a paired one toggles its connection.
    function btTap(dev) {
        if (!dev) return;
        if (dev.connected) root.btDisconnect(dev);
        else if (dev.paired || dev.bonded) root.btConnect(dev);
        else root.btPair(dev);
    }

    function btIsBusy(dev) {
        return dev && (root.btBusyPath === dev.dbusPath || dev.pairing
                       || dev.state === BluetoothDeviceState.Connecting
                       || dev.state === BluetoothDeviceState.Disconnecting);
    }

    // BlueZ's `icon` is a freedesktop icon name; map the ones that actually
    // turn up to nf-md glyphs rather than shipping a whole icon-theme lookup.
    function btIcon(dev) {
        var i = dev && dev.icon ? String(dev.icon).toLowerCase() : "";
        if (i.indexOf("headset") >= 0 || i.indexOf("headphone") >= 0) return root.g.headphones;
        if (i.indexOf("earbud") >= 0)   return root.g.earbuds;
        if (i.indexOf("speaker") >= 0 || i.indexOf("audio") >= 0) return root.g.speaker;
        if (i.indexOf("mouse") >= 0)    return root.g.mouse;
        if (i.indexOf("keyboard") >= 0) return root.g.keyboard;
        if (i.indexOf("phone") >= 0)    return root.g.phone;
        if (i.indexOf("computer") >= 0) return root.g.laptop;
        if (i.indexOf("watch") >= 0)    return root.g.watch;
        if (i.indexOf("printer") >= 0)  return root.g.printer;
        if (i.indexOf("camera") >= 0)   return root.g.camera;
        if (i.indexOf("gaming") >= 0 || i.indexOf("joypad") >= 0) return root.g.gamepad;
        return root.g.bt;
    }
    function btStateLabel(dev) {
        if (!dev) return "";
        if (dev.pairing) return "Pairing…";
        if (dev.state === BluetoothDeviceState.Connecting) return "Connecting…";
        if (dev.state === BluetoothDeviceState.Disconnecting) return "Disconnecting…";
        if (dev.connected) return "Connected";
        if (dev.paired || dev.bonded) return "Paired";
        return "";
    }

    //========================================================================//
    //  AUDIO  (Quickshell.Services.Pipewire)                                 //
    //========================================================================//
    readonly property var audSink:   Pipewire.defaultAudioSink
    readonly property var audSource: Pipewire.defaultAudioSource

    // `node.audio` is null for anything that isn't an audio node, which is what
    // keeps the V4L2 webcam out of the INPUT list; !isStream drops per-app
    // streams so only real devices are offered.
    readonly property var audSinks: {
        var o = [], n = Pipewire.nodes ? Pipewire.nodes.values : [];
        for (var i = 0; i < n.length; i++)
            if (n[i].isSink && !n[i].isStream && n[i].audio) o.push(n[i]);
        o.sort(function (a, b) { return root.audNodeLabel(a).localeCompare(root.audNodeLabel(b)); });
        return o;
    }
    readonly property var audSources: {
        var o = [], n = Pipewire.nodes ? Pipewire.nodes.values : [];
        for (var i = 0; i < n.length; i++)
            if (!n[i].isSink && !n[i].isStream && n[i].audio) o.push(n[i]);
        o.sort(function (a, b) { return root.audNodeLabel(a).localeCompare(root.audNodeLabel(b)); });
        return o;
    }

    // Quickshell only keeps a node's volume/mute properties live while some
    // PwObjectTracker is holding it — without this every row's volume would be
    // whatever it was at bind time. Track everything the panel can show.
    PwObjectTracker { objects: root.audSinks.concat(root.audSources) }

    readonly property int  audVol:      root.audSink   && root.audSink.audio   ? Math.round(root.audSink.audio.volume * 100) : 0
    readonly property bool audMuted:    root.audSink   && root.audSink.audio   ? root.audSink.audio.muted : false
    readonly property int  audMicVol:   root.audSource && root.audSource.audio ? Math.round(root.audSource.audio.volume * 100) : 0
    readonly property bool audMicMuted: root.audSource && root.audSource.audio ? root.audSource.audio.muted : false

    // Live mic level for the meter under the INPUT slider. Only enabled while
    // the panel is open — a peak monitor is a real pipewire stream.
    PwNodePeakMonitor {
        id: audMicPeak
        node: root.audVisible ? root.audSource : null
        enabled: root.audVisible && root.audSource !== null
    }

    function audNodeLabel(n) {
        if (!n) return "";
        if (n.nickname && n.nickname !== "") return n.nickname;
        if (n.description && n.description !== "") return n.description;
        return n.name || "";
    }
    // Guess a glyph from the node's own properties so the rows read like the
    // reference UI (speaker / headphones / hdmi / mic) instead of one icon.
    function audNodeIcon(n, isSink) {
        var s = ((root.audNodeLabel(n) || "") + " " + (n && n.name ? n.name : "")).toLowerCase();
        if (s.indexOf("hdmi") >= 0 || s.indexOf("displayport") >= 0) return root.g.hdmi;
        if (s.indexOf("headphone") >= 0 || s.indexOf("headset") >= 0) return root.g.headphones;
        if (s.indexOf("bluez") >= 0 || s.indexOf("bluetooth") >= 0)   return root.g.bt;
        return isSink ? root.g.speaker : root.g.mic;
    }
    function audSetSink(n)   { if (n) Pipewire.preferredDefaultAudioSink = n; }
    function audSetSource(n) { if (n) Pipewire.preferredDefaultAudioSource = n; }
    function audSetVol(n, pct) {
        if (!n || !n.audio) return;
        n.audio.volume = Math.max(0, Math.min(1.5, pct / 100));
    }

    function fmtDuration(seconds) {
        if (!seconds || seconds <= 0) return "—";
        var h = Math.floor(seconds / 3600);
        var m = Math.round((seconds % 3600) / 60);
        return h > 0 ? (h + "h " + m + "m") : (m + "m");
    }

    function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a); }
    function run(cmd) { Quickshell.execDetached(["sh", "-c", cmd]); }

    // Launches `cmd` pinned to whichever workspace is focused right now, via
    // Hyprland's exec_cmd window-rule (PID-tracked at spawn time) rather than
    // relying on it landing on "whatever's active when the window maps" —
    // that's what let wiremix/bluetui/impala sometimes pop up on a different
    // workspace than the one the user was actually on when they clicked.
    // Confirmed live: forcing { workspace = N } via hl.dsp.exec_cmd placed a
    // freshly spawned kitty window on workspace N even while a different
    // workspace was active at spawn time.
    function runOnCurrentWorkspace(cmd) {
        var ws = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : 1;
        root.run("hyprctl dispatch \"hl.dsp.exec_cmd('" + cmd + "', { workspace = " + ws + " })\"");
    }

    FileView {
        id: walColors
        path: root.homeDir + "/.cache/wal/colors-waybar.css"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            var css = walColors.text();
            var map = {};
            var re = /@define-color\s+([A-Za-z0-9_]+)\s+([^;]+);/g;
            var m;
            while ((m = re.exec(css)) !== null) { map[m[1]] = m[2].trim(); }
            root.palette = map;
        }
    }

    //========================================================================//
    //  NOTIFICATION BACKEND  (replaces the swaync daemon)                    //
    //========================================================================//
    // This owns org.freedesktop.Notifications. swaync MUST be disabled or it
    // will fight for the same D-Bus name (see the switch-over steps).
    NotificationServer {
        id: notifServer
        keepOnReload: false
        // advertise the same capabilities swaync did (config.json)
        bodySupported: true
        bodyMarkupSupported: true
        bodyImagesSupported: true
        imageSupported: true
        actionsSupported: true
        actionIconsSupported: true
        persistenceSupported: true      // notifications stay in the center as history
        inlineReplySupported: true      // config: notification-inline-replies

        // new notification -> show a transient popup (history is kept automatically
        // in trackedNotifications, mirroring swaync's control center).
        onNotification: (notif) => {
            notif.tracked = true;                       // keep in history
            if (root.dnd) return;                       // Do Not Disturb: no popup, history only
            var timeout = notif.urgency === NotificationUrgency.Critical ? root.tCritical
                        : notif.urgency === NotificationUrgency.Low      ? root.tLow
                        : root.tNormal;
            root.pushPopup(notif, timeout);
        }
    }

    // Do Not Disturb (toggled from the control center)
    property bool dnd: false

    // per-urgency popup timeouts, in ms (config.json: timeout / -low / -critical, seconds)
    readonly property int tNormal:   2000
    readonly property int tLow:      6000
    readonly property int tCritical: 1000

    // live popup list (separate from history). Reassigned so bindings update.
    property var popupList: []
    function pushPopup(n, ms) { popupList = popupList.concat([{ notif: n, ms: ms }]); }
    function dropPopup(n) { popupList = popupList.filter(function (e) { return e.notif !== n; }); }

    function clearAllNotifs() {
        var list = notifServer.trackedNotifications.values;
        for (var i = list.length - 1; i >= 0; i--) list[i].dismiss();
    }

    // active player for the control-center mpris widget (prefer one that's playing)
    readonly property var mprisPlayer: {
        var ps = Mpris.players.values;
        var first = null;
        for (var i = 0; i < ps.length; i++) {
            if (!first) first = ps[i];
            if (ps[i].isPlaying) return ps[i];
        }
        return first;
    }

    // ---- volume / backlight state for the control-center sliders -------------
    // polled only while the center is open; written on drag (reuses pactl/brightnessctl).
    property int volumePercent: 0
    property int brightPercent: 0
    Process {
        id: volRead
        command: ["bash", "-c", "pactl get-sink-volume @DEFAULT_SINK@ | awk '{print $5}' | tr -d '%' | head -1"]
        stdout: StdioCollector { onStreamFinished: {
            var v = parseInt((this.text || "").trim()); if (!isNaN(v)) root.volumePercent = v; } }
    }
    Process {
        id: brightRead
        command: ["bash", "-c", "echo $(( $(brightnessctl get) * 100 / $(brightnessctl max) ))"]
        stdout: StdioCollector { onStreamFinished: {
            var v = parseInt((this.text || "").trim()); if (!isNaN(v)) root.brightPercent = v; } }
    }
    Timer {
        interval: 500; repeat: true; running: root.ccVisible; triggeredOnStart: true
        onTriggered: { volRead.running = true; brightRead.running = true; }
    }

    //========================================================================//
    //  OSD BACKEND  (replaces swayosd)                                       //
    //========================================================================//
    // Triggered from your keybinds via `qs ipc call osd <volume|brightness|mic>`.
    // Each call reads the current value fresh (so it reflects the change the
    // keybind just made) and shows the pill for ~1.2s.
    property string osdMode: ""          // "volume" | "brightness" | "mic"
    property int  osdValue: 0
    property bool osdMuted: false
    property bool osdShown: false

    Timer { id: osdHideTimer; interval: 1200; onTriggered: root.osdShown = false }
    function osdPresent(mode) { root.osdMode = mode; root.osdShown = true; osdHideTimer.restart(); }

    Process {
        id: osdVolRead
        command: ["bash", "-c",
            "v=$(pactl get-sink-volume @DEFAULT_SINK@ | awk '{print $5}' | tr -d '%' | head -1); " +
            "m=$(pactl get-sink-mute @DEFAULT_SINK@ | grep -q yes && echo 1 || echo 0); echo \"$v|$m\""]
        stdout: StdioCollector { onStreamFinished: {
            var p = (this.text || "").trim().split("|");
            root.osdValue = Math.min(100, parseInt(p[0]) || 0);
            root.osdMuted = p[1] === "1";
            root.osdPresent("volume");
        } }
    }
    Process {
        id: osdBrightRead
        command: ["bash", "-c", "echo $(( $(brightnessctl get) * 100 / $(brightnessctl max) ))"]
        stdout: StdioCollector { onStreamFinished: {
            root.osdValue = parseInt((this.text || "").trim()) || 0;
            root.osdMuted = false;
            root.osdPresent("brightness");
        } }
    }
    Process {
        id: osdMicRead
        command: ["bash", "-c", "pactl get-source-mute @DEFAULT_SOURCE@ | grep -q yes && echo 1 || echo 0"]
        stdout: StdioCollector { onStreamFinished: {
            root.osdMuted = (this.text || "").trim() === "1";
            root.osdPresent("mic");
        } }
    }

    IpcHandler {
        target: "osd"
        function volume(): void { osdVolRead.running = true; }
        function brightness(): void { osdBrightRead.running = true; }
        function mic(): void { osdMicRead.running = true; }
    }

    //========================================================================//
    //  REUSABLE PIECES                                                       //
    //========================================================================//

    // Text label with the standard hover colour transition (0.3s ease).
    // Emits signals for the actions; wire them up per-module.
    component BarLabel: Text {
        id: lbl
        property color baseColor: root.col7
        property color hoverColor: root.col9
        property bool hoverable: true
        property string tip: ""                 // tooltip text ("" = none)
        signal leftClicked()
        signal rightClicked()
        signal scrolledUp()
        signal scrolledDown()

        font.family: root.fontFamily
        font.pixelSize: root.fontSize
        verticalAlignment: Text.AlignVCenter
        leftPadding: 5; rightPadding: 5          // style.css: padding 0 5px
        color: (hoverable && hover.hovered) ? hoverColor : baseColor
        Behavior on color { ColorAnimation { duration: 200; easing.type: Easing.InOutQuad } }

        HoverHandler { id: hover }
        MouseArea {
            anchors.fill: parent
            hoverEnabled: false
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onClicked: (e) => e.button === Qt.RightButton ? lbl.rightClicked() : lbl.leftClicked()
            onWheel: (w) => w.angleDelta.y > 0 ? lbl.scrolledUp() : lbl.scrolledDown()
        }

        Tooltip { target: lbl; text: lbl.tip; shown: hover.hovered && lbl.tip !== "" }
    }

    // Waybar-style tooltip: separate popup surface, styled like `tooltip{}`.
    component Tooltip: PopupWindow {
        id: ttip
        required property Item target
        property alias text: ttext.text
        property bool shown: false

        anchor.window: target ? target.QsWindow.window : null
        anchor.rect.x: target ? target.mapToItem(null, 0, 0).x + target.width / 2 - ttip.width / 2 : 0
        anchor.rect.y: target ? target.height + 6 : 0
        visible: shown && text !== ""
        implicitWidth: ttext.implicitWidth + 16
        implicitHeight: ttext.implicitHeight + 10
        color: "transparent"

        Rectangle {
            anchors.fill: parent
            radius: 8
            color: root.colBg                    // tooltip { background:@background }
            Text {
                id: ttext
                anchors.centerIn: parent
                color: root.col7                 // tooltip { color:@color7 }
                font.family: root.fontFamily
                font.pixelSize: root.fontSize
            }
        }
    }

    // An island (one of .modules-left / -center / -right)
    component Island: Rectangle {
        default property alias content: rowInner.data
        radius: 10                               // border-radius:10px
        color: root.alpha(root.colBg, 0.7)       // background: alpha(@background,.7)
        implicitWidth: rowInner.implicitWidth + 14   // padding:7px  (7*2)
        implicitHeight: rowInner.implicitHeight + 14

        // box-shadow: 0 0 2px rgba(0,0,0,.5)
        layer.enabled: true
        layer.effect: MultiEffect {
            shadowEnabled: true
            shadowBlur: 0.25
            shadowColor: Qt.rgba(0, 0, 0, 0.5)
            shadowVerticalOffset: 0
            shadowHorizontalOffset: 0
        }

        RowLayout {
            id: rowInner
            anchors.centerIn: parent
            spacing: 0
        }
    }

    // returns an image source for a notification (image, else themed app icon)
    function iconFor(n) {
        if (!n) return "";
        if (n.image && n.image !== "") return n.image;
        try { if (n.appIcon && n.appIcon !== "") return Quickshell.iconPath(n.appIcon, ""); } catch (e) {}
        return "";
    }

    // A notification card — used for both the floating popup and the history list.
    // Mirrors .notification in your style.css (bg, 1px border, radius 12, padding 10).
    component NotifCard: Rectangle {
        id: card
        property var notif
        signal closed()
        implicitHeight: cardRow.implicitHeight + 20
        radius: 12
        color: root.ncBg
        border.width: 2
        border.color: root.ncBorder

        RowLayout {
            id: cardRow
            anchors.fill: parent
            anchors.margins: 10                 // .notification-content { padding:10px }
            spacing: 10

            Image {
                source: root.iconFor(card.notif)
                visible: source != ""
                Layout.preferredWidth: visible ? 40 : 0    // notification-icon-size 40
                Layout.preferredHeight: 40
                Layout.alignment: Qt.AlignTop
                fillMode: Image.PreserveAspectCrop
                sourceSize.width: 40; sourceSize.height: 40
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2
                Text {
                    Layout.fillWidth: true
                    text: card.notif ? card.notif.summary : ""
                    color: root.ncText
                    font.family: root.ncFont
                    font.pixelSize: 15; font.weight: Font.Medium   // .summary 0.95rem/500
                    elide: Text.ElideRight
                }
                Text {
                    Layout.fillWidth: true
                    visible: card.notif && card.notif.body !== ""
                    text: card.notif ? card.notif.body : ""
                    color: root.ncText
                    font.family: root.ncFont
                    font.pixelSize: 13                              // .body 0.85rem
                    textFormat: Text.StyledText                     // pango-ish markup
                    wrapMode: Text.WordWrap
                    maximumLineCount: 5
                    elide: Text.ElideRight
                }
            }

            Text {                                                  // .close-button
                Layout.alignment: Qt.AlignTop
                text: "\u00d7"
                color: root.ncText
                font.pixelSize: 18
                MouseArea {
                    anchors.fill: parent; anchors.margins: -4
                    onClicked: { if (card.notif) card.notif.dismiss(); card.closed(); }
                }
            }
        }
    }

    // A media transport button (white glyph).
    component MediaBtn: Text {
        property string glyph
        signal clicked()
        text: glyph
        color: "white"
        font.family: root.ncFont
        font.pixelSize: 20
        MouseArea { anchors.fill: parent; anchors.margins: -6; onClicked: parent.clicked() }
    }

    // Circular album cover that spins while `spinning` is true (freezes when paused).
    component Vinyl: Item {
        id: v
        property string art: ""
        property bool spinning: false

        Item {
            id: disc
            anchors.fill: parent

            // circular album art (masked into a circle)
            Image {
                id: vLabel
                anchors.fill: parent
                source: v.art
                visible: false
                fillMode: Image.PreserveAspectCrop
                sourceSize.width: 300; sourceSize.height: 300
            }
            MultiEffect {
                anchors.fill: parent
                source: vLabel
                maskEnabled: true
                maskSource: vMask
                visible: v.art !== ""
            }
            Item {
                id: vMask
                anchors.fill: parent
                layer.enabled: true
                visible: false
                Rectangle { anchors.fill: parent; radius: width / 2; color: "black" }
            }

            // fallback when there's no cover art
            Rectangle {
                anchors.fill: parent
                radius: width / 2
                visible: v.art === ""
                color: "#3a3a3a"
                Text {
                    anchors.centerIn: parent
                    text: "\uf001"
                    color: Qt.rgba(1, 1, 1, 0.5)
                    font.family: root.ncFont
                    font.pixelSize: parent.width * 0.3
                }
            }

            // Keep the animation always running and pause it instead of stopping,
            // so resuming continues from the current angle (not back to 0).
            NumberAnimation on rotation {
                from: 0; to: 360
                duration: 10000
                loops: Animation.Infinite
                running: true
                paused: !v.spinning
            }
        }

        // static rim
        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: "transparent"
            border.color: "white"
            border.width: 1.5 
        }
    }

    // format seconds -> M:SS
    function fmtTime(s) {
        if (!s || s < 0) return "0:00";
        var m = Math.floor(s / 60); var sec = Math.floor(s % 60);
        return m + ":" + (sec < 10 ? "0" : "") + sec;
    }

    // Slider styled like your swaync trough/highlight (accent = @color9).
    // Custom slider (handles its own mouse events so nothing can swallow the drag).
    // Styled like your swaync trough/highlight (accent = @color9).
    component ThemedSlider: Item {
        id: sl
        property real from: 0
        property real to: 100
        property real value: 0
        property bool pressed: slMouse.pressed
        signal moved()

        implicitHeight: 18
        Layout.preferredHeight: 18

        function frac() { return (sl.to > sl.from) ? (sl.value - sl.from) / (sl.to - sl.from) : 0; }

        Rectangle {                                         // trough
            id: track
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width; height: 6; radius: 3
            color: root.alpha(root.col7, 0.2)
            Rectangle {                                     // highlight
                width: track.width * sl.frac(); height: parent.height
                radius: 3; color: root.ncAccent
            }
        }
        Rectangle {                                         // handle
            width: 16; height: 16; radius: 8; color: root.ncAccent
            anchors.verticalCenter: parent.verticalCenter
            x: (sl.width - width) * sl.frac()
        }
        MouseArea {
            id: slMouse
            anchors.fill: parent
            preventStealing: true
            function apply(mx) {
                var f = Math.max(0, Math.min(1, mx / sl.width));
                sl.value = sl.from + f * (sl.to - sl.from);
                sl.moved();
            }
            onPressed: (e) => apply(e.x)
            onPositionChanged: (e) => { if (pressed) apply(e.x); }
        }
    }

    // Small round nav button for the calendar header (prev/next month/year).
    component CalNavBtn: Rectangle {
        id: navBtn
        signal clicked()
        property string glyph: ""
        Layout.preferredWidth: 28
        Layout.preferredHeight: 28
        radius: 10
        color: navHover.hovered ? root.alpha(root.ncAccent, 0.2) : "transparent"
        HoverHandler { id: navHover }
        Text {
            anchors.centerIn: parent
            text: navBtn.glyph
            color: root.ncText
            font.family: root.ncFont
            font.pixelSize: 13
        }
        MouseArea { anchors.fill: parent; onClicked: navBtn.clicked() }
    }


    //---- shared chrome for the wifi / bluetooth / audio dropdowns ----------
    // All three reuse the battery panel's visual language: rounded boxes with
    // a 1.5px ncText-tinted border, ncAccent for the "on"/selected state.

    // Pill switch. Rounded-rect (not a circle) so it sits in the same family
    // as the battery panel's cap buttons rather than looking like a stray
    // Material control.
    component ThemedToggle: Rectangle {
        id: tog
        property bool checked: false
        signal toggled(bool value)

        implicitWidth: 46
        implicitHeight: 26
        radius: 9
        color: tog.checked ? root.ncAccent
               : (togHover.hovered ? root.alpha(root.col7, 0.18) : root.alpha(root.col7, 0.08))
        border.width: 1.5
        border.color: root.alpha(root.ncText, tog.checked ? 0.9 : 0.5)
        Behavior on color { ColorAnimation { duration: 160 } }

        HoverHandler { id: togHover }

        Rectangle {
            width: tog.height - 9
            height: width
            radius: 6
            y: 4.5
            x: tog.checked ? tog.width - width - 4.5 : 4.5
            color: tog.checked ? root.contrastText(root.ncAccent) : root.alpha(root.ncText, 0.8)
            Behavior on x { NumberAnimation { duration: 170; easing.type: Easing.OutCubic } }
            Behavior on color { ColorAnimation { duration: 160 } }
        }
        MouseArea { anchors.fill: parent; onClicked: tog.toggled(!tog.checked) }
    }

    // Square icon button — the "advanced settings" affordance in each panel
    // header, which hands off to the TUI that owns the domain for real
    // (impala / bluetui / wiremix).
    component PanelIconBtn: Rectangle {
        id: pib
        property string glyph: ""
        property bool spinning: false
        signal clicked()

        implicitWidth: 30
        implicitHeight: 26
        radius: 9
        color: pibHover.hovered ? root.alpha(root.ncAccent, 0.28) : root.alpha(root.col7, 0.08)
        border.width: 1.5
        border.color: root.alpha(root.ncText, 0.6)
        Behavior on color { ColorAnimation { duration: 160 } }

        HoverHandler { id: pibHover }
        Text {
            id: pibIcon
            anchors.centerIn: parent
            text: pib.glyph
            color: root.ncText
            font.family: root.ncFont
            font.pixelSize: 14
            RotationAnimation on rotation {
                running: pib.spinning
                from: 0; to: 360
                duration: 1200
                loops: Animation.Infinite
            }
        }
        onSpinningChanged: if (!pib.spinning) pibIcon.rotation = 0
        MouseArea { anchors.fill: parent; onClicked: pib.clicked() }
    }

    // Small labelled button used by the bluetooth device context menu.
    component PanelTextBtn: Rectangle {
        id: ptb
        property string label: ""
        property bool accent: false
        signal clicked()

        Layout.fillWidth: true
        Layout.preferredHeight: 30
        radius: 10
        color: ptb.accent ? root.ncAccent
               : (ptbHover.hovered ? root.alpha(root.col7, 0.18) : root.alpha(root.col7, 0.08))
        border.width: 1.5
        border.color: root.alpha(root.ncText, ptb.accent ? 0.9 : 0.6)
        HoverHandler { id: ptbHover }
        Text {
            anchors.centerIn: parent
            text: ptb.label
            color: ptb.accent ? root.contrastText(root.ncAccent) : root.ncText
            font.family: root.ncFont
            font.pixelSize: 12
            font.weight: ptb.accent ? Font.DemiBold : Font.Normal
        }
        MouseArea { anchors.fill: parent; onClicked: ptb.clicked() }
    }

    // "KNOWN NETWORKS" / "OUTPUT" / "PAIRED" — the small all-caps section caption.
    component SectionLabel: Text {
        color: root.alpha(root.ncText, 0.5)
        font.family: root.ncFont
        font.pixelSize: 10
        font.weight: Font.DemiBold
    }

    component PanelDivider: Rectangle {
        Layout.fillWidth: true
        implicitHeight: 1
        color: root.alpha(root.ncText, 0.18)
    }

    // One selectable row in a list (a network, a bluetooth device, an audio
    // device). `active` is the selected/connected state, `busy` swaps the
    // trailing slot for a spinner while an action is in flight.
    component PanelRow: Rectangle {
        id: prow
        property string glyph: ""
        property string label: ""
        property string sub: ""
        property string trailGlyph: ""
        property string trailText: ""
        property bool active: false
        property bool busy: false
        property bool hovered: rowHover.hovered
        signal clicked()
        signal rightClicked()

        Layout.fillWidth: true
        implicitHeight: prow.sub !== "" ? 52 : 38
        radius: 10
        // Solid accent fill when selected, matching the battery panel's active
        // charge-limit button — not a low-alpha wash over the background.
        color: prow.active ? root.ncAccent
               : (rowHover.hovered ? root.alpha(root.col7, 0.16) : root.alpha(root.col7, 0.05))
        readonly property color fg: prow.active ? root.contrastText(root.ncAccent) : root.ncText
        border.width: 1.5
        border.color: root.alpha(root.ncText, prow.active ? 0.85 : 0.32)
        Behavior on color { ColorAnimation { duration: 140 } }

        HoverHandler { id: rowHover }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 10
            anchors.rightMargin: 10
            spacing: 9

            Text {
                text: prow.glyph
                color: prow.fg
                font.family: root.ncFont
                font.pixelSize: 15
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 4
                Text {
                    Layout.fillWidth: true
                    text: prow.label
                    color: prow.fg
                    font.family: root.ncFont
                    font.pixelSize: 13
                    font.weight: prow.active ? Font.DemiBold : Font.Normal
                    elide: Text.ElideRight
                }
                Text {
                    Layout.fillWidth: true
                    visible: prow.sub !== ""
                    text: prow.sub
                    color: prow.active ? root.alpha(prow.fg, 0.75) : root.alpha(root.ncText, 0.55)
                    font.family: root.ncFont
                    font.pixelSize: 11
                    elide: Text.ElideRight
                }
            }
            Text {
                visible: prow.trailText !== "" && !prow.busy
                text: prow.trailText
                color: prow.active ? root.alpha(prow.fg, 0.8) : root.alpha(root.ncText, 0.65)
                font.family: root.ncFont
                font.pixelSize: 13
            }
            Text {
                visible: prow.trailGlyph !== "" && !prow.busy
                text: prow.trailGlyph
                color: prow.active ? prow.fg : root.alpha(root.ncText, 0.6)
                font.family: root.ncFont
                font.pixelSize: 13
            }
            Text {                                   // in-flight spinner
                visible: prow.busy
                text: root.g.loading
                color: prow.fg
                font.family: root.ncFont
                font.pixelSize: 14
                RotationAnimation on rotation {
                    running: prow.busy
                    from: 0; to: 360
                    duration: 900
                    loops: Animation.Infinite
                }
            }
        }

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onClicked: (e) => e.button === Qt.RightButton ? prow.rightClicked() : prow.clicked()
        }
    }

    // One wi-fi network: the row, plus the password prompt that expands beneath
    // it when a new secured network is tapped (same pattern as the bluetooth
    // device menu — the whole connect flow stays inside the panel).
    component WifiNetworkRow: ColumnLayout {
        id: wnr
        property var net: null
        readonly property string ssid: wnr.net ? wnr.net.ssid : ""
        readonly property bool prompting: wnr.ssid !== "" && root.wifiPromptSsid === wnr.ssid
        readonly property bool menuOpen: wnr.ssid !== "" && root.wifiMenuSsid === wnr.ssid

        Layout.fillWidth: true
        spacing: 6

        PanelRow {
            glyph: root.wifiIcon(wnr.net ? wnr.net.signal : 0)
            label: wnr.ssid
            sub: (wnr.net && wnr.net.active) ? "Connected" : ""
            active: wnr.net && wnr.net.active
            busy: root.wifiBusySsid === wnr.ssid
            trailText: (wnr.net ? wnr.net.signal : 0) + "%"
            trailGlyph: (wnr.net && wnr.net.secure) ? root.g.lock : ""
            onClicked: {
                if (!wnr.net) return;
                root.wifiMenuSsid = ""; root.wifiPwSsid = ""; root.wifiPwText = "";
                if (wnr.net.active) { root.wifiDisconnect(); return; }
                // A saved profile already holds the PSK, so only a brand-new
                // secured network needs to ask for one.
                if (wnr.net.secure && !wnr.net.known) root.wifiPromptSsid = wnr.ssid;
                else root.wifiConnect(wnr.ssid, "");
            }
            // Only saved networks have anything to offer here — there is no
            // password to reveal and nothing to forget for an unknown one.
            onRightClicked: {
                if (!wnr.net || !wnr.net.known) return;
                root.wifiPwSsid = ""; root.wifiPwText = "";
                root.wifiMenuSsid = wnr.menuOpen ? "" : wnr.ssid;
            }
        }

        // ---------- context menu ----------
        RowLayout {
            Layout.fillWidth: true
            Layout.bottomMargin: 4
            spacing: 8
            visible: wnr.menuOpen

            PanelTextBtn { label: "Forget"; onClicked: root.wifiForget(wnr.ssid) }
            PanelTextBtn {
                label: root.wifiPwSsid === wnr.ssid ? "Hide Password" : "Show Password"
                onClicked: root.wifiTogglePassword(wnr.ssid)
            }
        }

        // ---------- revealed password (selectable, so it can be copied) ------
        Rectangle {
            Layout.fillWidth: true
            Layout.bottomMargin: 4
            implicitHeight: 34
            radius: 10
            color: root.alpha(root.col7, 0.08)
            border.width: 1.5
            border.color: root.alpha(root.ncText, 0.5)
            visible: wnr.menuOpen && root.wifiPwSsid === wnr.ssid

            TextInput {
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 10
                verticalAlignment: TextInput.AlignVCenter
                text: root.wifiPwText
                readOnly: true
                selectByMouse: true
                color: root.ncText
                selectionColor: root.alpha(root.ncAccent, 0.6)
                font.family: root.ncFont
                font.pixelSize: 13
                clip: true
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.bottomMargin: 4
            spacing: 6
            visible: wnr.prompting

            Rectangle {
                Layout.fillWidth: true
                implicitHeight: 34
                radius: 10
                color: root.alpha(root.col7, 0.08)
                border.width: 1.5
                border.color: root.alpha(root.ncText, pwField.activeFocus ? 0.85 : 0.5)

                TextInput {
                    id: pwField
                    anchors.fill: parent
                    anchors.leftMargin: 10
                    anchors.rightMargin: 10
                    verticalAlignment: TextInput.AlignVCenter
                    echoMode: TextInput.Password
                    passwordCharacter: "•"
                    color: root.ncText
                    selectionColor: root.alpha(root.ncAccent, 0.6)
                    font.family: root.ncFont
                    font.pixelSize: 13
                    clip: true
                    focus: true
                    onAccepted: root.wifiConnect(wnr.ssid, pwField.text)
                    Keys.onEscapePressed: root.wifiPromptSsid = ""
                    // Created hidden and only shown on the tap, so the focus
                    // grab belongs on that transition; the retry covers the
                    // frame where the surface has not taken the keyboard yet.
                    onVisibleChanged: if (visible) { pwField.text = ""; pwField.forceActiveFocus(); pwFocusRetry.restart(); }
                    Timer {
                        id: pwFocusRetry
                        interval: 60
                        onTriggered: if (pwField.visible && !pwField.activeFocus) pwField.forceActiveFocus()
                    }
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    x: 10
                    width: parent.width - 20
                    visible: pwField.text === ""
                    text: "Password for " + wnr.ssid
                    color: root.alpha(root.ncText, 0.35)
                    font.family: root.ncFont
                    font.pixelSize: 13
                    elide: Text.ElideRight
                }
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                PanelTextBtn { label: "Cancel"; onClicked: root.wifiPromptSsid = "" }
                PanelTextBtn { label: "Connect"; accent: true; onClicked: root.wifiConnect(wnr.ssid, pwField.text) }
            }
        }
    }

    // One bluetooth device: the row itself plus its right-click context menu and
    // inline rename field, which expand underneath it (same pattern as the
    // wifi password prompt) rather than opening a floating menu window.
    component BtDeviceRow: ColumnLayout {
        id: bdr
        property var dev: null
        readonly property string path: bdr.dev ? bdr.dev.dbusPath : ""
        readonly property bool isPaired: bdr.dev && (bdr.dev.paired || bdr.dev.bonded)
        readonly property bool menuOpen: bdr.path !== "" && root.btMenuPath === bdr.path
        readonly property bool renaming: bdr.path !== "" && root.btRenamePath === bdr.path

        Layout.fillWidth: true
        spacing: 6

        PanelRow {
            glyph: root.btIcon(bdr.dev)
            label: root.btLabel(bdr.dev)
            sub: root.btStateLabel(bdr.dev)
            active: bdr.dev && bdr.dev.connected
            busy: root.btIsBusy(bdr.dev)
            // Peripherals that report battery over BlueZ (headphones, mice)
            // show it right here, so checking never needs another app.
            trailText: (bdr.dev && bdr.dev.batteryAvailable) ? Math.round(bdr.dev.battery * 100) + "%" : ""
            trailGlyph: (bdr.dev && bdr.dev.batteryAvailable) ? root.g.battery : ""
            onClicked: { root.btMenuPath = ""; root.btRenamePath = ""; root.btTap(bdr.dev); }
            onRightClicked: {
                root.btRenamePath = "";
                root.btMenuPath = bdr.menuOpen ? "" : bdr.path;
            }
        }

        // ---------- context menu ----------
        RowLayout {
            Layout.fillWidth: true
            Layout.bottomMargin: 4
            spacing: 8
            visible: bdr.menuOpen && !bdr.renaming

            PanelTextBtn {
                label: "Rename"
                onClicked: root.btRenamePath = bdr.path
            }
            PanelTextBtn {
                // Forget purges BlueZ's record of a device it knows but is not
                // paired with — the stale Trusted-without-a-link-key state that
                // can block re-pairing. Left as a deliberate action rather than
                // something pairing does silently.
                label: bdr.isPaired ? "Unpair" : "Forget"
                onClicked: root.btUnpair(bdr.dev)
            }
        }

        // ---------- inline rename ----------
        ColumnLayout {
            Layout.fillWidth: true
            Layout.bottomMargin: 4
            spacing: 6
            visible: bdr.renaming

            Rectangle {
                Layout.fillWidth: true
                implicitHeight: 34
                radius: 10
                color: root.alpha(root.col7, 0.08)
                border.width: 1.5
                border.color: root.alpha(root.ncText, nameField.activeFocus ? 0.85 : 0.5)

                TextInput {
                    id: nameField
                    anchors.fill: parent
                    anchors.leftMargin: 10
                    anchors.rightMargin: 10
                    verticalAlignment: TextInput.AlignVCenter
                    color: root.ncText
                    selectionColor: root.alpha(root.ncAccent, 0.6)
                    font.family: root.ncFont
                    font.pixelSize: 13
                    clip: true
                    focus: true
                    onAccepted: root.btRename(bdr.dev, nameField.text)
                    Keys.onEscapePressed: root.btRenamePath = ""
                    // Created hidden and only shown on the menu action, so the
                    // focus grab belongs on that transition. The retry covers
                    // the frame where the surface has not taken the keyboard yet.
                    onVisibleChanged: if (visible) {
                        nameField.text = root.btLabel(bdr.dev);
                        nameField.selectAll();
                        nameField.forceActiveFocus();
                        nameFocusRetry.restart();
                    }
                    Timer {
                        id: nameFocusRetry
                        interval: 60
                        onTriggered: if (nameField.visible && !nameField.activeFocus) nameField.forceActiveFocus()
                    }
                }
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                PanelTextBtn { label: "Cancel"; onClicked: root.btRenamePath = "" }
                PanelTextBtn { label: "Save"; accent: true; onClicked: root.btRename(bdr.dev, nameField.text) }
            }
        }
    }

    // label / value pair used by the wifi stats grid
    component InfoCell: RowLayout {
        id: ic
        property string label: ""
        property string value: ""
        Layout.fillWidth: true
        spacing: 6
        Text {
            text: ic.label
            color: root.alpha(root.ncText, 0.5)
            font.family: root.ncFont
            font.pixelSize: 12
        }
        Item { Layout.fillWidth: true }
        Text {
            text: ic.value
            color: root.ncText
            font.family: root.ncFont
            font.pixelSize: 12
            font.weight: Font.Medium
        }
    }

    //========================================================================//
    //  THE BAR (one per monitor)                                             //
    //========================================================================//
    Variants {
        model: Quickshell.screens
        delegate: PanelWindow {
            id: bar
            required property var modelData
            screen: modelData

            color: "transparent"                 // window#waybar { all:unset }
            anchors { top: true; left: true; right: true }
            implicitHeight: 44
            exclusiveZone: 44                    // waybar "exclusive": true

            //--------------------------------------------------------------//
            //  LEFT ISLAND : custom/notification , hyprland/workspaces      //
            //--------------------------------------------------------------//
            Island {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: 5            // margin:5px

                // custom/notification  →  "󰣇"  →  toggles the Quickshell control center
                BarLabel {
                    text: "󰣇"
                    onLeftClicked: root.togglePanel("cc")
                }

                // hyprland/workspaces  (persistent 1..4, click to activate)
                Row {
                    id: wsRow
                    Layout.alignment: Qt.AlignVCenter
                    leftPadding: 5; rightPadding: 5     // #workspaces { padding:0 5px }

                    // union of persistent {1,2,3,4} and any live workspace ids
                    property var ids: {
                        var base = [1, 2, 3, 4];
                        var live = Hyprland.workspaces.values.map(w => w.id);
                        for (var i = 0; i < live.length; i++)
                            if (live[i] > 0 && base.indexOf(live[i]) === -1) base.push(live[i]);
                        return base.sort((a, b) => a - b);
                    }

                    Repeater {
                        model: wsRow.ids
                        delegate: Text {
                            required property var modelData
                            property var hws: Hyprland.workspaces.values.find(w => w.id === modelData)
                            property bool isActive: Hyprland.focusedWorkspace
                                                    && Hyprland.focusedWorkspace.id === modelData
                            property bool isEmpty: hws === undefined      // not tracked => no windows

                            text: modelData                              // format-icons map number->number
                            font.family: root.fontFamily
                            font.pixelSize: root.fontSize
                            leftPadding: 6; rightPadding: 6              // button padding-left/right:3px
                            verticalAlignment: Text.AlignVCenter

                            // active -> @color7 ; empty -> transparent-ish ; else -> @text
                            color: isActive ? root.col7
                                   : (isEmpty ? Qt.rgba(0, 0, 0, 0.2) : root.colText)
                            Behavior on color { ColorAnimation { duration: 100; easing.type: Easing.InOutQuad } }

                            MouseArea {
                                anchors.fill: parent
                                // Hyprland.dispatch() sends a raw "workspace N" style string over
                                // the IPC socket, which used the same positional dispatcher syntax
                                // hyprctl dispatch used pre-0.55. That protocol now expects a Lua
                                // expression (hl.dsp...), so route this through hyprctl instead of
                                // relying on Quickshell's own (unverified against 0.55) dispatch call.
                                onClicked: root.run("hyprctl dispatch \"hl.dsp.focus({ workspace = " + parent.modelData + " })\"")
                            }
                        }
                    }
                }

                // focused window (macOS-style) — the currently focused app, e.g. "[ kitty ]"
                // ToplevelManager.activeToplevel comes from Quickshell.Wayland (already imported).
                BarLabel {
                    property var toplevel: ToplevelManager.activeToplevel
                    property string appName: {
                        if (!toplevel || !toplevel.appId) return "";
                        var id = toplevel.appId;
                        // Chrome/Chromium/Brave webapps (appId like "chrome-claude.ai__new-Default"):
                        // match the .desktop file by its StartupWMClass and show its Name ("Claude").
                        // "__" is the tell-tale sign of a browser webapp window, so normal apps
                        // (kitty, org.gnome.Text-Editor, ...) skip this and keep the cleaned name below.
                        if (id.indexOf("__") !== -1) {
                            var entry = DesktopEntries.heuristicLookup(id);
                            if (entry && entry.name) return entry.name;
                        }
                        // Everything else: clean reverse-DNS ids, e.g. org.gnome.Text-Editor -> text-editor
                        var parts = id.split(".");
                        return parts[parts.length - 1].toLowerCase();
                    }
                    hoverable: false
                    baseColor: root.col7
                    visible: appName !== ""       // hides when nothing is focused (empty workspace)
                    text: "[ " + appName + " ]"
                }
            }

            //--------------------------------------------------------------//
            //  CENTER ISLAND : clock , mpris                                //
            //--------------------------------------------------------------//
            Island {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter

                // clock  →  {:%a %d %B | %I:%M %p}  →  click: dropdown calendar
                BarLabel {
                    // %a=ddd  %d=dd  %B=MMMM  %I=hh(12h w/ AP)  %M=mm  %p=AP
                    text: Qt.formatDateTime(clock.date, "ddd dd MMMM | hh:mm AP")
                    onLeftClicked: {
                        if (!root.calVisible) {
                            // always reopen on the current month, not wherever
                            // a previous session left month-nav pointed
                            var d = new Date();
                            root.calYear = d.getFullYear();
                            root.calMonth = d.getMonth();
                        }
                        root.togglePanel("cal");
                    }
                    SystemClock { id: clock; precision: SystemClock.Seconds }
                }

                // mpris  (spotify)  →  "[   {status_icon} | {dynamic} ]"
                BarLabel {
                    id: mpris
                    // pick the spotify player
                    property var player: {
                        var ps = Mpris.players.values;
                        for (var i = 0; i < ps.length; i++) {
                            var name = (ps[i].identity || "") + " " + (ps[i].dbusName || "");
                            if (name.toLowerCase().indexOf("spotify") !== -1) return ps[i];
                        }
                        return null;
                    }
                    property int st: player ? player.playbackState : MprisPlaybackState.Stopped
                    // status-icons from your config: playing=\uf04c paused=\uf04b stopped=\uf04d
                    property string statusIcon: st === MprisPlaybackState.Playing ? "\uf04c"
                                              : st === MprisPlaybackState.Paused  ? "\uf04b" : "\uf04d"
                    property string title: player ? (player.trackTitle || "").substring(0, 50) : ""

                    // hidden when no player / stopped  (format-stopped / -disconnected = "")
                    visible: player !== null && st !== MprisPlaybackState.Stopped
                    // format: "[ \uf001  {status_icon} | {dynamic} ]"  (\uf001 = music note)
                    text: "[ \uf001  " + statusIcon + " | " + title + " ]"
                    // left-click = play/pause (waybar mpris default), right-click = next
                    onLeftClicked: if (player) player.isPlaying = !player.isPlaying
                    onRightClicked: if (player && player.canGoNext) player.next()
                }
            }

            //--------------------------------------------------------------//
            //  RIGHT ISLAND : group/expand , bluetooth , network , battery //
            //--------------------------------------------------------------//
            Island {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.rightMargin: 5

                //=== group/expand : hover reveals volume+brightness (600ms) ===
                // transition-to-left: revealed items slide out to the LEFT of
                // the  handle. click-to-reveal:false => reveal on hover.
                Item {
                    id: expandGroup
                    implicitHeight: expandInner.implicitHeight
                    implicitWidth: expandInner.implicitWidth
                    property bool expanded: grpHover.hovered
                    HoverHandler { id: grpHover }

                    RowLayout {
                        id: expandInner
                        spacing: 0

                        // ---- drawer (hidden until hover) ----
                        Item {
                            id: drawer
                            clip: true
                            implicitHeight: drawerRow.implicitHeight
                            Layout.preferredWidth: expandGroup.expanded ? drawerRow.implicitWidth : 0
                            opacity: expandGroup.expanded ? 1 : 0
                            Behavior on Layout.preferredWidth { NumberAnimation { duration: 600; easing.type: Easing.OutCubic } }
                            Behavior on opacity { NumberAnimation { duration: 600; easing.type: Easing.OutCubic } }

                            RowLayout {
                                id: drawerRow
                                anchors.right: parent.right   // grow leftward from the handle
                                spacing: 0

                                // custom/volume  (reuses volume.sh + your pactl cmds)
                                BarLabel {
                                    id: volWidget
                                    property string icon: ""
                                    text: icon
                                    tip: volTip
                                    property string volTip: ""
                                    // click -> audio panel ; right-click -> mute ; scroll -> volume
                                    // (wiremix moved to the panel's gear button)
                                    onLeftClicked:   root.togglePanel("aud")
                                    onRightClicked:  root.run("pactl set-sink-mute @DEFAULT_SINK@ toggle")
                                    onScrolledUp:    root.run("pactl set-sink-volume @DEFAULT_SINK@ +5%")
                                    onScrolledDown:  root.run("pactl set-sink-volume @DEFAULT_SINK@ -5%")

                                    // read volume + mute inline (no external volume.sh dependency)
                                    Process {
                                        id: volProc
                                        command: ["bash", "-c",
                                            "v=$(pactl get-sink-volume @DEFAULT_SINK@ | awk '{print $5}' | tr -d '%' | head -1); " +
                                            "m=$(pactl get-sink-mute @DEFAULT_SINK@ | grep -q yes && echo 1 || echo 0); echo \"$v|$m\""]
                                        stdout: StdioCollector {
                                            onStreamFinished: {
                                                var p = (this.text || "").trim().split("|");
                                                var muted = p[1] === "1";
                                                volWidget.icon = muted ? "\uf026" : "\uf028";   //  /
                                                volWidget.volTip = muted ? "Muted"
                                                    : ("Volume: " + Math.min(100, parseInt(p[0]) || 0) + "%");
                                            }
                                        }
                                    }
                                    Timer { interval: 1000; running: true; repeat: true; triggeredOnStart: true
                                            onTriggered: volProc.running = true }
                                }

                                // custom/brightness (format is literal 󰃠; tooltip from brightness.sh)
                                BarLabel {
                                    id: brightness
                                    text: "󰃠"
                                    tip: brTip
                                    property string brTip: ""
                                    onScrolledUp:   root.run("brightnessctl set +5%")
                                    onScrolledDown: root.run("brightnessctl set 5%-")

                                    // read brightness inline (no external brightness.sh dependency)
                                    Process {
                                        id: brProc
                                        command: ["bash", "-c", "echo $(( $(brightnessctl get) * 100 / $(brightnessctl max) ))"]
                                        stdout: StdioCollector {
                                            onStreamFinished: {
                                                brightness.brTip = "Brightness: " + (parseInt((this.text || "").trim()) || 0) + "%";
                                            }
                                        }
                                    }
                                    Timer { interval: 1000; running: true; repeat: true; triggeredOnStart: true
                                            onTriggered: brProc.running = true }
                                }

                                // custom/endpoint : the subtle "|" divider
                                // (#custom-endpoint: color transparent + dark text-shadow)
                                Text {
                                    text: "|"
                                    font.family: root.fontFamily
                                    font.pixelSize: root.fontSize
                                    verticalAlignment: Text.AlignVCenter
                                    color: "#FFFFFF"
                                    styleColor: Qt.rgba(0, 0, 0, 1)
                                }
                            }
                        }

                        // ---- handle : custom/expand  "" ----
                        // #custom-expand: color alpha(@foreground,.2); hover: white .2
                        BarLabel {
                            text: ""
                            hoverable: false
                            color: grpHover.hovered ? Qt.rgba(1, 1, 1, 0.2) : root.alpha(root.colFg, 0.2)
                            styleColor: grpHover.hovered ? Qt.rgba(1, 1, 1, 0.5) : Qt.rgba(0, 0, 0, 0.7)
                            style: Text.Outline
                            Behavior on color { ColorAnimation { duration: 300 } }
                        }
                    }
                }

                //=== bluetooth =================================================
                // format:"󰂯"  format-disabled:" 󰂲"  format-connected:"{alias} 󰂯"
                BarLabel {
                    id: bt
                    // VERIFY: Bluetooth.defaultAdapter / .enabled, device.connected / .name
                    property var adapter: Bluetooth.defaultAdapter
                    property bool btOn: adapter ? adapter.enabled : false
                    property var connDev: {
                        var ds = Bluetooth.devices ? Bluetooth.devices.values : [];
                        for (var i = 0; i < ds.length; i++) if (ds[i].connected) return ds[i];
                        return null;
                    }
                    text: !btOn ? " 󰂲"
                          : connDev ? (connDev.name + " 󰂯")
                          : "󰂯"
                    onLeftClicked: root.togglePanel("bt")
                    onRightClicked: root.runOnCurrentWorkspace("kitty --title bluetui zsh -i -c bluetui")
                }

                //=== network ==================================================
                // format-wifi:"\uf1eb"  format-ethernet:"\uef09"  format-disconnected:"\ueb01"
                // Detected by reading /sys/class/net so it works with iwd (impala),
                // NetworkManager, or anything else — no dependency on a specific stack.
                BarLabel {
                    id: net
                    // NB: 'state' and 'signal' are reserved in QML, so use safe names.
                    property string netState: "disconnected"   // "wifi" | "ethernet" | "disconnected"
                    property string essid: ""
                    property string signalPct: ""

                    text: netState === "wifi" ? "\uf1eb"
                          : netState === "ethernet" ? "\uef09" : "\ueb01"

                    onLeftClicked: root.togglePanel("net")
                    onRightClicked: root.runOnCurrentWorkspace("kitty --title impala zsh -i -c impala")

                    Process {
                        id: netProc
                        command: ["bash", "-c",
                            "for i in /sys/class/net/*; do ifc=${i##*/}; [ \"$ifc\" = lo ] && continue; " +
                            "[ \"$(cat \"$i/operstate\" 2>/dev/null)\" = up ] || continue; " +
                            "if [ -d \"$i/wireless\" ] || [ -e \"$i/phy80211\" ]; then " +
                            "  e=$(nmcli -t -f active,ssid dev wifi 2>/dev/null | awk -F: '$1==\"yes\"{print $2; exit}'); " +
                            "  q=$(awk -v d=\"$ifc:\" '$1==d{s=$3;sub(/\\./,\"\",s);print int(s*100/70)}' /proc/net/wireless 2>/dev/null); " +
                            "  echo \"wifi|$e|$q\"; exit 0; " +
                            "fi; echo \"ethernet|$ifc|\"; exit 0; done; echo 'disconnected||'"]
                        stdout: StdioCollector {
                            onStreamFinished: {
                                var parts = (this.text || "").trim().split("|");
                                net.netState  = parts[0] || "disconnected";
                                net.essid     = parts[1] || "";
                                net.signalPct = parts[2] || "";
                            }
                        }
                    }
                    Timer { interval: 3000; running: true; repeat: true; triggeredOnStart: true
                            onTriggered: netProc.running = true }
                }

                //=== battery ==================================================
                BarLabel {
                    id: battery
                    property int cap: root.batCap
                    property bool charging: root.batCharging
                    property var icons: ["󰁻", "󰁼", "󰁾", "󰂀", "󰂂", "󰁹"]
                    property string icon: icons[Math.min(icons.length - 1, Math.max(0, Math.floor(cap / (100 / icons.length))))]

                    // format:"{capacity}% {icon}"  format-charging:"{capacity}% 󰂄"
                    text: charging ? (cap + "% 󰂄") : (cap + "% " + icon)
                    baseColor: charging ? root.colCharging
                               : cap <= 20 ? root.colCritical
                               : cap <= 30 ? root.colWarning
                               : root.col7

                    onLeftClicked: root.togglePanel("bat")

                    // #battery.critical:not(.charging) blink (0.5s alternate)
                    property bool critical: cap <= 20 && !charging
                    SequentialAnimation on opacity {
                        running: battery.critical
                        loops: Animation.Infinite
                        NumberAnimation { from: 1.0; to: 0.3; duration: 500 }
                        NumberAnimation { from: 0.3; to: 1.0; duration: 500 }
                    }
                    // Reset on the critical->false transition itself, not on
                    // opacity changes — the animation's `running: critical`
                    // binding just freezes opacity wherever it was mid-fade
                    // when critical flips false, and that freeze doesn't
                    // necessarily fire another opacityChanged for this handler
                    // to catch, so plugging in mid-dim left it stuck dim.
                    onCriticalChanged: if (!critical) opacity = 1
                }
            }
        }
    }

    //========================================================================//
    //  FLOATING NOTIFICATION POPUPS  (top-left, like swaync)                 //
    //========================================================================//
    Variants {
        model: Quickshell.screens
        delegate: PanelWindow {
            required property var modelData
            screen: modelData
            visible: root.popupList.length > 0
            color: "transparent"
            anchors { top: true; left: true }
            margins { top: root.panelTopMargin; left: 10 }
            implicitWidth: 260                       // notification-window-width 250
            implicitHeight: Math.max(1, popupCol.implicitHeight)
            exclusiveZone: 0
            WlrLayershell.layer: WlrLayer.Overlay    // config: "layer": "overlay"
            WlrLayershell.namespace: "quickshell-notifications"

            Column {
                id: popupCol
                width: parent.width
                spacing: 8
                Repeater {
                    model: root.popupList
                    delegate: NotifCard {
                        required property var modelData
                        required property int index
                        width: popupCol.width
                        notif: modelData.notif
                        onClosed: root.dropPopup(modelData.notif)

                        // appear animation
                        opacity: 0
                        Component.onCompleted: opacity = 1
                        Behavior on opacity { NumberAnimation { duration: 200 } }

                        // auto-dismiss after the per-urgency timeout (history is kept)
                        Timer {
                            interval: modelData.ms; running: true; repeat: false
                            onTriggered: root.dropPopup(modelData.notif)
                        }
                    }
                }
            }
        }
    }

    //========================================================================//
    //  CONTROL CENTER  (the panel from the screenshot)                       //
    //========================================================================//
    PanelWindow {
        id: ccWin
        visible: root.ccVisible
        color: "transparent"
        anchors { top: true; left: true; right: true; bottom: true }   // full-screen catcher
        exclusiveZone: 0
        WlrLayershell.layer: WlrLayer.Top                              // control-center-layer: top
        WlrLayershell.namespace: "quickshell-control-center"
        WlrLayershell.keyboardFocus: root.ccVisible ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

        // click anywhere outside the panel -> close
        MouseArea { anchors.fill: parent; onClicked: root.ccVisible = false }

        Rectangle {
            id: ccPanel
            width: 320
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.topMargin: root.panelTopMargin
            anchors.leftMargin: 10                   // control-center-margin-left
            height: Math.min(600, ccWin.height - 20) // control-center-height 600
            radius: 14
            color: root.colBg          // fully opaque, same as the other dropdowns
            border.width: 2
            border.color: root.ncBorder

            MouseArea { anchors.fill: parent }       // swallow clicks (don't close)

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 14
                spacing: 12

                // ---------- MPRIS widget (cover on top, info/controls below) ----------
                // ===== To restyle the whole media box: border/color/radius are on
                // ===== THIS Rectangle (id: mpBox). Fonts use root.ncFont; text sizes
                // ===== are the font.pixelSize values on each Text below.
                Rectangle {
                    id: mpBox
                    Layout.fillWidth: true
                    Layout.preferredHeight: 300
                    visible: root.mprisPlayer !== null && root.mprisPlayer !== undefined
                    radius: 12
                    clip: true
                    color: "#20000000"
                    // border: uncomment / edit these two lines to frame the box
                    border.width: 2
                    border.color: "white"

                    property real trackLen: root.mprisPlayer ? (root.mprisPlayer.length || 0) : 0
                    // live position: bound to the player; the timer below keeps it ticking
                    property real curPos: root.mprisPlayer ? root.mprisPlayer.position : 0
                    property bool seeking: false
                    property real seekPos: 0
                    readonly property real shownPos: seeking ? seekPos : curPos

                    // Quickshell doesn't emit positionChanged every frame (to save CPU);
                    // pulse it once a second while playing so curPos re-reads the position.
                    Timer {
                        interval: 1000; repeat: true
                        running: root.ccVisible && root.mprisPlayer !== null && root.mprisPlayer !== undefined
                                 && root.mprisPlayer.isPlaying && !mpBox.seeking
                        onTriggered: if (root.mprisPlayer) root.mprisPlayer.positionChanged()
                    }

                    // blurred album-art background
                    Image {
                        anchors.fill: parent
                        source: root.mprisPlayer ? (root.mprisPlayer.trackArtUrl || "") : ""
                        visible: source != ""
                        fillMode: Image.PreserveAspectCrop
                        // It is drawn a few hundred points wide and then blurred, so
                        // the full-resolution cover art is never needed in memory.
                        sourceSize.width: 600
                        sourceSize.height: 600
                        layer.enabled: true
                        layer.effect: MultiEffect { blurEnabled: true; blur: 1.0; blurMax: 48 }
                    }
                    Rectangle { anchors.fill: parent; color: Qt.rgba(0, 0, 0, 0.6) }

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 16
                        spacing: 6

                        // spinning circular cover on top
                        Vinyl {
                            Layout.alignment: Qt.AlignHCenter
                            Layout.topMargin: 4
                            Layout.preferredWidth: 118
                            Layout.preferredHeight: 118
                            art: root.mprisPlayer ? (root.mprisPlayer.trackArtUrl || "") : ""
                            spinning: root.mprisPlayer ? root.mprisPlayer.isPlaying : false
                        }

                        Text {                                            // title
                            Layout.fillWidth: true; Layout.topMargin: 6
                            horizontalAlignment: Text.AlignHCenter
                            text: root.mprisPlayer ? (root.mprisPlayer.trackTitle || "") : ""
                            color: "white"; font.family: root.ncFont
                            font.pixelSize: 18; font.bold: true; elide: Text.ElideRight
                        }
                        Text {                                            // album
                            Layout.fillWidth: true
                            horizontalAlignment: Text.AlignHCenter
                            visible: text !== ""
                            text: root.mprisPlayer ? (root.mprisPlayer.trackAlbum || "") : ""
                            color: Qt.rgba(1, 1, 1, 0.6); font.family: root.ncFont
                            font.pixelSize: 13; elide: Text.ElideRight
                        }
                        Text {                                            // artist
                            Layout.fillWidth: true
                            horizontalAlignment: Text.AlignHCenter
                            text: root.mprisPlayer ? (root.mprisPlayer.trackArtist || "") : ""
                            color: Qt.rgba(1, 1, 1, 0.75); font.family: root.ncFont
                            font.pixelSize: 14; elide: Text.ElideRight
                        }

                        Item { Layout.fillHeight: true }   // push controls + progress toward the bottom

                        // controls (play/pause pill in the middle)
                        RowLayout {
                            Layout.alignment: Qt.AlignHCenter
                            spacing: 18
                            MediaBtn {                                    // shuffle
                                glyph: "\uf074"; font.pixelSize: 16
                                color: (root.mprisPlayer && root.mprisPlayer.shuffle) ? root.ncAccent : "white"
                                onClicked: if (root.mprisPlayer) root.mprisPlayer.shuffle = !root.mprisPlayer.shuffle
                            }
                            MediaBtn {                                    // previous
                                glyph: "\uf048"; font.pixelSize: 16
                                onClicked: if (root.mprisPlayer && root.mprisPlayer.canGoPrevious) root.mprisPlayer.previous()
                            }
                            Rectangle {                                   // play / pause pill
                                Layout.preferredWidth: 48; Layout.preferredHeight: 32
                                radius: height / 2
                                color: Qt.rgba(1, 1, 1, 0.92)
                                Text {
                                    anchors.centerIn: parent
                                    text: (root.mprisPlayer && root.mprisPlayer.isPlaying) ? "\uf04c" : "\uf04b"
                                    color: "#1a1a1a"; font.family: root.ncFont; font.pixelSize: 16
                                }
                                MouseArea { anchors.fill: parent
                                    onClicked: if (root.mprisPlayer) root.mprisPlayer.isPlaying = !root.mprisPlayer.isPlaying }
                            }
                            MediaBtn {                                    // next
                                glyph: "\uf051"; font.pixelSize: 16
                                onClicked: if (root.mprisPlayer && root.mprisPlayer.canGoNext) root.mprisPlayer.next()
                            }
                            MediaBtn {                                    // repeat / loop
                                glyph: "\uf01e"; font.pixelSize: 16
                                color: (root.mprisPlayer && root.mprisPlayer.loopState !== MprisLoopState.None) ? root.ncAccent : "white"
                                onClicked: {
                                    if (!root.mprisPlayer) return;
                                    var s = root.mprisPlayer.loopState;
                                    root.mprisPlayer.loopState = s === MprisLoopState.None ? MprisLoopState.Playlist
                                                               : s === MprisLoopState.Playlist ? MprisLoopState.Track
                                                               : MprisLoopState.None;
                                }
                            }
                        }

                        // draggable seek bar
                        Rectangle {
                            id: seekTrack
                            Layout.fillWidth: true
                            Layout.topMargin: 10
                            implicitHeight: 5
                            radius: 3
                            visible: mpBox.trackLen > 0
                            color: Qt.rgba(1, 1, 1, 0.2)

                            Rectangle {                                   // filled portion
                                height: parent.height; radius: 3
                                width: parent.width * Math.max(0, Math.min(1, mpBox.shownPos / mpBox.trackLen))
                                color: "white"
                            }
                            Rectangle {                                   // drag handle
                                width: 12; height: 12; radius: 6; color: "white"
                                y: parent.height / 2 - height / 2
                                x: Math.max(0, Math.min(parent.width - width,
                                       parent.width * (mpBox.shownPos / mpBox.trackLen) - width / 2))
                                visible: mpBox.seeking || handleHover.hovered
                                HoverHandler { id: handleHover }
                            }

                            MouseArea {
                                anchors.fill: parent
                                anchors.margins: -8          // easier to grab
                                preventStealing: true
                                enabled: mpBox.trackLen > 0
                                function frac(mx) { return Math.max(0, Math.min(1, mx / seekTrack.width)); }
                                onPressed: (e) => { mpBox.seeking = true; mpBox.seekPos = frac(e.x) * mpBox.trackLen; }
                                onPositionChanged: (e) => { if (pressed) mpBox.seekPos = frac(e.x) * mpBox.trackLen; }
                                onReleased: (e) => {
                                    if (root.mprisPlayer && root.mprisPlayer.canSeek && root.mprisPlayer.positionSupported)
                                        root.mprisPlayer.position = mpBox.seekPos;
                                    mpBox.seeking = false;
                                }
                            }
                        }
                        Text {                                            // time
                            Layout.alignment: Qt.AlignHCenter
                            Layout.topMargin: 3
                            visible: mpBox.trackLen > 0
                            text: root.fmtTime(mpBox.shownPos) + " / " + root.fmtTime(mpBox.trackLen)
                            color: Qt.rgba(1, 1, 1, 0.7); font.family: root.ncFont; font.pixelSize: 12
                        }
                    }
                }

                // ---------- title + DND + clear-all ----------
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Text {
                        Layout.fillWidth: true
                        text: "Notification Center"           // title widget text
                        color: root.ncText
                        font.family: root.ncFont
                        font.pixelSize: 20
                    }
                    // Do Not Disturb toggle (bell / bell-slash, accent when on)
                    Rectangle {
                        Layout.preferredWidth: 46; Layout.preferredHeight: 34
                        radius: 10
                        color: root.dnd ? root.alpha(root.ncAccent, 0.25)
                               : (dndHover.hovered ? root.alpha(root.ncAccent, 0.2) : "transparent")
                        HoverHandler { id: dndHover }
                        Text {
                            anchors.centerIn: parent
                            text: root.dnd ? "\uf1f6" : "\uf0f3"   // bell-slash when on, bell when off
                            color: root.dnd ? root.ncAccent : root.ncText
                            font.family: root.ncFont; font.pixelSize: 16
                        }
                        MouseArea { anchors.fill: parent; onClicked: root.dnd = !root.dnd }
                    }
                    // clear all
                    Rectangle {
                        Layout.preferredWidth: 46; Layout.preferredHeight: 34
                        radius: 10
                        color: clearHover.hovered ? root.alpha(root.ncAccent, 0.2) : "transparent"
                        HoverHandler { id: clearHover }
                        Text {
                            anchors.centerIn: parent
                            text: "󰆴"                          // title button-text
                            color: root.ncText; font.family: root.ncFont; font.pixelSize: 16
                        }
                        MouseArea { anchors.fill: parent; onClicked: root.clearAllNotifs() }
                    }
                }

                // ---------- notifications / empty state ----------
                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    ColumnLayout {
                        anchors.centerIn: parent
                        visible: notifServer.trackedNotifications.values.length === 0
                        spacing: 8
                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            text: "\uf0f3"                     // bell (empty state)
                            color: root.alpha(root.ncText, 0.35)
                            font.family: root.ncFont; font.pixelSize: 64
                        }
                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            text: "No Notifications"
                            color: root.alpha(root.ncText, 0.5)
                            font.family: root.ncFont; font.pixelSize: 18
                        }
                    }

                    ListView {
                        anchors.fill: parent
                        visible: count > 0
                        // newest first: trackedNotifications appends new ones at the end,
                        // so reverse it for display (history keeps ordering, this doesn't).
                        model: notifServer.trackedNotifications.values.slice().reverse()
                        spacing: 8
                        clip: true
                        delegate: NotifCard {
                            required property var modelData
                            width: ListView.view.width
                            notif: modelData
                        }
                    }
                }

                // ---------- volume slider ----------
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 12
                    Text { text: "\uf028"; color: root.ncText; font.family: root.ncFont; font.pixelSize: 20 }   // volume label
                    ThemedSlider {
                        id: volSlider
                        Layout.fillWidth: true
                        Component.onCompleted: value = root.volumePercent
                        Connections {
                            target: root
                            function onVolumePercentChanged() { if (!volSlider.pressed) volSlider.value = root.volumePercent; }
                        }
                        onMoved: root.run("pactl set-sink-volume @DEFAULT_SINK@ " + Math.round(value) + "%")
                    }
                }

                // ---------- backlight slider ----------
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 12
                    Text { text: "󰃠"; color: root.ncText; font.family: root.ncFont; font.pixelSize: 20 }         // backlight label
                    ThemedSlider {
                        id: brightSlider
                        Layout.fillWidth: true
                        Component.onCompleted: value = root.brightPercent
                        Connections {
                            target: root
                            function onBrightPercentChanged() { if (!brightSlider.pressed) brightSlider.value = root.brightPercent; }
                        }
                        onMoved: root.run("brightnessctl set " + Math.round(value) + "%")
                    }
                }
            }
        }
    }

    //========================================================================//
    //  CALENDAR  (dropdown from the clock — same chrome as the control       //
    //  center: rounded ncBgStrong card, ncBorder outline, ncFont/ncText)     //
    //========================================================================//
    PanelWindow {
        id: calWin
        visible: root.calVisible
        color: "transparent"
        anchors { top: true; left: true; right: true; bottom: true }   // full-screen catcher
        exclusiveZone: 0
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.namespace: "quickshell-calendar"
        WlrLayershell.keyboardFocus: root.calVisible ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

        // click anywhere outside the panel -> close
        MouseArea { anchors.fill: parent; onClicked: root.calVisible = false }

        Rectangle {
            id: calPanel
            width: 300
            anchors.top: parent.top
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.topMargin: root.panelTopMargin
            implicitHeight: calCol.implicitHeight + 28
            radius: 14
            // was deliberately more opaque than ncBgStrong; now fully opaque
            // like every other dropdown
            color: root.colBg
            border.width: 2
            border.color: root.ncBorder

            MouseArea { anchors.fill: parent }      // swallow clicks (don't close)

            ColumnLayout {
                id: calCol
                anchors.fill: parent
                anchors.margins: 14
                spacing: 10

                // ---------- month/year nav ----------
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 2
                    CalNavBtn { glyph: ""; onClicked: root.calYear--       }  // «  prev year
                    CalNavBtn { glyph: ""; onClicked: root.calPrevMonth()  }  // ‹  prev month
                    Text {
                        Layout.fillWidth: true
                        horizontalAlignment: Text.AlignHCenter
                        text: root.monthNames[root.calMonth] + " " + root.calYear
                        color: root.ncText
                        font.family: root.ncFont
                        font.pixelSize: 16
                        font.weight: Font.Medium
                    }
                    CalNavBtn { glyph: ""; onClicked: root.calNextMonth()  }  // ›  next month
                    CalNavBtn { glyph: ""; onClicked: root.calYear++       }  // »  next year
                }

                // ---------- weekday header ----------
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 4
                    Repeater {
                        model: ["S", "M", "T", "W", "T", "F", "S"]
                        delegate: Text {
                            required property string modelData
                            Layout.preferredWidth: 32
                            horizontalAlignment: Text.AlignHCenter
                            text: modelData
                            color: root.alpha(root.ncText, 0.5)
                            font.family: root.ncFont
                            font.pixelSize: 12
                            font.weight: Font.DemiBold
                        }
                    }
                }

                // ---------- day grid ----------
                GridLayout {
                    Layout.fillWidth: true
                    columns: 7
                    rowSpacing: 4
                    columnSpacing: 4

                    Repeater {
                        model: root.calCells
                        delegate: Rectangle {
                            required property var modelData
                            Layout.preferredWidth: 32
                            Layout.preferredHeight: 32
                            radius: 16
                            // weekends get a faint accent tint, today is a solid
                            // accent fill, everything else a subtle neutral tint —
                            // all derived from the live wal palette, not hardcoded
                            color: !modelData.inMonth ? "transparent"
                                   : modelData.isToday ? root.ncAccent
                                   : (modelData.weekday === 0 || modelData.weekday === 6) ? root.alpha(root.ncAccent, 0.15)
                                   : root.alpha(root.col7, 0.08)
                            Text {
                                anchors.centerIn: parent
                                text: modelData.num
                                font.family: root.ncFont
                                font.pixelSize: 13
                                color: !modelData.inMonth ? root.alpha(root.ncText, 0.3)
                                       : modelData.isToday ? root.contrastText(root.ncAccent)
                                       : root.ncText
                            }
                        }
                    }
                }
            }
        }
    }

    //========================================================================//
    //  BATTERY THRESHOLD PANEL  (dropdown from the battery icon — same       //
    //  chrome as the calendar/control center: rounded ncBgStrong card,       //
    //  ncBorder outline, ncFont/ncText)                                      //
    //========================================================================//
    PanelWindow {
        id: batWin
        visible: root.batVisible
        color: "transparent"
        anchors { top: true; left: true; right: true; bottom: true }   // full-screen catcher
        exclusiveZone: 0
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.namespace: "quickshell-battery"
        WlrLayershell.keyboardFocus: root.batVisible ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

        // click anywhere outside the panel -> close
        MouseArea { anchors.fill: parent; onClicked: root.batVisible = false }

        Rectangle {
            id: batPanel
            width: 300
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.topMargin: root.panelTopMargin
            anchors.rightMargin: 10
            implicitHeight: batCol.implicitHeight + 28
            radius: 14
            color: root.colBg          // fully opaque, same as the other dropdowns
            border.width: 2
            border.color: root.ncBorder

            MouseArea { anchors.fill: parent }      // swallow clicks (don't close)

            ColumnLayout {
                id: batCol
                anchors.fill: parent
                anchors.margins: 14
                spacing: 14

                // ---------- header: icon + title/subtitle, big percentage ----------
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10

                    Text {
                        text: "󰁹"
                        color: root.ncText
                        font.family: root.ncFont
                        font.pixelSize: 26
                    }
                    ColumnLayout {
                        spacing: 0
                        Text {
                            text: "Battery"
                            color: root.ncText
                            font.family: root.ncFont
                            font.pixelSize: 16
                            font.weight: Font.Medium
                        }
                    }
                    Item { Layout.fillWidth: true }
                    Text {
                        text: root.batCap + "%"
                        color: root.ncText
                        font.family: root.ncFont
                        font.pixelSize: 26
                        font.weight: Font.DemiBold
                    }
                }

                // ---------- capacity bar ----------
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 10
                    radius: 5
                    color: root.alpha(root.col7, 0.15)
                    Rectangle {
                        width: parent.width * Math.max(0, Math.min(1, root.batCap / 100))
                        height: parent.height
                        radius: 5
                        color: root.ncAccent
                    }
                }

                // ---------- health / size ----------
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10
                    ColumnLayout {
                        spacing: 2
                        Text { text: "Battery Health"; color: root.alpha(root.ncText, 0.5)
                               horizontalAlignment: Text.AlignHCenter; Layout.alignment: Qt.AlignHCenter
                               font.family: root.ncFont; font.pixelSize: 12 }
                        Text { text: root.batHealthPct >= 0 ? Math.round(root.batHealthPct) + "%" : "—"
                               color: root.ncText; horizontalAlignment: Text.AlignHCenter; Layout.alignment: Qt.AlignHCenter
                               font.family: root.ncFont; font.pixelSize: 17; font.weight: Font.Medium }
                    }
                    Item { Layout.fillWidth: true }
                    ColumnLayout {
                        spacing: 2
                        Text { text: "Battery Size"; color: root.alpha(root.ncText, 0.5)
                               horizontalAlignment: Text.AlignHCenter; Layout.alignment: Qt.AlignHCenter
                               font.family: root.ncFont; font.pixelSize: 12 }
                        Text { text: root.batSizeWh > 0 ? root.batSizeWh.toFixed(0) + " Wh" : "—"
                               color: root.ncText; horizontalAlignment: Text.AlignHCenter; Layout.alignment: Qt.AlignHCenter
                               font.family: root.ncFont; font.pixelSize: 17; font.weight: Font.Medium }
                    }
                }

                // ---------- time to full discharge / charge ----------
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2
                    Text { text: root.batTimeLabel; color: root.alpha(root.ncText, 0.5)
                           horizontalAlignment: Text.AlignHCenter; Layout.fillWidth: true
                           font.family: root.ncFont; font.pixelSize: 12 }
                    Text { text: root.fmtDuration(root.batTimeSeconds)
                           color: root.ncText; horizontalAlignment: Text.AlignHCenter; Layout.fillWidth: true
                           font.family: root.ncFont; font.pixelSize: 20; font.weight: Font.Bold }
}

                // ---------- charge-limit picker ----------
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Text {
                        text: "SET CHARGE LIMIT"
                        color: root.alpha(root.ncText, 0.5)
                        font.family: root.ncFont
                        font.pixelSize: 10
                        font.weight: Font.DemiBold
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        Repeater {
                            model: [70, 80, 90, 100]
                            delegate: Rectangle {
                                id: capBox
                                required property int modelData
                                property bool active: root.batThreshold === modelData
                                Layout.fillWidth: true
                                Layout.preferredHeight: 36
                                radius: 10
                                color: active ? root.ncAccent
                                       : (capHover.hovered ? root.alpha(root.ncAccent, 0.18) : root.alpha(root.col7, 0.08))
                                border.width: 1.5
                                border.color: root.alpha(root.ncText, 0.9)
                                HoverHandler { id: capHover }
                                Text {
                                    anchors.centerIn: parent
                                    text: capBox.modelData + "%"
                                    color: capBox.active ? root.contrastText(root.ncAccent) : root.ncText
                                    font.family: root.ncFont
                                    font.pixelSize: 13
                                    font.weight: capBox.active ? Font.DemiBold : Font.Normal
                                }
                                MouseArea { anchors.fill: parent; onClicked: root.setBatteryThreshold(capBox.modelData) }
                            }
                        }
                    }
                }
            }
        }
    }

    //========================================================================//
    //  WI-FI PANEL  (dropdown from the network icon)                         //
    //========================================================================//
    PanelWindow {
        id: netWin
        visible: root.netVisible
        color: "transparent"
        anchors { top: true; left: true; right: true; bottom: true }   // full-screen catcher
        exclusiveZone: 0
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.namespace: "quickshell-wifi"
        // Exclusive only while the password prompt is up — that is the one
        // moment this panel needs every keystroke; the rest of the time
        // OnDemand keeps Hyprland's own binds working over the panel.
        WlrLayershell.keyboardFocus: root.wifiPromptSsid !== "" ? WlrKeyboardFocus.Exclusive
                                     : (root.netVisible ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None)

        MouseArea { anchors.fill: parent; onClicked: root.netVisible = false }

        Rectangle {
            id: netPanel
            width: 340
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.topMargin: root.panelTopMargin
            anchors.rightMargin: 10
            implicitHeight: netColLayout.implicitHeight + 28
            radius: 14
            color: root.colBg          // fully opaque, same as the other dropdowns
            border.width: 2
            border.color: root.ncBorder

            MouseArea { anchors.fill: parent }      // swallow clicks (don't close)

            ColumnLayout {
                id: netColLayout
                anchors.fill: parent
                anchors.margins: 14
                spacing: 12

                // ---------- header ----------
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10
                    Text {
                        text: root.wifiIcon(root.wifiSignal)
                        color: root.ncText
                        font.family: root.ncFont
                        font.pixelSize: 26
                    }
                    Text {
                        text: "Wi-Fi"
                        color: root.ncText
                        font.family: root.ncFont
                        font.pixelSize: 16
                        font.weight: Font.Medium
                    }
                    Item { Layout.fillWidth: true }
                    PanelIconBtn {
                        glyph: root.g.cog
                        onClicked: { root.netVisible = false; root.runOnCurrentWorkspace("kitty --title impala zsh -i -c impala"); }
                    }
                    ThemedToggle {
                        checked: root.wifiEnabled
                        onToggled: (v) => root.wifiSetEnabled(v)
                    }
                }

                // ---------- live stats (only meaningful while associated) ----------
                GridLayout {
                    Layout.fillWidth: true
                    visible: root.wifiConnected
                    columns: 2
                    columnSpacing: 20
                    rowSpacing: 5
                    InfoCell { label: "Ping";       value: root.wifiPing !== "" ? root.wifiPing + " ms" : "—" }
                    InfoCell { label: "Packet Loss";value: root.wifiLoss !== "" ? root.wifiLoss + "%"   : "—" }
                    InfoCell { label: "Receiving";  value: root.fmtRate(root.wifiRxRate) }
                    InfoCell { label: "Sending";    value: root.fmtRate(root.wifiTxRate) }
                    InfoCell { label: "Downloaded"; value: root.fmtBytes(root.wifiRxTotal) }
                    InfoCell { label: "Uploaded";   value: root.fmtBytes(root.wifiTxTotal) }
                    InfoCell { label: "IP Address"; value: root.wifiIp !== "" ? root.wifiIp : "—" }
                    InfoCell { label: "Gateway";    value: root.wifiGw !== "" ? root.wifiGw : "—" }
                    InfoCell { label: "Link Rate";  value: root.wifiRate !== "" ? root.wifiRate : "—" }
                    InfoCell { label: "Interface";  value: root.wifiIface !== "" ? root.wifiIface : "—" }
                }

                PanelDivider { visible: root.wifiEnabled }

                // ---------- error banner (nmcli's own message) ----------
                Text {
                    Layout.fillWidth: true
                    visible: root.wifiError !== ""
                    text: root.wifiError
                    color: root.colCritical
                    font.family: root.ncFont
                    font.pixelSize: 11
                    wrapMode: Text.WordWrap
                }

                Text {
                    Layout.fillWidth: true
                    visible: !root.wifiEnabled
                    text: "Wi-Fi is turned off"
                    color: root.alpha(root.ncText, 0.5)
                    horizontalAlignment: Text.AlignHCenter
                    font.family: root.ncFont
                    font.pixelSize: 12
                }

                // ---------- network list ----------
                Flickable {
                    Layout.fillWidth: true
                    visible: root.wifiEnabled
                    // Cap the height so a busy airspace scrolls inside the card
                    // instead of growing it past the bottom of the screen.
                    Layout.preferredHeight: Math.min(contentHeight, 320)
                    contentHeight: netList.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    ColumnLayout {
                        id: netList
                        width: parent.width
                        spacing: 6

                        SectionLabel { text: "KNOWN NETWORKS"; font.pixelSize: 14; visible: root.wifiKnown.length > 0 }
                        Repeater {
                            model: root.wifiKnown
                            delegate: WifiNetworkRow {
                                required property var modelData
                                net: modelData
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            Layout.topMargin: root.wifiKnown.length > 0 ? 6 : 0
                            spacing: 8
                            SectionLabel { text: "UNKNOWN NETWORKS"; font.pixelSize: 14 }
                            Item { Layout.fillWidth: true }
                            PanelIconBtn {
                                glyph: root.g.radar
                                spinning: root.wifiScanning
                                onClicked: root.wifiSetScanning(!root.wifiScanning)
                            }
                        }

                        Repeater {
                            model: root.wifiOther
                            delegate: WifiNetworkRow {
                                required property var modelData
                                net: modelData
                            }
                        }

                        Text {
                            Layout.fillWidth: true
                            Layout.topMargin: 2
                            visible: root.wifiScanning && root.wifiOther.length === 0
                            text: "Scanning…"
                            color: root.alpha(root.ncText, 0.5)
                            horizontalAlignment: Text.AlignHCenter
                            font.family: root.ncFont
                            font.pixelSize: 12
                        }
                    }
                }
            }
        }
    }

    //========================================================================//
    //  BLUETOOTH PANEL  (dropdown from the bluetooth icon)                   //
    //========================================================================//
    PanelWindow {
        id: btWin
        visible: root.btVisible
        color: "transparent"
        anchors { top: true; left: true; right: true; bottom: true }
        exclusiveZone: 0
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.namespace: "quickshell-bluetooth"
        WlrLayershell.keyboardFocus: root.btRenamePath !== "" ? WlrKeyboardFocus.Exclusive
                                     : (root.btVisible ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None)

        MouseArea { anchors.fill: parent; onClicked: root.btVisible = false }

        Rectangle {
            id: btPanel
            width: 340
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.topMargin: root.panelTopMargin
            anchors.rightMargin: 10
            implicitHeight: btColLayout.implicitHeight + 28
            radius: 14
            color: root.colBg          // fully opaque, same as the audio panel
            border.width: 2
            border.color: root.ncBorder

            MouseArea { anchors.fill: parent }

            ColumnLayout {
                id: btColLayout
                anchors.fill: parent
                anchors.margins: 14
                spacing: 12

                // ---------- header ----------
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10
                    Text {
                        text: !root.btOn ? root.g.btOff : root.btConnectedCount > 0 ? root.g.btConn : root.g.bt
                        color: root.ncText
                        font.family: root.ncFont
                        font.pixelSize: 26
                    }
                    Text {
                        text: "Bluetooth"
                        color: root.ncText
                        font.family: root.ncFont
                        font.pixelSize: 16
                        font.weight: Font.Medium
                    }
                    Item { Layout.fillWidth: true }
                    PanelIconBtn {
                        glyph: root.g.cog
                        onClicked: { root.btVisible = false; root.runOnCurrentWorkspace("kitty --title bluetui zsh -i -c bluetui"); }
                    }
                    ThemedToggle {
                        checked: root.btOn
                        onToggled: (v) => { if (root.btAdapter) root.btAdapter.enabled = v; }
                    }
                }

                PanelDivider { visible: root.btOn }

                Text {
                    Layout.fillWidth: true
                    visible: !root.btOn
                    text: root.btAdapter ? "Bluetooth is turned off" : "No Bluetooth adapter found"
                    color: root.alpha(root.ncText, 0.5)
                    horizontalAlignment: Text.AlignHCenter
                    font.family: root.ncFont
                    font.pixelSize: 12
                }

                // ---------- error banner (bluetoothctl's own message) ----------
                Text {
                    Layout.fillWidth: true
                    visible: root.btError !== ""
                    text: root.btError
                    color: root.colCritical
                    font.family: root.ncFont
                    font.pixelSize: 11
                    wrapMode: Text.WordWrap
                }

                Flickable {
                    Layout.fillWidth: true
                    visible: root.btOn
                    Layout.preferredHeight: Math.min(contentHeight, 380)
                    contentHeight: btList.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    ColumnLayout {
                        id: btList
                        width: parent.width
                        spacing: 6

                        SectionLabel { text: "PAIRED"; font.pixelSize: 14; visible: root.btPaired.length > 0 }
                        Repeater {
                            model: root.btPaired
                            delegate: BtDeviceRow {
                                required property var modelData
                                dev: modelData
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            Layout.topMargin: root.btPaired.length > 0 ? 6 : 0
                            spacing: 8
                            SectionLabel { text: "AVAILABLE"; font.pixelSize: 14 }
                            Item { Layout.fillWidth: true }
                            // Manual scan — discovery is off unless asked for.
                            PanelIconBtn {
                                glyph: root.g.radar
                                spinning: root.btScanning
                                onClicked: root.btSetScanning(!root.btScanning)
                            }
                        }

                        Repeater {
                            model: root.btAvailable
                            delegate: BtDeviceRow {
                                required property var modelData
                                dev: modelData
                            }
                        }

                        Text {
                            Layout.fillWidth: true
                            Layout.topMargin: 2
                            visible: root.btScanning && root.btAvailable.length === 0
                            text: "Scanning…"
                            color: root.alpha(root.ncText, 0.5)
                            horizontalAlignment: Text.AlignHCenter
                            font.family: root.ncFont
                            font.pixelSize: 12
                        }
                    }
                }

            }
        }
    }

    //========================================================================//
    //  AUDIO PANEL  (dropdown from the volume icon)                          //
    //========================================================================//
    PanelWindow {
        id: audWin
        visible: root.audVisible
        color: "transparent"
        anchors { top: true; left: true; right: true; bottom: true }
        exclusiveZone: 0
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.namespace: "quickshell-audio"
        WlrLayershell.keyboardFocus: root.audVisible ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

        MouseArea { anchors.fill: parent; onClicked: root.audVisible = false }

        Rectangle {
            id: audPanel
            width: 340
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.topMargin: root.panelTopMargin
            anchors.rightMargin: 10
            implicitHeight: audColLayout.implicitHeight + 28
            radius: 14
            // Fully opaque, unlike the other dropdowns' ncBgStrong (alpha .95):
            // everything stacked on top of it uses low-alpha tints, so an
            // opaque base is what makes the whole panel read as solid instead
            // of letting the wallpaper through every row.
            color: root.colBg
            border.width: 2
            border.color: root.ncBorder

            MouseArea { anchors.fill: parent }

            ColumnLayout {
                id: audColLayout
                anchors.fill: parent
                anchors.margins: 14
                spacing: 12

                // ---------- header ----------
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10
                    Text {
                        text: root.audMuted ? root.g.volumeOff : root.g.volume
                        color: root.ncText
                        font.family: root.ncFont
                        font.pixelSize: 26
                    }
                    Text {
                        text: "Audio"
                        color: root.ncText
                        font.family: root.ncFont
                        font.pixelSize: 16
                        font.weight: Font.Medium
                    }
                    Item { Layout.fillWidth: true }
                    PanelIconBtn {
                        glyph: root.g.cog
                        onClicked: { root.audVisible = false; root.runOnCurrentWorkspace("kitty --title wiremix zsh -i -c wiremix"); }
                    }
                    // The header switch is master output mute: on = audible.
                    ThemedToggle {
                        checked: !root.audMuted
                        onToggled: (v) => { if (root.audSink && root.audSink.audio) root.audSink.audio.muted = !v; }
                    }
                }

                // ---------- OUTPUT ----------
                RowLayout {
                    Layout.fillWidth: true
                    SectionLabel { text: "OUTPUT"; font.pixelSize: 14 }
                    Item { Layout.fillWidth: true }
                    SectionLabel { text: root.audVol + "%"; font.pixelSize: 14; color: root.ncText }
                }
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 34
                    radius: 10
                    color: root.alpha(root.col7, 0.05)
                    border.width: 1.5
                    border.color: root.alpha(root.ncText, 0.32)
                    ThemedSlider {
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 12
                        id: outSlider
                        from: 0; to: 100
                        Component.onCompleted: value = root.audVol
                        Connections {
                            target: root
                            function onAudVolChanged() { if (!outSlider.pressed) outSlider.value = root.audVol; }
                        }
                        onMoved: root.audSetVol(root.audSink, value)
                    }
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 6
                    Repeater {
                        model: root.audSinks
                        delegate: PanelRow {
                            required property var modelData
                            glyph: root.audNodeIcon(modelData, true)
                            label: root.audNodeLabel(modelData)
                            active: root.audSink && root.audSink.id === modelData.id
                            trailGlyph: (root.audSink && root.audSink.id === modelData.id) ? root.g.radioOn : root.g.radioOff
                            onClicked: root.audSetSink(modelData)
                        }
                    }
                }

                PanelDivider {}

                // ---------- INPUT ----------
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    SectionLabel { text: "INPUT"; font.pixelSize: 14 }
                    Item { Layout.fillWidth: true }
                    // Without this the only sign of a muted mic is the dimmed
                    // slider, with no way to fix it from here — and this
                    // machine's default source ships muted.
                    PanelIconBtn {
                        implicitWidth: 26
                        implicitHeight: 20
                        glyph: root.audMicMuted ? root.g.micOff : root.g.mic
                        onClicked: if (root.audSource && root.audSource.audio)
                                       root.audSource.audio.muted = !root.audSource.audio.muted
                    }
                    SectionLabel { text: root.audMicVol + "%"; font.pixelSize: 14; color: root.ncText }
                }
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 34
                    radius: 10
                    color: root.alpha(root.col7, 0.05)
                    border.width: 1.5
                    border.color: root.alpha(root.ncText, 0.32)
                    ThemedSlider {
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 12
                        id: inSlider
                        from: 0; to: 100
                        Component.onCompleted: value = root.audMicVol
                        Connections {
                            target: root
                            function onAudMicVolChanged() { if (!inSlider.pressed) inSlider.value = root.audMicVol; }
                        }
                        onMoved: root.audSetVol(root.audSource, value)
                    }
                }
                // Live input level, straight off a pipewire peak monitor — the
                // second bar under INPUT in the reference shot. Shows at a
                // glance whether the selected mic is actually picking anything
                // up (and it is what makes a muted-but-selected mic obvious).
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 6
                    radius: 3
                    color: root.alpha(root.col7, 0.15)
                    Rectangle {
                        width: parent.width * Math.max(0, Math.min(1, root.audMicMuted ? 0 : audMicPeak.peak))
                        height: parent.height
                        radius: 3
                        color: root.ncAccent
                        Behavior on width { NumberAnimation { duration: 90 } }
                    }
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 6
                    Repeater {
                        model: root.audSources
                        delegate: PanelRow {
                            required property var modelData
                            glyph: root.audNodeIcon(modelData, false)
                            label: root.audNodeLabel(modelData)
                            active: root.audSource && root.audSource.id === modelData.id
                            trailGlyph: (root.audSource && root.audSource.id === modelData.id) ? root.g.radioOn : root.g.radioOff
                            onClicked: root.audSetSource(modelData)
                        }
                    }
                }
            }
        }
    }

    //========================================================================//
    //  OSD PILL  (the swayosd-style popup)                                   //
    //========================================================================//
    Variants {
        model: Quickshell.screens
        delegate: PanelWindow {
            required property var modelData
            screen: modelData
            // drive visibility off the root flag (not off a child, which may not
            // exist while the window is hidden -> it could never become visible)
            visible: root.osdShown
            color: "transparent"
            // anchoring only to bottom centers it horizontally (layer-shell behaviour)
            anchors { bottom: true }
            margins { bottom: 80 }         // sits above your dock; tweak to taste
	    implicitWidth: 300
            implicitHeight: 64
            exclusiveZone: 0
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.namespace: "quickshell-osd"

            Rectangle {
                id: pill
                anchors.fill: parent
                anchors.margins: 2
                radius: height / 2                       // style.css border-radius 40 -> pill
                color: root.alpha(root.colBg, 0.8)       // window { background: alpha(@background,.8) }
                opacity: root.osdShown ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.InOutQuad } }

                property string icon: {
                    if (root.osdMode === "brightness") return "󰃠";
                    if (root.osdMode === "mic")        return root.osdMuted ? "\uf131" : "\uf130";
                    return root.osdMuted ? "\uf026" : "\uf028";     // volume off / on
                }
                property bool showBar: root.osdMode === "volume" || root.osdMode === "brightness"

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 26
                    anchors.rightMargin: 26
                    spacing: 16

                    Text {                               // image { color:@color7 }
                        text: pill.icon
                        color: root.col7
                        font.family: "Ubuntu Nerd Font"
                        font.pixelSize: 24
                    }

                    Rectangle {                          // trough
                        Layout.fillWidth: true
                        visible: pill.showBar
                        implicitHeight: 6
                        radius: 10
                        color: Qt.rgba(1, 1, 1, 0.15)    // trough background
                        Rectangle {                      // progress
                            width: parent.width * (root.osdValue / 100)
                            height: parent.height
                            radius: 10
                            color: root.col7             // progress { background:@color7 }
                        }
                    }
                    // for mic, there's no bar — let the label take the middle
                    Item { Layout.fillWidth: true; visible: !pill.showBar }

                    Text {                               // label { color:@color7 }
                        text: root.osdMode === "mic" ? (root.osdMuted ? "Muted" : "On")
                                                     : (root.osdValue + "%")
                        color: root.col7
                        font.family: "Ubuntu Nerd Font"
                        font.pixelSize: 18
                        font.weight: Font.Medium
                    }
                }
            }
        }
    }
}
