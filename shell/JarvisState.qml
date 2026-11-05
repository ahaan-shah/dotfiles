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
// The old planner's files (brain.py, jarvis.py, server.sh, eval/) were deleted
// on 2026-10-26; they are in git history. act.py stays: `chat.py open` uses
// its launcher. Nothing here starts a model server or wakes the dGPU.
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
    // `voxtype record start` failed: the daemon is off (Settings -> Tools ->
    // Voice typing). The pill says so and stays usable for typing.
    property bool voxOff: false
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
        if (current) return hidden ? null : current
        if (phase !== "working" || hidden) return null
        if (live !== "") return { kind: "reply", body: live, streaming: true, sealed: liveSealed, query: query, attached: queryFiles }
        return { kind: "status", msg: status + (queue.length ? "   ·   " + queue.length + " queued" : "") }
    }
    readonly property bool expanded: card !== null && phase !== "launch"
    // A finished reply stays until a click elsewhere, like a panel (Ahaan,
    // 2026-10-20); so does a command to approve, whose keys need the catcher.
    // A reply still streaming took no keyboard until 2026-11-03 (below).
    // Since 2026-11-02 the thinking words and a streaming reply raise the
    // catcher too, and since 2026-11-03 it takes their keys as well, so Esc
    // folds them the way a click outside does (Bar.qml's jarvisCatch). Ahaan: "if i click
    // outside the eve box like while it is thinking before response, it
    // closes that expansion, but it still does the thing i asked it to … so
    // the expand thing isnt in my way". The click hides the card (dismiss()
    // while busy), the run goes on, and the reply drops down by itself
    // (_show unhides).
    readonly property bool interactive: expanded && card !== null &&
        (card.kind === "approve" || card.kind === "reply" || card.kind === "status")
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
        clear()
    }
    readonly property string model: ["sonnet", "haiku", "opus"].indexOf(UiConfig.aiModel) >= 0 ? UiConfig.aiModel : "sonnet"
    // Settings -> AI -> EVE's capabilities (Basic / Advanced) is gone since
    // 2026-11-03: there is one kit, the broker's (chat.py's header says why).
    // UiConfig still reads AI_LEVEL from an old ui.conf; nothing uses it.

    // "Continue on the web" on a sealed reply (JarvisCard): a NEW
    // conversation, with the request in the pill for Ahaan to read, edit and
    // send. Nothing goes anywhere until he presses Enter.
    property string draft: ""
    function continueOnWeb(text) {
        if (!enabled) return
        dismiss()
        draft = String(text || "")
        open(false, true)
    }

    // SUPER+ALT+E: the selected text, as an attachment of a NEW conversation
    // (chat.py selection), so "explain this" needs no copy and paste.
    function sendSelection() {
        if (!enabled) return
        selProc.running = false
        selProc.running = true
    }
    Process {
        id: selProc
        command: ["python3", root.chat, "selection"]
        stdout: StdioCollector {
            onStreamFinished: {
                let f = []
                try { f = JSON.parse(text).files || [] } catch (e) {}
                root.open(false, true)
                if (f.length) root.attach(f)
            }
        }
        stderr: StdioCollector {}
    }

    // fresh: SUPER+SPACE, a new conversation from this message on.
    function open(withVoice, fresh) {
        if (!enabled) return
        voice = !!withVoice
        voxOff = false
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
        attachments = []
        _closeIfDone()
    }

    function submit(text) {
        text = String(text || "").trim()
        if (!prompting) return
        if (text === "" && !attachments.length) { cancel(); return }
        voice = false
        prompting = false
        root.launched()
        const job = { text: text, sid: sessionId, files: _takeFiles() }
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
        if (!enabled || (text === "" && !attachments.length)) return
        const job = { text: text, sid: sessionId, files: _takeFiles() }
        if (phase === "result") { _clear(); phase = "idle" }
        if (phase === "idle") _start(job, false)
        else queue = queue.concat([job])
    }

    function _start(job, fly) {
        _clear()
        query = job.text
        queryFiles = (job.files || []).map(f => f.split("/").pop())
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

    // A finished reply clicked away (or Esc, or a tenant opening) RESTS
    // rather than ending (Ahaan, 2026-11-02: "leave the eve icon in the bar
    // so if i close the reply box (post reply), i can open again right there
    // by left clicking the eve icon"). The orb stays, the reply is kept,
    // a left click on the orb brings it back with its reply box — the same
    // conversation goes on from there — and a right click clears it for good
    // (interrupt() when not busy). Claude itself is stopped while it rests:
    // its life is still "something open on screen" (see _closeIfDone), and a
    // parked orb can sit there for hours. Reopening warms it again — ~1 s
    // more to the first word of the next follow-up, measured cold vs warm
    // below (2.3 s / 1.2 s).
    // Errors still go by themselves after 4 s: nothing in one to come back to.
    // A queue waiting on this card still runs the moment it is clicked away.
    property bool resting: false
    function dismiss() {
        // Clicking away from a command is a no: it is the answer that changes
        // nothing, and the run is blocked until there is one.
        if (approvals.length) { deny(); return }
        if (busy) { hidden = true; return }     // the run carries on; the orb brings it back
        if (phase === "idle") return
        if (phase === "result" && current && current.kind === "reply" && !queue.length) {
            if (resting) return
            hidden = true; _parked = false; resting = true
            if (!prompting) attachments = []    // staged in a reply box clicked away
            _closeIfDone()
            return
        }
        clear()
    }
    // The whole card gone, orb and all: the right click on a resting or
    // finished reply, an error's 4 s, Settings turning EVE off.
    function clear() {
        if (approvals.length) { deny(); return }
        if (busy || phase === "idle") return
        _clear()
        if (!prompting) attachments = []        // staged in a reply box clicked away
        phase = "idle"
        if (queue.length) {                     // the next one goes the moment this is done
            const next = queue[0]
            queue = queue.slice(1)
            _start(next, false)
        } else _closeIfDone()
    }

    // The orb, right-clicked: Esc in Claude Code (Ahaan, 2026-10-26). Stops
    // the turn in flight by stopping chat.py — Claude and the broker with it;
    // the broker notices it was orphaned and drops any wait — and says so for
    // 4 s. The next message starts Claude again on the same session, so the
    // conversation goes on; anything queued runs once the card goes. A password
    // box EVE raised is closed: the root action it was for is off too.
    property bool _interrupted: false
    // Not busy, it clears a finished reply — shown or resting — orb and all
    // (Ahaan, 2026-11-02: "also clears eve from the bar if i right click
    // after a reply is done").
    function interrupt() {
        if (!busy) { clear(); return }
        if (approvals.length && approvals[0].kind === "privileged") privilegedCancel()
        approvals = []
        _result = null
        _interrupted = true
        if (liveProc.running) liveProc.running = false
        else { _interrupted = false; _show({ kind: "error", msg: "Interrupted" }) }
    }

    // The orb, clicked: closes a card, or brings back the one you hid.
    function orbClicked() {
        if (!enabled) return
        if (busy) { hidden = !hidden; return }
        // A parked reply (islandTaken) or a resting one: back, with its reply
        // box, and Claude started again for it.
        if (current && hidden) {
            hidden = false; _parked = false; resting = false
            if (current.kind === "reply") warm()
            return
        }
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
    property bool liveSealed: false     // the conversation has read something local (chat.py)
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
    // Which button the keyboard is on: Left/Right move it, Enter answers it
    // (Ahaan, 2026-10-21, replacing Ctrl+Left/Right). It starts on Yes for
    // every command — his call the same day, over a first cut that started
    // on No. The cost is known: this surface takes the keyboard the moment
    // the card appears, so an Enter meant for something else runs the
    // command. sudo and friends are still refused before they get here.
    property bool approveYes: true
    // A third answer on a read outside ~/EVE: "Yes, all of <folder>/", the
    // rest of that folder free for the conversation (broker.may_read). The
    // keyboard's pick is 0 No, 1 Yes, 2 the folder; approveYes stays the
    // name the rest of the shell reads ("is the pick a yes of some kind").
    property int approvePick: 1
    onApprovePickChanged: approveYes = approvePick > 0
    onApproveYesChanged: if (approveYes !== (approvePick > 0)) approvePick = approveYes ? 1 : 0
    function _startPick(a) { approvePick = a && a.pick === "no" ? 0 : 1 }
    function allowFolder() {
        if (approvals.length && approvals[0].always) _answer(true, "folder")
    }
    // Advanced mode's broker asks through the same channel, with a `kind`
    // (action / read / write / privileged) and its own button label. A
    // privileged one has no buttons: the answer is the password box.
    function _approveCard(a) {
        return { kind: "approve", msg: a.description || "Run this command?", command: a.command,
                 yes: a.yes || "", what: a.kind || "command", privileged: a.kind === "privileged",
                 peekImage: a.peek_image || "", peekText: a.peek_text || "",
                 always: a.always || "", more: approvals.length - 1 }
    }
    // Enter / the Yes button never answers a privileged ask: only a password
    // the box accepted does (privilegedDone below).
    function allow() {
        if (!approvals.length || approvals[0].kind === "privileged") return
        if (approvePick === 2 && approvals[0].always) _answer(true, "folder")
        else _answer(true)
    }
    function deny()  {
        if (approvals.length && approvals[0].kind === "privileged") privilegedCancel()
        _answer(false)
    }
    function _answer(yes, word) {
        if (!approvals.length) return
        const a = approvals[0]
        approvals = approvals.slice(1)
        // The pick goes back to Yes only for a NEXT ask in the queue. With
        // none, the answered card is still drawn while the island fades it
        // out, and resetting here lit Yes on it for that moment after a No
        // (Ahaan, 2026-10-26: "for a flash of a second i saw the highlight go
        // onto the yes again"). A fresh ask resets it in _event instead.
        if (approvals.length) _startPick(approvals[0])
        // Detached and fire-and-forget: the answer is one small file.
        Quickshell.execDetached(["python3", root.chat, "answer", a.dir, a.id, word || (yes ? "yes" : "no")])
        _raiseNext()
    }

    // ── root, through the password box ─────────────────────────────────
    // The broker names an ACTION; the command is chosen here, from this
    // table, never taken from Claude. Finder raises the box (it already
    // refuses to open one over its socket — a box asked for by whatever
    // wanted the password); the password goes box -> privileged-run.sh and
    // never reaches chat.py. EVE hears only whether it went through.
    signal privilegedRequested(string reason, string command)
    signal privilegedCancel()
    readonly property var _rootCommands: ({
        firewall_on:  ["firewall.sh", "on"],
        firewall_off: ["firewall.sh", "off"]
    })
    function _raiseNext() {
        if (!approvals.length || approvals[0].kind !== "privileged" || awaitingPassword) return
        const c = _rootCommands[approvals[0].action]
        if (!c) { _answer(false); return }
        awaitingPassword = true
        privilegedRequested(approvals[0].description,
                            Sys.quote(Settings.scriptDir + "/" + c[0]) + " " + c.slice(1).join(" "))
    }
    function privilegedDone(ok) {
        if (!awaitingPassword) return
        awaitingPassword = false
        if (approvals.length && approvals[0].kind === "privileged") _answer(ok)
    }

    // ── files a reply names ─────────────────────────────────────────────
    // chat.py does the opening (Settings' editor for text, the xdg default
    // for the rest, the file manager for "reveal"); the card stays up, so a
    // second file can be opened from the same answer.
    function openPath(p)   { Quickshell.execDetached(["python3", root.chat, "open", String(p)]) }
    function revealPath(p) { Quickshell.execDetached(["python3", root.chat, "reveal", String(p)]) }

    // ── attachments ─────────────────────────────────────────────────────
    // Files and images sent WITH the next message (Ahaan, 2026-10-26:
    // "attach replies as images/files ... simply paste it, and [in the reply
    // box] even a drag and drop"). Ctrl+V in the pill or the reply box asks
    // `chat.py paste` first: a copied image is saved to the runtime dir and a
    // copied file is taken by its path; plain text pastes as it always did.
    // A drop on the reply box (or anywhere on the reply's catcher) adds the
    // dropped files. chat.py reads them into the message itself — images and
    // PDFs as blocks Claude sees, text inline — so none of it asks for a yes:
    // attaching is choosing to show it. Keys and vaults are still never sent.
    // One list for both surfaces; it goes with whichever sends first, and a
    // pill cancelled or a reply clicked away drops it.
    property var attachments: []        // [{ path, name, image }]
    property var queryFiles: []         // names sent with the message on screen
    property bool dragOver: false       // a drag is over a drop target: the box lights up
    // Text selected in the reply card, for the catcher's Ctrl+C. The card is
    // on the bar's surface (one per screen, inside a Variants delegate) and
    // the keys are on the catcher, which cannot reach it by id — so the card
    // writes its selection here and the catcher reads it (JarvisCard's
    // "copying" has the rest).
    property string selection: ""
    function copySelection() {
        if (selection === "") return false
        Quickshell.execDetached(["wl-copy", "--", selection])
        return true
    }
    function attach(paths) {
        let a = attachments.slice()
        for (let p of paths) {
            p = String(p || "")
            if (p.startsWith("file://")) p = decodeURIComponent(p.slice(7))
            if (!p.startsWith("/") || a.some(x => x.path === p)) continue
            a.push({ path: p, name: p.split("/").pop(),
                     image: /\.(png|jpe?g|webp|gif|bmp|tiff?|heic|avif|jxl|svg)$/i.test(p) })
        }
        attachments = a.slice(0, 10)    // chat.py's MAX_ATTACH
    }
    function detach(i) {
        if (i < 0) i = attachments.length - 1
        if (i < 0 || i >= attachments.length) return
        const a = attachments.slice()
        a.splice(i, 1)
        attachments = a
    }
    function _takeFiles() {
        const f = attachments.map(x => x.path)
        attachments = []
        return f
    }
    // target: the TextInput the Ctrl+V was pressed in; it gets the ordinary
    // text paste when the clipboard holds no file or image.
    function paste(target) {
        pasteProc.target = target
        if (!pasteProc.running) pasteProc.running = true
    }
    Process {
        id: pasteProc
        property var target: null
        command: ["python3", root.chat, "paste"]
        stdout: StdioCollector {
            onStreamFinished: {
                let f = []
                try { f = JSON.parse(text).files || [] } catch (e) {}
                if (f.length) root.attach(f)
                else if (pasteProc.target) pasteProc.target.paste()
            }
        }
        stderr: StdioCollector {}
    }

    // ── internals ───────────────────────────────────────────────────────
    property var _pending: null

    function _clear() {
        query = ""; queryFiles = []; current = null; selected = 0; live = ""; hidden = false; _parked = false; resting = false
        awaitingPassword = false; _pending = null; stepTool = ""; liveSealed = false
    }

    function _event(line) {
        let e
        try { e = JSON.parse(line) } catch (err) { console.warn("eve: bad line:", line); return }
        if (e.ev === "step") { root.stepTool = e.tool || ""; root._status() }
        else if (e.ev === "delta") { root.live = e.text || ""; root.liveSealed = !!e.sealed }
        else if (e.ev === "approve") { if (!root.approvals.length) root._startPick(e); root.approvals = root.approvals.concat([e]); root.hidden = false; root._raiseNext() }
        else if (e.ev === "result") {
            if (e.kind === "reply") { e.query = root.query; e.attached = root.queryFiles; root.sessionTitle = e.title || root.sessionTitle }
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

    // Another tenant holding the island (todo, calendar, reminders, music,
    // Gita), told by Bar.qml. A reply that lands while one is open waits
    // behind the orb instead of taking the island: "open my calendar" opened
    // it, then "Opened the calendar." arrived, expanded EVE, and islandOnly
    // closed the calendar again a second later (Ahaan, 2026-10-26). It comes
    // up by itself once that panel closes (Ahaan: "eves reply can show after
    // i close that panel"), or sooner from a click on the orb.
    property bool islandTaken: false
    property bool _parked: false
    onIslandTakenChanged: {
        if (islandTaken || !_parked) return
        _parked = false
        if (phase === "result" && current) hidden = false
    }

    function _show(card) {
        current = card
        hidden = islandTaken            // an error too: the orb's mood says it, for its 4 s
        _parked = islandTaken
        phase = "result"
        collapseTimer.stop()
        // An error says what went wrong and goes after 4 s; a reply stays.
        if (card.kind === "error") { collapseTimer.interval = 4000; collapseTimer.restart() }
        // A reply comes with a reply box: have Claude ready for it.
        if (card.kind === "reply") warm()
    }

    Timer { id: collapseTimer; onTriggered: root.clear() }

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
    // A resting reply (dismiss) counts as nothing open: the orb is a way
    // back to it, not a conversation on screen.
    function _closeIfDone() {
        if (prompting || (phase !== "idle" && !resting) || queue.length || approvals.length) return
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
        _outbox = _outbox.concat([JSON.stringify({ text: job.text, files: job.files || [] }) + "\n"])
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
        // The broker's IPC calls go to THIS shell — a repo instance while
        // testing, the live one once deployed — not a hardcoded path.
        environment: ({ EVE_QS: String(Quickshell.shellDir || "").replace(/^file:\/\//, "") })
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
            if (root._interrupted) {
                root._interrupted = false
                const card = { kind: "error", msg: "Interrupted" }
                if (root.phase === "launch") root._pending = card
                else root._show(card)
            } else if (root.busy && !root._want) {
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
    // voxtype types into whatever has the keyboard, and the pill has it, so
    // the transcription simply arrives as typing. All this needs is to start
    // it, and to stop it on Enter and wait for the text.
    // (Its key went to "new conversation" on 2026-10-20, and came back as
    // SUPER+A on 2026-11-05: Ahaan wants to talk straight into Claude.)
    property string voxState: "idle"          // idle | recording | transcribing
    FileView {
        path: root.runtimeDir + "/voxtype/state"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.voxState = (text() || "idle").trim()
    }
    Process {
        id: voxProc
        stderr: StdioCollector {}
        // Exit 1, "Voxtype daemon is not running" (measured with no daemon).
        // voxState cannot say this: the daemon deletes its state file on a
        // clean exit, and the watch leaves the last value in place.
        onExited: code => { if (code !== 0 && command[2] === "start") root.voxOff = true }
    }
    function _vox(verb) {
        voxProc.command = ["voxtype", "record", verb]
        voxProc.running = true
    }
    // Not `=== "idle"`, for the same stale value: from a state that says the
    // daemon is gone, trying is what finds out, and what sets voxOff.
    function startVoice() { if (voxState !== "recording" && voxState !== "transcribing") { voxOff = false; _vox("start") } }
    function stopVoice()  { if (voxState === "recording") _vox("stop") }

    // SUPER+A (`ipc call jarvis voice`). Closed: a new conversation, listening,
    // the same way SUPER+SPACE is the new-conversation key. Listening: stop, so
    // the words can be read and edited before Enter (Enter alone stops AND
    // sends; see Jarvis.qml send()). Otherwise, pill already up: dictate into
    // it, at the cursor, keeping what is there.
    function listen() {
        if (!enabled) return
        if (!prompting) { open(true, true); return }
        voice = true
        if (voxState === "recording") listenStop.restart()
        else if (voxState !== "transcribing") startVoice()
    }
    // The stop comes from a key chord, so SUPER can still be down when
    // transcription ends (0.16 s after a stop on Parakeet, voice-typing.sh).
    // wtype's keys and a held SUPER may read as compositor binds, and the
    // transcript can hold a "c" (SUPER+C closes the window). That combination
    // is reasoned, not measured. Waiting costs a little extra recording.
    Timer {
        id: listenStop
        interval: 350
        onTriggered: if (root.prompting) root.stopVoice()
    }
}
