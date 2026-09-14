import Quickshell

// hyprahaan's shell — the whole user-facing desktop in one Quickshell process.
//
// ── Why one process ───────────────────────────────────────────────────────
// It was three: macshell (dock + Alt-Tab switcher + wallpaper), taskbar (bar,
// eight dropdowns, the notification daemon, the OSD, reminders) and finder (the
// launcher and its eight modes, including the settings menu). Measured before
// the merge: 149.6 + 138.1 + 107.4 = 395.1 MB PSS.
//
// Almost none of that was the desktop. Each instance carried its own QML
// engine, its own scene graph, its own GPU context and its own copies of the
// singletons the other two already had — and this repo had already measured
// that cost once, when macdock and macswitcher were merged into macshell and
// ~72 MB of pure per-process overhead went with the second process. Three
// instances is that mistake twice more.
//
// Ahaan's ask: "combine macshell, taskbar and finder into one shell … it
// reduces clutter and makes the entire system work on one beautiful shell …
// I want the shell to be lean and clean and still do everything it does now."
//
// ── Why this file is four lines long ──────────────────────────────────────
// Because a QML file is its own id scope, the merge did NOT mean pasting 17k
// lines together. Each of the three roots became a component — taskbar's
// `Scope { id: root }` is Bar.qml unchanged, and the two ShellRoots became
// Scopes, which is the only edit either needed. Their internal ids, their
// `root.` references and every comment in them survive intact, which is the
// whole reason this was safe to do at all.
//
// What genuinely merged is underneath, and it is what the second half of the
// work was: one UiConfig where there were three, one WalColors where there were
// two plus a third copy of the same palette parsed out of colors-waybar.css,
// one inotify watch on the state directory where the dock and the wallpaper
// each had their own, and the launcher's two big indexes — the emoji table and
// the .desktop scan — built on first use instead of at startup. 395 MB to 200.
// The system map's "One shell" section has the measurements.
ShellRoot {
    // Order is draw order for nothing (every surface below is its own layer),
    // but it IS startup order, and the wallpaper coming up first is the one
    // that matters: everything else on this desktop appears over the top of it.
    MacShell {}
    Bar {}
    Launcher {}
}
