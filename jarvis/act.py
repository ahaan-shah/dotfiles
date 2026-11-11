"""act.py — carry out the calls brain.py chose.

brain.py decides WHAT; this file decides whether it is allowed and HOW. Every
rule that matters is enforced here, not in the model's prompt: the prompt is a
request the model usually honours, this is code that always does. So a
confused model can produce a wrong action, but never a forbidden one:

  - nothing is ever deleted outright: delete only builds a list and parks it,
    and the list goes to the Trash after the password box says yes
  - nothing outside $HOME, and nothing hidden (any path component starting
    with "."), can be read, listed, opened or trashed
  - notes are NEW files only; an existing name gets " (2)", never overwritten
  - shell runs a read-only allowlist with no shell at all (no redirects,
    no substitution, no ;/&&), each argv checked
  - closing more than one window, or "everything" on a workspace, asks first

── Every function takes dry ──────────────────────────────────────────────────
run(call, dry=True) resolves everything a real run would — which window,
which file, which command line — and reports it without doing any of it. That
is how each executor was exercised from a terminal before any UI existed
(CLAUDE.md step 2), and it is what `jarvis.py --dry-run` prints.

── Launching ─────────────────────────────────────────────────────────────────
Everything GUI goes out through Hyprland's own exec (hl.dsp.exec_cmd), so the
compositor is the parent and nothing jarvis starts inherits a pipe from a
Quickshell Process — the SIGPIPE rule in the system map, solved by never
being the parent. exec_cmd also takes window rules: { workspace = 'N silent' }
puts the new window straight on N with no flash on the current workspace
(measured 2026-10-06 on a probe window on a special workspace).
"""

import difflib
import json
import os
import random
import re
import secrets
import shlex
import shutil
import subprocess
import time
import urllib.parse
import urllib.request
from html.parser import HTMLParser
from pathlib import Path

HOME = Path.home()
HERE = Path(__file__).resolve().parent
# In the repo, the sibling scripts/ is the edited copy and the one to test; once
# deployed to ~/.config/jarvis the sibling is ~/.config/scripts. Same rule.
SCRIPTS = Path(os.environ.get("JARVIS_SCRIPTS") or (HERE.parent / "scripts"))
LIVE_SHELL = Path(os.environ.get("JARVIS_QS", HOME / ".config/shell"))
RUN = Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp")) / "jarvis"
PENDING = RUN / "pending"
SHOTS = HOME / "Pictures/Screenshots"
NOTES = HOME / "Documents/Notes"

KIND_EXT = {
    "pdf": {".pdf"},
    "image": {".png", ".jpg", ".jpeg", ".webp", ".gif", ".bmp", ".svg", ".heic", ".avif"},
    "video": {".mp4", ".mkv", ".webm", ".mov", ".avi", ".m4v"},
    "audio": {".mp3", ".flac", ".wav", ".ogg", ".m4a", ".opus"},
    "doc": {".pdf", ".doc", ".docx", ".odt", ".txt", ".md", ".xlsx", ".xls", ".ods", ".csv", ".pptx", ".ppt", ".odp"},
}


class Result(dict):
    """kind: done (one line, fades) | text (body, scrolls) | pick (options)
    | confirm (yes/no, token) | password (password box, token) | offer_claude
    | error.  msg is always the one line the orb shows."""
    def __init__(self, kind, msg, **kw):
        super().__init__(kind=kind, msg=msg, **kw)


# ── plumbing ─────────────────────────────────────────────────────────────────

def sh(argv, timeout=5, input=None):
    try:
        r = subprocess.run(argv, capture_output=True, text=input is None or isinstance(input, str),
                           input=input, timeout=timeout)
        return r.stdout if isinstance(r.stdout, str) else r.stdout.decode(errors="replace")
    except (OSError, subprocess.TimeoutExpired):
        return ""


def ok(argv, timeout=5):
    try:
        return subprocess.run(argv, capture_output=True, timeout=timeout).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def spawn(argv):
    """Detached, both halves (SIGPIPE rule): own session, no inherited fds."""
    subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True)


def hj(what):
    try:
        return json.loads(sh(["hyprctl", what, "-j"]) or "null")
    except ValueError:
        return None


def lua(s):
    """A Lua single-quoted string literal."""
    return "'" + str(s).replace("\\", "\\\\").replace("'", "\\'").replace("\n", " ") + "'"


def dispatch(expr):
    sh(["hyprctl", "dispatch", expr])


def exec_cmd(cmd, workspace=None, settle=6.0):
    """Run a shell command line through Hyprland. workspace=N: put it there,
    silently.

    The exec rule alone is not enough. It binds to the process Hyprland
    spawned, and a single-instance app hands the request to the copy that is
    already running and exits: measured 2026-10-06, `zen --new-window` with
    { workspace = '10 silent' } opened the window on the CURRENT workspace,
    owned by the old Zen pid. So any window that appears after the launch and
    is not on N gets moved there, follow = false. Returns that window's
    address, or None."""
    rules = f", {{ workspace = '{workspace} silent' }}" if workspace else ""
    before = {c["address"] for c in clients()} if workspace else set()
    here = (hj("activeworkspace") or {}).get("id")
    dispatch(f"hl.dsp.exec_cmd({lua(cmd)}{rules})")
    if not workspace:
        return None
    end = time.monotonic() + settle
    while time.monotonic() < end:
        new = [c for c in clients() if c["address"] not in before]
        if new:
            c = new[0]
            if c["workspace"]["id"] != workspace:
                dispatch(f"hl.dsp.window.move({{ workspace = {workspace}, window = 'address:{c['address']}', follow = false }})")
            # "Silent" has to survive the app too. hyprland.lua sets
            # misc.focus_on_activate = true, so an app that asks for focus
            # after mapping (Zen does) drags the view to N anyway — measured.
            # Watch briefly and put the view back where it was.
            if here and here != workspace:
                for _ in range(12):
                    time.sleep(0.1)
                    if (hj("activeworkspace") or {}).get("id") != here:
                        dispatch(f"hl.dsp.focus({{ workspace = {here} }})")
            return c["address"]
        time.sleep(0.1)
    return None


def qs_ipc(*args):
    spawn(["qs", "-p", str(LIVE_SHELL), "ipc", "call", *map(str, args)])


def script(name):
    return str(SCRIPTS / name)


def pref(key):
    return sh([script("ui-prefs.sh"), "get", key]).strip()


def norm(s):
    return re.sub(r"[^a-z0-9]+", "", str(s).lower())


def similar(a, b):
    a, b = norm(a), norm(b)
    if not a or not b:
        return 0.0
    if a == b:
        return 1.0
    if a in b or b in a:
        return 0.9
    return difflib.SequenceMatcher(None, a, b).ratio()


# ── apps (desktop entries) ───────────────────────────────────────────────────

def _app_dirs():
    dirs = [HOME / ".local/share/applications"]
    for d in os.environ.get("XDG_DATA_DIRS", "/usr/local/share:/usr/share").split(":"):
        dirs.append(Path(d) / "applications")
    dirs.append(Path("/var/lib/flatpak/exports/share/applications"))
    return dirs


_ENTRIES = None


def entries():
    """Visible desktop entries; a user copy in ~/.local/share wins (that is how
    prime-run launchers are made, per the map's Hybrid graphics section)."""
    global _ENTRIES
    if _ENTRIES is not None:
        return _ENTRIES
    seen, out = set(), []
    for d in _app_dirs():
        for f in sorted(d.glob("*.desktop")) if d.is_dir() else []:
            if f.name in seen:
                continue
            seen.add(f.name)
            e, sect = {"id": f.stem, "path": str(f)}, None
            try:
                for line in f.read_text(errors="replace").splitlines():
                    if line.startswith("["):
                        sect = line.strip()
                    elif sect == "[Desktop Entry]" and "=" in line:
                        k, v = line.split("=", 1)
                        if k in ("Name", "GenericName", "Exec", "StartupWMClass", "NoDisplay",
                                 "Hidden", "Categories", "Keywords", "Terminal"):
                            e.setdefault(k, v.strip())
            except OSError:
                continue
            if e.get("NoDisplay") == "true" or e.get("Hidden") == "true" or "Exec" not in e:
                continue
            out.append(e)
    _ENTRIES = out
    return out


def entry_cmd(e, files=()):
    """Exec line with field codes resolved. %f/%u get the file(s), the rest go."""
    argv = []
    for tok in shlex.split(e["Exec"]):
        if tok in ("%f", "%u", "%F", "%U"):
            argv += list(files)
        elif re.fullmatch(r"%[a-zA-Z]", tok):
            continue
        else:
            argv.append(tok.replace("%%", "%"))
    if files and not any(f in argv for f in files):
        argv += list(files)
    return argv


def find_entry(name):
    """-> (entry, alternatives). Roles resolve through the user's own defaults."""
    n = norm(name)
    role = {"terminal": "DEFAULT_TERMINAL", "term": "DEFAULT_TERMINAL", "browser": "DEFAULT_BROWSER",
            "webbrowser": "DEFAULT_BROWSER", "editor": "DEFAULT_EDITOR", "texteditor": "DEFAULT_EDITOR"}.get(n)
    if role:
        name = os.path.basename(pref(role)) or name
    if n in ("files", "filemanager", "filesapp", "explorer"):
        default = sh(["xdg-mime", "query", "default", "inode/directory"]).strip()
        for e in entries():
            if e["id"] + ".desktop" == default:
                return e, []
    scored = []
    for e in entries():
        s = max(similar(name, e.get("Name", "")), similar(name, e["id"]),
                similar(name, e["id"].split(".")[-1]),
                similar(name, e.get("StartupWMClass", "")),
                similar(name, exec_name(e)),
                0.85 if n and n in norm(e.get("Keywords", "")) else 0)
        if s >= 0.75:
            scored.append((s, e))
    scored.sort(key=lambda t: -t[0])
    if not scored:
        return None, []
    best = scored[0]
    alts = [e for s, e in scored[1:5] if s >= best[0] - 0.05]
    return best[1], alts


def entry_class_names(e):
    names = {e["id"], e["id"].split(".")[-1], e.get("StartupWMClass", ""), e.get("Name", ""), exec_name(e)}
    return {norm(x) for x in names if x}


def is_web_app(e):
    """A site wrapped as an app: `chromium --app=https://…` (the web apps in
    ~/.local/share/applications), or a browser's own PWA launcher."""
    return bool(re.search(r"(^|\s)--app(=|\s)|--app-id=", e.get("Exec") or ""))


