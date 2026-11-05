#!/usr/bin/env python3
"""mqueue.py — "play this next", for any MPRIS player (2026-11-02).

Ahaan asked EVE to play a song after the one on now, and she could only
offer a reminder: she had play_spotify (play NOW) and nothing that waits.
He picked the MPRIS route over adding a queue command to Spotsie "so its
universal" — this works for whatever player is running, as long as it takes
OpenUri (MPRIS SupportedUriSchemes; Spotsie measured: spotify, https, http).

MPRIS has no queue, so this is one: a list in a state file, and a watcher
that hands the next item to the player's OpenUri the moment the current
track ends. What that costs, against a player's own queue:
  - OpenUri replaces what was playing. After the queued songs, the album or
    playlist that was on does NOT resume — MPRIS never says what it was.
  - "Ends" is seen by polling, so it fires just before the end (< 0.4 s
    left) to beat the player's own advance; if a poll misses that window,
    the player's next track is heard for a moment before ours replaces it.
  - A skip (the track changing under it) also counts as an end, which is
    what "next" means anyway.

  mqueue.py add URI [TITLE]    queue it (plays at once if nothing is playing)
  mqueue.py list               JSON: player and items
  mqueue.py clear
  mqueue.py watch              the watcher; add starts it, one at a time

The watcher is started detached (setsid, all three fds on /dev/null — the
SIGPIPE rule: it must not hold a pipe of whatever started it, the broker
under Claude under the shell). One runs at a time, by a flock; it exits when
the list is empty, and gives up the list if the player is gone for 30 s.
"""
import fcntl
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve()
STATE = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local/state") / "hyprahaan/eve"
QFILE = STATE / "mqueue.json"
RUN = Path(os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}")
WLOCK = RUN / "eve-mqueue.watch.lock"     # held by the running watcher
FLOCK = RUN / "eve-mqueue.file.lock"      # held around every read-modify-write
MAX = 50

SPOTIFY = re.compile(r"(?:spotify:|https?://open\.spotify\.com/(?:intl-[a-z]+/)?)"
                     r"(track|album|playlist|artist|show|episode)[:/]([A-Za-z0-9]{22})")


def pc(*args, timeout=3):
    try:
        r = subprocess.run(["playerctl", *args], capture_output=True, text=True, timeout=timeout)
        return r.stdout.strip() if r.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired):
        return None


def meta(player):
    """(status, trackid, length_us, position_us), or None if the player is gone."""
    out = pc("-p", player, "metadata", "--format",
             "{{status}}\t{{mpris:trackid}}\t{{mpris:length}}\t{{position}}")
    if out is None:
        return None
    f = (out.split("\t") + ["", "", "", ""])[:4]

    def num(s):
        try:
            return int(float(s))
        except ValueError:
            return 0
    return f[0], f[1], num(f[2]), num(f[3])


def schemes(player):
    """The URI schemes the player's OpenUri takes, from MPRIS itself."""
    try:
        r = subprocess.run(["busctl", "--user", "get-property", "org.mpris.MediaPlayer2." + player,
                            "/org/mpris/MediaPlayer2", "org.mpris.MediaPlayer2", "SupportedUriSchemes"],
                           capture_output=True, text=True, timeout=3)
    except (OSError, subprocess.TimeoutExpired):
        return []
    return re.findall(r'"([^"]*)"', r.stdout) if r.returncode == 0 else []


def current_player():
    """The player playerctl would pick (a playing one first), by MPRIS name.
    MQUEUE_PLAYER pins one — for a test against a fake player."""
    if os.environ.get("MQUEUE_PLAYER"):
        return os.environ["MQUEUE_PLAYER"]
    name = pc("metadata", "--format", "{{playerInstance}}")
    if name:
        return name
    players = (pc("-l") or "").split()
    return players[0] if players else None


class Lock:
    def __init__(self, path):
        self.path = path

    def __enter__(self):
        RUN.mkdir(parents=True, exist_ok=True)
        self.f = open(self.path, "a")
        fcntl.flock(self.f, fcntl.LOCK_EX)
        return self

    def __exit__(self, *a):
        self.f.close()


def load():
    try:
        d = json.loads(QFILE.read_text())
        if isinstance(d, dict) and isinstance(d.get("items"), list):
            return d
    except (OSError, ValueError):
        pass
    return {"player": "", "items": []}


def save(d):
    STATE.mkdir(parents=True, exist_ok=True)
    tmp = QFILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(d, ensure_ascii=False))
    tmp.replace(QFILE)


