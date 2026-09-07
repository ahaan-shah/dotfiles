#!/usr/bin/env python3
# polkit-agent.py — this session's polkit authentication agent.
#
# polkit's own agents draw their own dialog (lxqt-policykit-agent's Qt5 box was
# what ran here before, and it looks like nothing else on this desktop). This
# one draws NOTHING. It registers as the session's agent, and when polkit asks
# for a password it hands the request to finder, which raises the same password
# box the settings menu already uses — one authenticate-password design
# everywhere, which is what Ahaan asked for when that box was built.
#
# ── Why a separate process at all, when the UI is Quickshell ─────────────
# An authentication agent has to (a) export an object implementing
# org.freedesktop.PolicyKit1.AuthenticationAgent on the SYSTEM bus and (b) run
# /usr/lib/polkit-1/polkit-agent-helper-1, which is setuid root and is the only
# thing allowed to answer polkitd. Quickshell's QML can consume D-Bus services
# but cannot export one, so neither half can live in finder. This process is
# the part that talks to polkit; finder is the part that talks to the user.
#
# ── Why libpolkit-agent's Session, rather than driving the helper here ───
# polkit-agent-helper-1 has a private stdin/stdout protocol (cookie first, then
# a PAM conversation, then SUCCESS/FAILURE) that has changed shape across
# releases — the cookie used to be an argv element and is not any more. The
# PolkitAgent typelib ships with polkit itself, so PolkitAgent.Session always
# speaks the version of the protocol that is installed. Nothing here has to
# know what that is.
#
# ── Two channels, and why the password only ever crosses one ─────────────
# The request is announced over finder's existing IPC socket, /tmp/finder.sock.
# It carries only an opaque request id — never the polkit message, and above
# all never the password. finder answers by connecting BACK to this agent's own
# socket under $XDG_RUNTIME_DIR (a 0700 per-user tmpfs) and quoting the id; the
# details come back over that connection and the password goes out over it.
#
# Measured rather than assumed, because the first version of this comment had
# it wrong: /tmp/finder.sock is srwxr-xr-x, and connect(2) needs the WRITE bit,
# so another user on the machine cannot reach it at all. What it is open to is
# anything running as this user. That is the threat the id closes — a process
# of Ahaan's own making a genuine-looking password box appear on demand by
# writing one line into it. An id this agent did not issue is refused, so the
# box never appears. The password is out of reach either way: it is only ever
# written into the runtime-dir socket.
#
# Usage:
#   polkit-agent.py                     register for this login session
#   polkit-agent.py --process PID       register for one process (testing:
#                                       does not displace the session's agent)
#   polkit-agent.py --socket PATH       listen elsewhere (testing)
#   polkit-agent.py --finder-socket P   announce elsewhere (testing)

import argparse
import json
import os
import secrets
import signal
import socket
import subprocess
import sys
import time

import gi

gi.require_version("Polkit", "1.0")
gi.require_version("PolkitAgent", "1.0")
from gi.repository import GLib, Gio, Polkit, PolkitAgent  # noqa: E402

OBJECT_PATH = "/org/hyprahaan/PolkitAgent"
AGENT_IFACE = "org.freedesktop.PolicyKit1.AuthenticationAgent"

# The two methods polkitd calls on an agent. Declared by hand because this
# object is exported directly on the shared system-bus connection rather than
# through PolkitAgent.Listener, whose async vfunc does not subclass cleanly
# from Python.
AGENT_XML = """
<node>
  <interface name='org.freedesktop.PolicyKit1.AuthenticationAgent'>
    <method name='BeginAuthentication'>
      <arg type='s' name='action_id' direction='in'/>
      <arg type='s' name='message' direction='in'/>
      <arg type='s' name='icon_name' direction='in'/>
      <arg type='a{ss}' name='details' direction='in'/>
      <arg type='s' name='cookie' direction='in'/>
      <arg type='a(sa{sv})' name='identities' direction='in'/>
    </method>
    <method name='CancelAuthentication'>
      <arg type='s' name='cookie' direction='in'/>
    </method>
  </interface>
</node>
"""

