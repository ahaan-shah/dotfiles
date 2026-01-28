#
# ~/.bashrc
#

# If not running interactively, don't do anything
[[ $- != *i* ]] && return

alias ls='ls --color=auto'
alias grep='grep --color=auto'

# Personal aliases
alias top="vtop --theme brew"
# alias oldtop="/usr/bin/top"
alias neo="neofetch"
alias ff="fastfetch"
alias yaz="yazi"
alias bkpconfigs="/home/ahaan/.config/scripts/backup_configs.sh"
alias backupnow="/home/ahaan/.config/scripts/backup_files.sh"
alias py="python"
alias arduinodata="/home/ahaan/college/year-2/sem4/dsp/Arduino/scripts/log_arduino.sh"
alias f="figlet"
alias btui="bluetui"
alias ave="source .venv/bin/activate"

# system update and install and remove packages
alias update="yay -Syu"
alias install="yay -S "
alias remove="yay -Rns "
alias search="yay -Ss"

# encryption
alias encrypt="gpg --encrypt -r ahaanshah04@gmail.com"
alias decrypt="gpg --decrypt"

PS1='[\u@\h \W]\$ '

eval "$(starship init bash)"

# Import colorscheme from 'wal' asynchronously
# &   # Run the process in the background.
# ( ) # Hide shell job control messages.
# Not supported in the "fish" shell.
(cat ~/.cache/wal/sequences &)

# Alternative (blocks terminal for 0-3ms)
#cat ~/.cache/wal/sequences

# To add support for TTYs this line can be optionally added.
source ~/.cache/wal/colors-tty.sh


export EDITOR="vim"
export VISUAL="vim"

