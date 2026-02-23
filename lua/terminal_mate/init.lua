--- terminal_mate.nvim - Warp-like terminal experience for Neovim + tmux
--- Upper pane: terminal output | Lower pane: Neovim command editor
local config = require("terminal_mate.config")
local tmux = require("terminal_mate.tmux")

local M = {}

--- State
local state = {
  terminal_pane_id = nil, -- tmux pane id of the upper terminal
  nvim_pane_id = nil,     -- tmux pane id where nvim runs
  input_buf = nil,        -- buffer number for the command input
  is_open = false,
}

--- Notify helper
---@param msg string
---@param level number|nil
local function notify(msg, level)
  vim.notify("[TerminalMate] " .. msg, level or vim.log.levels.INFO)
end

--- Create or get the input buffer
---@return number bufnr
local function get_or_create_input_buf()
  if state.input_buf and vim.api.nvim_buf_is_valid(state.input_buf) then
    return state.input_buf
  end

  local buf = vim.api.nvim_create_buf(false, true) -- nofile, scratch
  vim.api.nvim_buf_set_name(buf, config.options.buffer.bufname)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].filetype = config.options.buffer.filetype
  vim.bo[buf].swapfile = false
  vim.bo[buf].bufhidden = "hide"

  -- Enable syntax highlighting for shell commands
  vim.api.nvim_buf_set_option(buf, "syntax", "sh")

  state.input_buf = buf
  return buf
end

--- Get the text to send from the buffer
---@param mode string "line" for current line, "visual" for visual selection
---@return string
local function get_text(mode)
  if mode == "visual" then
    -- Get visual selection
    local start_pos = vim.fn.getpos("'<")
    local end_pos = vim.fn.getpos("'>")
    local start_line = start_pos[2]
    local end_line = end_pos[2]
    local lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)
    return table.concat(lines, "\n")
  else
    -- Get current line
    local line = vim.api.nvim_get_current_line()
    return line
  end
end

--- Send text to the terminal pane
---@param text string
local function send_to_terminal(text)
  if not state.is_open or not state.terminal_pane_id then
    notify("Terminal pane is not open. Run :TerminalMateOpen first.", vim.log.levels.WARN)
    return
  end

  -- Check if pane still exists
  if not tmux.pane_exists(state.terminal_pane_id) then
    notify("Terminal pane no longer exists. Reopening...", vim.log.levels.WARN)
    state.is_open = false
    state.terminal_pane_id = nil
    M.open()
    if not state.terminal_pane_id then
      return
    end
  end

  -- Send each line separately for multi-line input
  local lines = vim.split(text, "\n", { plain = true, trimempty = false })
  for i, line in ipairs(lines) do
    if i > 1 then
      -- For multi-line commands, use a small delay between lines
      tmux.send_keys(state.terminal_pane_id, line, true)
    else
      tmux.send_keys(state.terminal_pane_id, line, true)
    end
  end
end

--- Open the terminal pane
function M.open()
  if not tmux.is_tmux() then
    notify("Not running inside tmux! terminal_mate requires tmux.", vim.log.levels.ERROR)
    return
  end

  if state.is_open and state.terminal_pane_id then
    if tmux.pane_exists(state.terminal_pane_id) then
      notify("Terminal pane is already open.")
      return
    end
  end

  -- Record nvim's pane id
  state.nvim_pane_id = tmux.current_pane_id()

  -- Split above: create terminal pane on top
  local pane_id = tmux.split_above(config.options.split_percent, config.options.shell)
  if not pane_id then
    notify("Failed to create tmux split.", vim.log.levels.ERROR)
    return
  end

  state.terminal_pane_id = pane_id
  state.is_open = true

  -- Set up the input buffer in the current nvim window
  local buf = get_or_create_input_buf()
  vim.api.nvim_set_current_buf(buf)

  -- Set up buffer-local keymaps
  M._setup_buffer_keymaps(buf)

  notify("Terminal pane opened (" .. pane_id .. ")")
end

--- Close the terminal pane
function M.close()
  if not state.is_open or not state.terminal_pane_id then
    notify("No terminal pane to close.", vim.log.levels.WARN)
    return
  end

  if tmux.pane_exists(state.terminal_pane_id) then
    tmux.kill_pane(state.terminal_pane_id)
  end

  state.terminal_pane_id = nil
  state.is_open = false

  notify("Terminal pane closed.")
end

--- Toggle the terminal pane
function M.toggle()
  if state.is_open and state.terminal_pane_id and tmux.pane_exists(state.terminal_pane_id) then
    M.close()
  else
    state.is_open = false
    state.terminal_pane_id = nil
    M.open()
  end
end

