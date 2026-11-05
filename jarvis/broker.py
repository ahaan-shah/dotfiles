#!/usr/bin/env python3
"""broker.py — EVE's hands in advanced mode (2026-10-26).

An MCP server (stdio, JSON-RPC 2.0, one message per line — written out by
hand, there is no `mcp` package here). chat.py names it with --mcp-config
when Settings -> AI -> EVE's capabilities is Advanced; in Basic it is never
started. Claude then has WebSearch, WebFetch and THESE tools, and nothing
else: no Read, Glob, Grep, Bash, Edit or Write. Every action on the desktop
goes through a function below, and every rule is policy.py's or this file's
— code, not prompt.

Three tiers, decided here and not by the model:

  quiet    never asks: find files by NAME, the bar's own state, music,
           volume, brightness, Bluetooth status
  action   asks only after a web page was fetched this turn (a page can
           carry instructions; after one, nothing moves without a yes):
           open/close apps and files, captures, todo/reminder adds,
           Bluetooth changes, commands from the allowlist
  always   asks every time: reading a file's contents, writing one,
           anything as root (and root also needs the password box)

Approvals use chat.py's existing channel: a `.ask` file in EVE_ASK_DIR,
which chat.py turns into a card on the bar, answered with `.ans`. Claude
itself cannot write there — it has no tool that writes files.

Every call is appended to $XDG_STATE_HOME/hyprahaan/eve/audit.jsonl: tool,
arguments, decision, outcome.

Since 2026-11-03 this is EVE's only kit (Basic, with its shell, is gone) and
~/EVE is her folder: reads, searches and writes there need no yes, anything
else under home asks — a read can be answered "Yes, this folder" so the rest
of that folder is free for the conversation. Whatever text reaches Claude
(files, search hits, command output) goes through policy.redact(), and once
anything local has been read the conversation is SEALED: no web (chat.py's
gate), no remote images or clickable links on the card, and nothing here
that could carry data out (ping to a name, a non-Spotify URI to a player).
"""
import difflib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import policy  # noqa: E402

HOME = Path.home()
ASK_DIR = Path(os.environ.get("EVE_ASK_DIR") or "/nonexistent")
SESSION = os.environ.get("EVE_SESSION", "")
TAINT = Path(os.environ.get("EVE_TAINT") or "/nonexistent")
QS = os.environ.get("EVE_QS") or str(HOME / ".config/shell")
# act.py reads these at import: send its IPC calls to the shell that started
# EVE (a repo instance while testing), and its scripts from the same tree.
os.environ.setdefault("JARVIS_QS", QS)
STATE = Path(os.environ.get("XDG_STATE_HOME") or HOME / ".local/state") / "hyprahaan/eve"
AUDIT = STATE / "audit.jsonl"
ASK_WAIT = 600
# Claude, which started this broker. An interrupt (right click on the orb)
# stops chat.py and Claude with it; a broker still sleeping in ask() or
# _terminal() would otherwise sit out its 10 or 30 min as an orphan.
PARENT = os.getppid()


def orphaned():
    return os.getppid() != PARENT
import act  # noqa: E402  (after JARVIS_QS is set)

SCRIPTS = act.SCRIPTS


# ── plumbing ────────────────────────────────────────────────────────────

def audit(tool, args, decision, outcome=""):
    try:
        STATE.mkdir(parents=True, exist_ok=True)
        with open(AUDIT, "a") as f:
            f.write(json.dumps({"t": time.strftime("%Y-%m-%dT%H:%M:%S"), "session": SESSION, "tool": tool,
                                "args": {k: (v[:300] if isinstance(v, str) else v) for k, v in args.items()},
                                "decision": decision, "outcome": str(outcome)[:300]}, ensure_ascii=False) + "\n")
    except OSError:
        pass


def said():
    """What Ahaan typed this turn (chat.py writes it before each message)."""
    try:
        return (TAINT / "said").read_text()
    except OSError:
        return ""


def fetched():
    return (TAINT / "fetched").exists()


def sealed():
    """Something local has been read in this conversation (chat.py's header)."""
    return (TAINT / "read").exists()


def mark_read(what):
    """Seal the conversation. Raises if it can't be recorded: an unrecorded
    read would leave the web open."""
    try:
        TAINT.mkdir(parents=True, exist_ok=True)
        with open(TAINT / "read", "a") as f:
            f.write(" ".join(str(what).split())[:200] + "\n")
    except OSError:
        raise Refused("could not record the read, so it was not made")


def granted(p):
    """A folder Ahaan said "Yes, this folder" to in this conversation."""
    try:
        dirs = [Path(l) for l in (TAINT / "grants").read_text().splitlines() if l.strip()]
    except OSError:
        return False
    for d in dirs:
        try:
            Path(p).relative_to(d)
            return True
        except ValueError:
            pass
    return False


def grant(d):
    TAINT.mkdir(parents=True, exist_ok=True)
    with open(TAINT / "grants", "a") as f:
        f.write(str(d) + "\n")


def ask(kind, title, body, yes="Yes", aid=None, **extra):
    """Put a card on the bar and wait for the answer. -> True only on yes
    (or "folder", which only asks that pass `always` can get)."""
    return answer_of(kind, title, body, yes, aid, **extra) in ("yes", "folder")


def answer_of(kind, title, body, yes="Yes", aid=None, **extra):
    """The same, -> "yes" | "folder" | "no". extra may carry `always` (a
    third button's label, answered "folder") and `pick` ("no" starts the
    keyboard on No)."""
    if not ASK_DIR.is_dir():
        return "no"
    aid = aid or f"b{time.time_ns()}"
    tmp = ASK_DIR / (aid + ".tmp")
    tmp.write_text(json.dumps(dict(kind=kind, description=title, command=body, yes=yes, **extra)))
    tmp.replace(ASK_DIR / (aid + ".ask"))
    ans = ASK_DIR / (aid + ".ans")
    end = time.monotonic() + ASK_WAIT
    while time.monotonic() < end:
        if ans.exists():
            a = ans.read_text().strip()
            return a if a in ("yes", "folder") else "no"
        if orphaned() or not ASK_DIR.is_dir():      # interrupted: chat.py removed the dir
            return "no"
        time.sleep(0.1)
    return "no"


def may_read(p, what, pic=False, aid=None, peek_=None):
    """The one door for contents outside ~/EVE: free in ~/EVE or a granted
    folder, else a card with Yes / Yes, this folder / No. peek_ is called
    only when there is a card to show it on (a PDF's page is rendered)."""
    if policy.in_eve(p) or granted(p):
        return True
    folder = p if p.is_dir() else p.parent
    a = answer_of("read", what, short(p), "Yes, show it" if pic else "Yes, read it", aid=aid,
                  always=f"Yes, all of {short(folder)}/", **(peek_() if peek_ else {}))
    if a == "folder":
        grant(folder)
    return a != "no"


