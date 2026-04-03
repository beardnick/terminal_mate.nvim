---@class TerminalMateConfig
---@field backend string Terminal backend selection mode: "auto", "nvim", or "tmux"
---@field layout string TerminalMate UI layout mode: "split" or "tab"
---@field split_percent number Percentage of editor height used by the terminal pane
---@field shell string|nil Shell to use in the terminal pane (nil = default shell)
---@field close_on_exit boolean Close terminal pane when nvim exits
---@field auto_scroll boolean Auto scroll terminal pane to bottom after sending
---@field clear_input boolean Clear the input buffer after sending
---@field shell_integration TerminalMateShellIntegration
---@field persistence TerminalMatePersistence
---@field keymap TerminalMateKeymap
---@field buffer TerminalMateBuffer
---@field completion TerminalMateCompletion
---@field cheatsheets TerminalMateCheatsheets

---@class TerminalMateKeymap
---@field send_line string Send all buffer content in normal/insert mode
---@field send_visual string Send visual selection
---@field open string Open terminal pane
---@field mate_mode string Open terminal_mate input mode
---@field new_terminal string Create a new terminal instance
---@field hide string Hide the current terminal pane without killing it
---@field close string Close terminal pane
---@field toggle string Toggle terminal pane
---@field clear string Send clear to terminal
---@field interrupt string Send Ctrl-C to terminal
---@field prev_terminal string Switch to the previous managed terminal
---@field next_terminal string Switch to the next managed terminal
---@field switch_prefix string Prefix for normal-mode numeric terminal jump keymaps
---@field history_prev string Navigate to previous (older) history entry
---@field history_next string Navigate to next (newer) history entry
---@field history_search string Open history search picker
---@field cheatsheet_search string Search cheatsheets by description
---@field cheatsheet_edit string Edit the cheatsheet file
---@field cheatsheet_new string Create a cheatsheet entry
---@field accept_suggestion string Accept the current autosuggestion
---@field completion_trigger string Trigger native shell completion in tab mode / move to the next completion item
---@field completion_prev string Select the previous completion item in insert mode

---@class TerminalMateBuffer
---@field filetype string Filetype for the input buffer
---@field bufname string Name for the input buffer

---@class TerminalMateCompletion
---@field enabled boolean Enable native zsh completion in the TerminalMate input buffer
---@field trigger string Completion trigger mode: "auto" or "tab"
---@field debounce_ms number Delay before refreshing automatic completion suggestions
---@field shell string|nil Zsh executable to use for completion (nil = auto-detect)

---@class TerminalMateShellIntegration
---@field enabled boolean Enable shell integration for TerminalMate-managed Neovim terminals when supported

---@class TerminalMatePersistence
---@field enabled boolean Persist TerminalMate terminals and input buffer content across sessions
---@field path string|nil Path to the session state file (nil = stdpath("state") .. "/terminal_mate/session.json")
---@field debounce_ms number Delay before writing state updates to disk

---@class TerminalMateCheatsheets
---@field path string|nil Path to the Lua file that returns cheatsheet entries
---@field debounce_ms number Delay before refreshing cheatsheet variable completion

local M = {}

M.defaults = {
  backend = "auto",
  layout = "split",
  split_percent = 50,
  shell = nil,
  close_on_exit = true,
  auto_scroll = true,
  clear_input = false,
  shell_integration = {
    enabled = true,
  },
  persistence = {
    enabled = true,
    path = nil,
    debounce_ms = 150,
  },
  completion = {
    enabled = true,
    trigger = "auto",
    debounce_ms = 120,
    shell = nil,
  },
  cheatsheets = {
    path = nil,
    debounce_ms = 80,
  },
  keymap = {
    send_line = "<C-s>",
    send_visual = "<leader>ts",
    open = "<leader>to",
    mate_mode = "<leader>tm",
    new_terminal = "<leader>tn",
    hide = "<leader>th",
    close = "<leader>tc",
    toggle = "<leader>tt",
    clear = "<C-l>",
    interrupt = "<C-c>",
    prev_terminal = "<leader>t[",
    next_terminal = "<leader>t]",
    switch_prefix = "<leader>t",
    history_prev = "<Up>",
    history_next = "<Down>",
    history_search = "<C-r>",
    cheatsheet_search = "<C-g>",
    cheatsheet_edit = "<leader>te",
    cheatsheet_new = "<leader>ta",
    accept_suggestion = "<Right>",
    completion_trigger = "<Tab>",
    completion_prev = "<S-Tab>",
  },
  buffer = {
    filetype = "terminal_mate",
    bufname = "[TerminalMate]",
  },
}

M.options = vim.deepcopy(M.defaults)

---Merge user config with defaults
---@param opts table|nil
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})

  if not vim.tbl_contains({ "auto", "nvim", "tmux" }, M.options.backend) then
    error("terminal_mate: backend must be one of 'auto', 'nvim', or 'tmux'")
  end

  if not vim.tbl_contains({ "split", "tab" }, M.options.layout) then
    error("terminal_mate: layout must be 'split' or 'tab'")
  end

  if not vim.tbl_contains({ "auto", "tab" }, M.options.completion.trigger) then
    error("terminal_mate: completion.trigger must be 'auto' or 'tab'")
  end

  if type(M.options.completion.debounce_ms) ~= "number" or M.options.completion.debounce_ms < 0 then
    error("terminal_mate: completion.debounce_ms must be a non-negative number")
  end

  if type(M.options.cheatsheets.debounce_ms) ~= "number" or M.options.cheatsheets.debounce_ms < 0 then
    error("terminal_mate: cheatsheets.debounce_ms must be a non-negative number")
  end

  if type(M.options.shell_integration.enabled) ~= "boolean" then
    error("terminal_mate: shell_integration.enabled must be a boolean")
  end

  if type(M.options.persistence.enabled) ~= "boolean" then
    error("terminal_mate: persistence.enabled must be a boolean")
  end

  if type(M.options.persistence.debounce_ms) ~= "number" or M.options.persistence.debounce_ms < 0 then
    error("terminal_mate: persistence.debounce_ms must be a non-negative number")
  end
end

return M
