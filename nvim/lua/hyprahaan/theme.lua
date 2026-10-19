-- The desktop palette, in neovim.
--
-- Every other surface on this desktop takes its colours from ~/.cache/wal
-- (see ~/projects/hyprahaan/scripts/palette.sh), and so does this. It does not
-- care whether the cache was written by `wal --theme <palette>` or `wal -i
-- <wallpaper>`: both leave the same sixteen slots in colors.json.
--
-- Sixteen slots are not a colorscheme, though. Treesitter, LSP, diagnostics,
-- and every plugin LazyVim ships (snacks, blink, which-key, noice, lualine,
-- bufferline, gitsigns …) each want their own groups, and writing those by hand
-- is writing a colorscheme. tokyonight already is one, already installed, with
-- a group file for every one of those plugins, and it derives all of them from
-- a ~40-entry Palette table. So this file's whole job is the mapping
-- wal slot -> tokyonight Palette entry; tokyonight does the rest.
--
-- The one deliberate choice in the mapping: `blue` is color9, not color4.
-- tokyonight spends `blue` on functions, the cursor-line, the lualine NORMAL
-- block, float borders and selected picker rows — i.e. it is tokyonight's
-- accent. color9 is this desktop's accent (palette.sh's header explains why it
-- is not bright red), the colour of every selected row in the bar and launcher,
-- so nvim's selections wear the same colour as the rest of the desktop. Across
-- the shipped palettes color9 == color4 in most of them anyway.
local M = {}

local WAL = vim.fn.expand("~/.cache/wal")
local JSON = WAL .. "/colors.json"

local function rgb(c)
  return tonumber(c:sub(2, 3), 16), tonumber(c:sub(4, 5), 16), tonumber(c:sub(6, 7), 16)
end

-- a over b at alpha (0 = b, 1 = a)
local function mix(a, alpha, b)
  local ar, ag, ab = rgb(a)
  local br, bg, bb = rgb(b)
  local function ch(x, y)
    return math.floor(math.min(math.max(alpha * x + (1 - alpha) * y, 0), 255) + 0.5)
  end
  return string.format("#%02x%02x%02x", ch(ar, br), ch(ag, bg), ch(ab, bb))
end

-- Relative luminance (WCAG). colors.json carries no light/dark flag — the
-- palettes/*.json "mode" key does not survive `wal --theme` — and a wallpaper
-- palette has none to carry, so the background is measured instead.
local function is_light(hex)
  local function lin(v)
    v = v / 255
    return v <= 0.03928 and v / 12.92 or ((v + 0.055) / 1.055) ^ 2.4
  end
  local r, g, b = rgb(hex)
  return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b) > 0.4
end

local function read()
  local f = io.open(JSON, "r")
  if not f then return nil end
  local ok, data = pcall(vim.json.decode, f:read("*a"))
  f:close()
  -- pywal writes the file in place, so a read can land mid-write and see a
  -- truncated document. Treated as "no palette yet"; the watcher fires again
  -- when the write completes.
  if not ok or type(data) ~= "table" or not data.colors or not data.special then return nil end
  local c = data.colors
  for i = 0, 15 do
    if type(c["color" .. i]) ~= "string" or not c["color" .. i]:match("^#%x%x%x%x%x%x$") then return nil end
  end
  return data
end

local function palette(data)
  local c, s = data.colors, data.special
  local bg, fg = s.background, s.foreground
  local light = is_light(bg)
  -- Sidebars, popups and the statusline sit one step off the editor ground —
  -- darker on a dark palette, as tokyonight's own do. On a light palette
  -- "darker" means toward the (dark) foreground.
  local bg_dark = light and mix(fg, 0.05, bg) or mix(bg, 0.75, "#000000")
  return light,
    {
      bg = bg,
      bg_dark = bg_dark,
      bg_dark1 = light and mix(fg, 0.09, bg) or mix(bg, 0.55, "#000000"),
      bg_highlight = mix(fg, 0.07, bg),
      fg = fg,
      fg_dark = c.color7,
      fg_gutter = mix(fg, 0.22, bg),
      comment = c.color8,
      dark3 = mix(c.color8, 0.8, bg),
      dark5 = mix(fg, 0.5, bg),
      terminal_black = c.color8,

      blue = c.color9,
      blue0 = mix(c.color9, 0.55, bg), -- search / visual ground
      blue1 = c.color12,
      blue2 = c.color14,
      blue5 = c.color12,
      blue6 = c.color14,
      blue7 = mix(c.color9, 0.25, bg),
      cyan = c.color6,
      teal = c.color14,
      green = c.color2,
      green1 = c.color14,
      green2 = c.color6,
      magenta = c.color5,
      magenta2 = c.color13,
      purple = c.color13,
      red = c.color1,
      red1 = c.color1,
      orange = c.color11,
      yellow = c.color3,
      git = { add = c.color2, change = c.color4, delete = c.color1 },
    }
end

function M.load()
  local data = read()
  if not data then
    -- No wal cache at all (fresh machine, before install.sh's theme phase).
    vim.cmd.colorscheme("tokyonight-night")
    return
  end
  local light, pal = palette(data)
  vim.o.background = light and "light" or "dark"
  -- A style is just a key in this table; tokyonight indexes it with
  -- opts.style and calls it if it is a function. Its highlight cache is keyed
  -- on the style name but invalidated on the palette's contents, so a palette
  -- change can never be served stale groups.
  require("tokyonight.colors").styles.hyprahaan = function() return vim.deepcopy(pal) end
  -- theme.setup, not tokyonight.load: load() forces vim.o.background back to
  -- "dark" for any style that is not literally "day".
  require("tokyonight.theme").setup({ style = "hyprahaan" })
  vim.g.colors_name = "hyprahaan"
end

-- Repaint an already-open nvim when the palette changes, the same way the bar
-- and lock screen follow it: by watching the cache, not by being told. Nothing
-- in palette.sh knows nvim exists.
--
-- The directory is watched, not the file: an inotify watch on a file that is
-- replaced rather than rewritten goes deaf after the first change. And wal
-- rewrites ~20 files per apply, so changes are coalesced and only colors.json
-- counts.
local timer
function M.watch()
  local w = vim.uv.new_fs_event()
  if not w or vim.fn.isdirectory(WAL) == 0 then return end
  timer = timer or vim.uv.new_timer()
  w:start(WAL, {}, function(err, name)
    if err or name ~= "colors.json" then return end
    timer:stop()
    timer:start(200, 0, vim.schedule_wrap(function()
      -- Only while it is the scheme in use: someone who ran :colorscheme
      -- something-else has made a choice, as with a static palette over a
      -- wallpaper.
      if vim.g.colors_name == "hyprahaan" then M.load() end
    end))
  end)
end

return M