FINDER_LAUNCH = os.path.expanduser("~/.config/finder/finder-launch.sh")


def log(*a):
    # stderr, unbuffered-ish: this runs from hyprland.lua's exec-once, so this
    # is what ends up in the Hyprland log when something goes wrong.
    print("polkit-agent:", *a, file=sys.stderr, flush=True)


# ══ the UI side: one connection to finder per authentication ═════════════
class Ui:
    """finder's end of one authentication. Owns the socket connection and
    turns lines into callbacks."""

    def __init__(self, conn, on_line, on_closed):
        self._conn = conn
        self._on_line = on_line
        self._on_closed = on_closed
        self._closed = False
        self._in = Gio.DataInputStream.new(conn.get_input_stream())
        self._read()

    def _read(self):
        self._in.read_line_async(GLib.PRIORITY_DEFAULT, None, self._read_done)

    def _read_done(self, stream, res):
        try:
            line, _ = stream.read_line_finish_utf8(res)
        except GLib.Error:
            line = None
        if line is None:          # peer closed — finder gone, or the box cancelled
            self.close()
            self._on_closed()
            return
        self._on_line(line.rstrip("\n"))
        if not self._closed:
            self._read()

    def send(self, line):
        if self._closed:
            return
        try:
            # write_all rather than write: a short write on a stream socket is
            # legal and would silently truncate a message. These are all a few
            # hundred bytes, so it never actually blocks.
            self._conn.get_output_stream().write_all((line + "\n").encode(), None)
        except GLib.Error as e:
            log("write to finder failed:", e.message)
            self.close()

    def close(self):
        if self._closed:
            return
        self._closed = True
        try:
            self._conn.close(None)
        except GLib.Error:
            pass


# ══ one pending authentication ══════════════════════════════════════════
class Request:
    def __init__(self, agent, invocation, action_id, message, cookie, identity, uid):
        self.agent = agent
        self.invocation = invocation      # answered when authentication ends
        self.action_id = action_id
        self.message = message
        self.cookie = cookie
        self.identity = identity          # Polkit.Identity we authenticate as
        self.uid = uid
        self.id = secrets.token_hex(16)   # what finder quotes back to claim it
        self.ui = None
        self.session = None
        self.finished = False
        self.announced = False
        self.pam_ready = False        # the helper has asked for a password
        self.pending = None           # one typed password, waiting for it

    # ── the polkit half ──────────────────────────────────────────────────
    def start_session(self):
        """A fresh PolkitAgent.Session per typed password.

        Not reuse: a session ends the moment PAM answers and its setuid helper
        exits with it, so a retry is necessarily a new one.

        Started LAZILY — when a password arrives, not when the box opens. The
        first version started one as soon as finder attached and another the
        instant PAM said no, and both cost a faillock entry they had no
        business spending: one wrong password left TWO entries against
        service `polkit-1` (measured with `faillock --user`), because a session
        that is cancelled with its PAM conversation open counts as a failure
        too. Nothing is spawned now until there is something to authenticate
        with."""
        self.session = PolkitAgent.Session.new(self.identity, self.cookie)
        self.session.connect("request", self._on_pam_request)
        self.session.connect("show-error", lambda s, t: self._on_pam_text("error", t))
        self.session.connect("show-info", lambda s, t: self._on_pam_text("info", t))
        self.session.connect("completed", self._on_completed)
        self.session.initiate()

    def _on_pam_request(self, session, request, echo_on):
        # pam_unix asking for the password. The session only exists because a
        # password arrived, so the answer is already waiting here.
        self.pam_ready = True
        if self.pending is not None:
            pw, self.pending = self.pending, None
            session.response(pw)
        else:
            # A second prompt inside one conversation, which pam_unix does not
            # do. Answering blank fails this attempt cleanly rather than
            # hanging the box on a question nobody can see; re-sending the last
            # password would spend a second faillock entry on one keystroke,
            # which is the trap privileged-run.sh's one-shot askpass documents.
            log("unexpected second PAM prompt:", request)
            session.response("")

    def _on_pam_text(self, kind, text):
        # PAM's own words (an expired account, a faillock message). The box has
        # nowhere to put a running commentary, so this goes to the log; the
        # user-visible outcome is the failure itself.
        log("pam", kind + ":", text)

    def _on_completed(self, session, gained):
        if self.finished:
            return
        if gained:
            self.finish(True)
            return
        # PAM said no. The box stays up for another attempt; the next password
        # to arrive starts the next session (see start_session).
        self.pam_ready = False
        self.pending = None
        self.session = None
        if self.ui:
            self.ui.send("fail")

    def password(self, pw):
        # Stash first, then start: the helper answers the `request` signal
        # within milliseconds and it must find the password already here.
        self.pending = pw
        if self.session is None:
            self.start_session()
        elif self.pam_ready:
            pw, self.pending = self.pending, None
            self.session.response(pw)

    # ── ending, exactly once ─────────────────────────────────────────────
    def finish(self, ok, cancelled=False, cancelled_by_ui=False):
        if self.finished:
            return
        self.finished = True
        if self.session is not None:
            if not ok:
                self.session.cancel()
            self.session = None
        if self.ui:
            # Nothing is sent when the box itself asked to stop: it closed its
            # end as it said so, and writing into that got an EPIPE logged as
            # if something had gone wrong.
            if not cancelled_by_ui:
                self.ui.send("ok" if ok else "cancel")
            self.ui.close()
        if ok:
            # An empty reply IS the answer: the helper has already told polkitd
            # who authenticated. Returning without an error is what makes
            # polkitd re-check and hand the caller its authorisation.
            self.invocation.return_value(None)
        elif cancelled:
            self.invocation.return_dbus_error(
                "org.freedesktop.PolicyKit1.Error.Cancelled",
                "Authentication was cancelled")
        else:
            self.invocation.return_dbus_error(
                "org.freedesktop.PolicyKit1.Error.Failed",
                "Authentication failed")
        self.agent.done(self)


