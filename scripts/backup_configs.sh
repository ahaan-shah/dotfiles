#!/usr/bin/env bash
# backup_configs.sh — mirror the live config into ~/.config/dotfiles, which is
# a PUBLIC git repo (github.com/ahaan-shah/dotfiles).
#
# Two jobs, and the second one is why this is not just a pile of rsync calls:
#
#  1. Capture everything install.sh needs to rebuild this desktop from a bare
#     Arch install — which now includes systemd user units and the /etc-level
#     rules, not only ~/.config directories.
#  2. Keep anything private, machine-specific or secret OUT of it. The repo is
#     public, so this refuses to write at all if a credential scan trips.
#
# Machine-specific means "would be WRONG on another machine", not just secret:
# hardware.env names this laptop's touchpad, battery and GPU, and shipping it
# would hand a fresh install the wrong hardware profile. install.sh regenerates
# it, so it is deliberately excluded.
set -u

# Overridable so this can be exercised against a scratch directory instead of
# the real repo:  DOTFILES_DIR=/tmp/x ./backup_configs.sh
DOTDIR="${DOTFILES_DIR:-$HOME/.config/dotfiles}"
SRCREPO="${HYPRAHAAN_SRC:-$HOME/projects/hyprahaan}"

# ── things that must never be committed ──────────────────────────────────
EXCLUDES=(
    --exclude 'hardware.env'        # machine-specific; install.sh regenerates it
    # nwg-displays writes these with THIS panel's resolution/scale hardcoded.
    # hyprland.lua does not source them, so they are inert here — but they are
    # machine-specific values in a public repo, same class as hardware.env.
    --exclude 'monitors.conf'
    --exclude 'monitors.lua'
    --exclude 'workspaces.conf'
    # Which firewall services this machine has switched off, per zone. Not a
    # secret, but machine-specific in exactly the sense above — another machine's
    # zones and services are different, and a public repo should not describe
    # this one's firewall posture either.
    --exclude 'firewall-off.conf'
    # Which fingers are enrolled on this machine and what the user called them.
    # Same class again — machine-specific, and a public repo has no business
    # saying which finger unlocks this laptop.
    --exclude 'fingerprint-names.conf'
    --exclude 'backup_files.sh'     # names personal directories
    --exclude 'wake-lag-*'          # bulky machine-specific diagnostic captures
    --exclude 'wake-lag-logs/'
    --exclude 'diagnose-wake-lag.sh'
    --exclude '*.bak'
    --exclude '*.bak-*'
    --exclude '*.orig'
    --exclude '*.log'
    --exclude '.git'
    --exclude 'config.toml.bak-*'
)

sync() {
    local src="$1" dst="$2"
    if [ -e "$src" ]; then
        mkdir -p "$dst"
        rsync -a --delete "${EXCLUDES[@]}" "$src"/ "$dst"/
    else
        echo "Missing: $src"
    fi
}

copy() {
    local src="$1" dst="$2"
    if [ -e "$src" ]; then
        mkdir -p "$(dirname "$dst")"
        rsync -a "$src" "$dst"
    else
        echo "Missing: $src"
    fi
}

# ---------------- CONFIG FOLDERS ----------------
sync "$HOME/.config/hypr"        "$DOTDIR/hypr"
sync "$HOME/.config/finder"      "$DOTDIR/finder"
sync "$HOME/.config/lockscreen"  "$DOTDIR/lockscreen"
sync "$HOME/.config/kitty"       "$DOTDIR/kitty"
sync "$HOME/.config/cava"        "$DOTDIR/cava"
sync "$HOME/.config/fastfetch"   "$DOTDIR/fastfetch"
sync "$HOME/.config/neofetch"    "$DOTDIR/neofetch"
sync "$HOME/.config/fum"         "$DOTDIR/fum"
# btop.conf is part of the desktop — F12 is bound to it in hyprland.lua — and
# install.sh already tries to deploy ~/.config/btop, so without this line a
# fresh machine silently got stock btop settings.
sync "$HOME/.config/btop"        "$DOTDIR/btop"
sync "$HOME/.config/scripts"     "$DOTDIR/scripts"
sync "$HOME/.config/macshell"    "$DOTDIR/macshell"
sync "$HOME/.config/taskbar"     "$DOTDIR/taskbar"
sync "$HOME/.config/gtk-3.0"     "$DOTDIR/gtk-3.0"
sync "$HOME/.config/gtk-4.0"     "$DOTDIR/gtk-4.0"
sync "$HOME/Pictures/wallpapers" "$DOTDIR/wallpapers"

