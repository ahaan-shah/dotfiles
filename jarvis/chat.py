#!/usr/bin/env python3
"""chat.py — EVE as a window onto Claude (2026-10-20).

  chat.py ask MODEL SESSION -- TEXT   one turn of a conversation, streamed
  chat.py serve MODEL SESSION         a conversation kept running; messages as
                                      JSON lines on stdin (what the bar uses)
  chat.py list                        EVE's sessions, newest first (prunes first)
  chat.py answer DIR ID yes|no        the bar's Yes/No on a command
  chat.py open PATH                   a file named in a reply, in its default app
  chat.py reveal PATH                 the same, shown in the file browser
  chat.py hook                        (Claude's PreToolUse hook; not for people)

Ahaan scrapped the local planner (Qwen on the 3050 was not good enough on
this hardware) and asked for EVE to be "claude via my own setup here instead
of an app": the quick questions that would otherwise mean opening claude.ai
in the browser, or another terminal session. Major work stays in herdr.

So this is a chat, not an agent on the desktop:

  - `claude -p --restricted` in ~/projects, ALWAYS (a new session must start
    there — Ahaan's rule — and a resume has to run from the same directory
    or the CLI cannot find the session). --restricted confines Read/Glob/Grep
    to ~/projects (measured: a Read of ~/.bashrc came back blocked,
    ~/projects/hyprahaan/CLAUDE.md read fine), drops every code-running tool
    --tools does not name, and ignores the user settings file — so the
    leftover orca hooks in it (orca itself is gone) never run for EVE.
  - --tools names the whole kit (Ahaan, 2026-10-20: "only keep websearch,
    fetching and reading files in ~/projects. No writing. Commands that do
    not need sudo can be run ... harmless commands are okay"): the read
    tools and the web, allowed outright, and Bash, which is NOT in
    --allowedTools. There is no Edit or Write at all.
  - "Keep it on manual mode": every Bash command is put to Ahaan before it
    runs. In -p there is no prompt to answer, so the asking is a PreToolUse
    hook (this file, `hook`), passed in with --settings — which --restricted
    still honours — and measured to work: allow ran `uname -r`, deny
    stopped `whoami` and Claude reported the reason. The hook drops the
    command into a per-run directory and waits; the `ask` loop below sees
    it and prints an "approve" event; the bar shows the command with No/Yes
    (Ctrl+Left / Ctrl+Right) and answers with `chat.py answer`. Anything
    under sudo, or su/doas/pkexec/run0, is refused without asking. With
    dontAsk, anything else that would want a permission prompt is refused.
  - The default account: CLAUDE_CONFIG_DIR is stripped, the same as for the
    agents panel's own probes, so it is never the second account by accident.

Sessions are Claude Code's own. The id is chosen by the bar (a uuid it
makes), and this decides per turn whether that id is new (`--session-id`)
or a conversation to continue (`--resume`), by whether Claude has a
transcript for it — so a follow-up queued behind a brand-new session's first
question lands in the same conversation. EVE keeps its own index of the ids
it made (eve/sessions.json under the state dir), because the CLI's project
dir for ~/projects is shared with any `claude` started there by hand, and
the list under the pill should be EVE's conversations only.

A session not used for 7 days is deleted — its transcript and its sidecar
dir — and only sessions in EVE's index are ever touched.

stdout is one JSON object per line, as jarvis.py's is:
  {"ev":"step","tool":"WebSearch"}
  {"ev":"delta","text":"the reply so far"}       whole text, not a fragment
  {"ev":"result","kind":"reply","body":"…","session":"…","title":"…",
   "files":{"~/projects/x.html":{"path":"/home/…/x.html","dir":false}}}
  {"ev":"done"}
"""
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

HOME = Path.home()
CWD = HOME / "projects"
STATE = Path(os.environ.get("XDG_STATE_HOME") or HOME / ".local/state") / "hyprahaan/eve"
INDEX = STATE / "sessions.json"
KEEP = 7 * 24 * 3600