def gate(tool, args, title, body, yes="Yes, do it"):
    """The action tier: free unless the turn has fetched a web page."""
    if not fetched():
        return True
    return ask("action", title + "  (asked after reading a web page)", body, yes)


def qs(*args, timeout=5):
    try:
        r = subprocess.run(["qs", "-p", QS, "ipc", "call", *map(str, args)],
                           capture_output=True, text=True, timeout=timeout)
        return r.stdout.strip() or r.stderr.strip()
    except (OSError, subprocess.TimeoutExpired) as e:
        return f"error: {e}"


def short(p):
    p = str(p)
    return "~" + p[len(str(HOME)):] if p.startswith(str(HOME)) else p


class Refused(Exception):
    pass


# ── tools ───────────────────────────────────────────────────────────────
TOOLS = {}


def tool(name, desc, props=None, required=()):
    def wrap(fn):
        TOOLS[name] = {"fn": fn, "schema": {"name": name, "description": desc, "inputSchema": {
            "type": "object", "properties": props or {}, "required": list(required)}}}
        return fn
    return wrap


S = {"type": "string"}
I = {"type": "integer"}


# files: names freely, contents only with a yes

@tool("find_files", "Find files by NAME (fuzzy, like fzf) under the home folder. Never reads contents. "
      "`name` is words from the file name (e.g. 'batman'); `folder` narrows to a folder by name "
      "(e.g. 'wallpapers'); `kind` is pdf|image|video|audio|doc; `latest` sorts newest first.",
      {"name": S, "folder": S, "kind": {"type": "string", "enum": ["pdf", "image", "video", "audio", "doc"]},
       "latest": {"type": "boolean"}})
def find_files(a):
    found, root, err, fuzzy = act.find_files(a.get("name") or None, a.get("folder") or None,
                                             a.get("kind") or None, bool(a.get("latest")), limit=10)
    if err:
        return err
    if not found:
        return "No files matched."
    head = "Closest matches (none matched the words exactly):" if fuzzy else "Matches:"
    return head + "\n" + "\n".join(short(p) for p in found)


@tool("open_file", "Open a file or folder in its default app (PDF viewer, image viewer, editor for text, "
      "file manager for a folder). Programs and scripts are shown in the file manager, never run.",
      {"path": S}, ["path"])
def open_file(a):
    p = policy.expand(a["path"])
    if not p.exists() or not act.safe(p):
        raise Refused("not found, hidden, or outside the home folder")
    if not gate("open_file", a, "Open this?", short(p), "Yes, open it"):
        raise Refused("Ahaan said no")
    import chat
    chat.open_path(str(p), reveal=False)
    return f"Opened {short(p)}"


@tool("show_in_files", "Show a file in the file manager with it selected.", {"path": S}, ["path"])
def show_in_files(a):
    p = policy.expand(a["path"])
    if not p.exists() or not act.safe(p):
        raise Refused("not found, hidden, or outside the home folder")
    import chat
    chat.open_path(str(p), reveal=True)
    return f"Showing {short(p)}"


@tool("read_file", "Read a file so you can answer about it (summaries etc). Free inside ~/EVE (relative "
      "paths are ~/EVE); anywhere else under home Ahaan approves it on the bar. Text and PDFs come back as "
      "text; images (png, jpg, webp, gif, screenshots, photos) come back as the picture itself. Secret files "
      "(keys, .env, tokens, vaults, browser and app data) are always refused, and secret-looking values in "
      "text come back as «redacted». Reading anything turns web access off for the rest of this conversation.",
      {"path": S}, ["path"])
def read_file(a):
    p, why = policy.read_ok(a["path"])
    if not p:
        raise Refused(why)
    size = p.stat().st_size
    pic = policy.is_image(p)
    aid = f"b{time.time_ns()}"
    # Checked BEFORE the card: a key file is refused without asking, so a
    # yes can never be what lets one through.
    if not pic:
        out, why, n = policy.readable_text(p)
        if out is None:
            raise Refused(why)
    if not may_read(p, ("Let EVE see this image?" if pic else "Let EVE read this file?") + f"  ({size:,} bytes)",
                    pic, aid, lambda: peek(p, pic, aid)):
        raise Refused("Ahaan said no")
    mark_read(short(p))
    if pic:
        img, why = policy.image_of(p)
        if img is None:
            raise Refused(why)
        return Image(*img)
    return out + (f"\n\n[{n} secret-looking value(s) were redacted]" if n else "")


@tool("search_text", "Search INSIDE files for words (case-insensitive, plain text, not regex). `folder` "
      "defaults to ~/EVE, where it is free; any other folder under home Ahaan approves first. Skips hidden, "
      "secret and binary files. Returns up to 60 matching lines as path:line: text, with secret-looking values "
      "redacted. Counts as a read (web goes off).",
      {"text": S, "folder": S}, ["text"])
def search_text(a):
    q = (a.get("text") or "").strip().lower()
    if len(q) < 2:
        raise Refused("search for at least 2 characters")
    root = policy.expand(a.get("folder") or "~/EVE")
    if not root.is_absolute():
        root = policy.EVE_HOME / root
    if not root.is_dir():
        raise Refused("no such folder")
    rr = root.resolve()
    if policy._rel(rr) is None or policy.encrypted(root) or policy.hidden_off(root.absolute()) or policy.hidden_off(rr):
        raise Refused("that folder is off limits")
    if not may_read(root, f"Let EVE search inside this folder for “{q}”?"):
        raise Refused("Ahaan said no")
    mark_read(f"search {q!r} in {short(root)}")
    hits, files, n_red = [], 0, 0
    for dp, dns, fns in os.walk(rr):
        dns[:] = [d for d in dns if not d.startswith(".") and d not in ("node_modules", "__pycache__", "venv")
                  and not policy.encrypted(Path(dp) / d)]
        for fn in fns:
            f = Path(dp) / fn
            if fn.startswith(".") or policy.SECRET_NAME.search(fn) or f.is_symlink():
                continue
            try:
                if f.stat().st_size > 2_000_000:
                    continue
                with open(f, "rb") as fh:
                    if b"\x00" in fh.read(4096):
                        continue
                t = f.read_text(errors="replace")
            except OSError:
                continue
            files += 1
            if files > 5000:
                break
            if q not in t.lower() or policy.has_private_key(t):
                continue
            for i, line in enumerate(t.splitlines(), 1):
                if q in line.lower():
                    red, k = policy.redact(line.strip()[:240])
                    n_red += k
                    hits.append(f"{short(f)}:{i}: {red}")
                    if len(hits) >= 60:
                        break
            if len(hits) >= 60:
                break
        if len(hits) >= 60 or files > 5000:
            break
    if not hits:
        return f"No matches for “{q}” in {short(root)}."
    return "\n".join(hits) + (f"\n[{n_red} secret-looking value(s) redacted]" if n_red else "")