def exec_name(e):
    """The binary an entry runs, as a name it may be asked for by — except a
    web app's, which is the BROWSER's. Measured 2026-11-10: "open chromium"
    reached open_app("chromium"), and every web app here (ChatGPT, WhatsApp,
    X…) runs `chromium --app=…`, so each scored 1.0 against "chromium", tied
    with chromium.desktop itself, and the user entries sort first: EVE said
    "Opened ChatGPT". The same name in entry_class_names made a plain Chromium
    window count as "WhatsApp is already open"."""
    if not e.get("Exec") or is_web_app(e):
        return ""
    try:
        return os.path.basename(shlex.split(e["Exec"])[0])
    except ValueError:
        return ""


# ── windows ──────────────────────────────────────────────────────────────────

def clients():
    return [c for c in (hj("clients") or []) if c.get("mapped", True)]


_CLASS_NAME = None


def label(c):
    """What to call a window in a message: its app's Name, else its class.
    The class->Name map is built once: rebuilt per window it cost 324 ms of a
    ~1 s request (measured 2026-10-06, 12 windows x ~200 desktop entries)."""
    global _CLASS_NAME
    if _CLASS_NAME is None:
        _CLASS_NAME = {}
        for e in reversed(entries()):          # earlier dirs win, so they go last
            for k in entry_class_names(e):
                _CLASS_NAME[k] = e.get("Name", e["id"])
    cls = norm(c.get("class", ""))
    if cls in _CLASS_NAME:
        return _CLASS_NAME[cls]
    m = re.search(r"chrome-([a-z0-9.-]+?)__", c.get("class", ""))   # webapp classes
    if m:
        return m.group(1).replace("www.", "").split(".")[0].capitalize()
    return c.get("class") or c.get("title", "window")


TERMINALS = {"kitty", "foot", "alacritty", "ghostty", "wezterm", "org.wezfurlong.wezterm", "konsole",
             "gnome-terminal-server", "xterm"}


def _descendants(pid):
    """Command names of every process under pid — what a terminal is running.
    Read straight from /proc: one pass over it is a few ms."""
    kids = {}
    for d in os.listdir("/proc"):
        if not d.isdigit():
            continue
        try:
            with open(f"/proc/{d}/stat") as f:
                st = f.read()
            ppid = int(st[st.rindex(")") + 2:].split()[1])
            kids.setdefault(ppid, []).append(int(d))
        except (OSError, ValueError):
            continue
    names, todo = set(), list(kids.get(pid, []))
    while todo:
        p = todo.pop()
        try:
            with open(f"/proc/{p}/cmdline", "rb") as f:
                argv = [a.decode(errors="replace") for a in f.read().split(b"\0") if a]
            with open(f"/proc/{p}/comm") as f:
                names.add(f.read().strip())
            if argv:
                names.add(os.path.basename(argv[0]))
        except OSError:
            pass
        todo += kids.get(p, [])
    return names


def find_windows(name):
    """Windows matching a spoken name, best first. "active" = the focused one.

    A terminal is also matched by what is RUNNING in it. "Take a screenshot of
    the claude terminal" failed on 2026-10-06 because that kitty's title is
    "archlinux: hyprahaan" — herdr sets it — so nothing in its class or title
    says claude; the program is three levels down (kitty → zsh → herdr →
    claude). Weighted under a class match, so "kitty" still means kitty."""
    if norm(name) in ("active", "this", "current", "focused", "it"):
        a = hj("activewindow")
        return [a] if a and a.get("address") else []
    out = []
    for c in clients():
        title_words = re.findall(r"[a-z0-9]+", c.get("title", "").lower())
        s = max([similar(name, c.get("class", "")), similar(name, c.get("initialClass", "")),
                 similar(name, label(c)), 0.85 if norm(name) in norm(c.get("title", "")) else 0]
                + [similar(name, w) * 0.95 for w in title_words if len(w) > 2])
        if s < 0.75 and norm(c.get("class", "")) in {norm(t) for t in TERMINALS} and c.get("pid"):
            running = _descendants(c["pid"]) - {"zsh", "bash", "fish", "sh", "kitten", "herdr", "tmux", "zellij"}
            s = max([0] + [similar(name, r) * 0.88 for r in running])
        if s >= 0.75:
            out.append((s, c))
    out.sort(key=lambda t: (-t[0], t[1].get("focusHistoryID", 99)))
    return [c for _, c in out]


STOP = {"take", "screenshot", "screen", "shot", "window", "terminal", "the", "this", "that", "copy", "text",
        "record", "with", "sound", "audio", "move", "focus", "close", "open", "full", "just", "save", "and",
        "then", "into", "onto", "from", "please", "workspace", "kitty"}


def refine_match(match, said):
    """A window the model named generically, sharpened by what was said.
    "take a screenshot of clade terminal" came back as match "kitty" (dev eval,
    2026-10-06) — any kitty, not the one running Claude. If the model's match
    is a terminal class and a word the user said names a program running in
    one of the terminals, that word is the better match."""
    if not said or not match or norm(match) not in {norm(t) for t in TERMINALS} | {"terminal"}:
        return match
    for w in re.findall(r"[a-z0-9]+", said.lower()):
        if len(w) < 4 or w in STOP:
            continue
        hits = [c for c in clients() if norm(c.get("class", "")) in {norm(t) for t in TERMINALS} and c.get("pid")
                and any(similar(w, r) >= 0.75 for r in _descendants(c["pid"]))]
        if hits:
            return w
    return match


def visible_workspaces():
    vis = set()
    for m in hj("monitors") or []:
        vis.add(m["activeWorkspace"]["id"])
        if m.get("specialWorkspace", {}).get("id"):
            vis.add(m["specialWorkspace"]["id"])
    return vis


def _shown_specials():
    return {m["specialWorkspace"]["name"] for m in hj("monitors") or [] if m.get("specialWorkspace", {}).get("id")}


def bring_into_view(c):
    """Make a window visible AND on top, so a screen-rectangle capture of it is
    really it. Returns a function that puts back exactly what was there.

    On top matters as much as visible: the first live test screenshotted
    "Spotify" on the scratchpad and got ChatGPT, because every window there
    floats and ChatGPT was stacked over it — grim captures a rectangle of the
    screen, not a window. So the target is focused and raised first."""
    before_ws = (hj("activeworkspace") or {}).get("id")
    before_win = (hj("activewindow") or {}).get("address")
    specials_before = _shown_specials()
    wid, wname = c["workspace"]["id"], c["workspace"]["name"]
    switched = wid not in visible_workspaces()
    if switched and wname.startswith("special:"):
        dispatch(f"hl.dsp.workspace.toggle_special({lua(wname.split(':', 1)[1])})")
    elif switched:
        dispatch(f"hl.dsp.focus({{ workspace = {wid} }})")
    if c["address"] != before_win:
        dispatch(f"hl.dsp.focus({{ window = 'address:{c['address']}' }})")
        dispatch("hl.dsp.window.bring_to_top()")
    # A workspace switch has to finish animating before grim, or the capture is
    # the slide (workspaces run at spd(2), specials at spd(6) in hyprland.lua).
    # A raise on the visible workspace only needs a frame or two.
    time.sleep(0.7 if switched else 0.12)

    def restore():
        if before_win and before_win != c["address"] and any(x["address"] == before_win for x in clients()):
            dispatch(f"hl.dsp.focus({{ window = 'address:{before_win}' }})")
        for name in _shown_specials() - specials_before:
            dispatch(f"hl.dsp.workspace.toggle_special({lua(name.split(':', 1)[1])})")
        if before_ws and (hj("activeworkspace") or {}).get("id") != before_ws:
            dispatch(f"hl.dsp.focus({{ workspace = {before_ws} }})")
    return restore


def geom(c):
    """slurp-format "X,Y WxH", LOGICAL — what grim -g, gsr -w and ocr all take."""
    c = next((x for x in clients() if x["address"] == c["address"]), c)   # fresh position
    (x, y), (w, h) = c["at"], c["size"]
    return f"{x},{y} {w}x{h}"


def monitor_geom():
    m = next((m for m in hj("monitors") or [] if m.get("focused")), None)
    if not m:
        return None, None
    s = m.get("scale", 1) or 1
    return m["name"], f"{m['x']},{m['y']} {round(m['width'] / s)}x{round(m['height'] / s)}"


def wins_msg(ws):
    return "here" if ws is None else f"on workspace {ws}"


# ── capture ──────────────────────────────────────────────────────────────────

def _target_geom(target, match, dry, keep_view=False):
    """-> (geometry|None, what, undo, error)."""
    noop = lambda: None
    if target == "region":
        if dry:
            return "<slurp selection>", "the selected area", noop, None
        g = sh(["slurp", "-d"], timeout=60).strip()
        return (g or None), "the selected area", noop, (None if g else "cancelled")
    if target == "full":
        _, g = monitor_geom()
        return g, "the screen", noop, None
    match = refine_match(match, _SAID[0])
    ws = find_windows(match) if match else find_windows("active")
    if not ws:
        return None, None, noop, f"no open window matches “{match}”"
    c = ws[0]
    what = f"{label(c)}" + (f" ({c['title'][:40]})" if c.get("title") and norm(label(c)) not in norm(c["title"]) else "")
    if dry:
        return geom(c), what, noop, None
    undo = bring_into_view(c)
    return geom(c), what, (noop if keep_view else undo), None


