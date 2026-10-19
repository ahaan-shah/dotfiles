#!/usr/bin/env python3
"""jarvis.py — one request, start to finish.

  jarvis.py "take a screenshot of clade terminal"     plan + act
  jarvis.py --dry-run "delete all pics in Screenshots" plan + resolve, touch nothing
  jarvis.py --resume TOKEN [CHOICE]                    the UI's answer to a
                                                       confirm / password / pick / offer
  jarvis.py --context                                  print what the model is shown
  jarvis.py --browse QUERY                             the same search, in the browser
  jarvis.py --warm                                     start the server, cache the prompt, act on nothing

stdout is one JSON object per line, for the bar to read as they arrive:
  {"ev":"plan","calls":[...],"ms":812}
  {"ev":"step","i":0,"tool":"screenshot"}
  {"ev":"result","i":0, ...Result}
  {"ev":"done"}
Nothing else is ever written to stdout; diagnostics go to stderr.

The model server is NOT started or stopped here: the bar starts it when the
pill opens (so it loads while the sentence is typed) and stops it when the
card closes (server.sh). Run from a terminal with no server up, this starts
one, and --down stops it after.
"""
import json
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import act    # noqa: E402
import brain  # noqa: E402

SERVER = str(Path(__file__).resolve().parent / "server.sh")


def emit(**ev):
    print(json.dumps(ev, ensure_ascii=False), flush=True)


def context():
    """The live desktop, as the model sees it. Windows are named by their
    app's own Name ("WhatsApp"), not only their class
    ("chrome-web.whatsapp.com__-Default"): the held-out eval's "show me
    whatsapp" miss came from the model never recognising that class."""
    ws = (act.hj("activeworkspace") or {}).get("id", "?")
    lines = [f"Current workspace: {ws}", "Open windows (app | title | workspace):"]
    for c in act.clients():
        w = c["workspace"]["name"]
        w = "special" if w.startswith("special") else w
        lines.append(f"{act.label(c)} | {c.get('title', '')[:60]} | {w}")
    b = act.browsers()
    default = act.pref("DEFAULT_BROWSER")
    lines.append("Browsers: " + ", ".join(f"{n}{' (default)' if c == default else ''}" for n, c in b.items()))
    return "\n".join(lines)


def main(argv):
    dry = "--dry-run" in argv
    down = "--down" in argv
    args = [a for a in argv if not a.startswith("--")]
    if "--context" in argv:
        print(context())
        return
    if "--warm" in argv:
        # The pill fires this the moment it opens: bring the server up and
        # make one throwaway request, so the system prompt is in llama-server's
        # cache before Enter. Without it the first real request processes the
        # whole prompt and took 2.6 s against ~0.85 s warm (measured
        # 2026-10-06). Nothing is acted on and nothing is printed.
        subprocess.run([SERVER, "up"], stdout=subprocess.DEVNULL)
        try:
            brain.plan("warm up", context())
        except OSError:
            pass
        return
    if "--open" in argv:
        # A preview card's "Open" button: the exact file it showed.
        path = Path(argv[argv.index("--open") + 1])
        r = act._open_path(path, {}, False) if act.safe(path) else act.Result("error", "That file is off limits")
        emit(ev="result", i=0, **r)
        emit(ev="done")
        return
    if "--open-url" in argv:
        u = argv[argv.index("--open-url") + 1]
        emit(ev="result", i=0, **act.run({"tool": "open_url", "args": {"url": u}}))
        emit(ev="done")
        return
    if "--browse" in argv:
        # The card's "Open in browser" button: the same search, in the browser.
        q = argv[argv.index("--browse") + 1]
        emit(ev="result", i=0, **act.run({"tool": "open_url", "args": {"query": q}}))
        emit(ev="done")
        return
    if "--resume" in argv:
        i = argv.index("--resume")
        token = argv[i + 1]
        choice = argv[i + 2] if len(argv) > i + 2 and not argv[i + 2].startswith("--") else None
        emit(ev="result", i=0, **act.resume(token, choice))
        emit(ev="done")
        return
    text = " ".join(args).strip()
    if not text:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    # Always `up`, never "up if it is down": `up` is also what lifts Quiet to
    # Balanced, and skipping it when a server was already running is exactly
    # how requests ran under Quiet at 2.4 tok/s (2026-10-06). When the server
    # is healthy it costs one profile read and one /health.
    subprocess.run([SERVER, "up"], stdout=subprocess.DEVNULL)
    t0 = time.monotonic()
    calls, info = brain.plan(text, context())
    emit(ev="plan", calls=calls, ms=round((time.monotonic() - t0) * 1000))
    for i, call in enumerate(calls):
        emit(ev="step", i=i, tool=call["tool"])
        r = act.run(call, dry=dry, said=text)
        emit(ev="result", i=i, **r)
        if r["kind"] in ("pick", "confirm", "password", "offer_claude", "error"):
            break       # anything that needs an answer, or failed, stops the chain
    emit(ev="done")
    if down:
        subprocess.run([SERVER, "down"])


if __name__ == "__main__":
    main(sys.argv[1:])
