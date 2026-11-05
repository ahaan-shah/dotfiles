#!/usr/bin/env python3
# gita-from-pdf.py — build the Gita reader's text (shell/Gita.qml) from a PDF
# of Bhagavad-gītā As It Is.
#
#   gita-from-pdf.py <book.pdf>  ->  $XDG_DATA_HOME/hyprahaan/gita.json
#
# Ahaan, 2026-10-21: "the book … is here. Use it." The PDF's text layer is
# damaged in three ways, measured on his copy (a Zamzar conversion, 1338 pp):
#
#   1. Devanagari: conjuncts and vowel signs are gone — 2.13 extracts as
#      "दे हनोऽ मन्" for "देहिनोऽस्मिन्". Not repairable from the text, so the
#      Devanagari comes from the GPL dataset vedicscriptures/bhagavad-gita
#      instead, matched to each As It Is verse by its transliteration (below).
#   2. Diacritics: a combining mark is followed by a stray space — "Kṛ ṣṇa",
#      "Mā yā vā dı̄" — and ī is sometimes a dotless ı plus a macron.
#   3. Ligatures: the f of fi/fl/ff became a space — "con irmed", "re lection".
#
# 2 and 3 are repaired against a vocabulary: Prabhupada's own purports from the
# same dataset (the "prabhu" field — its wording is unreliable in places, but
# its spelling is his), plus the words this PDF itself spells cleanly. A split
# is joined only when the joined word is in that vocabulary and the split one
# is not, so "yogī is" stays two words while "Droṇ a" becomes one.
#
# The transliteration, synonyms and translation come through the PDF intact
# apart from 2 and 3; they are the As It Is text, with its merged verses
# (TEXTS 16–18) as printed.
#
# The text is the BBT's copyright: this writes under ~/.local/share, which
# backup_configs.sh does not mirror, and never into this repo.

import collections
import difflib
import io
import json
import os
import re
import subprocess
import sys
import tarfile
import unicodedata
import urllib.request
from datetime import date

HOME = os.path.expanduser("~")
CACHE = os.path.join(os.environ.get("XDG_CACHE_HOME") or HOME + "/.cache", "hyprahaan/gita")
OUT = os.path.join(os.environ.get("XDG_DATA_HOME") or HOME + "/.local/share", "hyprahaan/gita.json")
# Everything extracted (Devanagari, synonyms, purports), which the reader does
# not show. OUT holds only what a page draws: the reader parses it on open,
# and at 2 MB with all of this in it that parse was part of a slow first open.
FULL = OUT.replace("gita.json", "gita-full.json")
# Synonyms and purports by text id, for the reader's S and P keys. Read only
# when one of those is first pressed (Ahaan: "The file for this can be read
# only when it is called by me via the bind in the panel").
EXTRAS = OUT.replace("gita.json", "gita-extras.json")
DATASET = "https://codeload.github.com/vedicscriptures/bhagavad-gita/tar.gz/refs/heads/main"

# The As It Is chapter titles. The PDF's chapter openings did not survive
# extraction as text, and these are fixed.
TITLES = [
    "Observing the Armies on the Battlefield of Kurukṣetra",
    "Contents of the Gītā Summarized",
    "Karma-yoga",
    "Transcendental Knowledge",
    "Karma-yoga — Action in Kṛṣṇa Consciousness",
    "Dhyāna-yoga",
    "Knowledge of the Absolute",
    "Attaining the Supreme",
    "The Most Confidential Knowledge",
    "The Opulence of the Absolute",
    "The Universal Form",
    "Devotional Service",
    "Nature, the Enjoyer and Consciousness",
    "The Three Modes of Material Nature",
    "The Yoga of the Supreme Person",
    "The Divine and Demoniac Natures",
    "The Divisions of Faith",
    "Conclusion — The Perfection of Renunciation",
]

DEV = re.compile(r"[ऀ-ॿ]")
MARK = re.compile(r"(?m)^\f?\s*TEXTS?\s+(\d+)(?:\s*[–-]\s*(\d+))?\s*$")


