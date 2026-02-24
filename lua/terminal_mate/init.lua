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
  history = {},           -- command history (loaded from zsh + session)
  history_index = 0,      -- 0 = not browsing, 1 = most recent
}

--- Notify helper
---@param msg string
---@param level number|nil
local function notify(msg, level)
  vim.notify("[TerminalMate] " .. msg, level or vim.log.levels.INFO)
end

--- Load zsh history from ~/.zsh_history
---@return string[]
local function load_zsh_history()
  local history = {}
  local history_file = vim.env.HISTFILE or (vim.env.HOME .. "/.zsh_history")

  local f = io.open(history_file, "r")
  if not f then
    -- Try bash history as fallback
    f = io.open(vim.env.HOME .. "/.bash_history", "r")
  end
  if not f then
    return history
  end

  for line in f:lines() do
    -- zsh extended history format: ": timestamp:0;command"
    local cmd = line:match("^: %d+:%d+;(.+)$")
    if cmd then
      -- zsh extended format
      cmd = vim.trim(cmd)
      if cmd ~= "" then
        table.insert(history, cmd)
      end
    else
      -- plain format (bash or simple zsh)
      line = vim.trim(line)
      if line ~= "" and not line:match("^#") then
        table.insert(history, line)
      end
    end
  end
  f:close()

  return history
end

--- Deduplicate history, keeping last occurrence order
---@param hist string[]
---@return string[]
local function dedupe_history(hist)
  local seen = {}
  local result = {}
  -- Walk backwards so we keep the most recent occurrence
  for i = #hist, 1, -1 do
    if not seen[hist[i]] then
      seen[hist[i]] = true
      table.insert(result, 1, hist[i])
    end
  end
  return result
end

--- Add a command to session history
---@param cmd string
local function add_to_history(cmd)
  if cmd == "" then
    return
  end
  -- Remove duplicates of this command
  for i = #state.history, 1, -1 do
    if state.history[i] == cmd then
      table.remove(state.history, i)
    end
  end
  table.insert(state.history, cmd)
  state.history_index = 0
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

--- Get all non-empty lines from the current buffer as a single command block
---@return string
local function get_buffer_text()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  -- Filter out empty lines and collect
  local non_empty = {}
  for _, line in ipairs(lines) do
    if vim.trim(line) ~= "" then
      table.insert(non_empty, line)
    end
  end
  return table.concat(non_empty, "\n")
end

--- Get visual selection text
---@return string
local function get_visual_text()
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local start_line = start_pos[2]
  local end_line = end_pos[2]
  local lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)
  return table.concat(lines, "\n")
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

  -- Send each line separately
  local lines = vim.split(text, "\n", { plain = true, trimempty = false })
  for _, line in ipairs(lines) do
    tmux.send_keys(state.terminal_pane_id, line, true)
  end
end

--- Clear the buffer content
local function clear_buffer()
  if config.options.clear_input then
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
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

  -- Load zsh history on first open
  if #state.history == 0 then
    state.history = dedupe_history(load_zsh_history())
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

--- Send all commands in the current buffer to terminal, keep current mode
function M.send_buffer()
  local text = get_buffer_text()
  if text == "" then
    return
  end

  -- Add to history before sending
  add_to_history(text)

  send_to_terminal(text)
  clear_buffer()
end

--- Send visual selection to terminal
function M.send_visual()
  local text = get_visual_text()
  if text == "" then
    return
  end

  add_to_history(text)
  send_to_terminal(text)

  if config.options.clear_input then
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
    add_to_history(text)
    send_to_terminal(text)
  end
end

