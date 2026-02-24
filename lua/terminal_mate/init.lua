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
  _saved_nvim_height = nil, -- saved nvim pane height before search resize
}

--- Notify helper
---@param msg string
---@param level number|nil
local function notify(msg, level)
  vim.notify("[TerminalMate] " .. msg, level or vim.log.levels.INFO)
end

--- Load zsh history from ~/.zsh_history
--- Handles multi-line commands: lines ending with \ are continuation lines,
--- and zsh extended format ": timestamp:0;cmd" with embedded newlines.
---@return string[]
local function load_zsh_history()
  local history = {}
  local history_file = vim.env.HISTFILE or (vim.env.HOME .. "/.zsh_history")

  -- Read entire file as binary to handle embedded newlines properly
  local f = io.open(history_file, "rb")
  if not f then
    f = io.open(vim.env.HOME .. "/.bash_history", "rb")
  end
  if not f then
    return history
  end
  local content = f:read("*a")
  f:close()

  -- Split into raw lines (use [^\n]+ to skip empty lines)
  local raw_lines = {}
  for line in content:gmatch("[^\n]+") do
    table.insert(raw_lines, line)
  end

  -- Parse: merge continuation lines (ending with \) and handle zsh extended format
  local i = 1
  while i <= #raw_lines do
    local line = raw_lines[i]

    -- Check if this is a zsh extended history entry: ": timestamp:0;command"
    local cmd = line:match("^: %d+:%d+;(.*)$")
    if cmd then
      -- Merge continuation lines: if cmd ends with \, next line continues
      while cmd:sub(-1) == "\\" and i < #raw_lines do
        i = i + 1
        cmd = cmd:sub(1, -2) .. "\n" .. raw_lines[i]
      end
      cmd = vim.trim(cmd)
      if cmd ~= "" then
        table.insert(history, cmd)
      end
    else
      -- Plain format (bash or simple zsh)
      local plain = line
      -- Merge backslash continuations
      while plain:sub(-1) == "\\" and i < #raw_lines do
        i = i + 1
        plain = plain:sub(1, -2) .. "\n" .. raw_lines[i]
      end
      plain = vim.trim(plain)
      if plain ~= "" and not plain:match("^#") then
        table.insert(history, plain)
      end
    end

    i = i + 1
  end

  return history
end

--- Deduplicate history, keeping last occurrence order
---@param hist string[]
---@return string[]
local function dedupe_history(hist)
  local seen = {}
  local result = {}
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

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, config.options.buffer.bufname)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].filetype = config.options.buffer.filetype
  vim.bo[buf].swapfile = false
  vim.bo[buf].bufhidden = "hide"
  vim.api.nvim_buf_set_option(buf, "syntax", "sh")

  state.input_buf = buf
  return buf
end