# ── the dataset: Devanagari, and the vocabulary ──────────────────────────
def dataset():
    """{(chapter, verse): {...}} from the cached tarball, fetched once."""
    os.makedirs(CACHE, exist_ok=True)
    tgz = os.path.join(CACHE, "vedicscriptures-bhagavad-gita.tar.gz")
    if not os.path.exists(tgz):
        print("fetching the Devanagari dataset (one request)…", flush=True)
        with urllib.request.urlopen(DATASET, timeout=120) as r:
            body = r.read()
        with open(tgz + ".part", "wb") as f:
            f.write(body)
        os.replace(tgz + ".part", tgz)
    out = {}
    with tarfile.open(tgz) as t:
        for m in t.getmembers():
            if "/slok/" not in m.name or not m.name.endswith(".json"):
                continue
            d = json.load(io.TextIOWrapper(t.extractfile(m), encoding="utf-8"))
            out[(int(d["chapter"]), int(d["verse"]))] = d
    return out


def nfc(s):
    return unicodedata.normalize("NFC", s.replace("ı̄", "ī").replace("ı̄", "ī"))


def words(s):
    return re.findall(r"[^\W\d_]+", nfc(s))


def vocabulary(ds, pdf_text):
    """(clean, full). clean is Prabhupada's purports from the dataset plus a
    system word list; full adds the words this PDF spells cleanly. The
    ligature repair must use clean only: the PDF's own words include its
    broken fragments ("irmed" is common enough to look like a word), and with
    those counted "con irmed" read as two good words and was left alone."""
    clean = collections.Counter()
    for d in ds.values():
        p = d.get("prabhu") or {}
        for w in words((p.get("et") or "") + " " + (p.get("ec") or "")):
            clean[w.lower()] += 1
    for wl in ("/usr/share/dict/words", "/usr/share/dict/cracklib-small"):
        if os.path.exists(wl):
            for w in open(wl, encoding="utf-8", errors="ignore"):
                clean[w.strip().lower()] += 1
    full = collections.Counter(clean)
    pdf = collections.Counter(w.lower() for w in re.findall(r"[^\W\d_]+", pdf_text)
                              if not any(unicodedata.combining(c) for c in w))
    for w, n in pdf.items():
        if n >= 3:
            full[w] += n
    # For 2b's joined word only: every word as the PDF spells it, normalised.
    # "Pṛthā" is there 23 times unsplit but decomposed, which the filter
    # above (rightly, for the pieces) leaves out.
    whole = collections.Counter(w.lower() for w in words(pdf_text))
    # Word pairs in Prabhupada's purports, for 3b.
    pairs = collections.Counter()
    for d in ds.values():
        p = d.get("prabhu") or {}
        ws = [w.lower() for w in words((p.get("et") or "") + " " + (p.get("ec") or ""))]
        pairs.update(zip(ws, ws[1:]))
    return clean, full, whole, pairs


# ── repairing the PDF's English and transliteration ──────────────────────
# The fi/fl/ff ligatures extract as a space where the "f" was: "con irmed"
# is con·f·irmed, "the ield" the f·ield. So the repair puts back an f.
LIGS = ["f", "ff"]


