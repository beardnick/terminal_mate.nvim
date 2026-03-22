-- terminal_mate.nvim plugin entry point
-- Registers user commands for terminal_mate

if vim.g.loaded_terminal_mate then
  return
end
vim.g.loaded_terminal_mate = true

-- User commands
vim.api.nvim_create_user_command("TerminalMateOpen", function()
  require("terminal_mate").open_pane()
end, { desc = "Open terminal_mate split pane" })

vim.api.nvim_create_user_command("TerminalMateMode", function()
  require("terminal_mate").open()
end, { desc = "Open terminal_mate input mode" })

vim.api.nvim_create_user_command("TerminalMateNew", function()
  require("terminal_mate").new_terminal()
end, { desc = "Create a new terminal_mate terminal instance" })

vim.api.nvim_create_user_command("TerminalMateSwitch", function(opts)
  require("terminal_mate").switch_terminal(opts.args)
end, { nargs = 1, desc = "Switch to a specific managed terminal_mate terminal instance" })

vim.api.nvim_create_user_command("TerminalMateNextTerminal", function()
  require("terminal_mate").next_terminal()
end, { desc = "Switch to the next managed terminal_mate terminal instance" })

vim.api.nvim_create_user_command("TerminalMatePrevTerminal", function()
  require("terminal_mate").prev_terminal()
end, { desc = "Switch to the previous managed terminal_mate terminal instance" })

vim.api.nvim_create_user_command("TerminalMateHide", function()
  require("terminal_mate").hide()
end, { desc = "Hide the current terminal_mate pane without killing it" })

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
    require("terminal_mate").send_buffer()
  end
end, { nargs = "?", desc = "Send command to terminal_mate pane" })

vim.api.nvim_create_user_command("TerminalMateSendSelection", function()
  require("terminal_mate").send_visual()
end, { range = true, desc = "Send the current visual selection to the active terminal backend" })

vim.api.nvim_create_user_command("TerminalMateClear", function()
  require("terminal_mate").clear()
end, { desc = "Clear terminal_mate pane" })

vim.api.nvim_create_user_command("TerminalMateInterrupt", function()
  require("terminal_mate").interrupt()
end, { desc = "Send Ctrl-C to terminal_mate pane" })

vim.api.nvim_create_user_command("TerminalMateHistorySearch", function()
  require("terminal_mate").history_search()
end, { desc = "Search command history" })

vim.api.nvim_create_user_command("TerminalMateHistoryPrev", function()
  require("terminal_mate").history_prev()
end, { desc = "Previous history entry" })

vim.api.nvim_create_user_command("TerminalMateHistoryNext", function()
  require("terminal_mate").history_next()
end, { desc = "Next history entry" })

vim.api.nvim_create_user_command("TerminalMateCheatsheetSearch", function()
  require("terminal_mate").cheatsheet_search()
end, { desc = "Search cheatsheets by description" })

vim.api.nvim_create_user_command("TerminalMateCheatsheetEdit", function()
  require("terminal_mate").cheatsheet_edit()
end, { desc = "Edit the cheatsheet file" })

vim.api.nvim_create_user_command("TerminalMateCheatsheetNew", function()
  require("terminal_mate").cheatsheet_new()
end, { desc = "Create a cheatsheet entry" })

vim.api.nvim_create_user_command("TerminalMateDebugCompletion", function()
  require("terminal_mate").debug_completion_context()
end, { desc = "Show completion backend/cwd debug information" })
