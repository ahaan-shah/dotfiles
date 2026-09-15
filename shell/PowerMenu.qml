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
        // First, on Ahaan's ask, and it is also the only row here that does
        // not end the session — everything below it either suspends the
        // machine or logs you out, so the one reversible action belongs where
        // the selection already is when the menu opens.
        { icon: "󰌾", label: "Lock",      key: "lock" },
        { icon: "󰤄", label: "Sleep",     key: "sleep" },
        { icon: "󰜗", label: "Hibernate", key: "hibernate" },
        { icon: "󰐥", label: "Shutdown",  key: "shutdown" },
        { icon: "󰜉", label: "Reboot",    key: "reboot" },
        { icon: "󰍃", label: "Logout",    key: "logout" }
    ]

    function run(key) {
        switch (key) {
        case "lock":
            // The same launcher SUPER+L runs, and never a bare
            // `quickshell -c lockscreen`: it must guard against a double
            // launch without ever pkill-ing an existing instance, because a
            // WlSessionLock process that dies without setting locked = false
            // leaves the compositor locked with nothing listening. See that
            // script's own header.
            //
            // The path is HARDCODED to ~/.config, deliberately, and this is
            // the one place in this repo where resolving beside the shell
            // would be wrong. Everything else here resolves a sibling
            // directory so a repo instance exercises the repo's copy with no
            // deploy (apply-wallpaper.sh, Settings.scriptDir) — but the thing
            // being exercised there is a wallpaper or a listing, and the
            // thing being exercised here is the only surface on this desktop
            // whose failure mode is an unrecoverable session. A repo instance
            // should lock with the lock screen that is known to work.
            // ensure-hypridle.sh below is hardcoded for the same reason and
            // has been since it was written.
            //
            // No detach wrapper, and that is not an oversight: the script
            // already spawns its quickshell with `setsid … </dev/null
            // >/dev/null 2>&1 9>&-` and then exits. It writes nothing to the
            // pipe it inherits from us in the two seconds it is alive, so
            // there is nothing for SIGPIPE to land on — same shape as the
            // systemctl calls below.
            runProc.command = ["bash", "-c", "~/.config/lockscreen/lockscreen-launch.sh"]
            runProc.running = true
            break
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
