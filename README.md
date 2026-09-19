# My Archlinux dotfiles

**This is a totally personal setup, and also ships with a simple installer.**

**If you don't want the whole setup, cherry-pick whatever's cool to you!**

## Preview ✨

<video src="https://github.com/user-attachments/assets/b4e34bf2-3cb1-4cea-8920-abb2c80d2c54" controls></video>

## Wiring it up

```bash
git clone https://github.com/ahaan-shah/dotfiles.git ~/.config/dotfiles
~/.config/dotfiles/install/install.sh
```

It uses:  
**- Hyprland  
- Quickshell**

That's about it.

Two Quickshell apps, both autostarted from `hypr/hyprland.lua`:

- `shell/` — the entire desktop in one process: bar and its dropdowns,
  notifications, OSD, dock, Alt+Tab switcher, wallpaper, and the launcher with
  its settings menu.
- `lockscreen/` — spawned per lock, not a daemon.

`SUPER+Return` opens the settings menu, which is where most of the system can easily be configured: 
- Repo packages  
- AUR  
- Web Apps  
- Monitors  
- Keybinds  
- Window rules  
- Defaults  
- Themes  
- Tools  
- Power   
- Security 

Wallpapers live in `Pictures/wallpapers/` and are picked under Settings →
Theme → Wallpapers, which also has a "by palette"" page that ranks them by how
close each image's dominant colours sit to the palette you're on.

## Rebuilding from scratch

`install/` brings all of this up on a bare Arch TTY. `--dry-run` prints every
package, copy and service first — read that before the real run. Details in
[install/README.md](install/README.md).

---

If you're into the vibecoded-tool side of things rather than the desktop
side, I've also got [peach](https://github.com/ahaan-shah/peach) (a TUI
Splitwise) and [pear](https://github.com/ahaan-shah/pear) (a TUI budget
tracker) soooo check em out!
