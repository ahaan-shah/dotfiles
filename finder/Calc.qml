pragma Singleton

import QtQuick
import Quickshell.Io

// Wraps `qalc` (libqalculate) for real calculator/unit-conversion support.
// Only fires for queries containing a digit — qalc happily interprets bare
// words as units (e.g. "s" -> "1 s", the second) which would otherwise pop
// a bogus calc result on every plain-text search.
QtObject {
    id: root

    property string result: ""   // "" when no valid calc result for the current query
    property string expression: ""
    property int token: 0

    function hasDigit(q) { return /\d/.test(q) }

    function evaluate(query) {
        if (!query || !hasDigit(query)) { root.result = ""; return }
        proc.command = ["bash", "-c", "qalc -t " + _shellQuote(query) + " 2>/dev/null"]
        proc._forQuery = query
        proc.running = true
    }

    function _shellQuote(s) {
        return "'" + String(s).replace(/'/g, "'\\''") + "'"
    }

    property var proc: Process {
        id: proc
        property string _forQuery: ""
        running: false
        stdout: StdioCollector {
            id: out
            onStreamFinished: {
                const text = out.text.trim()
                // Reject symbolic/unresolved answers (qalc echoes unknown
                // identifiers back as unit-like symbols, e.g. "1E-12 × if(y)").
                const looksNumeric = text.length > 0 &&
                    !/[a-zA-Z]{3,}\(/.test(text) &&
                    text !== proc._forQuery.trim()
                if (looksNumeric) {
                    root.result = text
                    root.expression = proc._forQuery
                } else {
                    root.result = ""
                }
                root.token++
            }
        }
    }
}
