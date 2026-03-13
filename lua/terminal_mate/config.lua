---@class TerminalMateConfig
---@field backend string Terminal backend selection mode: "auto", "nvim", or "tmux"
---@field split_percent number Percentage of editor height used by the terminal pane
---@field shell string|nil Shell to use in the terminal pane (nil = default shell)
---@field close_on_exit boolean Close terminal pane when nvim exits
---@field auto_scroll boolean Auto scroll terminal pane to bottom after sending
---@field clear_input boolean Clear the input buffer after sending
---@field keymap TerminalMateKeymap
---@field buffer TerminalMateBuffer

---@class TerminalMateKeymap
---@field send_line string Send all buffer content in normal/insert mode
---@field send_visual string Send visual selection
---@field open string Open terminal pane
---@field new_terminal string Create a new terminal instance
---@field hide string Hide the current terminal pane without killing it
---@field close string Close terminal pane
---@field toggle string Toggle terminal pane
---@field clear string Send clear to terminal
---@field interrupt string Send Ctrl-C to terminal
---@field history_prev string Navigate to previous (older) history entry
---@field history_next string Navigate to next (newer) history entry
---@field history_search string Open history search picker

---@class TerminalMateBuffer
---@field filetype string Filetype for the input buffer
---@field bufname string Name for the input buffer

local M = {}

M.defaults = {
  backend = "auto",
  split_percent = 50,
  shell = nil,
  close_on_exit = true,
  auto_scroll = true,
  clear_input = true,
  keymap = {
    send_line = "<C-s>",
    send_visual = "<leader>ts",
    open = "<leader>to",
    new_terminal = "<leader>tn",
    hide = "<leader>th",
    close = "<leader>tc",
    toggle = "<leader>tt",
    clear = "<C-l>",
    interrupt = "<C-c>",
    history_prev = "<Up>",
    history_next = "<Down>",
    history_search = "<C-r>",
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
end

return M