def screenshot(a, dry):
    target, dest = a["target"], a.get("dest", "both")
    if a.get("delay") and not dry:
        time.sleep(min(a["delay"], 30))
    g, what, undo, err = _target_geom(target, a.get("match"), dry)
    if err:
        return Result("done" if err == "cancelled" else "error", "Screenshot cancelled" if err == "cancelled" else err)
    path = SHOTS / time.strftime("%Y-%m-%d-%H%M%S_jarvis.png")
    if dry:
        return Result("done", f"[dry] grim -g '{g}' → {dest} ({path if dest != 'clipboard' else 'clipboard'}) — {what}")
    try:
        png = subprocess.run(["grim", "-g", g, "-"], capture_output=True, timeout=10).stdout
    finally:
        undo()
    if not png:
        return Result("error", "Screenshot failed (grim returned nothing)")
    where = []
    if dest in ("file", "both"):
        SHOTS.mkdir(parents=True, exist_ok=True)
        path.write_bytes(png)
        where.append(f"saved to {path.relative_to(HOME)}")
    if dest in ("clipboard", "both"):
        # wl-copy forks to serve the selection; detached so it outlives us.
        p = subprocess.Popen(["wl-copy", "--type", "image/png"], stdin=subprocess.PIPE,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        p.communicate(png, timeout=5)
        where.insert(0, "copied to clipboard")
    return Result("done", f"Screenshot of {what} " + " and ".join(where), path=str(path) if dest != "clipboard" else None)


def ocr(a, dry):
    g, what, undo, err = _target_geom(a["target"], a.get("match"), dry)
    if err:
        return Result("done" if err == "cancelled" else "error", "OCR cancelled" if err == "cancelled" else err)
    argv = [script("ocr-region.sh"), "--geometry", g, "--stdout"]
    if dry:
        return Result("done", f"[dry] {shlex.join(argv)} — {what}")
    try:
        text = sh(argv, timeout=30)
    finally:
        undo()
    text = text.strip()
    if not text:
        return Result("done", f"No text found in {what}")
    return Result("text", f"Text from {what} copied to clipboard", body=text)


def record_start(a, dry):
    target = a["target"]
    argv = [script("screenrecord.sh"), "start", f"--target={target}", f"--audio={a.get('audio', 'none')}"]
    what = "the screen"
    if target == "window":
        g, what, _, err = _target_geom("window", a.get("match"), dry, keep_view=True)
        if err:
            return Result("error", err)
        argv.append(f"--geometry={g}")
    secs = a.get("seconds")
    if dry:
        return Result("done", f"[dry] {shlex.join(argv)}" + (f"; stop after {secs}s" if secs else ""))
    if "recording" in sh([script("screenrecord.sh"), "status"]):
        return Result("error", "Already recording — say “stop recording” first")
    if secs:
        # start; sleep; stop — one detached chain, so the clock starts when
        # `start` RETURNS, which screenrecord.sh only does once gsr has opened
        # its output file. Two earlier versions undercut it: a timer from spawn
        # gave a 2.3 s file for "5 seconds", and one keyed on `status` gave
        # 2.6 s, because status means "the process exists", which is true
        # seconds before the first frame (measured 2026-10-06).
        spawn(["sh", "-c", f"{shlex.join(argv)} && sleep {int(secs)} && "
                           f"exec {shlex.quote(script('screenrecord.sh'))} stop"])
    else:
        spawn(argv)
    audio = {"none": "", "desktop": " with system sound", "both": " with mic and system sound"}[a.get("audio", "none")]
    return Result("done", f"Recording {what}{audio}" + (f" for {secs}s" if secs else ""))


def record_stop(a, dry):
    if dry:
        return Result("done", f"[dry] {script('screenrecord.sh')} stop")
    spawn([script("screenrecord.sh"), "stop"])
    return Result("done", "Recording stopped and saved to Videos/Screencasts")


# ── apps & windows ───────────────────────────────────────────────────────────

ROLES = {"terminal", "term", "browser", "webbrowser", "files", "filemanager", "editor"}


def literal_app(model_app, said):
    """The app the user literally named, when the model swapped it for a
    look-alike. Measured 2026-10-06: "open spotifast" planned
    open_app("spotify") — the prompt's own rule says to fix typos like
    spotfy -> spotify, and the model has no list of what is installed, so a
    real app one letter-cluster away from a famous one gets "corrected".
    So: if a word (or two) of what was actually typed is an installed app's
    exact name, and the model's choice is merely similar to it, the user's
    word wins."""
    if not said:
        return model_app
    words = re.findall(r"[a-z0-9.+-]+", said.lower())
    grams = words + [a + b for a, b in zip(words, words[1:])]
    for g in grams:
        if norm(g) == norm(model_app) or len(norm(g)) < 4:
            continue
        for e in entries():
            names = {norm(e.get("Name", "")), norm(e["id"]), norm(e["id"].split(".")[-1])}
            # Similar names (spotify for spotifast), or a bare ROLE where the
            # user named an actual app: "launch obsidian right here" came back
            # as open_app("editor"), which resolves to nvim (held-out eval,
            # 2026-10-06).
            if norm(g) in names and (similar(g, model_app) >= 0.6 or norm(model_app) in ROLES):
                return g
    return model_app


def open_app(a, dry):
    a = dict(a, app=literal_app(a["app"], a.get("_said", "")))
    e, alts = find_entry(a["app"])
    if not e:
        return Result("error", f"I couldn't find an app called “{a['app']}”")
    ws, name = a.get("workspace"), e.get("Name", e["id"])
    # A named single app that is already open is brought to you, not launched
    # twice. Roles (a terminal, a browser) always mean a NEW one.
    if norm(a["app"]) not in ROLES and not a.get("dir"):
        cls = entry_class_names(e)
        running = [c for c in clients() if norm(c.get("class", "")) in cls or norm(c.get("initialClass", "")) in cls]
        if running:
            c = running[0]
            if dry:
                return Result("done", f"[dry] {name} is open ({c['address']}) → " + (f"move to {ws}" if ws else "focus"))
            if ws:
                dispatch(f"hl.dsp.window.move({{ workspace = {ws}, window = 'address:{c['address']}', follow = false }})")
                return Result("done", f"{name} was already open — moved it to workspace {ws}")
            raise_window(c)
            return Result("done", f"{name} was already open — switched to it")
    argv = entry_cmd(e)
    where = ""
    if a.get("dir"):
        d = resolve_dir(a["dir"])
        if not d:
            return Result("error", f"I couldn't find a folder called “{a['dir']}”")
        exe = os.path.basename(argv[0]) if argv else ""
        # The terminals' own flags for a starting directory; a file manager
        # simply takes the folder as its argument.
        flag = {"kitty": ["--directory"], "foot": ["--working-directory"], "alacritty": ["--working-directory"],
                "ghostty": ["--working-directory"], "wezterm": ["start", "--cwd"]}.get(exe)
        if flag:
            argv = [argv[0]] + flag + [str(d)] + argv[1:]
        elif "FileManager" in e.get("Categories", "") or exe in ("nautilus", "dolphin", "thunar", "nemo"):
            argv = [argv[0], str(d)]
        else:
            return Result("error", f"I can only open a terminal or the file manager in a folder")
        where = f" in ~/{d.relative_to(HOME)}" if d != HOME else " in ~"
    cmd = shlex.join(argv)
    if e.get("Terminal") == "true":
        cmd = f"{shlex.quote(pref('DEFAULT_TERMINAL') or 'kitty')} -e {cmd}"
    if dry:
        return Result("done", f"[dry] exec {cmd} {wins_msg(ws)}" + (f" (also matched: {', '.join(x.get('Name', x['id']) for x in alts)})" if alts else ""))
    exec_cmd(cmd, ws)
    return Result("done", f"Opened {name}{where}" + (f" on workspace {ws}" if ws else "") if where
                  else f"Opened {name} {wins_msg(ws)}")


def close_app(a, dry, confirmed=False):
    app, ws = a["app"], a.get("workspace")
    # "close all windows on 4" came back as app "active", all, workspace 4 on
    # the held-out eval. With all + a workspace, a non-app word means "every
    # window there" — still behind the confirm below, being more than one.
    if norm(app) in ("", "all", "everything", "windows", "window") or app == "*" or \
            (a.get("all") and ws and norm(app) in ("active", "this", "current", "focused")):
        targets = [c for c in clients() if ws is None or c["workspace"]["id"] == ws]
    else:
        found = find_windows(app)
        if ws:
            found = [c for c in found if c["workspace"]["id"] == ws]
        targets = found if a.get("all") else found[:1]
    if not targets:
        if app == "*" or norm(app) in ("", "all", "everything", "windows", "window", "active", "this", "current", "focused"):
            return Result("done", f"Nothing open on workspace {ws}" if ws else "Nothing to close")
        return Result("error", f"No open window matches “{app}”" + (f" on workspace {ws}" if ws else ""))
    names = sorted({label(c) for c in targets})
    what = (f"{len(targets)} windows" if len(targets) > 1 else label(targets[0])) + (f" on workspace {ws}" if ws else "")
    if dry:
        return Result("done", f"[dry] close {what}: " + ", ".join(c["address"] for c in targets))
    # More than one window is never closed without a yes. Measured why on the
    # held-out eval: "delete every screenshot" came back as close_app("*").
    if len(targets) > 1 and not confirmed:
        return park("confirm", f"Close {what}? ({', '.join(names)})",
                    {"tool": "close_app", "args": a}, options=[f"{label(c)} — {c['title'][:50]}" for c in targets])
    for c in targets:
        dispatch(f"hl.dsp.window.close({{ window = 'address:{c['address']}' }})")
    return Result("done", f"Closed {what}")


def raise_window(c):
    """Go to a window AND put it on top. Ahaan, 2026-10-06: "going to an app
    that is under another app does not bring it to top" — focus alone moves
    the keyboard to a floating window but leaves it stacked under the one
    covering it. bring_to_top acts on the focused window, so it goes second;
    it is the same pair bring_into_view uses before a screenshot.

    The same sequence the dock (DockIcon.qml) and Alt-Tab (AppSwitcher.qml)
    already run, so all three agree: a window on a special workspace is
    first brought onto the current one (e+0); any other, its workspace is
    shown first."""
    addr = f"address:{c['address']}"
    if c["workspace"]["name"].startswith("special"):
        dispatch(f"hl.dsp.window.move({{ workspace = 'e+0', window = '{addr}' }})")
    else:
        dispatch(f"hl.dsp.focus({{ workspace = {c['workspace']['id']} }})")
    dispatch(f"hl.dsp.focus({{ window = '{addr}' }})")
    dispatch("hl.dsp.window.bring_to_top()")


def window(a, dry):
    found = find_windows(refine_match(a["app"], _SAID[0]))
    if not found:
        return Result("error", f"No open window matches “{a['app']}”")
    c, act, ws = found[0], a["action"], a.get("workspace")
    w = f"window = 'address:{c['address']}'"
    if act == "focus" and not dry:
        raise_window(c)
        return Result("done", f"Switched to {label(c)}")
    exprs = {"focus": f"hl.dsp.focus({{ {w} }})",
             "move": f"hl.dsp.window.move({{ workspace = {ws}, {w}, follow = false }})" if ws else None,
             "fullscreen": f"hl.dsp.window.fullscreen({{ {w} }})",
             "float": f"hl.dsp.window.float({{ action = 'toggle', {w} }})"}
    if not exprs[act]:
        return Result("error", "Move it where? Say a workspace number")
    if dry:
        return Result("done", f"[dry] {exprs[act]}  ({label(c)})")
    dispatch(exprs[act])
    return Result("done", {"focus": f"Switched to {label(c)}", "move": f"Moved {label(c)} to workspace {ws}",
                           "fullscreen": f"Toggled fullscreen on {label(c)}",
                           "float": f"Toggled floating on {label(c)}"}[act])


def workspace(a, dry):
    if dry:
        return Result("done", f"[dry] focus workspace {a['n']}")
    dispatch(f"hl.dsp.focus({{ workspace = {a['n']} }})")
    return Result("done", f"Workspace {a['n']}")


# ── web ──────────────────────────────────────────────────────────────────────

UA = {"User-Agent": "Mozilla/5.0 (X11; Linux x86_64; rv:130.0) Gecko/20100101 Firefox/130.0"}

SITES = {
    "youtube": "https://www.youtube.com/results?search_query={q}",
    "amazon": "https://www.amazon.in/s?k={q}",
    "github": "https://github.com/search?q={q}&type=repositories",
    "reddit": "https://www.reddit.com/search/?q={q}",
    "wikipedia": "https://en.wikipedia.org/w/index.php?search={q}",
    "spotify": "https://open.spotify.com/search/{q}",
    "maps": "https://www.google.com/maps/search/{q}",
    "google": "https://www.google.com/search?q={q}",
}


def browsers():
    """name -> command, from ui-prefs.sh (the settings menu's browser list).
    Cached: the listing costs ~307 ms, which was 93% of building the model's
    context (measured 2026-10-06). It only changes when a browser is installed
    or removed, i.e. when an applications directory changes — so that, and
    nothing else, invalidates it."""
    cache = RUN / "browsers.json"
    newest = max((d.stat().st_mtime for d in _app_dirs() if d.is_dir()), default=0)
    try:
        if cache.stat().st_mtime > newest:
            return json.loads(cache.read_text())
    except (OSError, ValueError):
        pass
    out = {}
    for line in sh([script("ui-prefs.sh"), "list", "browsers"]).splitlines():
        parts = line.split("\t")
        if len(parts) >= 2 and parts[0]:
            out[parts[1]] = parts[0]
    if out:
        RUN.mkdir(parents=True, exist_ok=True)
        cache.write_text(json.dumps(out))
    return out


def open_url(a, dry):
    q, site, url = a.get("query"), a.get("site"), a.get("url")
    if url:
        url = url.strip()
        if not re.match(r"^[a-z]+://", url):
            url = "https://" + (url if "." in url else url + ".com")
    elif site and not q:
        url = "https://" + (site if "." in site else site + ".com")
    elif a.get("images"):
        url = "https://www.google.com/search?tbm=isch&q=" + urllib.parse.quote_plus(q or "")
    elif site:
        tmpl = SITES.get(norm(site)) or ("https://www.google.com/search?q=site%3A" + urllib.parse.quote(site) + "+{q}")
        url = tmpl.format(q=urllib.parse.quote_plus(q or ""))
    elif q:
        url = "https://www.google.com/search?q=" + urllib.parse.quote_plus(q)
    else:
        return Result("error", "Open what?")
    bmap, cmd, bname = browsers(), pref("DEFAULT_BROWSER"), "browser"
    if a.get("browser"):
        best = max(bmap, key=lambda n: similar(a["browser"], n), default=None)
        if not best or similar(a["browser"], best) < 0.7:
            return Result("error", f"I don't know a browser called “{a['browser']}”")
        cmd, bname = bmap[best], best
    else:
        bname = next((n for n, c in bmap.items() if c == cmd), "browser")
    ws = a.get("workspace")
    # A browser that is already running opens a TAB in its existing window,
    # which no workspace rule can place — so a workspace asks for a new window.
    line = shlex.join([cmd] + (["--new-window"] if ws else []) + [url])
    if dry:
        return Result("done", f"[dry] exec {line} {wins_msg(ws)}")
    exec_cmd(line, ws)
    return Result("done", f"Opened {urllib.parse.urlsplit(url).netloc.replace('www.', '')} in {bname}" + (f" on workspace {ws}" if ws else ""))


class _DDG(HTMLParser):
    def __init__(self):
        super().__init__()
        self.results, self._cur, self._in = [], None, None

    def handle_starttag(self, tag, attrs):
        cls = dict(attrs).get("class", "")
        if tag == "a" and "result__a" in cls:
            href = dict(attrs).get("href", "")
            u = urllib.parse.parse_qs(urllib.parse.urlsplit(href).query).get("uddg", [href])[0]
            self._cur = {"title": "", "url": u, "snippet": ""}
            self.results.append(self._cur)
            self._in = "title"
        elif tag in ("a", "div") and "result__snippet" in cls and self._cur:
            self._in = "snippet"

    def handle_endtag(self, tag):
        if tag in ("a", "div"):
            self._in = None

    def handle_data(self, data):
        if self._in and self._cur:
            self._cur[self._in] += data


def fetch(url, timeout=6):
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=timeout) as r:
        return r.read().decode("utf-8", errors="replace")


