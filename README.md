# My Archlinux dotfiles

**This is a totally personal setup, not a one-click installer.**

**So cherry-pick whatever's cool to you!**

## Preview ✨

<video src="https://github.com/user-attachments/assets/b4e34bf2-3cb1-4cea-8920-abb2c80d2c54" controls></video>

## Wiring it up

```bash
git clone https://github.com/ahaan-shah/dotfiles.git ~/.config/dotfiles
```

It uses:  
- Hyprland 0.56+ (the config is `hyprland.lua`, not `.conf`)  
- Quickshell  
- and a decent pile of CLI tools  

Two Quickshell apps, both autostarted from `hypr/hyprland.lua`:

- `shell/` — the entire desktop in one process: bar and its dropdowns,
  notifications, OSD, dock, Alt+Tab switcher, wallpaper, and the launcher with
  its settings menu. It was three separate apps and 395 MB of RAM; merging them
  cut it to 200.
- `lockscreen/` — spawned per lock, not a daemon.

`SUPER+Return` opens the settings menu, which is where most of the system is
actually configured: packages, AUR, web apps, monitors, keybinds, window rules,
defaults, firewall, fingerprints, power. 22 palettes plus pywal, and every
surface on screen reads the same colours.

Wallpapers live in `Pictures/wallpapers/` and are picked under Settings →
Theme → Wallpapers, which also has a **By palette** page that ranks them by how
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
