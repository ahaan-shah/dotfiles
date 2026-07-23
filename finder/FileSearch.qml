pragma Singleton

import QtQuick
import Quickshell.Io

// Fuzzy filename search via `fd` (fast filesystem walk) piped through
// `fzf --filter` (fuzzy scoring, non-interactive) across the user's home dir.
// Also builds previews for the selected result: plain text dump for text
// files, direct image display for pictures, and a rendered first page (via
// pdftoppm) for PDFs.
QtObject {
    id: root

    property var results: []      // [{name, path, isDir, subtext}]
    property string _query: ""

    property var _searchProc: Process {
        id: searchProc
        running: false
        stdout: StdioCollector {
            id: searchOut
            onStreamFinished: root._parseResults(searchOut.text)
        }
    }

    function search(query, limit) {
        root._query = query
        if (!query || query.length < 2) { root.results = []; return }
        const n = limit || 10
        // fd: search files+dirs under $HOME only, case-insensitive. No --hidden
        // — dotfiles/dotdirs (.cache, .config, .mozilla, etc.) are noisy and
        // not what the user means by "search my files", so leave them at fd's
        // default (excluded), which also keeps the tree small enough that no
        // --max-results cap is needed (fd enumerates ~60ms even unbounded).
        // fzf --filter: score+sort by the same query, non-interactive, best matches first.
        const cmd =
            "fd --type f --type d --exclude node_modules . ~ 2>/dev/null | " +
            "fzf --filter=" + root._shellQuote(query) + " 2>/dev/null | head -n " + n
        searchProc.command = ["bash", "-c", cmd]
        searchProc.running = true
    }

    function _parseResults(raw) {
        const home = root._homeDir
        const lines = raw.split("\n").map(l => l.trim()).filter(l => l.length > 0)
        root.results = lines.map(rawPath => {
            // fd appends a trailing "/" to directory results.
            const isDir = rawPath.endsWith("/")
            const p = isDir ? rawPath.slice(0, -1) : rawPath
            const parts = p.split("/")
            const name = parts[parts.length - 1]
            let dir = parts.slice(0, -1).join("/")
            if (home && dir.startsWith(home)) dir = "~" + dir.slice(home.length)
            return { name, path: p, isDir, subtext: dir }
        })
    }

    property string _homeDir: ""

    property var _homeProc: Process {
        id: homeProc
        command: ["bash", "-c", "echo -n $HOME"]
        running: true
        stdout: StdioCollector {
            id: homeOut
            onStreamFinished: root._homeDir = homeOut.text
        }
    }

    // ── Preview ──────────────────────────────────────────────────────
    // previewFor() is async across up to two hops (mime detection, then
    // pdf/text rendering) — fills `preview` and bumps `previewToken` when done.
    //
    // Every hop is guarded by comparing the path it was launched for against
    // `_previewPath` (the most recently *requested* path) before applying its
    // result. Without this, fast selection changes race: reassigning a
    // Process's `command` while it's still `running` is a no-op until the
    // in-flight run finishes, so a stale result for the previous item could
    // land and get shown as if it belonged to the newly selected one. Forcing
    // `running = false` before restarting, plus the path check as a second
    // line of defense, closes both halves of that race.
    property var preview: null   // {type:"text"|"image"|"pdf"|"none", text, source}
    property int previewToken: 0
    property string _previewPath: ""
    property string _mimeCallPath: ""
    property string _pdfCallPath: ""
    property string _textCallPath: ""

    function previewFor(path) {
        root._previewPath = path
        root.preview = null
        root._mimeCallPath = path
        if (mimeProc.running) mimeProc.running = false
        mimeProc.command = ["bash", "-c", "file --mime-type -b " + _shellQuote(path)]
        mimeProc.running = true
    }

    function _shellQuote(s) {
        return "'" + String(s).replace(/'/g, "'\\''") + "'"
    }

    property var mimeProc: Process {
        id: mimeProc
        running: false
        stdout: StdioCollector {
            id: mimeOut
            onStreamFinished: root._onMime(mimeOut.text.trim())
        }
    }

    function _onMime(mime) {
        const path = root._mimeCallPath
        if (path !== root._previewPath) return   // superseded by a newer selection

        if (mime.startsWith("image/")) {
            root.preview = { type: "image", source: "file://" + path }
            root.previewToken++
        } else if (mime === "application/pdf") {
            root._pdfCallPath = path
            const prefix = "/tmp/finder-preview-" + Math.floor(Math.random() * 1000000)
            if (pdfProc.running) pdfProc.running = false
            pdfProc.command = ["bash", "-c",
                "pdftoppm -png -f 1 -l 1 -r 120 " + _shellQuote(path) + " " + _shellQuote(prefix) + " && ls " + prefix + "*"]
            pdfProc.running = true
        } else if (mime.startsWith("text/") || mime === "application/json" || mime === "inode/x-empty") {
            root._textCallPath = path
            if (textProc.running) textProc.running = false
            textProc.command = ["bash", "-c", "head -c 6000 " + _shellQuote(path)]
            textProc.running = true
        } else {
            root.preview = { type: "none" }
            root.previewToken++
        }
    }

    property var pdfProc: Process {
        id: pdfProc
        running: false
        stdout: StdioCollector {
            id: pdfOut
            onStreamFinished: {
                if (root._pdfCallPath !== root._previewPath) return
                const f = pdfOut.text.trim().split("\n")[0]
                if (f) { root.preview = { type: "image", source: "file://" + f }; root.previewToken++ }
                else   { root.preview = { type: "none" }; root.previewToken++ }
            }
        }
    }

    property var textProc: Process {
        id: textProc
        running: false
        stdout: StdioCollector {
            id: textOut
            onStreamFinished: {
                if (root._textCallPath !== root._previewPath) return
                root.preview = { type: "text", text: textOut.text }
                root.previewToken++
            }
        }
    }

    function open(path, isDir) {
        // inode/directory's xdg default handler is codium.desktop on this
        // system (confirmed via `xdg-mime query default inode/directory`),
        // so a bare xdg-open on a folder opens it in VSCodium instead of a
        // file manager. Route directories to nautilus directly; files still
        // go through xdg-open so each file type's real default app is used.
        openProc.command = isDir ? ["nautilus", path] : ["xdg-open", path]
        openProc.running = true
    }
    property var openProc: Process { id: openProc; running: false }
}