def _weather(q):
    """wttr.in's answer for a weather question, or [] if it is not one."""
    m = re.search(r"weather\b(?:\s+(?:in|at|for))?\s*([a-z .'-]*?)\s*(today|tomorrow|tonight|this week)?$", q, re.I) \
        or re.search(r"^([a-z .'-]+?)\s+weather\s*(today|tomorrow|tonight)?$", q, re.I)
    if not m:
        return []
    out = []
    try:
        place = (m.group(1) or "").strip()
        # JSON, and a non-browser UA: wttr.in serves its HTML page to anything
        # that looks like a browser (measured: the first version got back
        # "<!DOCTYPE html>").
        req = urllib.request.Request(f"https://wttr.in/{urllib.parse.quote(place)}?format=j1",
                                     headers={"User-Agent": "curl/8"})
        with urllib.request.urlopen(req, timeout=6) as r:
            w = json.load(r)
        # The place as asked: wttr names its nearest weather station
        # ("whats the weather in mumbai" came back as "Ballard Estate").
        cur = w["current_condition"][0]
        area = place.title() or w["nearest_area"][0]["areaName"][0]["value"]
        out.append(f"{area} now: {cur['temp_C']}°C, {cur['weatherDesc'][0]['value'].strip()}, "
                   f"feels {cur['FeelsLikeC']}°C, humidity {cur['humidity']}%")
        for label_, day in (("Today", w["weather"][0]), ("Tomorrow", w["weather"][1])):
            rain = max(int(h.get("chanceofrain", 0)) for h in day["hourly"])
            desc = day["hourly"][4]["weatherDesc"][0]["value"].strip()      # midday
            out.append(f"{label_}: {day['mintempC']}–{day['maxtempC']}°C, {desc}, rain chance {rain}%")
    except (OSError, ValueError, KeyError, IndexError):
        pass
    return out


def _instant(q):
    try:
        ia = json.loads(fetch("https://api.duckduckgo.com/?format=json&no_html=1&skip_disambig=1&q=" + urllib.parse.quote_plus(q)))
    except (OSError, ValueError):
        return []
    out = []
    if ia.get("Answer"):
        out.append(str(ia["Answer"]))
    if ia.get("AbstractText"):
        out.append(f"{ia['AbstractText']}\n— {ia.get('AbstractSource', '')}")
    return out


class _Blocked(Exception):
    """DuckDuckGo answered with its bot challenge instead of results."""


def _lite(html_text):
    """lite.duckduckgo.com: result-link anchors, result-snippet cells."""
    out = []
    links = re.findall(r"<a[^>]*href=\"([^\"]+)\"[^>]*class=['\"]result-link['\"][^>]*>(.*?)</a>", html_text, re.S)
    snips = re.findall(r"class=['\"]result-snippet['\"][^>]*>(.*?)</td>", html_text, re.S)
    clean = lambda t: re.sub(r"\s+", " ", re.sub(r"<[^>]+>", "", __import__("html").unescape(t))).strip()
    for i, (u, t) in enumerate(links[:6]):
        u = urllib.parse.parse_qs(urllib.parse.urlsplit(u).query).get("uddg", [u])[0]
        out.append(_src(clean(t), clean(snips[i]) if i < len(snips) else "", u))
    return out


def _src(title, snippet, url):
    site = urllib.parse.urlsplit(url).netloc.replace("www.", "")
    return {"title": title.strip(), "snippet": snippet.strip(), "url": url, "site": site}


def _results(q):
    """Web results, or _Blocked. Measured 2026-10-06: after a day of testing
    from this IP, DuckDuckGo started answering both its html and lite
    endpoints with a "bots use DuckDuckGo too — select all squares containing
    a duck" page, intermittently. The html parser read that as zero results
    and the card said "Nothing found", which is a lie. So the challenge is
    detected by name, the lite endpoint is tried once, and a block is
    reported as a block."""
    page = fetch("https://html.duckduckgo.com/html/?q=" + urllib.parse.quote_plus(q))
    if "bots use DuckDuckGo" not in page:
        p = _DDG()
        p.feed(page)
        rs = [_src(r["title"], r["snippet"], r["url"])
              for r in p.results if "duckduckgo.com/y.js" not in r["url"]][:6]
        if rs:
            return rs
    page = fetch("https://lite.duckduckgo.com/lite/?q=" + urllib.parse.quote_plus(q))
    if "bots use DuckDuckGo" in page:
        raise _Blocked()
    return _lite(page)


def web_search(a, dry):
    q = a["query"].strip()
    if dry:
        return Result("done", f"[dry] DuckDuckGo: {q}")
    # The three sources are independent, so they are fetched at once. In
    # sequence a weather question took 17 s end to end on 2026-10-06 — each
    # fetch was 1-3 s from Python that morning, against <1 s from curl — and
    # the user waits for the sum. In parallel they wait for the slowest.
    from concurrent.futures import ThreadPoolExecutor
    with ThreadPoolExecutor(max_workers=3) as ex:
        fw, fi, fr = ex.submit(_weather, q), ex.submit(_instant, q), ex.submit(_results, q)
        facts = fw.result() + fi.result()
        try:
            sources = fr.result()
        except _Blocked:
            sources = []
            if not facts:
                r = open_url({"query": q}, False)
                return Result("done", "DuckDuckGo is asking for a captcha — " + r["msg"][0].lower() + r["msg"][1:])
        except OSError as e:
            sources = []
            if not facts:
                return Result("error", f"Search failed: {e}")
    if not facts and not sources:
        return Result("done", f"Nothing found for “{q}”")
    # The answer, written from the results only; the sources stay underneath
    # so it can be checked. If the model is unreachable the card still has
    # the sources — a summary is a convenience, never the only way to read.
    try:
        import brain
        answer = brain.summarize(q, sources[:5], facts)
    except Exception:
        answer = "\n".join(facts) if facts else ""
    return Result("answer", q, answer=answer, sources=sources[:5], facts=facts, browse=q)


# ── media, volume, brightness, settings ──────────────────────────────────────

def media(a, dry):
    act = {"toggle": "play-pause"}.get(a["action"], a["action"])
    if dry:
        return Result("done", f"[dry] playerctl {act}")
    if not ok(["playerctl", act]):
        return Result("error", "Nothing is playing")
    time.sleep(0.3)
    now = sh(["playerctl", "metadata", "--format", "{{title}} — {{artist}}"]).strip()
    verb = {"play": "Playing", "pause": "Paused", "play-pause": "Toggled", "next": "Next", "previous": "Previous"}[act]
    return Result("done", f"{verb}" + (f": {now}" if now and act != "pause" else ""))


def _spotify_up():
    """Spotify's MPRIS name, starting the app if it is not running. The
    official client is the one with OpenUri (SupportedUriSchemes ['spotify'],
    introspected 2026-10-06); Spotifast is a separate client with no such
    interface here, so a song always goes to Spotify."""
    def present():
        return "spotify" in sh(["playerctl", "-l"]).split()
    if present():
        return True
    exec_cmd("spotify", None)
    for _ in range(60):                       # cold start measured in seconds
        time.sleep(0.25)
        if present():
            time.sleep(1.0)                   # MPRIS appears before playback is ready
            return True
    return False


