"""policy.py — what EVE's advanced mode may touch, as code (2026-10-26).

Every rule broker.py enforces lives here, with no I/O beyond stat/reading a
file's first bytes, so the whole set can be exercised offline
(`python3 policy.py selftest`) before anything is wired to Claude. The model's
prompt describes these rules; this file is what makes them true. A confused
or manipulated model can ask for anything — it gets what this file allows.

Ahaan's rules (eve-upgrade.txt, 2026-10-26), and where each one lands:

  - file NAMES may be searched freely; CONTENTS only after a yes, per file
    (read_ok + the broker's approval card)
  - encrypted files are never read, even after a yes, even if asked
    directly (encrypted(): by name, by place, by magic bytes, by `file`)
  - writes only when he asked for one, only under ~/projects, each shown as
    a diff and approved (write_ok + asked_to_write)
  - shell commands only from a read-only allowlist, never through a shell
    (run_ok); anything else is refused, not asked — a stream of prompts is
    how a yes stops being read
  - root only through the four things the settings menu already does, and
    only with his password typed into the shell's own box (broker.py)

2026-11-03, one mode and a sandbox (Ahaan: "I dont want env files and any
other secretish stuff to even have a chance of leakage ... move eves working
dir from ~/projects to ~/EVE ... If eve wants to read/edit/write stuff
outside ~/EVE then it asks me for permission"):

  - ~/EVE is EVE's own folder: read, search and write there need no yes
    (in_eve). Everything else under home asks, per file or per folder.
  - secrets are refused before any yes, by name, place AND content: a file
    holding a private key is never read; any other secret-looking value
    (tokens, API keys, `password = …`, user:pass@ in a URL) is replaced by
    «redacted» in whatever reaches Claude — file text, search hits, command
    output, attachments (redact()).
  - hidden paths outside ~/EVE are refused except under ~/.config, so caches,
    shell history and app state never come up; ~/.config is still filtered
    by SECRET_DIRS.
"""
import os
import re
import stat
import subprocess
import sys
from pathlib import Path

HOME = Path.home()
PROJECTS = HOME / "projects"
# EVE's own folder: Claude's working directory, and where reads and writes
# need no yes. Relative paths are taken from here.
EVE_HOME = HOME / "EVE"

# ── never read, whatever the answer ─────────────────────────────────────
# Places whose contents are credentials or keys. Matched on the RESOLVED
# path and on the path as given, so a symlink in ~/projects pointing at
# ~/.ssh is still ~/.ssh.
SECRET_DIRS = [
    ".ssh", ".gnupg", ".password-store", ".local/share/keyrings", ".pki",
    ".aws", ".azure", ".kube", ".docker", ".config/gcloud", ".config/gh",
    ".config/rclone", ".config/op", ".config/Bitwarden", ".local/share/Cryptomator",
    ".mozilla", ".zen", ".librewolf", ".config/chromium", ".config/google-chrome",
    ".config/BraveSoftware", ".config/vivaldi", ".config/Signal", ".config/discord",
    ".claude", ".claude-avi", ".codex", ".local/share/fprint", ".cert",
    # 2026-11-03: more app state that holds sessions or keys.
    ".config/keepassxc", ".config/1Password", ".config/Proton", ".config/protonvpn",
    ".config/Slack", ".config/Element", ".config/teams-for-linux", ".config/spotify",
    ".config/obsidian", ".config/Code/User/globalStorage", ".config/VSCodium/User/globalStorage",
    ".config/github-copilot", ".config/hub", ".config/netlify", ".config/vercel", ".config/heroku",
    ".config/doctl", ".config/stripe", ".config/syncthing", ".config/wireguard", ".config/NetworkManager",
    ".config/evolution", ".config/goa-1.0", ".config/kdewallet", ".thunderbird", ".local/share/TelegramDesktop",
    ".local/share/password-store", ".local/share/kwalletd", ".terraform.d", ".vault-token", ".cargo/credentials",
    ".cargo/credentials.toml", ".config/hypr/secrets", ".config/scripts/secrets",
]
SECRET_FILES = {
    ".netrc", ".git-credentials", ".pgpass", ".my.cnf", ".npmrc", ".pypirc",
    ".claude.json", ".Xauthority", ".ICEauthority", ".bash_history", ".zsh_history",
    ".python_history", ".lesshst", ".viminfo",
    ".vault-token", ".s3cfg", ".boto", ".dockercfg", ".htpasswd", ".zsh_history.bak",
    "authorized_keys", "known_hosts", "wp-config.php",
}
# By name, anywhere. Keys, vaults, encrypted containers, and the dotenv family.
SECRET_NAME = re.compile(
    r"(^id_(rsa|dsa|ecdsa|ed25519)(_sk)?$|^\.env(\..*)?$|\.(gpg|pgp|asc|age|kdbx?|p12|pfx|pem|key|keystore|jks|"
    r"enc|aes|crypt|vc|hc|tc|luks|ppk|ovpn|sig|keychain|wallet)$|^(secrets?|credentials?)(\.[a-z]+)?$|"
    r"(^|[._-])(token|tokens|secret|secrets|passwords?|passwd|api[_-]?keys?|apikey|private|credentials?|"
    r"service[_-]?account|oauth|cookies?|session[_-]?keys?)([._-]|$)|^\.?htpasswd$|\.(env|envrc)$|^\.envrc$)", re.I)