# ---------------- SINGLE FILES ----------------
copy "$HOME/.zshrc"                   "$DOTDIR/shell/.zshrc"
copy "$HOME/.bashrc"                  "$DOTDIR/shell/.bashrc"
copy "$HOME/.config/starship.toml"    "$DOTDIR/starship/starship.toml"
copy "$HOME/.config/mimeapps.list"    "$DOTDIR/mimeapps.list"
copy "$HOME/.config/battery-threshold" "$DOTDIR/battery-threshold"
sync "$HOME/.config/spicetify/Themes/pywaldynamic" "$DOTDIR/spicetify/Themes/pywaldynamic"

# ---------------- DESKTOP FILES ----------------
sync "$HOME/.local/share/applications"  "$DOTDIR/webapps/applications"
sync "$HOME/.local/share/icons/webapps" "$DOTDIR/webapps/icons"

# ---------------- SYSTEMD USER UNITS ----------------
# Only real files: the .wants/ entries are symlinks that `systemctl --user
# enable` recreates, and several point into /usr where they would dangle.
mkdir -p "$DOTDIR/systemd-user"
if [ -d "$HOME/.config/systemd/user" ]; then
    rm -rf "${DOTDIR:?}/systemd-user"; mkdir -p "$DOTDIR/systemd-user"
    ( cd "$HOME/.config/systemd/user" && \
      find . -type f \( -name '*.service' -o -name '*.timer' \
                      -o -name '*.target' -o -name '*.conf' \) -print0 \
      | while IFS= read -r -d '' f; do
            mkdir -p "$DOTDIR/systemd-user/$(dirname "$f")"
            cp -a "$f" "$DOTDIR/systemd-user/$f"
        done )
else
    echo "Missing: ~/.config/systemd/user"
fi

