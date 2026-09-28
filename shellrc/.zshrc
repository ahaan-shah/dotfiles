### ---------- HISTORY ----------
HISTFILE=~/.zsh_history
HISTSIZE=5000
SAVEHIST=5000
setopt APPEND_HISTORY
setopt HIST_IGNORE_ALL_DUPS
setopt HIST_REDUCE_BLANKS
setopt SHARE_HISTORY

### ---------- KEYBINDS ----------
bindkey -e   # normal arrow key editing

### ---------- COMPLETION ----------
autoload -Uz compinit
compinit

# Case-insensitive completion
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}'

### ---------- PLUGINS ----------
# Autosuggestions
source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh

# Syntax highlighting (must be last)
source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

### ---------- ALIASES ----------
alias ll='ls -lah'
alias ls='ls --color=auto'
alias grep='grep --color=auto'
alias clr='clear'

# Personal aliases
alias neo="neofetch"
alias ff="fastfetch"
alias yaz="yazi"
alias bkpdots="~/.config/scripts/backup_configs.sh"
alias backupnow="~/.config/scripts/backup_files.sh"
alias py="python"
alias f="figlet"
alias btui="bluetui"
alias ave="source .venv/bin/activate"
alias jnotes="jupyter notebook"
alias jlab="jupyter lab"
alias gst="git status"

alias connectiphone="ifuse ~/iphone && nautilus ~/iphone/DCIM"
alias ninitimes="~/.config/scripts/sleep-timer.sh"

# system update and install and remove packages
alias update="~/.config/scripts/system-update.sh"
alias get="~/.config/scripts/pkg-install.sh"
alias aurget="~/.config/scripts/pkg-aur-install.sh"
alias remove="~/.config/scripts/pkg-remove.sh" 

# encryption
alias sycrypt="gpg -c"
alias encrypt="gpg --encrypt -r REDACTED@example.invalid"
alias decrypt="gpg --decrypt"

### ---------- STARSHIP PROMPT ----------
eval "$(starship init zsh)"

### ---------- PYWAL COLORS ----------
# Load wal colors in terminal
(cat ~/.cache/wal/sequences &)

# TTY support
#source ~/.cache/wal/colors-tty.sh

### ---------- DEFAULT EDITOR ----------
export EDITOR="vim"
export VISUAL="vim"

export PATH=$PATH:~/.spicetify
export PATH="$HOME/.local/bin:$PATH"
export PATH="$HOME/go/bin:$PATH"
export LIBVIRT_DEFAULT_URI=qemu:///system

### ---------- SECOND CLAUDE CODE ACCOUNT ----------
# CLAUDE_CONFIG_DIR relocates the whole profile — credentials, settings.json,
# MCP servers, session history and memory — so the two accounts share nothing
# but the binary and whatever CLAUDE.md the project they're sitting in provides.
# Verified isolated on 2.1.278: an alternate dir comes up with oauthAccount unset
# rather than inheriting the default login.
# Aliases exist only in interactive shells; if something spawns claude directly
# (herdr's agent integration, a systemd unit) it gets the default account, and
# this needs to become a wrapper script in ~/.local/bin instead.
alias claude-avi='CLAUDE_CONFIG_DIR=$HOME/.claude-avi claude'