# ── secret-looking text ─────────────────────────────────────────────────
# Content, not names: a key pasted into notes.md is as secret as id_rsa.
# PRIVATE_KEY anywhere in a file refuses the whole read (there is no useful
# part of a key file to show); the rest is replaced value by value, so a
# config can still be read with its passwords taken out.
PRIVATE_KEY = re.compile(r"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?-----|-----BEGIN PGP PRIVATE KEY BLOCK-----"
                         r"|PuTTY-User-Key-File-|-----BEGIN OPENSSH PRIVATE KEY-----")
TOKENS = re.compile(
    r"\b(?:sk-ant-[\w-]{16,}|sk-(?:proj-)?[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}"
    r"|glpat-[\w-]{20,}|xox[abposr]-[\w-]{10,}|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}"
    r"|ya29\.[\w-]{20,}|sk_live_[\w]{20,}|rk_live_[\w]{20,}|pk_live_[\w]{20,}|SG\.[\w-]{20,}\.[\w-]{20,}"
    r"|npm_[A-Za-z0-9]{30,}|pypi-[\w-]{30,}|hf_[A-Za-z0-9]{30,}|dop_v1_[a-f0-9]{40,}|shpat_[a-f0-9]{30,}"
    r"|eyJ[\w-]{10,}\.eyJ[\w-]{10,}\.[\w-]{10,}"
    # A bare high-entropy run: 32+ of base64's letters with all of upper,
    # lower and a digit in it. No "/" (long paths matched) and no hex-only
    # (a git SHA has no capitals).
    r"|(?<![\w/.-])(?=[A-Za-z0-9+_-]*\d)(?=[A-Za-z0-9+_-]*[A-Z])(?=[A-Za-z0-9+_-]*[a-z])[A-Za-z0-9+_-]{32,}={0,2}(?![\w/.-])"
    r")")
# key = value, key: value, KEY="value", --key value: the value goes.
ASSIGN = re.compile(
    r"(?i)((?:[\w.-]*?)(?:pass(?:word|wd|phrase)?|pwd|secret|token|api[_-]?key|apikey|auth(?:[_-]?key|[_-]?token)?"
    r"|private[_-]?key|access[_-]?key|client[_-]?secret|credentials?|cookie|session[_-]?id|bearer)[\w.-]*"
    r"[\"']?\s*(?:[=:]|\s-?-?>)\s*[\"']?|(?:--?(?:password|token|secret|api-key|key)[= ]))([^\s\"',;#]{3,})")
AUTH_HDR = re.compile(r"(?i)\b(authorization|x-api-key|api-key)(\s*[:=]\s*)(bearer\s+|basic\s+|token\s+)?(\S+)")
URL_CRED = re.compile(r"(\b[a-z][\w+.-]*://)([^/\s:@]+):([^/\s@]+)@", re.I)
HIDE = "«redacted»"


def has_private_key(text):
    return bool(PRIVATE_KEY.search(text or ""))


def redact(text):
    """-> (text with secret-looking values replaced, how many). Errs toward
    redacting: a false hit costs one word of a reply, a miss costs a key."""
    if not text:
        return text, 0
    n = 0

    def sub(rx, fn, t):
        nonlocal n
        def f(m):
            nonlocal n
            n += 1
            return fn(m)
        return rx.sub(f, t)
    t = sub(URL_CRED, lambda m: m.group(1) + m.group(2) + ":" + HIDE + "@", text)
    t = sub(AUTH_HDR, lambda m: m.group(1) + m.group(2) + (m.group(3) or "") + HIDE, t)
    t = sub(ASSIGN, lambda m: m.group(1) + HIDE, t)
    t = sub(TOKENS, lambda m: HIDE, t)
    return t, n
