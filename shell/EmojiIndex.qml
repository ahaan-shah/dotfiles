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
        copyProc.command = ["bash", "-c", "printf '%s' " + Sys.quote(glyph) + " | wl-copy"]
        copyProc.running = true
    }


    property var copyProc: Process { id: copyProc; running: false }

    // ── loaded on first use, not at startup ──────────────────────────────
    // This used to `cat` and JSON.parse emoji-data.json the moment the shell
    // came up: 94 KB on disk becoming a few thousand JS objects that live for
    // the session, for a mode reached with SUPER+. and used occasionally. In
    // three separate processes it was invisible; in one shell that is meant to
    // be lean at startup it is exactly the kind of thing to defer.
    //
    // Finder.openMode() calls this before it rebuilds the emoji list, and the
    // rebuild is already re-run when `emoji` lands (see onEmojiChanged there),
    // so the first open simply fills a frame later. Idempotent: the guard is
    // what makes it safe to call on every open.
    property bool _started: false
    function ensure() {
        if (root._started) return
        root._started = true
        proc.running = true
    }
}
