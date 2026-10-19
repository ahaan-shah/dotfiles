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
    readonly property string kind: r ? r.kind : ""
    property real maxHeight: 400
    readonly property real pad: 16
    // A finished reply keeps a strip free at its bottom for the reply box,
    // which Bar.qml draws there from the catcher window (it is the surface
    // that can hold the keyboard).
    readonly property real inputRoom: kind === "reply" && r && !r.streaming ? 38 + 12 : 0
    readonly property real wantHeight: col.implicitHeight + pad * 2 + inputRoom

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
        // it answers.
        Text {
            id: asked
            visible: card.kind === "reply" && !!card.r.query
            width: parent.width
            text: card.r && card.r.query ? "›  " + card.r.query : ""
            elide: Text.ElideRight
            maximumLineCount: 1
            font.family: Theme.font
            font.pixelSize: Theme.fsSub + 1
            color: Theme.dimmer
        }
        Flickable {
            id: replyFlick
            visible: card.kind === "reply"
            width: parent.width
            height: visible ? Math.min(replyCol.implicitHeight,
                                       Math.max(60, card.maxHeight - card.pad * 2 - card.inputRoom
                                                - (asked.visible ? asked.height + col.spacing : 0))) : 0
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

        // ── manual mode: a command, yes or no ───────────────────────────
        Text {
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
                maximumLineCount: 8
                elide: Text.ElideRight
                font.family: "monospace"
                font.pixelSize: Theme.fsSub + 1
                color: Theme.text
            }
        }
        Item {
            visible: card.kind === "approve"
            width: parent.width
            height: visible ? 30 : 0
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: (card.r && card.r.more > 0 ? card.r.more + " more waiting   ·   " : "") + "Ctrl+←  no   ·   Ctrl+→  yes"
                font.family: Theme.font
                font.pixelSize: Theme.fsSub
                color: Theme.dimmer
            }
            Row {
                anchors.right: parent.right
                spacing: 8
                CardButton {
                    text: "No"
                    onClicked: JarvisState.deny()
                }
                CardButton {
                    primary: true
                    text: "Yes, run it"
                    onClicked: JarvisState.allow()
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
            readonly property var b: parent ? parent.modelData : null
            readOnly: true
            selectByMouse: true
            wrapMode: TextEdit.Wrap
            textFormat: TextEdit.RichText
            // The reply's files ride along with the colours: EveMarkdown
            // links any it finds in the prose.
            text: b ? Md.html(b.md, Object.assign({ files: card.r && card.r.files ? card.r.files : {} }, card.colors)) : ""
            font.family: Theme.font
            font.pixelSize: Theme.fsRow
            color: Theme.alpha(Theme.text, 0.92)
            selectionColor: Theme.alpha(Theme.accent, 0.45)
            onLinkActivated: link => card.follow(link)
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
            readonly property string src: b ? card.imageSrc(b.url) : ""
            readonly property bool local: src.startsWith("file://")
            readonly property real aspect: pic.implicitHeight > 0 ? pic.implicitWidth / pic.implicitHeight : 1.6
            readonly property real picW: Math.min(width, 380 * aspect)
            readonly property real picH: picW / aspect
            implicitHeight: (pic.status === Image.Ready ? picH : pic.status === Image.Error ? 34 : 140)
                            + (cap.visible ? cap.height + 6 : 0)
            height: implicitHeight
            function open() {
                if (local) JarvisState.openPath(decodeURIComponent(src.slice(7)))
                else Qt.openUrlExternally(src)
            }

            // Loading: a panel-coloured block the size a picture usually is.
            Rectangle {
                visible: pic.status === Image.Loading || pic.status === Image.Null
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
