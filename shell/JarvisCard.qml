// JarvisCard.qml — what the bar's centre island grows down to show.
//
// It is drawn INSIDE the island (Bar.qml, Island.belowData), not as a card
// hung under it, because Ahaan's spec is that the island itself expands — one
// shape getting taller, no seam where a second surface meets it. So this item
// has no background and no border of its own: those are the island's.
//
// It reports `wantHeight`, what it would like; the island grants what fits and
// the reply scrolls inside whatever it is given.
//
// Since EVE became Claude (2026-10-20) there are four kinds of card:
//   status   the spinner words while she works, dropped down on their own
//   reply    Claude's answer, Markdown, streaming in and then staying put
//   approve  a command Claude wants to run, with No / Yes (manual mode)
//   error    what went wrong, for a few seconds
// The planner's cards (pick, password, preview, search sources) went with it.
//
// Typography is the settings card's (Theme.font, fsRow/fsSub), not the bar's,
// because what is in here is read like a card, not glanced at like a label.
import QtQuick
import QtQuick.Effects
import Quickshell
import "EveMarkdown.js" as Md

Item {
    id: card

    property var r: JarvisState.current
    // The conversation has read something local (chat.py's header): no
    // remote image is loaded and no web link is clickable, because either
    // would send whatever its URL spells out.
    readonly property bool sealed: !!(r && r.sealed)
    readonly property string kind: r ? r.kind : ""
    property real maxHeight: 400
    readonly property real pad: 16
    // A finished reply keeps a strip free at its bottom for the reply box,
    // which Bar.qml draws there from the catcher window (it is the surface
    // that can hold the keyboard).
    readonly property real inputRoom: kind === "reply" && r && !r.streaming ? 38 + 12 : 0
    readonly property real wantHeight: col.implicitHeight + pad * 2 + inputRoom

    // A drop on the island while a finished reply is up: the reply box sits
    // over this card's bottom strip, but it is drawn by the catcher window,
    // whose input region has the island cut out — so a drag over the box
    // arrives HERE, on the bar's surface. Same handling as the catcher's.
    DropArea {
        anchors.fill: parent
        enabled: card.kind === "reply" && card.r && !card.r.streaming
        onEntered: drag => { drag.accepted = drag.hasUrls || drag.hasText; JarvisState.dragOver = drag.accepted }
        onExited: JarvisState.dragOver = false
        onDropped: drop => { JarvisState.dragOver = false; card.dropped(drop) }
    }
    signal dropped(var drop)

    // ── copying ─────────────────────────────────────────────────────────
    // The reply's prose and code are read-only TextEdits, so a drag selects
    // — but this card is drawn on the BAR's surface, which never holds the
    // keyboard (the catcher does; Bar.qml jarvisCatch says why). So Ctrl+C
    // never reached the selection: it went to the reply box, which had
    // nothing selected, and nothing was copied. Now the catcher's keys copy
    // JarvisState.selection on Ctrl+C, and a selection starting raises
    // `selecting` so Bar.qml makes sure the keys are on the catcher at all.
    //
    // One selection at a time, across blocks: each block is its own
    // TextEdit, and a drag in a second one does not clear the first unless
    // focus moves — which a readOnly one may not take — so the card keeps
    // the newest and deselects the one before. What is selected goes to
    // JarvisState.selection, because the catcher cannot reach this card by
    // id (it is inside the bar's per-screen Variants delegate).
    property Item selBlock: null
    signal selecting()
    function selected(ed) {
        if (ed.selectedText === "") {
            if (selBlock === ed) { selBlock = null; JarvisState.selection = "" }
            return
        }
        if (selBlock && selBlock !== ed) selBlock.deselect()
        selBlock = ed
        JarvisState.selection = ed.selectedText
        selecting()
    }
    property bool copiedAll: false
    Timer { id: copiedAllTimer; interval: 1500; onTriggered: card.copiedAll = false }
    function copy(t, all) {
        if (!t) return false
        // wl-copy forks its own server and exits; execDetached is not a
        // Process pipe, so the SIGPIPE rule does not bite.
        Quickshell.execDetached(["wl-copy", "--", t])
        if (all) { copiedAll = true; copiedAllTimer.restart() }
        return true
    }
    // A new reply (or a new card) starts with nothing selected.
    onRChanged: if (selBlock) { selBlock = null; JarvisState.selection = "" }

    Column {
        id: col
        x: card.pad; y: card.pad
        width: card.width - card.pad * 2
        spacing: 12

        // ── a one-liner: what she is doing, or what went wrong ──────────
        Text {
            visible: card.kind === "status" || card.kind === "error"
            width: parent.width
            text: card.r && card.r.msg ? card.r.msg : ""
            wrapMode: Text.Wrap
            maximumLineCount: 3
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignHCenter
            font.family: Theme.font
            font.pixelSize: Theme.fsRow
            // The status is quieter than a result: it is what she is doing,
            // not what she found.
            color: card.kind === "error" ? Theme.danger : Theme.dim
        }

        // ── a reply ─────────────────────────────────────────────────────
        // What was asked, one line, so a reply read later still says what
        // it answers. A finished reply also gets a "copy" at the right of
        // that line for the whole answer, as Markdown, the way a code
        // block's strip has one for its code (Ahaan, 2026-11-03: "allow me
        // to copy text from eve's response"). Not while it streams: half an
        // answer on the clipboard is a trap.
        Item {
            id: asked
            readonly property bool hasQuery: card.kind === "reply" && (!!card.r.query || !!(card.r.attached && card.r.attached.length))
            readonly property bool canCopy: card.kind === "reply" && !card.r.streaming && !!card.r.body
            visible: hasQuery || canCopy
            width: parent.width
            height: askedText.implicitHeight
            Text {
                id: askedText
                visible: asked.hasQuery
                width: parent.width - (copyAll.visible ? copyAll.width + 12 : 0)
                // Files sent with it follow the words, after a paperclip.
                text: card.r ? "›  " + (card.r.query || "")
                             + (card.r.attached && card.r.attached.length ? "   󰏢 " + card.r.attached.join(", ") : "") : ""
                elide: Text.ElideRight
                maximumLineCount: 1
                font.family: Theme.font
                font.pixelSize: Theme.fsSub + 1
                color: Theme.dimmer
            }
            Text {
                id: copyAll
                visible: asked.canCopy
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: card.copiedAll ? "󰄬  copied" : "󰆏  copy"
                font.family: Theme.font
                font.pixelSize: Theme.fsSub
                color: copyAllHov.hovered || card.copiedAll ? Theme.text : Theme.dimmer
                HoverHandler { id: copyAllHov; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: card.copy(card.r.body, true) }
            }
        }
        Flickable {
            id: replyFlick
            visible: card.kind === "reply"
            width: parent.width
            height: visible ? Math.min(replyCol.implicitHeight,
                                       Math.max(60, card.maxHeight - card.pad * 2 - card.inputRoom
                                                - (asked.visible ? asked.height + col.spacing : 0)
                                                - (webRow.visible ? webRow.height + col.spacing : 0))) : 0
            contentHeight: replyCol.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            // While it streams, the newest words stay in view.
            onContentHeightChanged: if (card.r && card.r.streaming)
                contentY = Math.max(0, contentHeight - height)

            // Prose and code blocks, in order. Prose is EveMarkdown's HTML in
            // Theme's colours; each code block is its own panel.
            Column {
                id: replyCol
                width: replyFlick.width - 8
                spacing: 10
                Repeater {
                    model: card.kind === "reply" && card.r.body ? Md.blocks(card.r.body) : []
                    delegate: Loader {
                        id: blk
                        required property var modelData
                        width: replyCol.width
                        sourceComponent: modelData.type === "code" ? codeBlock
                                       : modelData.type === "image" ? imageBlock : proseBlock
                    }
                }
            }
            // Where you are in it, only when there is somewhere to go.
            Rectangle {
                visible: replyFlick.contentHeight > replyFlick.height + 1
                x: replyFlick.width - 3; width: 3; radius: 1.5
                y: replyFlick.contentY + replyFlick.visibleArea.yPosition * replyFlick.height
                height: Math.max(20, replyFlick.visibleArea.heightRatio * replyFlick.height)
                color: Theme.alpha(Theme.text, 0.35)
            }
        }
        // A sealed reply that needs the web ends with `WEB: <request>`
        // (chat.py strips it into r.web): the request, whole, and a button
        // that starts a NEW conversation with it in the pill. Shown in full
        // so what would leave is read before it can be sent.
        Rectangle {
            id: webRow
            visible: card.kind === "reply" && !card.r.streaming && !!card.r.web
            width: parent.width
            height: visible ? webCol.implicitHeight + 20 : 0
            radius: 10
            color: Qt.tint(Theme.bg, Theme.alpha(Theme.text, 0.055))
            Column {
                id: webCol
                x: 14; y: 10
                width: parent.width - 28
                spacing: 8
                Text {
                    width: parent.width
                    text: "󰖟  Needs the web — this conversation has read local files"
                    font.family: Theme.font; font.pixelSize: Theme.fsSub
                    color: Theme.dimmer
                }
                Text {
                    width: parent.width
                    text: card.r && card.r.web ? card.r.web : ""
                    wrapMode: Text.Wrap
                    textFormat: Text.PlainText
                    font.family: Theme.font; font.pixelSize: Theme.fsRow
                    color: Theme.text
                }
                CardButton {
                    primary: true
                    text: "Continue in a new conversation"
                    onClicked: JarvisState.continueOnWeb(card.r.web)
                }
            }
        }

        // ── manual mode: a command, yes or no ───────────────────────────
        Text {
            id: askText
            visible: card.kind === "approve"
            width: parent.width
            text: card.r && card.r.msg ? card.r.msg : ""
            wrapMode: Text.Wrap
            maximumLineCount: 3
            elide: Text.ElideRight
            font.family: Theme.font
            font.pixelSize: Theme.fsRow
            font.weight: Font.DemiBold
            color: Theme.text
        }
        Rectangle {
            id: cmdBox
            visible: card.kind === "approve"
            width: parent.width
            height: visible ? cmd.implicitHeight + 20 : 0
            radius: 8
            color: Theme.alpha(Theme.text, 0.06)
            Text {
                id: cmd
                x: 12; y: 10
                width: parent.width - 24
                text: card.r && card.r.command ? card.r.command : ""
                wrapMode: Text.WrapAnywhere
                // A write's diff needs room; a command or a path does not.
                maximumLineCount: card.r && card.r.what === "write" ? 24 : 8
                elide: Text.ElideRight
                font.family: "monospace"
                font.pixelSize: Theme.fsSub + 1
                color: Theme.text
            }
        }
        // A file read waiting on the yes shows what it is a yes TO: the
        // screenshot that was taken, a PDF's first page, a text file's first
        // lines (Ahaan, 2026-10-26). broker.py puts these in the ask; Claude
        // has seen none of it — it gets the file only after the yes. The
        // picture takes whatever height the card has left, fitted.
        readonly property real peekRoom: Math.max(120, card.maxHeight - card.pad * 2 - askText.height
                                                  - cmdBox.height - 30 - spacing * 3)
        Item {
            id: peekImg
            readonly property string src: card.kind === "approve" && card.r && card.r.peekImage
                                          ? "file://" + card.r.peekImage : ""
            readonly property real aspect: pk.implicitHeight > 0 ? pk.implicitWidth / pk.implicitHeight : 1.6
            readonly property real picW: Math.min(width, col.peekRoom * aspect)
            visible: src !== ""
            width: parent.width
            height: visible ? (pk.status === Image.Ready ? picW / aspect : pk.status === Image.Error ? 0 : 140) : 0
            Image {
                id: pk
                x: (parent.width - peekImg.picW) / 2
                width: peekImg.picW; height: peekImg.picW / peekImg.aspect
                source: peekImg.src
                asynchronous: true
                cache: false            // the same screenshot path never changes, but a PDF page might
                fillMode: Image.PreserveAspectFit
                sourceSize.width: 1400
                smooth: true; mipmap: true
                layer.enabled: true
                layer.effect: MultiEffect {
                    maskEnabled: true
                    maskSource: peekMask
                    maskThresholdMin: 0.5
                    maskSpreadAtMin: 1.0
                }
            }
            Rectangle {
                id: peekMask
                width: pk.width; height: pk.height
                radius: 10
                visible: false
                layer.enabled: true
            }
        }
        Rectangle {
            visible: card.kind === "approve" && !!(card.r && card.r.peekText)
            width: parent.width
            height: visible ? Math.min(peekTxt.implicitHeight + 20, col.peekRoom) : 0
            radius: 8
            clip: true
            color: Theme.alpha(Theme.text, 0.04)
            Text {
                id: peekTxt
                x: 12; y: 10
                width: parent.width - 24
                text: card.r && card.r.peekText ? card.r.peekText : ""
                wrapMode: Text.WrapAnywhere
                textFormat: Text.PlainText
                font.family: "monospace"
                font.pixelSize: Theme.fsSub + 1
                color: Theme.dim
            }
        }
        Item {
            visible: card.kind === "approve"
            width: parent.width
            height: visible ? 30 : 0
            // No key hint here (Ahaan, 2026-10-21): the accent on the
            // picked button is the only cue. Only the queue count is left.
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: card.r && card.r.privileged ? "Password box is open · Esc refuses"
                    : card.r && card.r.more > 0 ? card.r.more + " more waiting" : ""
                font.family: Theme.font
                font.pixelSize: Theme.fsSub
                color: Theme.dimmer
            }
            Row {
                anchors.right: parent.right
                spacing: 8
                visible: !(card.r && card.r.privileged)
                // The accent marks the keyboard's pick, not a fixed default:
                // it starts on Yes and follows Left/Right (Bar.qml's catcher).
                CardButton {
                    primary: JarvisState.approvePick === 0
                    text: "No"
                    // A click moves the pick first, so the card fades out
                    // with the answer given lit, not the keyboard's pick.
                    onClicked: { JarvisState.approvePick = 0; JarvisState.deny() }
                }
                CardButton {
                    primary: JarvisState.approvePick === 1
                    text: card.r && card.r.yes ? card.r.yes : "Yes, run it"
                    onClicked: { JarvisState.approvePick = 1; JarvisState.allow() }
                }
                // A read outside ~/EVE: the rest of that folder too, for this
                // conversation (broker.may_read).
                CardButton {
                    visible: !!(card.r && card.r.always)
                    primary: JarvisState.approvePick === 2
                    text: card.r && card.r.always ? card.r.always : ""
                    onClicked: { JarvisState.approvePick = 2; JarvisState.allow() }
                }
            }
        }
    }

    // ── the reply's pieces ──────────────────────────────────────────────
    // Colours for EveMarkdown, all from the palette. Syntax colours keep each
    // wal colour's HUE and lift it to a readable lightness: this palette's
    // color1-6 are dark wine and violet (#6E3B45, #4C3B6F …), unreadable as
    // text on its own #1a0000, but their hues are what makes the code look
    // like part of this desktop rather than a pasted-in IDE theme.
    function hue(c, sat, light) {
        const h = c.hslHue < 0 ? Theme.accent.hslHue : c.hslHue
        return String(Qt.hsla(Math.max(0, h), sat, light, 1))
    }
    function solid(c) { return String(Qt.tint(Theme.bg, c)) }
    // A file's name opens it in its default app; the folder glyph after it
    // shows it in the file browser; anything else is a web or mail link.
    function follow(link) {
        if (link.startsWith("file://")) JarvisState.openPath(decodeURI(link.slice(7)))
        else if (link.startsWith("reveal:")) JarvisState.revealPath(decodeURIComponent(link.slice(7)))
        else Qt.openUrlExternally(link)
    }
    readonly property var colors: ({
        size: Theme.fsRow,
        link: hue(Theme.accent, 0.55, 0.74),
        strong: solid(Theme.alpha(Theme.text, 1)),
        dim: solid(Theme.alpha(Theme.text, 0.6)),
        rule: solid(Theme.alpha(Theme.text, 0.16)),
        codeBg: solid(Theme.alpha(Theme.text, 0.09)),
        codeFg: hue(WalColors.color3, 0.5, 0.80),
        // code panel tokens
        keyword: hue(WalColors.color1, 0.55, 0.72),
        string: hue(WalColors.color2, 0.42, 0.76),
        number: hue(WalColors.color3, 0.55, 0.74),
        func: hue(WalColors.color5, 0.45, 0.80),
        type: hue(WalColors.color4, 0.40, 0.78),
        variable: hue(WalColors.color6, 0.45, 0.78),
        comment: solid(Theme.alpha(Theme.text, 0.42)),
        punct: solid(Theme.alpha(Theme.text, 0.62)),
        plain: solid(Theme.alpha(Theme.text, 0.90))
    })

    Component {
        id: proseBlock
        TextEdit {
            id: prose
            readonly property var b: parent ? parent.modelData : null
            readOnly: true
            selectByMouse: true
            wrapMode: TextEdit.Wrap
            textFormat: TextEdit.RichText
            // The reply's files ride along with the colours: EveMarkdown
            // links any it finds in the prose.
            text: b ? Md.html(b.md, Object.assign({ files: card.r && card.r.files ? card.r.files : {},
                                                    sealed: card.sealed }, card.colors)) : ""
            font.family: Theme.font
            font.pixelSize: Theme.fsRow
            color: Theme.alpha(Theme.text, 0.92)
            selectionColor: Theme.alpha(Theme.accent, 0.45)
            onLinkActivated: link => card.follow(link)
            onSelectedTextChanged: card.selected(prose)
            HoverHandler { cursorShape: parent.hoveredLink ? Qt.PointingHandCursor : Qt.IBeamCursor }
        }
    }

    // An image: Claude's ![alt](url) on a line of its own. A web image loads
    // straight from its URL; ~/ and / paths are local files. Shown whole —
    // fitted to the panel's width and at most 380 tall — with the corners of
    // the rows here, and its alt text under it. A click opens the full image:
    // the browser for a URL, the default viewer (imv) for a file. One that
    // fails to load says so and keeps the link, rather than leaving a hole.
    function imageSrc(u) {
        u = String(u || "")
        if (u.startsWith("~/")) return "file://" + (Quickshell.env("HOME") || "") + u.slice(1)
        if (u.startsWith("/")) return "file://" + u
        return u
    }
    Component {
        id: imageBlock
        Item {
            id: ib
            readonly property var b: parent ? parent.modelData : null
            readonly property string want: b ? card.imageSrc(b.url) : ""
            readonly property bool local: want.startsWith("file://")
            // Sealed: a web image is not fetched at all, only named.
            readonly property bool held: card.sealed && !local
            readonly property string src: held ? "" : want
            readonly property real aspect: pic.implicitHeight > 0 ? pic.implicitWidth / pic.implicitHeight : 1.6
            readonly property real picW: Math.min(width, 380 * aspect)
            readonly property real picH: picW / aspect
            implicitHeight: (held ? 34 : pic.status === Image.Ready ? picH : pic.status === Image.Error ? 34 : 140)
                            + (cap.visible ? cap.height + 6 : 0)
            height: implicitHeight
            function open() {
                if (local) JarvisState.openPath(decodeURIComponent(src.slice(7)))
                else Qt.openUrlExternally(src)
            }

            // Loading: a panel-coloured block the size a picture usually is.
            Rectangle {
                visible: !ib.held && (pic.status === Image.Loading || pic.status === Image.Null)
                width: parent.width; height: 140
                radius: 10
                color: Qt.tint(Theme.bg, Theme.alpha(Theme.text, 0.055))
                Text {
                    anchors.centerIn: parent
                    text: "󰋩  loading image" + (pic.progress > 0 ? "  " + Math.round(pic.progress * 100) + "%" : "…")
                    font.family: Theme.font; font.pixelSize: Theme.fsSub
                    color: Theme.dimmer
                }
            }
            Image {
                id: pic
                x: (parent.width - ib.picW) / 2
                width: ib.picW; height: ib.picH
                visible: status === Image.Ready
                source: ib.src
                asynchronous: true
                cache: true
                fillMode: Image.PreserveAspectFit
                sourceSize.width: 1400
                smooth: true; mipmap: true
                // Rounded the way the rest of the shell rounds a picture: the
                // image rendered to a layer and masked by a rounded rectangle.
                layer.enabled: true
                layer.effect: MultiEffect {
                    maskEnabled: true
                    maskSource: picMask
                    maskThresholdMin: 0.5
                    maskSpreadAtMin: 1.0
                }
                HoverHandler { cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: ib.open() }
            }
            Rectangle {
                id: picMask
                width: ib.picW; height: ib.picH
                radius: 10
                visible: false
                layer.enabled: true
            }
            // Held back by the seal: what it is and where from, no click.
            Text {
                visible: ib.held
                width: parent.width; height: 34
                verticalAlignment: Text.AlignVCenter
                text: "󰋩  " + (ib.b && ib.b.alt ? ib.b.alt : "image") + " — not loaded: this conversation has read local files"
                elide: Text.ElideRight
                font.family: Theme.font; font.pixelSize: Theme.fsSub + 1
                color: Theme.dimmer
            }
            // Failed: say so, and keep it one click from the browser.
            Text {
                visible: pic.status === Image.Error
                width: parent.width; height: 34
                verticalAlignment: Text.AlignVCenter
                text: "󰋩  couldn't load this image — open it"
                elide: Text.ElideRight
                font.family: Theme.font; font.pixelSize: Theme.fsSub + 1
                color: Theme.dim
                HoverHandler { cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: ib.open() }
            }
            Text {
                id: cap
                visible: !!(ib.b && ib.b.alt) && pic.status !== Image.Error
                y: (pic.status === Image.Ready ? ib.picH : 140) + 6
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: ib.b && ib.b.alt ? ib.b.alt : ""
                elide: Text.ElideRight
                font.family: Theme.font; font.pixelSize: Theme.fsSub
                color: Theme.dimmer
            }
        }
    }

    // A code block: the island's own colour, a shade lighter, rounded like the
    // rows in a settings card — no border, so it reads as a part of the panel.
    // The language and a copy button sit in its top strip, the way an
    // editor's tab does.
    Component {
        id: codeBlock
        Rectangle {
            id: cb
            readonly property var b: parent ? parent.modelData : null
            implicitHeight: codeHead.height + codeText.implicitHeight + 14
            height: implicitHeight
            radius: 10
            color: Qt.tint(Theme.bg, Theme.alpha(Theme.text, 0.055))
            property bool copied: false
            Item {
                id: codeHead
                width: parent.width
                height: 28
                Text {
                    x: 14
                    anchors.verticalCenter: parent.verticalCenter
                    text: cb.b && cb.b.lang ? cb.b.lang : "code"
                    font.family: Theme.font
                    font.pixelSize: Theme.fsSub
                    color: Theme.dimmer
                }
                Text {
                    id: copyBtn
                    anchors.right: parent.right; anchors.rightMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    text: cb.copied ? "󰄬  copied" : "󰆏  copy"
                    font.family: Theme.font
                    font.pixelSize: Theme.fsSub
                    color: copyHov.hovered || cb.copied ? Theme.text : Theme.dimmer
                    HoverHandler { id: copyHov; cursorShape: Qt.PointingHandCursor }
                    TapHandler {
                        onTapped: {
                            Quickshell.execDetached(["wl-copy", "--", cb.b.code])
                            cb.copied = true
                            copiedTimer.restart()
                        }
                    }
                }
                Timer { id: copiedTimer; interval: 1500; onTriggered: cb.copied = false }
                Rectangle {
                    anchors.bottom: parent.bottom
                    width: parent.width; height: 1
                    color: Theme.alpha(Theme.text, 0.06)
                }
            }
            TextEdit {
                id: codeText
                x: 14
                y: codeHead.height + 7
                width: parent.width - 28
                readOnly: true
                selectByMouse: true
                wrapMode: TextEdit.Wrap
                textFormat: TextEdit.RichText
                text: cb.b ? Md.highlight(cb.b.code, cb.b.lang, card.colors) : ""
                font.family: "monospace"
                font.pixelSize: Theme.fsSub + 2
                color: Theme.text
                selectionColor: Theme.alpha(Theme.accent, 0.45)
                onSelectedTextChanged: card.selected(codeText)
            }
        }
    }

    component CardButton: Rectangle {
        id: btn
        property string text: ""
        property bool primary: false
        signal clicked()
        width: label.implicitWidth + 28
        height: 30
        radius: 9
        color: btn.primary ? Theme.alpha(Theme.accent, hov.hovered ? 0.38 : 0.26)
                           : Theme.alpha(Theme.text, hov.hovered ? 0.10 : 0.05)
        border.width: btn.primary ? 1.5 : 0
        border.color: Theme.alpha(Theme.accent, 0.75)
        Text {
            id: label
            anchors.centerIn: parent
            text: btn.text
            font.family: Theme.font
            font.pixelSize: Theme.fsRow - 1
            color: Theme.text
        }
        HoverHandler { id: hov }
        TapHandler { onTapped: btn.clicked() }
    }
}
