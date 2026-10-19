"""brain.py — turn one sentence into a short list of tool calls.

This is the only part of jarvis that talks to the model, and the model's only
job is to PICK: which of the tools below, with what arguments. It never writes
a shell command that gets run as-is, never sees a password, never touches a
file. Everything it returns is checked again by the executors (act.py), which
own the actual rules — so a confused model can produce a wrong action, but not
a forbidden one.

── Why the output is held to a JSON schema ───────────────────────────────────
llama-server compiles `response_format.json_schema` into a grammar and masks
every token that would leave it. A 4B model asked nicely for JSON gets it right
most of the time; a 4B model under a grammar CANNOT emit an unknown tool, a
misspelt key or an unterminated string. Most of the reliability of a small
model here comes from that, not from its size.

── Why so many arguments are REQUIRED ────────────────────────────────────────
The first eval (2026-10-05) failed 16/48, and the largest group was the model
silently dropping an argument it was free to omit: "screenshot" with no
target, "record a region" with no target, "move zen to w5" with no app. An
optional field is one the grammar lets it skip, and a small model skips. Where
there is a sensible default, the field is required and the default is spelt
out in RULES, so the model has to write the choice down — and the choice is
then visible in the eval instead of being decided invisibly by an executor.

── Why the live context goes in the user turn, not the system prompt ────────
llama-server reuses the KV cache for the longest prefix a new request shares
with the last one (cache_prompt). The system prompt never changes, so it is
processed once per server start; only the window list and the sentence after
it are new each time (measured: 10-12 new tokens per request).
"""

import json
import os
import time
import urllib.request

URL = os.environ.get("JARVIS_URL", "http://127.0.0.1:8737")

WS = {"type": "integer", "minimum": 1, "maximum": 10}
TARGET = {"enum": ["region", "window", "full"]}
KIND = {"enum": ["any", "pdf", "image", "video", "audio", "doc", "folder"]}
# Every string is length-capped IN THE GRAMMAR. Measured 2026-10-05: on "whats
# in my groceries note" the 4B opened a string and never closed it, ran into
# max_tokens and returned unparseable JSON. A cap turns that runaway into a
# closed (if truncated) value the executors can still reject cleanly.
S = {"type": "string", "maxLength": 80}
LONG = {"type": "string", "maxLength": 600}
I = {"type": "integer"}
B = {"type": "boolean"}