def normalize(uri, player):
    """A Spotify web link becomes its spotify: URI when the player takes
    that scheme; anything else must be a scheme the player says it takes."""
    uri = str(uri or "").strip()
    sch = schemes(player)
    m = SPOTIFY.search(uri)
    if m and "spotify" in sch:
        return f"spotify:{m.group(1)}:{m.group(2)}"
    if uri.startswith("/"):
        uri = "file://" + uri
    scheme = uri.split(":", 1)[0].lower() if ":" in uri else ""
    if not scheme or (sch and scheme not in sch):
        raise ValueError(f"{player} can't open {scheme or 'that'} links (it takes: {', '.join(sch) or 'none'})")
    return uri


def start_watcher():
    subprocess.Popen([sys.executable, str(HERE), "watch"], stdin=subprocess.DEVNULL,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


def add(uri, title=""):
    """-> a sentence for EVE to pass on. Raises ValueError for a bad link."""
    player = current_player()
    if not player:
        raise ValueError("no music player is running")
    uri = normalize(uri, player)
    m = meta(player)
    if m is None:
        raise ValueError(f"{player} isn't answering")
    # Nothing on to wait for: "play it next" is "play it now".
    if m[0] == "Stopped" or not m[1]:
        pc("-p", player, "open", uri, timeout=10)
        return f"Nothing was playing, so it's playing now in {player}."
    with Lock(FLOCK):
        d = load()
        if d.get("player") and d["player"] != player:
            d = {"player": player, "items": []}     # a queue for a player no longer in front
        d["player"] = player
        if len(d["items"]) >= MAX:
            raise ValueError(f"the queue is full ({MAX})")
        d["items"].append({"uri": uri, "title": str(title or "")[:200]})
        save(d)
        n = len(d["items"])
    start_watcher()
    state = "" if m[0] == "Playing" else " (the current track is paused; it goes on after that one finishes)"
    return f"Queued in {player} at position {n}{state}."


def clear():
    with Lock(FLOCK):
        save({"player": "", "items": []})


def pop(player):
    with Lock(FLOCK):
        d = load()
        if d.get("player") != player or not d["items"]:
            return None
        item = d["items"].pop(0)
        save(d)
        return item


def watch():
    RUN.mkdir(parents=True, exist_ok=True)
    me = open(WLOCK, "a")
    try:
        fcntl.flock(me, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return                                          # one is already running
    watched = None          # the track we are waiting to end
    last_pos = 0
    gone_since = None
    while True:
        d = load()
        player = d.get("player")
        if not player or not d["items"]:
            return
        m = meta(player)
        if m is None:
            gone_since = gone_since or time.monotonic()
            if time.monotonic() - gone_since > 30:
                clear()                                 # the player closed: its queue goes with it
                return
            time.sleep(1)
            continue
        gone_since = None
        status, tid, length, pos = m
        if watched is None:
            watched, last_pos = tid, pos
        left = length - pos if length > 0 else 10**12
        ended = (tid != watched                                     # skipped, or the player moved on
                 or (status == "Playing" and left <= 400_000)       # about to end: beat its own advance
                 or (pos + 3_000_000 < last_pos and last_pos > length - 3_000_000 > 0)  # repeat-one looped
                 or status == "Stopped")
        if ended:
            item = pop(player)
            if not item:
                return
            before = tid
            pc("-p", player, "open", item["uri"], timeout=10)
            # Wait for the player to be on it, so its first poll is not
            # read as the end of the track it replaced.
            for _ in range(40):
                time.sleep(0.15)
                m2 = meta(player)
                if m2 and m2[1] and m2[1] not in (before, watched):
                    break
            m2 = meta(player)
            watched, last_pos = (m2[1], m2[3]) if m2 else (None, 0)
            continue
        last_pos = pos
        # Fine polling only near the end; a whole song at 1 Hz is cheap.
        time.sleep(0.1 if status == "Playing" and left < 3_000_000 else 1.0)


def main(argv):
    cmd = argv[1] if len(argv) > 1 else ""
    if cmd == "add" and len(argv) >= 3:
        try:
            print(add(argv[2], " ".join(argv[3:])))
        except ValueError as e:
            print(f"Not queued: {e}")
            return 1
    elif cmd == "list":
        print(json.dumps(load(), ensure_ascii=False))
    elif cmd == "clear":
        clear()
    elif cmd == "watch":
        watch()
    else:
        print("usage: mqueue.py add URI [TITLE] | list | clear | watch")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