# What `file -b` says about something encrypted or key-like. Lower-cased.
FILE_SAYS = re.compile(r"encrypted|pgp|gpg|luks|keepass|private key|age encrypted|openssh|"
                       r"cdfv2 encrypted|veracrypt|truecrypt|password", re.I)
# Leading bytes of the formats `file` can miss or a renamed file would hide.
MAGIC = [b"-----BEGIN PGP", b"-----BEGIN AGE", b"age-encryption.org/v1", b"LUKS\xba\xbe",
         b"-----BEGIN ENCRYPTED", b"-----BEGIN OPENSSH PRIVATE", b"-----BEGIN RSA PRIVATE",
         b"-----BEGIN EC PRIVATE", b"-----BEGIN DSA PRIVATE", b"-----BEGIN PRIVATE KEY",
         b"\x03\xd9\xa2\x9a",  # KeePass 2
         b"Salted__"]          # openssl enc


def _rel(p):
    try:
        return p.relative_to(HOME)
    except ValueError:
        return None


def _in_secret_place(p):
    r = _rel(p)
    if r is None:
        return False
    s = r.as_posix()
    if r.name in SECRET_FILES or (len(r.parts) == 1 and r.parts[0] in SECRET_FILES):
        return True
    return any(s == d or s.startswith(d + "/") for d in SECRET_DIRS)


def _magic_says_encrypted(p):
    try:
        with open(p, "rb") as f:
            head = f.read(4096)
    except OSError:
        return False
    if any(m in head[:64] for m in MAGIC) or any(m in head for m in MAGIC[:2]):
        return True
    # A zip whose first entry has the encryption bit (general purpose flag
    # bit 0) — docx/xlsx/odt are zips too, and an encrypted one is CDFV2,
    # which `file` names below.
    if head[:4] == b"PK\x03\x04" and len(head) > 7 and head[6] & 1:
        return True
    if head[:6] == b"7z\xbc\xaf\x27\x1c":
        return True        # 7z: the header may itself be encrypted; not worth guessing
    if head[:5] == b"%PDF-":
        try:
            with open(p, "rb") as f:
                f.seek(max(0, os.path.getsize(p) - 65536))
                if b"/Encrypt" in f.read():
                    return True
        except OSError:
            pass
    return False