--- Get all non-empty lines from the current buffer as a single command block
---@return string
local function get_buffer_text()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
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

  if not tmux.pane_exists(state.terminal_pane_id) then
    notify("Terminal pane no longer exists. Reopening...", vim.log.levels.WARN)
    state.is_open = false
    state.terminal_pane_id = nil
    M.open()
    if not state.terminal_pane_id then
      return
    end
  end

  -- Smart multi-line send:
  -- Lines ending with \ are shell continuation lines.
  -- For these, send the line text + literal newline (not Enter),
  -- so the shell sees it as one continuous command.
  -- Only press Enter on the final line or non-continuation lines.
  local lines = vim.split(text, "\n", { plain = true, trimempty = false })

  -- Group lines into command blocks:
  -- A block is a sequence of continuation lines ending with a final line.
  local blocks = {}
  local current_block = {}
  for _, line in ipairs(lines) do
    table.insert(current_block, line)
    -- Check if line ends with \ (continuation)
    local trimmed = vim.trim(line)
    if trimmed:sub(-1) ~= "\\" then
      -- End of block
      table.insert(blocks, table.concat(current_block, "\n"))
      current_block = {}
    end
  end
  -- If there are remaining lines (shouldn't happen normally)
  if #current_block > 0 then
    table.insert(blocks, table.concat(current_block, "\n"))
  end

  -- Send each block as a whole unit
  for _, block in ipairs(blocks) do
    tmux.send_text(state.terminal_pane_id, block, true)
  end
end

--- Clear the buffer content
local function clear_buffer()
  if config.options.clear_input then
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
  end
end

--- Temporarily resize nvim pane to 50% for search, save original height
local function expand_nvim_pane_for_search()
  if not state.nvim_pane_id then
    return
  end
  -- Save current height
  state._saved_nvim_height = tmux.get_pane_height(state.nvim_pane_id)
  -- Resize nvim pane to 50%
  tmux.resize_pane_percent(state.nvim_pane_id, 50)
end

--- Restore nvim pane to original height after search
local function restore_nvim_pane_size()
  if not state.nvim_pane_id or not state._saved_nvim_height then
    return
  end
  tmux.resize_pane_rows(state.nvim_pane_id, state._saved_nvim_height)
  state._saved_nvim_height = nil
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

  if #state.history == 0 then
    state.history = dedupe_history(load_zsh_history())
  end

  state.nvim_pane_id = tmux.current_pane_id()

  local pane_id = tmux.split_above(config.options.split_percent, config.options.shell)
  if not pane_id then
    notify("Failed to create tmux split.", vim.log.levels.ERROR)
    return
  end

  state.terminal_pane_id = pane_id
  state.is_open = true

  local buf = get_or_create_input_buf()
  vim.api.nvim_set_current_buf(buf)
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
    state._saved_input = get_buffer_text()
  end

  state.history_index = math.min(state.history_index + 1, #state.history)
  local cmd = state.history[#state.history - state.history_index + 1]
  if cmd then
    local lines = vim.split(cmd, "\n", { plain = true })
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
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

--- Built-in floating window history search
--- Expands nvim pane to 50% while searching, restores on close
function M.history_search()
  if #state.history == 0 then
    notify("No history available.", vim.log.levels.INFO)
    return
  end

  local caller_buf = state.input_buf

  -- Expand nvim pane to 50% so the float has room
  expand_nvim_pane_for_search()

  -- Build items in reverse order (most recent first)
  local all_items = {}
  for i = #state.history, 1, -1 do
    table.insert(all_items, state.history[i])
  end

  -- Calculate float dimensions based on editor size (after resize)
  -- Use a small delay to let tmux resize propagate
  vim.defer_fn(function()
    local ui = vim.api.nvim_list_uis()[1] or { width = 80, height = 24 }
    local float_width = math.min(math.floor(ui.width * 0.9), 140)
    local float_height = math.max(math.floor(ui.height * 0.7), 10)
    local row = math.max(math.floor((ui.height - float_height) / 2) - 1, 0)
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

    local picker = {
      query = "",
      filtered = vim.deepcopy(all_items),
      selected = 1,
    }

    local function render()
      local display_lines = {}
      for _, item in ipairs(picker.filtered) do
        local line = item:gsub("\n", " \\ ")
        table.insert(display_lines, line)
      end
      vim.api.nvim_buf_set_option(results_buf, "modifiable", true)
      vim.api.nvim_buf_set_lines(results_buf, 0, -1, false, display_lines)
      vim.api.nvim_buf_set_option(results_buf, "modifiable", false)

      if picker.selected < 1 then picker.selected = 1 end
      if picker.selected > #picker.filtered then picker.selected = #picker.filtered end

      if #picker.filtered > 0 and vim.api.nvim_win_is_valid(results_win) then
        vim.api.nvim_win_set_cursor(results_win, { picker.selected, 0 })
      end
    end

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

    local closed = false
    local function close_picker()
      if closed then return end
      closed = true
      if vim.api.nvim_win_is_valid(input_win) then
        vim.api.nvim_win_close(input_win, true)
      end
      if vim.api.nvim_win_is_valid(results_win) then
        vim.api.nvim_win_close(results_win, true)
      end
      -- Restore nvim pane size
      restore_nvim_pane_size()
    end

    local function confirm()
      local choice = picker.filtered[picker.selected]
      close_picker()
      if choice and caller_buf and vim.api.nvim_buf_is_valid(caller_buf) then
        local lines = vim.split(choice, "\n", { plain = true })
        vim.api.nvim_buf_set_lines(caller_buf, 0, -1, false, lines)
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
    vim.cmd("startinsert")

    -- Keymaps
    local kopts = { buffer = input_buf, noremap = true, silent = true }

    vim.keymap.set({ "i", "n" }, "<Esc>", function()
      close_picker()
    end, kopts)
    vim.keymap.set("i", "<C-c>", function()
      close_picker()
    end, kopts)

    vim.keymap.set({ "i", "n" }, "<CR>", function()
      confirm()
    end, kopts)

    vim.keymap.set("i", "<Up>", function()
      picker.selected = math.max(1, picker.selected - 1)
      render()
    end, kopts)
    vim.keymap.set("i", "<C-p>", function()
      picker.selected = math.max(1, picker.selected - 1)
      render()
    end, kopts)

    vim.keymap.set("i", "<Down>", function()
      picker.selected = math.min(#picker.filtered, picker.selected + 1)
      render()
    end, kopts)
    vim.keymap.set("i", "<C-n>", function()
      picker.selected = math.min(#picker.filtered, picker.selected + 1)
      render()
    end, kopts)

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

    vim.api.nvim_create_autocmd("BufLeave", {
      buffer = input_buf,
      once = true,
      callback = function()
        vim.schedule(function()
          close_picker()
        end)
      end,
    })
  end, 50) -- small delay for tmux resize to take effect
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

  vim.keymap.set("n", keymap.send_line, function()
    M.send_buffer()
  end, vim.tbl_extend("force", opts, { desc = "TerminalMate: Send all buffer commands" }))

  vim.keymap.set("v", keymap.send_visual, function()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
    vim.schedule(function()
      M.send_visual()
    end)
  end, vim.tbl_extend("force", opts, { desc = "TerminalMate: Send visual selection" }))

  vim.keymap.set("i", keymap.send_line, function()
    vim.cmd("stopinsert")
    M.send_buffer()
    vim.cmd("startinsert")
  end, vim.tbl_extend("force", opts, { desc = "TerminalMate: Send all buffer commands (insert mode)" }))

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

  vim.keymap.set("n", keymap.history_search, function()
    M.history_search()
  end, vim.tbl_extend("force", opts, { desc = "TerminalMate: Search history" }))

  vim.keymap.set("i", keymap.history_search, function()
    vim.cmd("stopinsert")
    M.history_search()
  end, vim.tbl_extend("force", opts, { desc = "TerminalMate: Search history (insert)" }))

  vim.keymap.set("n", keymap.clear, function()
    M.clear()
  end, vim.tbl_extend("force", opts, { desc = "TerminalMate: Clear terminal" }))

  vim.keymap.set("n", keymap.interrupt, function()
    M.interrupt()
  end, vim.tbl_extend("force", opts, { desc = "TerminalMate: Interrupt (Ctrl-C)" }))
end

--- Set up autocommands
local function setup_autocmds()
  local group = vim.api.nvim_create_augroup("TerminalMate", { clear = true })

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

  if not tmux.is_tmux() then
    notify(
      "Not running inside tmux. terminal_mate will be available but cannot open terminal panes.",
      vim.log.levels.WARN
    )
  end

  setup_autocmds()

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