def repair(s, vocab):
    s = s.replace("ı̄", "ī")

    clean, full, whole, pairs = vocab

    def known(w):
        return full.get(nfc(w).lower(), 0) > 0

    def good(w):
        return clean.get(nfc(w).lower(), 0) > 0

    # A token's punctuation, word, punctuation. Combining marks are word, not
    # punctuation: as \W they were stripped off "Pr̥" and "thā", which then
    # read as "Pr" and "tha" — both fragments common enough to look like
    # words — and "Pṛ thā" was never joined.
    def core(tok):
        m = re.match(r"^([^\ẁ-ͯ]*)(.*?)([^\ẁ-ͯ]*)$", tok, re.S)
        return m.groups()

    toks = s.split(" ")
    out = []
    i = 0
    while i < len(toks):
        t = toks[i]
        # 2. a combining mark, then a stray space: join while the join is a
        # word and the pieces are not.
        while i + 1 < len(toks) and t and unicodedata.combining(t[-1]):
            nxt = toks[i + 1]
            pre, a, _ = core(t)
            _, b, post = core(nxt)
            if b and (known(a + b) or not (known(a) and known(b))):
                t = t + nxt
                i += 1
            else:
                break
        # 2b. the same split where the marked letter is precomposed ("Dhṛ tarā
        # ṣṭra", ṛ as U+1E5B). The rule above cannot be widened to these:
        # tried, it joined 1,255 ordinary pairs ("yukta āsīta"), because most
        # romanised Sanskrit is in no vocabulary and so "neither piece is a
        # word" is true of nearly every pair. Here the JOIN must be a known
        # word, over up to three pieces.
        if t == toks[i] and i + 1 < len(toks):
            for n in (3, 2):
                parts = toks[i:i + n]
                if len(parts) < n or not all(core(x)[1] for x in parts):
                    continue
                if not any(unicodedata.combining(c) for x in parts for c in unicodedata.normalize("NFD", x)):
                    continue
                joined = "".join(parts)
                # Pieces judged by the clean vocabulary: the PDF's own counts
                # include its fragments ("Kurukṣ", "etra" are both common).
                jw = nfc(core(joined)[1]).lower()
                if (known(jw) or whole.get(jw, 0) >= 3) and not all(good(core(x)[1]) for x in parts):
                    t = joined
                    i += n - 1
                    break
        out.append(t)
        i += 1
    toks = out

    # 3. a dropped ligature, mid-word ("con irmed") or word-initial ("the
    # ield"); and 4. an initial Ś lost to S ("Srī" for "Śrī").
    out = []
    i = 0
    while i < len(toks):
        pre, a, post = core(toks[i])
        if i + 1 < len(toks) and a and not post:
            _, b, post2 = core(toks[i + 1])
            if b and not (good(a) and good(b)):
                lig = next((g for g in LIGS if good(a + g + b)), None)
                if lig:
                    out.append(pre + a + lig + b + post2)
                    i += 2
                    continue
        if a and not good(a):
            lig = next((g for g in LIGS if a[0].islower() and good(g + a)), None)
            if lig:
                a = lig + a
            elif a[0] == "S" and good("Ś" + a[1:]):
                a = "Ś" + a[1:]
        out.append(pre + a + post)
        i += 1
    # 3b. a lost f that leaves another real word: "lotus lower" (11.15) for
    # "lotus flower". No word check sees it, so this is by pairs: the f goes
    # back only where Prabhupada writes "lotus flower" and never "lotus lower".
    for k in range(1, len(out)):
        _, a, pa = core(out[k - 1])
        pre, b, post = core(out[k])
        if not a or not b or pa or not b[0].islower():
            continue
        al, bl = nfc(a).lower(), nfc(b).lower()
        if pairs.get((al, "f" + bl), 0) >= 2 and pairs.get((al, bl), 0) == 0:
            out[k] = pre + "f" + b + post
    s = " ".join(out)
    s = re.sub(r" ([.,;:!?)’”])", r"\1", s)     # "Paramā tmā ." -> "Paramātmā."
    return nfc(s)


# ── the verse blocks ──────────────────────────────────────────────────────
def squash(s):
    return re.sub(r"\s+", "", s).upper()


def blocks(text):
    """[(chapter, first, last, body)] in book order."""
    ends = [m.end() for m in re.finditer(r"Thus end the Bhaktivedanta Purports to the", text)]
    marks = list(MARK.finditer(text))
    out = []
    ch, last = 1, 0
    for k, m in enumerate(marks):
        first = int(m.group(1))
        lastv = int(m.group(2) or first)
        # A chapter ends at its "Thus end" line; a verse number that goes
        # back down is the next chapter.
        if first <= last:
            ch += 1
        last = lastv
        stop = marks[k + 1].start() if k + 1 < len(marks) else len(text)
        # The chapter's last purport stops at its "Thus end" line.
        stop = min([stop] + [e - len("Thus end the Bhaktivedanta Purports to the") for e in ends if m.end() < e <= stop])
        out.append((ch, first, lastv, text[m.end():stop]))
    return out


def split(body):
    """roman, synonyms, translation, purport lines from one verse block."""
    lines = [ln.replace("\f", "").rstrip() for ln in body.split("\n")]
    sec, roman, syn, tr, pp = "roman", [], [], [], []
    for ln in lines:
        q = squash(ln)
        if q == "TRANSLATION":
            sec = "tr"; continue
        if q == "PURPORT":
            sec = "pp"; continue
        if sec == "roman":
            if DEV.search(ln) or not ln.strip():
                continue
            # Synonyms start at the first "word – meaning" line.
            if " – " in ln or ln.strip().startswith("–"):
                sec = "syn"
            else:
                roman.append(ln.strip()); continue
        (syn if sec == "syn" else tr if sec == "tr" else pp).append(ln)
    return roman, syn, tr, pp