# tool -> (one-line description for the prompt, args schema properties, required)
TOOLS = {
    "open_app":     ("launch an app. app = name the user said, or a role: terminal, browser, files, editor. "
                     "dir = a folder to open it in (terminals and the file manager)",
                     {"app": S, "workspace": WS, "dir": S}, ["app"]),
    "close_app":    ("close window(s). app = name, or \"active\" for the focused window, or \"*\" with workspace for everything there",
                     {"app": S, "all": B, "workspace": WS}, ["app"]),
    "window":       ("act on an open window. app = name, or \"active\" for the focused one",
                     {"action": {"enum": ["focus", "move", "fullscreen", "float"]}, "app": S, "workspace": WS},
                     ["action", "app"]),
    "workspace":    ("switch to workspace n", {"n": WS}, ["n"]),
    "screenshot":   ("take a screenshot", {"target": TARGET, "match": S,
                     "dest": {"enum": ["clipboard", "file", "both"]}, "delay": I}, ["target"]),
    "record_start": ("start a screen recording. seconds = auto-stop",
                     {"target": TARGET, "match": S, "audio": {"enum": ["none", "desktop", "both"]}, "seconds": I},
                     ["target", "audio"]),
    "record_stop":  ("stop the screen recording", {}, []),
    "ocr":          ("copy the text visible on screen", {"target": TARGET, "match": S}, ["target"]),
    "web_search":   ("look something up and SHOW the answer inside jarvis, no browser", {"query": S}, ["query"]),
    "open_url":     ("open a website or a search in the BROWSER",
                     {"url": S, "query": S, "site": S, "images": B, "browser": S, "workspace": WS}, []),
    "media":        ("music/video playback", {"action": {"enum": ["play", "pause", "toggle", "next", "previous"]}}, ["action"]),
    "play_song":    ("play a SPECIFIC song (or artist/album) on Spotify", {"song": S, "artist": S}, ["song"]),
    "volume":       ("level = 0-100, change = +/- steps, mute = true/false", {"level": I, "change": I, "mute": B}, []),
    "brightness":   ("screen brightness. level = 0-100, change = +/-", {"level": I, "change": I}, []),
    "setting":      ("switch something on/off. nightlight = night light / warm screen, awake = keep the laptop from sleeping, dnd = do not disturb / silence notifications, kbd_backlight = keyboard light",
                     {"name": {"enum": ["wifi", "bluetooth", "nightlight", "dnd", "awake", "touchpad", "kbd_backlight"]},
                      "state": {"enum": ["on", "off", "toggle"]}}, ["name", "state"]),
    # nightlight = warm screen tint; awake = keep the laptop from sleeping or
    # locking; dnd = silence notifications. Said in the description because the
    # enum names are not the words anyone says.
    "power_profile": ("power mode. \"quiet mode\", \"quiet\", battery saver = power-saver (asusd calls it Quiet)", {"profile": {"enum": ["power-saver", "balanced", "performance"]}}, ["profile"]),
    "reminder":     ("remind the user later. minutes from now, OR at = \"HH:MM\" 24h",
                     {"text": S, "minutes": I, "at": S}, ["text"]),
    "wallpaper":    ("CHANGE the desktop wallpaper. Only when the user asks to set/change the wallpaper or background", {"query": S, "random": B}, []),
    "session":      ("lock the screen or suspend. there is NO shutdown, reboot or logout: those -> refuse", {"action": {"enum": ["lock", "suspend"]}}, ["action"]),
    "open_file":    ("open a file or folder from the home dir in its default app",
                     {"name": S, "folder": S, "kind": KIND, "latest": B, "workspace": WS, "page": I}, []),
    "show_file":    ("SHOW a file inside EVE without opening anything: an image, a pdf's first page, a text file's "
                     "contents, or only the lines containing grep", {"name": S, "folder": S, "kind": KIND, "grep": S}, ["name"]),
    "write_note":   ("create a NEW .txt/.md note", {"name": S, "content": LONG}, ["name", "content"]),
    "delete":       ("move the user's own files to the trash (asks for the password first)",
                     {"name": S, "folder": S, "kind": KIND}, ["kind"]),
    "ask_claude":   ("open Claude Code in a terminal, optionally with a task. dir only if the user named a folder or project",
                     {"prompt": LONG, "dir": S}, []),
    "shell":        ("a READ-ONLY command that answers a question about this computer", {"cmd": {"type": "string", "maxLength": 200}}, ["cmd"]),
    "reply":        ("just talk back: greetings, thanks, small talk, or questions about EVE itself. "
                     "One short friendly sentence. Never claim to have done anything",
                     {"text": {"type": "string", "maxLength": 160}}, ["text"]),
    "refuse":       ("cannot or must not do it", {"reason": S, "offer_claude": B}, ["reason", "offer_claude"]),
}


def schema():
    calls = []
    for name, (_, props, req) in TOOLS.items():
        calls.append({
            "type": "object",
            "properties": {"tool": {"const": name},
                           "args": {"type": "object", "properties": props,
                                    "required": req, "additionalProperties": False}},
            "required": ["tool", "args"], "additionalProperties": False,
        })
    return {"type": "object",
            "properties": {"calls": {"type": "array", "items": {"anyOf": calls},
                                     "minItems": 1, "maxItems": 3}},
            "required": ["calls"], "additionalProperties": False}