@tool("docs", "Look something up in the local documentation instead of the web: man pages and, if "
      "installed, the offline Arch Wiki. `topic` is a command (e.g. 'journalctl') or words ('bluetooth "
      "headset'). Free, and does NOT turn the web off, so prefer it for how-to questions in a conversation "
      "that has read files.", {"topic": S}, ["topic"])
def docs(a):
    t = (a.get("topic") or "").strip()
    if not re.fullmatch(r"[\w .+:-]{1,80}", t):
        raise Refused("give a command name or a few plain words")
    out = []
    env = dict(os.environ, MANWIDTH="90", MANPAGER="cat", PAGER="cat")
    if " " not in t and shutil.which("man"):
        r = subprocess.run(["man", "--", t], capture_output=True, text=True, timeout=10, env=env)
        if r.returncode == 0 and r.stdout.strip():
            out.append(f"man {t}:\n" + re.sub(r".\x08", "", r.stdout)[:9000])
    wiki = Path("/usr/share/doc/arch-wiki/html")
    if wiki.is_dir():
        words = [w.lower() for w in t.split()]
        pages = sorted(f for f in wiki.rglob("*.html") if all(w in f.stem.lower() for w in words))[:5]
        if pages:
            txt = re.sub(r"<[^>]+>", " ", pages[0].read_text(errors="replace"))
            txt = re.sub(r"[ \t]+", " ", re.sub(r"\n\s*\n+", "\n\n", txt))
            out.append(f"Arch Wiki — {pages[0].stem}:\n{txt[:9000]}"
                       + ("\nOther pages: " + ", ".join(p.stem for p in pages[1:]) if pages[1:] else ""))
    if not out and shutil.which("apropos"):
        r = subprocess.run(["apropos", "--", t], capture_output=True, text=True, timeout=10, env=env)
        if r.stdout.strip():
            out.append("Related man pages:\n" + r.stdout[:3000])
    if not out:
        return ("Nothing in the local docs for that." + ("" if shutil.which("man") else
                " (man-db is not installed)") + ("" if wiki.is_dir() else " (arch-wiki-docs is not installed)"))
    return "\n\n".join(out)


def peek(p, pic, aid):
    """What the approval card shows of the file, so Ahaan can see what he is
    agreeing to — the screenshot that was actually taken, the page, the
    first lines (Ahaan, 2026-10-26: "can i see the screenshot preview without
    the model seeing it?"). It rides in the .ask file, which only chat.py and
    the bar read; Claude gets nothing until the yes, when read_file returns.
      peek_image  a local picture for the card: the image itself, or a PDF's
                  first page rendered to ASK_DIR (gone when the turn ends)
      peek_text   the first lines of a text file"""
    try:
        if pic:
            return {"peek_image": str(p)}
        if p.suffix.lower() == ".pdf":
            out = ASK_DIR / f"{aid}-page"
            # Sized in pixels, not dpi: -r 70 gave a Letter page 595 px wide,
            # which the card (scale-2 panel) blew up to ~2x and read blurry
            # (Ahaan, 2026-10-26). 2000 px on the long side covers the card's
            # sourceSize cap (1400 wide) at any page shape.
            subprocess.run(["pdftoppm", "-png", "-scale-to", "2000", "-f", "1", "-l", "1", "-singlefile",
                            str(p), str(out)],
                           capture_output=True, timeout=15)
            if out.with_suffix(".png").exists():
                return {"peek_image": str(out.with_suffix(".png"))}
            return {}
        text, _ = policy.text_of(p, limit=4000)
        if text:
            return {"peek_text": "\n".join(text.splitlines()[:40])}
    except (OSError, subprocess.TimeoutExpired):
        pass
    return {}


class Image:
    """A tool result that is a picture: call() sends it as an MCP image
    block, which Claude Code hands to the model as an image."""
    def __init__(self, data, mime):
        self.data, self.mime = data, mime


@tool("write_file", "Create or change a text file. In ~/EVE (relative paths) it is free, folders are made as "
      "needed: use it for notes, drafts, research. Anywhere else under home (not hidden, not secret, the folder "
      "must exist) ONLY when Ahaan explicitly asked for that write in this message; he sees the diff and "
      "approves it. `content` is the WHOLE new file.",
      {"path": S, "content": S}, ["path", "content"])
def write_file(a):
    p, why = policy.write_ok(a["path"])
    if not p:
        raise Refused(why)
    eve = policy.in_eve(p)
    if not eve and not policy.asked_to_write(said()):
        raise Refused("Ahaan did not ask for a file outside ~/EVE to be written in this message")
    new = a["content"]
    if len(new.encode()) > 200_000:
        raise Refused("larger than 200 KB")
    old = p.read_text(errors="replace") if p.exists() else ""
    diff = list(difflib.unified_diff(old.splitlines(), new.splitlines(), lineterm="", n=1))[2:]
    if p.exists() and not diff:
        return "No change: the file already says that."
    shown = "\n".join(diff[:60]) + (f"\n… {len(diff) - 60} more lines" if len(diff) > 60 else "")
    verb = "Change" if p.exists() else "Create"
    # Outside ~/EVE the keyboard starts on No: a write there can be a config
    # that runs at login, and the catcher holds the keys the moment the card
    # is up, so a stray Enter must not be the yes.
    if not eve and not ask("write", f"{verb} {short(p)}?", shown or "(empty file)", "Yes, write it", pick="no"):
        raise Refused("Ahaan said no")
    if eve:
        p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_name(f".{p.name}.eve-{os.getpid()}")
    tmp.write_text(new)
    if p.exists():
        os.chmod(tmp, p.stat().st_mode & 0o666)
    tmp.replace(p)
    return f"{verb}d {short(p)}"


# commands

@tool("run", "Run ONE harmless read-only command, given as a list of words, no shell (no pipes, redirects, "
      "&&). Allowed: uptime uname whoami hostname date cal df free lsblk lscpu lsusb lspci sensors nvidia-smi ps "
      "pgrep ip ping(-c<=5) nmcli wpctl playerctl bluetoothctl systemctl(status etc) journalctl(-n<=300) "
      "hyprctl(read) pacman(-Q/-Ss/-Si) checkupdates which ls du stat tree fastfetch powerprofilesctl "
      "timedatectl loginctl fc-list acpi upower brightnessctl(get). Anything else is refused.",
      {"argv": {"type": "array", "items": S}}, ["argv"])
