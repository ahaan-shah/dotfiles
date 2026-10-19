#!/usr/bin/env python3
"""eval/run.py [cases.jsonl ...] — score the model behind JARVIS_URL against the cases.

Two sets, and the split is the point:
  dev.jsonl    tuned against. Its failures are read and the prompt changed.
  test.jsonl   HELD OUT. Never read case-by-case while tuning; its score is
               the number reported. A prompt tuned on the cases it is scored
               on measures memorisation, not whether a rule generalised.

A case passes when it produces the same tools in the same order and every
expected argument matches. Expected args are a SUBSET — anything the case does
not mention is free. Within it:
  "key": v       must be present and match v
  "?key": v      may be absent; if present must match v
  "!key": null   must be absent
  string         case-insensitive, either side containing the other
  list           any one of the alternatives
  ">0" / "<0"    numeric sign
  number, bool   exact
"expect" may instead be a list of alternative call lists ("expect_any").
"tag" groups the summary: simple, multi, long, refuse.

The window list is a FIXED snapshot, not the live one, so a run is repeatable.
"""
import collections
import re
import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
import brain  # noqa: E402

# Same shape as jarvis.py's live context(): windows named by their app's
# desktop Name, not their raw class.
CONTEXT = """\
Current workspace: 1
Open windows (app | title | workspace):
kitty | ~ | 1
kitty | ✳ Claude Code — hyprahaan | 4
Zen Browser | MATH | Full plan — Zen Browser | 5
Vesktop | Discord | #general | 6
Obsidian | notes - Obsidian | 2
Whatsapp | web.whatsapp.com | special
Spotify | Spotify Premium | special
Browsers: Brave, Chromium, Zen Browser (default)"""


def match(want, got):
    if isinstance(want, list):
        return any(match(w, got) for w in want)
    if want in (">0", "<0"):
        return isinstance(got, (int, float)) and not isinstance(got, bool) and (got > 0 if want == ">0" else got < 0)
    if isinstance(want, str):
        if not isinstance(got, str):
            return False
        # Letters and digits only: "standup" and "stand up" are the same
        # reminder, and a test that fails on the space is testing spelling.
        a, b = re.sub(r"[^a-z0-9]", "", want.lower()), re.sub(r"[^a-z0-9]", "", got.lower())
        return a in b or b in a
    return want == got and type(want) is type(got)


def call_ok(e, c):
    if e["tool"] != c["tool"]:
        return False
    args = c["args"]
    for k, v in e["args"].items():
        if k.startswith("!"):
            if k[1:] in args:
                return False
        elif k.startswith("?"):
            if k[1:] in args and not match(v, args[k[1:]]):
                return False
        elif k not in args or not match(v, args[k]):
            return False
    return True


def score(case, calls):
    alts = case.get("expect_any") or [case["expect"]]
    return any(len(a) == len(calls) and all(call_ok(e, c) for e, c in zip(a, calls)) for a in alts)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    quiet = "-q" in sys.argv
    files = args or [pathlib.Path(__file__).with_name("dev.jsonl")]
    cases = [json.loads(l) for f in files for l in open(f) if l.strip()]
    walls, fails = [], []
    by_tag = collections.defaultdict(lambda: [0, 0])
    brain.plan("warm up", CONTEXT)          # first call pays for the system prompt
    for c in cases:
        calls, info = brain.plan(c["say"], CONTEXT)
        ok = score(c, calls)
        tag = c.get("tag", "simple")
        by_tag[tag][0] += ok
        by_tag[tag][1] += 1
        walls.append(info["wall"])
        if not quiet:
            print(f"{'PASS' if ok else 'FAIL'} {info['wall']*1000:5.0f}ms  "
                  f"gen={info['gen_n']:>3}  {c['say']}", flush=True)
        if not ok:
            fails.append((c, calls))
    walls.sort()
    passed = sum(p for p, _ in by_tag.values())
    print(f"\n{passed}/{len(cases)} passed   median {walls[len(walls)//2]*1000:.0f}ms   "
          f"p90 {walls[int(len(walls)*.9)]*1000:.0f}ms   max {walls[-1]*1000:.0f}ms")
    print("   " + "   ".join(f"{t} {p}/{n}" for t, (p, n) in sorted(by_tag.items())))
    if not quiet:
        for c, calls in fails:
            want = c.get("expect_any") or c["expect"]
            print(f"\n✗ {c['say']}\n  want {json.dumps(want)}\n  got  {json.dumps(calls)}")


if __name__ == "__main__":
    main()