MODELS = {"sonnet": "claude-sonnet-5-5", "haiku": "claude-haiku-5-5", "opus": "claude-opus-5-5"}
SAFE = "Read,Glob,Grep,WebSearch,WebFetch"
TOOLS = SAFE + ",Bash"
SELF = str(Path(__file__).resolve())
ASK_WAIT = 600        # an unanswered command is a no after 10 minutes
# Bash goes through `hook`; its 600 s cap is the hook's own, so the wait above
# ends first and the answer is a clean no, not a killed hook.
HOOKS = json.dumps({"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [
    {"type": "command", "command": "python3 " + shlex.quote(SELF) + " hook", "timeout": ASK_WAIT + 30}]}]}})

# Appended to Claude Code's own prompt, not a replacement for it: the tools
# still need their instructions. What changes is the room it is answering in.
# The name is the login name, capitalised — the pill's greeting does the same —
# so nothing personal is written into a file that may be published.
WHO = (os.environ.get("USER") or "the user").capitalize()
PROMPT = f"""You are answering through EVE, a small popup on {WHO}'s Linux desktop \
(Arch + Hyprland), not a terminal. They use it for the quick questions they would \
otherwise ask Claude in the browser; real project work happens elsewhere. Your \
reply is rendered as Markdown in a card about 700 px wide, so keep it as short \
as the question allows, and prefer short paragraphs and lists to tables. You can \
search and read the web, and read files under ~/projects. You can run shell \
commands, but only harmless ones that look at things (nvidia-smi, uptime, df, \
journalctl reads and the like): each one is shown to them first and runs only if \
they say yes. Never write, move or delete files, never use sudo, and if they ask \
for a change, say in one line that EVE can't make it.

The card can show pictures. When asked to show or pull up an image, or when one \
clearly helps, put each image on a line of its own as ![short description](URL), \
one to three of them. The URL must point straight at an image file and must come \
from something you actually fetched: an article's og:image or main photo, an \
upload.wikimedia.org file, an official press image. Never guess or construct an \
image URL. A local image is shown the same way with its path (~/Pictures/x.png)."""


_lock = threading.Lock()


def emit(**ev):
    # The ask watcher prints from its own thread; the lock keeps lines whole.
    with _lock:
        sys.stdout.write(json.dumps(ev, ensure_ascii=False) + "\n")
        sys.stdout.flush()


def transcripts():
    # Claude Code's project dir is the cwd with every non-alphanumeric
    # character turned into "-": /home/USER/projects -> -home-USER-projects
    # (checked against ~/.claude/projects).
    base = Path(os.environ.get("HOME")) / ".claude/projects"
    return base / re.sub(r"[^A-Za-z0-9]", "-", str(CWD))


def load():
    try:
        d = json.loads(INDEX.read_text())
        if isinstance(d, dict) and isinstance(d.get("sessions"), list):
            return d
    except (OSError, ValueError):
        pass
    return {"current": "", "sessions": []}


def save(d):
    STATE.mkdir(parents=True, exist_ok=True)
    tmp = INDEX.with_suffix(".tmp")
    tmp.write_text(json.dumps(d, ensure_ascii=False, indent=1))
    tmp.replace(INDEX)       # a reader never sees half a write


def prune(d):
    now = time.time()
    keep = []
    for s in d["sessions"]:
        if now - s.get("updated", 0) < KEEP:
            keep.append(s)
            continue
        sid = s.get("id", "")
        if not re.fullmatch(r"[0-9a-f-]{36}", sid):
            continue          # never build a path out of something else
        (transcripts() / f"{sid}.jsonl").unlink(missing_ok=True)
        shutil.rmtree(transcripts() / sid, ignore_errors=True)
    if len(keep) != len(d["sessions"]):
        d["sessions"] = keep
        if d.get("current") not in {s["id"] for s in keep}:
            d["current"] = ""
        save(d)
    return d


def title_of(text):
    t = " ".join(text.split())
    return t if len(t) <= 60 else t[:57].rstrip() + "…"


def claude_cmd(model, sid, stream_in=False):
    exists = (transcripts() / f"{sid}.jsonl").exists()
    cmd = ["claude", "-p", "--model", MODELS.get(model, MODELS["sonnet"]),
           # Medium for every model (Ahaan, 2026-10-20). Said explicitly,
           # because --restricted skips the user settings file, and with it
           # the per-model effortLevel kept there. Accepted by all three
           # (checked: haiku, sonnet, opus 5.5 each answered with it).
           "--effort", "medium",
           "--restricted", "--strict-mcp-config",
           "--tools", TOOLS, "--allowedTools", SAFE,
           "--permission-mode", "dontAsk",
           "--settings", HOOKS,
           "--append-system-prompt", PROMPT,
           # Off: by default the prompt is recorded on a conversation's first
           # turn and replayed on every resume, so a change to PROMPT (the
           # image rules were the first) would never reach an old session.
           "--system-prompt-snapshot", "off",
           "--output-format", "stream-json", "--verbose", "--include-partial-messages",
           "--resume" if exists else "--session-id", sid]
    if stream_in:
        cmd += ["--input-format", "stream-json"]
    return cmd


