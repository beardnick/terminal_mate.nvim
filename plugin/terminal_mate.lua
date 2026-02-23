-- terminal_mate.nvim plugin entry point
-- Registers user commands for terminal_mate

if vim.g.loaded_terminal_mate then
  return
end
vim.g.loaded_terminal_mate = true

-- User commands
vim.api.nvim_create_user_command("TerminalMateOpen", function()
  require("terminal_mate").open()
end, { desc = "Open terminal_mate split pane" })

vim.api.nvim_create_user_command("TerminalMateClose", function()
  require("terminal_mate").close()
end, { desc = "Close terminal_mate split pane" })

vim.api.nvim_create_user_command("TerminalMateToggle", function()
  require("terminal_mate").toggle()
end, { desc = "Toggle terminal_mate split pane" })

vim.api.nvim_create_user_command("TerminalMateSend", function(opts)
  if opts.args and opts.args ~= "" then
    require("terminal_mate").send(opts.args)
  else
    require("terminal_mate").send_line()
  end
end, { nargs = "?", desc = "Send command to terminal_mate pane" })

vim.api.nvim_create_user_command("TerminalMateClear", function()
  require("terminal_mate").clear()
end, { desc = "Clear terminal_mate pane" })

vim.api.nvim_create_user_command("TerminalMateInterrupt", function()
  require("terminal_mate").interrupt()
end, { desc = "Send Ctrl-C to terminal_mate pane" })
