--- terminal_mate.nvim - Warp-like terminal experience for Neovim
--- Terminal backend defaults to Neovim's built-in terminal and falls back to tmux.
local config = require("terminal_mate.config")
local cheatsheets = require("terminal_mate.cheatsheets")
local nvim_terminal = require("terminal_mate.nvim_terminal")
local tmux = require("terminal_mate.tmux")
local zsh_completion = require("terminal_mate.zsh_completion")

local M = {}

local SIDEBAR_BUFNAME = "[TerminalMateList]"
local SIDEBAR_FILETYPE = "terminal_mate_sidebar"
local SIDEBAR_MIN_WIDTH = 14
local SIDEBAR_MAX_WIDTH = 28
local SIDEBAR_NS = vim.api.nvim_create_namespace("TerminalMateSidebar")
local AUTOSUGGEST_NS = vim.api.nvim_create_namespace("TerminalMateAutosuggest")
local AUTOSUGGEST_PREVIEW_MAX = 120
local INPUT_COMPLETEOPT = "menu,menuone,noinsert"

--- State
local state = {
  backend = nil,             -- active backend: "nvim" or "tmux"
  terminal_pane_id = nil,    -- tmux pane id managed by terminal_mate
  terminal_win = nil,        -- current Neovim terminal window id
  terminal_buf = nil,        -- current Neovim terminal buffer id
  terminal_job_id = nil,     -- current Neovim terminal job/channel id
  terminal_shell_command = nil, -- shell command used for the current Neovim terminal
  terminal_shell_source = nil,  -- source used to resolve the current Neovim terminal shell
  terminal_shell_diagnostics = nil, -- shell candidate scan for current Neovim terminal startup
  terminal_last_error = nil, -- last current Neovim terminal startup/send error
  nvim_terminals = {},       -- managed Neovim terminal instances
  current_terminal_id = nil, -- most recently active Neovim terminal id
  sidebar_buf = nil,         -- terminal list sidebar buffer
  sidebar_win = nil,         -- terminal list sidebar window
  sidebar_terminal_ids = {}, -- terminal ids mapped by sidebar line
  next_terminal_id = 0,      -- monotonic id for Neovim terminals
  activity_seq = 0,          -- monotonic sequence for latest-active selection
  nvim_pane_id = nil,        -- tmux pane id where nvim runs
  input_buf = nil,           -- buffer number for the command input
  is_open = false,           -- true when the dedicated TerminalMate input UI is active
  autosuggestion = nil,      -- active history-backed autosuggestion for the input buffer
  accepted_suggestion = nil, -- last accepted autosuggestion text for exact sends
  history = {},              -- command history (loaded from zsh + session)
  history_index = 0,         -- 0 = not browsing, 1 = most recent
  _saved_nvim_height = nil,  -- saved nvim pane height before search resize
  _saved_ui = nil,           -- saved UI options to restore on close
}

--- Save current UI options and apply minimal UI for TerminalMate mode
local function apply_minimal_ui()
  state._saved_ui = {
    cmdheight = vim.o.cmdheight,
    laststatus = vim.o.laststatus,
    showtabline = vim.o.showtabline,
    ruler = vim.o.ruler,
    showmode = vim.o.showmode,
    showcmd = vim.o.showcmd,
    completeopt = vim.o.completeopt,
    signcolumn = vim.wo.signcolumn,
    number = vim.wo.number,
    relativenumber = vim.wo.relativenumber,
  }
  vim.o.cmdheight = 0
  vim.o.laststatus = 0
  vim.o.showtabline = 0
  vim.o.ruler = false
  vim.o.showmode = false
  vim.o.showcmd = false
end

--- Restore saved UI options
local function restore_ui()
  if not state._saved_ui then
    return
  end

  vim.o.cmdheight = state._saved_ui.cmdheight
  vim.o.laststatus = state._saved_ui.laststatus
  vim.o.showtabline = state._saved_ui.showtabline
  vim.o.ruler = state._saved_ui.ruler
  vim.o.showmode = state._saved_ui.showmode
  vim.o.showcmd = state._saved_ui.showcmd
  vim.o.completeopt = state._saved_ui.completeopt

  pcall(function()
    vim.wo.signcolumn = state._saved_ui.signcolumn
    vim.wo.number = state._saved_ui.number
    vim.wo.relativenumber = state._saved_ui.relativenumber
  end)

  state._saved_ui = nil
end

--- Notify helper
---@param msg string
---@param level number|nil
local function notify(msg, level)
  vim.notify("[TerminalMate] " .. msg, level or vim.log.levels.INFO)
end

---@param value number
---@param minimum number
---@param maximum number
---@return number
local function clamp(value, minimum, maximum)
  return math.max(minimum, math.min(maximum, value))
end

---@param text string
---@return number
local function display_width(text)
  return vim.fn.strdisplaywidth(text)
end

---@param text string
---@param width number
---@return string
local function pad_right(text, width)
  local padding = math.max(width - display_width(text), 0)
  return text .. string.rep(" ", padding)
end

---@param path string|nil
---@return string|nil
local function path_tail(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end

  local normalized = path
  if normalized ~= "/" and not normalized:match("^%a:[/\\]?$") then
    normalized = normalized:gsub("[/\\]+$", "")
  end

  if normalized == "" then
    normalized = path
  end

  local tail = vim.fn.fnamemodify(normalized, ":t")
  if tail ~= "" then
    return tail
  end

  return normalized
end

---@param win number|nil
---@return boolean
local function is_normal_window(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return false
  end

  local ok, cfg = pcall(vim.api.nvim_win_get_config, win)
  return ok and cfg.relative == ""
end

---@param win number
local function apply_input_window_options(win)
  vim.wo[win].signcolumn = "no"
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false

  if config.options.completion.enabled then
    vim.o.completeopt = INPUT_COMPLETEOPT
  end
end

local switch_nvim_terminal
local sync_nvim_sidebar
local show_nvim_terminal
local ensure_history_loaded
local clear_input_autosuggestion
local render_input_autosuggestion
local setup_input_buffer_autocmds
local feed_insert_keys

local function refresh_completion_state(buf, win)
  if not config.options.completion.enabled then
    return
  end

  if cheatsheets.has_placeholder_context(buf, win) then
    zsh_completion.cancel_auto_complete()
    cheatsheets.schedule_completion(buf, win)
    return
  end

  if config.options.completion.trigger == "auto" then
    zsh_completion.schedule_auto_complete(buf, win)
  else
    if vim.fn.pumvisible() == 1 then
      feed_insert_keys("<C-e>")
    end
    zsh_completion.cancel_auto_complete()
  end
end

---@param keys string
feed_insert_keys = function(keys)
  local rhs = vim.api.nvim_replace_termcodes(keys, true, false, true)
  vim.api.nvim_feedkeys(rhs, "in", false)
end

---@param text string
---@param width number
---@return string
local function setup_sidebar_highlights()
  vim.api.nvim_set_hl(0, "TerminalMateSidebarActive", { default = true, bold = true, reverse = true })
  vim.api.nvim_set_hl(0, "TerminalMateSidebarInactive", { default = true, link = "Normal" })
  vim.api.nvim_set_hl(0, "TerminalMateSuggestion", { default = true, link = "Comment" })
end

---@param win number|nil
---@return boolean
local function is_sidebar_window(win)
  return win ~= nil
    and vim.api.nvim_win_is_valid(win)
    and is_normal_window(win)
    and state.sidebar_buf ~= nil
    and vim.api.nvim_buf_is_valid(state.sidebar_buf)
    and vim.api.nvim_win_get_buf(win) == state.sidebar_buf
end

---@return number[]
local function get_sidebar_windows()
  if not state.sidebar_buf or not vim.api.nvim_buf_is_valid(state.sidebar_buf) then
    return {}
  end

  local windows = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if is_sidebar_window(win) then
      table.insert(windows, win)
    end
  end

  table.sort(windows, function(left, right)
    local left_pos = vim.api.nvim_win_get_position(left)
    local right_pos = vim.api.nvim_win_get_position(right)
    if left_pos[2] ~= right_pos[2] then
      return left_pos[2] > right_pos[2]
    end
    return left_pos[1] > right_pos[1]
  end)

  return windows
end

---@return number|nil
local function normalize_sidebar_window()
  local keep = nil

  if is_sidebar_window(state.sidebar_win) then
    keep = state.sidebar_win
  end

  local sidebar_windows = get_sidebar_windows()
  if not keep and #sidebar_windows > 0 then
    keep = sidebar_windows[1]
  end

  for _, win in ipairs(sidebar_windows) do
    if win ~= keep then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end

  state.sidebar_win = keep
  return keep
end

local function close_nvim_sidebar()
  for _, win in ipairs(get_sidebar_windows()) do
    pcall(vim.api.nvim_win_close, win, true)
  end

  state.sidebar_win = nil
  state.sidebar_terminal_ids = {}
end

local function get_or_create_sidebar_buf()
  if state.sidebar_buf and vim.api.nvim_buf_is_valid(state.sidebar_buf) then
    return state.sidebar_buf
  end

  local buf = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, buf, SIDEBAR_BUFNAME)

  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = SIDEBAR_FILETYPE

  local opts = { buffer = buf, noremap = true, silent = true, nowait = true }
  vim.keymap.set("n", "<CR>", function()
    M._sidebar_select_current()
  end, vim.tbl_extend("force", opts, { desc = "TerminalMate: Switch terminal" }))
  vim.keymap.set("n", "<LeftMouse>", function()
    M._sidebar_select_mouse()
  end, vim.tbl_extend("force", opts, { desc = "TerminalMate: Switch terminal" }))
  vim.keymap.set("n", "<2-LeftMouse>", function()
    M._sidebar_select_mouse()
  end, vim.tbl_extend("force", opts, { desc = "TerminalMate: Switch terminal" }))

  state.sidebar_buf = buf
  return buf
end

---@param win number
---@param width number
local function configure_sidebar_window(win, width)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end

  vim.api.nvim_win_set_width(win, width)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].wrap = false
  vim.wo[win].winfixwidth = true
  vim.wo[win].cursorline = false
  vim.wo[win].fillchars = "eob: "
