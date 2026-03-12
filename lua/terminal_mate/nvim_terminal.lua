--- Neovim built-in terminal backend for terminal_mate.nvim
local M = {}

---@param job_id number|nil
---@return boolean
local function job_is_running(job_id)
  if type(job_id) ~= "number" or job_id <= 0 then
    return false
  end

  local ok, result = pcall(vim.fn.jobwait, { job_id }, 0)
  return ok and result[1] == -1
end

---@return boolean
function M.is_available()
  return vim.fn.exists("*termopen") == 1
end

---@param state table
---@return boolean
function M.is_alive(state)
  return state.terminal_buf ~= nil
    and vim.api.nvim_buf_is_valid(state.terminal_buf)
    and job_is_running(state.terminal_job_id)
end

---@param state table
function M.reset(state)
  state.terminal_win = nil
  state.terminal_buf = nil
  state.terminal_job_id = nil
end

local function normalize_shell_command(candidate)
  if type(candidate) ~= "string" then
    return nil
  end

  local cmd = vim.trim(candidate)
  if cmd == "" then
    return nil
  end

  -- Accept quoted shell paths like '"/bin/zsh" -l'.
  cmd = cmd:gsub('^"([^"]+)"', "%1")
  cmd = cmd:gsub("^'([^']+)'", "%1")

  return cmd
end

local function resolve_shell(opts)
  local candidates = {
    opts.shell,
    vim.env.SHELL,
    vim.o.shell,
    "/bin/zsh",
    "/bin/bash",
    "/bin/sh",
    "sh",
  }

  local first_non_empty = nil

  for _, candidate in ipairs(candidates) do
    local cmd = normalize_shell_command(candidate)
    if cmd then
      first_non_empty = first_non_empty or cmd
      local bin = cmd:match("^([^%s]+)")
      if bin and vim.fn.executable(bin) == 1 then
        return cmd
      end
    end
  end

  -- If detection is inconclusive, let termopen try the first non-empty shell command.
  return first_non_empty
end

local function pick_split_anchor_win()
  local current = vim.api.nvim_get_current_win()
  local current_cfg = vim.api.nvim_win_get_config(current)
  if current_cfg.relative == "" then
    return current
  end

  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative == "" and vim.api.nvim_win_is_valid(win) then
      return win
    end
  end

  return current
end

---@param state table
---@param opts table
---@return boolean
---@return string|nil
function M.open(state, opts)
  if not M.is_available() then
    return false, "Neovim terminal backend is unavailable."
  end

  if M.is_alive(state) then
    return true, nil
  end

  local editor_win = pick_split_anchor_win()
  if vim.api.nvim_win_is_valid(editor_win) then
    vim.api.nvim_set_current_win(editor_win)
  end

  local editor_height = vim.api.nvim_win_get_height(editor_win)
  local terminal_height = math.max(3, math.floor(editor_height * (opts.split_percent / 100)))

  local ok = pcall(vim.cmd, "botright " .. terminal_height .. "split")
  if not ok then
    return false, "Failed to open a Neovim terminal split."
  end

  local terminal_win = vim.api.nvim_get_current_win()
  vim.cmd("enew")

  local terminal_buf = vim.api.nvim_get_current_buf()
  vim.bo[terminal_buf].bufhidden = "hide"
  vim.bo[terminal_buf].swapfile = false

  local shell = resolve_shell(opts)
  if not shell then
    pcall(vim.api.nvim_win_close, terminal_win, true)
    pcall(vim.api.nvim_buf_delete, terminal_buf, { force = true })
    return false, "Failed to resolve a valid shell executable for Neovim terminal."
  end

  local job_id = vim.fn.termopen(shell)
  if job_id <= 0 then
    pcall(vim.api.nvim_win_close, terminal_win, true)
    pcall(vim.api.nvim_buf_delete, terminal_buf, { force = true })
    return false, "Failed to start the Neovim terminal shell: " .. shell
  end

  pcall(vim.api.nvim_buf_set_name, terminal_buf, "[TerminalMateTerminal]")
  vim.wo[terminal_win].number = false
  vim.wo[terminal_win].relativenumber = false
  vim.wo[terminal_win].signcolumn = "no"

  state.terminal_win = terminal_win
  state.terminal_buf = terminal_buf
  state.terminal_job_id = job_id

  if vim.api.nvim_win_is_valid(editor_win) then
    vim.api.nvim_set_current_win(editor_win)
  end

  return true, nil
end

---@param state table
function M.close(state)
  local terminal_win = state.terminal_win
  local terminal_buf = state.terminal_buf

  M.reset(state)

  if terminal_win and vim.api.nvim_win_is_valid(terminal_win) then
    pcall(vim.api.nvim_win_close, terminal_win, true)
  end
  if terminal_buf and vim.api.nvim_buf_is_valid(terminal_buf) then
    pcall(vim.api.nvim_buf_delete, terminal_buf, { force = true })
  end
end

---@param state table
---@param text string
---@param press_enter boolean
---@return boolean
---@return string|nil
function M.send_text(state, text, press_enter)
  if not M.is_alive(state) then
    return false, "Neovim terminal is not running."
  end

  local ok_send, err_send = pcall(vim.api.nvim_chan_send, state.terminal_job_id, text)
  if not ok_send then
    return false, "Failed to send to Neovim terminal: " .. tostring(err_send)
  end

  if press_enter then
    local ok_enter, err_enter = pcall(vim.api.nvim_chan_send, state.terminal_job_id, "\r")
    if not ok_enter then
      return false, "Failed to send Enter to Neovim terminal: " .. tostring(err_enter)
    end
  end

  if state.terminal_win and vim.api.nvim_win_is_valid(state.terminal_win) then
    local line_count = vim.api.nvim_buf_line_count(state.terminal_buf)
    pcall(vim.api.nvim_win_set_cursor, state.terminal_win, { math.max(line_count, 1), 0 })
  end

  return true, nil
end

---@param state table
---@param key string
---@return boolean
---@return string|nil
function M.send_special_key(state, key)
  if not M.is_alive(state) then
    return false, "Neovim terminal is not running."
  end

  local code = nil
  if key == "C-c" then
    code = "\003"
  elseif key == "C-l" then
    code = "\012"
  end

  if not code then
    return false, "Unsupported Neovim terminal key: " .. key
  end

  local ok_send, err_send = pcall(vim.api.nvim_chan_send, state.terminal_job_id, code)
  if not ok_send then
    return false, "Failed to send special key to Neovim terminal: " .. tostring(err_send)
  end

  return true, nil
end

return M