RULES = """\
Rules:
- Output 1 to 3 calls, in the order they should happen. One call per thing asked.
- Fill an optional argument only when the user implied it. "here" / "where i am" -> leave workspace out.
  "w2", "ws 2", "on 2", "in 2", "workspace 2" -> workspace 2.
- Fix obvious typos in names (clade -> claude, spotfy -> spotify, discrod -> discord).
- "this window", "this", "it" about a window -> app "active".
- "open a terminal in X", "terminal at X" -> open_app terminal, dir X. "open claude" with no task -> ask_claude, no prompt.
- "switch to X", "show me X", "bring up X", "pull up X", "focus X" where X is an app -> window focus, app X.
  Never use workspace() for an app: workspace() is only for "workspace N" / "go to N".
- "all/every X windows" -> close_app all true.
- Never invent a value the user did not say (no made-up durations, browsers or workspaces).

Capture:
- screenshot/ocr target: nothing said -> full for screenshot, region for ocr. "this", "part", "area", "region",
  "select" -> region. "this window", "current window" -> window. An app named -> window + match = that app.
- screenshot dest: "copy"/"clipboard" only -> clipboard. "save" -> file. Otherwise leave dest out.
- "in N seconds" on a screenshot -> delay N. It is still a screenshot, not a recording.
- record_start target: nothing said, "the screen", "my screen" -> full. An app named -> window + match.
- record_start seconds: ONLY if a duration was said.
- record_start audio: nothing said -> none. "sound", "audio", "system/desktop sound" -> desktop.
  Any mention of mic, voice or talking -> both. Durations go in seconds (2 mins -> 120).

Web:
- web_search: questions, facts, news, weather, "google X", "search X", "look up X" -> answer shown in jarvis.
- open_url: a browser is named, the user says "open", wants pictures/images/videos, or names a site to search on
  (youtube, amazon, github, reddit ...). "search youtube for X" -> site youtube, query X.
  Opening a site itself ("open youtube", "open github.com") -> url, not query.
  "pics/pictures/images of X" -> images true.

Music:
- "play/pause/skip/next song" with no song named -> media. A named song, artist or album ("play X",
  "put on X by Y", "play some Y") -> play_song with song = the name and artist if given.

Files (all relative to the home folder):
- "open X" -> open_file (launches its app). "go to / scroll to / jump to / at page N" -> page N.
- "show me X", "let me see X", "what does X look like", "read X", "what does X say" -> show_file (a preview in EVE, nothing opens). "find WORD in X" -> show_file with grep = WORD.
- folder = a folder the user named (Screenshots, Downloads, Videos ...). name = the file name words, without
  filler like "my", "the", "file". kind = pics/photos/screenshots/wallpapers -> image, videos -> video, pdf -> pdf.
- "the latest/last/newest X" -> latest true.
- "all pics in Screenshots" -> folder Screenshots, kind image, no name.
- A wallpaper, photo or picture the user OWNS is a file (open_file / delete), not a web search.
  "change/set the wallpaper" -> wallpaper. "open/show/delete the X wallpaper" -> open_file / show_file / delete.

Talking:
- "hi", "hello there", "hey jarvis", "thanks", "how are you", "who are you", "what can you do" -> reply.
  A greeting with a request in it ("hey, open spotify") is the request, not a reply.

Safety:
- delete is ONLY for normal files in the home folder. Hidden files or folders (starting with "."), system paths
  (/etc, /usr, /bin, /), rm -rf, sudo, formatting, killing the desktop or all processes, shutdown, reboot,
  logout -> refuse.
- Writing code, scripts or apps, or editing/changing an existing file or config -> refuse with offer_claude true,
  UNLESS the user explicitly asked for claude ("ask claude", "have claude", "tell claude", "get claude") -> ask_claude.
- shell only reads information (cpu, ram, disk, battery, ip, uptime, hardware). It never changes, kills,
  installs or deletes anything.
"""