# ══ the agent ═══════════════════════════════════════════════════════════
class Agent:
    def __init__(self, sock_path, finder_sock, subject):
        self.sock_path = sock_path
        self.finder_sock = finder_sock
        self.subject = subject
        self.queue = []                # requests waiting for the box
        self.by_cookie = {}
        self.bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
        self._conns = set()            # keep server connections alive
        self._serve()
        self._export()
        self._register()

    # ── finder answers here ──────────────────────────────────────────────
    def _serve(self):
        # A stale socket file outlives a crash and would make listen() fail, so
        # it goes first — the runtime dir is ours alone, so nothing else can be
        # holding this name legitimately.
        try:
            os.unlink(self.sock_path)
        except FileNotFoundError:
            pass
        self.service = Gio.SocketService.new()
        # 0600 even though $XDG_RUNTIME_DIR is already 0700: the password
        # crosses this socket, and it costs one line to not depend on the
        # directory alone.
        old = os.umask(0o177)
        try:
            self.service.add_address(
                Gio.UnixSocketAddress.new(self.sock_path),
                Gio.SocketType.STREAM, Gio.SocketProtocol.DEFAULT, None)
        finally:
            os.umask(old)
        self.service.connect("incoming", self._on_incoming)
        self.service.start()

    def _on_incoming(self, service, conn, source):
        self._conns.add(conn)
        state = {"req": None}

        def on_line(line):
            verb, _, arg = line.partition(" ")
            if verb == "attach":
                req = next((r for r in self.queue if r.id == arg), None)
                if req is None or req.finished or req.ui is not None:
                    # An id we never issued, or one already claimed. Say so and
                    # drop the connection: this is the case that stops anything
                    # else on the machine from conjuring a password box.
                    ui.send("no")
                    ui.close()
                    return
                state["req"] = req
                req.ui = ui
                ui.send("request " + json.dumps({
                    "action":  req.action_id,
                    "message": req.message,
                    "user":    pwname(req.uid),
                    # Whether the password wanted is the one whose owner is
                    # sitting here. finder pre-checks against PAM only when it
                    # is; for anyone else it has nothing to pre-check against.
                    "self":    req.uid == os.getuid(),
                }))
                # No session yet. start_session() spawns the setuid helper and
                # opens a PAM conversation, and one opened here — before there
                # is a password to answer it with — was measured costing a
                # faillock entry for a password the box had already rejected on
                # its own. It starts when the first password arrives.
            elif verb == "password":
                if state["req"]:
                    state["req"].password(arg)
            elif verb == "cancel":
                if state["req"]:
                    state["req"].finish(False, cancelled=True, cancelled_by_ui=True)

        def on_closed():
            self._conns.discard(conn)
            # finder went away without answering — a dead shell, or the box
            # dismissed. Either way polkit is owed a reply.
            if state["req"] and not state["req"].finished:
                state["req"].finish(False, cancelled=True, cancelled_by_ui=True)

        ui = Ui(conn, on_line, on_closed)
        return True

    # ── polkit calls in here ─────────────────────────────────────────────
    def _export(self):
        node = Gio.DBusNodeInfo.new_for_xml(AGENT_XML)
        iface = node.lookup_interface(AGENT_IFACE)
        # register_object() is deprecated in PyGObject and says so on stderr —
        # which here is the Hyprland log, three warnings on every login. The
        # closure form is the supported spelling; the plain one stays as a
        # fallback so an older PyGObject still registers rather than crashing.
        if hasattr(self.bus, "register_object_with_closures2"):
            self.bus.register_object_with_closures2(
                OBJECT_PATH, iface, self._on_call, None, None)
        else:
            self.bus.register_object(OBJECT_PATH, iface, self._on_call, None, None)

    def _on_call(self, conn, sender, path, iface, method, params, invocation):
        if method == "BeginAuthentication":
            action_id, message, icon, details, cookie, identities = params.unpack()
            self._begin(invocation, action_id, message, cookie, identities)
        elif method == "CancelAuthentication":
            (cookie,) = params.unpack()
            invocation.return_value(None)
            req = self.by_cookie.get(cookie)
            if req:
                # polkitd withdrew it — the caller gave up or timed out. The
                # box is closed from under the user rather than left asking for
                # a password nothing is waiting for any more.
                req.finish(False, cancelled=True)

    def _begin(self, invocation, action_id, message, cookie, identities):
        uid, identity = pick_identity(identities)
        if identity is None:
            log("no identity we can authenticate for", action_id)
            invocation.return_dbus_error(
                "org.freedesktop.PolicyKit1.Error.Failed",
                "No usable identity")
            return
        req = Request(self, invocation, action_id, message, cookie, identity, uid)
        self.queue.append(req)
        self.by_cookie[cookie] = req
        # One box at a time. A second request while one is up waits its turn
        # rather than replacing it — polkitd is content to wait, and a prompt
        # that changes what it is asking for under the user's hands is worse
        # than one that arrives a moment later.
        if len(self.queue) == 1:
            self._announce(req)

    def done(self, req):
        self.by_cookie.pop(req.cookie, None)
        if req in self.queue:
            self.queue.remove(req)
        if self.queue and not self.queue[0].announced:
            self._announce(self.queue[0])

    def _announce(self, req):
        req.announced = True
        if not self._poke_finder(req.id):
            log("finder unreachable; cannot ask for a password")
            req.finish(False, cancelled=True)

    def _poke_finder(self, req_id, _relaunched=False):
        """Tell finder there is a request waiting. Returns False if it could
        not be reached at all."""
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(2)
            s.connect(self.finder_sock)
            s.sendall(("polkit:" + req_id + "\n").encode())
            s.close()
            return True
        except OSError:
            pass
        if _relaunched or not os.path.exists(FINDER_LAUNCH):
            return False
        # finder is not running — SUPER+K hides all three shells, and a system
        # asking for a password is exactly when it has to come back. Detached,
        # per the SIGPIPE rule: a child holding this process's pipes dies with
        # it, and this one has to outlive the request.
        log("finder is not up; starting it")
        subprocess.Popen(["setsid", FINDER_LAUNCH],
                         stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL,
                         start_new_session=True)
        # It binds its IPC socket a beat after the process starts; poll rather
        # than guess a sleep. This blocks the main loop, which is why it is
        # bounded at six seconds: nothing else can be served while it waits,
        # and a request nobody can answer should give up rather than wedge the
        # agent for the rest of the session.
        for _ in range(60):
            time.sleep(0.1)
            if os.path.exists(self.finder_sock):
                break
        return self._poke_finder(req_id, _relaunched=True)

    # ── registration ─────────────────────────────────────────────────────
    def _register(self):
        authority = Polkit.Authority.get_sync(None)
        # The locale polkit renders its action messages in. This desktop is
        # en_US; asking the environment keeps that from being a hardcoded fact.
        locale = os.environ.get("LANG", "en_US.UTF-8")
        try:
            authority.register_authentication_agent_sync(
                self.subject, locale, OBJECT_PATH, None)
        except GLib.Error as e:
            # polkit allows exactly one agent per session and will not let a
            # second one take over. This is what a deploy looks like if the old
            # agent was left running: the message is worth spelling out,
            # because the symptom otherwise is a traceback in the Hyprland log
            # and no prompts at all.
            raise SystemExit(
                "polkit-agent: could not register (%s).\n"
                "  Another agent already holds this session — if this is a\n"
                "  deploy, stop the old one first: pkill -f lxqt-policykit-agent"
                % e.message)
        self.authority = authority

    def unregister(self):
        try:
            self.authority.unregister_authentication_agent_sync(
                self.subject, OBJECT_PATH, None)
        except GLib.Error as e:
            log("unregister:", e.message)
        try:
            os.unlink(self.sock_path)
        except OSError:
            pass