def flow(lines):
    """Wrapped lines back into running text. A line ending in a hyphen is a
    compound broken at the margin ("śastra-" / "sampāte"): no space after it."""
    out = ""
    for ln in (x.strip() for x in lines):
        if ln:
            out += ("" if not out or out.endswith("-") else " ") + ln
    return out


def paragraphs(lines):
    """Rejoin a purport's wrapped lines. A paragraph ends at a line that is
    short and ends a sentence; a page break inside one is only a blank line."""
    paras, cur = [], []
    for ln in lines:
        s = ln.strip()
        if not s:
            continue
        cur.append(s)
        if len(s) < 52 and re.search(r"[.?!:”’)]$", s):
            paras.append(flow(cur)); cur = []
    if cur:
        paras.append(flow(cur))
    return paras


# ── Devanagari by transliteration ─────────────────────────────────────────
def key(roman):
    s = roman.replace(".a", "").replace("’", "").replace("'", "")
    s = unicodedata.normalize("NFD", s)
    s = "".join(c for c in s if not unicodedata.combining(c))
    return re.sub(r"[^a-z]", "", s.lower())


DIGITS = str.maketrans("0123456789", "०१२३४५६७८९")


# Devanagari to the same folded Latin key(), for matching only — so a
# Devanagari line is matched by what it says, not by the dataset's own
# transliteration, whose lines do not correspond to its Devanagari lines (its
# 1.21 transliteration runs "hṛṣīkeśaṃ … arjuna uvāca senay…" as one line).
_V = dict(zip("अआइईउऊऋॠऌएऐओऔ", ["a", "a", "i", "i", "u", "u", "r", "r", "l", "e", "ai", "o", "au"]))
_M = dict(zip("ािीुूृॄेैोौ", ["a", "i", "i", "u", "u", "r", "r", "e", "ai", "o", "au"]))
_C = dict(zip("कखगघङचछजझञटठडढणतथदधनपफबभमयरलवशषसहळ",
              "k kh g gh n c ch j jh n t th d dh n t th d dh n p ph b bh m y r l v s s s h l".split()))


def devkey(s):
    out, i = [], 0
    while i < len(s):
        c = s[i]
        if c in _C:
            out.append(_C[c])
            nx = s[i + 1] if i + 1 < len(s) else ""
            if nx == "़":                      # nukta
                i += 1; nx = s[i + 1] if i + 1 < len(s) else ""
            if nx in _M:
                out.append(_M[nx]); i += 1
            elif nx == "्":                    # virama
                i += 1
            else:
                out.append("a")
        elif c in _V:
            out.append(_V[c])
        elif c in "ंँ":
            out.append("m")
        elif c == "ः":
            out.append("h")
        i += 1
    return "".join(out)


def units(ds, ch):
    """The chapter's Devanagari as a run of [key, [line]], one per line, in
    order. Lines, not verses, because As It Is draws some verse boundaries
    mid-verse: the dataset's 1.21 opens with the last line of As It Is 1.20,
    and from there chapter 1 never lines up verse-for-verse again. The
    colophon is left out."""
    out = []
    for v in sorted(v for (c, v) in ds if c == ch):
        d = ds[(ch, v)]
        # "oṁ tat sad iti śrīmad-bhagavad-gītāsu…" — not 17.23, which also
        # opens "oṁ tat sad iti".
        if key(d.get("transliteration", "")).startswith("omtatsaditisrimad"):
            continue
        s = re.sub(r"\|\|\s*[\d०-९]+[-–][\d०-९]+\s*\|\|", "", d["slok"].strip())
        # Editorial variants carried inline: "…संशयः (orसंशयम्)".
        s = re.sub(r"\s*\(or[^)]*\)", "", s)
        s = s.replace("||", "॥").replace("|", "।")
        out += [[devkey(ln), [ln.strip()]] for ln in s.split("\n") if ln.strip()]
    return out