# Phrasings here are deliberately NOT ones in eval/dev.jsonl or eval/test.jsonl,
# so a pass on the eval means the rule generalised, not that the case was
# copied into the prompt. Written in Ahaan's own register — lowercase, clipped,
# typos kept — because that is what the model will actually be reading.
EXAMPLES = [
    ("open vscode on ws 7", [("open_app", {"app": "vscode", "workspace": 7})]),
    ("ss", [("screenshot", {"target": "full"})]),
    ("screenshot the discrod window just copy it", [("screenshot", {"target": "window", "match": "discord", "dest": "clipboard"})]),
    ("record this window w my voice for 1 min", [("record_start", {"target": "window", "audio": "both", "seconds": 60})]),
    ("move this to 4", [("window", {"action": "move", "app": "active", "workspace": 4})]),
    ("open the thesis pdf on w3 at page 12", [("open_file", {"name": "thesis", "kind": "pdf", "workspace": 3, "page": 12})]),
    ("find red car pics with brave", [("open_url", {"query": "red car", "images": True, "browser": "brave"})]),
    ("search amazon for usb c hubs", [("open_url", {"query": "usb c hubs", "site": "amazon"})]),
    ("whos the president of france", [("web_search", {"query": "president of france"})]),
    ("wipe all the videos in Downloads", [("delete", {"folder": "Downloads", "kind": "video"})]),
    ("show me where it says budget in plans.txt", [("show_file", {"name": "plans.txt", "grep": "budget"})]),
    ("show me the sunset pic", [("show_file", {"name": "sunset", "kind": "image"})]),
    ("remind me to stand up in 25 min", [("reminder", {"text": "stand up", "minutes": 25})]),
    ("change my waybar colors", [("refuse", {"reason": "editing config is a job for claude", "offer_claude": True})]),
    ("ask claude to change my waybar colors", [("ask_claude", {"prompt": "change my waybar colors"})]),
    ("show me steam", [("window", {"action": "focus", "app": "steam"})]),
    ("pull up the claude code window", [("window", {"action": "focus", "app": "claude"})]),
    ("go to battery saver", [("power_profile", {"profile": "power-saver"})]),
    ("open twitter in brave", [("open_url", {"url": "twitter", "browser": "brave"})]),
    ("open the sunset wallpaper", [("open_file", {"name": "sunset", "kind": "image"})]),
    ("delete the old essay doc in Documents", [("delete", {"name": "essay", "kind": "doc", "folder": "Documents"})]),
    ("heyy", [("reply", {"text": "Hey Ahaan! What can I do for you?"})]),
    ("whats your name", [("reply", {"text": "I'm EVE — I run things on this desktop for you."})]),
    ("cheers mate", [("reply", {"text": "Anytime!"})]),
    ("log me out", [("refuse", {"reason": "logging out is not something i do", "offer_claude": False})]),
    ("delete ~/.local/share/fonts", [("refuse", {"reason": "hidden folders are off limits", "offer_claude": False})]),
    ("open a terminal in my music folder", [("open_app", {"app": "terminal", "dir": "Music"})]),
    ("play blinding lights by the weeknd", [("play_song", {"song": "blinding lights", "artist": "the weeknd"})]),
    ("put on some bohemian rhapsody", [("play_song", {"song": "bohemian rhapsody"})]),
    ("open claude", [("ask_claude", {})]),
    ("open discord on 6 and mute", [("open_app", {"app": "discord", "workspace": 6}), ("volume", {"mute": True})]),
]


def _sig(props, req):
    """screenshot(target: region|window|full, match?, dest?: clipboard|file|both, delay?: int)"""
    out = []
    for k, v in props.items():
        t = ("|".join(v["enum"]) if "enum" in v else
             "int" if v.get("type") == "integer" else "true/false" if v.get("type") == "boolean" else "")
        out.append(k + ("" if k in req else "?") + (f": {t}" if t else ""))
    return ", ".join(out)