def _track_id(q):
    """The first Spotify track for a song name, from a DuckDuckGo search of
    open.spotify.com/track pages — no API key needed. Measured: 0.7 s for
    "blinding lights the weeknd". Raises _Blocked on DDG's bot check."""
    qq = urllib.parse.quote_plus(f"site:open.spotify.com/track {q}")
    blocked = True
    # Both endpoints, as _results does: the bot check comes and goes, and on
    # 2026-10-06 the html one blocked while lite still answered.
    for url in ("https://html.duckduckgo.com/html/?q=" + qq, "https://lite.duckduckgo.com/lite/?q=" + qq):
        # 3 s, not fetch's 6: a hung endpoint cost a 10.3 s wait before the
        # fallback on 2026-10-06, and the fallback is fine to land on.
        try:
            page = fetch(url, timeout=3)
        except OSError:
            continue
        if "bots use DuckDuckGo" in page:
            continue
        blocked = False
        ids = re.findall(r"open\.spotify\.com(?:%2F|/)track(?:%2F|/)([A-Za-z0-9]{22})", page)
        if ids:
            return ids[0]
    if blocked:
        raise _Blocked()
    return None


def play_song(a, dry):
    """Ahaan, 2026-10-06: "I wanna be able to ask to play a specific song in
    spotify." Find the track, hand it to Spotify over MPRIS (playerctl open
    spotify:track:ID starts it playing), then say what is ACTUALLY playing,
    read back from the player — not what was asked for. If the lookup is
    blocked or finds nothing, Spotify's own search opens instead: the
    browser-fallback rule, applied to music."""
    q = (a.get("song") or "").strip()
    if a.get("artist"):
        q = f"{q} {a['artist'].strip()}"
    if not q:
        return Result("error", "Play which song?")
    if dry:
        return Result("done", f"[dry] spotify: {q}")
    try:
        tid = _track_id(q)
    except (_Blocked, OSError):
        tid = None
    if not _spotify_up():
        return Result("error", "Spotify didn't start")
    if not tid:
        sh(["playerctl", "-p", "spotify", "open", "spotify:search:" + urllib.parse.quote(q)])
        # The search is only useful if it can be seen: Spotify is usually on
        # the scratchpad or another workspace. Left in view — not restored —
        # because picking the track there is the next thing to do.
        ws = find_windows("spotify")
        if ws:
            bring_into_view(ws[0])
        return Result("done", f"Couldn't look it up — Spotify's search for “{q}” is open")
    sh(["playerctl", "-p", "spotify", "open", f"spotify:track:{tid}"])
    for _ in range(20):
        time.sleep(0.25)
        if tid in sh(["playerctl", "-p", "spotify", "metadata", "mpris:trackid"]):
            break
    now = sh(["playerctl", "-p", "spotify", "metadata", "--format", "{{title}} — {{artist}}"]).strip()
    return Result("done", f"Playing {now}" if now else f"Playing “{q}”")


def _step(change):
    """The model says +1 for "a bit" and +10 for "ten percent"; both are fine."""
    pct = change * 5 if abs(change) < 5 else change
    return f"{abs(pct)}%{'+' if pct > 0 else '-'}"


def volume(a, dry):
    sink = "@DEFAULT_AUDIO_SINK@"
    if "mute" in a:
        argv = ["wpctl", "set-mute", sink, "1" if a["mute"] else "0"]
    elif "level" in a:
        argv = ["wpctl", "set-volume", sink, f"{max(0, min(100, a['level']))}%"]
    elif "change" in a:
        argv = ["wpctl", "set-volume", "-l", "1.0", sink, _step(a["change"])]
    else:
        return Result("error", "Volume to what?")
    if dry:
        return Result("done", f"[dry] {shlex.join(argv)}")
    sh(argv)
    qs_ipc("osd", "volume")
    v = sh(["wpctl", "get-volume", sink]).strip()           # "Volume: 0.40 [MUTED]"
    m = re.search(r"([\d.]+)", v)
    pct = round(float(m.group(1)) * 100) if m else "?"
    return Result("done", "Muted" if "MUTED" in v else f"Volume {pct}%")


def brightness(a, dry):
    if "level" in a:
        val = f"{max(1, min(100, a['level']))}%"
    elif "change" in a:
        val = _step(a["change"])
    else:
        return Result("error", "Brightness to what?")
    if dry:
        return Result("done", f"[dry] brightnessctl set {val}")
    sh(["brightnessctl", "-q", "set", val])
    qs_ipc("osd", "brightness")
    cur, mx = sh(["brightnessctl", "get"]).strip(), sh(["brightnessctl", "max"]).strip()
    pct = round(int(cur) * 100 / int(mx)) if cur.isdigit() and mx.isdigit() and int(mx) else "?"
    return Result("done", f"Brightness {pct}%")


def _hw(key):
    p = HOME / ".config/scripts/hardware.env"
    try:
        m = re.search(rf'^{key}="?([^"\n]*)"?', p.read_text(), re.M)
        return m.group(1) if m else ""
    except OSError:
        return ""


def setting(a, dry):
    name, want = a["name"], a["state"]
    # Each probe reads the current state, so "on" when it is already on does
    # nothing — the underlying scripts only toggle.
    def nm_wifi():
        return sh(["nmcli", "radio", "wifi"]).strip() == "enabled"

    def bt():
        return "Powered: yes" in sh(["bluetoothctl", "show"])

    def awake():
        return not ok(["pgrep", "-x", "hypridle"])

    def touchpad():
        return not Path("/tmp/hypr-touchpad-disabled").exists()

    def kbd():
        d = _hw("KBD_BACKLIGHT_LED")
        return bool(d) and sh(["brightnessctl", "-d", d, "get"]).strip() not in ("", "0")

    def night():
        return "on" in sh([script("nightlight.sh"), "status"]).lower()

    table = {
        "wifi": (nm_wifi, lambda on: ["nmcli", "radio", "wifi", "on" if on else "off"], "Wi-Fi"),
        "bluetooth": (bt, lambda on: ["bluetoothctl", "power", "on" if on else "off"], "Bluetooth"),
        "nightlight": (night, lambda on: [script("nightlight.sh"), "on" if on else "off"], "Night light"),
        "awake": (awake, lambda on: [script("idle-inhibitor.sh")], "Always awake"),
        "touchpad": (touchpad, lambda on: [script("toggle-touchpad.sh")], "Touchpad"),
        "kbd_backlight": (kbd, lambda on: [script("kbdbacklight_toggle.sh")], "Keyboard light"),
    }
    if name == "dnd":
        # The bar owns DnD as a QML property with no IPC verb yet; added with
        # the UI work. Saying so beats pretending.
        return Result("error", "Do Not Disturb isn't wired to jarvis yet")
    probe, argv, pretty = table[name]
    cur = probe()
    on = (not cur) if want == "toggle" else (want == "on")
    if cur == on:
        return Result("done", f"{pretty} is already {'on' if on else 'off'}")
    if dry:
        return Result("done", f"[dry] {shlex.join(argv(on))}  ({pretty} {'on' if cur else 'off'} → {'on' if on else 'off'})")
    if name in ("awake",):
        spawn(argv(on))            # restarts hypridle, which must be detached
    else:
        sh(argv(on), timeout=10)
    return Result("done", f"{pretty} {'on' if on else 'off'}")


def power_profile(a, dry):
    p = a["profile"]
    if dry:
        return Result("done", f"[dry] power-profile.sh set {p}")
    sh([script("power-profile.sh"), "set", p])
    # An explicit choice is final: server.sh must not "restore" over it when
    # the model unloads (see server.sh, "Quiet is lifted while the model is up").
    (RUN / "profile.prev").unlink(missing_ok=True)
    return Result("done", f"Power mode: {({'power-saver': 'Quiet'}).get(p, p.capitalize())}")


def reminder(a, dry):
    mins = a.get("minutes")
    if not mins and a.get("at"):
        m = re.match(r"^(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$", a["at"].strip().lower())
        if not m:
            return Result("error", f"I didn't understand the time “{a['at']}”")
        h, mi = int(m.group(1)), int(m.group(2) or 0)
        h = h % 12 + (12 if m.group(3) == "pm" else 0) if m.group(3) else h
        now = time.localtime()
        delta = (h * 60 + mi) - (now.tm_hour * 60 + now.tm_min)
        mins = delta if delta > 0 else delta + 24 * 60
    if not mins or mins <= 0:
        return Result("error", "Remind you when?")
    when = time.strftime("%H:%M", time.localtime(time.time() + mins * 60))
    if dry:
        return Result("done", f"[dry] qs ipc call reminder add {mins} {a['text']!r}  (at {when})")
    qs_ipc("reminder", "add", str(mins), a["text"])
    return Result("done", f"I'll remind you at {when}: {a['text']}")


def wallpaper(a, dry):
    # Only when the sentence is about the wallpaper. "Show me the batmobile
    # image" was planned as wallpaper("batmobile") on 2026-10-06 and CHANGED
    # Ahaan's wallpaper — a request to look at something must never redecorate
    # the desktop. Without the word, it is a request to see the file.
    if not re.search(r"\b(wall ?papers?|background|backdrop|desktop image)\b", _SAID[0], re.I) and _SAID[0]:
        return show_file({"name": a.get("query") or "", "kind": "image", "_said": _SAID[0]}, dry)
    walls = []
    for line in sh([script("wallpapers.sh"), "list", "all"], timeout=10).splitlines():
        parts = line.split("\t")
        if parts and parts[0]:
            walls.append((parts[0], parts[1] if len(parts) > 1 else Path(parts[0]).stem))
    if not walls:
        return Result("error", "I couldn't list your wallpapers")
    if a.get("random") or not a.get("query"):
        path, name = random.choice(walls)
    else:
        scored = sorted(((similar(a["query"], n), p, n) for p, n in walls), reverse=True)
        if scored[0][0] < 0.7:
            return Result("error", f"No wallpaper matches “{a['query']}”")
        _, path, name = scored[0]
    argv = [str(LIVE_SHELL / "apply-wallpaper.sh"), path]
    if dry:
        return Result("done", f"[dry] {shlex.join(argv)}")
    spawn(argv)
    return Result("done", f"Wallpaper set to {name}")


