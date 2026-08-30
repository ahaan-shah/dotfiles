--##############################################################
--############## THIS IS MY HYPRLAND CONFIG FILE! ##############
--##############################################################
--
-- Migrated from hyprland.conf (hyprlang) to the Lua config format
-- introduced in Hyprland v0.55. The goal of this file is a faithful,
-- behavior-preserving translation of the original .conf.
--
-- A handful of lines could not be translated 1:1 because they depend on
-- external files or third-party plugins whose Lua API is plugin-defined.
-- Those are marked with `-- TODO:` and explained in the chat message.

------------------------------------------------------------------
-- Import pywal colors
------------------------------------------------------------------
-- The old config did:  source = ~/.cache/wal/colors-hyprland.conf
-- In Lua, files are pulled in with require() (no extension, '/' or '.'
-- as separators, relative to ~/.config/hypr/).
--
-- IMPORTANT: pywal currently writes a *.conf* file, not a *.lua* file.
-- For this to work you must change your pywal template so it outputs a
-- Lua module that returns a table of colors, e.g. ~/.config/hypr/colors-hyprland.lua:
--
--     return { color0 = "rgb(1d1f21)", color7 = "rgb(c5c8c6)", ... }
--
-- Until you do that, the require below will error. As a stop-gap the
-- `colors` table is given safe fallbacks via pcall so the rest of the
-- file still loads even if the module is missing.
local ok, wal = pcall(require, "colors-hyprland")
local colors = ok and wal or {}

-- The original config referenced $color7 (active border) and $color2
-- (a comment only). Mirror those as locals so the rest of the file is
-- a direct translation. Fallback keeps Hyprland happy if wal is absent.
local color7 = colors.color7 or "rgb(ffffff)" -- TODO: real value comes from pywal
local color2 = colors.color2 or "rgb(6a6b69)" -- only used in a comment originally


------------------------------------------------------------------
-- HARDWARE PROFILE
------------------------------------------------------------------
-- install.sh detects this machine's monitor, battery, LEDs, touchpad and
-- integrated GPU and writes them to ~/.config/scripts/hardware.env as plain
-- KEY="value" lines. The shell scripts source that file; this parses it.
--
-- Why a generated file rather than values edited into this config: the same
-- config then runs unmodified on any machine, and re-detecting is a one-command
-- operation (`install.sh --only hardware`) instead of a hand-edit.
--
-- Every lookup below falls back to a value that WORKS ON UNKNOWN HARDWARE
-- rather than to this laptop's specifics — a missing env file must degrade to a
-- usable desktop, never to a black screen.
local function read_hw_env()
    local t = {}
    local home = os.getenv("HOME")
    if not home then return t end
    local f = io.open(home .. "/.config/scripts/hardware.env", "r")
    if not f then return t end
    for line in f:lines() do
        local k, v = line:match('^%s*([A-Z_][A-Z0-9_]*)%s*=%s*"(.-)"%s*$')
        if k and v ~= "" then t[k] = v end
    end
    f:close()
    return t
end

local hw = read_hw_env()

-- Hyprland wants a number for a numeric scale but the string "auto" for the
-- automatic mode, so pass through only what is genuinely numeric.
local function num_or_string(v, fallback)
    if v == nil then return fallback end
    return tonumber(v) or v
end


