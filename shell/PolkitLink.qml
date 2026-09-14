pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// finder's end of the polkit agent (scripts/polkit-agent.py).
//
// polkit asks for a password by way of an agent that has to live on the system
// bus and drive a setuid helper — neither of which QML can do — so the agent is
// its own process and this is the half that faces the user. What arrives here
// is the same thing the settings menu asks for: a password, in the box that
// already exists for it. lxqt-policykit-agent's Qt5 dialog, which is what used
// to answer these, matched nothing else on this desktop.
//
// ── Why the request arrives over one socket and is answered over another ──
// The agent announces a waiting request over finder's ordinary IPC socket
// (/tmp/finder.sock), and sends nothing with it but an opaque id — no detail
// worth having and, above all, never the password.
//
// Everything real happens on the agent's own socket under $XDG_RUNTIME_DIR, a
// per-user 0700 tmpfs. This end connects there and quotes the id; an id the
// agent did not issue is refused and the box never appears.
//
// What that guards against, exactly: /tmp/finder.sock is srwxr-xr-x and
// connect(2) needs the write bit, so another USER cannot reach it — but
// anything running as this user can, and without the id it could make a
// genuine-looking password prompt appear by writing one line into it.
Item {
    id: link

    // Raised when there is a real request to show. `message` is polkit's own
    // wording for the action; `user` is whose password is wanted.
    signal requested(string message, string user, bool isSelf)
    signal failed()        // PAM refused it — the box stays up
    signal accepted()      // authorised; the caller is on its way
    signal withdrawn()     // polkitd or the agent gave up; take the box away

    // The id of the request being served, "" when idle. Also the guard that
    // keeps a late line from a finished request out of a new one.
    property string _id: ""
    readonly property bool active: link._id !== ""

    // The env override is not decoration: it is what lets a repo-path finder
    // and a scratch agent talk to each other without either of them touching
    // the live session's socket — CLAUDE.md step 2, same purpose as the
    // taskbar's IPC verbs.
    readonly property string socketPath: {
        const override = Quickshell.env("HYPRAHAAN_POLKIT_SOCK")
        if (override) return override
        return (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/hyprahaan-polkit.sock"
    }

    // ── in ────────────────────────────────────────────────────────────────
    function announce(id) {
        // A second announcement while one is live should not happen — the
        // agent shows one box at a time — but if it does, the older one is
        // dropped rather than left with a connection nobody reads.
        if (link.active) link._close()
        link._id = id
        sock.connected = true
    }

    function sendPassword(pw) {
        if (!link.active) return
        // One line, and the password is the whole of it after the verb: it may
        // contain spaces and backslashes and neither is escaped anywhere on
        // this path. Only a newline would break it, and a newline cannot be
        // typed into the field.
        sock.write("password " + pw + "\n")
        sock.flush()
    }

    function cancel() {
        if (!link.active) return
        sock.write("cancel\n")
        sock.flush()
        link._close()
    }

    function _close() {
        link._id = ""
        sock.connected = false
    }

    property var _sock: Socket {
        id: sock
        path: link.socketPath

        onConnectionStateChanged: {
            if (sock.connected) {
                sock.write("attach " + link._id + "\n")
                sock.flush()
                return
            }
            // Dropped while a request was live: the agent died, or it closed
            // on us. Either way nothing is going to answer, so the box must
            // not be left asking.
            if (link.active) {
                link._id = ""
                link.withdrawn()
            }
        }

        onError: err => {
            // Almost always "the agent is not running" — the socket is created
            // by it and removed when it stops. Nothing to show the user: the
            // announcement came from the agent, so if it is gone the request
            // is gone with it.
            if (link.active) {
                link._id = ""
                link.withdrawn()
            }
            console.warn("polkit link: socket error", err)
        }

        parser: SplitParser {
            splitMarker: "\n"
            onRead: data => {
                const line = String(data)
                const sp = line.indexOf(" ")
                const verb = sp < 0 ? line : line.substring(0, sp)
                const arg  = sp < 0 ? ""   : line.substring(sp + 1)
                if (!link.active) return

                if (verb === "request") {
                    let r = {}
                    try { r = JSON.parse(arg) } catch (e) {
                        console.warn("polkit link: unparseable request", arg)
                        link._close()
                        return
                    }
                    link.requested(String(r.message || ""),
                                   String(r.user || ""),
                                   r.self === true)
                } else if (verb === "fail") {
                    link.failed()
                } else if (verb === "ok") {
                    // The box keeps the connection until it has shown its
                    // accepted state; the agent has already answered polkitd.
                    link.accepted()
                    link._close()
                } else if (verb === "no") {
                    // An id the agent does not recognise: a stale announcement,
                    // or one this instance was never meant to serve.
                    link._close()
                } else if (verb === "cancel") {
                    link._id = ""
                    sock.connected = false
                    link.withdrawn()
                }
            }
        }
    }
}