def session(a, dry):
    lock = str(HOME / ".config/lockscreen/lockscreen-launch.sh")
    if dry:
        return Result("done", f"[dry] {lock}" + ("; systemctl suspend" if a["action"] == "suspend" else ""))
    if a["action"] == "lock":
        spawn([lock])
        return Result("done", "Locked")
    # Suspend locks FIRST, ourselves. hypridle's before_sleep_cmd normally does
    # it, but hypridle is absent whenever "always awake" is on — and a suspend
    # with nothing to lock would resume straight to an open desktop.
    if not ok(["pgrep", "-x", "hypridle"]):
        spawn([lock])
        time.sleep(1.5)
    spawn(["systemctl", "suspend"])
    return Result("done", "Suspending")


# ── files ────────────────────────────────────────────────────────────────────

def safe(p):
    """Under $HOME, no hidden component, and resolving there too (no symlink out)."""
    try:
        rp = Path(p).resolve()
        rel = Path(p).absolute().relative_to(HOME)
        rp.relative_to(HOME)
    except (ValueError, OSError):
        return False
    return not any(part.startswith(".") for part in rel.parts)


def find_folder(name):
    if not name:
        return None
    if Path(os.path.expanduser(name)).is_absolute():
        p = Path(os.path.expanduser(name))
        return p if p.is_dir() and safe(p) else None
    out = sh(["fd", "-t", "d", "-i", "--max-depth", "4", "--exclude", "node_modules",
              f"^{re.escape(name)}$", str(HOME)], timeout=4).splitlines()
    if not out:
        out = sh(["fd", "-t", "d", "-i", "--max-depth", "4", "--exclude", "node_modules",
                  re.escape(name), str(HOME)], timeout=4).splitlines()
    out = [Path(o.rstrip("/")) for o in out if safe(o.rstrip("/"))]
    return min(out, key=lambda p: len(p.parts)) if out else None


GENERIC = {"my", "the", "a", "an", "file", "files", "pdf", "doc", "docs", "document", "folder", "wallpaper",
           "wallpapers", "pic", "pics", "picture", "pictures", "photo", "photos", "image", "images", "video",
           "videos", "note", "notes", "one", "that", "this", "old", "new", "i", "took", "made", "called", "named"}


def _prefix_score(q, path):
    """Best shared-beginning match of a query word against the file name's
    words. "batman" vs "batmobile" share "batm": 4/6 = 0.67. This is the
    fallback for what fzf structurally cannot see — fzf needs every letter of
    the query in order, and batmobile has no a or n after its m."""
    words = [w for w in re.split(r"[^a-z0-9]+", path.stem.lower()) if w]
    best = 0.0
    for w in words:
        k = len(os.path.commonprefix([q, w]))
        if k >= 3:
            best = max(best, k / len(q))
        best = max(best, difflib.SequenceMatcher(None, q, w).ratio() * 0.9)
    return best


# Dependency trees are not anybody's files. Measured 2026-10-06: ~/go (the Go
# module cache) is 34k of the 46k files under home and ~/R's package library
# another 6k, and "read todo" opened a Go module's TODO.
# A pattern with a slash is anchored at fd's search root, so "pkg/mod" excluded
# nothing when searching from ~ (measured: 34,450 Go files still listed); the
# "**/" form matches at any depth. 46,566 files -> 6,003.
NOT_MINE = ["node_modules", "**/pkg/mod", "site-packages", "__pycache__", "*-library", ".venv", "venv",
            "**/target/debug", "**/target/release"]


def find_files(name=None, folder=None, kind=None, latest=False, recursive=True, limit=8):
    """-> (best matches, folder used | None, error | None, fuzzy).

    Candidates come from fd (all 46k files under home list in ~55 ms). The
    ranking is fzf's, as Ahaan asked after "remove the batman wallpaper" found
    nothing (2026-10-06) — `fzf --filter`, matching the FILE NAME only
    (--delimiter / --nth -1) so a folder called "resume-templates" cannot make
    every file in it a resume — re-scored so a name that CONTAINS the words
    beats one that merely contains their letters in order (fzf alone ranked
    adam-bateman.gif for "batman"). Shared word beginnings are the fallback for
    what fzf structurally cannot see: the file is solitude/batmobile.jpeg, and
    batmobile has no a or n after its m. Anything that is not a whole-word
    match comes back flagged fuzzy, and callers ask before acting on it."""
    root = HOME
    if folder:
        root = find_folder(folder)
        if not root:
            return [], None, f"I couldn't find a folder called “{folder}”", False
    argv = ["fd", "-t", "f", "--max-results", "80000"]
    for x in NOT_MINE:
        argv += ["--exclude", x]
    if not recursive:
        argv += ["--max-depth", "1"]
    exts = KIND_EXT.get(kind or "any")
    if exts:
        for e in exts:
            argv += ["-e", e.lstrip(".")]
    home = str(HOME) + "/"
    # fd -t f never returns a symlink and skips hidden paths itself, so being
    # under $HOME is the whole safety check here; safe() resolving every path
    # cost ~5 s over 46k files.
    paths = [p for p in sh(argv + [".", str(root)], timeout=8).splitlines() if p.startswith(home)]
    toks = [t for t in re.findall(r"[a-z0-9]+", (name or "").lower()) if t not in GENERIC]

    def mtime(p):
        try:
            return os.stat(p).st_mtime
        except OSError:
            return 0

    def stem(p):
        return os.path.splitext(os.path.basename(p))[0].lower()

    if not toks:
        paths.sort(key=mtime, reverse=True)
        return [Path(p) for p in paths[:limit]], root if folder else None, None, False

    def tok_score(t, st):
        if t in st:
            return 1.0
        best = 0.0
        for w in re.split(r"[^a-z0-9]+", st):
            if not w:
                continue
            k = len(os.path.commonprefix([t, w]))
            if k >= 3:
                best = max(best, k / len(t))
        return best

    shortlist = sh(["fzf", "--filter", " ".join(toks), "--delimiter", "/", "--nth", "-1"],
                   input="\n".join(paths), timeout=6).splitlines()[:300]
    fz = {p: i for i, p in enumerate(shortlist)}
    pool = shortlist if shortlist else paths
    scored = []
    for p in pool:
        st = stem(p)
        sc = sum(tok_score(t, st) for t in toks) / len(toks)
        if p in fz:
            sc = max(sc, 0.62) + 0.05 * (1 - fz[p] / 300)     # fzf found it: keep, mildly ranked
        if sc >= 0.6:
            scored.append((sc, p))
    if shortlist and not any(sc >= 1.0 for sc, _ in scored):
        # fzf only found letters-in-order matches; let shared beginnings
        # compete across everything before settling for them.
        for p in paths:
            if p in fz:
                continue
            sc = sum(tok_score(t, stem(p)) for t in toks) / len(toks)
            if sc >= 0.6:
                scored.append((sc, p))
    # Closest first, by how the words meet the name — Ahaan, 2026-10-06:
    # "delete hi" listed HIS_Midsem_Theory_Notes.html above hi.txt, because a
    # token found anywhere inside a name scored the same as the whole name.
    # Now: the exact name, then a whole word, then the start of a word, then
    # anywhere; ties go to the shorter name, then to the old score.
    want = norm(_strip_ext(name or ""))

    def closeness(p):
        st = stem(p)
        if norm(st) == want:
            return (0, 0, 0)
        words = [w for w in re.split(r"[^a-z0-9]+", st) if w]
        rank = 0
        for t in toks:
            rank += (1 if t in words else 2 if any(w.startswith(t) for w in words)
                     else 3 if t in st else 4)
        return (1, rank, len(st))
    scored.sort(key=lambda t: (closeness(t[1]), -t[0]))
    found = [p for _, p in scored]
    exact = [p for p in found if norm(stem(p)) == want]
    whole = scored and scored[0][0] >= 1.0
    found = exact + [p for p in found if p not in exact]
    if latest:
        found.sort(key=mtime, reverse=True)
    return [Path(p) for p in found[:limit]], root if folder else None, None, not (exact or whole)


def _strip_ext(name):
    """ "hi.txt" -> "hi": the model often passes the extension along with the
    name, and stems are compared without one."""
    b, e = os.path.splitext(name.strip())
    return b if e and 1 < len(e) <= 6 and re.fullmatch(r"\.[A-Za-z0-9]+", e) else name


def _confident(found, name):
    """One clear winner, or a list to pick from."""
    if len(found) == 1:
        return True
    n = norm(_strip_ext(name or ""))
    return bool(n) and norm(found[0].stem) == n and norm(found[1].stem) != n


# Editors that only run inside a terminal, for when DEFAULT_EDITOR names a
# binary with no desktop entry saying Terminal=true.
TERMINAL_EDITORS = {"nvim", "vim", "vi", "nano", "hx", "helix", "micro", "kak", "emacs -nw", "ne", "mcedit"}


def launch_file(p, ws=None, page=None):
    mime = sh(["xdg-mime", "query", "filetype", str(p)]).strip()
    if TEXTY.match(mime) or mime == "inode/x-empty":
        # Text always opens in the editor chosen in Settings (ui.conf's
        # DEFAULT_EDITOR), not whatever xdg-mime says — Ahaan, 2026-10-06:
        # "always use default editor which is in settings". xdg-mime said
        # vim.desktop, which is Terminal=true: it was run with no terminal,
        # vim started with nowhere to draw and exited, and EVE reported
        # "Opened in Vim" for a window that never existed.
        ed = pref("DEFAULT_EDITOR") or "nvim"
        e, _ = find_entry(os.path.basename(ed))
        if e and norm(os.path.basename(shlex.split(e["Exec"])[0])) != norm(os.path.basename(ed)):
            e = None                         # a fuzzy match to some other app
        argv = entry_cmd(e, [str(p)]) if e else shlex.split(ed) + [str(p)]
        in_term = (e.get("Terminal") == "true") if e else os.path.basename(ed) in TERMINAL_EDITORS
        name = (e.get("Name") if e else None) or os.path.basename(ed)
        cmd = shlex.join(argv)
        if in_term:
            cmd = f"{shlex.quote(pref('DEFAULT_TERMINAL') or 'kitty')} -e {cmd}"
        return cmd, name
    desk = sh(["xdg-mime", "query", "default", mime]).strip() if mime else ""
    e = next((x for x in entries() if x["id"] + ".desktop" == desk), None)
    if p.is_dir() and not e:
        e, _ = find_entry("files")
    argv = entry_cmd(e, [str(p)]) if e else ["xdg-open", str(p)]
    if page and e and "papers" in e["id"].lower():
        argv = [argv[0], f"--page-index={page}", str(p)]
    elif page and e and any(x in e["id"].lower() for x in ("evince", "okular", "zathura")):
        argv = [argv[0], f"--page={page}" if "zathura" in e["id"].lower() else f"--page-index={page}", str(p)]
    cmd = shlex.join(argv)
    if e and e.get("Terminal") == "true":       # same trap as above, any terminal app
        cmd = f"{shlex.quote(pref('DEFAULT_TERMINAL') or 'kitty')} -e {cmd}"
    return cmd, (e.get("Name") if e else "default app")


