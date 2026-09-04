#!/bin/bash
# Fuzzy-search the AUR (via yay) and install the picked packages.
# Layout/keybinds mirror Omarchy's omarchy-pkg-aur-install; colors pull from pywal.

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
  --preview 'yay -Sii {1}'
  --preview-label='alt-p: toggle description, alt-↑/↓: scroll, tab: multi-select'
  --preview-label-pos='bottom'
  --preview-window 'down:65%:wrap'
  --bind 'alt-p:toggle-preview'
  --bind 'alt-d:preview-half-page-down,alt-u:preview-half-page-up'
  --bind 'alt-up:preview-up,alt-down:preview-down'
  --color "$fzf_colors"
)

selected=$(yay -Slq aur | fzf "${fzf_args[@]}")

[ -z "$selected" ] && exit 0


if [[ -t 1 ]]; then
    BOLD=$(tput bold); RESET=$(tput sgr0)
    CYAN=$(tput setaf 6); YELLOW=$(tput setaf 3)
else
    BOLD=""; RESET=""; CYAN=""; YELLOW=""
fi

# Name what is about to happen BEFORE sudo asks for anything. Selecting in fzf
# and then being met by a bare "[sudo] password for ahaan:" gives no confirmation
# of WHAT was selected, on the one screen where that matters most. Same banner
# shape as system-update.sh so the flows read alike.
printf '\n%s%s  %s%s\n' "$BOLD" "$CYAN" "Installing these packages:" "$RESET"
printf '%s  ─────────────────────────────────────────────%s\n\n' "$CYAN" "$RESET"
for _p in $selected; do printf '    %s\n' "$_p"; done
printf '\n%s  Input password to continue.%s\n\n' "$YELLOW" "$RESET"

yay -S --noconfirm $selected