# ---------------- SYSTEM-LEVEL FILES ----------------
# Snapshotted for reference and for install.sh to diff against. All of these are
# world-readable and contain no credentials; /etc/NetworkManager/system-connections
# (which holds wifi PSKs) is root-only and is deliberately NOT touched here.
mkdir -p "$DOTDIR/system"
for f in /etc/udev/rules.d/99-battery-charge-threshold.rules \
         /etc/udev/rules.d/99-micmute-led.rules \
         /etc/keyd/default.conf \
         /etc/systemd/zram-generator.conf \
         /etc/sysctl.d/99-zram-swappiness.conf \
         /etc/sysctl.d/20-quiet-printk.conf \
         /etc/NetworkManager/conf.d/wifi_backend.conf \
         /etc/greetd/config.toml; do
    [ -r "$f" ] && { mkdir -p "$DOTDIR/system/$(dirname "${f#/etc/}")"; cp -a "$f" "$DOTDIR/system/${f#/etc/}"; }
done

# ---------------- THE INSTALLER ----------------
# Authored in the source repo; carried here so a fresh machine only ever needs
# to clone the dotfiles repo.
if [ -d "$SRCREPO/install" ]; then
    # Refresh the shipped mimeapps template from the live file FIRST, so the
    # copy that travels inside install/ can never drift from reality. It is the
    # fallback the installer uses when run from the source repo rather than
    # from this mirror.
    if [ -f "$HOME/.config/mimeapps.list" ] && [ -d "$SRCREPO/install/templates" ]; then
        cp -f "$HOME/.config/mimeapps.list" "$SRCREPO/install/templates/mimeapps.list"
    fi
    sync "$SRCREPO/install" "$DOTDIR/install"
else
    echo "Missing: $SRCREPO/install (set HYPRAHAAN_SRC if the repo moved)"
fi

# ---------------- PACKAGE MANIFEST ----------------
# What is actually installed right now, for reference when the curated lists in
# install/packages/ drift from reality.
pacman -Qqen > "$DOTDIR/pkglist-repo.txt" 2>/dev/null
pacman -Qqem > "$DOTDIR/pkglist-aur.txt"  2>/dev/null

# ---------------- STALE ARTEFACTS ----------------
# rsync --exclude does not DELETE a file that is already there: --delete only
# removes destination files that are absent from the source, and an excluded
# path is not even considered. So anything that was committed BEFORE its
# exclude existed sits in the mirror forever, untouched by every later sync.
#
# That is not hypothetical — hypr/hyprland.lua.bak-preNvidia was committed
# before the '*.bak-*' exclude was added and has been in the public repo ever
# since, carrying an absolute path into a personal directory. install.sh
# rm -f's it after deploying, which fixes the target machine and does nothing
# at all about the copy that is published.
#
# NOTE: not `-path .git -prune -o … -delete`. -delete implies -depth, which
# disables -prune outright — find says so on stderr and then deletes NOTHING
# matched through the pruned branch. Measured: the .bak-preNvidia above
# survived a run written that way. Exclude by path test instead.
find "$DOTDIR" -type f -not -path "$DOTDIR/.git/*" \
     \( -name '*.bak' -o -name '*.bak-*' -o -name '*.orig' \) -print -delete \
  | sed "s#^$DOTDIR/#  removed stale artefact: #"

# ---------------- SANITISE ----------------
# The rule this section keeps: anything with a deterministic neutral form is
# REWRITTEN here; anything without one is REFUSED below.
#
# That split is the same one the exclude list at the top already makes. An
# absolute home path is not a secret and not dangerous — it is simply a fact
# about this machine that is wrong on every other one, exactly like
# hardware.env — so it gets neutralised rather than blocking the backup. A
# credential has no neutral form, so it stops the run instead.
#
# Neutralising rather than excluding matters because several of these files
# have to keep their absolute paths to work at all: a .desktop file cannot
# expand $HOME, so webapps/applications/*.desktop genuinely need one. Writing
# the placeholder keeps the file complete and install.sh's configs phase
# rewrites '/home/<anything>/' to the new user's $HOME on the way in, so
# /home/USER/ restores correctly on the target machine.
USERHOME="/home/$USER"
EMAIL_RE='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'

# A scanner cannot scan itself. The mirror carries a copy of THIS script, which
# necessarily contains the placeholder it substitutes (an address, so it matches
# EMAIL_RE) and the literal path the gate below greps for. Without this the
# first run after deploying it redacts its own copy and then refuses, naming
# itself as the offender — measured, both happened.
#
# Excluding it is safe in a way excluding an ordinary file would not be: it is
# source in this repo, reviewed like the rest of it, and it is the one file in
# the mirror whose whole purpose is to be read before it is trusted.
SELF="$(basename "${BASH_SOURCE[0]}")"

# grep -l, then sed the named files: sed -i over everything would rewrite
# mtimes on the whole mirror every run and make git think all 215 files changed.
scrubbed=0
while IFS= read -r f; do
    [ -n "$f" ] || continue
    sed -i "s#$USERHOME#/home/USER#g" "$f"
    echo "  neutralised home path: ${f#"$DOTDIR"/}"
    scrubbed=1
done < <(grep -rIlF --exclude-dir=.git --exclude="$SELF" -e "$USERHOME" "$DOTDIR" 2>/dev/null || true)

# An email address has no neutral form that still works, so this one is a
# redaction and is reported as such. The case that put it here: the gpg alias
# in .zshrc and .bashrc carries the user's own key recipient, and those two
# files live ONLY in the mirror — there is no source-repo copy to fix upstream,
# so the choice is redact here or publish it.
while IFS= read -r f; do
    [ -n "$f" ] || continue
    sed -i -E "s#$EMAIL_RE#REDACTED@example.invalid#g" "$f"
    echo "  redacted an email address: ${f#"$DOTDIR"/}"
    scrubbed=1
done < <(grep -rIlE --exclude-dir=.git --exclude="$SELF" -e "$EMAIL_RE" "$DOTDIR" 2>/dev/null || true)

[ "$scrubbed" = 0 ] && echo "Nothing to neutralise."

# ---------------- PERSONAL DATA SCAN ----------------
# The gate for what sanitising deliberately does NOT fix. Each of these means
# the mirror is describing THIS machine or the person on it, and each has a
# real answer that is not "rewrite the string".
echo
personal=""

# Anything still naming this user's home means the rewrite above missed a file
# shape — a new directory, or a path written some way the literal match did not
# catch. It is a bug in this script, not something to publish around.
left=$(grep -rIlF --exclude-dir=.git --exclude="$SELF" -e "$USERHOME" "$DOTDIR" 2>/dev/null || true)
[ -n "$left" ] && personal="$personal
absolute home paths survived the rewrite in:
$left"

# An absolute path into the private source repo. That tree is not mirrored on
# purpose — it holds this file, CLAUDE.md and system-map.html, which carry the
# private artifact link — so a public file naming a path INSIDE it means a live
# file has drifted from its authored copy.
#
# Matched as '/home/USER/projects/' and not as the bare repo name: this file,
# taskbar/shell.qml and finder/Settings.qml all mention 'projects/hyprahaan' in
# prose, and a check that fires on a comment is a check that gets switched off.
# It is the absolute path that is the leak, not the word.
#
# The known case: ~/.config/systemd/user/battery-threshold.service, whose
# authored version in install/user-systemd/ already uses %h and whose deployed
# copy still carries the old absolute Documentation= line. The fix is to deploy
# the authored unit, not to edit the mirror.
src=$(grep -rIl --exclude-dir=.git --exclude="$SELF" -e '/home/USER/projects/' "$DOTDIR" 2>/dev/null || true)
[ -n "$src" ] && personal="$personal
the private source-repo path appears in:
$src
  (a live file has drifted from its authored copy in install/ — redeploy it)"

if [ -n "$personal" ]; then
    echo "!! PERSONAL DATA — review before committing:$personal"
    echo
    echo "Nothing was deleted; the files are staged in $DOTDIR."
    exit 1
fi
echo "Personal-data scan clean."

# ---------------- SECRET SCAN ----------------
# Last line of defence before this is pushed to a public repo. Matches assigned
# values, not the words themselves, so the many legitimate mentions of
# "password" in the wifi panel's own code do not trip it.
echo
hits=$(grep -rIE --exclude-dir=.git \
        -e '(psk|password|passwd|api[_-]?key|secret|token)[[:space:]]*=[[:space:]]*["'"'"']?[A-Za-z0-9/+_.-]{8,}' \
        -e 'BEGIN [A-Z ]*PRIVATE KEY' \
        -e '\b(ghp|gho|ghs|sk|xoxb|xoxp)-[A-Za-z0-9]{16,}' \
        "$DOTDIR" 2>/dev/null \
      | grep -vE '\$\{?[A-Za-z_]|shq\(|root\.|\+ *"|nmcli|wifi-sec|placeholder|= *""' || true)

if [ -n "$hits" ]; then
    echo "!! POSSIBLE SECRET FOUND — review before committing:"
    echo "$hits" | head -20
    echo
    echo "Nothing was deleted; the files are staged in $DOTDIR."
    echo "Remove the offending value, then commit."
    exit 1
fi

echo "Secret scan clean."
echo "Dotfiles sync complete 🚀"
