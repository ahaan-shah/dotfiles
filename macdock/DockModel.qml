import QtQuick

ListModel {

    ListElement {
        name: "Terminal"
        icon: "/usr/share/icons/Papirus/128x128/apps/kitty.svg"
        command: "kitty"
        windowClass: "kitty"
        separator: false
    }
     ListElement {
        name: "Spotify"
        icon: "/usr/share/icons/Papirus/128x128/apps/spotify.svg"
        command: "spotify"
        windowClass: "Spotify"
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
        name: "Librewolf"
        icon: "/usr/share/icons/Papirus-Dark/128x128/apps/librewolf.svg"
        command: "librewolf --new-window"
        windowClass: "librewolf"
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
        name: "Claude"
        icon: "file:///home/ahaan/.local/share/icons/webapps/claude.png"
        command: "chromium --app=https://claude.ai/new"
        windowClass: "claude.ai"
        separator: false
    }
    ListElement {
        name: "ChatGPT"
        icon: "file:///home/ahaan/.local/share/icons/webapps/openai.svg"
        command: "chromium --app=https://chat.openai.com"
        windowClass: "chat.openai"
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
        icon: "/home/ahaan/.local/share/icons/webapps/tradingview.svg"
        command: "chromium --app=https://www.tradingview.com/chart/lCRrEItS/"
        windowClass: "tradingview"
        separator: false
    }
     ListElement {
        name: "Text-Editor"
        icon: "/usr/share/icons/Papirus/128x128/apps/text-editor.svg"
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
        icon: "/usr/share/icons/Papirus-Dark/128x128/apps/nautilus-alt.svg"
        command: "nautilus"
        windowClass: "org.gnome.Nautilus"
        separator: false
    }
}