--- Send current line to terminal
function M.send_line()
  local text = get_text("line")
  if text == "" then
    return
  end
  send_to_terminal(text)

  if config.options.clear_input then
    -- Clear the current line after sending
    vim.api.nvim_set_current_line("")
  end
end

--- Send visual selection to terminal
function M.send_visual()
  local text = get_text("visual")
  if text == "" then
    return
  end
  send_to_terminal(text)

  if config.options.clear_input then
    -- Clear the selected lines after sending
    local start_pos = vim.fn.getpos("'<")
    local end_pos = vim.fn.getpos("'>")
    local start_line = start_pos[2]
    local end_line = end_pos[2]
    local empty_lines = {}
    for _ = start_line, end_line do
      table.insert(empty_lines, "")
    end
    vim.api.nvim_buf_set_lines(0, start_line - 1, end_line, false, empty_lines)
  end
end

--- Send clear command to terminal
function M.clear()
  if not state.is_open or not state.terminal_pane_id then
    return
  end
  tmux.send_special_key(state.terminal_pane_id, "C-l")
end

--- Send interrupt (Ctrl-C) to terminal
function M.interrupt()
  if not state.is_open or not state.terminal_pane_id then
    return
  end
  tmux.send_special_key(state.terminal_pane_id, "C-c")
end

--- Send arbitrary text to terminal (for user commands)
---@param text string
function M.send(text)
  if text and text ~= "" then
    send_to_terminal(text)
  end
end

--- Get current state (for statusline integration etc.)
---@return table
function M.get_state()
  return {
    is_open = state.is_open,
    terminal_pane_id = state.terminal_pane_id,
    nvim_pane_id = state.nvim_pane_id,
  }
end

--- Set up buffer-local keymaps for the input buffer
---@param buf number
function M._setup_buffer_keymaps(buf)
  local opts = { buffer = buf, noremap = true, silent = true }
  local keymap = config.options.keymap

  -- Normal mode: send current line (default: <C-s>)
  vim.keymap.set("n", keymap.send_line, function()
    M.send_line()
  end, vim.tbl_extend("force", opts, { desc = "TerminalMate: Send current line" }))

  -- Visual mode: send selection (default: <C-s>)
  vim.keymap.set("v", keymap.send_visual, function()
    -- Exit visual mode first so marks are set
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
    vim.schedule(function()
      M.send_visual()
    end)
  end, vim.tbl_extend("force", opts, { desc = "TerminalMate: Send visual selection" }))

  -- Insert mode: send current line with the configured key (default: <C-s>)
  vim.keymap.set("i", keymap.send_line, function()
    vim.cmd("stopinsert")
    M.send_line()
    vim.cmd("startinsert!")
  end, vim.tbl_extend("force", opts, { desc = "TerminalMate: Send line (insert mode)" }))

  -- Clear terminal
  vim.keymap.set("n", keymap.clear, function()
    M.clear()
  end, vim.tbl_extend("force", opts, { desc = "TerminalMate: Clear terminal" }))

  -- Interrupt terminal
  vim.keymap.set("n", keymap.interrupt, function()
    M.interrupt()
  end, vim.tbl_extend("force", opts, { desc = "TerminalMate: Interrupt (Ctrl-C)" }))
end

--- Set up autocommands
local function setup_autocmds()
  local group = vim.api.nvim_create_augroup("TerminalMate", { clear = true })

  -- Clean up terminal pane when nvim exits
  if config.options.close_on_exit then
    vim.api.nvim_create_autocmd("VimLeavePre", {
      group = group,
      callback = function()
        if state.is_open and state.terminal_pane_id then
          pcall(function()
            tmux.kill_pane(state.terminal_pane_id)
          end)
        end
      end,
    })
  end
end

--- Plugin setup
---@param opts table|nil
function M.setup(opts)
  config.setup(opts)

  -- Validate tmux availability
  if not tmux.is_tmux() then
    notify(
      "Not running inside tmux. terminal_mate will be available but cannot open terminal panes.",
      vim.log.levels.WARN
    )
  end

  setup_autocmds()

  -- Set up global keymaps for open/close/toggle
  local keymap = config.options.keymap
  local gopts = { noremap = true, silent = true }

  vim.keymap.set("n", keymap.open, function()
    M.open()
  end, vim.tbl_extend("force", gopts, { desc = "TerminalMate: Open terminal pane" }))

  vim.keymap.set("n", keymap.close, function()
    M.close()
  end, vim.tbl_extend("force", gopts, { desc = "TerminalMate: Close terminal pane" }))

  vim.keymap.set("n", keymap.toggle, function()
    M.toggle()
  end, vim.tbl_extend("force", gopts, { desc = "TerminalMate: Toggle terminal pane" }))
end

return M