def _file_says(p):
    try:
        out = subprocess.run(["file", "-b", "--", str(p)], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return out.strip()


def encrypted(p):
    """True for anything encrypted or secret: by name, by place, by content.
    Checked on the path as given AND resolved."""
    p = Path(p)
    for q in {p.absolute(), p.resolve()}:
        if SECRET_NAME.search(q.name) or _in_secret_place(q):
            return True
    if p.is_file():
        if _magic_says_encrypted(p):
            return True
        if FILE_SAYS.search(_file_says(p)):
            return True
    return False


def expand(path):
    return Path(os.path.expanduser(str(path).strip()))


def read_ok(path):
    """-> (Path, None) or (None, reason). A yes is still needed after this."""
    p = expand(path)
    if not p.is_absolute():
        p = EVE_HOME / p
    # The name and place are judged before existence, so asking for a key
    # that is not there gets the same answer as one that is.
    if SECRET_NAME.search(p.name) or _in_secret_place(p.absolute()):
        return None, "encrypted or secret — EVE never reads those"
    try:
        rp = p.resolve(strict=True)
    except (OSError, RuntimeError):
        return None, "no such file"
    if _rel(rp) is None and not str(rp).startswith(("/etc/", "/usr/share/doc/")):
        return None, "outside your home folder"
    if hidden_off(p.absolute()) or hidden_off(rp):
        return None, "hidden files outside ~/EVE and ~/.config are off limits (caches, history, app state)"
    if rp.is_dir():
        return None, "that is a folder; EVE reads files"
    if not rp.is_file():
        return None, "not a regular file"
    if encrypted(p) or encrypted(rp):
        return None, "encrypted or secret — EVE never reads those"
    if str(rp).startswith("/etc/") and (rp.name in ("shadow", "gshadow", "sudoers") or "ssl/private" in str(rp)):
        return None, "system secret"
    return rp, None


def in_eve(p):
    """Inside ~/EVE, as given AND resolved: a symlink in ~/EVE pointing out
    is outside."""
    p = expand(p)
    if not p.is_absolute():
        p = EVE_HOME / p
    try:
        p.absolute().relative_to(EVE_HOME)
        p.resolve().relative_to(EVE_HOME.resolve())
        return True
    except (ValueError, OSError, RuntimeError):
        return False


def hidden_off(p):
    """A hidden component outside ~/EVE, other than ~/.config/…"""
    r = _rel(Path(p))
    if r is None or not r.parts:
        return False
    if r.parts[0] == "EVE":
        return False
    parts = r.parts[1:] if r.parts[0] == ".config" else r.parts
    return any(x.startswith(".") for x in parts)


def readable_text(p, limit=200_000):
    """text_of plus the content rules: a private key refuses the read, any
    other secret-looking value is redacted. -> (text, None, n) or
    (None, why, 0)."""
    t, why = text_of(p, limit)
    if t is None:
        return None, why, 0
    if has_private_key(t):
        return None, "it holds a private key — EVE never reads those", 0
    t, n = redact(t)
    return t, None, n


def text_of(p, limit=200_000):
    """The readable text of a file, or (None, why). PDFs through pdftotext."""
    try:
        size = p.stat().st_size
    except OSError as e:
        return None, str(e)
    if p.suffix.lower() == ".pdf":
        try:
            out = subprocess.run(["pdftotext", "-layout", "-l", "60", str(p), "-"],
                                 capture_output=True, text=True, timeout=30).stdout
        except (OSError, subprocess.TimeoutExpired):
            return None, "pdftotext is not available"
        return out[:limit], None
    if size > 5_000_000:
        return None, "larger than 5 MB"
    data = p.read_bytes()[: limit * 2]
    if b"\x00" in data[:8192]:
        return None, "not a text file"
    return data.decode("utf-8", errors="replace")[:limit], None


# ── images ──────────────────────────────────────────────────────────────
# What Claude can be shown as a picture (2026-10-26): Ahaan asked EVE to open
# X, screenshot it and summarize the feed; it took the shot and then told him
# to go look himself, because read_file only knew text. An image is read the
# same way a text file is — read_ok, then a yes — and comes back as an image
# block. The API takes these four types; anything else (bmp, tiff, heic…)
# goes through magick to JPEG. Over IMG_MAX, or longer than IMG_EDGE on a
# side, it is shrunk: the API refuses a 5 MB image, and it scales anything
# past ~1568 px down itself, so the extra pixels would only cost upload time.
IMG_TYPES = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
             ".gif": "image/gif", ".webp": "image/webp"}
IMG_OTHER = {".bmp", ".tif", ".tiff", ".heic", ".heif", ".avif", ".jxl", ".ico", ".svg"}
IMG_MAX = 3_500_000
IMG_EDGE = 1920


def is_image(p):
    return Path(p).suffix.lower() in IMG_TYPES or Path(p).suffix.lower() in IMG_OTHER


def image_of(p):
    """-> ((bytes, mime), None) or (None, why)."""
    p = Path(p)
    mime = IMG_TYPES.get(p.suffix.lower())
    try:
        size = p.stat().st_size
    except OSError as e:
        return None, str(e)
    if size > 60_000_000:
        return None, "larger than 60 MB"
    if mime and size <= IMG_MAX:
        try:
            dims = subprocess.run(["magick", "identify", "-format", "%w %h", f"{p}[0]"],
                                  capture_output=True, text=True, timeout=15).stdout.split()
            small = len(dims) == 2 and max(map(int, dims)) <= IMG_EDGE
        except (OSError, subprocess.TimeoutExpired, ValueError):
            small = True        # can't measure: send it as it is
        if small:
            return (p.read_bytes(), mime), None
    # [0]: the first frame of a gif or the first page of a tiff.
    try:
        out = subprocess.run(["magick", f"{p}[0]", "-auto-orient", "-resize", f"{IMG_EDGE}x{IMG_EDGE}>",
                              "-quality", "85", "jpg:-"], capture_output=True, timeout=30).stdout
    except (OSError, subprocess.TimeoutExpired):
        return None, "could not convert the image (is imagemagick installed?)"
    if not out:
        return None, "could not read that image"
    return (out, "image/jpeg"), None


