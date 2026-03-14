local config_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local project_root = vim.fn.fnamemodify(config_root .. "/..", ":p")
local data_root = vim.fn.stdpath("data") .. "/terminal-mate-minimal"
local site_root = data_root .. "/site"
local lazypath = data_root .. "/lazy/lazy.nvim"
local uv = vim.uv or vim.loop

vim.g.mapleader = " "
vim.g.maplocalleader = " "

-- Keep startup isolated from the user's regular config and packages.
vim.opt.packpath = site_root
vim.opt.runtimepath = table.concat({
  config_root,
  site_root,
  vim.env.VIMRUNTIME,
  site_root .. "/after",
  config_root .. "/after",
}, ",")

if not uv.fs_stat(lazypath) then
  local clone_output = vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "--branch=stable",
    "https://github.com/folke/lazy.nvim.git",
    lazypath,
  })

  if vim.v.shell_error ~= 0 then
    error("Failed to clone lazy.nvim:\n" .. clone_output)
  end
end

vim.opt.runtimepath:prepend(lazypath)

require("lazy").setup({
  {
    dir = project_root,
    name = "terminal_mate.nvim",
    lazy = false,
    config = function()
      require("terminal_mate").setup({
        backend = "nvim",
      })
    end,
  },
}, {
  root = data_root .. "/lazy",
  lockfile = data_root .. "/lazy-lock.json",
  change_detection = {
    notify = false,
  },
})