def take(run, p, k):
    """Consume units from run[p] that spell out key k (one As It Is verse).
    Returns (lines, next p, similarity)."""
    if p >= len(run):
        return [], p, 0.0
    # Resync: the start that best matches the verse's opening, a unit either
    # side of where the last verse ended.
    head = k[:16]
    p = max(range(max(0, p - 2), min(len(run), p + 5)),
            key=lambda j: difflib.SequenceMatcher(None, head, run[j][0][:16]).ratio())
    # Then as many units as make the closest match: grow to well past the
    # verse's length and keep the best. (Stopping at the length cut 1.20 a
    # line short, and every verse after it in the chapter started wrong.)
    acc, lines, j = "", [], p
    best = ([], p, 0.0)
    while j < len(run) and len(acc) < len(k) * 1.4:
        acc += run[j][0]
        lines = lines + run[j][1]
        j += 1
        r = difflib.SequenceMatcher(None, k, acc).ratio()
        if r > best[2]:
            best = (lines, j, r)
    return best


# ── who is speaking ──────────────────────────────────────────────────────
# Ahaan, 2026-10-21: "clear distinction from the actual text and the 'arjuna
# said' thing". The speaker is lifted out of both the romanised verse (its
# "arjuna uvāca" line) and the translation (its "Arjuna said:"), and the page
# draws it as a label of its own. A merged text can change speaker partway
# (13.1-2: Arjuna asks, Kṛṣṇa answers), so both come out as parts.
# "Arjuna said:", "Arjuna inquired:", "The Personality of Godhead replied:",
# "Sañjaya said to Dhṛtarāṣṭra:". `who` keeps the whole phrase, verb and all,
# so the label reads as the book does.
SAID = re.compile(r"(?:^|(?<=[.?!”’]\s))(([A-ZŚ][^.:;?!“”]{0,80}?),? (?:said|inquired|replied|asked)"
                  r"(?: to [A-ZŚ][^.:;?!]{0,30})?):\s*")


def tr_parts(tr):
    """[{who, t}] — who is "" where no one is named (most verses)."""
    out, who, last = [], "", 0
    for m in SAID.finditer(tr):
        # A speaker is a name or a title, never a clause: 11.51 opens "When
        # Arjuna thus saw Kṛṣṇa in His original form, he said:", which is
        # narration and stays in the text.
        if len(m.group(2).split()) > 7:
            continue
        seg = tr[last:m.start()].strip()
        if seg:
            out.append({"who": who, "t": seg})
        who, last = m.group(1).replace(", said", " said").strip(), m.end()
    out.append({"who": who, "t": tr[last:].strip()})
    return [x for x in out if x["t"]]


# The speakers, by the verse's own "… uvāca" line. The book names a speaker
# only where the speaker changes; every verse after it is theirs until the
# next one. So the speaker is carried forward through the whole book, and
# every page gets its label — not only the ~50 that name one (Ahaan: "The
# speaker labels is only on 13(1-2). No other place has it").
SPEAKERS = {"śrī-bhagavān": "Śrī Kṛṣṇa", "arjuna": "Arjuna",
            "sañjaya": "Sañjaya", "dhṛtarāṣṭra": "Dhṛtarāṣṭra"}


def roman_parts(rom, current):
    """([{who, t}], speaker after this verse). The verse split at each
    "… uvāca" line; the part before the first one is `current`'s."""
    out, cur, who = [], [], current
    for ln in rom.split("\n"):
        m = re.match(r"^\s*(\S+)\s+uvāca\s*$", ln)
        if m:
            if cur:
                out.append({"who": who, "t": "\n".join(cur)}); cur = []
            who = SPEAKERS.get(m.group(1), m.group(1).capitalize())
            continue
        cur.append(ln)
    if cur:
        out.append({"who": who, "t": "\n".join(cur)})
    return out, who


