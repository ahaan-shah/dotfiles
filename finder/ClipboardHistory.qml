pragma Singleton

import QtQuick
import Quickshell.Io

// cliphist isn't installed on this system, so this is a small homegrown
// clipboard history: a persistent `wl-paste --watch` listener writes each new
// clipboard entry — text OR image — to its own file under
// ~/.cache/finder/clipboard/, deduped against the most recent entry by
// content hash and capped at 200 files. Reading the history lists that
// directory newest-first; text entries are cat'd inline (marker-delimited),
// image entries are listed by filename only and previewed straight off disk
// by the UI — their bytes never get read into a JS string, which would
// corrupt them (command substitution / QString can't hold NUL bytes safely).
QtObject {
    id: root

    property string homeDir: ""
    readonly property string dir: root.homeDir + "/.cache/finder/clipboard"
    property bool _pendingRefresh: false

    property var entries: []   // [{kind:"text"|"image", text, preview, file, path}], newest first

    property var _homeProc: Process {
        id: homeProc
        command: ["bash", "-c", "echo -n $HOME"]
        running: true
        stdout: StdioCollector {
            id: homeOut
            onStreamFinished: {
                root.homeDir = homeOut.text
                root.startWatching()
                if (root._pendingRefresh) {
                    root._pendingRefresh = false
                    readProc.running = true
                }
            }
        }
    }

    // ── Persistent watcher — started once, runs for the life of the shell ──
    // Reads each clipboard change into a temp file first (binary-safe — no
    // shell variable ever holds the raw bytes), sniffs its mime type, dedupes
    // against the previous entry by sha256 (works uniformly for text and
    // binary), then moves it into place with an extension that encodes kind
    // (.txt for text, the sniffed image extension otherwise).
    //
    // `wl-paste --watch` can fire the callback multiple times in quick
    // succession for a single copy (confirmed live: one `wl-copy < img.png`
    // produced 4 near-simultaneous invocations) — without serializing them,
    // every invocation reads "last entry" before any of the others have
    // written theirs, so the sha256 dedup check races and all 4 copies land
    // as separate history entries. `flock` on a lockfile in $dir forces the
    // check-then-write to run as one atomic section per invocation.
    property var _watchProc: Process {
        id: watchProc
        running: false
        command: ["bash", "-c",
            "dir=" + root.dir + "; mkdir -p \"$dir\"; " +
            "wl-paste --watch bash -c '" +
            "dir=" + root.dir + "; " +
            "tmpf=$(mktemp); cat > \"$tmpf\"; " +
            "[ -s \"$tmpf\" ] || { rm -f \"$tmpf\"; exit 0; }; " +
            "( flock -x 200; " +
            "mime=$(file --mime-type -b \"$tmpf\"); " +
            "case \"$mime\" in image/*) ext=\"${mime#image/}\";; *) ext=txt;; esac; " +
            "newsum=$(sha256sum \"$tmpf\" | cut -d\" \" -f1); " +
            "last=$(ls -t \"$dir\" 2>/dev/null | grep -v \"\\.lock$\" | head -1); " +
            "if [ -n \"$last\" ] && [ \"$(sha256sum \"$dir/$last\" 2>/dev/null | cut -d\" \" -f1)\" = \"$newsum\" ]; then rm -f \"$tmpf\"; exit 0; fi; " +
            "mv \"$tmpf\" \"$dir/$(date +%s%N).$ext\"; " +
            "ls -t \"$dir\" | grep -v \"\\.lock$\" | tail -n +201 | while read -r f; do rm -f \"$dir/$f\"; done " +
            ") 200>\"$dir/.lock\"" +
            "'"]
    }

    function startWatching() {
        if (!watchProc.running) watchProc.running = true
    }

    // ── Reading history ─────────────────────────────────────────────
    property var _readProc: Process {
        id: readProc
        running: false
        command: ["bash", "-c",
            "dir=" + root.dir + "; mkdir -p \"$dir\"; " +
            "for f in $(ls -t \"$dir\" 2>/dev/null | grep -v '\\.lock$'); do " +
            "echo '---CLIP_ENTRY_START---'; echo \"FILE=$f\"; " +
            "case \"$f\" in *.txt) cat \"$dir/$f\";; esac; done"]
        stdout: StdioCollector {
            id: readOut
            onStreamFinished: root._parse(readOut.text)
        }
    }

    function refresh() {
        // homeDir resolves async on startup; if a refresh lands before it's
        // ready, `dir` would be a relative path with no $HOME prefix — defer.
        if (!root.homeDir) { root._pendingRefresh = true; return }
        readProc.running = true
    }

    function _parse(raw) {
        const blocks = raw.split("---CLIP_ENTRY_START---")
        const list = []
        blocks.forEach(rawBlock => {
            // Each block after the split starts with the newline left over
            // from the marker's own `echo`, which would otherwise shift the
            // "FILE=..." line detection below by one line — strip it first.
            const b = rawBlock.replace(/^\n/, "")
            if (!b.trim()) return
            const nl = b.indexOf("\n")
            const fileLine = (nl < 0 ? b : b.slice(0, nl)).trim()
            const file = fileLine.startsWith("FILE=") ? fileLine.slice(5) : ""
            if (!file) return
            const path = root.dir + "/" + file

            if (!file.endsWith(".txt")) {
                list.push({ kind: "image", text: "", preview: "Image", file, path })
                return
            }

            const text = (nl < 0 ? "" : b.slice(nl + 1)).replace(/\n$/, "")
            if (!text.trim()) return
            const firstLine = text.split("\n")[0]
            const preview = firstLine.length > 120 ? firstLine.slice(0, 120) + "…" : firstLine
            list.push({ kind: "text", text, preview, file, path })
        })
        root.entries = list
    }

    function search(query, limit) {
        const n = limit || 50
        if (!query) return root.entries.slice(0, n)
        const q = query.toLowerCase()
        return root.entries.filter(e =>
            e.kind === "image" ? "image".includes(q) : e.text.toLowerCase().includes(q)
        ).slice(0, n)
    }

    // entry.file is always a "<epoch-nanos>.<ext>" name we generated ourselves
    // (see the watcher command above), so it's safe to interpolate directly.
    function copyBack(entry) {
        if (entry.kind === "image") {
            const ext = entry.file.split(".").pop()
            copyProc.command = ["bash", "-c", "wl-copy -t image/" + ext + " < " + _shellQuote(entry.path)]
        } else {
            copyProc.command = ["bash", "-c", "wl-copy < " + _shellQuote(entry.path)]
        }
        copyProc.running = true
    }

    function _shellQuote(s) {
        return "'" + String(s).replace(/'/g, "'\\''") + "'"
    }

    property var copyProc: Process { id: copyProc; running: false }
}