--- Navigate history: go to previous (older) command
function M.history_prev()
  if #state.history == 0 then
    notify("No history available.", vim.log.levels.INFO)
    return
  end

  if state.history_index == 0 then
    -- Save current buffer content before browsing history
    state._saved_input = get_buffer_text()
  end

  state.history_index = math.min(state.history_index + 1, #state.history)
  local cmd = state.history[#state.history - state.history_index + 1]
  if cmd then
    local lines = vim.split(cmd, "\n", { plain = true })
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
    -- Move cursor to end
    vim.api.nvim_win_set_cursor(0, { #lines, #lines[#lines] })
  end
end

--- Navigate history: go to next (newer) command
function M.history_next()
  if state.history_index <= 0 then
    return
  end

  state.history_index = state.history_index - 1

  if state.history_index == 0 then
    -- Restore saved input
    local saved = state._saved_input or ""
    local lines = vim.split(saved, "\n", { plain = true })
    if #lines == 0 then
      lines = { "" }
    end
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
    vim.api.nvim_win_set_cursor(0, { #lines, #lines[#lines] })
    return
  end

  local cmd = state.history[#state.history - state.history_index + 1]
  if cmd then
    local lines = vim.split(cmd, "\n", { plain = true })
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
    vim.api.nvim_win_set_cursor(0, { #lines, #lines[#lines] })
  end
end

--- Simple fuzzy match: all characters in query must appear in str in order
---@param str string
---@param query string
---@return boolean
local function fuzzy_match(str, query)
  if query == "" then
    return true
  end
  local lower_str = str:lower()
  local lower_q = query:lower()
  local si = 1
  for qi = 1, #lower_q do
    local ch = lower_q:sub(qi, qi)
    local found = lower_str:find(ch, si, true)
    if not found then
      return false
    end
    si = found + 1
  end
  return true
end

--- Built-in floating window history search (no external plugin needed)
function M.history_search()
  if #state.history == 0 then
    notify("No history available.", vim.log.levels.INFO)
    return
  end

  -- Remember the caller buffer to write the result back
  local caller_buf = state.input_buf

  -- Build items in reverse order (most recent first)
  local all_items = {}
  for i = #state.history, 1, -1 do
    table.insert(all_items, state.history[i])
  end

  -- Calculate float dimensions
  local ui = vim.api.nvim_list_uis()[1] or { width = 80, height = 24 }
  local float_width = math.min(math.floor(ui.width * 0.8), 120)
  local float_height = math.min(math.floor(ui.height * 0.6), 30)
  local row = math.floor((ui.height - float_height) / 2)
  local col = math.floor((ui.width - float_width) / 2)

  -- Create results buffer
  local results_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[results_buf].bufhidden = "wipe"

  -- Create input buffer (single line)
  local input_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[input_buf].bufhidden = "wipe"
  vim.bo[input_buf].buftype = "nofile"

  -- Open results window
  local results_win = vim.api.nvim_open_win(results_buf, false, {
    relative = "editor",
    width = float_width,
    height = float_height - 3,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " History ",
    title_pos = "center",
  })
  vim.api.nvim_win_set_option(results_win, "cursorline", true)
  vim.api.nvim_win_set_option(results_win, "winhighlight", "CursorLine:PmenuSel,Normal:Normal")

  -- Open input window below results
  local input_win = vim.api.nvim_open_win(input_buf, true, {
    relative = "editor",
    width = float_width,
    height = 1,
    row = row + float_height - 2,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " Search> ",
    title_pos = "left",
  })

  -- State for the picker
  local picker = {
    query = "",
    filtered = vim.deepcopy(all_items),
    selected = 1,  -- 1-indexed, 1 = top item
  }

  -- Render the results list
  local function render()
    local display_lines = {}
    for _, item in ipairs(picker.filtered) do
      local line = item:gsub("\n", " \\ ")
      table.insert(display_lines, line)
    end
    vim.api.nvim_buf_set_option(results_buf, "modifiable", true)
    vim.api.nvim_buf_set_lines(results_buf, 0, -1, false, display_lines)
    vim.api.nvim_buf_set_option(results_buf, "modifiable", false)

    -- Clamp selection
    if picker.selected < 1 then picker.selected = 1 end
    if picker.selected > #picker.filtered then picker.selected = #picker.filtered end

    -- Move cursor in results window
    if #picker.filtered > 0 and vim.api.nvim_win_is_valid(results_win) then
      vim.api.nvim_win_set_cursor(results_win, { picker.selected, 0 })
    end
  end

  -- Filter items based on query
  local function update_filter()
    picker.filtered = {}
    for _, item in ipairs(all_items) do
      local flat = item:gsub("\n", " ")
      if fuzzy_match(flat, picker.query) then
        table.insert(picker.filtered, item)
      end
    end
    picker.selected = 1
    render()
  end

  -- Close the picker
  local function close_picker()
    if vim.api.nvim_win_is_valid(input_win) then
      vim.api.nvim_win_close(input_win, true)
    end
    if vim.api.nvim_win_is_valid(results_win) then
      vim.api.nvim_win_close(results_win, true)
    end
  end

  -- Confirm selection: write chosen command into the caller buffer
  local function confirm()
    local choice = picker.filtered[picker.selected]
    close_picker()
    if choice and caller_buf and vim.api.nvim_buf_is_valid(caller_buf) then
      local lines = vim.split(choice, "\n", { plain = true })
      vim.api.nvim_buf_set_lines(caller_buf, 0, -1, false, lines)
      -- Switch to caller buffer window and place cursor at end
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(win) == caller_buf then
          vim.api.nvim_set_current_win(win)
          vim.api.nvim_win_set_cursor(win, { #lines, #lines[#lines] })
          break
        end
      end
      state.history_index = 0
    end
  end

  -- Initial render
  update_filter()

  -- Start insert mode in the input window
  vim.cmd("startinsert")

  -- Set up keymaps on the input buffer
  local kopts = { buffer = input_buf, noremap = true, silent = true }

  -- Esc / Ctrl-C: close picker
  vim.keymap.set({ "i", "n" }, "<Esc>", function()
    close_picker()
  end, kopts)
  vim.keymap.set("i", "<C-c>", function()
    close_picker()
  end, kopts)

  -- Enter: confirm selection
  vim.keymap.set({ "i", "n" }, "<CR>", function()
    confirm()
  end, kopts)

  -- Up / Ctrl-P: move selection up
  vim.keymap.set("i", "<Up>", function()
    picker.selected = math.max(1, picker.selected - 1)
    render()
  end, kopts)
  vim.keymap.set("i", "<C-p>", function()
    picker.selected = math.max(1, picker.selected - 1)
    render()
  end, kopts)

  -- Down / Ctrl-N: move selection down
  vim.keymap.set("i", "<Down>", function()
    picker.selected = math.min(#picker.filtered, picker.selected + 1)
    render()
  end, kopts)
  vim.keymap.set("i", "<C-n>", function()
    picker.selected = math.min(#picker.filtered, picker.selected + 1)
    render()
  end, kopts)

  -- Watch for text changes in input buffer to update filter
  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
    buffer = input_buf,
    callback = function()
      if not vim.api.nvim_buf_is_valid(input_buf) then
        return
      end
      local lines = vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)
      picker.query = lines[1] or ""
      update_filter()
    end,
  })

  -- Auto-close when input buffer is hidden
  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = input_buf,
    once = true,
    callback = function()
      vim.schedule(function()
        close_picker()
      end)
    end,
  })
end

--- Get current state (for statusline integration etc.)
---@return table
function M.get_state()
  return {
    is_open = state.is_open,
    terminal_pane_id = state.terminal_pane_id,
    nvim_pane_id = state.nvim_pane_id,
    history_count = #state.history,
  }
end

--- Set up buffer-local keymaps for the input buffer
---@param buf number
function M._setup_buffer_keymaps(buf)
  local opts = { buffer = buf, noremap = true, silent = true }
  local keymap = config.options.keymap

  -- Normal mode: send all buffer content (default: <C-s>)
  vim.keymap.set("n", keymap.send_line, function()
    M.send_buffer()
  end, vim.tbl_extend("force", opts, { desc = "TerminalMate: Send all buffer commands" }))

  -- Visual mode: send selection (default: <C-s>)
  vim.keymap.set("v", keymap.send_visual, function()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
    vim.schedule(function()
      M.send_visual()
    end)
  end, vim.tbl_extend("force", opts, { desc = "TerminalMate: Send visual selection" }))

  -- Insert mode: send all buffer content, stay in insert mode (default: <C-s>)
  vim.keymap.set("i", keymap.send_line, function()
    local cursor = vim.fn.mode() -- remember we're in insert
    vim.cmd("stopinsert")
    M.send_buffer()
    vim.cmd("startinsert")
  end, vim.tbl_extend("force", opts, { desc = "TerminalMate: Send all buffer commands (insert mode)" }))

  -- History navigation: Up/Down arrows
  vim.keymap.set("n", keymap.history_prev, function()
    M.history_prev()
  end, vim.tbl_extend("force", opts, { desc = "TerminalMate: Previous history" }))

  vim.keymap.set("n", keymap.history_next, function()
    M.history_next()
  end, vim.tbl_extend("force", opts, { desc = "TerminalMate: Next history" }))

  vim.keymap.set("i", keymap.history_prev, function()
    vim.cmd("stopinsert")
    M.history_prev()
    vim.cmd("startinsert!")
  end, vim.tbl_extend("force", opts, { desc = "TerminalMate: Previous history (insert)" }))

  vim.keymap.set("i", keymap.history_next, function()
    vim.cmd("stopinsert")
    M.history_next()
    vim.cmd("startinsert!")
  end, vim.tbl_extend("force", opts, { desc = "TerminalMate: Next history (insert)" }))

  -- History search
  vim.keymap.set("n", keymap.history_search, function()
    M.history_search()
  end, vim.tbl_extend("force", opts, { desc = "TerminalMate: Search history" }))

  vim.keymap.set("i", keymap.history_search, function()
    vim.cmd("stopinsert")
    M.history_search()
  end, vim.tbl_extend("force", opts, { desc = "TerminalMate: Search history (insert)" }))

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
