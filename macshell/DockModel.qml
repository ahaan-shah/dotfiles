import QtQuick

// NOTE: ListElement values must be compile-time literals — no bindings, no JS —
// so a home-relative icon path cannot call Quickshell.env() here. Such paths are
// written with a leading "~/" and expanded by Dock.qml's _expandHome() as the
// model is read in _rebuild(). Keeps this file free of any hardcoded username.
ListModel {

    ListElement {
        name: "Terminal"
        icon: "/usr/share/icons/Papirus-Dark/128x128/apps/kitty.svg"
        command: "kitty"
        windowClass: "kitty"
        separator: false
    }
     ListElement {
        name: "Spotify"
        icon: "/usr/share/icons/Papirus-Dark/128x128/apps/spotify.svg"
        command: "spotify"
        // lowercase native Wayland app-id, not the old XWayland WM_CLASS
        // ("Spotify") — since ~/.config/spotify-flags.conf added
        // --ozone-platform=wayland, and DockIcon.qml's cycleClass Process
        // builds a case-sensitive "class:<windowClass>" hyprctl selector
        windowClass: "spotify"
        separator: false
    }
     ListElement {
        name: "Whatsapp"
        icon: "/usr/share/icons/Papirus-Dark/128x128/apps/whatsie.svg"
        command: "chromium --app=https://web.whatsapp.com"
        windowClass: "whatsapp"
        separator: false
    }
    ListElement {
        name: "Chromium"
        icon: "/usr/share/icons/Papirus-Dark/128x128/apps/chromium.svg"
        command: "chromium"
        windowClass: "chromium"
        separator: false
    }
    ListElement {
        name: "Zen"
        icon: "/usr/share/icons/Papirus-Dark/128x128/apps/zen-browser.svg"
        command: "zen-browser"
        windowClass: "zen"
        separator: false
    }
    ListElement {
        name: "ChatGPT"
        icon: "~/.local/share/icons/webapps/openai.svg"
        command: "chromium --app=https://chat.openai.com"
        windowClass: "chat.openai"
        separator: false
    }
    ListElement {
        name: "Claude"
        icon: "~/.local/share/icons/webapps/claude.png"
        command: "chromium --app=https://claude.ai/new"
        windowClass: "claude.ai"
        separator: false
    }
    ListElement {
        name: "VSCodium"
        icon: "/usr/share/icons/Papirus-Dark/128x128/apps/vscodium.svg"
        command: "codium"
        windowClass: "codium"
        separator: false
    }
    ListElement {
        name: "TradingView"
        icon: "~/.local/share/icons/webapps/tradingview.svg"
        command: "chromium --app=https://www.tradingview.com/chart/lCRrEItS/"
        windowClass: "tradingview"
        separator: false
    }
     ListElement {
        name: "Text-Editor"
        icon: "/usr/share/icons/Papirus-Dark/128x128/apps/text-editor.svg"
        command: "gnome-text-editor"
        windowClass: "org.gnome.TextEditor"
        separator: false
    }
     ListElement {
        name: "Papers"
        icon: "/usr/share/icons/Papirus-Dark/128x128/apps/org.gnome.Papers.svg"
        command: "papers"
        windowClass: "org.gnome.Papers"
        separator: false
    }
    ListElement {
        name: "Files"
        icon: "/usr/share/icons/Papirus-Dark/128x128/apps/org.kde.dolphin.svg"
        command: "nautilus"
        windowClass: "org.gnome.Nautilus"
        separator: false
    }
}
