-- The desktop palette as the colorscheme. See lua/hyprahaan/theme.lua.
return {
  {
    "LazyVim/LazyVim",
    opts = { colorscheme = "hyprahaan" },
  },
  {
    "folke/tokyonight.nvim",
    init = function()
      require("hyprahaan.theme").watch()
    end,
  },
}