def system_prompt():
    # Each tool is shown WITH its signature. The first version listed only
    # the one-line descriptions, so the arguments and their allowed values
    # reached the model only through the grammar — which constrains tokens
    # but explains nothing. Measured: "turn on night light" became
    # brightness(change: 0), because nothing it could read said that
    # setting() had a nightlight.
    # EVE, from WALL-E — Ahaan's name for it (2026-10-06). The code is still
    # called jarvis; only what it calls itself changed.
    lines = ["You are EVE, the assistant on Ahaan's Linux desktop (Hyprland). You act by choosing tools.",
             "Map the request to tool calls. ? marks an optional argument. Tools:"]
    lines += [f"- {n}({_sig(p, r)}): {d}" for n, (d, p, r) in TOOLS.items()]
    lines += ["", RULES, "Examples:"]
    lines += [f"{q}\n=> " + json.dumps({"calls": [{"tool": t, "args": a} for t, a in c]}) for q, c in EXAMPLES]
    return "\n".join(lines)


def plan(text, context, max_tokens=300, timeout=60):
    """-> (calls, info). info carries timings for the eval and the UI."""
    body = {
        "messages": [{"role": "system", "content": system_prompt()},
                     {"role": "user", "content": f"{context}\n\nRequest: {text}"}],
        "response_format": {"type": "json_schema", "json_schema": {"name": "calls", "schema": schema()}},
        "temperature": 0, "max_tokens": max_tokens, "cache_prompt": True,
        # Qwen3 hybrid models think before answering unless told not to; the
        # grammar would forbid the <think> tokens anyway, but the template has
        # to agree or the first token is already outside the schema.
        "chat_template_kwargs": {"enable_thinking": False},
    }
    req = urllib.request.Request(URL + "/v1/chat/completions", json.dumps(body).encode(),
                                 {"Content-Type": "application/json"})
    t0 = time.monotonic()
    with urllib.request.urlopen(req, timeout=timeout) as r:
        resp = json.load(r)
    wall = time.monotonic() - t0
    t = resp.get("timings", {})
    try:
        calls = json.loads(resp["choices"][0]["message"]["content"])["calls"]
    except (ValueError, KeyError):
        # Still possible if the whole object outruns max_tokens. Say so in
        # the box rather than crash or guess.
        calls = [{"tool": "refuse", "args": {"reason": "didn't catch that, try rephrasing", "offer_claude": False}}]
    return calls, {"wall": wall, "prompt_n": t.get("prompt_n"), "prompt_ms": t.get("prompt_ms"),
                          "gen_n": t.get("predicted_n"), "gen_ms": t.get("predicted_ms")}


def summarize(question, sources, facts=(), max_tokens=170, timeout=30):
    """A short answer to a web question, written ONLY from the results.

    Ahaan (2026-10-06): the result card "has a lot of fluff — can it be
    condensed like a summary?". One plain completion — no grammar, a low
    temperature — over the numbered snippets, citing them as [n]. A 4B model
    blends sources happily, so the rules forbid adding anything not in them
    and say what to do when they do not answer the question; the card shows
    the numbered sources underneath, so every claim can be checked."""
    lines = [f"[{i}] {s['title']} ({s['site']}): {s['snippet']}" for i, s in enumerate(sources, 1)]
    if facts:
        lines.insert(0, "Facts: " + " | ".join(facts))
    body = {
        "messages": [
            {"role": "system", "content":
                "Answer the user's question in 1 to 3 short sentences using ONLY the search results given. "
                "Lead with the answer itself. Cite results like [1]. If the results do not answer it, say so in "
                "one sentence. No preamble, no lists, no advice."},
            {"role": "user", "content": f"Question: {question}\n\nSearch results:\n" + "\n".join(lines)},
        ],
        "temperature": 0.2, "max_tokens": max_tokens, "cache_prompt": True,
        "chat_template_kwargs": {"enable_thinking": False},
    }
    req = urllib.request.Request(URL + "/v1/chat/completions", json.dumps(body).encode(),
                                 {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)["choices"][0]["message"]["content"].strip()
