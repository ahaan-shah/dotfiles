import QtQuick

// THE FIRST-RUN SEED, not the dock. What is actually pinned lives in
// ~/.local/state/hyprahaan/dock-pins.json and is edited by right-clicking an
// icon — see DockPins.qml, which reads this file exactly once, on a machine
// that has no store yet.
//
// It is two entries on purpose. This used to be eleven, naming Spotify, Zen,
// VSCodium, two chromium webapps and the rest of one machine's software, so a
// fresh install of these dotfiles came up with a dock of icons for apps that
// were not installed and could not be launched. A terminal and a file manager
// are the two things an Arch desktop can assume it has; everything else
// arrives in the dock by being opened, and stays by being right-clicked.
//
// NOTE: ListElement values must be compile-time literals — no bindings, no JS —
// so a home-relative icon path cannot call Quickshell.env() here. Such paths are
// written with a leading "~/" and expanded by Dock.qml's _resolveDockIcon() as
// the model is read in _rebuild(). Keeps this file free of any hardcoded username.
//
// `icon` takes three shapes, all resolved by that same function:
//   "kitty"              an icon NAME, looked up in whatever icon theme is
//                        currently set (Settings -> Icons), falling back to
//                        Papirus-Dark. These used to be absolute
//                        /usr/share/icons/Papirus-Dark/… paths, which is why
//                        the dock kept its old icons after a theme change while
//                        every GTK app had already switched.
//   "~/…"                a home-relative file, for the webapp marks that no
//                        icon theme ships.
//   "/…"                 an absolute file, used as-is.
ListModel {

    ListElement {
        name: "Terminal"
        icon: "kitty"
        command: "kitty"
        windowClass: "kitty"
        separator: false
    }
    ListElement {
        name: "Files"
        // Dolphin's icon over Nautilus's own — IconResolver.qml carries the
        // matching alias so an unpinned Nautilus window looks the same.
        icon: "org.kde.dolphin"
        command: "nautilus"
        windowClass: "org.gnome.Nautilus"
        separator: false
    }
}
