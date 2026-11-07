-- nvim-firstrun.lua — finish LazyVim's first launch at install time, and wait for it.
--
-- Run by phase_apps, after `nvim --headless "+Lazy! restore" +qa` has cloned the
-- plugins pinned in lazy-lock.json:
--     nvim --headless -c "luafile install/lib/nvim-firstrun.lua"
--
-- Why it exists (2026-11-08 VM run): on a fresh machine the FIRST nvim launch starts
-- downloads in the background — Mason's tools (stylua, shfmt, tree-sitter-cli) and
-- every treesitter parser. Quit before they finish (`nvim --headless +qa`, or a person
-- closing the window) and Mason records "Installation was aborted" and shows
-- "Failed to install `tree-sitter-cli` with `mason.nvim`" on that launch. Doing the
-- first launch here, synchronously, means the person's first launch has nothing left
-- to fetch. Measured in an empty profile on this machine: 27/27 parsers in 10.5 s.
--
-- Exits 0 when everything landed, 1 otherwise (the installer warns, not dies: nvim
-- itself retries the rest on the next launch).
local failed = {}

local function opts(name)
  local p = require("lazy.core.config").plugins[name]
  return p and require("lazy.core.plugin").values(p, "opts", false) or {}
end

-- Deferred so LazyVim's own startup (VeryLazy and friends) has run first.
vim.defer_fn(function()
  -- ── Mason ──────────────────────────────────────────────────────────────
  -- tree-sitter-cli is not in mason's ensure_installed: LazyVim's treesitter spec
  -- installs it through Mason on demand, which is exactly the download that got cut off.
  local ok_m = pcall(require("lazy").load, { plugins = { "mason.nvim" } })
  local ok_r, reg = pcall(require, "mason-registry")
  if ok_m and ok_r then
    local want = vim.list_extend({ "tree-sitter-cli" }, vim.deepcopy(opts("mason.nvim").ensure_installed or {}))
    -- On a fresh profile the registry itself is not downloaded yet: get_package
    -- fails for every name until refresh() has finished, so wait for that first.
    local refreshed = false
    reg.refresh(function() refreshed = true end)
    vim.wait(120000, function() return refreshed end, 200)
    for _, n in ipairs(want) do
      local ok, p = pcall(reg.get_package, n)
      if ok and not p:is_installed() and not p:is_installing() then p:install() end
    end
    vim.wait(300000, function()
      for _, n in ipairs(want) do
        local ok, p = pcall(reg.get_package, n)
        if not ok or p:is_installing() or not p:is_installed() then return false end
      end
      return true
    end, 500)
    for _, n in ipairs(want) do
      if not reg.is_installed(n) then table.insert(failed, "mason:" .. n) end
    end
  else
    table.insert(failed, "mason.nvim did not load")
  end

  -- ── treesitter parsers ─────────────────────────────────────────────────
  -- nvim-treesitter (main branch) compiles with tree-sitter-cli, so after Mason.
  local ok_t, ts = pcall(require, "nvim-treesitter")
  if ok_t and ts.install then
    local want = opts("nvim-treesitter").ensure_installed or {}
    pcall(function() ts.install(want):wait(600000) end)
    -- The compiled parser on disk. Not get_installed(): that counts a language as
    -- present from its query files alone, and reported 27/27 with every .so deleted.
    -- Not nvim_get_runtime_file() either: on a fresh profile site/parser does not
    -- exist at startup, and the lookup kept answering 0 for files that were there.
    local okc, cfg = pcall(require, "nvim-treesitter.config")
    local dir = (okc and cfg.get_install_dir and cfg.get_install_dir("parser"))
      or (vim.fn.stdpath("data") .. "/site/parser")
    for _, l in ipairs(want) do
      if not vim.uv.fs_stat(dir .. "/" .. l .. ".so") then
        table.insert(failed, "parser:" .. l)
      end
    end
  end

  if #failed > 0 then
    io.stderr:write("nvim first run incomplete: " .. table.concat(failed, " ") .. "\n")
    vim.cmd("cquit 1")
  else
    vim.cmd("qa")
  end
end, 2000)
