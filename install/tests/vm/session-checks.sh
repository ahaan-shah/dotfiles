#!/usr/bin/env bash
# session-checks.sh — run in the GUEST inside a logged-in Hyprland session. What
# verify cannot reach from a TTY: the things that only exist once the desktop is
# up. Prints one PASS/FAIL line each and exits non-zero on any FAIL.
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t "$XDG_RUNTIME_DIR/hypr" | head -1)
export WAYLAND_DISPLAY=$(basename "$(ls "$XDG_RUNTIME_DIR"/wayland-? | head -1)")
export DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus
export PATH="$HOME/.local/bin:$PATH"
F=0
t() { local n="$1"; shift; if timeout 90 bash -c "$*" >/tmp/chk.out 2>&1; then echo "PASS $n"; else echo "FAIL $n :: $(tail -2 /tmp/chk.out | tr '\n' ' ' | cut -c1-150)"; F=$((F+1)); fi; }
# Checks of an optional list run only if nothing was left out of it, because they
# name several of its members at once. What was left out gets checked below by name.
left() { sed -n "s/^exclude_$1=//p" ~/.local/state/hyprahaan/install-choices 2>/dev/null; }
said() { [ -z "$(left "$1")" ]; }
t "hyprland: no config errors"      '[ -z "$(hyprctl configerrors | grep -v "no errors")" ]'
t "hyprland: binds loaded (>=70; luastub counts 79)"   '[ "$(hyprctl binds | grep -c modmask)" -ge 70 ]'
# Which colours depends on ui.conf's PALETTE at the time of the mirror, so this asks
# the one thing true of all of them. It held tokyo-night's background until ui.conf
# moved to pywal and it failed a correct desktop (2026-11-06).
t "hyprland: colours generated"     'python3 -c "import json,os;assert len(json.load(open(os.path.expanduser(\"~/.cache/wal/colors.json\")))[\"colors\"])==16"'
t "shell: one quickshell running"   '[ "$(pgrep -cx quickshell)" -ge 1 ]'
t "shell: ipc answers"              'qs -c "$HOME/.config/shell" ipc show | grep -q jarvis || qs -p "$HOME/.config/shell" ipc show | grep -q jarvis'
t "polkit agent running"            'pgrep -f scripts/polkit-agent.py'
t "hypridle running"                'pgrep -x hypridle'
t "portal answers"                  'busctl --user status org.freedesktop.portal.Desktop'
t "keyring: secret store works"     'printf s3 | secret-tool store --label=t a b && [ "$(secret-tool lookup a b)" = s3 ]'
t "audio: pipewire up, wpctl reads" 'wpctl status | grep -q PipeWire'
t "clipboard: wl-copy round trip"   'printf hi | wl-copy && sleep 0.3 && [ "$(wl-paste -n)" = hi ]'
t "screenshot: grim"                'grim /tmp/s.png && [ -s /tmp/s.png ]'
t "OCR: tesseract reads the screen" 'magick -size 600x120 xc:white -pointsize 48 -annotate +20+70 "HELLO EVE" /tmp/o.png && tesseract /tmp/o.png - 2>/dev/null | grep -q "HELLO EVE"'
t "OCR: script deployed+deps"       '[ -x ~/.config/scripts/ocr-region.sh ] && command -v slurp grim tesseract wl-copy'
if ! case " $(left aur) " in *" voxtype-bin "*) true ;; *) false ;; esac; then
t "voxtype: daemon active"          'systemctl --user is-active voxtype.service'
t "voxtype: model on disk"          'ls ~/.local/share/voxtype/models/ | grep -q base.en'
t "voice typing: settings backend"  '~/.config/scripts/voice-typing.sh status'
# espeak-ng is test-only: the harness installs it in the guest for a speech sample.
t "voxtype: transcribes real speech" 'cd /tmp && espeak-ng -s 140 -w s.wav "the quick brown fox jumps over the lazy dog" && ffmpeg -y -loglevel error -i s.wav -ar 16000 -ac 1 s16.wav && voxtype transcribe s16.wav | grep -qi "quick brown fox"'
fi
t "keyring: secret survives login"  'if [ -f ~/.chk-secret ]; then [ "$(secret-tool lookup k persist)" = yes ]; else printf yes | secret-tool store --label=p k persist && touch ~/.chk-secret; fi'
t "kitty launches"                  'hyprctl dispatch "hl.dsp.exec_cmd(\"kitty --class kitty\")" ; sleep 4; hyprctl clients | grep -q "class: kitty"'
t "webapp: chromium --app window"   'hyprctl dispatch "hl.dsp.exec_cmd(\"chromium --app=about:blank --class=chkweb\")"; sleep 12; hyprctl clients | grep -qi "chromium\|chkweb\|about:blank"'
if said webapps; then
t "webapps: launchers present"      '[ "$(ls ~/.local/share/applications/*.desktop | wc -l)" -gt 15 ]'
else
for w in $(left webapps); do t "webapps: $w left out" "[ ! -e ~/.local/share/applications/$w ]"; done
fi
t "webapps: icons resolve"          'for d in ~/.local/share/applications/*.desktop; do i=$(sed -n "s/^Icon=//p" "$d" | head -1); case "$i" in /*) [ -e "$i" ] || { echo "$d: $i"; exit 1; } ;; esac; done'
t "dock: pins carried, no dead ones" 'python3 -c "import json,os;d=json.load(open(os.path.expanduser(\"~/.local/state/hyprahaan/dock-pins.json\")));print(len(d[\"pins\"]));assert len(d[\"pins\"])>=3;import shutil,shlex;assert not [p for p in d[\"pins\"] if not shutil.which(shlex.split(p[\"command\"])[0])]"'
if said aur; then
# Asks whether links open in the browser ui.conf names, not in Zen: Ahaan's own default
# is chromium, which the mirror carries, and this held Zen and failed a correct
# desktop on 2026-11-08. The repoint below covers the case where Zen was left out.
t "default browser resolves"        '. ~/.config/scripts/ui.conf; [ -n "$DEFAULT_BROWSER_DESKTOP" ] && [ "$(xdg-mime query default x-scheme-handler/https)" = "$DEFAULT_BROWSER_DESKTOP" ] && [ -e "/usr/share/applications/$DEFAULT_BROWSER_DESKTOP" ]'
t "zen/brave/codium/rstudio present" 'command -v zen-browser brave codium rstudio'
else
case " $(left aur) " in *" zen-browser-bin "*)
t "no Zen: chromium opens links" 'xdg-mime query default x-scheme-handler/https | grep -q chromium' ;; esac
fi
t "pywal is built whatever was left out" 'command -v wal'
# Everything excluded that is a package, by name. The rest of each list is verify's job.
for p in $(left aur) $(left extras); do
    case "$p" in
        virtual-machines) t "left out: VMs" '! command -v virsh' ;;
        kaggle|herdr) t "left out: $p" "! command -v $p" ;;
        TinyTeX) t "left out: TinyTeX" '[ ! -d ~/.TinyTeX ]' ;;
        org.*) t "left out: $p" "! flatpak list --app --columns=application 2>/dev/null | grep -q $p" ;;
        *) t "left out: $p" "! pacman -Q $p" ;;
    esac