def spawn(cmd):
    env = dict(os.environ)
    env.pop("CLAUDE_CONFIG_DIR", None)
    # Where this run's hook leaves its questions. In the runtime dir: tmpfs,
    # private to Ahaan, gone at logout.
    run = Path(os.environ.get("XDG_RUNTIME_DIR") or tempfile.gettempdir()) / "eve"
    run.mkdir(mode=0o700, parents=True, exist_ok=True)
    asks = Path(tempfile.mkdtemp(prefix="ask-", dir=run))
    env["EVE_ASK_DIR"] = str(asks)
    stop = threading.Event()
    threading.Thread(target=watch_asks, args=(asks, stop), daemon=True).start()
    CWD.mkdir(parents=True, exist_ok=True)
    # Claude dies with this script: Quickshell stops `serve` with a SIGTERM
    # to it alone, and an orphaned claude would hold a session open.
    def die_with_parent():
        import ctypes
        ctypes.CDLL("libc.so.6").prctl(1, signal.SIGTERM)    # PR_SET_PDEATHSIG
    p = subprocess.Popen(cmd, cwd=CWD, env=env, text=True, stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         preexec_fn=die_with_parent)
    return p, asks, stop


def read_turn(p):
    """Stream one turn's events to stdout; return Claude's result event, or
    None if its output ended first."""
    live, sent, last = "", "", 0.0
    for line in p.stdout:
        try:
            e = json.loads(line)
        except ValueError:
            continue
        t = e.get("type")
        if t == "stream_event":
            ev = e.get("event", {})
            et = ev.get("type")
            # Only the newest message's words are shown: the text before a
            # tool call ("let me look that up") is replaced by the answer
            # after it, which is also all the final result carries.
            if et == "message_start":
                live = ""
            elif et == "content_block_start" and ev.get("content_block", {}).get("type") in ("tool_use", "server_tool_use"):
                emit(ev="step", tool=ev["content_block"].get("name", ""))
            elif et == "content_block_delta" and ev.get("delta", {}).get("type") == "text_delta":
                live += ev["delta"].get("text", "")
                # ~12 updates a second at most: each one re-lays the whole
                # Markdown body in the bar, and tokens arrive faster than that.
                now = time.monotonic()
                if now - last > 0.08 and live != sent:
                    emit(ev="delta", text=live)
                    sent, last = live, now
        elif t == "result":
            return e
    return None


def finish_turn(model, sid, text, result, err=""):
    if not result or result.get("is_error"):
        why = (result or {}).get("result") or (err.strip().splitlines()[-1:] or ["claude stopped"])[0]
        emit(ev="result", kind="error", msg="Claude didn't answer: " + str(why)[:200])
        return
    d = prune(load())
    now = time.time()
    s = next((s for s in d["sessions"] if s["id"] == sid), None)
    if s is None:
        s = {"id": sid, "title": title_of(text), "created": now}
        d["sessions"].append(s)
    s["updated"] = now
    s["model"] = model
    d["current"] = sid
    d["sessions"].sort(key=lambda s: -s.get("updated", 0))
    save(d)
    body = result.get("result", "")
    emit(ev="result", kind="reply", body=body, session=sid, title=s["title"], files=files_in(body))


def ask(model, sid, text):
    """One turn, start to finish: claude is started for it and exits after."""
    if not re.fullmatch(r"[0-9a-f-]{36}", sid):
        emit(ev="result", kind="error", msg="Bad session id")
        return
    p, asks, stop = spawn(claude_cmd(model, sid))
    # The question goes in on stdin, so one that starts with "--" is a
    # question and not a flag.
    p.stdin.write(text)
    p.stdin.close()
    result = read_turn(p)
    err = p.stderr.read()
    p.wait()
    stop.set()
    shutil.rmtree(asks, ignore_errors=True)
    finish_turn(model, sid, text, result, err)


