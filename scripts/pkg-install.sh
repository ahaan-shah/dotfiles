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

selected=$(pacman -Slq | fzf "${fzf_args[@]}")

[ -z "$selected" ] && exit 0

sudo pacman -S --noconfirm $selected