------------------------------------------------------------------
-- GPU SELECTION  (must stay at the top of this file)
------------------------------------------------------------------
-- This box is an Optimus hybrid: Intel Iris Xe (0000:00:02.0, i915) drives
-- eDP-1, and an RTX 3050 6GB (0000:01:00.0) sits idle in D3cold until
-- something explicitly asks for it. The whole desktop is meant to stay on
-- the iGPU; the dGPU is for PRIME render offload only (`prime-run <cmd>`).
--
-- Without this line Hyprland enumerates BOTH cards -- verified live via
-- /proc/<pid>/fd, which listed card1 + renderD128 (the NVIDIA nodes)
-- alongside the Intel ones. It happens to render on Intel today only
-- because eDP-1 lives there, i.e. by luck of which card owns the panel,
-- not by configuration. Once the nvidia driver is loaded, nvidia_drm
-- modeset makes that card a KMS device the same enumeration will pick up.
--
-- aquamarine reads AQ_DRM_DEVICES at backend init (confirmed present in
-- libaquamarine.so.0.14.0), so it has to be set before the backend comes
-- up -- hence this block sitting above MONITORS rather than down in the
-- ENVIRONMENT section with the other hl.env calls. Verified: setting it
-- from here DOES reach the backend (an earlier wrong value crash-looped
-- the session, which proves the value is read this early).
--
-- ############ DO NOT PUT A by-path PATH IN HERE ############
-- AQ_DRM_DEVICES is a COLON-SEPARATED LIST -- aquamarine parses it with
-- CVarList(explicitGpus, 0, ':', true). PCI by-path names contain colons,
-- so "/dev/dri/by-path/pci-0000:00:02.0-card" is shredded into three
-- fragments and every one of them fails to resolve:
--     drm: Failed to canonicalize path /dev/dri/by-path/pci-0000
--     drm: Failed to canonicalize path 00
--     drm: Failed to canonicalize path 02.0-card
--     drm: Found no gpus to use, cannot continue
-- -> CBackend::create() failed -> Hyprland aborts at startup -> black
-- screen and a greetd crash-loop (7 sessions in 21s). Cost one TTY
-- recovery to find. The value handed to aquamarine must be a plain
-- /dev/dri/cardN with no colons in it.
--
-- But a hardcoded cardN is ALSO wrong: numbering is probe-order dependent
-- and is already counterintuitive here (nouveau took card1 despite the
-- HIGHER PCI address, i915 got card2), and installing the nvidia driver
-- can reshuffle it. So resolve the PCI address -> cardN at config-parse
-- time instead, which is stable by construction.
--
-- FAIL-SAFE: if resolution fails or returns anything that isn't an
-- existing /dev/dri/cardN, AQ_DRM_DEVICES is left UNSET. Unset means
-- Hyprland enumerates every GPU -- which is merely the old, working,
-- unpinned behaviour. It must never be possible for this block to hand
-- aquamarine a bad value and take the session down again.
--
-- NOTE: HDMI-A-1 is wired to the dGPU (card1-HDMI-A-1), so external HDMI
-- output is deliberately given up by this pin. USB-C/DP-alt runs off the
-- iGPU and is unaffected. Revisit only if HDMI out is actually needed.
-- Supplied by hardware.env. When absent, resolve_igpu_node() below returns nil
-- and AQ_DRM_DEVICES is simply never set, which is the old unpinned behaviour.
local IGPU_PCI = hw.IGPU_PCI

local function sh(cmd)
    local p = io.popen(cmd .. " 2>/dev/null")
    if not p then return nil end
    local out = p:read("*l")
    p:close()
    return out
end

local function resolve_igpu_node()
    if not IGPU_PCI or IGPU_PCI == "" then return nil end
    -- primary: udev's by-path symlink, resolved to its real cardN target
    local node = sh("readlink -f /dev/dri/by-path/pci-" .. IGPU_PCI .. "-card")
    -- fallback: ask sysfs which cardN this PCI device owns
    if not (node and node:match("^/dev/dri/card%d+$")) then
        -- sh() appends 2>/dev/null to the END of the pipeline, which does not
        -- cover ls's own stderr; redirect it here or a machine without this PCI
        -- path prints an error into Hyprland's log on every config parse.
        local name = sh("ls /sys/bus/pci/devices/" .. IGPU_PCI .. "/drm/ 2>/dev/null | grep -m1 -E '^card[0-9]+$'")
        node = name and ("/dev/dri/" .. name) or nil
    end
    -- the pattern anchor is what guarantees no colon ever reaches aquamarine
    if node and node:match("^/dev/dri/card%d+$") and sh("test -e '" .. node .. "' && echo ok") == "ok" then
        return node
    end
    return nil
end

local igpuNode = resolve_igpu_node()
if igpuNode then
    hl.env("AQ_DRM_DEVICES", igpuNode)
end


------------------------------------------------------------------
-- MONITORS
------------------------------------------------------------------
-- Original: monitor = eDP-1, 2880x1620@120, 0x0, 2
-- Values come from hardware.env. The fallbacks are Hyprland's own catch-all
-- (output "" matches any monitor, preferred/auto let it pick) — confirmed
-- against upstream's example/hyprland.lua. That is deliberately NOT this
-- laptop's 2880x1620@120: a config that cannot find its profile must still
-- light up an unknown panel.
hl.monitor({
    output   = hw.PRIMARY_MONITOR  or "",
    mode     = hw.MONITOR_MODE     or "preferred",
    position = hw.MONITOR_POSITION or "auto",
    scale    = num_or_string(hw.MONITOR_SCALE, "auto"),
})
-- Original (commented out):
-- hl.monitor({ output = "HDMI-A-1", mode = "1920x1080@60", position = "0x0", scale = 1 })


------------------------------------------------------------------
-- ENVIRONMENT VARIABLES
------------------------------------------------------------------
-- unscale XWayland
hl.config({
    xwayland = {
        force_zero_scaling = true,
    },
})