def serve(model, sid):
    """A conversation, kept running (2026-10-20). Claude is started BEFORE
    anything is asked — when the pill opens or a reply box appears — and
    waits on stream-json input, so Enter skips its startup: measured 2.3 s
    cold against 1.2 s pre-started from Enter to the first word, three runs
    each. It then stays up for the follow-ups too. Nothing is sent to the
    API until a message is, so an idle one costs no tokens.

    stdin: one JSON line per message, {"text": "..."}. stdout: the same
    events as `ask`, with a "done" after each turn. EOF or SIGTERM ends it."""
    if not re.fullmatch(r"[0-9a-f-]{36}", sid):
        emit(ev="result", kind="error", msg="Bad session id")
        emit(ev="done")
        return 1
    p, asks, stop = spawn(claude_cmd(model, sid, stream_in=True))

    def end(*_):
        stop.set()
        try:
            p.terminate()
        except OSError:
            pass
        shutil.rmtree(asks, ignore_errors=True)
        sys.exit(0)
    signal.signal(signal.SIGTERM, end)

    for line in sys.stdin:
        try:
            text = str(json.loads(line).get("text", "")).strip()
        except ValueError:
            continue
        if not text:
            continue
        try:
            p.stdin.write(json.dumps({"type": "user", "message": {"role": "user", "content": text}}) + "\n")
            p.stdin.flush()
        except (BrokenPipeError, OSError):
            finish_turn(model, sid, text, None, p.stderr.read() if p.poll() is not None else "")
            emit(ev="done")
            break
        finish_turn(model, sid, text, read_turn(p))
        emit(ev="done")
        if p.poll() is not None:
            break
    end()


# ── manual mode ─────────────────────────────────────────────────────────

def watch_asks(d, stop):
    # Polled, 150 ms: one tiny directory for the life of one turn, and a
    # thread is all that is free while the main loop blocks on Claude's stdout.
    seen = set()
    while not stop.wait(0.15):
        for f in sorted(d.glob("*.ask")):
            if f.name in seen:
                continue
            seen.add(f.name)
            try:
                q = json.loads(f.read_text())
            except (OSError, ValueError):
                seen.discard(f.name)      # caught mid-write; next pass
                continue
            emit(ev="approve", dir=str(d), id=f.stem,
                 command=q.get("command", ""), description=q.get("description", ""))


def answer(d, aid, yes):
    d = Path(d)
    run = Path(os.environ.get("XDG_RUNTIME_DIR") or tempfile.gettempdir()) / "eve"
    if d.parent != run or not re.fullmatch(r"[A-Za-z0-9_-]+", aid):
        return 2
    tmp = d / (aid + ".tmp")
    tmp.write_text("yes" if yes else "no")
    tmp.replace(d / (aid + ".ans"))
    return 0


SUDOISH = re.compile(r"(^|[\s;&|(`])(sudo|doas|su|pkexec|run0)(\s|$)")


def hook():
    q = json.load(sys.stdin)
    cmd = (q.get("tool_input") or {}).get("command", "")
    desc = (q.get("tool_input") or {}).get("description", "")

    def decide(ok, why):
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
              "permissionDecision": "allow" if ok else "deny", "permissionDecisionReason": why}}))
        return 0

    if SUDOISH.search(cmd):
        return decide(False, "EVE never runs anything as root; tell Ahaan to run it himself.")
    d = os.environ.get("EVE_ASK_DIR")
    if not d or not Path(d).is_dir():
        return decide(False, "No one to ask, so no.")
    aid = re.sub(r"[^A-Za-z0-9_-]", "", q.get("tool_use_id", "")) or str(time.time_ns())
    d = Path(d)
    tmp = d / (aid + ".tmp")
    tmp.write_text(json.dumps({"command": cmd, "description": desc}))
    tmp.replace(d / (aid + ".ask"))
    ans = d / (aid + ".ans")
    end = time.monotonic() + ASK_WAIT
    while time.monotonic() < end:
        if ans.exists():
            yes = ans.read_text().strip() == "yes"
            return decide(yes, "Ahaan approved it." if yes
                          else "Ahaan said no. Don't run it again unless he asks.")
        time.sleep(0.1)
    return decide(False, "Ahaan didn't answer, so it was not run.")