end

---@param terminal_win number
---@param width number
---@return number|nil
local function ensure_sidebar_window(terminal_win, width)
  local sidebar_buf = get_or_create_sidebar_buf()
  local sidebar_win = normalize_sidebar_window()

  if sidebar_win then
    vim.api.nvim_win_set_buf(sidebar_win, sidebar_buf)
    configure_sidebar_window(sidebar_win, width)
    return sidebar_win
  end

  if not is_normal_window(terminal_win) then
    return nil
  end

  local previous_win = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(terminal_win)

  -- rightbelow keeps the sidebar attached to the terminal row instead of
  -- creating a full-height tab-wide split.
  local ok = pcall(vim.cmd, "rightbelow vertical " .. width .. "split")
  if not ok then
    if vim.api.nvim_win_is_valid(previous_win) then
      vim.api.nvim_set_current_win(previous_win)
    end
    return nil
  end

  state.sidebar_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.sidebar_win, sidebar_buf)
  configure_sidebar_window(state.sidebar_win, width)
  normalize_sidebar_window()

  if vim.api.nvim_win_is_valid(previous_win) and previous_win ~= state.sidebar_win then
    vim.api.nvim_set_current_win(previous_win)
  end

  return state.sidebar_win
end

function M._sidebar_select_current()
  if vim.api.nvim_get_current_buf() ~= state.sidebar_buf then
    return
  end

  local line = vim.api.nvim_win_get_cursor(0)[1]
  local terminal_id = state.sidebar_terminal_ids[line]
  if terminal_id and switch_nvim_terminal then
    switch_nvim_terminal(terminal_id)
  end
end

function M._sidebar_select_mouse()
  local mouse = vim.fn.getmousepos()
  local winid = mouse.winid
  if not winid or winid == 0 or winid ~= state.sidebar_win or not vim.api.nvim_win_is_valid(winid) then
    return
  end

  local line_count = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(winid))
  local line = clamp(mouse.line or mouse.winrow or 1, 1, math.max(line_count, 1))
  vim.api.nvim_set_current_win(winid)
  vim.api.nvim_win_set_cursor(winid, { line, 0 })
  M._sidebar_select_current()
end

--- Unmetafy a binary string from zsh's metafied format.
--- Zsh stores history in "metafied" format where certain bytes (0x83-0x9d, 0xa0, 0x00)
--- are escaped: a Meta byte (0x83) is inserted before the byte, and the byte is XOR'd with 0x20.
--- This function reverses that encoding to recover the original UTF-8 bytes.
---@param data string raw binary data from zsh history file
---@return string unmetafied data
local function unmetafy(data)
  local bit = require("bit")
  local result = {}
  local i = 1
  local len = #data
  local META = 0x83

  while i <= len do
    local byte = data:byte(i)
    if byte == META and i < len then
      local next_byte = data:byte(i + 1)
      table.insert(result, string.char(bit.bxor(next_byte, 0x20)))
      i = i + 2
    else
      table.insert(result, string.char(byte))
      i = i + 1
    end
  end

  return table.concat(result)
end

