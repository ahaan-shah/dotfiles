#!/bin/bash
# Fuzzy-search official Arch repos (pacman -Slq) and install the picked packages.
# Layout/keybinds mirror Omarchy's omarchy-pkg-install; colors pull from pywal.

set -euo pipefail

wal="$HOME/.cache/wal/colors.sh"
if [ -f "$wal" ]; then
  set +u
  source "$wal"
  set -u
fi

foreground="${foreground:-#eae1e3}"
background="${background:-#000000}"
color1="${color1:-#A84234}"
color2="${color2:-#DC4223}"
color4="${color4:-#946E6B}"
color8="${color8:-#a39d9e}"

fzf_colors="fg:$foreground,bg:$background,hl:$color1"
fzf_colors+=",info:$color4,prompt:$color2,pointer:$color2,marker:$color2,spinner:$color1,gutter:$color8"
fzf_colors+=",border:$color8,list-border:$color8,input-border:$color8,preview-border:$color8"
fzf_colors+=",label:$color4,list-label:$color4,preview-label:$color4,input-label:$color4"
fzf_colors+=",scrollbar:$color8,preview-scrollbar:$color8,separator:$color8"

fzf_args=(
  --multi
  --preview 'pacman -Sii {1}'
  --preview-label='alt-p: toggle description, alt-↑/↓: scroll, tab: multi-select'
  --preview-label-pos='bottom'
  --preview-window 'down:65%:wrap'
  --bind 'alt-p:toggle-preview'
  --bind 'alt-d:preview-half-page-down,alt-u:preview-half-page-up'
  --bind 'alt-up:preview-up,alt-down:preview-down'
  --color "$fzf_colors"
)

if [[ -t 1 ]]; then
    BOLD=$(tput bold); RESET=$(tput sgr0)
    CYAN=$(tput setaf 6); YELLOW=$(tput setaf 3)
else
    BOLD=""; RESET=""; CYAN=""; YELLOW=""
fi

# ── Install without questions, except for a conflict ──────────────────────
# Ahaan, 2026-09-30: "I want just to input password and it does the install.
# Only ask y/n for conflicts removal." pacman cannot be told that directly:
# --noconfirm answers EVERY question with its default, and a package conflict
# ("A and B are in conflict. Remove B? [y/N]") defaults to No, so it aborts
# (exit 1) having changed nothing. Without --noconfirm it also stops for
# "Proceed with installation?", which is the question he does not want.
#
# So two passes. The first is --noconfirm, which is the whole install in the
# normal case. If it aborted on a conflict, the packages it refused to remove
# are read out of its own output, named, and asked about ONCE; a yes re-runs
# with --ask 4. --ask is pacman's (undocumented) bitmask of questions whose
# default answer is inverted under --noconfirm; 4 is ALPM_QUESTION_CONFLICT_PKG
# and nothing else, so every other prompt still takes its default.
#
# Both halves measured before this went in, as a fake root in a user namespace
# (`unshare -r pacman --dbpath <copy> --root <scratch>`), installing
# zathura-pdf-poppler over the installed zathura-pdf-mupdf: --noconfirm → rc 1,
# "Remove zathura-pdf-mupdf? [y/N]" in the output; --noconfirm --ask 4 → rc 0,
# mupdf removed, poppler installed.
#
# `script` runs the first pass on a pty and records it, so the output stays
# live with its colours and progress bars AND can be read afterwards. The
# recording is full of escape codes, which make grep call it binary and print
# nothing: hence the sed and `grep -a`.
_conflicts() {
    sed 's/\x1b\[[0-9;?]*[A-Za-z]//g; s/\r//g' "$1" \
        | grep -aoP 'Remove \K[^?]+(?=\? \[y/N\])' | sort -u || true
}
_ask_conflicts() {
    local -a doomed
    mapfile -t doomed < <(_conflicts "$1")
    [ ${#doomed[@]} -gt 0 ] || return 2   # failed for some other reason
    printf '\n%s%s  %s%s\n' "$BOLD" "$YELLOW" "Installing this needs these packages removed:" "$RESET"
    for _p in "${doomed[@]}"; do printf '    %s\n' "$_p"; done
    printf '\n'
    local ans=""
    read -rp "  Remove them and continue? [y/N] " ans
    [[ $ans == [Yy]* ]]
}

# ── One terminal for all of it ────────────────────────────────────────────
# Everything that needs root happens INSIDE one `script` session: this file
# re-runs itself there with --inner. It used to `sudo -v` out here and then run
# the install under `script`, and Ahaan got asked for his password twice
# (2026-09-30). sudo's ticket is per terminal and `script` gives its command a
# pty of its own, so the password typed out here did not count in there. With
# the prompt, both passes and the conflict question all on the one pty, one
# password covers the lot. The conflict question works in there too: `script`
# forwards the keyboard. The log is readable mid-session because -f flushes
# after every write.
_install() {
    local log=$PKG_INSTALL_LOG
    sudo -v || { printf '%s  sudo authentication failed.%s\n' "$YELLOW" "$RESET" >&2; return 1; }
    sudo pacman -S --noconfirm "$@" && return 0
    local rc=0; _ask_conflicts "$log" || rc=$?
    case $rc in
        1) printf '\n  Left as it was: nothing removed, nothing installed.\n'; return 1 ;;
        2) return 1 ;;   # not a conflict; the error is already on screen above
    esac
    sudo pacman -S --noconfirm --ask 4 "$@"
}

if [[ ${1:-} == --inner ]]; then shift; _install "$@"; exit; fi

selected=$(pacman -Slq | fzf "${fzf_args[@]}")

[ -z "$selected" ] && exit 0

# Name what is about to happen BEFORE sudo asks for anything. Selecting in fzf
# and then being met by a bare "[sudo] password for ahaan:" gives no confirmation
# of WHAT was selected, on the one screen where that matters most. Same banner
# shape as system-update.sh so the flows read alike.
printf '\n%s%s  %s%s\n' "$BOLD" "$CYAN" "Installing these packages:" "$RESET"
printf '%s  ─────────────────────────────────────────────%s\n\n' "$CYAN" "$RESET"
for _p in $selected; do printf '    %s\n' "$_p"; done
printf '\n%s  Input password to continue.%s\n\n' "$YELLOW" "$RESET"

PKG_INSTALL_LOG=$(mktemp); export PKG_INSTALL_LOG
trap 'rm -f "$PKG_INSTALL_LOG"' EXIT
script -qefc "$(printf '%q ' bash "$0" --inner $selected)" "$PKG_INSTALL_LOG"