done
if said extras; then
t "steam/discord/signal/obs present" 'command -v steam discord signal-desktop obs'
t "jasp flatpak"                    'flatpak list --app --columns=application | grep -q JASP'
t "kaggle/herdr/tinytex"            'command -v kaggle herdr pdflatex'
fi
t "controls remain whatever was left out" 'for c in mpv imv papers wiremix bluetui impala nwg-displays playerctl; do command -v $c || exit 1; done'
t "EVE: chat.py runs"               'cd ~/.config/jarvis && python3 -c "import chat" '
t "EVE: claude CLI"                 'claude --version'
t "EVE: broker lists its tools"     'cd ~/.config/jarvis && printf %s "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}" | timeout 8 python3 broker.py 2>/dev/null | grep -q search_text'
t "EVE: agents collectors"          '~/.config/scripts/agent-usage-update.sh; ls ~/.local/state/hyprahaan/agents/usage | grep -q claude'
t "shell rc: zsh is the login shell" '[ "$(getent passwd $USER | cut -d: -f7)" = /usr/bin/zsh ]'
t "zsh loads clean"                 '[ "$(zsh -ic exit 2>&1 | grep -c "not found")" = 0 ]'
t "starship prompt"                 'starship prompt >/dev/null'
t "nvim opens headless"             'timeout 30 nvim --headless "+qa"'
if ! case " $(left extras) " in *" virtual-machines "*) true ;; *) false ;; esac; then
t "virt: system networks"           'LIBVIRT_DEFAULT_URI=qemu:///system virsh net-list --name | grep -q default'
t "virt: iso pool"                  'LIBVIRT_DEFAULT_URI=qemu:///system virsh pool-list --name | grep -q iso_files'
fi
t "firewall running w/ localsend"   'systemctl is-active firewalld && grep -q localsend /etc/firewalld/zones/public.xml'
t "hardware.env complete"           '. ~/.config/scripts/hardware.env; [ -n "$PRIMARY_MONITOR" ]'
t "no failed user units"            '[ -z "$(systemctl --user --failed --no-legend)" ]'
t "no failed system units"          '[ -z "$(systemctl --failed --no-legend)" ]'
echo "failures: $F"
exit $F