def pwname(uid):
    import pwd
    try:
        return pwd.getpwuid(uid).pw_name
    except KeyError:
        return str(uid)


def pick_identity(identities):
    """Which of the identities polkit will accept we should ask for.

    auth_admin resolves through 50-default.rules to unix-group:wheel, which
    polkitd expands to its members — this user among them. Preferring our own
    uid is what keeps the box asking for the password of the person sitting
    here rather than for a root password that does not exist on this machine."""
    me = os.getuid()
    users = [d["uid"] for kind, d in identities if kind == "unix-user" and "uid" in d]
    if me in users:
        return me, Polkit.UnixUser.new(me)
    if users:
        uid = users[0]
        return uid, Polkit.UnixUser.new(uid)
    return None, None


def session_subject():
    subject = Polkit.UnixSession.new_for_process_sync(os.getpid(), None)
    if subject is None:
        raise SystemExit("polkit-agent: this process is not in a logind session")
    return subject


def process_subject(pid):
    # start-time as well as the pid: polkit refuses a bare pid because pids are
    # reused. new_for_owner(pid, 0, uid) reads the start time from /proc itself
    # when it is passed 0.
    return Polkit.UnixProcess.new_for_owner(pid, 0, os.getuid())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--process", type=int, default=None)
    ap.add_argument("--socket", default=None)
    ap.add_argument("--finder-socket", default="/tmp/finder.sock")
    args = ap.parse_args()

    runtime = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
    sock = args.socket or os.path.join(runtime, "hyprahaan-polkit.sock")

    subject = process_subject(args.process) if args.process else session_subject()
    agent = Agent(sock, args.finder_socket, subject)
    log("registered", "for pid %d" % args.process if args.process
        else "for the session", "on", sock)

    loop = GLib.MainLoop()

    def stop(*_):
        agent.unregister()
        loop.quit()
        return GLib.SOURCE_REMOVE

    # Same story as register_object above: GLib.unix_signal_add is deprecated
    # in favour of the GLibUnix module, and warns to the Hyprland log if used.
    try:
        gi.require_version("GLibUnix", "2.0")
        from gi.repository import GLibUnix
        add_signal = GLibUnix.signal_add
    except (ValueError, ImportError):
        # Named, not touched, above: merely READING GLib.unix_signal_add is
        # what emits the deprecation warning, so it has to stay inside the
        # branch that actually needs it.
        add_signal = GLib.unix_signal_add
    add_signal(GLib.PRIORITY_DEFAULT, signal.SIGTERM, stop)
    add_signal(GLib.PRIORITY_DEFAULT, signal.SIGINT, stop)
    loop.run()


if __name__ == "__main__":
    main()
