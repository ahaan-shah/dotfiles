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
alias bkpdots="/home/ahaan/.config/scripts/backup_configs.sh"
alias backupnow="/home/ahaan/.config/scripts/backup_files.sh"
alias py="python"
#alias arduinodata="/home/ahaan/college/year-2/sem4/dsp/Arduino/scripts/log_arduino.sh"
alias f="figlet"
alias btui="bluetui"
alias ave="source .venv/bin/activate"
alias jnotes="jupyter notebook"
alias jlab="jupyter lab"

alias connectiphone="ifuse ~/iphone && nautilus ~/iphone/DCIM"
alias ninitimes="/home/ahaan/.config/scripts/sleep-timer.sh"

# system update and install and remove packages
alias update="yay -Syu"
alias install="yay -S "
alias remove="yay -Rns "
alias search="yay -Ss"

# encryption
alias sycrypt="gpg -c"
alias encrypt="gpg --encrypt -r ahaanshah04@gmail.com"
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