RECENCY = re.compile(r"\b(the\s+)?(last|latest|newest|most\s+recent|recent)\b", re.I)


def normalise_file_args(a):
    """What the model sometimes puts in the wrong field, put right. "open the
    last screenshot i took" came back as name "last_screenshot" with no folder
    (held-out eval, 2026-10-06): recency words are not part of a file name,
    and a screenshot with no folder lives in Screenshots."""
    a = dict(a)
    said = a.pop("_said", "") or ""
    name = (a.get("name") or "").replace("_", " ")
    # Where the user's own words name a place the model left out: "remove the
    # batman wallpaper" planned delete(name "batman", kind image) and lost the
    # one word that says where to look.
    if not a.get("folder") and re.search(r"\bwall ?papers?\b", said + " " + name, re.I):
        a["folder"] = "wallpapers"
        a.setdefault("kind", "image")
        name = re.sub(r"\bwall ?papers?\b", " ", name, flags=re.I)
    if RECENCY.search(name):
        a["latest"] = True
        name = RECENCY.sub(" ", name)
    if re.search(r"\bscreen ?shots?\b", name + " " + said, re.I) and not a.get("folder") \
            and a.get("kind") in (None, "image", "any"):
        a["folder"] = "Screenshots"
        a.setdefault("kind", "image")
        name = re.sub(r"\bscreen ?shots?\b", " ", name, flags=re.I)
    name = re.sub(r"\b(i took|i made|file|my|the)\b", " ", name, flags=re.I).strip()
    if name:
        a["name"] = name
    else:
        a.pop("name", None)
    return a


def open_file(a, dry):
    a = normalise_file_args(a)
    found, root, err, fuzzy = find_files(a.get("name"), a.get("folder"), a.get("kind"), a.get("latest"))
    if err:
        return Result("error", err)
    if not found and a.get("kind") == "folder" or (not found and not a.get("folder") and a.get("name")):
        d = find_folder(a.get("name"))
        if d:
            found = [d]
    if not found:
        return Result("error", "I couldn't find that file" + (f" in {root.relative_to(HOME)}" if root else ""))
    if fuzzy or (not a.get("latest") and not _confident(found, a.get("name"))):
        return park("pick", (f"Did you mean {'one of these' if len(found) > 1 else 'this'}?" if fuzzy
                             else f"Which one? ({len(found)} matches)"), {"tool": "open_file", "args": a},
                    options=[str(p.relative_to(HOME)) for p in found], paths=[str(p) for p in found])
    return _open_path(found[0], a, dry)


def _open_path(p, a, dry):
    cmd, app = launch_file(p, a.get("workspace"), a.get("page"))
    if dry:
        return Result("done", f"[dry] exec {cmd} {wins_msg(a.get('workspace'))}")
    exec_cmd(cmd, a.get("workspace"))
    return Result("done", f"Opened {p.name} in {app}" + (f" at page {a['page']}" if a.get("page") else "")
                  + (f" on workspace {a['workspace']}" if a.get("workspace") else ""), path=str(p))


TEXTY = re.compile(r"^(text/|application/(json|xml|x-shellscript|toml|yaml|x-yaml|javascript|x-desktop))")


def read_file(a, dry):
    # Kept for the eval's older cases and any plan that still says read_file:
    # a read is a text preview now.
    return show_file(a, dry)


def _read_path(p, a):
    if p.stat().st_size > 512 * 1024:
        return Result("error", f"{p.name} is too big to show here ({p.stat().st_size // 1024} KB)")
    lines = p.read_text(errors="replace").splitlines()
    rel = p.relative_to(HOME)
    if a.get("grep"):
        g = a["grep"].lower()
        hits = [f"{i:>4}  {l}" for i, l in enumerate(lines, 1) if g in l.lower()]
        if not hits:
            return Result("done", f"“{a['grep']}” isn't in {rel}")
        return Result("text", f"{len(hits)} line{'s' * (len(hits) != 1)} with “{a['grep']}” in {rel}",
                      body="\n".join(hits[:300]), mono=True)
    return Result("text", f"{rel}", body="\n".join(lines[:600]), mono=True)


def show_file(a, dry):
    """A preview inside the card — Ahaan (2026-10-06): "if i ask for showing me
    images, pdfs, txt files show me a preview like how it does in the
    filesearch". The same three cases FileSearch.qml previews, the same way:
    an image as itself, a PDF as its first page rendered by pdftoppm, text as
    its contents (or the lines matching grep). Opening is a button on the
    card, never a side effect of looking."""
    a = normalise_file_args(a)
    found, root, err, fuzzy = find_files(a.get("name"), a.get("folder"), a.get("kind"), a.get("latest"))
    if err:
        return Result("error", err)
    if not found:
        return Result("error", "I couldn't find that file" + (f" in {root.relative_to(HOME)}" if root else ""))
    if fuzzy or (not a.get("latest") and not _confident(found, a.get("name"))):
        return park("pick", (f"Did you mean {'one of these' if len(found) > 1 else 'this'}?" if fuzzy
                             else f"Which one? ({len(found)} matches)"), {"tool": "show_file", "args": a},
                    options=[str(p.relative_to(HOME)) for p in found], paths=[str(p) for p in found])
    return _show_path(found[0], a, dry)


def _show_path(p, a, dry):
    mime = sh(["file", "-b", "--mime-type", str(p)]).strip()
    rel = str(p.relative_to(HOME))
    if dry:
        return Result("done", f"[dry] preview {mime} {p}")
    if mime.startswith("image/"):
        return Result("preview", p.name, image=str(p), path=str(p), sub=rel)
    if mime == "application/pdf":
        # The first pages, at reading size — Ahaan: "previews like pdfs can
        # expand the island a lot more and bigger so i can actually read the
        # contents". 150 dpi is a 1240 px wide A4 page: sharp in an island
        # ~900 points wide at scale 2 without being slow (pdftoppm, 5 pages).
        RUN.mkdir(parents=True, exist_ok=True)
        for old in RUN.glob("preview-*.png"):          # one preview at a time
            old.unlink(missing_ok=True)
        stem = RUN / f"preview-{secrets.token_hex(4)}"
        sh(["pdftoppm", "-png", "-f", "1", "-l", "5", "-r", "150", str(p), str(stem)], timeout=30)
        pngs = sorted(RUN.glob(stem.name + "*.png"))
        if not pngs:
            return Result("error", f"I couldn't render {p.name}")
        m = re.search(r"Pages:\s+(\d+)", sh(["pdfinfo", str(p)]))
        total = int(m.group(1)) if m else len(pngs)
        sub = rel + f"  ·  {total} page{'s' * (total != 1)}" + (f", first {len(pngs)} shown" if total > len(pngs) else "")
        return Result("preview", p.name, pages=[str(x) for x in pngs], path=str(p), sub=sub)
    if TEXTY.match(mime) or mime == "inode/x-empty":
        r = _read_path(p, a)
        r["path"] = str(p)
        return r
    return park("offer_open", f"I can't preview {p.name} — open it?", {"tool": "open_path", "args": {"path": str(p)}})


def write_note(a, dry):
    name = re.sub(r"[/\\:*?\"<>|]+", "-", a["name"]).strip(" .-") or "note"
    if not re.search(r"\.(md|txt)$", name, re.I):
        name += ".md"
    p = NOTES / name
    stem, ext, n = p.stem, p.suffix, 2
    while p.exists():                       # NEW files only, never overwrite
        p, n = NOTES / f"{stem} ({n}){ext}", n + 1
    if dry:
        return Result("done", f"[dry] write {len(a['content'])} chars → {p}")
    NOTES.mkdir(parents=True, exist_ok=True)
    with open(p, "x") as f:                 # "x": fails rather than overwrite, even in a race
        f.write(a["content"].rstrip() + "\n")
    return Result("done", f"Saved note {p.relative_to(HOME)}", path=str(p))


def delete(a, dry):
    name, folder, kind = a.get("name"), a.get("folder"), a.get("kind", "any")
    if not name and not folder:
        return Result("error", "Delete what? Name a file or a folder")
    a = normalise_file_args(a)
    name, folder, kind = a.get("name"), a.get("folder"), a.get("kind", "any")
    fuzzy = False
    # MANY files only when the sentence says so — "delete all screenshots",
    # "every pdf in Downloads" — or names just a folder. Otherwise a name is
    # ONE file: 2026-10-06, "delete hi" came back as "Move 50 files to the
    # Trash?" with every loose match listed.
    said = _SAID[0] or a.get("_said", "")
    bulk = bool(re.search(r"\b(all|every|everything|each|both)\b", said, re.I)) or not name
    if bulk and not name and said:
        # Words the plan dropped narrow the delete, never widen it: "delete
        # all the batman wallpapers" was planned (dry run, 2026-10-06) as
        # folder=wallpapers with no name — every wallpaper. What is left of
        # the sentence once the verb, the quantifier, the folder and the kind
        # are taken out is the name.
        drop = {"delete", "remove", "trash", "bin", "get", "rid", "of", "all", "every", "everything", "each",
                "both", "the", "my", "in", "from", "inside", "under", "folder", "directory", "dir", "files",
                "file", "and", "please", "eve", "can", "you", "a", "those", "these", "them", "that", "this"}
        drop |= set(re.findall(r"[a-z0-9]+", (folder or "").lower()))
        kindw = {"image", "images", "pic", "pics", "picture", "pictures", "photo", "photos", "screenshot",
                 "screenshots", "wallpaper", "wallpapers", "video", "videos", "pdf", "pdfs", "doc", "docs",
                 "document", "documents", "song", "songs", "audio", "music", "note", "notes", "text"}
        left = [w for w in re.findall(r"[a-z0-9]+", said.lower()) if w not in drop and w not in kindw]
        if left:
            name = " ".join(left)
            a = dict(a, name=name)
    if folder and not name:
        found, root, err, _ = find_files(None, folder, kind, limit=500)
    else:
        found, root, err, fuzzy = find_files(name, folder, kind, limit=500 if bulk else 15)
    if err:
        return Result("error", err)
    if not found:
        return Result("error", "Nothing matched, so nothing to delete")
    if not bulk and (fuzzy or not _confident(found, name)):
        # Which one? Up to 15, closest first, picked with the arrow keys.
        return park("pick", ("Did you mean this?" if len(found) == 1 else
                             f"Which one should go?{' (closest 15)' if len(found) >= 15 else ''}"),
                    {"tool": "delete", "args": a},
                    options=[str(p.relative_to(HOME)) for p in found], paths=[str(p) for p in found])
    if not bulk:
        found = found[:1]
    where = f" in {root.relative_to(HOME)}" if root else ""
    noun = {"image": "image", "video": "video", "pdf": "PDF", "audio": "audio file", "doc": "document"}.get(kind, "file")
    msg = (f"Move {found[0].relative_to(HOME)} to the Trash?" if len(found) == 1
           else f"Move {len(found)} {noun}s{where} to the Trash?")
    if dry:
        return Result("done", f"[dry] would ask: {msg}  first: {[str(p) for p in found[:5]]}")
    return park("password", msg, {"tool": "delete", "args": a},
                options=[str(p.relative_to(HOME)) for p in found[:200]], paths=[str(p) for p in found])