-- includes flatpak's exported .desktop/icon dirs so flatpak apps (e.g. JASP)
-- show up in menus/launchers session-wide, not just in a shell where the
-- user manually exported it (a per-shell `export` never reaches Quickshell/
-- other GUI children, since they're spawned by Hyprland, not a login shell)
hl.env("XDG_DATA_DIRS", "/var/lib/flatpak/exports/share:" .. os.getenv("HOME") .. "/.local/share/flatpak/exports/share:/usr/local/share:/usr/share")
hl.env("TERMINAL", "kitty")
hl.env("EDITOR", "vim")

-- toolkit-specific scale
-- GDK_SCALE only accepts an INTEGER. Setting it to 2 on a 1x display makes
-- every GTK app twice the size it should be, so it is set only when the
-- monitor scale is a whole number above 1.
local _gdkScale = tonumber(hw.MONITOR_SCALE or "")
if _gdkScale and _gdkScale > 1 and _gdkScale == math.floor(_gdkScale) then
    hl.env("GDK_SCALE", tostring(math.floor(_gdkScale)))
end
hl.env("GDK_BACKEND", "wayland")
hl.env("GTK_USE_PORTAL", "0")


------------------------------------------------------------------
-- CURSORS
------------------------------------------------------------------
hl.env("XCURSOR_THEME", "Bibata-Original-Ice")
hl.env("XCURSOR_SIZE", "28")


------------------------------------------------------------------
-- MY DEFAULT PROGRAMS
------------------------------------------------------------------
-- Old hyprlang used $variables. In Lua these are just local variables.
local terminal    = "kitty"
local fileManager = "nautilus --new-window"


------------------------------------------------------------------
-- AUTOSTART
------------------------------------------------------------------
-- exec-once becomes commands run inside the "hyprland.start" event.
-- One hl.on(...) block holds all of them; order is preserved.
hl.on("hyprland.start", function()
    -- D-Bus / systemd environment MUST come before the session target
    hl.exec_cmd("dbus-update-activation-environment --systemd --all && systemctl --user start hyprland-session.target")

    -- GVFS early (so nautilus doesn't wait for it)
    hl.exec_cmd("/usr/lib/gvfsd")
    hl.exec_cmd("/usr/lib/gvfsd-fuse $XDG_RUNTIME_DIR/gvfs -f")

    -- Fills TOUCHPAD_DEVICE into hardware.env on the first login after a fresh
    -- install: it is the one hardware fact that needs a running compositor, so
    -- install.sh cannot get it from a TTY. Returns in ~10ms on every later boot
    -- once the name is recorded. See scripts/complete-hardware-profile.sh.
    hl.exec_cmd("~/.config/scripts/complete-hardware-profile.sh")

    hl.exec_cmd("hyprpaper")
    hl.exec_cmd("hypridle")
    -- elephant + walker replaced by finder/ (native Quickshell reimplementation,
    -- no elephant backend needed) — left here commented, not deleted, in case
    -- of rollback.
    -- hl.exec_cmd("elephant")
    hl.exec_cmd("hyprpm reload")
    -- hl.exec_cmd("walker --gapplication-service")
    hl.exec_cmd("/usr/bin/lxqt-policykit-agent")
    hl.exec_cmd("~/.config/scripts/battery_notify.sh")
    -- re-applies the taskbar battery panel's saved charge cap (sysfs
    -- resets to 100 on every boot) — see scripts/apply-battery-threshold.sh
    hl.exec_cmd("~/.config/scripts/apply-battery-threshold.sh")
    -- sync the mic LED to actual mute state right away, don't wait for the
    -- first F9 press (see scripts/micmute-led.sh)
    hl.exec_cmd("~/.config/scripts/micmute-led.sh sync")
    -- macdock + macswitcher merged into one Quickshell instance (macshell)
    hl.exec_cmd("~/.config/macshell/macshell-launch.sh")
    hl.exec_cmd("~/.config/taskbar/taskbar-launch.sh")
    hl.exec_cmd("~/.config/finder/finder-launch.sh")

    -- hl.exec_cmd("localsearch daemon -s")
end)


------------------------------------------------------------------
-- LOOK AND FEEL
------------------------------------------------------------------
hl.config({
    general = {
        gaps_in          = 3,
        gaps_out         = 5,
        border_size      = 2,
        -- col.active_border in hyprlang becomes a nested col table here.
        col = {
            active_border = color7, -- was $color7
        },
        resize_on_border = true,
        allow_tearing    = false,
        layout           = "dwindle",
    },

    decoration = {
        rounding          = 16,
        active_opacity    = 0.95,
        inactive_opacity  = 0.85,
        fullscreen_opacity = 1,
        dim_special       = 0.1,
        blur = {
            enabled          = true,
            size             = 3,
            passes           = 5,
            new_optimizations = true,
            ignore_opacity   = true,
            xray             = false,
            popups           = true,
        },
        shadow = {
            enabled      = true,
            range        = 5,
            render_power = 2,
        },
    },

    animations = {
        enabled = true,
    },

    dwindle = {
        preserve_split = true,
    },

    misc = {
        force_default_wallpaper = 1,
        disable_hyprland_logo   = true,
        focus_on_activate       = true,
    },
})

-- Permission rule (was misc.permission in hyprlang).
hl.permission("/usr/(bin|local/bin)/hyprpm", "plugin", "allow")

-- Animation curves (`bezier` in hyprlang) are now hl.curve(...).
-- Points are given as a list of {x, y} control-point pairs.
hl.curve("linear", { type = "bezier", points = { {0, 0}, {1, 1} } })
hl.curve("swirl",  { type = "bezier", points = { {0.02, 1}, {0.2, 1.2} } })

-- animation = NAME, ONOFF, SPEED, CURVE[, STYLE]  →  hl.animation({...})
-- A style like "popin 0%" goes in the `style` field.
hl.animation({ leaf = "windows",            enabled = true, speed = 3, bezier = "swirl",  style = "popin 0%" })
hl.animation({ leaf = "windowsOut",         enabled = true, speed = 3, bezier = "linear", style = "popin 0%" })
hl.animation({ leaf = "fade",               enabled = true, speed = 2, bezier = "linear" })
hl.animation({ leaf = "workspaces",         enabled = true, speed = 2, bezier = "linear" })
hl.animation({ leaf = "specialWorkspaceIn", enabled = true, speed = 6, bezier = "swirl",  style = "slidefadevert -50%" })
hl.animation({ leaf = "specialWorkspaceOut",enabled = true, speed = 6, bezier = "swirl",  style = "fade" })


------------------------------------------------------------------
-- PLUGINS
------------------------------------------------------------------
-- IMPORTANT: plugin OPTIONS go through hl.config under a `plugin`
-- table, exactly like every other config section. (hl.plugin.<name>
-- is a NAMESPACE holding plugin *functions* such as add_button — it
-- is NOT itself callable. Calling it errors with
-- "attempt to call a table value".)
--
-- Per the hyprbars README:
--   options -> hl.config({ plugin = { hyprbars = { ... } } })
--   buttons -> hl.plugin.hyprbars.add_button({ ... }) one per button
hl.config({
    plugin = {
        hyprbars = {
            bar_height               = 22,
            bar_blur                 = false,
            bar_part_of_window       = true,
            bar_precedence_over_border = true,

            bar_color = "rgba(106, 107, 105, 0.4)", -- was $color2 in pywal comments

            -- `col.text` was the hyprlang key for title text color.
            -- Kept under a nested col table; if hyprbars rejects it,
            -- the title is disabled anyway (bar_title_enabled = false).
            col = {
                text = "rgba(255, 255, 255, 0)",
            },

            bar_text_size    = 10,
            bar_text_font    = "JetBrainsMono Nerd Font Propo",
            bar_text_align   = "center",
            bar_title_enabled = false,

            bar_button_padding = 5,
            bar_padding        = 8,
            icon_on_hover      = true,

            bar_buttons_alignment = "left",
        },
    },
})

-- Buttons are added individually. The Lua field names come from the
-- hyprbars README: bg_color, fg_color, size, icon, action.
-- Original hyprlang form was:  hyprbars-button = COLOR, SIZE, ICON, ON_CLICK
-- (fg_color is the optional 5th arg; your originals had a blank icon).
--
-- IMPORTANT: `action` is still a raw shell command (hyprbars just execs it),
-- but since Hyprland 0.55 `hyprctl dispatch` itself takes a Lua expression
-- (it's shorthand for `eval 'hl.dispatch(...)'`), not the old
-- `dispatchname arg1 arg2` string. The old-style commands here
-- (`hyprctl dispatch killactive`, `... resizeactive exact ...`) would now
-- fail to parse as Lua and silently no-op — quoted as 'hl.dsp...(...)' below.
hl.plugin.hyprbars.add_button({
    bg_color = "rgb(ff5f57)",
    fg_color = "rgb(ffffff)",
    size     = 12,
    icon     = "",
    action   = "hyprctl dispatch 'hl.dsp.window.close()'",
})
hl.plugin.hyprbars.add_button({
    bg_color = "rgb(febb2e)",
    fg_color = "rgb(ffffff)",
    size     = 12,
    icon     = "",
    action   = "~/.config/scripts/hyprbars-minimize.sh",
})
hl.plugin.hyprbars.add_button({
    bg_color = "rgb(28c840)",
    fg_color = "rgb(ffffff)",
    size     = 12,
    icon     = "",
    action   = "hyprctl dispatch 'hl.dsp.window.resize({ x = 1425, y = 733 })' && hyprctl dispatch 'hl.dsp.window.move({ x = 7, y = 69 })'",
})

-- hymission had an empty block in the original — no options to set, so
-- there is simply nothing to emit here. (Do NOT call hl.plugin.hymission;
-- same "call a table value" trap.)


------------------------------------------------------------------
-- INPUT
------------------------------------------------------------------
hl.config({
    input = {
        kb_layout    = "us",
        follow_mouse = 1,
        sensitivity  = 0, -- -1.0 - 1.0, 0 means no modification.
        touchpad = {
            natural_scroll = true,
        },
    },
})

-- Gestures (was commented out in the original):
-- hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace", scale = 1.5 })

-- toggle-touchpad.sh flips this device at runtime via `hyprctl eval`. The name
-- is machine-specific, so it comes from the profile; with no profile there is
-- simply no device block, which is harmless (enabled = true is the default).
if hw.TOUCHPAD_DEVICE then
    hl.device({
        name    = hw.TOUCHPAD_DEVICE,
        enabled = true,
    })
end


------------------------------------------------------------------
-- KEYBINDINGS
------------------------------------------------------------------
-- $mainMod = SUPER  →  a local. Key combos are single strings joined with " + ".
local mainMod = "SUPER"

hl.bind(mainMod .. " + Q", hl.dsp.exec_cmd(terminal))
hl.bind(mainMod .. " + E", hl.dsp.exec_cmd(fileManager))
-- finder/ replaces walker (native Quickshell reimplementation); toggled via
-- its persistent IPC socket, same convention as macshell's switcher socat bind below.
hl.bind("ALT + S", hl.dsp.exec_cmd("echo \"open:default\" | socat - UNIX-CONNECT:/tmp/finder.sock"))
-- File Search (finder/, filesearch mode — restricted to non-hidden files
-- under $HOME via fd's own defaults, see FileSearch.qml)
hl.bind("ALT + F", hl.dsp.exec_cmd("echo \"open:filesearch\" | socat - UNIX-CONNECT:/tmp/finder.sock"))
hl.bind(mainMod .. " + C", hl.dsp.window.close())
hl.bind(mainMod .. " + W", hl.dsp.window.float({ action = "toggle" }))
-- Native dispatch calls instead of shelling out to `hyprctl dispatch` with
-- the old positional syntax (`resizeactive exact W H`), which no longer
-- parses under 0.55's `hyprctl dispatch 'hl.dsp...(...)'` calling convention.
hl.bind(mainMod .. " + D", function()
    hl.dispatch(hl.dsp.window.resize({ x = 1425, y = 733 }))
    hl.dispatch(hl.dsp.window.move({ x = 7, y = 69 }))
end)
hl.bind(mainMod .. " + F", hl.dsp.window.fullscreen())

-- Move focus with mainMod + arrow keys.
-- The original ran two dispatchers per key (movefocus + bringactivetotop).
-- A Lua function lets one bind fire several dispatchers in order.
hl.bind("SUPER + Left", function()
    hl.dispatch(hl.dsp.focus({ direction = "left" }))
    hl.dispatch(hl.dsp.window.bring_to_top())
end)
hl.bind("SUPER + Right", function()
    hl.dispatch(hl.dsp.focus({ direction = "right" }))
    hl.dispatch(hl.dsp.window.bring_to_top())
end)
hl.bind("SUPER + Up", function()
    hl.dispatch(hl.dsp.focus({ direction = "up" }))
    hl.dispatch(hl.dsp.window.bring_to_top())
end)
hl.bind("SUPER + Down", function()
    hl.dispatch(hl.dsp.focus({ direction = "down" }))
    hl.dispatch(hl.dsp.window.bring_to_top())
end)

-- Switch / move-to workspaces with mainMod + [0-9].
-- A loop replaces the 20 repetitive bind lines. key 0 maps to workspace 10.
for i = 1, 10 do
    local key = i % 10 -- 10 -> "0"
    hl.bind(mainMod .. " + " .. key,         hl.dsp.focus({ workspace = i }))
    hl.bind(mainMod .. " + SHIFT + " .. key, hl.dsp.window.move({ workspace = i }))
end

-- Special workspace (scratchpad)
hl.bind(mainMod .. " + S",         hl.dsp.workspace.toggle_special("magic"))
hl.bind(mainMod .. " + SHIFT + S", hl.dsp.window.move({ workspace = "special:magic" }))

-- movetoworkspacesilent -> window.move({ workspace, follow = false }) natively,
-- instead of shelling out to `hyprctl dispatch` with the old dispatcher name.
hl.bind("SUPER + X", hl.dsp.window.move({ workspace = "special:magic", follow = false }))

-- Scroll through workspaces with mainMod + scroll
hl.bind(mainMod .. " + mouse_down", hl.dsp.focus({ workspace = "e+1" }))
hl.bind(mainMod .. " + mouse_up",   hl.dsp.focus({ workspace = "e-1" }))

-- Macswitcher
hl.bind("ALT + Tab",         hl.dsp.exec_cmd("echo \"next\"    | socat - UNIX-CONNECT:/tmp/macswitcher.sock"))
hl.bind("ALT + SHIFT + Tab", hl.dsp.exec_cmd("echo \"prev\"    | socat - UNIX-CONNECT:/tmp/macswitcher.sock"))
-- bindrt = release + transparent (r + t)
hl.bind("ALT + Alt_L",       hl.dsp.exec_cmd("echo \"confirm\" | socat - UNIX-CONNECT:/tmp/macswitcher.sock"), { release = true, transparent = true })

-- Move/resize windows with mainMod + LMB/RMB and dragging
-- bindm = mouse bind ({ mouse = true })
hl.bind(mainMod .. " + mouse:272", hl.dsp.window.drag(),   { mouse = true })
hl.bind(mainMod .. " + R",         hl.dsp.window.resize(), { mouse = true })
-- SUPER + A removed: it ran ~/.config/scripts/hymission-fix.sh, which does
-- not exist (never written), and the hymission plugin is not loaded either —
-- hyprpm lists only hyprbars. The key was doing nothing at all.

-- Toggle Layout (the old plugin:xtd:throwunfocused bind on this same key
-- in the .conf is dead/superseded — SUPER + T is toggle-layout only)
hl.bind("SUPER + T", hl.dsp.exec_cmd("~/.config/scripts/toggle-layout.sh"))

------------------------------------------------------------------
-- Brightness and Volume controls
------------------------------------------------------------------

-- Volume
hl.bind("F1", hl.dsp.exec_cmd("pactl set-sink-mute @DEFAULT_SINK@ toggle && qs -p ~/.config/taskbar ipc call osd volume"))
hl.bind("F2", hl.dsp.exec_cmd("pactl set-sink-volume @DEFAULT_SINK@ -5% && qs -p ~/.config/taskbar ipc call osd volume"), { repeating = true })
hl.bind("F3", hl.dsp.exec_cmd("wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+ && qs -p ~/.config/taskbar ipc call osd volume"), { repeating = true })

-- Brightness
hl.bind("F4", hl.dsp.exec_cmd("brightnessctl set 10%- && qs -p ~/.config/taskbar ipc call osd brightness"), { repeating = true })
hl.bind("F5", hl.dsp.exec_cmd("brightnessctl set +10% && qs -p ~/.config/taskbar ipc call osd brightness"), { repeating = true })

-- Keyboard backlight (unchanged)
hl.bind("F7", hl.dsp.exec_cmd("~/.config/scripts/kbdbacklight_toggle.sh"))

-- Mic mute (with OSD + keyboard LED sync). bindel = repeating + locked.
-- Routed through micmute-led.sh instead of a bare `pactl ... toggle` because
-- the kernel's own audio-micmute LED trigger drives the keyboard's mic LED
-- with the opposite polarity (lit = muted) from what's wanted (lit = on) —
-- see scripts/micmute-led.sh for the full story.
hl.bind("F9", hl.dsp.exec_cmd("~/.config/scripts/micmute-led.sh toggle"), { repeating = true, locked = true })

------------------------------------------------------------------
-- Random Tools
------------------------------------------------------------------
-- Emoji Picker (finder/, emoji mode)
hl.bind("SUPER + period", hl.dsp.exec_cmd("echo \"open:emoji\" | socat - UNIX-CONNECT:/tmp/finder.sock"))

-- Voice-to-text (voxtype, push-to-talk). Hold to record, release to transcribe
-- at the cursor. Two hl.bind() calls on one key is safe *here* only because
-- they differ by the `release` flag, so Hyprland registers them as distinct
-- binds -- verified live: `hyprctl binds -j` lists CTRL+period twice, once
-- with release:false and once with release:true.
--
-- The daemon must be running (`systemctl --user enable --now voxtype`) or both
-- binds are silent no-ops: `record start/stop` just signal an existing daemon.
hl.bind("CTRL + period", hl.dsp.exec_cmd("voxtype record start"))
hl.bind("CTRL + period", hl.dsp.exec_cmd("voxtype record stop"), { release = true })

-- Btop
hl.bind("F12", hl.dsp.exec_cmd("kitty --title btop -e zsh -i -c btop"))

-- Screenshot Utilities
hl.bind("F11",         hl.dsp.exec_cmd("hyprshot -m region -o ~/Pictures/Screenshots"))
hl.bind("ALT + Print", hl.dsp.exec_cmd("hyprshot -m window -o ~/Pictures/Screenshots"))
hl.bind("Print",       hl.dsp.exec_cmd("hyprshot -m active -m output -o ~/Pictures/Screenshots"))

-- Colorpicker
hl.bind("ALT + C", hl.dsp.exec_cmd("hyprpicker -a"))

-- Clipboard (finder/, clipboard mode)
hl.bind("SUPER + V", hl.dsp.exec_cmd("echo \"open:clipboard\" | socat - UNIX-CONNECT:/tmp/finder.sock"))

-- Power Menu (finder/, powermenu mode)
hl.bind(mainMod .. " + Escape", hl.dsp.exec_cmd("echo \"open:powermenu\" | socat - UNIX-CONNECT:/tmp/finder.sock"))

-- Idle Inhibitor
hl.bind(mainMod .. " + I", hl.dsp.exec_cmd("~/.config/scripts/idle-inhibitor.sh"))

-- Toggle all Quickshell shells (macshell/taskbar/finder): kills
-- them if any are alive, relaunches them if all are dead. Deliberately
-- excludes lockscreen/ — see toggle-shells.sh for why.
hl.bind(mainMod .. " + K", hl.dsp.exec_cmd("~/.config/scripts/toggle-shells.sh"))

-- Power Profiles (finder/, powerprofiles mode)
hl.bind(mainMod .. " + B", hl.dsp.exec_cmd("echo \"open:powerprofiles\" | socat - UNIX-CONNECT:/tmp/finder.sock"))

-- Toggle Touchpad
hl.bind("F6", hl.dsp.exec_cmd("~/.config/scripts/toggle-touchpad.sh"))

-- LockScreen — replaced by the Quickshell lockscreen/ app (1:1 visual port
-- of the old hyprlock.conf, see that project directory). Old bind:
-- hl.bind(mainMod .. " + L", hl.dsp.exec_cmd("hyprlock"))
-- Goes through lockscreen-launch.sh, not a bare `quickshell -c ...`, since
-- it must guard against double-launch without ever pkill-ing an existing
-- instance (killing a live WlSessionLock process leaves the compositor
-- permanently locked with nothing listening) — see that script's comment.
hl.bind(mainMod .. " + L", hl.dsp.exec_cmd("~/.config/lockscreen/lockscreen-launch.sh"))

-- Wallpaper Picker (finder/, wallpaper mode)
hl.bind("ALT + W", hl.dsp.exec_cmd("echo \"open:wallpaper\" | socat - UNIX-CONNECT:/tmp/finder.sock"))

-- Study
-- Personal shortcut: edit studyDir (or drop this bind) on a machine where
-- that folder does not exist. Nothing else depends on it.
local studyDir = os.getenv("HOME") .. "/college/year-4/sleep deprivv project"
hl.bind("SUPER + G", hl.dsp.exec_cmd("nautilus \"" .. studyDir .. "\""))


------------------------------------------------------------------
-- WINDOW RULES
------------------------------------------------------------------
-- Each `windowrule { ... }` block becomes one hl.window_rule({...}).
-- `match:class` / `match:title` become a `match = { class=..., title=... }`
-- table; the action keys (float, size, move, center, ...) sit alongside it.

-- Remember the size you manually resized for floating windows (per class + title)
hl.window_rule({
    name  = "remember-float-size",
    match = { class = ".*" },
    persistent_size = true,
})

-- Global: Float everything by default + sensible default size + center new windows
--
-- Deliberately a GLOBAL (no `local`), not a throwaway call: toggle-layout.sh
-- used to flip this rule's `float = on/off` by sed-editing hyprland.conf and
-- `hyprctl reload`-ing — dead now that hyprland.lua is the active config
-- (sed-editing the old .conf no longer does anything). Instead the script
-- flips this rule at runtime with:
--   hyprctl eval 'globalFloatRule:set_enabled(false)'  -- new windows tile
--   hyprctl eval 'globalFloatRule:set_enabled(true)'   -- new windows float
-- (relies on hyprctl eval/dispatch running in the same persistent Lua state
-- that loaded this config, so this global stays reachable — the same
-- mechanism the official example uses for e.g. `closeWindowBind:set_enabled(false)`.
-- Verify with `hyprctl repl 'globalFloatRule'` after a reload if it misbehaves.)
globalFloatRule = hl.window_rule({
    name   = "global-float",
    match  = { class = ".*" },
    float  = true,
    size   = {950, 550}, -- default size; percentages are reliable across monitors
    center = true,
})

-- Kitty (terminal)
hl.window_rule({
    name   = "kitty-float",
    match  = { class = "^(kitty)$" },
    size   = {750, 430},
    center = true,
})

-- Browsers
hl.window_rule({
    name  = "browsers-float",
    match = { class = "^(librewolf|brave-browser|chromium)$" },
    size  = {1250, 660},
    move  = {95, 72},
})

-- Zen Browser
hl.window_rule({
    name   = "zen-float",
    match  = { class = "^(zen)$" },
    size   = {1125, 640},
    move   = {42, 85},
})

-- Kitty-based tools
hl.window_rule({
    name   = "kitty-tools-float",
    match  = { class = "^(kitty)$", title = "^(bluetui|impala|pulsemixer|wiremix|calcurse)$" },
    center = true,
    size   = {870, 500},
})

-- Btop
hl.window_rule({
    name   = "btop-float",
    match  = { class = "^(kitty)$", title = "^(btop)$" },
    center = true,
    size   = {970, 550},
})

-- MPV
hl.window_rule({
    name   = "mpv-float",
    match  = { class = "^(mpv)$" },
    size   = {800, 450},
    center = true,
})

-- Zathura (PDF viewer)
hl.window_rule({
    name   = "zathura-float",
    match  = { class = "^(org.pwmt.zathura)$" },
    center = true,
    size   = {870, 650},
})

-- Calculator
hl.window_rule({
    name  = "calc-float",
    match = { class = "^(org.gnome.Calculator)$" },
    size  = {380, 615},
    move  = {986, 103},
})

-- Calendar
hl.window_rule({
    name  = "calendar-float",
    match = { class = "^(org.gnome.Calendar)$" },
    size  = {620, 600},
    move  = {10, 75},
})

-- imv
hl.window_rule({
    name   = "imv-float",
    match  = { class = "^(imv)$" },
    size   = {700, 400},
    center = true,
})

-- Browser upload files
hl.window_rule({
    name   = "file-upload-float",
    match  = { class = "^(xdg-desktop-portal-gtk|Firefox)$", title = "^(Open Files|File Upload)$" },
    float  = true,
    center = true,
})

-- Nomacs
hl.window_rule({
    name        = "nomacs-float",
    match       = { class = "^(org.nomacs.ImageLounge)$" },
    workspace   = "special:magic",
    no_blur     = true,
    border_size = 1,
    no_shadow   = true,
})

-- Nautilus
hl.window_rule({
    name  = "nautilus-float",
    match = { class = "^(org.gnome.Nautilus)$" },
    size  = {850, 490},
    move  = {483, 123},
})

-- Evince Docs
hl.window_rule({
    name  = "evince-float",
    match = { class = "^(org.gnome.Evince)$" },
    size  = {800, 670},
    move  = {630, 75},
})

-- Papers Docs
hl.window_rule({
    name  = "papers-float",
    match = { class = "^(org.gnome.Papers)$" },
    size  = {800, 670},
    move  = {630, 75},
})

-- Camera
hl.window_rule({
    name   = "camera-float",
    match  = { class = "^(org.gnome.Snapshot)$" },
    center = true,
    size   = {740, 420},
})

-- Spotify
-- class matches both "Spotify" (old XWayland WM_CLASS) and "spotify" (native
-- Wayland app-id, used since ~/.config/spotify-flags.conf added
-- --ozone-platform=wayland to fix a blurry cursor over the XWayland surface)
hl.window_rule({
    name  = "spotify-float",
    match = { class = "^([Ss]potify)$" },
    size  = {1200, 670},
    move  = {10, 75},
    float = true,
})

-- Codium
hl.window_rule({
    name  = "codium-float",
    match = { class = "^(codium)$" },
    size  = {1150, 650},
    move  = {118, 88},
})

-- TRW
hl.window_rule({
    name  = "TRW-float",
    match = { class = "^(chrome-app.jointherealworld.com__checklist-Default)$" },
    size  = {1425, 725},
    move  = {7, 77},
})

-- Tradingview
hl.window_rule({
    name  = "tradingview-float",
    match = { class = "^(chrome-www.tradingview.com__chart_lCRrEItS_-Default)$" },
    size  = {1425, 725},
    move  = {7, 77},
})

-- Instagram
hl.window_rule({
    name   = "instagram-float",
    match  = { class = "^(chrome-www.instagram.com__-Default)$" },
    size   = {950, 550},
    center = true,
})

-- Whatsapp
hl.window_rule({
    name  = "whatsapp-float",
    match = { class = "^(chrome-web.whatsapp.com__-Default)$" },
    size  = {1200, 670},
    move  = {6, 75},
})

-- Chatgpt
hl.window_rule({
    name   = "chatgpt-float",
    match  = { class = "^(chrome-chat.openai.com__-Default)$" },
    size   = {910, 550},
    center = true,
})

-- Grok
hl.window_rule({
    name   = "grok-float",
    match  = { class = "^(chrome-grok.com__-Default)$" },
    size   = {910, 550},
    center = true,
})

-- Claude
hl.window_rule({
    name   = "claude-float",
    match  = { class = "^(chrome-claude.ai__new-Default)$" },
    size   = {910, 550},
    center = true,
})

-- Coursera
hl.window_rule({
    name  = "coursera-float",
    match = { class = "^(chrome-www.coursera.org__-Default)$" },
    size  = {1425, 725},
    move  = {7, 77},
})

-- Prime Video
hl.window_rule({
    name  = "primevideo-float",
    match = { class = "^(chrome-www.primevideo.com__region_eu_storefront-Default)$" },
    size  = {1190, 625},
    move  = {78, 95},
})

-- Youtube
hl.window_rule({
    name   = "youtube-float",
    match  = { class = "^(brave-www.youtube.com__-Default)$" },
    size   = {1200, 650},
    center = true,
})