def run(a):
    argv, why = policy.run_ok(a.get("argv"))
    if not argv:
        raise Refused(why)
    argv = [os.path.expanduser(x) if x.startswith("~") else x for x in argv]
    # A name to ping is a DNS lookup, and a lookup can spell out anything:
    # once sealed, only an address.
    if argv[0] == "ping" and sealed() and not re.fullmatch(r"[\d.]+|[0-9a-fA-F:]+", argv[-1]):
        raise Refused("this conversation has read local files, so ping takes an IP address only")
    if not gate("run", a, "Run this command?", shlex.join(argv), "Yes, run it"):
        raise Refused("Ahaan said no")
    # Output that can show what is in files or processes (names, command
    # lines, logs, unit environments) seals the conversation; pure hardware
    # and state readouts do not.
    if argv[0] not in QUIET_RUN:
        mark_read("ran: " + shlex.join(argv))
    env = {k: v for k, v in os.environ.items() if k in ("PATH", "HOME", "LANG", "USER", "XDG_RUNTIME_DIR",
           "WAYLAND_DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE", "DBUS_SESSION_BUS_ADDRESS", "TERM")}
    env["SYSTEMD_PAGER"] = env["PAGER"] = "cat"
    try:
        r = subprocess.run(argv, capture_output=True, text=True, timeout=20, env=env,
                           stdin=subprocess.DEVNULL, cwd=str(HOME))
    except subprocess.TimeoutExpired:
        return "timed out after 20 s"
    except OSError as e:
        return f"could not run: {e}"
    out = (r.stdout + ("\n" + r.stderr if r.stderr.strip() else ""))[:12000]
    out, n = policy.redact(out)
    return ((out or "(no output)") + (f"\n[exit {r.returncode}]" if r.returncode else "")
            + (f"\n[{n} secret-looking value(s) redacted]" if n else ""))


QUIET_RUN = {"uptime", "uname", "whoami", "hostname", "date", "cal", "df", "free", "lsblk", "lscpu", "lsusb",
             "lspci", "sensors", "nvidia-smi", "ip", "ping", "nmcli", "wpctl", "playerctl", "bluetoothctl",
             "checkupdates", "which", "fastfetch", "powerprofilesctl", "timedatectl", "acpi", "upower",
             "brightnessctl", "pacman", "fc-list"}


# the bar

def pick(query, rows, what, verb="delete"):
    """The one row Ahaan's words mean. rows: [(id, text, label)]. An exact id,
    then exact text, then a substring, all case-folded. Zero or several is a
    Refused naming the candidates, so Claude asks instead of guessing: a
    delete has no undo, and "the gym one" with two gym tasks is a question."""
    q = (query or "").strip()
    if not q:
        raise Refused(f"{verb} which {what}?")
    f = q.casefold()
    for test in (lambda r: r[0] == q, lambda r: r[1].casefold() == f, lambda r: f in r[1].casefold()):
        hit = [r for r in rows if test(r)]
        if len(hit) == 1:
            return hit[0]
        if hit:
            raise Refused(f"several {what}s match {q!r}: " + "; ".join(r[2] for r in hit)
                          + ". Ask which one (or pass its exact text).")
    raise Refused(f"no {what} matches {q!r}. They are: " + ("; ".join(r[2] for r in rows) or "(none)"))


def clock(s):
    """'18:30', '6pm', '6:30 am', '9' -> minutes past midnight. act.reminder's
    reading, so add and edit take the same words."""
    m = re.fullmatch(r"(\d{1,2})(?::(\d{2}))?\s*(am|pm)?", (s or "").strip().lower())
    if not m or int(m[1]) > 23 or int(m[2] or 0) > 59 or (m[3] and not 1 <= int(m[1]) <= 12):
        raise Refused(f"I didn't understand the time {s!r}")
    h = int(m[1]) % 12 + (12 if m[3] == "pm" else 0) if m[3] else int(m[1])
    return h * 60 + int(m[2] or 0)


def day(s):
    """'today' | 'tomorrow' | weekday name (the next one, today excluded) |
    YYYY-MM-DD -> that day's local midnight, epoch seconds."""
    s = (s or "").strip().lower()
    t = time.localtime()
    midnight = time.mktime((t.tm_year, t.tm_mon, t.tm_mday, 0, 0, 0, 0, 0, -1))
    days = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
    if s == "today":
        return midnight
    if s == "tomorrow":
        n = 1
    elif s in days:
        n = (days.index(s) - t.tm_wday) % 7 or 7
    elif re.fullmatch(r"\d{4}-\d{2}-\d{2}", s):
        try:
            return time.mktime(time.strptime(s, "%Y-%m-%d"))
        except ValueError:
            raise Refused(f"no such date {s!r}")
    else:
        raise Refused(f"date must be today, tomorrow, a weekday or YYYY-MM-DD, not {s!r}")
    # Through a struct, not +86400: a DST change makes some days 23 or 25 h.
    return time.mktime((t.tm_year, t.tm_mon, t.tm_mday + n, 0, 0, 0, 0, 0, -1))


def stamp(ms):
    return time.strftime("%a %d %b %H:%M", time.localtime(ms / 1000))


@tool("todo", "Ahaan's todo list on the bar. action: list | add (with text) | edit | remove | show (open it "
      "on screen). edit and remove find the task by text = its words or a unique part. edit changes any of: "
      "new_text; urgent / important (true/false); due = today | tomorrow | a weekday | YYYY-MM-DD | none; "
      "at = a time on that day ('18:30', '6pm'; with no due, the task's current day or today) — a timed "
      "task still ahead gets its reminder moved with it. remove: he confirms on a card.",
      {"action": {"type": "string", "enum": ["list", "add", "edit", "remove", "show"]}, "text": S,
       "new_text": S, "urgent": {"type": "boolean"}, "important": {"type": "boolean"}, "due": S, "at": S},
      ["action"])