def lean_verse(v, current):
    """The reader's record for one text, and the speaker after it. The
    translation's own "X said:" is cut out (tr_parts) and its parts take the
    verse's speakers; a translation that does not split the way the verse
    does keeps one part, under the verse's first speaker."""
    roman, after = roman_parts(v["roman"], current)
    tr = tr_parts(v["tr"])
    if len(tr) == len(roman):
        tr = [{"who": r["who"], "t": t["t"]} for r, t in zip(roman, tr)]
    else:
        tr = [{"who": roman[0]["who"] if roman else current, "t": " ".join(t["t"] for t in tr)}]
    return {"id": v["id"], "n": v["n"], "roman": roman, "tr": tr}, after


def main():
    if len(sys.argv) < 2:
        raise SystemExit("usage: gita-from-pdf.py <Bhagavad-gita As It Is.pdf>")
    raw = subprocess.run(["pdftotext", sys.argv[1], "-"], check=True,
                         capture_output=True).stdout.decode("utf-8")
    start = MARK.search(raw).start()
    stop = [m.end() for m in re.finditer(r"Thus end the Bhaktivedanta Purports to the[^\n]*\n[^\n]*", raw)]
    text = raw[start:stop[-1]] if len(stop) >= 18 else raw[start:]

    ds = dataset()
    vocab = vocabulary(ds, raw)
    runs = {ch: units(ds, ch) for ch in range(1, 19)}
    pos = collections.Counter()

    chapters = [{"n": n + 1, "title": TITLES[n], "verses": []} for n in range(18)]
    weak = []
    for ch, first, last, body in blocks(text):
        if ch > 18:
            break
        roman, syn, tr, pp = split(body)
        rom = repair("\n".join(roman), vocab)
        nid = f"{first}" if first == last else f"{first}-{last}"
        # The verse's Devanagari: the dataset's lines, in order, that spell
        # out this verse's transliteration. A poor match is left blank rather
        # than shown beside the wrong verse.
        lines, pos[ch], score = take(runs[ch], pos[ch], key(rom))
        dev = ""
        if lines and score >= 0.8:
            dev = "\n".join(lines).rstrip(" ।॥") + " ॥ " + nid.replace("-", "–").translate(DIGITS) + " ॥"
        else:
            weak.append(f"{ch}.{nid} ({score:.2f})")
        chapters[ch - 1]["verses"].append({
            "id": f"{ch}.{nid}", "n": nid, "dev": dev, "roman": rom,
            "syn": repair(flow(syn), vocab),
            "tr": repair(flow(tr), vocab),
            "pp": [{"t": repair(p, vocab), "q": False} for p in paragraphs(pp)],
        })

    # Every chapter's verses must run on without a gap: a missing marker would
    # show here as a jump.
    gaps = []
    for c in chapters:
        expect = 1
        for v in c["verses"]:
            f = int(v["n"].split("-")[0])
            if f != expect:
                gaps.append(f"{c['n']}: expected {expect}, got {v['n']}")
            expect = int(v["n"].split("-")[-1]) + 1
        c["count"] = len(c["verses"])

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    source = ("Bhagavad-gītā As It Is (© BBT), from " + os.path.basename(sys.argv[1])
              + "; Devanagari from vedicscriptures/bhagavad-gita (GPL-3.0)")
    lean, speaker = [], ""
    for c in chapters:
        verses = []
        for v in c["verses"]:
            rec, speaker = lean_verse(v, speaker)
            verses.append(rec)
        lean.append({"n": c["n"], "title": c["title"], "count": c["count"], "verses": verses})
    extras = {v["id"]: {"syn": v["syn"], "pp": [p["t"] for p in v["pp"]]}
              for c in chapters for v in c["verses"]}
    with open(EXTRAS + ".part", "w", encoding="utf-8") as f:
        json.dump(extras, f, ensure_ascii=False, separators=(",", ":"))
    os.replace(EXTRAS + ".part", EXTRAS)
    for path, body in ((FULL, chapters), (OUT, lean)):
        with open(path + ".part", "w", encoding="utf-8") as f:
            json.dump({"source": source, "built": date.today().isoformat(), "chapters": body},
                      f, ensure_ascii=False, separators=(",", ":"))
        os.replace(path + ".part", path)
    n = sum(c["count"] for c in chapters)
    print(f"wrote {OUT}: 18 chapters, {n} texts")
    if gaps:
        print("numbering gaps:", *gaps, sep="\n  ")
    if weak:
        print("no confident Devanagari match:", " ".join(weak))


if __name__ == "__main__":
    main()