# ── writes ──────────────────────────────────────────────────────────────
# Only when the message this turn asks for one. The approval card is the
# real gate; this stops a write Claude decided on by itself from even
# reaching it.
WRITE_WORDS = re.compile(r"\b(write|edit|create|save|append|add|change|update|modify|fix|rewrite|"
                         r"put|make|note down|jot|insert|replace|rename|draft)\b", re.I)


def asked_to_write(said):
    return bool(WRITE_WORDS.search(said or ""))


def write_ok(path):
    """-> (Path, None) or (None, reason). Anywhere under home, nothing hidden,
    nothing secret, and an existing file must be text. In ~/EVE a missing
    folder is made (by the caller); outside it the folder must exist.
    Whether a yes is needed is the caller's: in_eve(p) says."""
    p = expand(path)
    if not p.is_absolute():
        p = EVE_HOME / p
    p = p.absolute()
    rel = _rel(p)
    if rel is None or not rel.parts:
        return None, "EVE only writes inside your home folder"
    if any(x.startswith(".") for x in rel.parts):
        return None, "hidden files and folders (.git, .env, ~/.config …) are off limits"
    if _in_secret_place(p) or SECRET_NAME.search(p.name):
        return None, "that name or place is reserved for secrets"
    eve = in_eve(p)
    # The nearest folder that exists must resolve to where the path says:
    # no symlinked folder leading somewhere else.
    anc = p.parent
    while not anc.exists() and anc != anc.parent:
        anc = anc.parent
    try:
        real = anc.resolve()
        if eve:
            real.relative_to(EVE_HOME.resolve())
        else:
            real.relative_to(HOME.resolve())
            if real != anc.absolute():
                return None, "that folder is a symlink to somewhere else"
    except (ValueError, OSError):
        return None, "that folder leads outside " + ("~/EVE" if eve else "your home folder")
    if not eve and not p.parent.is_dir():
        return None, "that folder does not exist (outside ~/EVE, EVE does not create folders)"
    if p.is_symlink():
        return None, "that is a symlink"
    if p.exists():
        if not p.is_file():
            return None, "not a regular file"
        if p.stat().st_mode & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH):
            return None, "an executable — EVE does not edit scripts or programs"
        if encrypted(p):
            return None, "encrypted or secret"
        txt, why = text_of(p)
        if txt is None or p.suffix.lower() == ".pdf":
            return None, why or "not a text file"
    elif SECRET_NAME.search(p.name):
        return None, "that name is reserved for secrets"
    return p, None


# ── commands ────────────────────────────────────────────────────────────
# argv only, never a shell: there is nothing to redirect, substitute or
# chain. Each entry checks the arguments, because most of these tools have
# a flag that writes (`ip link set`, `journalctl --vacuum-size`, `pacman -S`).
# Nothing that prints a file's contents is here — cat/head/grep/less are
# reads, and reads go through read_file and its yes.
def _flags_only(allowed):
    return lambda args: all(a in allowed for a in args)


def _subcmd(allowed, rest=lambda r: True):
    return lambda args: bool(args) and args[0] in allowed and rest(args[1:])


def _no_write_flags(bad):
    return lambda args: not any(a.split("=")[0] in bad for a in args)


def _plain(args):
    # a word, a path, a number, a flag: no glob, no ~ expansion surprises
    return all(re.fullmatch(r"[\w@%+=:,./~-]{1,200}", a) for a in args)


def _journal(args):
    bad = {"--vacuum-size", "--vacuum-time", "--vacuum-files", "--rotate", "--flush", "--sync",
           "--relinquish-var", "--smart-relinquish-var", "--setup-keys", "--update-catalog", "-o", "--output-fields"}
    if any(a.split("=")[0] in bad for a in args):
        return False
    # bounded: -n N up to 300, and -f would never return
    if "-f" in args or "--follow" in args:
        return False
    for i, a in enumerate(args):
        if a in ("-n", "--lines") and (i + 1 >= len(args) or not args[i + 1].isdigit() or int(args[i + 1]) > 300):
            return False
    return _plain(args)


def _hyprctl(args):
    read = {"clients", "monitors", "workspaces", "activewindow", "activeworkspace", "version",
            "devices", "layers", "binds", "cursorpos", "animations", "instances", "systeminfo", "-j"}
    return bool(args) and all(a in read for a in args)


