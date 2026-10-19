pragma Singleton

// JarvisState.qml — the one place EVE's state lives, for the surfaces that
// show it: the pill, its session list and the flight (Jarvis.qml), and the
// orb and the card in the bar's centre island (Bar.qml). None of them talk to
// each other; all of them read this.
//
// Since 2026-10-20 EVE is Claude, not a local planner: Ahaan scrapped the
// Qwen-on-the-3050 brain ("not too good on my gpu and hardware setup") and
// asked for "claude via my own setup here instead of an app" — the quick
// questions he would otherwise open claude.ai for. Each message is one turn
// of a Claude Code session, run by ../jarvis/chat.py (the repo's copy from a
// repo-path instance, the deployed one from ~/.config/shell), which prints
// JSON lines this turns into a phase and a card:
//
//   idle ──open()──▶ prompt ──submit()──▶ launch ──landed()──▶ working ──▶ result
//     ▲                 │ Esc                (flight)      (status drops down,  │
//     │                 │                                   then the reply     │
//     │                 │                                   streams into it)   │
//     └─────────────────┴──────────────── dismiss() ◀──────────────────────────┘
//
// Sessions: SUPER+ALT+SPACE carries on the current conversation, SUPER+SPACE
// starts a new one, and Down in the pill lists EVE's sessions to switch to.
// The id is made HERE, so a second message typed while the first of a new
// conversation is still running goes to the same conversation (chat.py
// decides per turn whether the id is new or resumed).
//
// The old planner's files (brain.py, act.py, jarvis.py, server.sh) are left in
// ../jarvis unused; nothing here starts the model server or wakes the dGPU.
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    readonly property string dir: {
        const d = String(Quickshell.shellDir || "").replace(/^file:\/\//, "")
        const cut = d.lastIndexOf("/")
        return cut > 0 ? d.substring(0, cut) + "/jarvis"
                       : (Quickshell.env("HOME") || "") + "/.config/jarvis"
    }
    readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || "/run/user/1000"
    readonly property string chat: root.dir + "/chat.py"

    // The run: idle | launch (flying to the bar) | working | result.
    property string phase: "idle"
    // The pill is NOT a phase: it can be open while a request is running, so a
    // second one can be typed and queued (Ahaan, 2026-10-06: "if i press super
    // space, it allows me to send in another request which sends after the
    // first one is done").
    property bool prompting: false
    property var queue: []              // [{ text, sid }]
    property bool voice: false
    property string query: ""
    property var current: null          // the card: a reply, an error, a command to approve
    property int selected: 0            // unused since the planner went; JarvisCard's pick list reads it
    property bool awaitingPassword: false

    // The bar's orb slot and island, registered by Bar.qml so the flight knows
    // where to land and the click-catcher knows what not to cover.
    property var slot: null
    property var island: null

    signal launched()                   // a request just left the pill: fly it

    readonly property bool busy: phase === "launch" || phase === "working"
    readonly property bool orbVisible: phase === "working" || phase === "result"

    // What the island shows. While she works it drops down on its own — the
    // spinner words at first, then the reply as it streams in (Ahaan,
    // 2026-10-20: "when claude is thinking, id like to see the bar show me the
    // percolating, thinking ... text by dropping down a little. It does this
    // on click rn"). A command waiting for a yes or no outranks both.
    readonly property var card: {
        if (approvals.length) return _approveCard(approvals[0])
        if (current) return current
        if (phase !== "working" || hidden) return null
        if (live !== "") return { kind: "reply", body: live, streaming: true, query: query }
        return { kind: "status", msg: status + (queue.length ? "   ·   " + queue.length + " queued" : "") }
    }
    readonly property bool expanded: card !== null && phase !== "launch"
    // A finished reply stays until a click elsewhere, like a panel (Ahaan,
    // 2026-10-20); so does a command to approve, whose keys need the catcher.
    // A reply still streaming does not take the keyboard from whatever you
    // were typing into — it scrolls under the pointer like any island.
    readonly property bool interactive: expanded && card !== null &&
        (card.kind === "approve" || (card.kind === "reply" && !card.streaming))
    readonly property string mood: {
        if (approvals.length) return "ask"
        if (busy) return "think"
        if (!current) return "idle"
        if (current.kind === "error") return "error"
        return "happy"
    }

    // ── entry points ────────────────────────────────────────────────────
    // Settings -> AI. Off means off: no pill, no voice.
    readonly property bool enabled: UiConfig.aiEnabled !== "off"
    onEnabledChanged: {
        if (enabled) return
        if (liveProc.running) liveProc.running = false     // and Claude with it
        cancel()
        dismiss()
    }
    readonly property string model: ["sonnet", "haiku", "opus"].indexOf(UiConfig.aiModel) >= 0 ? UiConfig.aiModel : "sonnet"

    // fresh: SUPER+SPACE, a new conversation from this message on.
    function open(withVoice, fresh) {
        if (!enabled) return
        voice = !!withVoice
        if (fresh || sessionId === "") newSession()
        prompting = true
        listSessions()
        warm()
    }

    function cancel() {
        if (!prompting) return
        if (voice && voxState !== "idle") _vox("cancel")
        voice = false
        prompting = false
        _closeIfDone()
    }

    function submit(text) {
        text = String(text || "").trim()
        if (!prompting) return
        if (text === "") { cancel(); return }
        voice = false
        prompting = false
        root.launched()
        const job = { text: text, sid: sessionId }
        // A finished reply is simply replaced by the next one.
        if (phase === "result") { _clear(); phase = "idle" }
        if (phase === "idle") _start(job, true)
        else queue = queue.concat([job])
    }

    // The reply box under a finished answer (Bar.qml): the same as sending
    // from the pill, without the pill — no flight, the card simply turns into
    // the status line and then the next reply, in the same conversation.
    function followUp(text) {
        text = String(text || "").trim()
        if (!enabled || text === "") return
        const job = { text: text, sid: sessionId }
        if (phase === "result") { _clear(); phase = "idle" }
        if (phase === "idle") _start(job, false)
        else queue = queue.concat([job])
    }

    function _start(job, fly) {
        _clear()
        query = job.text
        phase = fly ? "launch" : "working"
        _status()
        _send(job)
    }

    // The flight has landed in the bar. A reply may already be waiting.
    function landed() {
        if (phase !== "launch") return
        phase = "working"
        if (_pending) { const p = _pending; _pending = null; _show(p) }
    }

    function dismiss() {
        // Clicking away from a command is a no: it is the answer that changes
        // nothing, and the run is blocked until there is one.
        if (approvals.length) { deny(); return }
        if (busy) { hidden = true; return }     // the run carries on; the orb brings it back
        if (phase === "idle") return
        _clear()
        phase = "idle"
        if (queue.length) {                     // the next one goes the moment this is done
            const next = queue[0]
            queue = queue.slice(1)
            _start(next, false)
        } else _closeIfDone()
    }

    // The orb, clicked: closes a card, or brings back the one you hid.
    function orbClicked() {
        if (!enabled) return
        if (busy) { hidden = !hidden; return }
        if (current) dismiss()
    }

    // ── sessions ────────────────────────────────────────────────────────
    property string sessionId: ""
    property string sessionTitle: ""            // "" for a conversation not started yet
    property var sessions: []                   // [{ id, title, model, updated }], newest first

    function newSession() {
        // RFC 4122 v4 from Math.random: an id for a transcript file, not a
        // secret, and chat.py checks its shape before using it.
        const h = "0123456789abcdef"
        let s = ""
        for (let i = 0; i < 36; i++) {
            if (i === 8 || i === 13 || i === 18 || i === 23) s += "-"
            else if (i === 14) s += "4"
            else if (i === 19) s += h[8 + Math.floor(Math.random() * 4)]
            else s += h[Math.floor(Math.random() * 16)]
        }
        sessionId = s
        sessionTitle = ""
    }
    function useSession(s) {
        if (!s) newSession()
        else { sessionId = s.id; sessionTitle = s.title || "" }
        if (prompting) warm()
    }
    function listSessions() { if (!listProc.running) listProc.running = true }

    Process {
        id: listProc
        command: ["python3", root.chat, "list"]
        stdout: StdioCollector {
            onStreamFinished: {
                let d
                try { d = JSON.parse(text) } catch (e) { return }
                root.sessions = d.sessions || []
                // First run after a restart: carry on where the last one was.
                if (root.sessionId === "" && d.current) {
                    const s = root.sessions.find(x => x.id === d.current)
                    if (s) root.useSession(s)
                }
                if (root.sessionId === "") root.newSession()
                // A title arrives once a new conversation's first answer does.
                const me = root.sessions.find(x => x.id === root.sessionId)
                if (me) root.sessionTitle = me.title
            }
        }
        stderr: StdioCollector {}
    }
    Component.onCompleted: listSessions()

    // ── the status line ─────────────────────────────────────────────────
    property bool hidden: false
    property string live: ""
    property string status: "Thinking…"
    property string stepTool: ""
    // What she is doing, when there is a step to name; otherwise one of these,
    // changing every 1.1 s — "like you do", Ahaan said, meaning Claude Code's
    // own spinner words.
    readonly property var verbs: ["Thinking", "Mulling", "Pondering", "Skedaddling", "Noodling", "Cogitating",
                                  "Rummaging", "Tinkering", "Percolating", "Scheming", "Brewing", "Moseying",
                                  "Puzzling", "Wrangling", "Conjuring", "Fiddling", "Dazzling", "Marinating"]
    readonly property var steps: ({
        "WebSearch": "Searching the web", "WebFetch": "Reading a page", "web_search": "Searching the web",
        "web_fetch": "Reading a page", "Read": "Reading a file", "Glob": "Looking through your projects",
        "Grep": "Looking through your projects", "Bash": "Running a command" })
    function _status() {
        if (stepTool && steps[stepTool]) { status = steps[stepTool] + "…"; return }
        let v = status
        while (v === status) v = verbs[Math.floor(Math.random() * verbs.length)] + "…"
        status = v
    }
    Timer {
        interval: 1100; repeat: true
        running: root.phase === "working" && root.live === ""
        onTriggered: { root.stepTool = ""; root._status() }
    }

    // ── manual mode: a command, yes or no ───────────────────────────────
    // chat.py's hook holds every Bash command until it is answered here.
    // Claude can ask for several at once (measured: uptime and whoami in one
    // turn), so they are queued and asked one by one.
    property var approvals: []          // [{ dir, id, command, description }]
    function _approveCard(a) {
        return { kind: "approve", msg: a.description || "Run this command?", command: a.command,
                 more: approvals.length - 1 }
    }
    function allow() { _answer(true) }
    function deny()  { _answer(false) }
    function _answer(yes) {
        if (!approvals.length) return
        const a = approvals[0]
        approvals = approvals.slice(1)
        // Detached and fire-and-forget: the answer is one small file.
        Quickshell.execDetached(["python3", root.chat, "answer", a.dir, a.id, yes ? "yes" : "no"])
    }

    // ── files a reply names ─────────────────────────────────────────────
    // chat.py does the opening (Settings' editor for text, the xdg default
    // for the rest, the file manager for "reveal"); the card stays up, so a
    // second file can be opened from the same answer.
    function openPath(p)   { Quickshell.execDetached(["python3", root.chat, "open", String(p)]) }
    function revealPath(p) { Quickshell.execDetached(["python3", root.chat, "reveal", String(p)]) }

    // ── internals ───────────────────────────────────────────────────────
    property var _pending: null

    function _clear() {
        query = ""; current = null; selected = 0; live = ""; hidden = false
        awaitingPassword = false; _pending = null; stepTool = ""
    }

    function _event(line) {
        let e
        try { e = JSON.parse(line) } catch (err) { console.warn("eve: bad line:", line); return }
        if (e.ev === "step") { root.stepTool = e.tool || ""; root._status() }
        else if (e.ev === "delta") root.live = e.text || ""
        else if (e.ev === "approve") { root.approvals = root.approvals.concat([e]); root.hidden = false }
        else if (e.ev === "result") {
            if (e.kind === "reply") { e.query = root.query; root.sessionTitle = e.title || root.sessionTitle }
            root._result = e
        }
        else if (e.ev === "done") _finish()
    }
    property var _result: null

    function _finish() {
        const card = _result || { kind: "error", msg: "Claude didn't answer" }
        _result = null
        approvals = []
        listSessions()
        if (phase === "launch") _pending = card     // still flying: show it on landing
        else _show(card)
    }

    function _show(card) {
        current = card
        hidden = false
        phase = "result"
        collapseTimer.stop()
        // An error says what went wrong and goes after 4 s; a reply stays.
        if (card.kind === "error") { collapseTimer.interval = 4000; collapseTimer.restart() }
        // A reply comes with a reply box: have Claude ready for it.
        if (card.kind === "reply") warm()
    }

    Timer { id: collapseTimer; onTriggered: root.dismiss() }

    // ── Claude, kept running ────────────────────────────────────────────
    // `chat.py serve MODEL SESSION` is started when the pill opens and when a
    // reply box appears, before anything is typed, and stays up for the
    // follow-ups: Enter then skips Claude Code's startup (measured from Enter
    // to the first word: 2.3 s started cold, 1.2 s pre-started). Messages go
    // in as JSON lines on its stdin; each turn ends with a "done" line. It is
    // keyed by model and session — picking another of either restarts it.
    //
    // Its life is the conversation's on screen (Ahaan, 2026-10-20): up from
    // the moment either key opens the pill, up while the reply panel is open
    // — so every reply from the box is fast — and stopped the moment nothing
    // is open: the panel clicked away, or the pill cancelled unsent. The
    // next SUPER+ALT+SPACE starts it again on the same session. A 2-minute idle
    // timer did this for one commit, and stopped Claude under an open panel.
    //
    // Waiting costs nothing: no request is made until a message is sent.
    // Staying up saves TIME, not tokens — each turn still sends the whole
    // conversation; what makes that cheap is the API's prompt cache
    // (~5 min), which works the same whether the process stayed up or not.
    property string _liveKey: ""                 // model|session of the running one
    property var _want: null                     // { key, sid, model } to start next
    property var _outbox: []                     // lines waiting for it to be up

    function warm() { _ensure(root.sessionId) }
    function _ensure(sid) {
        if (!enabled || !sid) return
        const key = root.model + "|" + sid
        if (liveProc.running && _liveKey === key) return
        _want = { key: key, sid: sid, model: root.model }
        if (liveProc.running) liveProc.running = false     // onRunningChanged starts the new one
        else _launch()
    }
    // Nothing on screen and nothing running: Claude goes too.
    function _closeIfDone() {
        if (prompting || phase !== "idle" || queue.length || approvals.length) return
        _want = null
        _outbox = []
        if (liveProc.running) liveProc.running = false
    }
    function _launch() {
        if (!_want) return
        const w = _want
        _want = null
        _liveKey = w.key
        liveProc.command = ["python3", root.chat, "serve", w.model, w.sid]
        liveProc.running = true
    }
    function _send(job) {
        _ensure(job.sid)
        _outbox = _outbox.concat([JSON.stringify({ text: job.text }) + "\n"])
        if (liveProc.running && !_want) _flush()
    }
    function _flush() {
        const out = _outbox
        _outbox = []
        for (const l of out) liveProc.write(l)
    }

    Process {
        id: liveProc
        stdinEnabled: true
        stdout: SplitParser { onRead: data => root._event(data) }
        stderr: StdioCollector { id: liveErr }
        onStarted: root._flush()
        onRunningChanged: {
            if (running) return
            root._liveKey = ""
            if (root._want) root._launch()
        }
        onExited: (code, status) => {
            // Stopped on purpose (panel closed, or another model/session) between
            // turns is normal; mid-turn it is a failure to report.
            if (root.busy && !root._want) {
                console.warn("chat.py serve ended mid-turn:", liveErr.text)
                const card = { kind: "error", msg: "Something went wrong — see the shell log" }
                if (root.phase === "launch") root._pending = card
                else root._show(card)
            }
        }
    }

    // Kept so Finder/Settings' jarvis password path still resolves; nothing
    // raises it since the planner went.
    function confirm() {}
    function choose(i) {}
    function passwordAccepted(token) { awaitingPassword = false }
    function passwordCancelled() { awaitingPassword = false }

    // ── voice ───────────────────────────────────────────────────────────
    // voxtype types into whatever has the keyboard, and the pill has it
    // exclusively, so the transcription simply arrives as typing. All this
    // needs is to start it, and to stop it on Enter and wait for the text.
    // (Its key went to "new conversation" on 2026-10-20; `ipc call jarvis
    // voice` still works.)
    property string voxState: "idle"          // idle | recording | transcribing
    FileView {
        path: root.runtimeDir + "/voxtype/state"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.voxState = (text() || "idle").trim()
    }
    Process { id: voxProc; stderr: StdioCollector {} }
    function _vox(verb) {
        voxProc.command = ["voxtype", "record", verb]
        voxProc.running = true
    }
    function startVoice() { if (voxState === "idle") _vox("start") }
    function stopVoice()  { if (voxState === "recording") _vox("stop") }
}
