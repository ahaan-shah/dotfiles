pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Loads the bundled emoji-data.json (name -> glyph, generated from Python's
// unicodedata names — not exact CLDR short names, but functionally
// equivalent and covers ~1900 single-codepoint emoji) and exposes search.
QtObject {
    id: root

    property var emoji: []   // [{emoji, name}], sorted alphabetically by name
    property string _buf: ""

    property var _proc: Process {
        id: proc
        command: ["cat", Quickshell.shellPath("emoji-data.json")]
        running: false
        stdout: StdioCollector {
            id: out
            onStreamFinished: root._parse(out.text)
        }
    }

    function _parse(raw) {
        try {
            root.emoji = JSON.parse(raw)
        } catch (e) {
            console.warn("EmojiIndex: failed to parse emoji-data.json:", e)
            root.emoji = []
        }
    }

    function search(query, limit) {
        const n = limit || 50
        if (!query) return root.emoji.slice(0, n)
        const q = query.toLowerCase()
        const hits = []
        for (const e of root.emoji) {
            if (e.name.includes(q)) hits.push(e)
        }
        hits.sort((a, b) => {
            const ap = a.name.startsWith(q) ? 0 : 1
            const bp = b.name.startsWith(q) ? 0 : 1
            if (ap !== bp) return ap - bp
            return a.name.localeCompare(b.name)
        })
        return hits.slice(0, n)
    }

    function copy(glyph) {
        copyProc.command = ["bash", "-c", "printf '%s' " + _shellQuote(glyph) + " | wl-copy"]
        copyProc.running = true
    }

    function _shellQuote(s) {
        return "'" + String(s).replace(/'/g, "'\\''") + "'"
    }

    property var copyProc: Process { id: copyProc; running: false }

    Component.onCompleted: { proc.running = true }
}