def _pacman(args):
    if not args or not re.fullmatch(r"-(Q[a-z]*|Ss|Si|Sii|F[sly]?)", args[0]):
        return False
    return _plain(args[1:]) and not any(a.startswith("-") and re.search(r"[yuSRU]", a) for a in args[1:])


def _playerctl(args):
    # Reading only: list players, status, metadata; -p picks one. Playing
    # and pausing go through the music tool, which shows on the bar.
    i, verbs = 0, 0
    while i < len(args):
        a = args[i]
        if a in ("-p", "--player") and i + 1 < len(args) and re.fullmatch(r"[\w.-]+", args[i + 1]):
            i += 2
            continue
        if a in ("-l", "--list-all"):
            pass
        elif a in ("status", "metadata"):
            verbs += 1
        elif a.startswith("--format=") or (verbs and re.fullmatch(r"[\w:]+", a)):
            pass
        else:
            return False
        i += 1
    return True


def _ls(args):
    return _plain(args) and not any(_in_secret_place(expand(a).absolute()) for a in args if not a.startswith("-"))


ALLOW = {
    "uptime": _flags_only({"-p", "-s"}),
    "uname": _flags_only({"-a", "-r", "-m", "-n", "-s", "-v", "-o"}),
    "whoami": _flags_only(set()),
    "hostname": _flags_only(set()),
    "date": lambda a: _plain(a) and not any(x in ("-s", "--set") or x.startswith("--set") for x in a),
    "cal": _plain,
    "df": lambda a: _plain(a),
    "free": _flags_only({"-h", "-m", "-g", "-w", "--si"}),
    "lsblk": _flags_only({"-f", "-o", "-a", "-p", "-J", "NAME,SIZE,TYPE,MOUNTPOINTS", "NAME,SIZE,FSTYPE,MOUNTPOINTS"}),
    "lscpu": _flags_only(set()),
    "lsusb": _flags_only({"-t"}),
    "lspci": _flags_only({"-k", "-nn", "-v"}),
    "sensors": _flags_only(set()),
    "nvidia-smi": lambda a: all(x in ("-q", "-L") or x.startswith(("--query-gpu=", "--format=")) for x in a),
    "ps": _plain,
    "pgrep": _plain,
    "ip": _subcmd({"a", "addr", "address", "r", "route", "link", "-br", "-c", "neigh"},
                  lambda r: all(x in ("show", "-br", "-c", "a", "addr", "link", "route") or re.fullmatch(r"[\w.-]+", x)
                                and x not in ("set", "add", "del", "delete", "flush", "change", "replace") for x in r)),
    "ping": lambda a: _plain(a) and "-c" in a and a[a.index("-c") + 1:a.index("-c") + 2] and
                      a[a.index("-c") + 1].isdigit() and int(a[a.index("-c") + 1]) <= 5 and "-f" not in a,
    "nmcli": _subcmd({"general", "g", "device", "d", "connection", "c", "radio", "r"},
                     lambda r: all(x in ("status", "show", "list", "wifi", "all") for x in r[:1]) and len(r) <= 2
                     and not any(x in ("up", "down", "modify", "delete", "add", "on", "off", "connect", "disconnect") for x in r)),
    "wpctl": _subcmd({"status", "inspect", "get-volume"}, _plain),
    "playerctl": _playerctl,
    "bluetoothctl": _subcmd({"show", "devices", "info", "list"}, _plain),
    "systemctl": lambda a: _plain(a) and any(x in ("status", "list-units", "list-timers", "is-active", "is-enabled", "is-failed", "show", "list-unit-files", "--failed") for x in a)
                           and not any(x in ("start", "stop", "restart", "reload", "enable", "disable", "mask", "unmask", "kill", "edit", "set-property", "daemon-reload", "isolate", "reboot", "poweroff", "suspend", "hibernate") for x in a),
    "journalctl": _journal,
    "hyprctl": _hyprctl,
    "pacman": _pacman,
    "checkupdates": _flags_only(set()),
    "which": _plain,
    "ls": _ls,
    "du": lambda a: _ls(a) and all(x in ("-h", "-s", "-sh", "-hs", "-d1", "--max-depth=1", "-c") or not x.startswith("-") for x in a),
    "stat": _ls,
    "tree": lambda a: _ls(a) and "-o" not in a,
    "fastfetch": _flags_only(set()),
    "powerprofilesctl": _subcmd({"get", "list"}),
    "timedatectl": lambda a: a in ([], ["status"]),
    "loginctl": lambda a: a in ([], ["list-sessions"], ["session-status"]),
    "fc-list": _plain,
    "acpi": _flags_only({"-b", "-V", "-i"}),
    "upower": lambda a: a[:1] in (["-e"], ["-d"], ["-i"]) and _plain(a),
    "brightnessctl": lambda a: all(x in ("get", "max", "info", "-l", "-m") for x in a),
}