def todo(a):
    act_ = a["action"]
    if act_ == "list":
        return qs("todo", "list")
    if act_ == "show":
        qs("todo", "open")
        return "Todo list open."
    text = (a.get("text") or "").strip()
    if act_ in ("remove", "edit"):
        try:
            items = json.loads(qs("todo", "items"))
        except ValueError:
            raise Refused("could not read the todo list (is the shell running?)")
        tid, ttext, _ = pick(text, [(x["id"], x["text"], x["text"] + (" [done]" if x["done"] else ""))
                                    for x in items], "task", act_)
        old = next(x for x in items if x["id"] == tid)
    if act_ == "remove":
        # Always a card, web page or not: add is undone by a delete, a delete
        # is undone by nothing.
        if not ask("action", "Delete this task?", ttext, "Yes, delete it"):
            raise Refused("Ahaan said no")
        out = qs("todo", "remove", tid)
        return f"Deleted: {ttext}" if out == "removed" else out
    if act_ == "edit":
        f, said_ = {}, []
        if (a.get("new_text") or "").strip():
            f["text"] = a["new_text"].strip()
            said_.append(f"text → {f['text']}")
        for k in ("urgent", "important"):
            if isinstance(a.get(k), bool):
                f[k] = a[k]
                said_.append(f"{k} → {'yes' if a[k] else 'no'}")
        due, at = (a.get("due") or "").strip().lower(), (a.get("at") or "").strip()
        if due == "none":
            if at:
                raise Refused("due none with a time? pick one")
            f["due"], f["timed"] = 0, False
            said_.append("no due date")
        elif due or at:
            if due:
                base = day(due)
            elif old.get("due"):
                o = time.localtime(old["due"] / 1000)
                base = time.mktime((o.tm_year, o.tm_mon, o.tm_mday, 0, 0, 0, 0, 0, -1))
            else:
                base = day("today")
            if at:
                b = time.localtime(base)
                mins = clock(at)
                f["due"] = int(time.mktime((b.tm_year, b.tm_mon, b.tm_mday, mins // 60, mins % 60, 0, 0, 0, -1))
                               * 1000)
                f["timed"] = True
                said_.append(f"due {stamp(f['due'])}")
            else:
                # A new day keeps the time it had, as moving it in the day view would.
                if old.get("timed") and old.get("due"):
                    o = time.localtime(old["due"] / 1000)
                    b = time.localtime(base)
                    f["due"] = int(time.mktime((b.tm_year, b.tm_mon, b.tm_mday, o.tm_hour, o.tm_min, 0, 0, 0, -1))
                                   * 1000)
                    f["timed"] = True
                    said_.append(f"due {stamp(f['due'])}")
                else:
                    f["due"], f["timed"] = int(base * 1000), False
                    said_.append("due " + time.strftime("%a %d %b", time.localtime(base)))
        if not f:
            raise Refused("edit it how? (new_text, urgent, important, due, at)")
        if not gate("todo", a, "Change this task?", f"{ttext}\n" + "\n".join(said_)):
            raise Refused("Ahaan said no")
        out = qs("todo", "edit", tid, json.dumps(f))
        return f"Edited {ttext!r}: " + "; ".join(said_) if out == "edited" else out
    if not text:
        raise Refused("add what?")
    if not gate("todo", a, "Add this task?", text):
        raise Refused("Ahaan said no")
    qs("todo", "add", text)
    return f"Added: {text}"


@tool("reminder", "Reminders on the bar. action: list | add (text + in_minutes, or text + at 'HH:MM' "
      "24h or '6pm') | edit | remove | show. edit and remove find the reminder by text = its words, a "
      "unique part, or its id from list. edit changes new_text and/or the time: in_minutes from now, or at "
      "(+ optional date = today | tomorrow | a weekday | YYYY-MM-DD; without one, the next such time). "
      "remove: he confirms on a card.",
      {"action": {"type": "string", "enum": ["list", "add", "edit", "remove", "show"]}, "text": S,
       "new_text": S, "in_minutes": I, "at": S, "date": S},
      ["action"])
def reminder(a):
    act_ = a["action"]
    if act_ == "list":
        return f"Now: {time.strftime('%Y-%m-%d %H:%M')}\n" + qs("reminder", "list")
    if act_ == "show":
        qs("reminder", "open")
        return "Reminders open."
    if act_ in ("remove", "edit"):
        # list() lines: "yyyy-MM-dd hh:mm:ss  [pending] text   (id)" (Bar.qml).
        rows = []
        for line in qs("reminder", "list").splitlines():
            m = re.fullmatch(r"(\S+ \d\d:\d\d):\d\d\s+\[(\w+)\]\s+(.*?)\s+\((\S+)\)", line.strip())
            if m:
                rows.append((m[4], m[3], f"{m[3]} ({m[1]}, {m[2]})"))
        rid, rtext, label = pick(a.get("text"), rows, "reminder", act_)
    if act_ == "remove":
        if not ask("action", "Delete this reminder?", label, "Yes, delete it"):
            raise Refused("Ahaan said no")
        # dismiss = RemindersState.remove, pending or fired alike.
        qs("reminder", "dismiss", rid)
        return f"Deleted reminder: {rtext}"
    if act_ == "edit":
        # A timed task's reminder is the task's: moving it here would leave the
        # task saying one time and the chip firing at another.
        try:
            owner = next((x for x in json.loads(qs("todo", "items")) if x.get("rid") == rid), None)
        except ValueError:
            owner = None
        if owner:
            raise Refused(f"that reminder belongs to the task {owner['text']!r}: edit the task (todo edit, "
                          "due/at) and its reminder moves with it")
        new_text = (a.get("new_text") or "").strip()
        at_ms = 0
        if a.get("in_minutes"):
            if a["in_minutes"] <= 0:
                raise Refused("in_minutes must be more than 0")
            at_ms = int((time.time() + a["in_minutes"] * 60) * 1000)
        elif a.get("at") or a.get("date"):
            mins = clock(a["at"]) if a.get("at") else None
            if a.get("date"):
                if mins is None:
                    raise Refused("a date needs a time too (at)")
                b = time.localtime(day(a["date"]))
                at_ms = int(time.mktime((b.tm_year, b.tm_mon, b.tm_mday, mins // 60, mins % 60, 0, 0, 0, -1)) * 1000)
            else:
                t = time.localtime()
                at_s = time.mktime((t.tm_year, t.tm_mon, t.tm_mday, mins // 60, mins % 60, 0, 0, 0, -1))
                if at_s <= time.time():
                    at_s = time.mktime((t.tm_year, t.tm_mon, t.tm_mday + 1, mins // 60, mins % 60, 0, 0, 0, -1))
                at_ms = int(at_s * 1000)
        if not new_text and not at_ms:
            raise Refused("edit it how? (new_text, in_minutes, at/date)")
        said_ = ([f"text → {new_text}"] if new_text else []) + ([f"at {stamp(at_ms)}"] if at_ms else [])
        if not gate("reminder", a, "Change this reminder?", f"{label}\n" + "\n".join(said_)):
            raise Refused("Ahaan said no")
        out = qs("reminder", "edit", rid, new_text, str(at_ms or ""))
        return f"Edited reminder {rtext!r}: " + "; ".join(said_) if out == "edited" else out
    if not (a.get("text") or "").strip():
        raise Refused("remind about what?")
    if not gate("reminder", a, "Set this reminder?", f"{a.get('text')}  ({a.get('at') or str(a.get('in_minutes')) + ' min'})"):
        raise Refused("Ahaan said no")
    r = act.reminder({"text": a["text"], "minutes": a.get("in_minutes"), "at": a.get("at")}, False)
    return r["msg"]


@tool("agenda", "Today at a glance: date and time, the todo list (with due dates) and reminders. "
      "show=true also opens the calendar on screen, on today's day view.", {"show": {"type": "boolean"}})
def agenda(a):
    if a.get("show"):
        qs("calendar", "date", time.strftime("%Y-%m-%d"))
    return (f"Now: {time.strftime('%A %d %B %Y, %H:%M')}\n\nTodo:\n{qs('todo', 'list')}"
            f"\n\nReminders:\n{qs('reminder', 'list')}")


@tool("calendar", "Open the calendar on screen. date = YYYY-MM-DD opens that day's view (its tasks and "
      "reminders); without a date it opens this month.", {"date": S})
def calendar(a):
    d = (a.get("date") or "").strip()
    if d and not re.fullmatch(r"\d{4}-\d{2}-\d{2}", d):
        raise Refused("date must be YYYY-MM-DD")
    if d:
        qs("calendar", "date", d)
    else:
        qs("calendar", "open")
    return f"Calendar open on {d}." if d else "Calendar open on this month."


# The Gita reader on the bar (Ahaan, 2026-11-05). The panel goes through the
# shell like the calendar does. Text comes straight from the book's files, so
# reading a verse neither moves the reading place nor needs the panel open, and the
# purports (1.3 MB the shell only loads on S or P) don't get loaded into it.
#
# No gate and no seal: this is a published book in a file the broker reads by
# fixed path, not one of Ahaan's documents, so "what does 2.47 say" must not close
# off the web for the rest of the conversation the way read_file does.
GITA_DIR = Path(os.environ.get("XDG_DATA_HOME") or HOME / ".local/share") / "hyprahaan"
GITA_REF = re.compile(r"(\d+)\D+(\d+)")     # GitaState.find's: "2.13", "2 13", "bg 2.13"
_gita_book = {}


def gita_file(name):
    if name not in _gita_book:
        try:
            _gita_book[name] = json.loads((GITA_DIR / name).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            raise Refused("the Gita text is not built on this machine "
                          "(python3 ~/.config/scripts/gita-from-pdf.py <book.pdf>)")
    return _gita_book[name]


def gita_verse(ref):
    """(chapter, verse) for a reference. As GitaState.find does, any verse of a
    merged page finds it: 1.17 is the page 1.16-18."""
    m = GITA_REF.search(str(ref or ""))
    if m:
        for c in gita_file("gita.json").get("chapters", []):
            if c.get("n") == int(m.group(1)):
                for v in c.get("verses", []):
                    p = [int(x) for x in str(v.get("n")).split("-")]
                    if p[0] <= int(m.group(2)) <= p[-1]:
                        return c, v
    raise Refused(f"no such verse: {ref} (give chapter.verse, e.g. 2.47)")


def gita_tr(v):
    return "\n".join((f"{x['who']}: " if x.get("who") else "") + x.get("t", "") for x in v.get("tr", []))


def gita_place():
    """The reading place, from the running shell: '4.11 (read)' -> '4.11'."""
    out = qs("gita", "where")
    m = re.match(r"(\d+\.[\d-]+) ", out)
    if not m:
        raise Refused("could not reach the Gita reader (is the shell running?)")
    return m.group(1)


@tool("gita", "The Bhagavad-gita As It Is, in the reader on the bar. action: read (a verse's text for you, "
      "ref = chapter.verse, default the current reading place; purport=true adds word meanings and the purport; "
      "does not open the panel or move the place) | search (query: words, \"a phrase\", -excluded; the "
      "first 5 hits with translations) | where (the current reading place) | open (the panel; with ref, at that "
      "verse) | close | next | previous | random (these move the place and open the panel).",
      {"action": S, "ref": S, "query": S, "purport": {"type": "boolean"}}, ["action"])
def gita(a):
    act_ = (a.get("action") or "").strip()
    gita_file("gita.json")          # no book: say so before anything opens
    if act_ == "read":
        c, v = gita_verse(a.get("ref") or gita_place())
        out = [f"Bg. {v['id']} (chapter {c['n']}, {c.get('title', '')})"]
        out += [x.get("t", "") for x in v.get("roman", [])]
        out += ["Translation:", gita_tr(v)]
        if a.get("purport"):
            x = gita_file("gita-extras.json").get(v["id"]) or {}
            if x.get("syn"):
                out += ["Word meanings:", x["syn"]]
            out += ["Purport:", "\n\n".join(x.get("pp") or []) or "(this verse has none)"]
        return "\n".join(out)
    if act_ == "search":
        q = (a.get("query") or "").strip()
        if not q:
            raise Refused("search for what?")
        # "--": the reader's syntax has -word, and qs takes that for a flag
        # (measured: "-war duty" exits 109 without it).
        # No hits reads "0 |": qs() strips the space a partition(" | ") needs.
        m = re.fullmatch(r"(\d+) \|\s*(.*)", qs("gita", "search", "--", q))
        if not m:
            raise Refused("could not reach the Gita reader (is the shell running?)")
        if m.group(1) == "0":
            return f"No verse matches {q!r}."
        hits = [f"{r}: {gita_tr(gita_verse(r)[1])}" for r in m.group(2).split()]
        return f"Matches: {m.group(1)}. Showing {len(hits)}:\n" + "\n".join(hits)
    if act_ == "where":
        return "Current place: " + gita_place()
    if act_ == "close":
        qs("gita", "close")
        return "Gita closed."
    if act_ == "open":
        ref = a.get("ref")
        target = gita_verse(ref)[1]["id"] if ref else None    # a bad ref opens nothing
        qs("gita", "open")
        if target:
            qs("gita", "go", target)
        return f"Gita open at {gita_place()}."
    if act_ in ("next", "previous", "random"):
        qs("gita", "open")
        qs("gita", {"previous": "prev"}.get(act_, act_))
        return f"Gita open at {gita_place()}."
    raise Refused("action must be read, search, where, open, close, next, previous or random")


@tool("music", "Control music. action: open (the player panel) | play_pause | next | previous | shuffle | "
      "repeat | state.", {"action": {"type": "string", "enum": ["open", "play_pause", "next", "previous",
                                                               "shuffle", "repeat", "state"]}}, ["action"])
def music(a):
    fn = {"play_pause": "playpause", "previous": "prev"}.get(a["action"], a["action"])
    out = qs("music", fn)
    if fn == "state":
        return out
    time.sleep(0.4)
    now = act.sh(["playerctl", "metadata", "--format", "{{status}}: {{title}} — {{artist}}"]).strip()
    return f"Done. {now}" if now else "Done."


SPOTIFY = re.compile(r"(?:spotify:|https?://open\.spotify\.com/(?:intl-[a-z]+/)?)"
                     r"(track|album|playlist|artist|show|episode)[:/]([A-Za-z0-9]{22})")


@tool("play_spotify", "Play a Spotify track/album/playlist/artist in Spotsie (starting it if needed). "
      "`link` is a spotify: URI or an open.spotify.com link — find one with WebSearch first "
      "(e.g. search 'about you the 1975 open.spotify.com').", {"link": S}, ["link"])
def play_spotify(a):
    m = SPOTIFY.search(a.get("link", ""))
    if not m:
        raise Refused("that is not a Spotify link")
    uri = f"spotify:{m.group(1)}:{m.group(2)}"
    if "spotsie" not in act.sh(["playerctl", "-l"]).split():
        act.exec_cmd("spotsie")
        for _ in range(60):
            time.sleep(0.25)
            if "spotsie" in act.sh(["playerctl", "-l"]).split():
                time.sleep(1.0)
                break
        else:
            return "Spotsie didn't start."
    act.sh(["spotsie", "play-uri", uri], timeout=15)
    time.sleep(1.5)
    now = act.sh(["spotsie", "now-playing"], timeout=5).strip()
    return f"Playing {now}" if now else f"Sent {uri} to Spotsie."


@tool("queue_music", "Play something NEXT, after the current track ends, in whatever player is running "
      "(MPRIS — Spotsie, a browser, mpv ...). action add: `link` is a spotify: URI or open.spotify.com link "
      "(find one with WebSearch, as for play_spotify) or another URI the player takes; `title` is "
      "'Song — Artist' for the list. Several adds play in order. action list | clear. Once the queue "
      "has played, the album/playlist that was on before does not resume.",
      {"action": {"type": "string", "enum": ["add", "list", "clear"]}, "link": S, "title": S}, ["action"])
def queue_music(a):
    # mqueue.py is the queue; this is only its door. Quiet tier, like music:
    # it changes what plays next, nothing more.
    import mqueue
    if a["action"] == "clear":
        mqueue.clear()
        return "Queue cleared."
    if a["action"] == "list":
        d = mqueue.load()
        if not d["items"]:
            return "The queue is empty."
        return f"Up next in {d['player']}:\n" + "\n".join(
            f"{i + 1}. {x.get('title') or x['uri']}" for i, x in enumerate(d["items"]))
    if not (a.get("link") or "").strip():
        raise Refused("give a link to queue")
    # Any other URI is fetched by the player, so it could carry what was read.
    if sealed() and not SPOTIFY.search(a["link"]):
        raise Refused("this conversation has read local files, so only Spotify links can be queued")
    try:
        return mqueue.add(a["link"], a.get("title") or "")
    except ValueError as e:
        raise Refused(str(e))


@tool("volume", "Set volume: level 0-100, or change (+/- percent), or mute true/false.",
      {"level": I, "change": I, "mute": {"type": "boolean"}})
def volume(a):
    return act.volume({k: v for k, v in a.items() if v is not None}, False)["msg"]


@tool("brightness", "Set screen brightness: level 1-100, or change (+/- percent).", {"level": I, "change": I})
def brightness(a):
    return act.brightness({k: v for k, v in a.items() if v is not None}, False)["msg"]


@tool("bluetooth", "Bluetooth. action: status | on | off | connect | disconnect (device = part of a PAIRED "
      "device's name; pairing new devices is not possible from EVE).",
      {"action": {"type": "string", "enum": ["status", "on", "off", "connect", "disconnect"]}, "device": S},
      ["action"])
def bluetooth(a):
    act_ = a["action"]
    if act_ == "status":
        show = act.sh(["bluetoothctl", "show"])
        conn = act.sh(["bluetoothctl", "devices", "Connected"]).strip()
        paired = act.sh(["bluetoothctl", "devices", "Paired"]).strip()
        return ("Powered: " + ("yes" if "Powered: yes" in show else "no") +
                f"\nConnected:\n{conn or '(none)'}\nPaired:\n{paired or '(none)'}")
    if act_ in ("on", "off"):
        if not gate("bluetooth", a, f"Turn Bluetooth {act_}?", "bluetoothctl power " + act_):
            raise Refused("Ahaan said no")
        act.sh(["bluetoothctl", "power", act_], timeout=10)
        return f"Bluetooth {act_}."
    want = (a.get("device") or "").lower().strip()
    devs = [l.split(" ", 2)[1:] for l in act.sh(["bluetoothctl", "devices", "Paired"]).splitlines()
            if l.startswith("Device ") and len(l.split(" ", 2)) == 3]
    hits = [(mac, name) for mac, name in devs if want and want in name.lower()]
    if not hits:
        raise Refused("no paired device matches; paired: " + ", ".join(n for _, n in devs))
    mac, name = hits[0]
    if not gate("bluetooth", a, f"{act_.capitalize()} {name}?", f"bluetoothctl {act_} {mac}"):
        raise Refused("Ahaan said no")
    if act_ == "connect" and "Powered: yes" not in act.sh(["bluetoothctl", "show"]):
        act.sh(["bluetoothctl", "power", "on"], timeout=10)
    out = act.sh(["timeout", "20", "bluetoothctl", act_, mac], timeout=25)
    ok = "successful" in out.lower()
    return f"{'Done' if ok else 'Failed'}: {act_} {name}" + ("" if ok else f" ({out.strip().splitlines()[-1:]})")


# windows and apps

@tool("open_app", "Open an app by name (e.g. 'spotsie', 'zen', 'kitty'); if it is already open it is "
      "brought forward. workspace optional.", {"app": S, "workspace": I}, ["app"])
def open_app(a):
    if not gate("open_app", a, "Open this app?", a["app"]):
        raise Refused("Ahaan said no")
    return act.open_app({"app": a["app"], "workspace": a.get("workspace"), "_said": said()}, False)["msg"]


@tool("close_app", "Close an app's window. all=true closes every window of that app (asks first if more "
      "than one).", {"app": S, "all": {"type": "boolean"}}, ["app"])
def close_app(a):
    app = a["app"].strip()
    if app in ("", "*", "all", "everything"):
        raise Refused("name the app to close")
    found = act.find_windows(app)
    targets = found if a.get("all") else found[:1]
    if not targets:
        return f"No open window matches “{app}”."
    names = ", ".join(act.label(c) + " — " + (c.get("title") or "")[:40] for c in targets)
    if len(targets) > 1:
        if not ask("action", f"Close {len(targets)} windows?", names, "Yes, close them"):
            raise Refused("Ahaan said no")
    elif not gate("close_app", a, "Close this window?", names, "Yes, close it"):
        raise Refused("Ahaan said no")
    for c in targets:
        act.dispatch(f"hl.dsp.window.close({{ window = 'address:{c['address']}' }})")
    return f"Closed {names}"


@tool("focus_app", "Switch to an open app's window.", {"app": S}, ["app"])
def focus_app(a):
    found = act.find_windows(a["app"])
    if not found:
        return f"No open window matches “{a['app']}”."
    act.raise_window(found[0])
    return f"Switched to {act.label(found[0])}"


# captures

@tool("screenshot", "Take a screenshot. target: region (Ahaan drags a box) | full | window (with `window` = "
      "app name, or the focused one). dest: file | clipboard | both (default both). The result names the saved "
      "file; to look at the shot (e.g. to summarize what is on screen), call read_file on that path — Ahaan "
      "approves it on the bar. A clipboard-only shot has no file to read.",
      {"target": {"type": "string", "enum": ["region", "full", "window"]}, "window": S,
       "dest": {"type": "string", "enum": ["file", "clipboard", "both"]}, "delay": I}, ["target"])
def screenshot(a):
    if not gate("screenshot", a, "Take a screenshot?", a["target"] + (" " + a["window"] if a.get("window") else "")):
        raise Refused("Ahaan said no")
    act._SAID[0] = said()
    r = act.screenshot({"target": a["target"], "match": a.get("window"), "dest": a.get("dest") or "both",
                        "delay": a.get("delay")}, False)
    # act's line says "saved to Pictures/…", relative to home; read_file
    # takes a relative path as under ~/EVE, so the full one is named.
    return r["msg"] + (f"\nFile: {short(r['path'])}" if r.get("path") else "")


@tool("record", "Screen recording. action: start (target full|region|window, audio none|desktop|both, "
      "optional seconds, optional window app name) | stop.",
      {"action": {"type": "string", "enum": ["start", "stop"]},
       "target": {"type": "string", "enum": ["full", "region", "window"]},
       "audio": {"type": "string", "enum": ["none", "desktop", "both"]}, "seconds": I, "window": S},
      ["action"])
def record(a):
    if a["action"] == "stop":
        return act.record_stop({}, False)["msg"]
    if not gate("record", a, "Start recording?", f"{a.get('target', 'full')}, audio {a.get('audio', 'none')}"):
        raise Refused("Ahaan said no")
    act._SAID[0] = said()
    r = act.record_start({"target": a.get("target") or "full", "audio": a.get("audio") or "none",
                          "seconds": a.get("seconds"), "match": a.get("window")}, False)
    return r["msg"]


# root: only the settings menu's own four, only with his password

PKG = re.compile(r"[a-z0-9@._+-]{1,80}")


def _terminal(title, script, args, wait_s=1800):
    """The settings menu's terminal flow (Settings._term), plus a file the
    exit code lands in so the result can be reported back."""
    TAINT.mkdir(parents=True, exist_ok=True)
    rc = TAINT / f"rc-{time.time_ns()}"
    inner = shlex.join([str(SCRIPTS / script), *args])
    inner += (f"; rc=$?; echo $rc > {shlex.quote(str(rc))}; [ $rc -eq 130 ] && exit 0; "
              "if [ $rc -eq 0 ]; then printf '\\n✅ Done — press any key to close '; "
              "else printf '\\n⚠ Something went wrong — scroll up for the details. Press any key to close '; fi; "
              "read -rsn1 _")
    act.exec_cmd(shlex.join(["kitty", "--title", title, "-e", "bash", "-c", inner]))
    # A terminal closed with SUPER+C never writes rc: bash dies with it. The
    # first cut then waited out all 30 min with the turn stuck on "Pondering…
    # 1 queued" (Ahaan, 2026-10-26). The rc path is unique and sits in bash's
    # own command line, so pgrep on it says whether that terminal is still up;
    # 5 s of grace covers kitty starting.
    start = time.monotonic()
    while time.monotonic() < start + wait_s:
        if rc.exists():
            code = rc.read_text().strip()
            rc.unlink(missing_ok=True)
            return code
        if orphaned():
            return None
        if time.monotonic() > start + 5 and not _alive(rc):
            time.sleep(0.5)                 # rc is written just before bash exits
            if rc.exists():
                continue
            return "closed"
        time.sleep(0.5)
    return None


def _alive(rc):
    r = subprocess.run(["pgrep", "-f", "-c", "--", str(rc)], capture_output=True, text=True)
    return r.stdout.strip() not in ("", "0")


@tool("system", "Things that need root, exactly as the settings menu does them. action: update (system update "
      "in a terminal) | install / remove (package = an official-repo package name; a terminal opens with it "
      "searched, Ahaan picks it and types his password) | firewall_on | firewall_off (Ahaan types his "
      "password into the shell's password box). You never see or handle the password; you only learn "
      "whether it went through. AUR installs are not available.",
      {"action": {"type": "string", "enum": ["update", "install", "remove", "firewall_on", "firewall_off"]},
       "package": S}, ["action"])
def system(a):
    act_ = a["action"]
    if act_ in ("firewall_on", "firewall_off"):
        state = act_.split("_")[1]
        ok = ask("privileged", f"EVE asks to turn the firewall {state}. Type your password in the box, or Esc.",
                 f"firewall.sh {state}", "", action=act_)
        return f"Firewall turned {state}." if ok else "Not done: the password box was cancelled or the command failed."
    if act_ == "update":
        code = _terminal("system-update", "system-update.sh", [])
    else:
        pkg = (a.get("package") or "").strip().lower()
        if not PKG.fullmatch(pkg):
            raise Refused("give one package name")
        code = _terminal("pkg-" + act_, f"pkg-{act_}.sh", ["--query", pkg])
    if code is None:
        return "The terminal is still open; no result yet."
    if code == "closed":
        return "The terminal was closed before it finished, so nothing is known to have changed."
    return {"0": "Done — it went through.", "130": "Cancelled in the picker; nothing changed."}.get(
        code, f"It did not go through (exit {code}); the terminal shows why.")


# ── MCP over stdio ──────────────────────────────────────────────────────

def call(name, args):
    t = TOOLS.get(name)
    if not t:
        return f"unknown tool {name}", True
    try:
        out = t["fn"](args or {})
        audit(name, args or {}, "done", out if name != "read_file" else "(contents)")
        if isinstance(out, Image):
            import base64
            return [{"type": "image", "data": base64.b64encode(out.data).decode(), "mimeType": out.mime}], False
        return str(out), False
    except Refused as e:
        audit(name, args or {}, "refused", e)
        return f"Refused: {e}", True
    except Exception as e:      # a bug here must not take the conversation down
        audit(name, args or {}, "error", repr(e))
        return f"Error: {e}", True


def main():
    for line in sys.stdin:
        try:
            m = json.loads(line)
        except ValueError:
            continue
        mid, meth = m.get("id"), m.get("method", "")
        if mid is None:
            continue                    # a notification: nothing to answer
        if meth == "initialize":
            res = {"protocolVersion": (m.get("params") or {}).get("protocolVersion", "2025-06-18"),
                   "capabilities": {"tools": {}}, "serverInfo": {"name": "eve", "version": "1"}}
        elif meth == "tools/list":
            res = {"tools": [t["schema"] for t in TOOLS.values()]}
        elif meth == "tools/call":
            p = m.get("params") or {}
            out, err = call(p.get("name", ""), p.get("arguments") or {})
            res = {"content": out if isinstance(out, list) else [{"type": "text", "text": out}], "isError": err}
        elif meth == "ping":
            res = {}
        else:
            sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": mid,
                                         "error": {"code": -32601, "message": "no such method"}}) + "\n")
            sys.stdout.flush()
            continue
        sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": mid, "result": res}, ensure_ascii=False) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
