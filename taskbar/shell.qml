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
//      1. homeDir (below) now resolves from $HOME at runtime //
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
    property string homeDir: Quickshell.env("HOME") || ""
    property string scriptsDir: homeDir + "/.config/waybar/scripts"
    // Quickshell.env is synchronous, so this needs no deferral.
    property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || "/run/user/1000"

    // ---- fonts (JetBrainsMono Nerd Font Propo; was CodeNewRoman) -------------
    readonly property string fontFamily: "JetBrainsMono Nerd Font Propo"
    readonly property int fontSize: 15

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
    readonly property string ncFont: "JetBrainsMono Nerd Font Propo"

    //=====================================================================//
    //  PANEL TEXT SIZE  —  change this one number                         //
    //=====================================================================//
    //  Every font.pixelSize inside the six dropdown panels (control centre,
    //  calendar, battery, wifi, bluetooth, audio) is written as
    //  root.ns(<base>), so this single multiplier scales all of them at once.
    //
    //    1.00 = the sizes measured to fit exactly after the switch to
    //           JetBrainsMono, which is 20% wider than the UbuntuMono it
    //           replaced. Below 1.00 everything just gets smaller.
    //    1.10 = current. Comfortable, still ~8% of headroom left.
    //    1.20 = the bleed threshold — at this point panel text is back to the
    //           width that ran off the right edge of the wifi panel.
    //
    //  Nudge it in 0.05 steps. Anything at or above 1.20 will overflow.
    //  The bar's own text is separate: that is `fontSize` near the top.
    readonly property real ncScale: 1.10
    function ns(base) { return Math.round(base * root.ncScale) }

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

    // The battery is BAT0 on this laptop but BAT1 on plenty of others, so the
    // name is resolved at call time instead of being written into the source:
    // first from the profile install.sh generates, then by globbing sysfs.
    // Emitted as a shell prelude because both readers are Process commands.
    readonly property string batResolve:
        "HW=\"${XDG_CONFIG_HOME:-$HOME/.config}/scripts/hardware.env\"; " +
        "[ -r \"$HW\" ] && . \"$HW\"; " +
        // NOTE: an unset BATTERY must NOT collapse to the parent directory —
        // \"/sys/class/power_supply/\" is itself a valid directory, so a bare
        // [ -d ] test would pass and the glob fallback would never run.
        "B=; [ -n \"${BATTERY:-}\" ] && B=\"/sys/class/power_supply/$BATTERY\"; " +
        "[ -n \"$B\" ] && [ -d \"$B\" ] || B=$(ls -d /sys/class/power_supply/BAT* 2>/dev/null | head -1); "

    Process {
        id: batHealthRead
        command: ["bash", "-c", root.batResolve +
            "cat \"$B/charge_full\" 2>/dev/null; echo '|'; " +
            "cat \"$B/charge_full_design\" 2>/dev/null"]
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
        command: ["bash", "-c", root.batResolve +
                  "cat \"$B/charge_control_end_threshold\" 2>/dev/null"]
        stdout: StdioCollector { onStreamFinished: {
            var v = parseInt((this.text || "").trim()); if (!isNaN(v)) root.batThreshold = v; } }
    }
    Timer { interval: 2000; running: root.batVisible; repeat: true; triggeredOnStart: true
            onTriggered: batThresholdRead.running = true }

    // Goes through apply-battery-threshold.sh rather than echoing to sysfs
    // directly (no sudo either way — see the udev rule that group-writes this
    // attribute to "power"). The script also persists the choice and, crucially,
    // FORCES a real EC transaction: writing the value sysfs already holds can be
    // a no-op at the driver level, which is why re-clicking the same percentage
    // did nothing after a hibernate had silently reset the EC. See the script.
    function setBatteryThreshold(v) {
        // update the highlighted box immediately — don't wait on the shell
        // round-trip (write + notify-send) before the UI reflects the click.
        // The periodic batThresholdRead poll re-syncs from real sysfs state
        // shortly after anyway, so this optimistic set self-corrects if the
        // write actually failed (e.g. permission denied pre-relogin).
        root.batThreshold = v;
        root.run("~/.config/scripts/apply-battery-threshold.sh " + v +
                  " && notify-send 'Battery' 'Charging capped at " + v + "%' " +
                  "|| notify-send -u critical 'Battery' 'Failed to set charge threshold " +
                  "(see $XDG_RUNTIME_DIR/battery-threshold.log)'");
        batThresholdReapply.restart();
    }
    // re-read shortly after a click to confirm/correct the optimistic update
    // above against the real sysfs value
    Timer { id: batThresholdReapply; interval: 400; onTriggered: batThresholdRead.running = true }


    //========================================================================//
    //  DISPLAY  (brightness / night light / scale / monitors)                //
    //========================================================================//
    // Backing state for the dropdown behind the bar's brightness icon.
    property bool dispVisible: false

    // Hyprland's own monitor list, polled while the panel is open. Quickshell
    // exposes Hyprland.monitors, but the fields this panel needs — mode,
    // refresh rate, position, per-monitor scale — live on the raw IPC object,
    // so parsing `hyprctl -j monitors` is both simpler and complete. Polling
    // covers hotplug for free: a display plugged in while the panel is open
    // appears within one tick, and one unplugged disappears the same way.
    property var dispMonitors: []
    Process {
        id: dispMonRead
        command: ["hyprctl", "-j", "monitors"]
        stdout: StdioCollector { onStreamFinished: {
            // A half-written read parses as nothing; keep the last good list
            // rather than blanking the panel for a tick.
            try { root.dispMonitors = JSON.parse(this.text || "[]"); } catch (e) { }
        } }
    }
    Timer { interval: 2000; running: root.dispVisible; repeat: true; triggeredOnStart: true
            onTriggered: dispMonRead.running = true }
    // A scale change lands asynchronously, and Hyprland may not honour the
    // exact number asked for (it snaps a scale it cannot divide cleanly to the
    // nearest one it can). Re-read shortly after a click so the highlighted
    // button shows what the compositor actually did, not what we requested.
    Timer { id: dispMonReapply; interval: 400; onTriggered: {
        dispMonRead.running = true;
        // Same settle is where the scale gets WRITTEN DOWN. Picking a scale
        // here was a runtime-only change: hyprland.lua reads MONITOR_SCALE out
        // of hardware.env on every parse, so the next `hyprctl reload` or
        // reboot silently restored the old one. Measured 2026-09-02 — a 1.8
        // chosen in this panel had been running since Aug 31 against a profile
        // that said 2, and one reload moved every window on the desktop.
        //
        // Deferred to the 400ms tick rather than fired next to the eval above
        // for the same reason the re-read is: the script records what the
        // compositor SETTLED ON (click 1.75, land on 1.8), and 400ms earlier
        // that is still the old value.
        if (root.dispPersistMon !== "") {
            root.run(root.shq(root.sideScriptDir + "/persist-monitor-scale.sh")
                     + " " + root.shq(root.dispPersistMon));
            root.dispPersistMon = "";
        }
    } }
    // Set by dispSetScale and nowhere else, so merely opening the panel — or
    // any other reason to re-read monitors — never rewrites the profile.
    property string dispPersistMon: ""

    // "" = follow whichever monitor is focused; otherwise the name picked in
    // the DISPLAYS list. Reset on close so the panel always opens pointing at
    // the display the user is actually looking at.
    property string dispTarget: ""
    onDispVisibleChanged: if (!root.dispVisible) root.dispTarget = "";
    readonly property var dispMon: {
        var ms = root.dispMonitors;
        for (var i = 0; i < ms.length; i++) if (ms[i].name === root.dispTarget) return ms[i];
        for (var j = 0; j < ms.length; j++) if (ms[j].focused) return ms[j];
        return ms.length > 0 ? ms[0] : null;
    }
    // The internal panel is the one brightnessctl actually drives; everything
    // else is a cable away. Matches the connector names Hyprland reports for
    // built-in outputs (eDP on laptops, LVDS on older ones, DSI on tablets).
    function dispIsInternal(m) { return !!m && /^(eDP|LVDS|DSI)/i.test(m.name); }

    // The ladder, the same on every display.
    //
    // Hyprland wants a logical size that is a whole number of pixels, and will
    // NOT take one of these verbatim when it cannot divide cleanly — it snaps
    // to the nearest scale it can and says nothing. Measured on this laptop's
    // 2880x1620: asking for 1.75 lands on 1.8 (2880/1.8 = 1600 and 1620/1.8 =
    // 900, both whole). That is the compositor's call, not something this
    // panel can talk it out of, so the buttons offer the round numbers and the
    // DISPLAYS row below reports what it actually settled on.
    readonly property var dispScales: [1, 1.25, 1.5, 1.75, 2]
    // Hyprland does that snapping itself, but NOT silently: handing it 1.75
    // puts a toast on screen — "Invalid scale passed to monitor eDP-1: 1.75,
    // using suggested scale: 1.80" — and then applies 1.8 anyway. It is a
    // notification, not a config error, so `hyprctl configerrors` stays empty
    // and it cannot be dismissed or suppressed from here. The only way not to
    // see it is to never send a scale the compositor would object to.
    //
    // So the same arithmetic is done first, and only the result is sent.
    // Scales live on a 1/120 grid — the unit of the fractional-scale protocol,
    // which is why Hyprland's suggestion is always a multiple of it — and one
    // is clean when the logical width AND height both come out whole. Search
    // outward from what was asked for and take the first that does: for 1.75
    // on 2880x1620 that is 1.8, the exact figure the toast suggested.
    function dispCleanScale(m, v) {
        if (!m) return v;
        var want = Math.round(v * 120);
        var w120 = Math.round(m.width * 120), h120 = Math.round(m.height * 120);
        for (var off = 0; off <= 60; off++) {
            for (var dir = 0; dir < (off === 0 ? 1 : 2); dir++) {
                var s120 = (off === 0) ? want : (dir === 0 ? want + off : want - off);
                if (s120 <= 0) continue;
                if (w120 % s120 === 0 && h120 % s120 === 0) return s120 / 120;
            }
        }
        // Nothing clean within half a scale step either way — vanishingly
        // unlikely for a real mode, and Hyprland arbitrating (loudly) beats
        // this panel silently doing nothing.
        return v;
    }

    // The highlight is nearest-wins rather than an exact match: click 1.75 and
    // the monitor ends up on 1.8, so an equality test would leave the row with
    // nothing selected at all.
    function dispNearestScale(cur) {
        var best = -1, bestD = Infinity;
        for (var i = 0; i < root.dispScales.length; i++) {
            var d = Math.abs(root.dispScales[i] - cur);
            if (d < bestD) { bestD = d; best = root.dispScales[i]; }
        }
        return best;
    }
    function dispScaleLabel(v) { return (Math.round(v * 100) / 100) + "x"; }

    // `hyprctl keyword` is gone since 0.55 — the live-config entry point is
    // `hyprctl eval` running the same Lua hyprland.lua uses. Mode and position
    // are handed back verbatim rather than left out: hl.monitor fills anything
    // missing with its own catch-alls ("preferred"/"auto"), which would quietly
    // re-pick the mode as a side effect of a scale click. Verified live on
    // eDP-1: 2 → 1.5 → 2 changed and restored the scale with the mode intact.
    function dispSetScale(m, v) {
        if (!m) return;
        v = root.dispCleanScale(m, v);
        var mode = m.width + "x" + m.height + "@" + Number(m.refreshRate).toFixed(2);
        var lua = "hl.monitor({ output = '" + m.name + "', mode = '" + mode + "', " +
                  "position = '" + m.x + "x" + m.y + "', scale = " + v + " })";
        root.run("hyprctl eval " + root.shq(lua));
        root.dispPersistMon = m.name;
        dispMonReapply.restart();
    }

    // ---- night light (hyprsunset) ----------------------------------------
    // scripts/nightlight.sh owns the daemon; see its header for why "on" is
    // defined as "hyprsunset is running" rather than anything the daemon
    // reports about itself. This side only mirrors that state.
    property bool nlOn: false
    property int  nlTemp: 4000
    readonly property int nlMinTemp: 2500        // warmest the slider goes
    readonly property int nlMaxTemp: 6500        // daylight — no warmth at all
    // The slider runs in warmth (0–100), not kelvin: in kelvin the fill would
    // EMPTY as the screen got warmer, which reads backwards under a label that
    // says WARMTH.
    function nlPct(k)    { return (root.nlMaxTemp - k) * 100 / (root.nlMaxTemp - root.nlMinTemp); }
    function nlKelvin(p) { return Math.round(root.nlMaxTemp - p * (root.nlMaxTemp - root.nlMinTemp) / 100); }
    readonly property string nlScript: root.sideScriptDir + "/nightlight.sh"

    Process {
        id: nlRead
        command: [root.nlScript, "status"]
        stdout: StdioCollector { onStreamFinished: {
            var p = (this.text || "").trim().split("|");
            if (p.length < 2) return;
            root.nlOn = p[0] === "on";
            // Same guard as brightRead: the state file still holds the old
            // temperature until the queued write lands.
            if (root.nlPending >= 0) return;
            var k = parseInt(p[1]); if (!isNaN(k)) root.nlTemp = k;
        } }
    }
    Timer { interval: 2000; running: root.dispVisible; repeat: true; triggeredOnStart: true
            onTriggered: nlRead.running = true }
    // Same optimistic-update-then-confirm shape as the battery cap buttons: the
    // toggle flips immediately, and this re-read corrects it if the daemon
    // refused to start.
    Timer { id: nlReadSoon; interval: 500; onTriggered: nlRead.running = true }

    function nlSetEnabled(on) {
        root.nlOn = on;
        root.run(root.shq(root.nlScript) + (on ? " on" : " off"));
        nlReadSoon.restart();
    }
    // Deliberately NOT `nlSetEnabled(!nlOn)`: nlOn is only polled while the
    // panel is open, so a keybind fired with the panel closed would be deciding
    // from a stale flag. The script reads the live daemon instead.
    function nlToggle() {
        root.run(root.shq(root.nlScript) + " toggle");
        nlReadSoon.restart();
    }
    // Dragging the warmth slider never turns the filter on: it stores the
    // temperature, and the script pushes it to the daemon only if one is
    // already running.
    //
    // Coalesced exactly like the brightness write above, and for a stronger
    // reason: every move event here forked bash AND hyprctl, which is far too
    // much to run at mouse-frame rate.
    property int nlPending: -1
    Timer {
        interval: 60; repeat: true; running: root.nlPending >= 0
        onTriggered: {
            root.run(root.shq(root.nlScript) + " set " + root.nlPending);
            root.nlPending = -1;
        }
    }
    function nlSetTemp(k) {
        if (k === root.nlTemp) return;
        root.nlTemp = k;
        root.nlPending = k;
    }

    //========================================================================//
    //  PANEL MUTUAL EXCLUSION                                                //
    //  Every dropdown (control center, calendar, battery, display, wifi,     //
    //  bluetooth, audio) is its own PanelWindow; only one may be open at a   //
    //  time.                                                                 //
    //========================================================================//
    property bool netVisible: false
    property bool btVisible:  false
    property bool audVisible: false
    property bool agentVisible: false

    function closePanels() {
        root.ccVisible = false; root.calVisible = false; root.batVisible = false;
        root.netVisible = false; root.btVisible = false; root.audVisible = false;
        root.agentVisible = false; root.dispVisible = false;
    }
    function panelOpen(which) {
        return which === "cc"  ? root.ccVisible  : which === "cal" ? root.calVisible
             : which === "bat" ? root.batVisible : which === "net" ? root.netVisible
             : which === "bt"  ? root.btVisible  : which === "aud" ? root.audVisible
             : which === "agent" ? root.agentVisible
             : which === "disp" ? root.dispVisible : false;
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
        else if (which === "agent") root.agentVisible = true;
        else if (which === "disp") root.dispVisible = true;
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
    property string wifiPromptError: ""   // shown inside the prompt box until retyped
    // The typed password lives on root, not in the TextInput. The network list
    // refreshes on a timer, and reassigning that model rebuilds every Repeater
    // delegate - including the prompt - which silently threw away whatever had
    // been typed so far. Holding it here means a rebuild cannot lose it.
    property string wifiPromptText: ""
    property bool   wifiPromptReveal: false
    property string _wifiActionSsid: ""   // ssid the in-flight action belongs to
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

            var actionSsid = root._wifiActionSsid; root._wifiActionSsid = "";

            if (code === 0) {
                root.wifiPromptSsid = ""; root.wifiError = ""; root.wifiPromptError = "";
                root.wifiPromptText = ""; root.wifiPromptReveal = false;
                wifiProfilesProc.running = true;   // the key may have just been saved
            }
            else {
                var msg = root.wifiFriendlyError(wifiActionProc.errText) || "Connection failed";
                // A saved network whose stored key is wrong or missing fails
                // here with nothing offering a way to correct it - which is
                // exactly the dead end this hit: the prompt only ever opened
                // for networks that were NOT already saved, so a bad saved
                // password could never be replaced from this panel. Reopen the
                // prompt on the network that failed and report it there.
                if (root.wifiAuthFailed(wifiActionProc.errText) && actionSsid !== "") {
                    root.wifiPromptSsid = actionSsid;
                    root.wifiPromptText = "";      // reset the box so it can just be retyped
                    root.wifiPromptReveal = false;
                    root.wifiPromptError = msg;
                    root.wifiError = "";
                } else {
                    root.wifiError = msg;
                }
                // A failed `device wifi connect` still leaves behind the profile
                // nmcli created for the attempt — so a network you mistyped the
                // password for becomes "known", and the next click connects
                // without prompting, fails again, and offers no way back in.
                // Roll the profile back so it returns to the unknown list and
                // asks for the password again. Only for a network that was not
                // already saved, so a transient failure never destroys a real
                // stored profile.
                // Belt and braces: only ever delete a profile that was absent
                // from the saved set when the attempt started AND is not the
                // network currently connected.
                if (rollback !== "" && rollback !== root.wifiSsid) {
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
    // An auth failure means the stored key is wrong or absent - recoverable by
    // retyping, unlike "out of range" which is not.
    function wifiAuthFailed(raw) {
        return /Secrets were required|no secrets|802-1X|Authentication/i.test(String(raw || ""))
    }

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
        root._wifiActionSsid = busySsid || "";
        root.wifiError = "";
        wifiActionProc.errText = "";
        wifiActionProc.running = false;      // a re-assigned command is ignored while still running
        wifiActionProc.command = ["sh", "-c", cmd];
        wifiActionProc.running = true;
    }
    // `nmcli device wifi connect` reuses an existing saved profile when one
    // matches the SSID, so this is the single entry point for both known and
    // brand-new networks. -w bounds the wait (default is ~90s of a frozen row).
    // Whether NetworkManager already has a saved profile for this SSID.
    //
    // This MUST come from wifiProfiles (built from `nmcli connection show`) and
    // not from the scan list's `known` flag. The scan list only contains
    // networks currently being advertised, so a saved network that is out of
    // range - or simply not in the latest scan, which is the case immediately
    // after disconnecting from it - reads as "not known". The rollback below
    // then treats a failed connect as "a profile I just created" and deletes
    // it. That destroyed a real saved profile during testing; the authoritative
    // list cannot produce that mistake.
    function wifiIsKnown(ssid) {
        return root.wifiProfiles[ssid] !== undefined;
    }
    function wifiConnect(ssid, password) {
        // Remember whether this network was already saved, so a failure can tell
        // a profile nmcli just invented from one that was already there.
        var uuid = root.wifiProfiles[ssid];
        var hasPw = password && password.length > 0;
        var c;

        root._wifiNewProfile = "";   // armed only by the creating branch below

        if (hasPw && uuid !== undefined) {
            // Typed a password for a network that already has a saved profile.
            // `device wifi connect ... password ...` would connect, but the key
            // belongs *in the profile* or the next attempt is back to the same
            // failure - and most of the saved profiles on this machine turned
            // out to carry key-mgmt=wpa-psk with no psk at all (created via
            // iwd, whose secrets live in its own store, not NetworkManager's).
            // So write the key into the profile first, then bring that profile
            // up: the correction is persisted for every future connect.
            c = "nmcli connection modify uuid " + root.shq(uuid) +
                " wifi-sec.key-mgmt wpa-psk wifi-sec.psk " + root.shq(password) +
                " && nmcli -w 25 connection up uuid " + root.shq(uuid);
        } else if (hasPw) {
            // Brand-new network: nmcli creates the profile as it connects.
            // This is the ONLY branch that can bring a profile into existence,
            // so it is the only one that may roll one back. Deciding that from
            // "was it in the saved set" instead was unsafe: the saved set is a
            // cached snapshot, so a profile created moments earlier by anything
            // else (impala, nmcli, another panel action) read as new and got
            // deleted on a failed connect.
            root._wifiNewProfile = ssid;
            c = "nmcli -w 25 device wifi connect " + root.shq(ssid) +
                " password " + root.shq(password);
        } else {
            // Known network, first attempt: let the saved profile supply the key.
            c = "nmcli -w 25 device wifi connect " + root.shq(ssid);
        }
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
    // Paused while a password is being typed: a refresh reassigns wifiNets,
    // which rebuilds the delegate the prompt lives in.
    Timer { interval: 4000; running: root.netVisible && root.wifiPromptSsid === ""
            repeat: true; triggeredOnStart: true
            onTriggered: wifiListProc.running = true }
    Timer { interval: 10000; running: root.netVisible && root.wifiScanning && root.wifiEnabled
            repeat: true; onTriggered: wifiScanProc.running = true }

    onNetVisibleChanged: {
        if (!netVisible) {
            root.wifiPromptSsid = ""; root.wifiError = ""; root.wifiPromptError = "";
            root.wifiPromptText = ""; root.wifiPromptReveal = false;
            root.wifiSetScanning(false);
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
    // cmap by glyph name (md-wifi_strength_4 etc.), not recalled. The bar now
    // renders them from JetBrainsMono Nerd Font Propo instead; all 34 were
    // verified present in that font's cmap before the switch (Nerd Fonts
    // patches every family at the same codepoints, so the names still hold).
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
        eye:      String.fromCodePoint(0xf06e),    // fa-eye
        eyeOff:   String.fromCodePoint(0xf070),    // fa-eye_slash
        loading:  String.fromCodePoint(0xf0772),
        robot:    String.fromCodePoint(0xf16a3),   // md-robot_outline (agents, idle)
        robotOn:  String.fromCodePoint(0xf06a9),   // md-robot         (agents, live)
        refresh:  String.fromCodePoint(0xf0450),   // md-refresh
        monitor:  String.fromCodePoint(0xf0379),   // md-monitor (external display)
        check:    String.fromCodePoint(0xf012c)    // md-check   (selected display)
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

    // The `scripts` dir that sits BESIDE this shell config, never a fixed path.
    // From ~/.config/taskbar that resolves to ~/.config/scripts; from
    // ~/projects/hyprahaan/taskbar it resolves to the repo's own scripts/. So a
    // second instance launched out of the repo exercises the repo's scripts —
    // exactly what step 2 of CLAUDE.md's workflow needs — with no deploy and no
    // path special-casing.
    readonly property string sideScriptDir: {
        var dir = String(Quickshell.shellDir || "").replace(/^file:\/\//, "");
        var cut = dir.lastIndexOf("/");
        return cut > 0 ? dir.substring(0, cut) + "/scripts"
                       : root.homeDir + "/.config/scripts";
    }

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
    //  AGENTS  (AI coding-agent plan, rate limits and token history)         //
    //========================================================================//
    // Ported from omarchy's `omarchy.agents` bar plugin (MIT — basecamp/omarchy
    // @ quattro, shell/plugins/agents/). Their Main/Agent/Panel.qml split is
    // folded into this file's single-shell layout, and the chrome is this
    // repo's (ncBg card, ncBorder, SectionLabel, PanelDivider) rather than
    // theirs, but the data model and the derivations below are theirs.
    //
    // THE PANEL NEVER LEARNS HOW A NUMBER WAS MADE. It reads JSON records out
    // of one directory; a collector script is what puts them there:
    //
    //     scripts/agent-usage-<id>  ->  <agentsUsageDir>/<id>.json  ->  a tab
    //
    // That indirection is the whole design, and it is what makes the module
    // universal: nothing below names "claude". This machine has only that one
    // agent, but someone installing these dotfiles with codex gets a second tab
    // by dropping in a second collector — no edit to this file. See
    // scripts/agent-usage-update.sh for the writer half of the contract.
    //
    // Record contract (every field optional except id):
    //   id, name, ready, tierLabel, usageStatusText, authHelpText
    //   limits[]      {label, title?, percent 0..1, resetsAt ISO-8601}
    //   recentDays[]  {date "YYYY-MM-DD", messageCount}   <- TOKENS, legacy name
    //   modelUsage    {modelId: {inputTokens, outputTokens,
    //                            cacheReadInputTokens, cacheCreationInputTokens}}
    //   todayPrompts, todaySessions, todayTotalTokens, totalPrompts,
    //   totalSessions, activeDays, updatedAt

    readonly property string agentsUsageDir:
        (Quickshell.env("XDG_STATE_HOME") || root.homeDir + "/.local/state")
        + "/hyprahaan/agents/usage"

    // The collectors live beside this shell config — see sideScriptDir, which
    // is what makes a repo-path instance run the repo's own collectors.
    readonly property string agentsScriptDir: root.sideScriptDir

    property var agentIds: []            // ids discovered in the usage dir
    property var agentCollectorIds: []   // ids the installed collectors declare
    property var agents: []              // normalized records that have something to say
    property int agentIndex: 0           // which one the panel is showing
    property var agentLive: ({})         // id -> true while that CLI has a live process
    property bool agentsBusy: false      // a collector run is in flight
    property string agentsError: ""

    readonly property var agent: root.agents.length > 0
        ? root.agents[Math.max(0, Math.min(root.agentIndex, root.agents.length - 1))]
        : null

    // Whether there is a record to draw. NOT what puts the icon in the bar —
    // that is agentRunning below — but what the panel's empty state turns on:
    // an agent can be up before its first record has been collected.
    readonly property bool agentsPresent: root.agents.length > 0

    // Whether any agent CLI is live *right now*. This is what puts the module
    // in the bar; the records only decide what the panel then draws. Read off
    // the live map itself rather than off the records, so an agent running for
    // the very first time — nothing on disk about it yet — still shows up.
    readonly property bool agentRunning: {
        for (var id in root.agentLive) if (root.agentLive[id]) return true;
        return false;
    }

    // Who to look for. The installed COLLECTORS are the declaration of which
    // agents this machine knows about, and they exist before any usage does —
    // that is what lets a first-ever run be recognised. Union with the record
    // ids so an agent whose collector was removed, but whose record is still
    // on disk, keeps working.
    readonly property var agentProbeIds: {
        var seen = ({}), out = [];
        var lists = [root.agentCollectorIds, root.agentIds];
        for (var l = 0; l < lists.length; l++)
            for (var i = 0; i < lists[l].length; i++) {
                var id = lists[l][i];
                if (id !== "" && !seen[id]) { seen[id] = true; out.push(id); }
            }
        return out;
    }

    // A first run has no record, so the panel would open onto nothing. Pull one
    // as soon as an agent appears rather than waiting for the 15-minute tick.
    // And when the last agent exits the icon leaves the bar, so the dropdown
    // must not be left hanging off a button that is no longer there.
    onAgentRunningChanged: {
        if (root.agentRunning) root.agentRefresh("normal");
        else root.agentVisible = false;
    }

    // The collectors are enumerated the same way agent-usage-update.sh does it,
    // and must stay in step with it: skip the update script itself, strip one
    // trailing extension so agent-usage-codex and agent-usage-codex.py both
    // mean "codex".
    Process {
        id: agentCollectorScan
        command: ["bash", "-c",
            "S=" + root.shq(root.agentsScriptDir) + "; [ -d \"$S\" ] || exit 0; " +
            "for f in \"$S\"/agent-usage-*; do [ -x \"$f\" ] || continue; " +
            "b=${f##*/agent-usage-}; [ \"$b\" = update.sh ] && continue; " +
            "echo \"${b%.[!.]*}\"; done"]
        stdout: StdioCollector { onStreamFinished: {
            var ids = [], lines = (this.text || "").split("\n");
            for (var i = 0; i < lines.length; i++) {
                var id = lines[i].trim();
                if (id !== "") ids.push(id);
            }
            if (ids.join(" ") !== root.agentCollectorIds.join(" ")) root.agentCollectorIds = ids;
        } }
    }

    // Reset countdowns need a clock the binding engine can actually see, and
    // dayClock is already ticking at minute precision for the calendar. A
    // countdown rendered as "3h 13m" needs nothing finer.
    readonly property double agentNowMs: dayClock.date.getTime()

    //---- discovery ---------------------------------------------------------
    // The set of agents IS the set of records on disk. Nothing here consults a
    // list of known agents, checks for an installed binary, or waits on a
    // collector it was told to expect.
    Process {
        id: agentScanProc
        command: ["bash", "-c",
            "D=" + root.shq(root.agentsUsageDir) + "; [ -d \"$D\" ] || exit 0; " +
            "for f in \"$D\"/*.json; do [ -e \"$f\" ] || continue; b=${f##*/}; echo \"${b%.json}\"; done"]
        stdout: StdioCollector { onStreamFinished: {
            var ids = [], lines = (this.text || "").split("\n");
            for (var i = 0; i < lines.length; i++) {
                var id = lines[i].trim();
                if (id !== "") ids.push(id);
            }
            // Only reassign when the SET changed. Reassigning agentIds rebuilds
            // every watcher below, and a rebuild drops each FileView and
            // re-reads from disk — doing that on every poll would make the
            // panel flicker for no reason.
            if (ids.join(" ") !== root.agentIds.join(" ")) root.agentIds = ids;
        } }
    }

    // One watcher per record. watchChanges means a collector run repopulates
    // the panel with no polling on this side at all.
    Instantiator {
        id: agentWatchers
        model: root.agentIds
        onObjectAdded: root.rebuildAgents()
        onObjectRemoved: root.rebuildAgents()
        delegate: Item {
            id: agentWatcher
            required property string modelData
            property var record: null
            onRecordChanged: root.rebuildAgents()

            FileView {
                path: root.agentsUsageDir + "/" + agentWatcher.modelData + ".json"
                watchChanges: true
                printErrors: false
                onFileChanged: reload()
                onLoadFailed: agentWatcher.record = null
                onLoaded: {
                    // A record that will not parse is a collector bug, not a
                    // reason to take the panel down: drop that one agent and
                    // leave the others alone.
                    try {
                        var parsed = JSON.parse(text() || "");
                        agentWatcher.record = (parsed && typeof parsed === "object") ? parsed : null;
                    } catch (e) {
                        console.warn("agents: ignoring unparseable record", agentWatcher.modelData, e);
                        agentWatcher.record = null;
                    }
                }
            }
        }
    }

    function agentNum(v) { var n = Number(v); return isFinite(n) ? n : 0; }

    // Oldest to newest, always. The transcript scanner already emits the week
    // in date order, but the stats-cache fallback hands back whatever order the
    // file happens to hold, and a synced snapshot merges several sources — so
    // the panel sorts rather than trusting its input. ISO-8601 dates sort
    // correctly as plain strings, which is the whole reason for that format.
    function agentSortDays(days) {
        if (!Array.isArray(days)) return [];
        return days.slice().sort(function (a, b) {
            return String(a.date || "").localeCompare(String(b.date || ""));
        });
    }

    // A record earns a tab by having something to say. A collector for an
    // agent that is installed but has never been used still writes its record
    // (that is how it reports "nothing yet" rather than failing), and this is
    // what stops such a record from putting an empty tab — and an icon — in the
    // bar.
    function agentHasData(r) {
        if (!r) return false;
        return root.agentNum(r.totalPrompts) > 0 || root.agentNum(r.totalSessions) > 0
            || root.agentNum(r.activeDays) > 0 || root.agentNum(r.todayPrompts) > 0
            || root.agentNum(r.todayTotalTokens) > 0
            || (Array.isArray(r.limits) && r.limits.length > 0);
    }

    function rebuildAgents() {
        var out = [];
        for (var i = 0; i < agentWatchers.count; i++) {
            var w = agentWatchers.objectAt(i);
            if (!w || !w.record) continue;
            var r = w.record;
            if (!root.agentHasData(r)) continue;
            out.push({
                id:              String(r.id || w.modelData),
                name:            String(r.name || r.id || w.modelData),
                tierLabel:       String(r.tierLabel || ""),
                usageStatusText: String(r.usageStatusText || ""),
                authHelpText:    String(r.authHelpText || ""),
                limits:          Array.isArray(r.limits) ? r.limits : [],
                recentDays:      root.agentSortDays(r.recentDays),
                modelUsage:      r.modelUsage || ({}),
                todayPrompts:    root.agentNum(r.todayPrompts),
                todaySessions:   root.agentNum(r.todaySessions),
                todayTotalTokens: root.agentNum(r.todayTotalTokens),
                totalPrompts:    root.agentNum(r.totalPrompts),
                activeDays:      root.agentNum(r.activeDays),
                updatedAt:       String(r.updatedAt || "")
            });
        }
        // Stable order, so the tab you picked stays where it was across a
        // refresh that rewrote the records in a different order.
        out.sort(function (a, b) { return a.name.localeCompare(b.name); });
        root.agents = out;
        if (root.agentIndex >= out.length) root.agentIndex = 0;
    }

    //---- live-process probe ------------------------------------------------
    // `pgrep -x <id>` is enough for every agent so far: claude and codex both
    // set comm to their own name, which keeps this as generic as the rest of
    // the module — the agent id IS the process name until a collector proves
    // otherwise. Note the trailing `true`: with no agents the command would
    // otherwise be an empty script, and with agents the last pgrep failing
    // would make the whole thing exit non-zero for no reason.
    Process {
        id: agentLiveProc
        command: ["bash", "-c",
            root.agentProbeIds.map(function (id) {
                return "pgrep -x " + root.shq(id) + " >/dev/null 2>&1 && echo " + root.shq(id);
            }).join("; ") + (root.agentProbeIds.length > 0 ? "; true" : "true")]
        stdout: StdioCollector { onStreamFinished: {
            var live = {}, lines = (this.text || "").split("\n");
            for (var i = 0; i < lines.length; i++) {
                var id = lines[i].trim();
                if (id !== "") live[id] = true;
            }
            root.agentLive = live;
        } }
    }

    //---- regeneration ------------------------------------------------------
    // Deliberately NOT detached. CLAUDE.md's SIGPIPE rule is about long-lived
    // children that must outlive their Process; this is the opposite — the run
    // is short, and its exit is the signal that the records are on disk.
    Process {
        id: agentUpdateProc
        command: ["true"]
        onExited: (code) => {
            root.agentsBusy = false;
            // The update script leaves the previous record in place when a
            // collector fails, so a failure here means stale numbers, not none.
            root.agentsError = code === 0 ? "" : "Couldn't refresh usage";
            agentScanProc.running = true;
        }
    }

    // kind: "normal" | "limits" (reuse the transcript scan, re-probe limits)
    //     | "force" (bypass every cache the collector keeps)
    function agentRefresh(kind) {
        if (root.agentsBusy) return;
        root.agentsBusy = true;
        agentUpdateProc.command = ["bash", "-c",
            root.shq(root.agentsScriptDir + "/agent-usage-update.sh")
            + (kind === "force" ? " --force" : kind === "limits" ? " --limits-only" : "")];
        agentUpdateProc.running = true;
    }

    // Background regeneration. 15 minutes is omarchy's default and sits well
    // inside every window the panel draws: the 5-hour session bar can move by
    // at most ~5% between ticks.
    Timer { interval: 900000; running: true; repeat: true; triggeredOnStart: true
            onTriggered: root.agentRefresh("normal") }

    // While the panel is open the limits are what someone is actually watching,
    // so re-probe those alone and reuse the transcript scan, which is the
    // expensive half. The collector caches its probe for 15s of its own accord,
    // so opening and shutting the panel cannot become a request per flick.
    Timer { interval: 120000; running: root.agentVisible; repeat: true; triggeredOnStart: true
            onTriggered: root.agentRefresh("limits") }

    // A collector installed mid-session shows up within the minute; nothing has
    // to watch the directory itself for that to work.
    Timer { interval: 60000; running: true; repeat: true; triggeredOnStart: true
            onTriggered: agentScanProc.running = true }

    // 2s, and no longer gated on there being records: this probe is what puts
    // the icon in the bar, so its interval is the delay between quitting an
    // agent and the icon going away. A pgrep of one or two names is cheap
    // enough that this is not worth being cleverer about.
    Timer { interval: 2000; running: true; repeat: true; triggeredOnStart: true
            onTriggered: agentLiveProc.running = true }

    Timer { interval: 60000; running: true; repeat: true; triggeredOnStart: true
            onTriggered: agentCollectorScan.running = true }

    //---- derivations the panel draws from ----------------------------------

    function agentFmtTokens(n) {
        var v = root.agentNum(n);
        if (v >= 1e9) return (v / 1e9).toFixed(1) + "B";
        if (v >= 1e6) return (v / 1e6).toFixed(1) + "M";
        if (v >= 1e3) return (v / 1e3).toFixed(1) + "K";
        return String(Math.round(v));
    }

    function agentModelWord(w) {
        if (w === "gpt") return "GPT";
        if (w === "deepseek") return "DeepSeek";
        return w.charAt(0).toUpperCase() + w.slice(1);
    }

    // Model ids arrive hyphenated with the version split across segments
    // ("claude-opus-4-8", "gpt-5.6-sol"). Rejoin the numeric run into one
    // version and title-case the words around it.
    function agentModelName(id) {
        if (!id) return "Unknown";
        var parts = String(id).replace(/^claude-/, "").replace(/-\d{8}$/, "").split("-");
        var words = [], version = [];
        for (var i = 0; i < parts.length; i++) {
            var part = parts[i];
            if (part === "") continue;
            if (/^\d/.test(part)) { version.push(part); continue; }
            if (version.length > 0) { words.push(version.join(".")); version = []; }
            words.push(root.agentModelWord(part));
        }
        if (version.length > 0) words.push(version.join("."));
        return words.length > 0 ? words.join(" ") : "Unknown";
    }

    // A collector that already knows which window a limit belongs to says so in
    // `title`, and that beats reading it back out of the label: a model-scoped
    // limit is titled after its model, and a name like "Opus 5 (1M context)"
    // would parse as a one-minute window.
    function agentLimitTitle(entry) {
        var title = String(entry.title || "");
        if (title !== "") return title;
        var text = String(entry.label || "").toLowerCase();
        if (text.indexOf("month") >= 0) return "Monthly";
        if (text.indexOf("week") >= 0 || text.indexOf("7-day") >= 0) return "Weekly";
        if (text.indexOf("session") >= 0 || text.indexOf("hour") >= 0) return "Session";
        var plain = String(entry.label || "").replace(/\s*\(.*\)\s*/, "").trim();
        return plain === "" ? "Limit" : plain;
    }

    function agentLimitRows(a) {
        if (!a) return [];
        var out = [], list = a.limits || [];
        for (var i = 0; i < list.length; i++) {
            var entry = list[i] || {};
            var percent = Number(entry.percent);
            if (!(percent >= 0)) continue;
            out.push({ title: root.agentLimitTitle(entry),
                       percent: percent,
                       resetsAt: String(entry.resetsAt || "") });
        }
        return out;
    }

    // The window that decides how much room is left is the FULLEST one — that
    // is the one that stops the next prompt, whatever its span.
    function agentBindingLimit(a) {
        var rows = root.agentLimitRows(a), best = null;
        for (var i = 0; i < rows.length; i++)
            if (!best || rows[i].percent > best.percent) best = rows[i];
        return best;
    }

    function agentResetMs(row) {
        if (!row || row.resetsAt === "") return -1;
        var ms = new Date(row.resetsAt).getTime();
        return isFinite(ms) ? ms - root.agentNowMs : -1;
    }

    function agentFmtDuration(ms) {
        if (!(ms > 0)) return "now";
        var minutes = Math.floor(ms / 60000);
        var hours = Math.floor(minutes / 60);
        var days = Math.floor(hours / 24);
        if (days > 0) return days + "d " + (hours % 24) + "h";
        if (hours > 0) return hours + "h " + (minutes % 60) + "m";
        return Math.max(1, minutes) + "m";
    }

    // Local calendar date, recomputed from agentNowMs so a panel left open
    // across midnight moves its "Today" row with the clock.
    function agentToday() {
        var now = new Date(root.agentNowMs);
        return now.getFullYear() + "-" + String(now.getMonth() + 1).padStart(2, "0")
             + "-" + String(now.getDate()).padStart(2, "0");
    }

    function agentDayLabel(date) {
        var parsed = new Date(String(date || "") + "T00:00:00");
        if (isNaN(parsed.getTime())) return String(date || "");
        return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][parsed.getDay()]
             + " " + parsed.getDate();
    }

    function agentWeekPeak(a) {
        var days = a ? (a.recentDays || []) : [], peak = 0;
        for (var i = 0; i < days.length; i++)
            peak = Math.max(peak, root.agentNum(days[i].messageCount));
        return Math.max(1, peak);
    }

    function agentModelRows(a) {
        var byModel = a ? (a.modelUsage || {}) : ({}), rows = [];
        for (var id in byModel) {
            var b = byModel[id] || {};
            var input = root.agentNum(b.inputTokens), output = root.agentNum(b.outputTokens);
            var cacheRead = root.agentNum(b.cacheReadInputTokens);
            var cacheWrite = root.agentNum(b.cacheCreationInputTokens);
            // Only the total is drawn. The four classes are still summed
            // separately because that is the only correct way to get it — a
            // record has no total field of its own.
            rows.push({ name: root.agentModelName(id),
                        total: input + output + cacheRead + cacheWrite });
        }
        rows.sort(function (x, y) { return y.total - x.total; });
        return rows.slice(0, 4);
    }

    // The plan you pay for, under the name of the tool it pays for. Limits get
    // their own section; this line just says what the subscription is — or what
    // is wrong with it, which matters more when something is.
    function agentHeroMeta(a) {
        if (!a) return "";
        if (a.usageStatusText !== "") return a.usageStatusText;
        if (a.tierLabel === "") return "Subscription";
        return a.tierLabel;
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

    // Live popup list (separate from history).
    //
    // This used to be a plain JS array, reassigned on every push and drop —
    // which rebuilds EVERY Repeater delegate (the array-model gotcha in
    // CLAUDE.md). Two visible consequences whenever more than one popup was
    // on screen: the entire stack blinked out for a frame and re-ran its
    // 200ms fade-in every time any one of them expired, and each surviving
    // card's auto-dismiss Timer restarted from zero, so popups outlived their
    // own timeout. A ListModel removes one row without touching its
    // neighbours, so the others neither flicker nor lose their timers.
    ListModel { id: popupModel; dynamicRoles: true }

    function pushPopup(n, ms) { popupModel.append({ notif: n, ms: ms }); }
    // Called by a card once its fade-out has finished. Removal is always
    // initiated by the card itself (close button or timeout), so the model
    // needs no "closing" role.
    function removePopup(n) {
        for (var i = 0; i < popupModel.count; i++)
            if (popupModel.get(i).notif === n) { popupModel.remove(i); return; }
    }

    function clearAllNotifs() {
        var list = notifServer.trackedNotifications.values;
        for (var i = list.length - 1; i >= 0; i--) list[i].dismiss();
    }

    // ---- active player for the control-center mpris widget --------------------
    //
    // Sticky by design. The old rule was "prefer one that's playing, else the
    // FIRST on the bus", so the instant Spotify paused the widget jumped to
    // whatever else happened to be registered - here zen, which sits on the bus
    // for the whole browser session and usually has no track at all. Now the
    // last player that actually PLAYED keeps the widget while it is paused, and
    // hands over only when another player starts playing (or the user swipes).
    //
    // The pin is stored as bus name + identity rather than the object, because
    // an MprisPlayer is destroyed when its app quits. Bus name is the precise
    // key; identity is the fallback, since zen's bus name carries a per-launch
    // instance number (org.mpris.MediaPlayer2.firefox.instance_1_94) while
    // "Zen Browser" survives a restart.
    property string mprisPinnedBus: ""
    property string mprisPinnedId: ""
    property var mprisPlayer: null

    function mprisPin(p) {
        if (!p) return;
        root.mprisPinnedBus = p.dbusName || "";
        root.mprisPinnedId = p.identity || "";
        root.mprisResolve();
    }

    // Recomputed rather than bound, so the pin can be re-written to whatever was
    // actually picked. A stale pin (app quit while paused) would otherwise sit
    // there and steal the widget back the moment that app reappeared.
    function mprisResolve() {
        var ps = Mpris.players.values;
        var byBus = null, byId = null, playing = null;
        for (var i = 0; i < ps.length; i++) {
            var p = ps[i];
            if (!playing && p.isPlaying) playing = p;
            if (root.mprisPinnedBus !== "" && p.dbusName === root.mprisPinnedBus) byBus = p;
            else if (!byId && root.mprisPinnedId !== "" && p.identity === root.mprisPinnedId) byId = p;
        }
        var pick = byBus || byId || playing || (ps.length > 0 ? ps[0] : null);
        root.mprisPinnedBus = pick ? (pick.dbusName || "") : "";
        root.mprisPinnedId = pick ? (pick.identity || "") : "";
        root.mprisPlayer = pick;
    }

    // Two-finger swipe on the media widget walks this list (spotify -> zen ->
    // spotify). dir is +1 / -1; a manual pick pins like a play does, so it
    // sticks until something else starts playing or the user swipes again.
    function mprisCycle(dir) {
        var ps = Mpris.players.values;
        if (ps.length < 2) return;
        var idx = -1;
        for (var i = 0; i < ps.length; i++) if (ps[i] === root.mprisPlayer) { idx = i; break; }
        var n = ((idx + (dir >= 0 ? 1 : -1)) % ps.length + ps.length) % ps.length;
        root.mprisPin(ps[n]);
    }

    Component.onCompleted: root.mprisResolve()
    Connections {
        target: Mpris.players
        function onValuesChanged() { root.mprisResolve(); }
    }
    // One watcher per live player: whoever starts playing takes the pin. The
    // delegates are rebuilt whenever the array is reassigned (players coming and
    // going), which is harmless - they hold no state, and a Connections only
    // forwards signals emitted after it exists, so a rebuild cannot re-pin.
    Instantiator {
        model: Mpris.players.values
        delegate: Connections {
            required property var modelData
            target: modelData
            function onIsPlayingChanged() { if (modelData.isPlaying) root.mprisPin(modelData); }
            // A player that appears on the bus ALREADY playing (spotify launched
            // straight into a track) never emits isPlayingChanged afterwards, so
            // the watcher alone would never see it and the widget would sit on
            // whatever it had. Claim the pin at creation instead.
            Component.onCompleted: if (modelData.isPlaying) root.mprisPin(modelData);
        }
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
            // Never fight a drag. While a write is queued the device still
            // reads the OLD value, and assigning it here would pull the
            // number backwards under the moving handle — which is what made
            // the readout look like it was skipping values.
            if (root.brightPending >= 0) return;
            var v = parseInt((this.text || "").trim()); if (!isNaN(v)) root.brightPercent = v; } }
    }

    // ---- slider writes: optimistic value, coalesced command ---------------
    // A drag emits a move event per mouse frame and each one forked a shell —
    // ~100 `brightnessctl` invocations a second, arriving out of order, with
    // the displayed percentage only refreshed by the 500 ms poll behind them.
    // The handle moved smoothly and the number lagged in chunks, which reads
    // as an imprecise slider. The audio panel feels exact because Pipewire
    // updates its number in-process on the same frame as the drag.
    //
    // So: set the value immediately (the repo's optimistic-UI convention, same
    // as the charge cap) and let this timer flush at most one command per
    // tick. Clearing pending stops the timer, so the value the drag ENDS on is
    // always the one written — a plain throttle would drop it.
    property int brightPending: -1
    Timer {
        interval: 40; repeat: true; running: root.brightPending >= 0
        onTriggered: {
            root.run("brightnessctl set " + root.brightPending + "%");
            root.brightPending = -1;
        }
    }
    function setBrightness(pct) {
        pct = Math.max(1, Math.min(100, Math.round(pct)));
        // ~3px of travel per percent, so most move events in a drag land on the
        // percent the backlight is already at. Dropping those is most of what
        // keeps the queue short.
        if (pct === root.brightPercent) return;
        root.brightPercent = pct;
        root.brightPending = pct;
    }
    Timer {
        interval: 500; repeat: true; running: root.ccVisible; triggeredOnStart: true
        onTriggered: { volRead.running = true; brightRead.running = true; }
    }
    // The display panel wants the same backlight reading and none of the volume
    // half, so it gets its own timer rather than making the control center's
    // pactl round-trip run for a panel with no volume control on it.
    Timer {
        interval: 500; repeat: true; running: root.dispVisible; triggeredOnStart: true
        onTriggered: brightRead.running = true
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

    // Same reasoning as the agents handler below: the display dropdown is
    // otherwise mouse-only, and a repo-path instance has to be exercisable
    // without deploying (CLAUDE.md step 2). `qs -p <shell> ipc call display
    // toggle` is how this panel was verified before it ever reached ~/.config.
    IpcHandler {
        target: "display"
        function open(): void { root.closePanels(); root.dispVisible = true; }
        function close(): void { root.dispVisible = false; }
        function toggle(): void { root.togglePanel("disp"); }
        // Picks the display the SCALE row acts on; "" hands it back to whichever
        // monitor is focused.
        function select(name: string): void { root.dispTarget = name; }
        // Flips the blue-light filter. Bound to nothing by default; it exists
        // because the toggle is otherwise mouse-only, and it is the obvious
        // thing to put on a keybind later.
        function nightlight(): void { root.nlToggle(); }
    }

    IpcHandler {
        target: "osd"
        function volume(): void { osdVolRead.running = true; }
        function brightness(): void { osdBrightRead.running = true; }
        function mic(): void { osdMicRead.running = true; }
    }

    // `qs -p <shell> ipc call agents <fn>` — the agents panel is the one module
    // worth driving from a keybind (omarchy's ships the same five verbs), and
    // it is also the only way to exercise the dropdown without a mouse, which
    // is what makes a repo instance testable per step 2 of CLAUDE.md.
    IpcHandler {
        target: "agents"
        function open(): void { root.closePanels(); root.agentVisible = root.agentRunning; }
        function close(): void { root.agentVisible = false; }
        function toggle(): void { if (root.agentRunning) root.togglePanel("agent"); }
        function refresh(): void { root.agentRefresh("force"); }
        // Cycles subscriptions. A no-op with one agent, which is the common case.
        function next(): void {
            if (root.agents.length > 1)
                root.agentIndex = (root.agentIndex + 1) % root.agents.length;
        }
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
                    font.pixelSize: root.ns(12); font.weight: Font.Medium   // .summary 0.95rem/500
                    elide: Text.ElideRight
                }
                Text {
                    Layout.fillWidth: true
                    visible: card.notif && card.notif.body !== ""
                    text: card.notif ? card.notif.body : ""
                    color: root.ncText
                    font.family: root.ncFont
                    font.pixelSize: root.ns(11)                              // .body 0.85rem
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
                font.family: root.ncFont
                font.pixelSize: root.ns(15)
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
        font.pixelSize: root.ns(17)
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
            font.pixelSize: root.ns(11)
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
            font.pixelSize: root.ns(12)
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
        // Overridable so a button nested in an accent-filled row can sit on a
        // darker surface instead of vanishing into it.
        property color surface:      root.alpha(root.col7, 0.08)
        property color surfaceHover: root.alpha(root.col7, 0.18)
        property color outline:      root.alpha(root.ncText, 0.6)
        property color textColor:    root.ncText
        signal clicked()

        Layout.fillWidth: true
        Layout.preferredHeight: 30
        radius: 10
        color: ptb.accent ? root.ncAccent
               : (ptbHover.hovered ? ptb.surfaceHover : ptb.surface)
        border.width: 1.5
        border.color: ptb.accent ? root.alpha(root.ncText, 0.9) : ptb.outline
        HoverHandler { id: ptbHover }
        Text {
            anchors.centerIn: parent
            text: ptb.label
            color: ptb.accent ? root.contrastText(root.ncAccent) : ptb.textColor
            font.family: root.ncFont
            font.pixelSize: root.ns(10)
            font.weight: ptb.accent ? Font.DemiBold : Font.Normal
        }
        MouseArea { anchors.fill: parent; onClicked: ptb.clicked() }
    }

    // "KNOWN NETWORKS" / "OUTPUT" / "PAIRED" — the small all-caps section
    // caption, and the value readout that sits opposite it.
    //
    // The size lives HERE, not on the call sites, which used to repeat a
    // literal `font.pixelSize: 14` thirteen times over. ns(11) is 12px at the
    // current ncScale — the size Ahaan settled on — and writing it through ns()
    // keeps it moving with the panel text knob instead of pinning it to a raw
    // pixel count.
    //
    // Every panel that has captions uses this and nothing overrides it, the
    // agents panel included. The control center is untouched by any of it: it
    // has no SectionLabel at all, its headings are plain Text with their own
    // sizes.
    component SectionLabel: Text {
        color: root.alpha(root.ncText, 0.5)
        font.family: root.ncFont
        font.pixelSize: root.ns(11)
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
    // One selectable row in a list (a network, a bluetooth device, an audio
    // device). `active` is the selected/connected state, `busy` swaps the
    // trailing slot for a spinner while an action is in flight.
    //
    // Anything declared inside a PanelRow becomes its expanded content: it is
    // laid out *within the row's own box*, which grows to fit, rather than
    // appearing as a separate card below the row.
    component PanelRow: Rectangle {
        id: prow
        property string glyph: ""
        property string label: ""
        property string sub: ""
        property string trailGlyph: ""
        property string trailText: ""
        property bool active: false
        property bool busy: false
        property bool expanded: false
        property bool hovered: rowHover.hovered
        default property alias expandedData: extraCol.data
        signal clicked()
        signal rightClicked()

        readonly property int headerHeight: prow.sub !== "" ? 52 : 38

        Layout.fillWidth: true
        // Driven through Layout.preferredHeight, not implicitHeight: inside a
        // ColumnLayout the layout engine sets the item's height from the
        // preferred value, so a Behavior on implicitHeight never gets to
        // interpolate - the row simply snapped to its new size.
        readonly property int targetHeight: prow.headerHeight
                                            + (prow.expanded ? extraCol.implicitHeight + 10 : 0)
        // The animation runs on this plain property, and the layout is bound to
        // it. A Behavior cannot be attached to an attached property, so
        // `Behavior on Layout.preferredHeight` silently does nothing - the row
        // just snapped to its new size (confirmed by watching a deliberately
        // 5s-long expansion complete instantly).
        property real animHeight: prow.targetHeight
        Behavior on animHeight { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
        implicitHeight: prow.animHeight
        Layout.preferredHeight: prow.animHeight
        // Content is clipped to the box so it slides out from under the header
        // as the row grows, instead of overflowing during the animation.
        clip: true

        radius: 10
        // Solid accent fill when selected, matching the battery panel's active
        // charge-limit button — not a low-alpha wash over the background.
        color: prow.active ? root.ncAccent
               : (rowHover.hovered ? root.alpha(root.col7, 0.16) : root.alpha(root.col7, 0.05))
        readonly property color fg: prow.active ? root.contrastText(root.ncAccent) : root.ncText
        // Surfaces for anything nested inside an expanded row. On a normal row
        // that is a faint light wash over the panel; on the *connected* row the
        // backdrop is the solid accent fill, where the same wash all but
        // disappears - so there it darkens instead, keeping the nested controls
        // reading as controls.
        readonly property color innerBg:      prow.active ? root.alpha(root.colBg, 0.55) : root.alpha(root.col7, 0.08)
        readonly property color innerBgHover: prow.active ? root.alpha(root.colBg, 0.72) : root.alpha(root.col7, 0.18)
        readonly property color innerBorder:  prow.active ? root.alpha(prow.fg, 0.55)    : root.alpha(root.ncText, 0.5)
        border.width: 1.5
        border.color: root.alpha(root.ncText, prow.active ? 0.85 : 0.32)
        Behavior on color { ColorAnimation { duration: 140 } }

        // Hover and click belong to the header strip only — with expanded
        // content living inside the same box, a fill-parent MouseArea would
        // swallow clicks meant for the password field and the buttons.
        Item {
            id: headerArea
            anchors { top: parent.top; left: parent.left; right: parent.right }
            height: prow.headerHeight

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
                    font.pixelSize: root.ns(12)
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 4
                    Text {
                        Layout.fillWidth: true
                        text: prow.label
                        color: prow.fg
                        font.family: root.ncFont
                        font.pixelSize: root.ns(11)
                        font.weight: prow.active ? Font.DemiBold : Font.Normal
                        elide: Text.ElideRight
                    }
                    Text {
                        Layout.fillWidth: true
                        visible: prow.sub !== ""
                        text: prow.sub
                        color: prow.active ? root.alpha(prow.fg, 0.75) : root.alpha(root.ncText, 0.55)
                        font.family: root.ncFont
                        font.pixelSize: root.ns(9)
                        elide: Text.ElideRight
                    }
                }
                Text {
                    visible: prow.trailText !== "" && !prow.busy
                    text: prow.trailText
                    color: prow.active ? root.alpha(prow.fg, 0.8) : root.alpha(root.ncText, 0.65)
                    font.family: root.ncFont
                    font.pixelSize: root.ns(11)
                }
                Text {
                    visible: prow.trailGlyph !== "" && !prow.busy
                    text: prow.trailGlyph
                    color: prow.active ? prow.fg : root.alpha(root.ncText, 0.6)
                    font.family: root.ncFont
                    font.pixelSize: root.ns(11)
                }
                Text {                                   // in-flight spinner
                    visible: prow.busy
                    text: root.g.loading
                    color: prow.fg
                    font.family: root.ncFont
                    font.pixelSize: root.ns(12)
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

        ColumnLayout {
            id: extraCol
            anchors { top: headerArea.bottom; left: parent.left; right: parent.right }
            anchors.leftMargin: 10
            anchors.rightMargin: 10
            spacing: 6
            // Fades with the growth rather than appearing the instant the row
            // starts expanding. Kept "visible" until the fade finishes so it
            // does not vanish mid-collapse.
            opacity: prow.expanded ? 1 : 0
            visible: opacity > 0.01
            Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
        }
    }

    // One wi-fi network. The context menu and the password prompt both open
    // inside this row's own box rather than as separate cards beneath it.
    component WifiNetworkRow: PanelRow {
        id: wnr
        property var net: null
        readonly property string ssid: wnr.net ? wnr.net.ssid : ""
        readonly property bool prompting: wnr.ssid !== "" && root.wifiPromptSsid === wnr.ssid
        readonly property bool menuOpen: wnr.ssid !== "" && root.wifiMenuSsid === wnr.ssid

        glyph: root.wifiIcon(wnr.net ? wnr.net.signal : 0)
        label: wnr.ssid
        sub: (wnr.net && wnr.net.active) ? "Connected" : ""
        active: wnr.net && wnr.net.active
        busy: root.wifiBusySsid === wnr.ssid
        trailText: (wnr.net ? wnr.net.signal : 0) + "%"
        trailGlyph: (wnr.net && wnr.net.secure) ? root.g.lock : ""
        expanded: wnr.menuOpen || wnr.prompting

        onClicked: {
            if (!wnr.net) return;
            root.wifiMenuSsid = ""; root.wifiPwSsid = ""; root.wifiPwText = "";
            if (wnr.net.active) { root.wifiDisconnect(); return; }
            // A saved profile already holds the PSK, so only a brand-new
            // secured network needs to ask for one.
            if (wnr.net.secure && !wnr.net.known) {
                root.wifiPromptError = ""; root.wifiPromptText = "";
                root.wifiPromptReveal = false; root.wifiPromptSsid = wnr.ssid;
            }
            else root.wifiConnect(wnr.ssid, "");
        }
        // Only saved networks have anything to offer here — there is no
        // password to reveal and nothing to forget for an unknown one.
        onRightClicked: {
            if (!wnr.net || !wnr.net.known) return;
            root.wifiPwSsid = ""; root.wifiPwText = "";
            root.wifiMenuSsid = wnr.menuOpen ? "" : wnr.ssid;
        }

        // ---------- context menu ----------
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            visible: wnr.menuOpen

            PanelTextBtn {
                label: "Forget"
                surface: wnr.innerBg; surfaceHover: wnr.innerBgHover
                outline: wnr.innerBorder; textColor: wnr.fg
                onClicked: root.wifiForget(wnr.ssid)
            }
            PanelTextBtn {
                label: root.wifiPwSsid === wnr.ssid ? "Hide Password" : "Show Password"
                surface: wnr.innerBg; surfaceHover: wnr.innerBgHover
                outline: wnr.innerBorder; textColor: wnr.fg
                onClicked: root.wifiTogglePassword(wnr.ssid)
            }
        }

        // ---------- revealed password (selectable, so it can be copied) ------
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 34
            radius: 10
            color: wnr.innerBg
            border.width: 1.5
            border.color: wnr.innerBorder
            visible: wnr.menuOpen && root.wifiPwSsid === wnr.ssid

            TextInput {
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 10
                verticalAlignment: TextInput.AlignVCenter
                text: root.wifiPwText
                readOnly: true
                selectByMouse: true
                color: wnr.fg
                selectionColor: root.alpha(root.ncAccent, 0.6)
                font.family: root.ncFont
                font.pixelSize: root.ns(11)
                clip: true
            }
        }

        // ---------- password prompt ----------
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 38
            visible: wnr.prompting
            radius: 10
            color: wnr.innerBg
            border.width: 1.5
            // Themed from the palette rather than a hardcoded red. On the
            // connected row the accent *is* the row fill, so an accent border
            // would be invisible there - use the contrasting foreground instead.
            border.color: root.wifiPromptError !== ""
                          ? (wnr.active ? wnr.fg : root.ncAccent)
                          : (pwField.activeFocus ? root.alpha(wnr.fg, 0.85) : wnr.innerBorder)

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 12
                anchors.rightMargin: 5
                spacing: 6

                TextInput {
                    id: pwField
                    Layout.fillWidth: true
                    // Sized to its own text and centred, rather than filled to
                    // the box: filling it puts the mask glyphs on the baseline
                    // of the full-height line box, which left them sitting high.
                    Layout.preferredHeight: pwField.implicitHeight
                    Layout.alignment: Qt.AlignVCenter

                    echoMode: root.wifiPromptReveal ? TextInput.Normal : TextInput.Password
                    passwordCharacter: "●"          // filled circle
                    color: wnr.fg
                    selectionColor: root.alpha(root.ncAccent, 0.6)
                    font.family: root.ncFont
                    font.pixelSize: root.ns(12)
                    clip: true
                    focus: true

                    // Mirror into root so a list refresh rebuilding this
                    // delegate cannot lose what has been typed.
                    onTextChanged: root.wifiPromptText = pwField.text
                    // Clear the standing error on a real keystroke, not on
                    // textChanged - the error itself arrives together with a
                    // programmatic reset of this field, and that reset would
                    // otherwise wipe the message before it was ever seen.
                    Keys.onPressed: if (root.wifiPromptError !== "") root.wifiPromptError = ""
                    onAccepted: root.wifiConnect(wnr.ssid, pwField.text)
                    Keys.onEscapePressed: root.wifiPromptSsid = ""

                    Component.onCompleted: pwField.text = root.wifiPromptText
                    onVisibleChanged: if (visible) {
                        pwField.text = root.wifiPromptText
                        pwField.forceActiveFocus()
                        pwFocusRetry.restart()
                    }
                    Connections {
                        target: root
                        // A programmatic reset (wrong password) has to reach the
                        // field even though the field normally drives this.
                        function onWifiPromptTextChanged() {
                            if (root.wifiPromptText !== pwField.text) pwField.text = root.wifiPromptText
                        }
                    }
                    Timer {
                        id: pwFocusRetry
                        interval: 60
                        onTriggered: if (pwField.visible && !pwField.activeFocus) pwField.forceActiveFocus()
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        width: parent.width
                        visible: pwField.text === ""
                        text: "Password for " + wnr.ssid
                        color: root.alpha(wnr.fg, 0.4)
                        font.family: root.ncFont
                        font.pixelSize: root.ns(12)
                        elide: Text.ElideRight
                    }
                }

                // Reveal toggle: shows the state the field is in — a struck-out
                // eye while the password is hidden, a plain eye while visible.
                PanelIconBtn {
                    implicitWidth: 28
                    implicitHeight: 26
                    Layout.alignment: Qt.AlignVCenter
                    glyph: root.wifiPromptReveal ? root.g.eye : root.g.eyeOff
                    onClicked: {
                        root.wifiPromptReveal = !root.wifiPromptReveal
                        pwField.forceActiveFocus()
                    }
                }
            }
        }

        Text {
            Layout.fillWidth: true
            visible: wnr.prompting && root.wifiPromptError !== ""
            text: root.wifiPromptError
            color: wnr.active ? wnr.fg : root.ncAccent
            font.family: root.ncFont
            font.pixelSize: root.ns(11)
            font.weight: Font.Medium
            wrapMode: Text.WordWrap
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            visible: wnr.prompting
            PanelTextBtn {
                label: "Cancel"
                surface: wnr.innerBg; surfaceHover: wnr.innerBgHover
                outline: wnr.innerBorder; textColor: wnr.fg
                onClicked: { root.wifiPromptSsid = ""; root.wifiPromptError = ""; root.wifiPromptText = ""; root.wifiPromptReveal = false; }
            }
            PanelTextBtn { label: "Connect"; accent: true; onClicked: root.wifiConnect(wnr.ssid, pwField.text) }
        }
    }

    // One bluetooth device. Context menu and rename open inside the row's box,
    // same as the wifi row above.
    component BtDeviceRow: PanelRow {
        id: bdr
        property var dev: null
        readonly property string path: bdr.dev ? bdr.dev.dbusPath : ""
        readonly property bool isPaired: bdr.dev && (bdr.dev.paired || bdr.dev.bonded)
        readonly property bool menuOpen: bdr.path !== "" && root.btMenuPath === bdr.path
        readonly property bool renaming: bdr.path !== "" && root.btRenamePath === bdr.path

        glyph: root.btIcon(bdr.dev)
        label: root.btLabel(bdr.dev)
        sub: root.btStateLabel(bdr.dev)
        active: bdr.dev && bdr.dev.connected
        busy: root.btIsBusy(bdr.dev)
        // Peripherals that report battery over BlueZ (headphones, mice) show it
        // right here, so checking never needs another app.
        trailText: (bdr.dev && bdr.dev.batteryAvailable) ? Math.round(bdr.dev.battery * 100) + "%" : ""
        trailGlyph: (bdr.dev && bdr.dev.batteryAvailable) ? root.g.battery : ""
        expanded: bdr.menuOpen || bdr.renaming

        onClicked: { root.btMenuPath = ""; root.btRenamePath = ""; root.btTap(bdr.dev); }
        onRightClicked: {
            root.btRenamePath = "";
            root.btMenuPath = bdr.menuOpen ? "" : bdr.path;
        }

        // ---------- context menu ----------
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            visible: bdr.menuOpen && !bdr.renaming

            PanelTextBtn {
                label: "Rename"
                surface: bdr.innerBg; surfaceHover: bdr.innerBgHover
                outline: bdr.innerBorder; textColor: bdr.fg
                onClicked: root.btRenamePath = bdr.path
            }
            PanelTextBtn {
                // Forget purges BlueZ's record of a device it knows but is not
                // paired with — the stale Trusted-without-a-link-key state that
                // can block re-pairing. Left as a deliberate action rather than
                // something pairing does silently.
                label: bdr.isPaired ? "Unpair" : "Forget"
                surface: bdr.innerBg; surfaceHover: bdr.innerBgHover
                outline: bdr.innerBorder; textColor: bdr.fg
                onClicked: root.btUnpair(bdr.dev)
            }
        }

        // ---------- inline rename ----------
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 34
            visible: bdr.renaming
            radius: 10
            color: bdr.innerBg
            border.width: 1.5
            border.color: nameField.activeFocus ? root.alpha(bdr.fg, 0.85) : bdr.innerBorder

            TextInput {
                id: nameField
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 10
                verticalAlignment: TextInput.AlignVCenter
                color: bdr.fg
                selectionColor: root.alpha(root.ncAccent, 0.6)
                font.family: root.ncFont
                font.pixelSize: root.ns(11)
                clip: true
                focus: true
                onAccepted: root.btRename(bdr.dev, nameField.text)
                Keys.onEscapePressed: root.btRenamePath = ""
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
            visible: bdr.renaming
            PanelTextBtn {
                label: "Cancel"
                surface: bdr.innerBg; surfaceHover: bdr.innerBgHover
                outline: bdr.innerBorder; textColor: bdr.fg
                onClicked: root.btRenamePath = ""
            }
            PanelTextBtn { label: "Save"; accent: true; onClicked: root.btRename(bdr.dev, nameField.text) }
        }
    }

    // label / value pair used by the wifi stats grid
    component InfoCell: RowLayout {
        id: ic
        property string label: ""
        property string value: ""

        Layout.fillWidth: true
        // preferredWidth 1 makes the grid split the row on the space it actually
        // has, rather than sizing columns from their contents. Without it a long
        // value (a 15-character IP, "1080 Mbit/s", an interface named wlp0s20f3)
        // grew the cell's implicit width, and a GridLayout will not shrink a
        // cell below that - so on some networks the panel's whole content was
        // pushed out past its own right edge.
        Layout.preferredWidth: 1
        spacing: 6

        Text {
            // The label yields first: it is a constant caption, whereas the
            // value is the actual information, so an elided "IP Addre..." beats
            // an elided address.
            Layout.fillWidth: true
            Layout.minimumWidth: 0
            elide: Text.ElideRight
            text: ic.label
            color: root.alpha(root.ncText, 0.5)
            font.family: root.ncFont
            font.pixelSize: root.ns(10)
        }
        Text {
            // Natural width, but never more than most of the cell, so a
            // pathological value still cannot push the panel open.
            Layout.maximumWidth: ic.width * 0.74
            horizontalAlignment: Text.AlignRight
            elide: Text.ElideRight
            text: ic.value
            color: root.ncText
            font.family: root.ncFont
            font.pixelSize: root.ns(10)
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

                // mpris  (spotify / cliamp)  →  "[   {status_icon} | {dynamic} ]"
                BarLabel {
                    id: mpris
                    // music players this island is willing to show, matched
                    // case-insensitively against identity + bus name.
                    // cliamp advertises identity "Cliamp" on
                    // org.mpris.MediaPlayer2.cliamp — "spotify" only ever
                    // appears in its xesam:url, never in the name, so the old
                    // spotify-only match never saw it.
                    readonly property var known: ["spotify", "cliamp"]
                    // pick a known player, preferring one that is actually playing
                    property var player: {
                        var ps = Mpris.players.values;
                        var idle = null;
                        for (var i = 0; i < ps.length; i++) {
                            var name = ((ps[i].identity || "") + " " + (ps[i].dbusName || "")).toLowerCase();
                            var hit = false;
                            for (var k = 0; k < known.length; k++)
                                if (name.indexOf(known[k]) !== -1) { hit = true; break; }
                            if (!hit) continue;
                            if (ps[i].isPlaying) return ps[i];
                            if (!idle) idle = ps[i];
                        }
                        return idle;
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
            //  RIGHT ISLAND : group/expand , agents , voxtype , bluetooth , //
            //                 network , battery                            //
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
                    // Raw `expanded: grpHover.hovered` was too twitchy to use:
                    // collapsed, the group's hit area is only the  handle, so
                    // a few px of cursor drift on the way over to the volume
                    // icon un-hovered it and slammed the 600ms animation shut
                    // mid-reveal. Un-hover now only ARMS a 1s timer, and the
                    // drawer counts as expanded for as long as that timer runs,
                    // so a brief overshoot never collapses it. Re-entering
                    // disarms the timer (below), which is what makes the grace
                    // period a buffer rather than a 1s cap on every reveal.
                    //
                    // Also pinned open while a panel launched from inside the
                    // drawer is up: clicking the volume icon moves the pointer
                    // down onto the panel, which is outside the group, so the
                    // drawer used to collapse out from under the panel it had
                    // just opened. Both drawer icons now own a panel, so both
                    // visible flags pin the drawer open.
                    property bool expanded: grpHover.hovered || collapseDelay.running
                                            || root.audVisible || root.dispVisible
                    HoverHandler {
                        id: grpHover
                        onHoveredChanged: hovered ? collapseDelay.stop() : collapseDelay.restart()
                    }
                    Timer { id: collapseDelay; interval: 1000 }

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
                                            }
                                        }
                                    }
                                    Timer { interval: 1000; running: true; repeat: true; triggeredOnStart: true
                                            onTriggered: volProc.running = true }
                                }

                                // custom/brightness -> the display panel.
                                // The glyph is the panel's own monitor icon
                                // rather than waybar's sun: the item opens
                                // DISPLAY, and brightness is one row of it.
                                // Via root.g, not a pasted literal — these
                                // Material codepoints are outside the BMP and
                                // a pasted surrogate pair gets mangled by sed,
                                // heredocs and diff viewers.
                                // click -> display panel ; scroll -> backlight
                                BarLabel {
                                    id: brightness
                                    text: root.g.monitor
                                    onLeftClicked:  root.togglePanel("disp")
                                    onScrolledUp:   root.run("brightnessctl set +5%")
                                    onScrolledDown: root.run("brightnessctl set 5%-")
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

                //=== agents : AI coding-agent usage ============================
                // Sits left of voxtype, so the island's two "something is
                // happening right now" glyphs end up next to each other.
                //
                // The module leaves the bar ENTIRELY when no agent has recorded
                // usage — an invisible child is skipped by the RowLayout, so it
                // costs no width either. A machine that has never run a coding
                // agent draws nothing here and the icon arrives on its own the
                // first time a collector finds something, which is what makes
                // this safe to ship in a dotfiles repo's default bar.
                //
                // "Running", strictly: a live CLI process, not usage on
                // record. Start `claude` in any terminal and the icon arrives
                // within the probe's 2s; Ctrl+C back to the prompt and it
                // leaves. The records decide what the PANEL draws, never
                // whether the module is in the bar at all.
                BarLabel {
                    id: agentBtn
                    visible: root.agentRunning
                    text: root.g.robotOn

                    // The icon is only ever on screen while an agent is up,
                    // so presence alone carries "running" and the glyph does not
                    // need to. Colour is left to say the one thing that is
                    // urgent: red once the fullest window is nearly spent, at
                    // the same 90% the panel's own meters go red at. (Not
                    // ncAccent — on this wallpaper's palette that is #4E627D
                    // against a #c3c7cc foreground, a tint that reads as
                    // *disabled*.)
                    readonly property var binding: root.agentBindingLimit(root.agent)
                    baseColor: binding && binding.percent >= 0.9 ? root.colCritical : root.col7

                    onLeftClicked: root.togglePanel("agent")
                    // Right-click is the force refresh, matching the panel's own
                    // refresh button, so the numbers can be pulled fresh without
                    // opening anything.
                    onRightClicked: root.agentRefresh("force")
                    // Scroll cycles subscriptions when there is more than one,
                    // the same way the panel's chips do.
                    onScrolledUp: if (root.agents.length > 1)
                        root.agentIndex = (root.agentIndex + 1) % root.agents.length
                    onScrolledDown: if (root.agents.length > 1)
                        root.agentIndex = (root.agentIndex + root.agents.length - 1) % root.agents.length
                }

                //=== voxtype : voice-to-text ==================================
                // Recording indicator, sitting left of the bluetooth glyph.
                // Collapsed to zero width when idle, so it costs no bar space
                // until it has something to say.
                //
                // Driven by voxtype's own state file rather than by polling
                // `voxtype status`: the daemon rewrites that file in place on
                // every transition, and the inode is stable across a full
                // idle -> recording -> idle cycle (verified with stat), so one
                // inotify watch survives instead of needing a re-arm.
                Item {
                    id: vox

                    // 'state' is already taken on Item -- same reason the
                    // network module below calls its own field netState.
                    property string voxState: "idle"     // idle|recording|transcribing
                    readonly property bool active: voxState === "recording"
                                                || voxState === "transcribing"

                    // A Behavior cannot attach to an attached property, so the
                    // reveal animates a plain real and the layout width is
                    // bound to that. (The hover drawer above puts a Behavior
                    // directly on Layout.preferredWidth, which silently never
                    // animates -- worth fixing there too.)
                    property real openAmount: active ? 1 : 0
                    Behavior on openAmount {
                        NumberAnimation { duration: 260; easing.type: Easing.OutCubic }
                    }

                    // One phase drives all five bars, rather than five
                    // independent animations: it keeps them in a fixed
                    // relationship and leaves exactly one value to reset. A
                    // running:-bound animation freezes its property wherever it
                    // stood when the binding goes false, so the reset is done
                    // from the state change below, not from inside the anim.
                    property real phase: 0
                    NumberAnimation on phase {
                        running: vox.active
                        loops: Animation.Infinite
                        from: 0; to: 2 * Math.PI
                        duration: vox.voxState === "transcribing" ? 1400 : 900
                    }
                    onVoxStateChanged: if (!vox.active) vox.phase = 0

                    // Recording: a travelling wave (per-bar phase offset).
                    // Transcribing: a shallower breath, all bars in step, so
                    // the two states read differently at a glance.
                    function barHeight(i) {
                        var wave = vox.voxState === "transcribing";
                        var amp  = wave ? 0.45 : 1.0;
                        var off  = wave ? 0 : i * 0.9;
                        return 3 + 10 * amp * (0.5 + 0.5 * Math.sin(vox.phase + off));
                    }

                    clip: true
                    implicitHeight: voxRow.implicitHeight
                    Layout.preferredWidth: (voxRow.implicitWidth + 10) * openAmount
                    opacity: openAmount

                    Row {
                        id: voxRow
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.right: parent.right      // reveal leftward
                        anchors.rightMargin: 5
                        spacing: 2

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.g.mic
                            font.family: root.fontFamily
                            font.pixelSize: root.fontSize
                            color: vox.voxState === "recording" ? root.colCritical
                                                                : root.col9
                            Behavior on color { ColorAnimation { duration: 200 } }
                        }

                        Repeater {
                            model: 5
                            Rectangle {
                                width: 2
                                radius: 1
                                anchors.verticalCenter: parent.verticalCenter
                                height: vox.barHeight(index)
                                color: vox.voxState === "recording" ? root.colCritical
                                                                    : root.col9
                                Behavior on color { ColorAnimation { duration: 200 } }
                            }
                        }
                    }

                    FileView {
                        id: voxStateFile
                        path: root.runtimeDir + "/voxtype/state"
                        watchChanges: true
                        onFileChanged: reload()
                        onLoaded: vox.voxState = (voxStateFile.text() || "idle").trim()
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
            visible: popupModel.count > 0
            color: "transparent"
            anchors { top: true; left: true }
            margins { top: root.panelTopMargin; left: 10 }
            implicitWidth: 260                       // notification-window-width 250

            // The height is deliberately FIXED instead of tracking the card
            // stack, and this is the fix for the "white box left behind when a
            // notification disappears" bug. SHRINKING a layer surface leaves a
            // translucent white block filling the strip that was removed, for
            // a few hundred ms — nothing in the QML scene draws it (proved by
            // painting the window red and the cards blue: the block stayed
            // white), and pinning implicitHeight made it vanish completely.
            // So the surface now keeps one size for its whole life and only
            // the cards inside it come and go. `mask` keeps input to the cards
            // themselves, exactly as macshell's dock window does, so the empty
            // space below them stays click-through.
            implicitHeight: screen.height
            mask: Region { item: popupCol }
            exclusiveZone: 0
            WlrLayershell.layer: WlrLayer.Overlay    // config: "layer": "overlay"
            WlrLayershell.namespace: "quickshell-notifications"

            Column {
                id: popupCol
                width: parent.width
                // spacing 0 on purpose — the 8px gap between cards lives
                // INSIDE each slot below. Column spacing only exists between
                // items, so it would snap shut the instant a collapsing slot
                // hit zero, which is what made the cards below jump the last
                // few pixels after an otherwise smooth collapse.
                spacing: 0
                Repeater {
                    model: popupModel
                    // Each card sits in a slot that owns the card plus the gap
                    // under it. Closing animates the SLOT's height to zero, so
                    // the card and its gap disappear as one motion and the
                    // cards below slide up smoothly instead of snapping.
                    delegate: Item {
                        id: popupSlot
                        required property var model
                        // Held on the slot so it survives the model row being
                        // removed out from under us.
                        readonly property var myNotif: model.notif

                        width: popupCol.width
                        implicitHeight: card.implicitHeight + popupGap
                        height: implicitHeight
                        clip: closing               // card must not spill while the slot shrinks

                        readonly property int popupGap: 8
                        property bool closing: false

                        function close() {
                            if (closing) return;
                            closing = true;         // enables the Behavior below first
                            card.opacity = 0;
                            height = 0;             // breaks the binding; Behavior animates it
                            reaper.start();
                        }
                        Behavior on height {
                            // Only while closing: height is otherwise bound to
                            // implicitHeight, which settles as the icon/text
                            // load, and animating that would look like a jitter.
                            enabled: popupSlot.closing
                            NumberAnimation { duration: 200; easing.type: Easing.InOutQuad }
                        }
                        Timer {
                            id: reaper
                            interval: 220; repeat: false
                            onTriggered: root.removePopup(popupSlot.myNotif)
                        }

                        NotifCard {
                            id: card
                            width: popupSlot.width
                            notif: popupSlot.myNotif
                            onClosed: popupSlot.close()

                            // appear animation
                            opacity: 0
                            Component.onCompleted: opacity = 1
                            Behavior on opacity { NumberAnimation { duration: 200 } }
                        }

                        // auto-dismiss after the per-urgency timeout (history is kept)
                        Timer {
                            interval: popupSlot.model.ms; running: true; repeat: false
                            onTriggered: popupSlot.close()
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
                    // 300 was a fixed guess and the content outgrew it, so `clip`
                    // sliced the time readout in half. Track the content height and
                    // only ever use 300 as a floor, so it can't clip again if the
                    // fonts grow (ncScale) or a longer control row appears.
                    Layout.preferredHeight: Math.max(300, mpCol.implicitHeight + 32)
                    visible: root.mprisPlayer !== null && root.mprisPlayer !== undefined
                    radius: 12
                    clip: true
                    color: "#20000000"
                    // border: uncomment / edit these two lines to frame the box
                    border.width: 2
                    border.color: "white"

                    // ---- two-finger swipe cycles the player -------------------
                    // A touchpad two-finger swipe reaches QML as scroll events -
                    // there is no separate swipe gesture on this stack.
                    //
                    // This MUST be a MouseArea. Measured on this Quickshell/Qt
                    // build, a WheelHandler receives NO wheel events at all (a
                    // HoverHandler beside it fires normally), while
                    // MouseArea.onWheel receives every one - which is why the
                    // first attempt at this silently did nothing.
                    //
                    // Declared as the FIRST child, so it sits at the bottom of
                    // the stack, and acceptedButtons: Qt.NoButton so it can never
                    // take a click from the transport buttons or the seek bar
                    // above it. Wheel still reaches it because nothing above
                    // connects to `wheel`, so nothing above accepts one.
                    MouseArea {
                        id: mpSwipe
                        anchors.fill: parent
                        acceptedButtons: Qt.NoButton

                        // Horizontal travel that counts as a swipe. From a real
                        // touchpad capture on this machine: one deliberate
                        // sideways swipe covers 25-410px (median 119) over ~20
                        // events, i.e. ~5px per event. 25 is the smallest real
                        // swipe seen, and firing only once per gesture means a
                        // low bar costs nothing.
                        readonly property int threshold: 25
                        // This hardware reports angleDelta at exactly 12x
                        // pixelDelta; a plain mouse wheel sets only angleDelta.
                        readonly property int anglePerPixel: 12
                        property real accX: 0
                        property real accY: 0
                        property bool fired: false

                        function endGesture() { accX = 0; accY = 0; fired = false; }

                        onWheel: (w) => {
                            // The touchpad brackets every gesture with a
                            // zero-delta event (libinput axis_stop). Measured: it
                            // segmented a 1856-event capture into 65 gestures
                            // cleanly. Momentum events would otherwise keep
                            // cycling after the fingers lift, so they end it too.
                            if (w.phase === Qt.ScrollEnd || w.phase === Qt.ScrollMomentum
                                || (w.angleDelta.x === 0 && w.angleDelta.y === 0
                                    && w.pixelDelta.x === 0 && w.pixelDelta.y === 0)) {
                                mpSwipe.endGesture();
                                gestureGap.stop();
                                return;
                            }
                            // Fallback boundary if phase is ever absent: a gap in
                            // the event stream ends the gesture.
                            gestureGap.restart();

                            if (Mpris.players.values.length < 2) return;

                            mpSwipe.accX += w.pixelDelta.x !== 0 ? w.pixelDelta.x
                                                                 : w.angleDelta.x / mpSwipe.anglePerPixel;
                            mpSwipe.accY += w.pixelDelta.y !== 0 ? w.pixelDelta.y
                                                                 : w.angleDelta.y / mpSwipe.anglePerPixel;

                            // exactly one switch per swipe, and only for a swipe
                            // that is mostly sideways - comparing against accY is
                            // what keeps ordinary vertical scrolling inert.
                            if (mpSwipe.fired) return;
                            if (Math.abs(mpSwipe.accX) < mpSwipe.threshold) return;
                            if (Math.abs(mpSwipe.accX) <= Math.abs(mpSwipe.accY)) return;
                            mpSwipe.fired = true;
                            mpBox.startCycle(mpSwipe.accX < 0 ? 1 : -1);
                        }
                    }
                    Timer { id: gestureGap; interval: 150; onTriggered: mpSwipe.endGesture() }

                    // ---- player-change transition ----------------------------
                    // The swap is deferred to the MIDPOINT of the animation, so
                    // the outgoing player slides out and the incoming one slides
                    // in from the opposite side. Switching the data first and
                    // animating after would just be the same abrupt change with a
                    // wipe over it.
                    property real swapShift: 0
                    property real swapFade: 1
                    // A swipe landing mid-transition is remembered rather than
                    // dropped - swiping twice quickly should advance twice. One
                    // deep on purpose: a flurry of swipes should not queue up a
                    // long train of animations to sit through.
                    property int pendingDir: 0
                    function startCycle(dir) {
                        if (mpSwap.running) { mpBox.pendingDir = dir; return; }
                        mpSwap.dir = dir;
                        mpSwap.start();
                    }
                    SequentialAnimation {
                        id: mpSwap
                        property int dir: 1
                        ParallelAnimation {
                            NumberAnimation { target: mpBox; property: "swapShift"
                                              to: -mpSwap.dir * 34; duration: 120; easing.type: Easing.InQuad }
                            NumberAnimation { target: mpBox; property: "swapFade"
                                              to: 0; duration: 120; easing.type: Easing.InQuad }
                        }
                        ScriptAction { script: {
                            root.mprisCycle(mpSwap.dir);
                            mpBox.swapShift = mpSwap.dir * 34;   // jump to the far side to slide back in
                        } }
                        ParallelAnimation {
                            NumberAnimation { target: mpBox; property: "swapShift"
                                              to: 0; duration: 200; easing.type: Easing.OutCubic }
                            NumberAnimation { target: mpBox; property: "swapFade"
                                              to: 1; duration: 200; easing.type: Easing.OutCubic }
                        }
                        onFinished: if (mpBox.pendingDir !== 0) {
                            var d = mpBox.pendingDir;
                            mpBox.pendingDir = 0;
                            mpBox.startCycle(d);
                        }
                    }

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

                    // Blurred album-art background + dim overlay, rounded off.
                    //
                    // `clip: true` on a Rectangle clips to the BOUNDING RECT, not to
                    // the rounded corners, so a full-bleed square child still paints
                    // into the four corner notches outside the radius. Both of these
                    // did, which is what put the dark square patches on the corners.
                    //
                    // Blur and mask are two SEPARATE stages on purpose. Doing both in
                    // one MultiEffect does not work: enabling blur expands the
                    // effect's padding rect, and the mask texture is stretched over
                    // that larger rect, so the rounded mask lands outside the corners
                    // and clips nothing. Measured — the notch pixel stayed art-
                    // coloured instead of going back to the panel background.
                    // Blurring on the Image's own layer and masking the wrapper
                    // (a mask-only MultiEffect, so no padding) clips exactly.
                    Item {
                        id: mpBg
                        anchors.fill: parent
                        opacity: mpBox.swapFade          // cross-fades with the swap; no slide
                        layer.enabled: true
                        layer.effect: MultiEffect { maskEnabled: true; maskSource: mpArtMask }

                        Image {
                            id: mpArt
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
                    }
                    // rounded-rect mask for the stack above (same pattern as Vinyl)
                    Item {
                        id: mpArtMask
                        anchors.fill: parent
                        layer.enabled: true
                        visible: false
                        Rectangle { anchors.fill: parent; radius: mpBox.radius; color: "black" }
                    }

                    ColumnLayout {
                        id: mpCol
                        anchors.fill: parent
                        anchors.margins: 16
                        spacing: 6
                        opacity: mpBox.swapFade
                        // a Translate transform, not x - mpCol is anchor-filled
                        transform: Translate { x: mpBox.swapShift }

                        // which player the widget is on - only worth the space
                        // once there is more than one to swipe between.
                        Text {
                            Layout.fillWidth: true
                            horizontalAlignment: Text.AlignHCenter
                            visible: Mpris.players.values.length > 1
                            text: root.mprisPlayer ? (root.mprisPlayer.identity || "") : ""
                            color: Qt.rgba(1, 1, 1, 0.55); font.family: root.ncFont
                            font.pixelSize: root.ns(9); elide: Text.ElideRight
                        }

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
                            font.pixelSize: root.ns(15); font.bold: true; elide: Text.ElideRight
                        }
                        Text {                                            // artist
                            Layout.fillWidth: true
                            horizontalAlignment: Text.AlignHCenter
                            text: root.mprisPlayer ? (root.mprisPlayer.trackArtist || "") : ""
                            color: Qt.rgba(1, 1, 1, 0.75); font.family: root.ncFont
                            font.pixelSize: root.ns(12); elide: Text.ElideRight
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
                                    color: "#1a1a1a"; font.family: root.ncFont; font.pixelSize: root.ns(13)
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
                            color: Qt.rgba(1, 1, 1, 0.7); font.family: root.ncFont; font.pixelSize: root.ns(10)
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
                        // 17 overflowed: this row has 292-46-46-8-8 = 184px for
                        // the text, and 19 chars x 0.6em x 17px = 194px, so the
                        // glyphs ran under the DND button's hover highlight.
                        // 14 (=15px at ncScale 1.10) needs 171px and fits.
                        font.pixelSize: root.ns(14)
                        // safety net: if ncScale is ever raised far enough to
                        // overflow again, truncate rather than collide.
                        elide: Text.ElideRight
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
                            font.family: root.ncFont; font.pixelSize: root.ns(13)
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
                            color: root.ncText; font.family: root.ncFont; font.pixelSize: root.ns(13)
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
                            font.family: root.ncFont; font.pixelSize: root.ns(53)
                        }
                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            text: "No Notifications"
                            color: root.alpha(root.ncText, 0.5)
                            font.family: root.ncFont; font.pixelSize: root.ns(15)
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
                    Text { text: "\uf028"; color: root.ncText; font.family: root.ncFont; font.pixelSize: root.ns(17) }   // volume label
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
                    Text { text: "󰃠"; color: root.ncText; font.family: root.ncFont; font.pixelSize: root.ns(17) }         // backlight label
                    ThemedSlider {
                        id: brightSlider
                        Layout.fillWidth: true
                        Component.onCompleted: value = root.brightPercent
                        Connections {
                            target: root
                            function onBrightPercentChanged() { if (!brightSlider.pressed) brightSlider.value = root.brightPercent; }
                        }
                        onMoved: root.setBrightness(value)
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
                        font.pixelSize: root.ns(13)
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
                            font.pixelSize: root.ns(10)
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
                                font.pixelSize: root.ns(11)
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
                        font.pixelSize: root.ns(22)
                    }
                    ColumnLayout {
                        spacing: 0
                        Text {
                            text: "Battery"
                            color: root.ncText
                            font.family: root.ncFont
                            font.pixelSize: root.ns(13)
                            font.weight: Font.Medium
                        }
                    }
                    Item { Layout.fillWidth: true }
                    Text {
                        text: root.batCap + "%"
                        color: root.ncText
                        font.family: root.ncFont
                        font.pixelSize: root.ns(22)
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
                               font.family: root.ncFont; font.pixelSize: root.ns(10) }
                        Text { text: root.batHealthPct >= 0 ? Math.round(root.batHealthPct) + "%" : "—"
                               color: root.ncText; horizontalAlignment: Text.AlignHCenter; Layout.alignment: Qt.AlignHCenter
                               font.family: root.ncFont; font.pixelSize: root.ns(14); font.weight: Font.Medium }
                    }
                    Item { Layout.fillWidth: true }
                    ColumnLayout {
                        spacing: 2
                        Text { text: "Battery Size"; color: root.alpha(root.ncText, 0.5)
                               horizontalAlignment: Text.AlignHCenter; Layout.alignment: Qt.AlignHCenter
                               font.family: root.ncFont; font.pixelSize: root.ns(10) }
                        Text { text: root.batSizeWh > 0 ? root.batSizeWh.toFixed(0) + " Wh" : "—"
                               color: root.ncText; horizontalAlignment: Text.AlignHCenter; Layout.alignment: Qt.AlignHCenter
                               font.family: root.ncFont; font.pixelSize: root.ns(14); font.weight: Font.Medium }
                    }
                }

                // ---------- time to full discharge / charge ----------
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2
                    Text { text: root.batTimeLabel; color: root.alpha(root.ncText, 0.5)
                           horizontalAlignment: Text.AlignHCenter; Layout.fillWidth: true
                           font.family: root.ncFont; font.pixelSize: root.ns(10) }
                    Text { text: root.fmtDuration(root.batTimeSeconds)
                           color: root.ncText; horizontalAlignment: Text.AlignHCenter; Layout.fillWidth: true
                           font.family: root.ncFont; font.pixelSize: root.ns(17); font.weight: Font.Bold }
}

                // ---------- charge-limit picker ----------
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Text {
                        text: "SET CHARGE LIMIT"
                        color: root.alpha(root.ncText, 0.5)
                        font.family: root.ncFont
                        font.pixelSize: root.ns(8)
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
                                    font.pixelSize: root.ns(11)
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
    //  DISPLAY PANEL  (dropdown from the brightness icon — same chrome as    //
    //  the battery/audio dropdowns: opaque colBg card, ncBorder outline)     //
    //========================================================================//
    PanelWindow {
        id: dispWin
        visible: root.dispVisible
        color: "transparent"
        anchors { top: true; left: true; right: true; bottom: true }   // full-screen catcher
        exclusiveZone: 0
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.namespace: "quickshell-display"
        WlrLayershell.keyboardFocus: root.dispVisible ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

        MouseArea { anchors.fill: parent; onClicked: root.dispVisible = false }

        Rectangle {
            id: dispPanel
            width: 340
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.topMargin: root.panelTopMargin
            anchors.rightMargin: 10
            implicitHeight: dispColLayout.implicitHeight + 28
            radius: 14
            color: root.colBg          // fully opaque, same as the other dropdowns
            border.width: 2
            border.color: root.ncBorder

            MouseArea { anchors.fill: parent }      // swallow clicks (don't close)

            ColumnLayout {
                id: dispColLayout
                anchors.fill: parent
                anchors.margins: 14
                spacing: 12

                // ---------- header ----------
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10
                    Text {
                        text: root.g.monitor
                        color: root.ncText
                        font.family: root.ncFont
                        font.pixelSize: root.ns(22)
                    }
                    Text {
                        text: "Display"
                        color: root.ncText
                        font.family: root.ncFont
                        font.pixelSize: root.ns(13)
                        font.weight: Font.Medium
                    }
                    Item { Layout.fillWidth: true }
                }

                // ---------- brightness ----------
                // Panel-level, not per-display: brightnessctl only ever drives
                // the internal backlight, and an external monitor would need
                // ddcutil, which is not installed on this machine. Selecting a
                // second display below therefore does NOT re-point this slider —
                // it would silently keep changing the laptop panel either way.
                RowLayout {
                    Layout.fillWidth: true
                    SectionLabel { text: "BRIGHTNESS" }
                    Item { Layout.fillWidth: true }
                    SectionLabel { text: root.brightPercent + "%"; color: root.ncText }
                }
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 34
                    radius: 10
                    color: root.alpha(root.col7, 0.05)
                    border.width: 1.5
                    border.color: root.alpha(root.ncText, 0.32)
                    ThemedSlider {
                        id: dispBrightSlider
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 12
                        // 1 rather than 0: brightnessctl will happily take the
                        // backlight to a black screen with no way back from this
                        // panel, since the panel is on that screen.
                        from: 1; to: 100
                        Component.onCompleted: value = root.brightPercent
                        Connections {
                            target: root
                            function onBrightPercentChanged() {
                                if (!dispBrightSlider.pressed) dispBrightSlider.value = root.brightPercent;
                            }
                        }
                        onMoved: root.setBrightness(value)
                    }
                }

                // ---------- night light ----------
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    SectionLabel { text: "NIGHT LIGHT" }
                    Item { Layout.fillWidth: true }
                    // No kelvin readout here on purpose: the number moved 40K
                    // per 1% of slider travel, so it read as a value that
                    // skipped rather than one you were setting. The slider
                    // position is the whole control.
                    ThemedToggle {
                        checked: root.nlOn
                        onToggled: (v) => root.nlSetEnabled(v)
                    }
                }
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 34
                    radius: 10
                    color: root.alpha(root.col7, 0.05)
                    border.width: 1.5
                    border.color: root.alpha(root.ncText, 0.32)
                    // Dimmed, not disabled, while the filter is off: the warmth
                    // is still worth setting before switching it on, and the
                    // script stores it without starting the daemon.
                    opacity: root.nlOn ? 1 : 0.5
                    Behavior on opacity { NumberAnimation { duration: 160 } }
                    ThemedSlider {
                        id: nlSlider
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 12
                        from: 0; to: 100
                        Component.onCompleted: value = root.nlPct(root.nlTemp)
                        Connections {
                            target: root
                            function onNlTempChanged() {
                                if (!nlSlider.pressed) nlSlider.value = root.nlPct(root.nlTemp);
                            }
                        }
                        onMoved: root.nlSetTemp(root.nlKelvin(value))
                    }
                }

                // ---------- scale ----------
                SectionLabel { text: "SCALE" }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6
                    Repeater {
                        model: root.dispScales
                        delegate: Rectangle {
                            id: scaleBox
                            required property var modelData
                            property bool active: !!root.dispMon
                                                  && root.dispNearestScale(Number(root.dispMon.scale)) === modelData
                            Layout.fillWidth: true
                            Layout.preferredHeight: 34
                            radius: 10
                            color: active ? root.ncAccent
                                   : (scaleHover.hovered ? root.alpha(root.ncAccent, 0.18) : root.alpha(root.col7, 0.08))
                            border.width: 1.5
                            border.color: root.alpha(root.ncText, 0.9)
                            HoverHandler { id: scaleHover }
                            Text {
                                anchors.centerIn: parent
                                text: root.dispScaleLabel(scaleBox.modelData)
                                color: scaleBox.active ? root.contrastText(root.ncAccent) : root.ncText
                                font.family: root.ncFont
                                font.pixelSize: root.ns(10)
                                font.weight: scaleBox.active ? Font.DemiBold : Font.Normal
                            }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: root.dispSetScale(root.dispMon, scaleBox.modelData)
                            }
                        }
                    }
                }

                // ---------- displays ----------
                SectionLabel { text: "DISPLAYS" }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 6
                    Repeater {
                        model: root.dispMonitors
                        delegate: PanelRow {
                            required property var modelData
                            // Laptop glyph for the built-in panel, monitor glyph
                            // for anything on a cable — the same is-internal test
                            // the brightness note above depends on.
                            glyph: root.dispIsInternal(modelData) ? root.g.laptop : root.g.monitor
                            label: modelData.name + (modelData.focused ? " · focused" : "")
                            sub: modelData.width + "×" + modelData.height
                                 + " · " + Math.round(modelData.refreshRate) + "Hz"
                                 + " · " + root.dispScaleLabel(Number(modelData.scale))
                            // Selection drives the SCALE row above, so the check
                            // marks the display those buttons will act on — which
                            // is the focused one until the user picks another.
                            active: !!root.dispMon && root.dispMon.name === modelData.name
                            trailGlyph: (!!root.dispMon && root.dispMon.name === modelData.name) ? root.g.check : ""
                            onClicked: root.dispTarget = modelData.name
                        }
                    }
                    // Only reachable in the blink before the first poll returns,
                    // or if hyprctl is not answering at all.
                    Text {
                        visible: root.dispMonitors.length === 0
                        text: "No displays reported"
                        color: root.alpha(root.ncText, 0.5)
                        font.family: root.ncFont
                        font.pixelSize: root.ns(10)
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
                        font.pixelSize: root.ns(22)
                    }
                    Text {
                        text: "Wi-Fi"
                        color: root.ncText
                        font.family: root.ncFont
                        font.pixelSize: root.ns(13)
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
                    // Auth failures are reported inside the password prompt
                    // instead; this only carries what the prompt cannot fix.
                    visible: root.wifiError !== "" && root.wifiPromptSsid === ""
                    text: root.wifiError
                    color: root.colCritical
                    font.family: root.ncFont
                    font.pixelSize: root.ns(12)
                    font.weight: Font.Medium
                    wrapMode: Text.WordWrap
                }

                Text {
                    Layout.fillWidth: true
                    visible: !root.wifiEnabled
                    text: "Wi-Fi is turned off"
                    color: root.alpha(root.ncText, 0.5)
                    horizontalAlignment: Text.AlignHCenter
                    font.family: root.ncFont
                    font.pixelSize: root.ns(10)
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

                        SectionLabel { text: "KNOWN NETWORKS"; visible: root.wifiKnown.length > 0 }
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
                            SectionLabel { text: "UNKNOWN NETWORKS" }
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
                            font.pixelSize: root.ns(10)
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
                        font.pixelSize: root.ns(22)
                    }
                    Text {
                        text: "Bluetooth"
                        color: root.ncText
                        font.family: root.ncFont
                        font.pixelSize: root.ns(13)
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
                    font.pixelSize: root.ns(10)
                }

                // ---------- error banner (bluetoothctl's own message) ----------
                Text {
                    Layout.fillWidth: true
                    visible: root.btError !== ""
                    text: root.btError
                    color: root.colCritical
                    font.family: root.ncFont
                    font.pixelSize: root.ns(12)
                    font.weight: Font.Medium
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

                        SectionLabel { text: "PAIRED"; visible: root.btPaired.length > 0 }
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
                            SectionLabel { text: "AVAILABLE" }
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
                            font.pixelSize: root.ns(10)
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
                        font.pixelSize: root.ns(22)
                    }
                    Text {
                        text: "Audio"
                        color: root.ncText
                        font.family: root.ncFont
                        font.pixelSize: root.ns(13)
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
                    SectionLabel { text: "OUTPUT" }
                    Item { Layout.fillWidth: true }
                    SectionLabel { text: root.audVol + "%"; color: root.ncText }
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
                    SectionLabel { text: "INPUT" }
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
                    SectionLabel { text: root.audMicVol + "%"; color: root.ncText }
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
    //  AGENTS PANEL  (dropdown from the robot icon)                          //
    //  omarchy's agents dashboard in this repo's panel language: same         //
    //  ncBg card / ncBorder outline / SectionLabel + PanelDivider as the      //
    //  battery, wifi, bluetooth and audio dropdowns.                          //
    //========================================================================//
    PanelWindow {
        id: agentWin
        visible: root.agentVisible
        color: "transparent"
        anchors { top: true; left: true; right: true; bottom: true }   // full-screen catcher
        exclusiveZone: 0
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.namespace: "quickshell-agents"
        WlrLayershell.keyboardFocus: root.agentVisible ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

        MouseArea { anchors.fill: parent; onClicked: root.agentVisible = false }

        Rectangle {
            id: agentPanel
            // Wider than the 300px control dropdowns: this one is a dashboard,
            // and the model rows carry a name and a token figure on one line.
            width: 330
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.topMargin: root.panelTopMargin
            anchors.rightMargin: 10
            implicitHeight: agentCol.implicitHeight + 28
            radius: 14
            color: root.colBg
            border.width: 2
            border.color: root.ncBorder

            MouseArea { anchors.fill: parent }      // swallow clicks (don't close)

            ColumnLayout {
                id: agentCol
                anchors.fill: parent
                anchors.margins: 14
                spacing: 12

                // ---------- hero: mark, tool name, the plan it runs on ----------
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10

                    // An agent may ship its own mark at assets/<id>.svg — the
                    // one place in the module where an agent gets to look like
                    // itself. Nothing requires it: Image reports Error for a
                    // file that is not there and the bar glyph takes over, so
                    // a collector with no artwork still gets a hero.
                    // Qt.resolvedUrl is relative to THIS file, so it follows
                    // the shell whether it runs from the repo or ~/.config.
                    Item {
                        Layout.preferredWidth: root.ns(26)
                        Layout.preferredHeight: root.ns(26)

                        Image {
                            id: agentMark
                            anchors.fill: parent
                            source: root.agent ? Qt.resolvedUrl("assets/" + root.agent.id + ".svg") : ""
                            // SVGs rasterize at sourceSize, so ask for 2x and
                            // let it scale down — at 1x the mark is mush on a
                            // HiDPI screen.
                            sourceSize.width: root.ns(52)
                            sourceSize.height: root.ns(52)
                            fillMode: Image.PreserveAspectFit
                            smooth: true
                        }
                        Text {
                            anchors.centerIn: parent
                            visible: agentMark.status !== Image.Ready
                            text: root.g.robotOn
                            color: root.ncText
                            font.family: root.ncFont
                            font.pixelSize: root.ns(24)
                        }
                    }
                    ColumnLayout {
                        spacing: 1
                        Layout.fillWidth: true
                        Text {
                            // Reachable for a second or two on a first-ever run:
                            // the icon appears with the process, the record
                            // lands when the collector kicked off by
                            // onAgentRunningChanged comes back.
                            text: root.agent ? root.agent.name
                                  : root.agentsBusy ? "Collecting usage…" : "No usage recorded yet"
                            color: root.ncText
                            font.family: root.ncFont
                            font.pixelSize: root.ns(15)
                            font.weight: Font.Medium
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                        }
                        // The plan, in caps, the way the reference does it —
                        // "MAX 20X" / "PRO". An auth or endpoint problem
                        // replaces it, because that matters more than the tier.
                        Text {
                            text: root.agentHeroMeta(root.agent).toUpperCase()
                            color: root.agent && root.agent.usageStatusText !== ""
                                   ? root.colWarning : root.alpha(root.ncText, 0.5)
                            font.family: root.ncFont
                            font.pixelSize: root.ns(10)
                            font.weight: Font.DemiBold
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                        }
                    }
                    // Spins while a collector run is in flight, so a refresh
                    // that takes a second to come back is visibly working
                    // rather than apparently ignored.
                    PanelIconBtn {
                        glyph: root.g.refresh
                        spinning: root.agentsBusy
                        onClicked: root.agentRefresh("force")
                    }
                }

                // ---------- subscription switch ----------
                // Only earns its row when there is a choice to make: with one
                // agent the hero already names it.
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    visible: root.agents.length > 1
                    Repeater {
                        model: root.agents
                        delegate: PanelTextBtn {
                            required property var modelData
                            required property int index
                            label: modelData.name
                            accent: index === root.agentIndex
                            onClicked: root.agentIndex = index
                        }
                    }
                }

                // ---------- auth / endpoint trouble ----------
                // The hero line says something is wrong; this says what to do
                // about it, and only appears when there is something to say.
                Rectangle {
                    Layout.fillWidth: true
                    visible: root.agent && root.agent.usageStatusText !== ""
                             && root.agent.authHelpText !== ""
                    implicitHeight: agentHelp.implicitHeight + 20
                    radius: 10
                    color: root.alpha(root.colWarning, 0.10)
                    border.width: 1.5
                    border.color: root.alpha(root.colWarning, 0.35)
                    Text {
                        id: agentHelp
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: 10
                        anchors.rightMargin: 10
                        text: root.agent ? root.agent.authHelpText : ""
                        color: root.alpha(root.ncText, 0.75)
                        font.family: root.ncFont
                        font.pixelSize: root.ns(9)
                        wrapMode: Text.WordWrap
                    }
                }

                // ---------- limits ----------
                PanelDivider { visible: agentLimits.visible }

                ColumnLayout {
                    id: agentLimits
                    Layout.fillWidth: true
                    spacing: 10
                    readonly property var rows: root.agentLimitRows(root.agent)
                    visible: rows.length > 0

                    SectionLabel { text: "LIMITS" }

                    Repeater {
                        model: agentLimits.rows
                        delegate: ColumnLayout {
                            required property var modelData
                            readonly property bool alarming: modelData.percent >= 0.9
                            Layout.fillWidth: true
                            spacing: 5

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8
                                Text {
                                    // Model-scoped windows are titled after the
                                    // model ("Fable Weekly") and run long, so
                                    // the title is what gives way, never the
                                    // percentage.
                                    text: modelData.title
                                    color: root.ncText
                                    font.family: root.ncFont
                                    font.pixelSize: root.ns(12)
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                }
                                Text {
                                    text: Math.round(modelData.percent * 100) + "%"
                                    color: alarming ? root.colCritical : root.ncText
                                    font.family: root.ncFont
                                    font.pixelSize: root.ns(11)
                                    font.weight: Font.DemiBold
                                }
                            }

                            Rectangle {
                                Layout.fillWidth: true
                                implicitHeight: 6
                                radius: 3
                                color: root.alpha(root.col7, 0.15)
                                Rectangle {
                                    width: parent.width * Math.max(0, Math.min(1, modelData.percent))
                                    height: parent.height
                                    radius: parent.radius
                                    color: alarming ? root.colCritical : root.ncAccent
                                    Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                                }
                            }

                            Text {
                                readonly property real remaining: root.agentResetMs(modelData)
                                visible: remaining > 0
                                text: "Resets in " + root.agentFmtDuration(remaining)
                                color: root.alpha(root.ncText, 0.5)
                                font.family: root.ncFont
                                font.pixelSize: root.ns(9)
                            }
                        }
                    }
                }

                // ---------- tokens by day ----------
                PanelDivider { visible: agentDays.visible }

                ColumnLayout {
                    id: agentDays
                    Layout.fillWidth: true
                    spacing: 6
                    readonly property var rows: root.agent ? (root.agent.recentDays || []) : []
                    readonly property real peak: root.agentWeekPeak(root.agent)
                    readonly property string today: root.agentToday()
                    visible: rows.length > 0

                    SectionLabel { text: "TOKENS BY DAY" }

                    Repeater {
                        model: agentDays.rows
                        delegate: RowLayout {
                            required property var modelData
                            // By date, not by position: a stats-cache fallback
                            // can hand back a window that stops short of today.
                            readonly property bool isToday: String(modelData.date || "") === agentDays.today
                            readonly property real tokens: root.agentNum(modelData.messageCount)
                            Layout.fillWidth: true
                            spacing: 8

                            // Weekday plus day-of-month. The window is a
                            // rolling seven days, so it starts on whatever
                            // weekday it starts on, and a run of quiet days
                            // ahead of two busy ones reads exactly like a
                            // sort by size until the dates are on screen.
                            Text {
                                text: isToday ? "Today" : root.agentDayLabel(modelData.date)
                                color: isToday ? root.ncText : root.alpha(root.ncText, 0.5)
                                font.family: root.ncFont
                                font.pixelSize: root.ns(10)
                                font.weight: isToday ? Font.DemiBold : Font.Normal
                                Layout.preferredWidth: root.ns(46)
                            }

                            Rectangle {
                                Layout.fillWidth: true
                                implicitHeight: 5
                                radius: 2.5
                                color: root.alpha(root.col7, 0.15)
                                Rectangle {
                                    width: parent.width * Math.max(0, Math.min(1, tokens / agentDays.peak))
                                    height: parent.height
                                    radius: parent.radius
                                    // Scaled to the busiest day of the week, so
                                    // the peak row is always full and the rest
                                    // read as a fraction of it.
                                    color: isToday ? root.ncAccent : root.alpha(root.ncAccent, 0.55)
                                    Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                                }
                            }

                            Text {
                                text: root.agentFmtTokens(tokens)
                                color: isToday ? root.ncText : root.alpha(root.ncText, 0.5)
                                font.family: root.ncFont
                                font.pixelSize: root.ns(10)
                                font.weight: Font.DemiBold
                                horizontalAlignment: Text.AlignRight
                                Layout.preferredWidth: root.ns(44)
                            }
                        }
                    }

                    // Prompt and session counts only exist for today, so they
                    // ride along under the week rather than taking a section of
                    // their own.
                    // fillWidth + wrap, both required: a Text with neither
                    // takes its implicit width from the string and a
                    // ColumnLayout lets it overflow the card rather than
                    // squeezing it, which is exactly what this line did.
                    Text {
                        visible: root.agent && root.agent.todayPrompts > 0
                        text: root.agent ? (root.agent.todayPrompts + " prompts, "
                                            + root.agent.todaySessions + " sessions today  ·  "
                                            + root.agent.activeDays + " active days") : ""
                        color: root.alpha(root.ncText, 0.4)
                        font.family: root.ncFont
                        font.pixelSize: root.ns(9)
                        wrapMode: Text.WordWrap
                        Layout.fillWidth: true
                        Layout.topMargin: 2
                    }
                }

                // ---------- tokens by model ----------
                PanelDivider { visible: agentModels.visible }

                ColumnLayout {
                    id: agentModels
                    Layout.fillWidth: true
                    spacing: 6
                    readonly property var rows: root.agentModelRows(root.agent)
                    visible: rows.length > 0

                    SectionLabel { text: "TOKENS BY MODEL" }

                    Repeater {
                        model: agentModels.rows
                        delegate: Rectangle {
                            id: agentModelBox
                            required property var modelData
                            Layout.fillWidth: true
                            Layout.preferredHeight: 28
                            radius: 8
                            color: root.alpha(root.col7, 0.06)

                            // The share bar fills the row BEHIND the label
                            // rather than stacking under it, which is what keeps
                            // the whole dashboard on one screen. Scaled to the
                            // heaviest model, so the top row is always full —
                            // the same scale-to-peak the week above uses.
                            Rectangle {
                                anchors.left: parent.left
                                height: parent.height
                                radius: parent.radius
                                width: parent.width * Math.max(0, Math.min(1,
                                    modelData.total / Math.max(1, agentModels.rows[0].total)))
                                color: root.alpha(root.ncAccent, 0.22)
                                Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                            }

                            Text {
                                anchors.left: parent.left
                                anchors.leftMargin: 9
                                anchors.right: agentModelTokens.left
                                anchors.rightMargin: 8
                                anchors.verticalCenter: parent.verticalCenter
                                text: modelData.name
                                color: root.ncText
                                font.family: root.ncFont
                                font.pixelSize: root.ns(11)
                                elide: Text.ElideRight
                            }
                            Text {
                                id: agentModelTokens
                                anchors.right: parent.right
                                anchors.rightMargin: 9
                                anchors.verticalCenter: parent.verticalCenter
                                text: root.agentFmtTokens(modelData.total)
                                color: root.alpha(root.ncText, 0.6)
                                font.family: root.ncFont
                                font.pixelSize: root.ns(11)
                                font.weight: Font.DemiBold
                            }
                        }
                    }
                }

                // ---------- footer ----------
                Text {
                    Layout.fillWidth: true
                    visible: text !== ""
                    text: root.agentsError
                    color: root.colWarning
                    font.family: root.ncFont
                    font.pixelSize: root.ns(9)
                    horizontalAlignment: Text.AlignHCenter
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
                        font.family: "JetBrainsMono Nerd Font Propo"
                        font.pixelSize: 21
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
                        font.family: "JetBrainsMono Nerd Font Propo"
                        font.pixelSize: 15
                        font.weight: Font.Medium
                    }
                }
            }
        }
    }
}