def run_ok(argv):
    """-> (argv, None) or (None, reason)."""
    if not isinstance(argv, list) or not argv or not all(isinstance(a, str) for a in argv):
        return None, "give the command as a list of words"
    if len(argv) > 24 or any(len(a) > 200 for a in argv):
        return None, "too long"
    cmd, args = argv[0], argv[1:]
    if "/" in cmd:
        return None, "name the command, not a path to it"
    check = ALLOW.get(cmd)
    if check is None:
        return None, f"`{cmd}` is not on EVE's list of harmless commands"
    try:
        good = check(args)
    except (IndexError, ValueError, StopIteration):
        good = False
    if not good:
        return None, f"those arguments to `{cmd}` are not allowed (read-only use only)"
    return argv, None


# ── self-test ───────────────────────────────────────────────────────────
def selftest():
    import tempfile
    bad = 0

    def expect(name, got, want):
        nonlocal bad
        ok = got == want
        bad += not ok
        print(("ok  " if ok else "FAIL") + f"  {name}: {got!r}" + ("" if ok else f" (wanted {want!r})"))

    for argv, want in [
        (["uptime"], True), (["df", "-h"], True), (["nvidia-smi"], True),
        (["journalctl", "--user", "-n", "50"], True), (["journalctl", "-n", "5000"], False),
        (["journalctl", "--vacuum-size=1M"], False), (["journalctl", "-f"], False),
        (["rm", "-rf", "/"], False), (["sudo", "pacman", "-Syu"], False), (["/bin/rm", "x"], False),
        (["bash", "-c", "ls"], False), (["cat", "/etc/passwd"], False), (["curl", "evil.com"], False),
        (["ip", "addr"], True), (["ip", "link", "set", "wlan0", "down"], False),
        (["hyprctl", "clients", "-j"], True), (["hyprctl", "dispatch", "exec", "x"], False),
        (["pacman", "-Qi", "kitty"], True), (["pacman", "-S", "x"], False), (["pacman", "-Syu"], False),
        (["pacman", "-Qs", "-y"], False),
        (["systemctl", "--user", "status", "hypridle"], True), (["systemctl", "stop", "sshd"], False),
        (["ls", "~/Pictures"], True), (["ls", "~/.ssh"], False), (["ls", "-la", "~/.gnupg"], False),
        (["nmcli", "device", "status"], True), (["nmcli", "radio", "wifi", "off"], False),
        (["ping", "-c", "3", "1.1.1.1"], True), (["ping", "1.1.1.1"], False),
        (["date"], True), (["date", "-s", "2020-01-01"], False),
        (["bluetoothctl", "devices"], True), (["bluetoothctl", "remove", "AA"], False),
        (["find", "/", "-delete"], False), (["ls", "$(rm x)"], False),
    ]:
        expect("run " + " ".join(argv), run_ok(argv)[0] is not None, want)

    # HOME, not the system default, when ~/projects is absent: a fresh machine has
    # no ~/projects, and these cases expect a folder a read can reach, which /tmp
    # is not. Three cases failed there with the policy working correctly.
    d = Path(tempfile.mkdtemp(dir=PROJECTS if PROJECTS.is_dir() else HOME))
    try:
        (d / "notes.md").write_text("hello\n")
        (d / "vault.kdbx").write_bytes(b"\x03\xd9\xa2\x9a" + b"\0" * 20)
        (d / "renamed.txt").write_bytes(b"-----BEGIN PGP MESSAGE-----\nhQ\n")
        (d / "aged").write_bytes(b"age-encryption.org/v1\n-> X25519 abc\n")
        (d / "secret.pdf").write_bytes(b"%PDF-1.7\n1 0 obj\n<< /Encrypt 5 0 R >>\n%%EOF")
        (d / ".env").write_text("TOKEN=1\n")
        (d / "zipenc.zip").write_bytes(b"PK\x03\x04\x14\x00\x01\x00" + b"\0" * 30)
        os.symlink(HOME / ".ssh", d / "sshlink")
        expect("read notes.md", read_ok(d / "notes.md")[0] is not None, True)
        for n in ["vault.kdbx", "renamed.txt", "aged", "secret.pdf", ".env", "zipenc.zip", "sshlink/id_ed25519"]:
            expect("read " + n, read_ok(d / n)[0] is not None, False)
        expect("read ~/.ssh/config", read_ok("~/.ssh/config")[0] is not None, False)
        expect("read ~/.claude.json", read_ok("~/.claude.json")[0] is not None, False)
        expect("write notes.md", write_ok(d / "notes.md")[0] is not None, True)
        expect("write new.md", write_ok(d / "new.md")[0] is not None, True)
        expect("write ~/x.md (outside EVE, asks)", write_ok("~/x.md")[0] is not None, True)
        expect("write ~/.bashrc", write_ok("~/.bashrc")[0] is not None, False)
        expect("write ~/.config/hypr/x", write_ok("~/.config/hypr/x.lua")[0] is not None, False)
        expect("write ~/EVE/new/dir/x.md", write_ok("~/EVE/new/dir/x.md")[0] is not None, True)
        expect("write ~/EVE/.env", write_ok("~/EVE/.env")[0] is not None, False)
        expect("write ~/EVE/api_keys.txt", write_ok("~/EVE/api_keys.txt")[0] is not None, False)
        expect("in_eve ~/EVE/a", in_eve("~/EVE/a"), True)
        expect("in_eve relative", in_eve("notes/a.md"), True)
        expect("in_eve ~/projects", in_eve("~/projects/a"), False)
        expect("read ~/.cache/x", read_ok("~/.cache/fontconfig")[0] is not None, False)
        expect("read ~/.local/share/x", read_ok("~/.local/share/recently-used.xbel")[0] is not None, False)
        (d / "conf.ini").write_text("user=ahaan\npassword = hunter22\napi_key: sk-ant-abcdefghijklmnopqrstuv\n"
                                    "url=postgres://bob:pw123@db/x\nAuthorization: Bearer abc.def.ghi\nplain line\n")
        t, why, n = readable_text(d / "conf.ini")
        expect("redact: hunter22 gone", "hunter22" in t, False)
        expect("redact: sk-ant gone", "sk-ant" in t, False)
        expect("redact: pw123 gone", "pw123" in t, False)
        expect("redact: bearer gone", "abc.def.ghi" in t, False)
        expect("redact: plain kept", "plain line" in t and "user=ahaan" in t, True)
        (d / "notes2.md").write_text("my key\n-----BEGIN OPENSSH PRIVATE KEY-----\nb3Bl\n")
        expect("read notes2.md (key inside)", readable_text(d / "notes2.md")[0] is not None, False)
        expect("redact AWS", "AKIAABCDEFGHIJKLMNOP" in redact("id AKIAABCDEFGHIJKLMNOP x")[0], False)
        expect("redact ghp", redact("ghp_" + "a" * 36)[1], 1)
        expect("keep a path", redact("/home/someone/src/dotfiles/install/lib x")[1], 0)
        expect("keep a sha", redact("commit 825bf19a6e3f0c1d2b3a4e5f60718293a4b5c6d7")[1], 0)
        expect("keep prose", redact("The password manager is KeePassXC, see the token docs.")[1], 0)
        expect("redact entropy", redact("x Zt8kQ2mN9pL4vR7wX1yB6cD3fG5hJ0aE y")[1], 1)
        expect("name api_keys.txt", read_ok(d / "api_keys.txt")[0] is not None, False)
        expect("name prod.env", read_ok(d / "prod.env")[0] is not None, False)
        expect("write .git/config", write_ok(d / ".git/config")[0] is not None, False)
        expect("write nested missing dir", write_ok(d / "nope/x.md")[0] is not None, False)
        expect("write ../../escape", write_ok(str(d / "../../../.bashrc"))[0] is not None, False)
        expect("write via symlink", write_ok(d / "sshlink/config")[0] is not None, False)
        expect("asked: 'add a line to notes'", asked_to_write("add a line to notes"), True)
        expect("asked: 'summarize notes'", asked_to_write("summarize notes"), False)
    finally:
        import shutil
        shutil.rmtree(d, ignore_errors=True)
    print(f"\n{bad} failed")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(selftest() if sys.argv[1:] == ["selftest"] else 2)