--- Load shell history from zsh or bash history file.
--- Supports three formats that can coexist in the same file:
---   1. Plain text lines (one command per line, no prefix)
---   2. Zsh extended history lines (`: timestamp:0;command`)
---   3. Multi-line commands using `\` or `\\` continuation at end of line
--- For zsh files with metafied encoding, applies unmetafy() first.
---@return string[]
local function load_zsh_history()
  local history = {}
  local history_file = vim.env.HISTFILE or (vim.env.HOME .. "/.zsh_history")

  local f = io.open(history_file, "rb")
  if not f then
    f = io.open(vim.env.HOME .. "/.bash_history", "rb")
  end
  if not f then
    return history
  end

  local raw = f:read("*a")
  f:close()

  local content
  if raw:find("\131") then
    content = unmetafy(raw)
  else
    content = raw
  end

  local function is_continuation(line)
    return line:match("\\$") ~= nil
  end

  local function unescape_history(cmd)
    local lines = {}
    for line in cmd:gmatch("[^\n]+") do
      table.insert(lines, line)
    end
    if cmd:match("\n$") then
      table.insert(lines, "")
    end

    local result = {}
    for _, line in ipairs(lines) do
      if line:match("\\\\$") then
        table.insert(result, line:sub(1, -2))
      elseif line:match("\\$") then
        table.insert(result, line:sub(1, -2))
      else
        table.insert(result, line)
      end
    end
    return table.concat(result, "\n")
  end

  local function save_entry(cmd)
    if not cmd then
      return
    end

    local unescaped = unescape_history(cmd)
    local trimmed = vim.trim(unescaped)
    if trimmed ~= "" and not trimmed:match("^#") then
      table.insert(history, trimmed)
    end
  end

  local current_cmd = nil
  for line in content:gmatch("[^\n]+") do
    local ts_cmd = line:match("^: %d+:%d+;(.*)$")

    if ts_cmd then
      save_entry(current_cmd)
      current_cmd = ts_cmd
    elseif current_cmd ~= nil and is_continuation(current_cmd) then
      current_cmd = current_cmd .. "\n" .. line
    else
      save_entry(current_cmd)
      if line ~= "" then
        current_cmd = line
      else
        current_cmd = nil
      end
    end
  end

  save_entry(current_cmd)
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

---@param text string
---@return string[]
local function split_buffer_text(text)
  local lines = vim.split(text, "\n", { plain = true })
  if #lines == 0 then
    return { "" }
  end
  return lines
end

---@param buf number
---@return string
local function get_raw_buffer_text(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if #lines == 0 then
    return ""
  end
  return table.concat(lines, "\n")
end

---@param text string
---@return string
local function normalize_buffer_text(text)
  local lines = split_buffer_text(text)
  local first = 1
  while first <= #lines and vim.trim(lines[first]) == "" do
    first = first + 1
  end

  local last = #lines
  while last >= first and vim.trim(lines[last]) == "" do
    last = last - 1
  end

  if first > last then
    return ""
  end

  return table.concat(vim.list_slice(lines, first, last), "\n")
end

---@param buf number|nil
local function clear_accepted_suggestion(buf)
  if not state.accepted_suggestion then
    return
  end

  if not buf or state.accepted_suggestion.buf == buf then
    state.accepted_suggestion = nil
  end
end

---@param buf number
local function sync_accepted_suggestion(buf)
  local accepted = state.accepted_suggestion
  if not accepted or accepted.buf ~= buf then
    return
  end

  if not vim.api.nvim_buf_is_valid(buf) then
    state.accepted_suggestion = nil
    return
  end

  local raw = get_raw_buffer_text(buf)
  if raw == accepted.text or accepted.text:sub(1, #raw) == raw then
    return
  end

  state.accepted_suggestion = nil
end

---@param buf number
---@param text string
---@return string[]
local function set_buffer_text(buf, text)
  cheatsheets.clear_active(buf)
  local lines = split_buffer_text(text)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return lines
end

---@param buf number
---@param win number
local function refresh_input_buffer_state(buf, win)
  sync_accepted_suggestion(buf)
  render_input_autosuggestion(buf, win)
  cheatsheets.refresh(buf, win)
  refresh_completion_state(buf, win)
end

---@param buf number
---@param win number
---@return table|nil
local function current_input_line_context(buf, win)
  if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_win_is_valid(win) then
    return nil
  end

  if vim.api.nvim_win_get_buf(win) ~= buf then
    return nil
  end

  local cursor = vim.api.nvim_win_get_cursor(win)
  local row = cursor[1] - 1
  local col = cursor[2]
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""

  return {
    row = row,
    line_nr = cursor[1],
    col = col,
    line = line,
  }
end

---@param line string
---@param col number
---@return number
local function previous_shell_word_col(line, col)
  local prefix = line:sub(1, col)
  local trimmed = prefix:gsub("%s+$", "")
  local without_word = trimmed:gsub("%S+$", "")
  return #without_word
end

---@param line string
---@param col number
---@return number
local function next_shell_word_col(line, col)
  local suffix = line:sub(col + 1)
  local spaces = suffix:match("^%s*") or ""
  local word = suffix:sub(#spaces + 1):match("^%S*") or ""
  return col + #spaces + #word
end

---@param buf number
---@param win number
---@param start_col number
---@param end_col number
---@param replacement string
local function replace_input_range(buf, win, start_col, end_col, replacement)
  local ctx = current_input_line_context(buf, win)
  if not ctx then
    return
  end

  vim.api.nvim_buf_set_text(buf, ctx.row, start_col, ctx.row, end_col, { replacement })
  vim.api.nvim_win_set_cursor(win, { ctx.line_nr, start_col + #replacement })
  state.history_index = 0
  refresh_input_buffer_state(buf, win)
end

---@param win number
---@param buf number
local function move_cursor_to_buffer_end(win, buf)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end

  local line_count = math.max(vim.api.nvim_buf_line_count(buf), 1)
  local last_line = vim.api.nvim_buf_get_lines(buf, line_count - 1, line_count, false)[1] or ""
  vim.api.nvim_win_set_cursor(win, { line_count, #last_line })
end

---@param remainder string
---@return string
local function format_autosuggestion_preview(remainder)
  local preview = remainder:gsub("\n", " \\ ")
  if #preview > AUTOSUGGEST_PREVIEW_MAX then
    preview = preview:sub(1, AUTOSUGGEST_PREVIEW_MAX - 3) .. "..."
  end
  return preview
end

---@param prefix string
---@return string|nil
local function find_history_suggestion(prefix)
  if prefix == "" then
    return nil
  end

  ensure_history_loaded()

  for index = #state.history, 1, -1 do
    local entry = state.history[index]
    if entry ~= prefix and entry:sub(1, #prefix) == prefix then
      return entry
    end
  end

  return nil
end

---@param buf number
---@param win number
---@return table|nil
local function get_autosuggestion_candidate(buf, win)
  if not buf
    or not vim.api.nvim_buf_is_valid(buf)
    or not win
    or not vim.api.nvim_win_is_valid(win)
    or vim.api.nvim_win_get_buf(win) ~= buf
  then
    return nil
  end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if #lines == 0 then
    return nil
  end

  local cursor = vim.api.nvim_win_get_cursor(win)
  local row = cursor[1]
  local col = cursor[2]

  if row ~= #lines or col ~= #lines[#lines] then
    return nil
  end

  local prefix = table.concat(lines, "\n")
  if prefix == "" then
    return nil
  end

  local suggestion = find_history_suggestion(prefix)
  if not suggestion then
    return nil
  end

  local remainder = suggestion:sub(#prefix + 1)
  if remainder == "" then
    return nil
  end

  local preview = format_autosuggestion_preview(remainder)
  if preview == "" then
    return nil
  end

  return {
    buf = buf,
    row = row,
    col = col,
    text = suggestion,
    remainder = remainder,
    preview = preview,
  }
end

clear_input_autosuggestion = function(buf)
  local target_buf = buf or (state.autosuggestion and state.autosuggestion.buf) or state.input_buf
  if target_buf and vim.api.nvim_buf_is_valid(target_buf) then
    vim.api.nvim_buf_clear_namespace(target_buf, AUTOSUGGEST_NS, 0, -1)
  end
  state.autosuggestion = nil
end

render_input_autosuggestion = function(buf, win)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    state.autosuggestion = nil
    return nil
  end

  clear_input_autosuggestion(buf)

  local candidate = get_autosuggestion_candidate(buf, win)
  if not candidate then
    return nil
  end

  vim.api.nvim_buf_set_extmark(buf, AUTOSUGGEST_NS, candidate.row - 1, candidate.col, {
    virt_text = { { candidate.preview, "TerminalMateSuggestion" } },
    virt_text_pos = "overlay",
    hl_mode = "combine",
  })

  state.autosuggestion = candidate
  return candidate
end

setup_input_buffer_autocmds = function(buf)
  if vim.b[buf].terminal_mate_autosuggest_ready then
    return
  end
  vim.b[buf].terminal_mate_autosuggest_ready = true

  local group = vim.api.nvim_create_augroup("TerminalMateInput" .. buf, { clear = true })

  vim.api.nvim_create_autocmd(
    { "TextChangedI", "TextChanged", "CursorMovedI", "CursorMoved", "BufEnter", "InsertEnter", "WinEnter" },
    {
      group = group,
      buffer = buf,
      callback = function(args)
        if not vim.api.nvim_buf_is_valid(buf) then
          return
        end

        local win = vim.api.nvim_get_current_win()
        if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= buf then
          clear_input_autosuggestion(buf)
          zsh_completion.cancel_auto_complete()
          return
        end

        render_input_autosuggestion(buf, win)
        cheatsheets.refresh(buf, win)

        if args.event == "TextChangedI" then
          refresh_completion_state(buf, win)
        end
      end,
    }
  )

  vim.api.nvim_create_autocmd({ "BufLeave", "InsertLeave", "BufHidden" }, {
    group = group,
    buffer = buf,
    callback = function()
      clear_input_autosuggestion(buf)
      zsh_completion.cancel_auto_complete()
    end,
  })

  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = group,
    buffer = buf,
    once = true,
    callback = function()
      clear_input_autosuggestion(buf)
      if state.input_buf == buf then
        state.input_buf = nil
      end
    end,
  })
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
  setup_input_buffer_autocmds(buf)

  if config.options.completion.enabled then
    zsh_completion.prime()
  end

  return buf
end

--- Get the current buffer as a command block, preserving internal blank lines.
---@return string
local function get_buffer_text()
  local buf = vim.api.nvim_get_current_buf()
  local raw = get_raw_buffer_text(buf)
  local normalized = normalize_buffer_text(raw)

  if buf == state.input_buf then
    sync_accepted_suggestion(buf)

    local accepted = state.accepted_suggestion
    if accepted and accepted.buf == buf then
      local accepted_text = normalize_buffer_text(accepted.text)
      if accepted_text ~= "" and accepted_text ~= normalized and accepted.text:sub(1, #raw) == raw then
        return accepted_text
      end
    end
  end

  return normalized
end

--- Get visual selection text
---@param visual_type string|nil
---@return string
local function get_visual_text(visual_type)
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local selection_type = visual_type or vim.fn.visualmode()

  if vim.fn.exists("*getregion") == 1 then
    local ok_region, region = pcall(vim.fn.getregion, start_pos, end_pos, { type = selection_type })
    if not ok_region then
      ok_region, region = pcall(vim.fn.getregion, start_pos, end_pos, selection_type)
    end
    if ok_region and type(region) == "table" then
      return table.concat(region, "\n")
    end
  end

  local start_row = start_pos[2] - 1
  local start_col = start_pos[3] - 1
  local end_row = end_pos[2] - 1
  local end_col = end_pos[3] - 1

  if start_row > end_row or (start_row == end_row and start_col > end_col) then
    start_row, end_row = end_row, start_row
    start_col, end_col = end_col, start_col
  end

  if selection_type == "V" then
    local lines = vim.api.nvim_buf_get_lines(0, start_row, end_row + 1, false)
    return table.concat(lines, "\n")
  end

  if selection_type == "\22" then
    local left = math.min(start_col, end_col)
    local right = math.max(start_col, end_col) + 1
    local lines = {}
    for row = start_row, end_row do
      local line = vim.api.nvim_buf_get_lines(0, row, row + 1, false)[1] or ""
      local line_end = math.min(#line, right)
      local chunk = vim.api.nvim_buf_get_text(0, row, left, row, line_end, {})[1] or ""
      table.insert(lines, chunk)
    end
    return table.concat(lines, "\n")
  end

  local lines = vim.api.nvim_buf_get_text(0, start_row, start_col, end_row, end_col + 1, {})
  return table.concat(lines, "\n")
end

local function reset_tmux_state()
  state.terminal_pane_id = nil
  state.nvim_pane_id = nil
end

local function sync_current_nvim_state(terminal)
  state.terminal_win = terminal and terminal.win or nil
  state.terminal_buf = terminal and terminal.buf or nil
  state.terminal_job_id = terminal and terminal.job_id or nil
  state.terminal_shell_command = terminal and terminal.shell_command or nil
  state.terminal_shell_source = terminal and terminal.shell_source or nil
  state.terminal_shell_diagnostics = terminal and terminal.shell_diagnostics or nil
  state.terminal_last_error = terminal and terminal.last_error or nil
end

---@param terminal table
local function mark_nvim_terminal_active(terminal)
  state.activity_seq = state.activity_seq + 1
  terminal.last_used_seq = state.activity_seq
  state.current_terminal_id = terminal.id
  state.backend = "nvim"
  sync_current_nvim_state(terminal)

  if sync_nvim_sidebar then
    sync_nvim_sidebar()
  end
end

---@param left table|nil
---@param right table|nil
---@return boolean
local function is_newer_terminal(left, right)
  if not left then
    return false
  end
  if not right then
    return true
  end

  local left_seq = left.last_used_seq or left.created_seq or 0
  local right_seq = right.last_used_seq or right.created_seq or 0
  if left_seq ~= right_seq then
    return left_seq > right_seq
  end

  return (left.id or 0) > (right.id or 0)
end

---@param terminal_id number|nil
---@return table|nil
local function find_nvim_terminal(terminal_id)
  if not terminal_id then
    return nil
  end

  for _, terminal in ipairs(state.nvim_terminals) do
    if terminal.id == terminal_id then
      return terminal
    end
  end

  return nil
end

---@param buf number|nil
---@return table|nil
local function find_nvim_terminal_by_buf(buf)
  if not buf then
    return nil
  end

  for _, terminal in ipairs(state.nvim_terminals) do
    if terminal.buf == buf then
      return terminal
    end
  end

  return nil
end

local function remove_nvim_terminal(terminal_id)
  for index, terminal in ipairs(state.nvim_terminals) do
    if terminal.id == terminal_id then
      table.remove(state.nvim_terminals, index)
      break
    end
  end
end

---@return table|nil
local function get_visible_nvim_terminal()
  local visible = nil

  for _, terminal in ipairs(state.nvim_terminals) do
    if terminal.win and not vim.api.nvim_win_is_valid(terminal.win) then
      terminal.win = nil
    end

    if terminal.win and vim.api.nvim_win_is_valid(terminal.win) then
      visible = terminal
    end
  end

  return visible
end

---@return table|nil
local function get_latest_nvim_terminal()
  local latest = nil

  for _, terminal in ipairs(state.nvim_terminals) do
    if is_newer_terminal(terminal, latest) then
      latest = terminal
    end
  end

  return latest
end

local function prune_nvim_terminals()
  local alive = {}

  for _, terminal in ipairs(state.nvim_terminals) do
    if terminal.win and not vim.api.nvim_win_is_valid(terminal.win) then
      terminal.win = nil
    end

    if nvim_terminal.is_alive(terminal) then
      table.insert(alive, terminal)
    else
      nvim_terminal.reset(terminal)
    end
  end

  state.nvim_terminals = alive

  local current = find_nvim_terminal(state.current_terminal_id)
  if not current then
    current = get_latest_nvim_terminal()
    state.current_terminal_id = current and current.id or nil
  end

  sync_current_nvim_state(current)
  if not current and state.backend == "nvim" then
    state.backend = nil
  end
end

---@return boolean
local function has_tmux_terminal()
  if state.terminal_pane_id and tmux.pane_exists(state.terminal_pane_id) then
    return true
  end

  reset_tmux_state()
  if state.backend == "tmux" then
    state.backend = nil
  end
  return false
end

---@return boolean
local function has_nvim_terminal()
  prune_nvim_terminals()
  return #state.nvim_terminals > 0
end

---@return table|nil
local function get_current_nvim_terminal()
  prune_nvim_terminals()

  local current = find_nvim_terminal(state.current_terminal_id)
  if current then
    return current
  end

  current = get_latest_nvim_terminal()
  if current then
    state.current_terminal_id = current.id
    sync_current_nvim_state(current)
  end

  return current
end

local function build_sidebar_entries()
  local terminals = {}
  for _, terminal in ipairs(state.nvim_terminals) do
    table.insert(terminals, terminal)
  end

  table.sort(terminals, function(left, right)
    return (left.id or 0) < (right.id or 0)
  end)

  for _, terminal in ipairs(terminals) do
    local label = path_tail(nvim_terminal.current_path(terminal))
    if not label then
      local shell_command = terminal.shell_command or config.options.shell or vim.env.SHELL or vim.o.shell or "shell"
      local executable = shell_command:match("^%s*([^%s]+)") or shell_command
      label = vim.fn.fnamemodify(executable, ":t")
      label = label ~= "" and label or "shell"
    end

    terminal._sidebar_label = label
  end

  local rows = {}
  local active_row = 1
  local longest = 0

  for index, terminal in ipairs(terminals) do
    local is_active = terminal.id == state.current_terminal_id
    local label = terminal._sidebar_label or "shell"

    local prefix = is_active and "| " or "  "
    local line = string.format("%s#%d %s", prefix, terminal.id or index, label)
    longest = math.max(longest, display_width(line))
    table.insert(rows, {
      line = line,
      terminal_id = terminal.id,
      active = is_active,
    })

    if terminal.id == state.current_terminal_id then
      active_row = index
    end
  end

  local width = clamp(longest + 1, SIDEBAR_MIN_WIDTH, SIDEBAR_MAX_WIDTH)
  local lines = {}
  local terminal_ids = {}
  local line_highlights = {}

  for _, row in ipairs(rows) do
    local line_number = #lines + 1
    table.insert(lines, pad_right(row.line, width))
    terminal_ids[line_number] = row.terminal_id
    line_highlights[line_number] = row.active and "TerminalMateSidebarActive" or "TerminalMateSidebarInactive"
  end

  local active_line = active_row
  return lines, terminal_ids, line_highlights, width, active_line
end

local function render_sidebar(lines, terminal_ids, line_highlights, active_line)
  local sidebar_buf = get_or_create_sidebar_buf()
  local sidebar_win = state.sidebar_win
  if not sidebar_win or not vim.api.nvim_win_is_valid(sidebar_win) then
    return
  end

  vim.bo[sidebar_buf].modifiable = true
  vim.api.nvim_buf_set_lines(sidebar_buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(sidebar_buf, SIDEBAR_NS, 0, -1)

  for index, _ in ipairs(lines) do
    local hl_group = line_highlights[index] or "TerminalMateSidebarInactive"
    vim.api.nvim_buf_add_highlight(sidebar_buf, SIDEBAR_NS, hl_group, index - 1, 0, -1)
  end

  vim.bo[sidebar_buf].modifiable = false
  state.sidebar_terminal_ids = terminal_ids

  local current_win = vim.api.nvim_get_current_win()
  if current_win ~= sidebar_win then
    pcall(vim.api.nvim_win_set_cursor, sidebar_win, { active_line, 0 })
    return
  end

  local line = vim.api.nvim_win_get_cursor(sidebar_win)[1]
  if line < 1 or line > #lines then
    pcall(vim.api.nvim_win_set_cursor, sidebar_win, { active_line, 0 })
  end
end

sync_nvim_sidebar = function()
  prune_nvim_terminals()

  local visible_terminal = get_visible_nvim_terminal()
  if not visible_terminal or not visible_terminal.win then
    close_nvim_sidebar()
    return
  end

  local lines, terminal_ids, line_highlights, width, active_line = build_sidebar_entries()
  if #lines == 0 then
    close_nvim_sidebar()
    return
  end

  setup_sidebar_highlights()

  local sidebar_win = ensure_sidebar_window(visible_terminal.win, width)
  if not sidebar_win then
    return
  end

  render_sidebar(lines, terminal_ids, line_highlights, active_line)
end

switch_nvim_terminal = function(terminal_id)
  prune_nvim_terminals()

  local terminal = find_nvim_terminal(terminal_id)
  if not terminal then
    sync_nvim_sidebar()
    notify("Managed terminal #" .. tostring(terminal_id) .. " is no longer available.", vim.log.levels.WARN)
    return
  end

  if terminal.win and vim.api.nvim_win_is_valid(terminal.win) then
    mark_nvim_terminal_active(terminal)
    pcall(vim.api.nvim_set_current_win, terminal.win)
    return
  end

  if not show_nvim_terminal(terminal) then
    sync_nvim_sidebar()
  end
end

---@return table[]
local function get_sorted_nvim_terminals()
  prune_nvim_terminals()

  local terminals = {}
  for _, terminal in ipairs(state.nvim_terminals) do
    table.insert(terminals, terminal)
  end

  table.sort(terminals, function(left, right)
    return (left.id or 0) < (right.id or 0)
  end)

  return terminals
end

---@param step integer
local function cycle_nvim_terminal(step)
  local terminals = get_sorted_nvim_terminals()
  if #terminals == 0 then
    notify("No managed Neovim terminals available.", vim.log.levels.WARN)
    return
  end

  local current = get_current_nvim_terminal() or terminals[1]
  local current_index = 1
  for index, terminal in ipairs(terminals) do
    if terminal.id == current.id then
      current_index = index
      break
    end
  end

  local target_index = ((current_index - 1 + step) % #terminals) + 1
  switch_nvim_terminal(terminals[target_index].id)
end

---@return string|nil
local function get_active_backend()
  if state.backend == "nvim" and has_nvim_terminal() then
    return "nvim"
  end
  if state.backend == "tmux" and has_tmux_terminal() then
    return "tmux"
  end
  if has_nvim_terminal() then
    state.backend = "nvim"
    return "nvim"
  end
  if has_tmux_terminal() then
    state.backend = "tmux"
    return "tmux"
  end

  state.backend = nil
  return nil
end

---@return string[]
local function preferred_backends()
  if config.options.backend == "nvim" then
    return { "nvim" }
  end
  if config.options.backend == "tmux" then
    return { "tmux" }
  end
  return { "nvim", "tmux" }
end

---@param backend string
---@return boolean
local function backend_is_available(backend)
  if backend == "nvim" then
    -- Defer strict capability checks to ensure_nvim_terminal(); it has better
    -- diagnostics and fallback handling than a boolean gate here.
    return true
  end
  return tmux.is_tmux()
end

---@return string|nil
local function get_managed_tmux_pane()
  if has_tmux_terminal() then
    return state.terminal_pane_id
  end
  return nil
end

---@return string|nil
local function ensure_managed_tmux_pane()
  if not tmux.is_tmux() then
    notify("tmux backend is unavailable outside a tmux session.", vim.log.levels.ERROR)
    return nil
  end

  local pane_id = get_managed_tmux_pane()
  if pane_id then
    state.backend = "tmux"
    return pane_id
  end

  state.nvim_pane_id = tmux.current_pane_id()
  pane_id = tmux.split_above(config.options.split_percent, config.options.shell)
  if not pane_id then
    notify("Failed to create tmux split.", vim.log.levels.ERROR)
    return nil
  end

  state.backend = "tmux"
  state.terminal_pane_id = pane_id
  return pane_id
end

---@return string|nil
local function resolve_tmux_completion_pane()
  if not tmux.is_tmux() then
    return nil
  end

  local current_pane_id = tmux.current_pane_id()
  if current_pane_id then
    state.nvim_pane_id = current_pane_id
    local adjacent_pane_id = tmux.find_adjacent_pane(current_pane_id)
    if adjacent_pane_id and tmux.pane_exists(adjacent_pane_id) then
      return adjacent_pane_id
    end
  end

  if has_tmux_terminal() then
    return state.terminal_pane_id
  end

  return nil
end

---@return table
local function collect_completion_context()
  local visible_terminal = get_visible_nvim_terminal()
  if visible_terminal then
    local path_ctx = nvim_terminal.current_path_context(visible_terminal)
    if path_ctx.cwd then
      return {
        backend = "nvim",
        source = "visible_nvim_terminal:" .. path_ctx.source,
        cwd = path_ctx.cwd,
        terminal_id = visible_terminal.id,
        terminal_buf = visible_terminal.buf,
      }
    end
  end

  local active_backend = get_active_backend()
  if active_backend == "tmux" then
    local pane_id = resolve_tmux_completion_pane()
    local cwd = tmux.current_path(pane_id)
    if cwd then
      return {
        backend = "tmux",
        source = "active_tmux_pane",
        cwd = cwd,
        pane_id = pane_id,
      }
    end
  end

  local current_terminal = get_current_nvim_terminal()
  if current_terminal then
    local path_ctx = nvim_terminal.current_path_context(current_terminal)
    if path_ctx.cwd then
      return {
        backend = "nvim",
        source = "current_nvim_terminal:" .. path_ctx.source,
        cwd = path_ctx.cwd,
        terminal_id = current_terminal.id,
        terminal_buf = current_terminal.buf,
      }
    end
  end

  if active_backend ~= "nvim" then
    local pane_id = resolve_tmux_completion_pane()
    local cwd = tmux.current_path(pane_id)
    if cwd then
      return {
        backend = "tmux",
        source = "fallback_tmux_pane",
        cwd = cwd,
        pane_id = pane_id,
      }
    end
  end

  return {
    backend = active_backend,
    source = "none",
    cwd = nil,
  }
end

---@return string|nil
local function resolve_completion_cwd()
  return collect_completion_context().cwd
end

---@return string
local function resolve_cheatsheet_shell()
  local visible_terminal = get_visible_nvim_terminal()
  if visible_terminal and type(visible_terminal.shell_command) == "string" and visible_terminal.shell_command ~= "" then
    return visible_terminal.shell_command
  end

  local current_terminal = get_current_nvim_terminal()
  if current_terminal and type(current_terminal.shell_command) == "string" and current_terminal.shell_command ~= "" then
    return current_terminal.shell_command
  end

  return config.options.shell or vim.env.SHELL or vim.o.shell or "sh"
end

---@param terminal table
---@return boolean
show_nvim_terminal = function(terminal)
  local visible = get_visible_nvim_terminal()
  local reuse_win = visible and visible.win or nil
  if visible and visible.id ~= terminal.id then
    visible.win = nil
  end

  local ok, err = nvim_terminal.show(terminal, {
    split_percent = config.options.split_percent,
    reuse_win = reuse_win,
  })
  if not ok then
    notify(err or "Failed to show Neovim terminal.", vim.log.levels.ERROR)
    prune_nvim_terminals()
    return false
  end

  mark_nvim_terminal_active(terminal)
  return true
end

---@return table|nil
local function create_nvim_terminal()
  prune_nvim_terminals()

  local visible = get_visible_nvim_terminal()
  local reuse_win = visible and visible.win or nil
  if visible then
    visible.win = nil
  end

  state.next_terminal_id = state.next_terminal_id + 1
  local terminal = {
    id = state.next_terminal_id,
    created_seq = state.next_terminal_id,
    last_used_seq = 0,
  }

  local ok, err = nvim_terminal.create(terminal, {
    split_percent = config.options.split_percent,
    shell = config.options.shell,
    shell_integration = config.options.shell_integration,
    reuse_win = reuse_win,
  })
  if not ok then
    notify(err or "Failed to create Neovim terminal.", vim.log.levels.ERROR)
    return nil
  end

  table.insert(state.nvim_terminals, terminal)
  mark_nvim_terminal_active(terminal)
  return terminal
end

---@param opts table|nil
---@return table|nil
local function ensure_nvim_terminal(opts)
  opts = opts or {}

  local terminal = nil
  if opts.new_terminal then
    terminal = create_nvim_terminal()
  else
    terminal = get_current_nvim_terminal()
    if not terminal then
      terminal = create_nvim_terminal()
    elseif opts.show then
      if not show_nvim_terminal(terminal) then
        return nil
      end
    end
  end

  if not terminal then
    return nil
  end

  if opts.show and not terminal.win then
    if not show_nvim_terminal(terminal) then
      return nil
    end
  elseif not opts.show then
    mark_nvim_terminal_active(terminal)
  end

  return terminal
end

---@return string|nil
---@return string|table|nil
local function ensure_managed_terminal()
  local active_backend = get_active_backend()
  if active_backend == "nvim" then
    local terminal = ensure_nvim_terminal({ show = true })
    return terminal and "nvim" or nil, terminal
  end
  if active_backend == "tmux" then
    return "tmux", state.terminal_pane_id
  end

  for _, backend in ipairs(preferred_backends()) do
    if backend == "nvim" and backend_is_available("nvim") then
      local terminal = ensure_nvim_terminal({ show = true })
      if terminal then
        return "nvim", terminal
      end
      if config.options.backend == "nvim" then
        return nil, nil
      end
    elseif backend == "tmux" and backend_is_available("tmux") then
      local pane_id = ensure_managed_tmux_pane()
      if pane_id then
        return "tmux", pane_id
      end
      if config.options.backend == "tmux" then
        return nil, nil
      end
    end
  end

  notify("No terminal backend is available.", vim.log.levels.ERROR)
  return nil, nil
end

---@return string|nil
---@return string|table|nil
local function ensure_send_target()
  local active_backend = get_active_backend()
  if active_backend == "nvim" then
    local terminal = ensure_nvim_terminal({ show = false })
    return terminal and "nvim" or nil, terminal
  end
  if active_backend == "tmux" then
    return "tmux", state.terminal_pane_id
  end

  for _, backend in ipairs(preferred_backends()) do
    if backend == "nvim" and backend_is_available("nvim") then
      local terminal = ensure_nvim_terminal({ show = false })
      if terminal then
        return "nvim", terminal
      end
      if config.options.backend == "nvim" then
        return nil, nil
      end
    elseif backend == "tmux" and backend_is_available("tmux") then
      local current_pane_id = tmux.current_pane_id()
      if current_pane_id then
        state.nvim_pane_id = current_pane_id
        local adjacent_pane_id = tmux.find_adjacent_pane(current_pane_id)
        if adjacent_pane_id and tmux.pane_exists(adjacent_pane_id) then
          return "tmux", adjacent_pane_id
        end
      end

      local pane_id = ensure_managed_tmux_pane()
      if pane_id then
        return "tmux", pane_id
      end
      if config.options.backend == "tmux" then
        return nil, nil
      end
    end
  end

  notify(
    "No terminal target is available. Check :set shell? and terminal backend config (:h terminal-mate).",
    vim.log.levels.ERROR
  )
  return nil, nil
end

---@param text string
---@return string[]
local function build_command_blocks(text)
  local lines = vim.split(text, "\n", { plain = true, trimempty = false })
  local blocks = {}
  local current_block = {}

  for _, line in ipairs(lines) do
    table.insert(current_block, line)
    local trimmed = vim.trim(line)
    if trimmed:sub(-1) ~= "\\" then
      table.insert(blocks, table.concat(current_block, "\n"))
      current_block = {}
    end
  end

  if #current_block > 0 then
    table.insert(blocks, table.concat(current_block, "\n"))
  end

  return blocks
end

---@param backend string
---@param target string|table|nil
---@param text string
local function send_to_target(backend, target, text)
  if text == "" then
    return
  end

  local blocks = build_command_blocks(text)

  if backend == "tmux" then
    if not target or not tmux.pane_exists(target) then
      notify("Target tmux pane no longer exists.", vim.log.levels.WARN)
      if state.terminal_pane_id == target then
        reset_tmux_state()
      end
      return
    end

    for _, block in ipairs(blocks) do
      tmux.send_text(target, block, true)
    end
    return
  end

  local terminal = target
  if not terminal or not nvim_terminal.is_alive(terminal) then
    if terminal and terminal.id then
      remove_nvim_terminal(terminal.id)
    end
    prune_nvim_terminals()
    terminal = get_current_nvim_terminal() or ensure_nvim_terminal({ show = false })
  end

  for _, block in ipairs(blocks) do
    if not terminal then
      return
    end

    mark_nvim_terminal_active(terminal)

    local ok, err = nvim_terminal.send_text(terminal, block, true)
    if not ok then
      notify(err or "Failed to send to Neovim terminal.", vim.log.levels.WARN)
      local failed_id = terminal.id
      nvim_terminal.close(terminal)
      remove_nvim_terminal(failed_id)
      prune_nvim_terminals()

      local delivered = false
      terminal = get_current_nvim_terminal()
      if not terminal then
        terminal = ensure_nvim_terminal({ show = false })
      end

      if terminal then
        mark_nvim_terminal_active(terminal)
        local retry_ok, retry_err = nvim_terminal.send_text(terminal, block, true)
        if retry_ok then
          delivered = true
        else
          notify(retry_err or "Failed to send to replacement Neovim terminal.", vim.log.levels.WARN)
        end
      end

      if not delivered and tmux.is_tmux() and config.options.backend ~= "nvim" then
        local fallback_target = ensure_managed_tmux_pane()
        if fallback_target then
          tmux.send_text(fallback_target, block, true)
          state.backend = "tmux"
          delivered = true
        end
      end

      if not delivered then
        return
      end
    end
  end
end

---@param text string
local function send_to_terminal(text)
  if text == "" then
    return
  end

  local active_backend = get_active_backend()

  local backend = active_backend
  local target = nil
  if backend == "tmux" then
    target = state.terminal_pane_id
  elseif backend == "nvim" then
    target = get_current_nvim_terminal()
  else
    backend, target = ensure_managed_terminal()
  end

  if not backend then
    return
  end

  send_to_target(backend, target, text)
end

--- Clear the buffer content
local function clear_buffer()
  if config.options.clear_input then
    clear_accepted_suggestion(0)
    set_buffer_text(0, "")
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    if vim.api.nvim_get_current_buf() == state.input_buf then
      render_input_autosuggestion(0, vim.api.nvim_get_current_win())
    end
  end
end

--- Temporarily resize nvim pane to 50% for search, save original height
local function expand_nvim_pane_for_search()
  if get_active_backend() ~= "tmux" or not state.nvim_pane_id then
    return
  end

  state._saved_nvim_height = tmux.get_pane_height(state.nvim_pane_id)
  tmux.resize_pane_percent(state.nvim_pane_id, 50)
end

--- Restore nvim pane to original height after search
local function restore_nvim_pane_size()
  if get_active_backend() ~= "tmux" or not state.nvim_pane_id or not state._saved_nvim_height then
    return
  end

  tmux.resize_pane_rows(state.nvim_pane_id, state._saved_nvim_height)
  state._saved_nvim_height = nil
end

ensure_history_loaded = function()
  if #state.history == 0 then
    state.history = dedupe_history(load_zsh_history())
  end
end

local function ensure_terminal_visible()
  local active_backend = get_active_backend()
  local backend = active_backend
  local target = nil

  if backend == "nvim" then
    target = ensure_nvim_terminal({ show = true })
    if not target then
      return nil, nil
    end
  elseif not backend then
    backend, target = ensure_managed_terminal()
    if not backend then
      return nil, nil
    end
  elseif backend == "tmux" then
    target = state.terminal_pane_id
  end

  if backend ~= "nvim" then
    close_nvim_sidebar()
  end

  return backend, target
end

--- Open terminal pane only (do not enter terminal_mate input mode)
function M.open_pane()
  ensure_history_loaded()

  local backend, target = ensure_terminal_visible()
  if not backend then
    return
  end

  if backend == "tmux" then
    notify("Terminal pane opened (" .. target .. ", tmux backend)")
  else
    notify("Terminal pane opened (Neovim backend #" .. target.id .. ")")
  end
end

--- Open terminal_mate input mode
function M.open()
  ensure_history_loaded()

  local backend, target = ensure_terminal_visible()
  if not backend then
    return
  end

  if not state.is_open then
    state.is_open = true
    apply_minimal_ui()
  end

  local buf = get_or_create_input_buf()
  vim.api.nvim_set_current_buf(buf)
  M._setup_buffer_keymaps(buf)

  if config.options.completion.enabled then
    zsh_completion.prime()
  end

  apply_input_window_options(vim.api.nvim_get_current_win())
  render_input_autosuggestion(buf, vim.api.nvim_get_current_win())

  if backend == "tmux" then
    notify("TerminalMate mode opened (" .. target .. ", tmux backend)")
  else
    notify("TerminalMate mode opened (Neovim backend #" .. target.id .. ")")
  end
end

--- Create and show a new terminal instance
function M.new_terminal()
  ensure_history_loaded()

  local backend = config.options.backend == "tmux" and "tmux" or nil
  local target = nil

  if backend == "tmux" then
    target = ensure_managed_tmux_pane()
    if not target then
      return
    end
  else
    target = ensure_nvim_terminal({ new_terminal = true, show = true })
    if not target then
      if config.options.backend == "nvim" then
        return
      end
      local tmux_target = ensure_managed_tmux_pane()
      if not tmux_target then
        return
      end
      backend = "tmux"
      target = tmux_target
    else
      backend = "nvim"
    end
  end

  if backend ~= "nvim" then
    close_nvim_sidebar()
  end

  if not state.is_open then
    state.is_open = true
    apply_minimal_ui()
  end

  local buf = get_or_create_input_buf()
  vim.api.nvim_set_current_buf(buf)
  M._setup_buffer_keymaps(buf)

  if config.options.completion.enabled then
    zsh_completion.prime()
  end

  apply_input_window_options(vim.api.nvim_get_current_win())
  render_input_autosuggestion(buf, vim.api.nvim_get_current_win())

  if backend == "tmux" then
    notify("Terminal pane opened (" .. target .. ", tmux backend)")
  else
    notify("New terminal created (Neovim backend #" .. target.id .. ")")
  end
end

--- Hide the current terminal pane without killing it
function M.hide()
  local active_backend = get_active_backend()
  if active_backend == "tmux" then
    notify("Hide is only supported for managed Neovim terminals.", vim.log.levels.WARN)
    return
  end

  local terminal = get_current_nvim_terminal()
  if not terminal or not terminal.win or not vim.api.nvim_win_is_valid(terminal.win) then
    notify("No terminal pane to hide.", vim.log.levels.WARN)
    return
  end

  nvim_terminal.hide(terminal)
  sync_current_nvim_state(terminal)
  close_nvim_sidebar()
  notify("Terminal pane hidden.")
end

--- Close the terminal pane
function M.close()
  local active_backend = get_active_backend()
  if not active_backend then
    if state.is_open then
      state.is_open = false
      restore_ui()
    end
    close_nvim_sidebar()
    notify("No terminal pane to close.", vim.log.levels.WARN)
    return
  end

  if active_backend == "tmux" then
    tmux.kill_pane(state.terminal_pane_id)
    reset_tmux_state()
  else
    local terminal = get_current_nvim_terminal()
    if terminal then
      nvim_terminal.close(terminal)
      remove_nvim_terminal(terminal.id)
      prune_nvim_terminals()
    end
  end

  state.backend = nil
  state.is_open = false
  close_nvim_sidebar()
  restore_ui()

  notify("Terminal pane closed.")
end

--- Toggle terminal pane visibility (without entering terminal_mate input mode)
function M.toggle()
  local active_backend = get_active_backend()
  if active_backend == "nvim" then
    local terminal = get_current_nvim_terminal()
    if terminal and terminal.win and vim.api.nvim_win_is_valid(terminal.win) then
      M.hide()
      return
    end
    state.is_open = false
    M.open_pane()
    return
  end

  if state.is_open and active_backend then
    M.close()
  else
    state.is_open = false
    M.open_pane()
  end
end

--- Send all commands in the current buffer to terminal, keep current mode
function M.send_buffer()
  local text = get_buffer_text()
  if text == "" then
    return
  end

  if config.options.completion.enabled then
    zsh_completion.dismiss()
  end

  add_to_history(text)
  send_to_terminal(text)
  clear_buffer()
end

--- Send visual selection to terminal
function M.send_visual(visual_type)
  local text = get_visual_text(visual_type)
  if text == "" then
    return
  end

  local backend, target = ensure_send_target()
  if not backend then
    return
  end

  add_to_history(text)
  send_to_target(backend, target, text)

  if config.options.clear_input and vim.api.nvim_get_current_buf() == state.input_buf then
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
  local active_backend = get_active_backend()
  if active_backend == "tmux" then
    tmux.send_special_key(state.terminal_pane_id, "C-l")
  elseif active_backend == "nvim" then
    local terminal = get_current_nvim_terminal()
    if not terminal then
      return
    end
    mark_nvim_terminal_active(terminal)
    local ok, err = nvim_terminal.send_special_key(terminal, "C-l")
    if not ok then
      notify(err or "Failed to clear Neovim terminal.", vim.log.levels.WARN)
    end
  end
end

--- Send interrupt (Ctrl-C) to terminal
function M.interrupt()
  local active_backend = get_active_backend()
  if active_backend == "tmux" then
    tmux.send_special_key(state.terminal_pane_id, "C-c")
  elseif active_backend == "nvim" then
    local terminal = get_current_nvim_terminal()
    if not terminal then
      return
    end
    mark_nvim_terminal_active(terminal)
    local ok, err = nvim_terminal.send_special_key(terminal, "C-c")
    if not ok then
      notify(err or "Failed to interrupt Neovim terminal.", vim.log.levels.WARN)
    end
  end
end

--- Send arbitrary text to terminal (for user commands)
---@param text string
function M.send(text)
  if text and text ~= "" then
    add_to_history(text)
    send_to_terminal(text)
  end
end

--- Switch to a specific managed Neovim terminal instance by id.
---@param terminal_id number|string
function M.switch_terminal(terminal_id)
  if not has_nvim_terminal() then
    if has_tmux_terminal() then
      notify("Terminal switching commands are only supported for managed Neovim terminals.", vim.log.levels.WARN)
    else
      notify("No managed Neovim terminals available.", vim.log.levels.WARN)
    end
    return
  end

  local target_id = tonumber(terminal_id)
  if not target_id then
    notify("Expected a numeric terminal id.", vim.log.levels.ERROR)
    return
  end

  switch_nvim_terminal(target_id)
end

--- Switch to the next managed Neovim terminal instance.
function M.next_terminal()
  if not has_nvim_terminal() then
    if has_tmux_terminal() then
      notify("Terminal switching commands are only supported for managed Neovim terminals.", vim.log.levels.WARN)
    else
      notify("No managed Neovim terminals available.", vim.log.levels.WARN)
    end
    return
  end

  cycle_nvim_terminal(1)
end

--- Switch to the previous managed Neovim terminal instance.
function M.prev_terminal()
  if not has_nvim_terminal() then
    if has_tmux_terminal() then
      notify("Terminal switching commands are only supported for managed Neovim terminals.", vim.log.levels.WARN)
    else
      notify("No managed Neovim terminals available.", vim.log.levels.WARN)
    end
    return
  end

  cycle_nvim_terminal(-1)
end

--- Navigate history: go to previous (older) command
function M.history_prev()
  if #state.history == 0 then
    notify("No history available.", vim.log.levels.INFO)
    return
  end

  if state.history_index == 0 then
    state._saved_input = get_raw_buffer_text(0)
  end

  state.history_index = math.min(state.history_index + 1, #state.history)
  local cmd = state.history[#state.history - state.history_index + 1]
  if cmd then
    local lines = set_buffer_text(0, cmd)
    vim.api.nvim_win_set_cursor(0, { #lines, #lines[#lines] })
    render_input_autosuggestion(0, vim.api.nvim_get_current_win())
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
    local lines = set_buffer_text(0, saved)
    vim.api.nvim_win_set_cursor(0, { #lines, #lines[#lines] })
    render_input_autosuggestion(0, vim.api.nvim_get_current_win())
    return
  end

  local cmd = state.history[#state.history - state.history_index + 1]
  if cmd then
    local lines = set_buffer_text(0, cmd)
    vim.api.nvim_win_set_cursor(0, { #lines, #lines[#lines] })
    render_input_autosuggestion(0, vim.api.nvim_get_current_win())
  end
end

--- Accept the current autosuggestion into the input buffer.
---@return boolean
function M.accept_suggestion()
  local buf = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()

  if buf ~= state.input_buf or not vim.api.nvim_win_is_valid(win) then
    return false
  end

  local candidate = get_autosuggestion_candidate(buf, win)
  if not candidate then
    return false
  end

  local current_text = get_raw_buffer_text(buf)
  local mode = vim.api.nvim_get_mode().mode
  local use_paste = (mode:sub(1, 1) == "i" or mode:sub(1, 1) == "R")
    and current_text ~= candidate.text
    and candidate.text:sub(1, #current_text) == current_text

  local lines = nil
  if use_paste then
    clear_input_autosuggestion(buf)
    local ok_paste, pasted = pcall(vim.api.nvim_paste, candidate.remainder, false, -1)
    if ok_paste and pasted then
      lines = split_buffer_text(candidate.text)
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_win_is_valid(win) then
          return
        end
        if vim.api.nvim_win_get_buf(win) ~= buf then
          return
        end
        render_input_autosuggestion(buf, win)
      end)
    end
  end

  if not lines then
    lines = set_buffer_text(buf, candidate.text)
    move_cursor_to_buffer_end(win, buf)
  end

  state.history_index = 0
  state.accepted_suggestion = {
    buf = buf,
    text = candidate.text,
  }
  state.autosuggestion = nil
  if not use_paste then
    render_input_autosuggestion(buf, win)
  end

  return #lines > 0
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
--- Expands the tmux nvim pane while searching when the tmux backend is active.
function M.history_search()
  if #state.history == 0 then
    notify("No history available.", vim.log.levels.INFO)
    return
  end

  local caller_buf = state.input_buf
  expand_nvim_pane_for_search()

  local all_items = {}
  for i = #state.history, 1, -1 do
    table.insert(all_items, state.history[i])
  end

  vim.defer_fn(function()
    local ui = vim.api.nvim_list_uis()[1] or { width = 80, height = 24 }
    local float_width = math.min(math.floor(ui.width * 0.9), 140)
    local float_height = math.max(math.floor(ui.height * 0.7), 10)
    local row = math.max(math.floor((ui.height - float_height) / 2) - 1, 0)
    local col = math.floor((ui.width - float_width) / 2)

    local results_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[results_buf].bufhidden = "wipe"

    local input_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[input_buf].bufhidden = "wipe"
    vim.bo[input_buf].buftype = "nofile"

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

      if picker.selected < 1 then
        picker.selected = 1
      end
      if picker.selected > #picker.filtered then
        picker.selected = #picker.filtered
      end

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
      if closed then
        return
      end
      closed = true
      if vim.api.nvim_win_is_valid(input_win) then
        vim.api.nvim_win_close(input_win, true)
      end
      if vim.api.nvim_win_is_valid(results_win) then
        vim.api.nvim_win_close(results_win, true)
      end
      restore_nvim_pane_size()
    end

    local function confirm()
      local choice = picker.filtered[picker.selected]
      close_picker()
      if choice and caller_buf and vim.api.nvim_buf_is_valid(caller_buf) then
        set_buffer_text(caller_buf, choice)
        for _, win in ipairs(vim.api.nvim_list_wins()) do
          if vim.api.nvim_win_get_buf(win) == caller_buf then
            vim.api.nvim_set_current_win(win)
            move_cursor_to_buffer_end(win, caller_buf)
            render_input_autosuggestion(caller_buf, win)
            break
          end
        end
        state.history_index = 0
      end
    end

    update_filter()
    vim.cmd("startinsert")

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
  end, 50)
end

function M.cheatsheet_search()
  M.open()
  local buf = state.input_buf
  local win = vim.api.nvim_get_current_win()
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  cheatsheets.search(buf, win)
end

function M.cheatsheet_edit()
  cheatsheets.edit_file()
end

function M.cheatsheet_new()
  cheatsheets.new_entry()
end

--- Get current state (for statusline integration etc.)
---@return table
function M.get_state()
  local current_terminal = get_current_nvim_terminal()
  return {
    is_open = state.is_open,
    backend = get_active_backend(),
    terminal_pane_id = state.terminal_pane_id,
    terminal_buf = state.terminal_buf,
    terminal_win = state.terminal_win,
    current_terminal_id = current_terminal and current_terminal.id or nil,
    nvim_terminal_count = #state.nvim_terminals,
    nvim_pane_id = state.nvim_pane_id,
    history_count = #state.history,
  }
end

---@return table
function M.get_completion_debug_state()
  local context = collect_completion_context()
  local completion_state = zsh_completion.get_debug_state()
  local visible_terminal = get_visible_nvim_terminal()
  local current_terminal = get_current_nvim_terminal()
  return {
    active_backend = get_active_backend(),
    state_backend = state.backend,
    input_buf = state.input_buf,
    visible_nvim_terminal_id = visible_terminal and visible_terminal.id or nil,
    current_nvim_terminal_id = current_terminal and current_terminal.id or nil,
    managed_tmux_pane = state.terminal_pane_id,
    nvim_pane_id = state.nvim_pane_id,
    completion_context = context,
    visible_nvim_terminal = nvim_terminal.get_debug_state(visible_terminal),
    current_nvim_terminal = nvim_terminal.get_debug_state(current_terminal),
    completion_session = completion_state,
  }
end

function M.debug_completion_context()
  notify(vim.inspect(M.get_completion_debug_state()))
end

--- Set up buffer-local keymaps for the input buffer
---@param buf number
function M._setup_buffer_keymaps(buf)
  local opts = { buffer = buf, noremap = true, silent = true }
  local keymap = config.options.keymap
  local function with_input_context(callback)
    return function()
      local win = vim.api.nvim_get_current_win()
      local ctx = current_input_line_context(buf, win)
      if not ctx then
        return
      end

      callback(win, ctx)
    end
  end

  vim.keymap.set("n", keymap.send_line, function()
    M.send_buffer()
  end, vim.tbl_extend("force", opts, { desc = "TerminalMate: Send all buffer commands" }))

  vim.keymap.set("v", keymap.send_visual, function()
    local visual_type = vim.fn.visualmode()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
    vim.schedule(function()
      M.send_visual(visual_type)
    end)
  end, vim.tbl_extend("force", opts, { desc = "TerminalMate: Send visual selection" }))

  vim.keymap.set("i", keymap.send_line, function()
    if config.options.completion.enabled and vim.fn.pumvisible() == 1 then
      local target_buf = buf
      zsh_completion.dismiss()
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(target_buf) or vim.api.nvim_get_current_buf() ~= target_buf then
          return
        end
        M.send_buffer()
      end)
      return
    end

    M.send_buffer()
  end, vim.tbl_extend("force", opts, { desc = "TerminalMate: Send all buffer commands (insert mode)" }))

  vim.keymap.set("i", "<C-a>", with_input_context(function(win, ctx)
    vim.api.nvim_win_set_cursor(win, { ctx.line_nr, 0 })
  end), vim.tbl_extend("force", opts, { desc = "TerminalMate: Move to line start" }))

  vim.keymap.set("i", "<C-e>", with_input_context(function(win, ctx)
    vim.api.nvim_win_set_cursor(win, { ctx.line_nr, #ctx.line })
  end), vim.tbl_extend("force", opts, { desc = "TerminalMate: Move to line end" }))

  vim.keymap.set("i", "<C-b>", function()
    feed_insert_keys("<Left>")
  end, vim.tbl_extend("force", opts, { desc = "TerminalMate: Move left" }))

  vim.keymap.set("i", "<C-f>", function()
    feed_insert_keys("<Right>")
  end, vim.tbl_extend("force", opts, { desc = "TerminalMate: Move right" }))

  vim.keymap.set("i", "<M-b>", with_input_context(function(win, ctx)
    vim.api.nvim_win_set_cursor(win, { ctx.line_nr, previous_shell_word_col(ctx.line, ctx.col) })
  end), vim.tbl_extend("force", opts, { desc = "TerminalMate: Backward word" }))

  vim.keymap.set("i", "<M-f>", with_input_context(function(win, ctx)
    vim.api.nvim_win_set_cursor(win, { ctx.line_nr, next_shell_word_col(ctx.line, ctx.col) })
  end), vim.tbl_extend("force", opts, { desc = "TerminalMate: Forward word" }))

  vim.keymap.set("i", "<C-u>", with_input_context(function(win, ctx)
    if ctx.col == 0 then
      return
    end

    replace_input_range(buf, win, 0, ctx.col, "")
  end), vim.tbl_extend("force", opts, { desc = "TerminalMate: Delete to line start" }))

  vim.keymap.set("i", "<C-k>", with_input_context(function(win, ctx)
    if ctx.col >= #ctx.line then
      return
    end

    replace_input_range(buf, win, ctx.col, #ctx.line, "")
  end), vim.tbl_extend("force", opts, { desc = "TerminalMate: Delete to line end" }))

  vim.keymap.set("i", "<C-w>", with_input_context(function(win, ctx)
    local start_col = previous_shell_word_col(ctx.line, ctx.col)
    if start_col == ctx.col then
      return
    end

    replace_input_range(buf, win, start_col, ctx.col, "")
  end), vim.tbl_extend("force", opts, { desc = "TerminalMate: Delete previous word" }))

  vim.keymap.set("i", "<C-d>", with_input_context(function(win, ctx)
    if ctx.col >= #ctx.line then
      return
    end

    replace_input_range(buf, win, ctx.col, ctx.col + 1, "")
  end), vim.tbl_extend("force", opts, { desc = "TerminalMate: Delete character" }))

  vim.keymap.set("n", keymap.new_terminal, function()
    M.new_terminal()
  end, vim.tbl_extend("force", opts, { desc = "TerminalMate: Create a new terminal instance" }))

  vim.keymap.set("n", keymap.hide, function()
    M.hide()
  end, vim.tbl_extend("force", opts, { desc = "TerminalMate: Hide current terminal pane" }))

  vim.keymap.set("n", keymap.history_prev, function()
    M.history_prev()
  end, vim.tbl_extend("force", opts, { desc = "TerminalMate: Previous history" }))

  vim.keymap.set("n", keymap.history_next, function()
    M.history_next()
  end, vim.tbl_extend("force", opts, { desc = "TerminalMate: Next history" }))

  vim.keymap.set("i", keymap.history_prev, function()
    if config.options.completion.enabled and zsh_completion.select_prev() then
      return
    end

    vim.cmd("stopinsert")
    M.history_prev()
    vim.cmd("startinsert!")
  end, vim.tbl_extend("force", opts, { desc = "TerminalMate: Previous history (insert)" }))

  vim.keymap.set("i", keymap.history_next, function()
    if config.options.completion.enabled and zsh_completion.select_next() then
      return
    end

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

  vim.keymap.set("n", keymap.cheatsheet_search, function()
    M.cheatsheet_search()
  end, vim.tbl_extend("force", opts, { desc = "TerminalMate: Search cheatsheets" }))

  vim.keymap.set("i", keymap.cheatsheet_search, function()
    vim.cmd("stopinsert")
    M.cheatsheet_search()
  end, vim.tbl_extend("force", opts, { desc = "TerminalMate: Search cheatsheets (insert)" }))

  if keymap.accept_suggestion and keymap.accept_suggestion ~= "" then
    vim.keymap.set("i", keymap.accept_suggestion, function()
      if M.accept_suggestion() then
        return
      end

      feed_insert_keys(keymap.accept_suggestion)
    end, vim.tbl_extend("force", opts, { desc = "TerminalMate: Accept autosuggestion" }))
  end

  if config.options.completion.enabled then
    vim.keymap.set("i", keymap.completion_trigger, function()
      if cheatsheets.jump_next(vim.api.nvim_get_current_win()) then
        return
      end
      zsh_completion.handle_trigger_key(buf, vim.api.nvim_get_current_win())
    end, vim.tbl_extend("force", opts, { desc = "TerminalMate: Trigger shell completion" }))

    vim.keymap.set("i", keymap.completion_prev, function()
      if cheatsheets.jump_prev(vim.api.nvim_get_current_win()) then
        return
      end
      zsh_completion.select_prev()
    end, vim.tbl_extend("force", opts, { desc = "TerminalMate: Previous shell completion" }))

    vim.keymap.set("i", "<CR>", function()
      if cheatsheets.confirm(buf, vim.api.nvim_get_current_win()) then
        return
      end

      if zsh_completion.confirm() then
        return
      end

      feed_insert_keys("<CR>")
    end, vim.tbl_extend("force", opts, { desc = "TerminalMate: Confirm shell completion" }))
  end

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

  vim.api.nvim_create_autocmd({ "BufEnter", "TermEnter" }, {
    group = group,
    callback = function(args)
      for _, terminal in ipairs(state.nvim_terminals) do
        if terminal.buf == args.buf then
          mark_nvim_terminal_active(terminal)
          break
        end
      end
    end,
  })

  if vim.fn.has("nvim-0.10") == 1 then
    vim.api.nvim_create_autocmd("TermRequest", {
      group = group,
      callback = function(args)
        local terminal = find_nvim_terminal_by_buf(args.buf)
        if not terminal then
          return
        end

        nvim_terminal.handle_term_request(terminal, args.data)
      end,
    })
  end

  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(args)
      local closed_win = tonumber(args.match)
      if closed_win and state.sidebar_win == closed_win then
        state.sidebar_win = nil
        state.sidebar_terminal_ids = {}
        return
      end

      if state.sidebar_win or #state.nvim_terminals > 0 then
        vim.schedule(function()
          if sync_nvim_sidebar then
            sync_nvim_sidebar()
          end
        end)
      end
    end,
  })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      zsh_completion.stop()
    end,
  })

  if config.options.close_on_exit then
    vim.api.nvim_create_autocmd("VimLeavePre", {
      group = group,
      callback = function()
        if has_tmux_terminal() then
          pcall(function()
            tmux.kill_pane(state.terminal_pane_id)
          end)
        end
      end,
    })
  end
end

local function setup_terminal_switch_keymaps(gopts)
  local keymap = config.options.keymap

  if keymap.prev_terminal and keymap.prev_terminal ~= "" then
    vim.keymap.set("n", keymap.prev_terminal, function()
      M.prev_terminal()
    end, vim.tbl_extend("force", gopts, { desc = "TerminalMate: Previous terminal" }))
  end

  if keymap.next_terminal and keymap.next_terminal ~= "" then
    vim.keymap.set("n", keymap.next_terminal, function()
      M.next_terminal()
    end, vim.tbl_extend("force", gopts, { desc = "TerminalMate: Next terminal" }))
  end

  if type(keymap.switch_prefix) ~= "string" or keymap.switch_prefix == "" then
    return
  end

  for terminal_id = 1, 9 do
    local id = terminal_id
    vim.keymap.set("n", keymap.switch_prefix .. id, function()
      M.switch_terminal(id)
    end, vim.tbl_extend("force", gopts, {
      desc = string.format("TerminalMate: Switch to terminal #%d", id),
    }))
  end
end

--- Plugin setup
---@param opts table|nil
function M.setup(opts)
  config.setup(opts)
  zsh_completion.setup(vim.tbl_extend("force", {}, config.options.completion, {
    cwd_resolver = resolve_completion_cwd,
  }))
  cheatsheets.setup(vim.tbl_extend("force", {}, config.options.cheatsheets, {
    cwd_resolver = resolve_completion_cwd,
    shell_resolver = resolve_cheatsheet_shell,
    notify = notify,
  }))
  setup_sidebar_highlights()
  setup_autocmds()

  if config.options.backend == "tmux" and not tmux.is_tmux() then
    notify(
      "Configured tmux backend is unavailable outside a tmux session.",
      vim.log.levels.WARN
    )
  elseif config.options.backend ~= "tmux" and not nvim_terminal.is_available() and not tmux.is_tmux() then
    notify(
      "No supported terminal backend is available. Install a Neovim build with :terminal support or run inside tmux.",
      vim.log.levels.WARN
    )
  end

  if config.options.shell_integration.enabled and vim.fn.has("nvim-0.10") ~= 1 then
    notify(
      "shell_integration requires Neovim 0.10+ and only applies to TerminalMate-managed Neovim terminals.",
      vim.log.levels.WARN
    )
  end

  local keymap = config.options.keymap
  local gopts = { noremap = true, silent = true }

  vim.keymap.set("n", keymap.open, function()
    M.open_pane()
  end, vim.tbl_extend("force", gopts, { desc = "TerminalMate: Open terminal pane" }))

  vim.keymap.set("n", keymap.mate_mode or "<leader>tm", function()
    M.open()
  end, vim.tbl_extend("force", gopts, { desc = "TerminalMate: Open terminal_mate input mode" }))

  vim.keymap.set("n", keymap.new_terminal, function()
    M.new_terminal()
  end, vim.tbl_extend("force", gopts, { desc = "TerminalMate: Create a new terminal instance" }))

  vim.keymap.set("n", keymap.hide, function()
    M.hide()
  end, vim.tbl_extend("force", gopts, { desc = "TerminalMate: Hide current terminal pane" }))

  vim.keymap.set("n", keymap.close, function()
    M.close()
  end, vim.tbl_extend("force", gopts, { desc = "TerminalMate: Close terminal pane" }))

  vim.keymap.set("n", keymap.toggle, function()
    M.toggle()
  end, vim.tbl_extend("force", gopts, { desc = "TerminalMate: Toggle terminal pane" }))

  setup_terminal_switch_keymaps(gopts)

  vim.keymap.set("x", keymap.send_visual, function()
    local visual_type = vim.fn.visualmode()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
    vim.schedule(function()
      M.send_visual(visual_type)
    end)
  end, vim.tbl_extend("force", gopts, { desc = "TerminalMate: Send visual selection to terminal" }))

  vim.keymap.set("n", keymap.cheatsheet_search, function()
    M.cheatsheet_search()
  end, vim.tbl_extend("force", gopts, { desc = "TerminalMate: Search cheatsheets" }))

  vim.keymap.set("n", keymap.cheatsheet_edit, function()
    M.cheatsheet_edit()
  end, vim.tbl_extend("force", gopts, { desc = "TerminalMate: Edit cheatsheet file" }))

  vim.keymap.set("n", keymap.cheatsheet_new, function()
    M.cheatsheet_new()
  end, vim.tbl_extend("force", gopts, { desc = "TerminalMate: Create cheatsheet entry" }))
end

return M
