---@class TerminalMateConfig
---@field split_percent number Percentage of terminal pane height (upper pane)
---@field shell string|nil Shell to use in the terminal pane (nil = default shell)
---@field close_on_exit boolean Close terminal pane when nvim exits
---@field auto_scroll boolean Auto scroll terminal pane to bottom after sending
---@field clear_input boolean Clear the input line after sending
---@field keymap TerminalMateKeymap
---@field buffer TerminalMateBuffer

---@class TerminalMateKeymap
---@field send_line string Send current line in normal mode
---@field send_visual string Send visual selection
---@field open string Open terminal pane
---@field close string Close terminal pane
---@field toggle string Toggle terminal pane
---@field clear string Send clear to terminal
---@field interrupt string Send Ctrl-C to terminal

---@class TerminalMateBuffer
---@field filetype string Filetype for the input buffer
---@field bufname string Name for the input buffer

local M = {}

M.defaults = {
  split_percent = 80,
  shell = nil,
  close_on_exit = true,
  auto_scroll = true,
  clear_input = true,
  keymap = {
    send_line = "<C-s>",
    send_visual = "<C-s>",
    open = "<leader>to",
    close = "<leader>tc",
    toggle = "<leader>tt",
    clear = "<C-l>",
    interrupt = "<C-c>",
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
end

return M