# ── files named in a reply ──────────────────────────────────────────────
# Ahaan, 2026-10-20: "if it mentions a file, clicking it should open it in the
# default app (like html in zen, image in imv, folder in nautilus), and also
# always give option beside to ... open in file browser". The bar cannot stat
# a path, so the finished reply is read here and every path-looking string
# that EXISTS is handed back, as written, with where it resolved to. Relative
# ones are tried against ~/projects (the session's cwd), each project in it,
# and home — Claude writes `shell/Bar.qml` as often as the full path. Code
# blocks are skipped: a path in a script is part of the script.
# ~/x and /x may be one segment (~/Pictures, /etc); a relative path needs a
# slash, or every word in the reply would be tried as a file.
SEG = r"[\w@+-][\w.@+-]*"
PATHISH = re.compile(rf"~(?:/{SEG})+/?|/{SEG}(?:/{SEG})*/?|(?:\.\.?/)?{SEG}(?:/{SEG})+/?")


def files_in(body):
    prose = re.sub(r"```.*?(```|$)", " ", body, flags=re.S)
    prose = re.sub(r"https?://\S+", " ", prose)
    bases = [CWD] + sorted(d for d in CWD.iterdir() if d.is_dir() and not d.name.startswith(".")) + [HOME]
    found = {}
    for m in PATHISH.finditer(prose):
        tok = m.group(0).rstrip(".,:;")
        if tok in found or len(found) >= 40:
            continue
        if tok.startswith("~"):
            cands = [HOME / tok[1:].lstrip("/")]
        elif tok.startswith("/"):
            cands = [Path(tok)]
        else:
            cands = [b / tok for b in bases]
        for c in cands:
            try:
                if c.exists():
                    found[tok] = {"path": str(c.resolve()), "dir": c.is_dir()}
                    break
            except OSError:
                pass
    return found


def open_path(path, reveal):
    p = Path(path)
    if not p.exists():
        return 1
    mime = subprocess.run(["xdg-mime", "query", "filetype", str(p)],
                          capture_output=True, text=True).stdout.strip()
    # A program is never run from a click on its name; it is shown instead.
    if mime in ("application/x-executable", "application/x-pie-executable", "application/x-sharedlib"):
        reveal = True
    if reveal:
        # The desktop's own "show this file" call: the file manager opens its
        # folder with it selected (a folder: opens it).
        uri = p.resolve().as_uri()
        meth = "ShowFolders" if p.is_dir() else "ShowItems"
        subprocess.run(["gdbus", "call", "--session", "--dest", "org.freedesktop.FileManager1",
                        "--object-path", "/org/freedesktop/FileManager1",
                        "--method", "org.freedesktop.FileManager1." + meth, f"['{uri}']", ""],
                       capture_output=True, timeout=10)
        return 0
    sys.path.insert(0, str(Path(SELF).parent))
    import act    # the old planner's launcher: Settings' editor for text, xdg defaults for the rest
    if mime in ("text/html", "application/xhtml+xml"):
        # act opens HTML as text, in the editor; a page wants the browser.
        desk = subprocess.run(["xdg-mime", "query", "default", mime], capture_output=True, text=True).stdout.strip()
        e = next((x for x in act.entries() if x["id"] + ".desktop" == desk), None)
        cmd = shlex.join(act.entry_cmd(e, [str(p)]) if e else ["xdg-open", str(p)])
    else:
        cmd, _ = act.launch_file(p)
    act.exec_cmd(cmd)
    return 0


def main(argv):
    if argv[:1] == ["list"]:
        print(json.dumps(prune(load()), ensure_ascii=False))
        return 0
    if len(argv) == 2 and argv[0] in ("open", "reveal"):
        return open_path(argv[1], argv[0] == "reveal")
    if argv[:1] == ["hook"]:
        return hook()
    if len(argv) == 4 and argv[0] == "answer":
        return answer(argv[1], argv[2], argv[3] == "yes")
    if len(argv) == 3 and argv[0] == "serve":
        return serve(argv[1], argv[2])
    if len(argv) >= 4 and argv[0] == "ask" and argv[3] == "--":
        ask(argv[1], argv[2], " ".join(argv[4:]))
        emit(ev="done")
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