# ── claude, shell, refuse ────────────────────────────────────────────────────

def resolve_dir(name):
    """A folder the user named: ~-relative or absolute paths, a project under
    ~/projects, or any folder of that name under home (find_folder)."""
    raw = os.path.expanduser(name.strip())
    if raw.startswith("/") and Path(raw).is_dir() and safe(raw):
        return Path(raw)
    if (HOME / raw).is_dir() and safe(HOME / raw):
        return HOME / raw
    if (HOME / "projects" / raw).is_dir():
        return HOME / "projects" / raw
    return find_folder(name)


def ask_claude(a, dry):
    # ~/projects unless a folder or project was named — Ahaan, 2026-10-06:
    # "it should do that in ~/projects/ by default unless i specify a dir".
    # A project named in the task itself ("fix the bar clock in hyprahaan")
    # counts as specifying one.
    d = HOME / "projects" if (HOME / "projects").is_dir() else HOME
    prompt = (a.get("prompt") or "").strip()
    if a.get("dir"):
        d = resolve_dir(a["dir"]) or d
    elif prompt:
        for proj in sorted((HOME / "projects").glob("*")) if (HOME / "projects").is_dir() else []:
            if proj.is_dir() and re.search(rf"\b{re.escape(proj.name.lower())}\b", prompt.lower()):
                d = proj
    term = pref("DEFAULT_TERMINAL") or "kitty"
    claude = shutil.which("claude") or str(HOME / ".local/bin/claude")
    line = f"{shlex.quote(term)} --directory {shlex.quote(str(d))} -e {shlex.quote(claude)}"
    if prompt:
        line += " " + shlex.quote(prompt)
    if dry:
        return Result("done", f"[dry] exec {line}")
    exec_cmd(line)
    where = "~/" + str(d.relative_to(HOME)) if d != HOME else "~"
    return Result("done", (f"Handed to Claude in {where}" if prompt else f"Opened Claude in {where}"))


# command -> allowed first argument (None = any arguments). No shell is ever
# involved: argv lists, joined only by pipes this code sets up itself.
READONLY = {
    "free": None, "df": None, "uptime": None, "ps": None, "lscpu": None, "lspci": None, "lsblk": None,
    "lsusb": None, "nproc": None, "uname": None, "whoami": None, "hostname": None, "date": None,
    "sensors": None, "who": None, "id": None, "wc": None, "sort": None, "head": None, "tail": None,
    "grep": None, "cut": None, "uniq": None, "nvidia-smi": None, "du": None, "acpi": None,
    "top": {"-b", "-bn1", "-bn", "-n"}, "ip": {"a", "addr", "address", "-br", "-4", "-6", "route", "r", "link"},
    "upower": {"-i", "-e", "-d", "--dump", "--enumerate"}, "hyprctl": {"clients", "monitors", "version",
    "activewindow", "workspaces", "devices", "-j"}, "wpctl": {"status", "get-volume", "inspect"},
    "playerctl": {"metadata", "status", "-l", "--list-all"}, "nmcli": {"-t", "general", "device", "d", "-f"},
    "pactl": {"info", "list"}, "cat": None, "bluetoothctl": {"show", "devices", "info"},
    "systemctl": {"status", "is-active", "list-units", "--failed", "--user"},
}


def _shell_ok(stages):
    for argv in stages:
        if not argv or argv[0] not in READONLY:
            return f"“{argv[0] if argv else ''}” isn't on the read-only list"
        allowed = READONLY[argv[0]]
        if allowed is not None and len(argv) > 1 and argv[1] not in allowed:
            return f"“{shlex.join(argv[:2])}” isn't read-only"
        if argv[0] == "cat" and any(not x.startswith(("/proc/", "/sys/", "/etc/os-release")) for x in argv[1:]):
            return "cat is limited to /proc, /sys and /etc/os-release"
        if argv[0] == "systemctl" and any(x in argv for x in ("start", "stop", "restart", "enable", "disable", "kill", "mask")):
            return "systemctl may only read"
    return None


def shell(a, dry):
    cmd = a["cmd"].strip()
    # Several independent read-only commands joined by ; or && are fine — the
    # model wrote "uptime; free -h; top -bn1 | head -10" for "whats eating my
    # cpu" and the first guard refused it whole. Each part is checked on its
    # own; redirects, substitution, backgrounding and || stay refused.
    if re.search(r"[><`$\\]|\|\||\(|(?<!&)&(?!&)|&&&", cmd):
        return Result("error", "That command isn't read-only, so I won't run it")
    try:
        parts = [[shlex.split(st) for st in part.split("|")] for part in re.split(r";|&&", cmd) if part.strip()]
    except ValueError:
        return Result("error", "I couldn't parse that command")
    for stages in parts:
        why = _shell_ok(stages)
        if why:
            return Result("error", f"Not running “{cmd}”: {why}")
    if dry:
        return Result("done", f"[dry] {cmd}")
    outs = []
    for stages in parts:
        data = None
        for argv in stages:
            try:
                r = subprocess.run(argv, input=data, capture_output=True, timeout=8)
            except (OSError, subprocess.TimeoutExpired):
                return Result("error", f"“{argv[0]}” failed or took too long")
            data = r.stdout
        outs.append((data or b"").decode(errors="replace").rstrip())
    out = "\n\n".join(o for o in outs if o)
    return Result("text", cmd, body=out[:12000] or "(no output)", mono=True)


def refuse(a, dry, said=""):
    if a.get("offer_claude"):
        return park("offer_claude", f"{a['reason']} — hand it to Claude?", {"tool": "ask_claude", "args": {"prompt": said}})
    return Result("done", a["reason"][:1].upper() + a["reason"][1:])


# ── parked actions: confirm, password, pick, offer ───────────────────────────

def park(kind, msg, then, **extra):
    """Hold an action until the UI answers. The token names EXACTLY what was
    shown — a delete confirms the listed paths, not a fresh search."""
    PENDING.mkdir(parents=True, exist_ok=True)
    for old in PENDING.glob("*.json"):              # five minutes, then gone
        if time.time() - old.stat().st_mtime > 300:
            old.unlink(missing_ok=True)
    # Named `ticket`, not `token`: backup_configs.sh's secret scan matches
    # `token = <8+ chars>` and refused the whole mirror on this line, which
    # is a random id minted per request, not a secret.
    ticket = secrets.token_hex(8)
    (PENDING / f"{ticket}.json").write_text(json.dumps({"kind": kind, "then": then, **extra}))
    return Result(kind, msg, token=ticket, **{k: v for k, v in extra.items() if k == "options"})


def resume(token, choice=None):
    """The UI's answer: yes (confirm / password accepted / offer taken), or the
    index of a pick."""
    f = PENDING / f"{re.sub(r'[^0-9a-f]', '', token)}.json"
    try:
        p = json.loads(f.read_text())
    except (OSError, ValueError):
        return Result("error", "That request expired — ask again")
    f.unlink(missing_ok=True)
    then = p["then"]
    if p["kind"] == "password" and then["tool"] == "delete":
        return _trash([Path(x) for x in p["paths"]])
    if p["kind"] == "pick":
        try:
            path = Path(p["paths"][int(choice)])
        except (TypeError, ValueError, IndexError):
            return Result("error", "Pick one of the listed files")
        if then["tool"] == "open_file":
            return _open_path(path, then["args"], False)
        if then["tool"] == "show_file":
            return _show_path(path, then["args"], False)
        if then["tool"] == "delete":
            r = park("password", f"Move {path.relative_to(HOME)} to the Trash?", then,
                     options=[str(path.relative_to(HOME))], paths=[str(path)])
            r["auto"] = True        # choosing it WAS the decision: raise the password box now
            return r
    if p["kind"] == "confirm" and then["tool"] == "close_app":
        return close_app(then["args"], False, confirmed=True)
    if p["kind"] == "offer_claude":
        return ask_claude(then["args"], False)
    if p["kind"] == "offer_open":
        return _open_path(Path(then["args"]["path"]), {}, False)
    return Result("error", "I lost track of that one — ask again")


def _trash(paths):
    done, failed = 0, []
    for p in paths:
        if not safe(p) or not (p.is_file() or p.is_symlink()):
            failed.append(p.name)
            continue
        if ok(["gio", "trash", str(p)]):
            done += 1
        else:
            failed.append(p.name)
    msg = f"Moved {done} file{'s' * (done != 1)} to the Trash"
    return Result("done" if not failed else "text", msg + (f" ({len(failed)} skipped)" if failed else ""),
                  body="\n".join(failed) if failed else None)


TABLE = {
    "open_app": open_app, "close_app": close_app, "window": window, "workspace": workspace,
    "screenshot": screenshot, "record_start": record_start, "record_stop": record_stop, "ocr": ocr,
    "web_search": web_search, "open_url": open_url, "media": media, "volume": volume,
    "brightness": brightness, "setting": setting, "power_profile": power_profile, "reminder": reminder,
    "wallpaper": wallpaper, "session": session, "open_file": open_file, "read_file": read_file,
    "write_note": write_note, "delete": delete, "ask_claude": ask_claude, "shell": shell,
    "show_file": show_file, "play_song": play_song,
}


JUNK = "\"'“”‘’`,;:()[]{} "


def tidy(args):
    """Strip stray quotes and punctuation from the ends of string arguments.
    Measured 2026-10-06: the 4B once emitted folder "Downloads”, " — a closing
    quote and a comma inside the value — and find_folder then found nothing."""
    return {k: (v.strip(JUNK) if isinstance(v, str) and k not in ("content", "cmd", "prompt", "text") else v)
            for k, v in args.items()}


_SAID = [""]     # the sentence being served, for the executors that refine by it


def run(call, dry=False, said=""):
    tool, args = call["tool"], tidy(call.get("args", {}))
    _SAID[0] = said
    if tool == "refuse":
        return refuse(args, dry, said)
    if tool == "reply":
        # Talk is the one thing jarvis does that changes nothing — added after
        # "hello there" was planned as workspace 1 (2026-10-06): with only
        # actions to choose from, a greeting got the nearest action.
        return Result("done", (args.get("text") or "Hey!").strip())
    fn = TABLE.get(tool)
    if not fn:
        return Result("error", f"I don't know how to {tool}")
    if tool in ("open_app", "open_file", "delete", "read_file", "show_file") and said:
        args = dict(args, _said=said)
    try:
        return fn(args, dry)
    except Exception as e:                      # one broken tool must not kill the reply
        return Result("error", f"{tool} failed: {type(e).__name__}: {e}")
