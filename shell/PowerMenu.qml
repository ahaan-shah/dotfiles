pragma Singleton

import QtQuick
import Quickshell.Io

// 1:1 port of scripts/powermenu.sh's option list + case dispatch — same
// four actions. Icon glyphs are a separate field (not baked into the label
// string like the original rofi listing did) so Finder's icon tile can
// render them properly — these MDI codepoints are outside the BMP (need a
// UTF-16 surrogate pair), and Finder previously derived tile icons via
// title.charAt(0), which only grabs the lead surrogate and renders as a
// broken glyph ("?"). Rendering the full glyph string fixes that.
QtObject {
    id: root

    readonly property var items: [
        { icon: "󰤄", label: "Sleep",     key: "sleep" },
        { icon: "󰜗", label: "Hibernate", key: "hibernate" },
        { icon: "󰐥", label: "Shutdown",  key: "shutdown" },
        { icon: "󰜉", label: "Reboot",    key: "reboot" },
        { icon: "󰍃", label: "Logout",    key: "logout" }
    ]

    function run(key) {
        switch (key) {
        case "hibernate":
            // Suspend-to-disk. Set up 2026-08-26: a 20G /swapfile plus the
            // resume hook and resume=/resume_offset= on the cmdline, because
            // zram alone cannot hold the image (it lives in the RAM being
            // saved). Preferred over Sleep for long idles — s2idle drains
            // ~1.5%/h here (~20% overnight) and deep/S3 is unusable on this
            // Raptor Lake firmware, never waking without a hard power cycle.
            // Same hypridle guard as Sleep below: logind emits PrepareForSleep
            // for hibernate too, so hypridle's before_sleep_cmd runs and
            // inhibit_sleep=3 holds the inhibitor until the session is really
            // locked — the machine cannot write the image while still unlocked.
            sleepProc.command = ["bash", "-c",
                "~/.config/scripts/ensure-hypridle.sh; systemctl hibernate"]
            sleepProc.running = true
            break
        case "sleep":
            // ensure-hypridle.sh, not an inline respawn. hypridle is what runs
            // before_sleep_cmd (raising the lockscreen) and what holds the
            // delay inhibitor until the session is genuinely locked, so if it
            // has been toggled off via idle-inhibitor.sh the machine would
            // otherwise sleep unlocked. The previous inline
            // `hypridle & disown; sleep 0.5` looked equivalent but was not:
            // a Quickshell Process hands its child a pipe, so that hypridle
            // was killed by SIGPIPE as soon as this command exited, taking its
            // inhibitor with it. See ensure-hypridle.sh.
            sleepProc.command = ["bash", "-c",
                "~/.config/scripts/ensure-hypridle.sh; systemctl suspend"]
            sleepProc.running = true
            break
        case "shutdown":
            runProc.command = ["systemctl", "poweroff"]
            runProc.running = true
            break
        case "reboot":
            runProc.command = ["systemctl", "reboot"]
            runProc.running = true
            break
        case "logout":
            runProc.command = ["bash", "-c",
                "if [ \"$XDG_CURRENT_DESKTOP\" = \"Hyprland\" ]; then " +
                "hyprctl dispatch 'hl.dsp.exit()'; " +
                "elif [ \"$DESKTOP_SESSION\" = \"plasma\" ]; then " +
                "qdbus org.kde.ksmserver /KSMServer logout 0 0 0; " +
                "else pkill -KILL -u \"$USER\"; fi"]
            runProc.running = true
            break
        }
    }

    property var runProc: Process { id: runProc; running: false }
    property var sleepProc: Process { id: sleepProc; running: false }
}
