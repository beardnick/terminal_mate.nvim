--- Neovim built-in terminal backend for terminal_mate.nvim
local M = {}

local FALLBACK_SHELL_CANDIDATES = {
  { source = "fallback:/bin/zsh", raw = "/bin/zsh" },
  { source = "fallback:/bin/bash", raw = "/bin/bash" },
  { source = "fallback:/bin/sh", raw = "/bin/sh" },
  { source = "fallback:sh", raw = "sh" },
}

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
  state.terminal_shell_command = nil
  state.terminal_shell_source = nil
  state.terminal_shell_diagnostics = nil
end

---@param value any
---@return string
local function format_value(value)
  if value == nil then
    return "nil"
  end

  if type(value) == "string" then
    return string.format("%q", value)
  end

  return string.format("<%s:%s>", type(value), tostring(value))
end

---@param candidate any
---@return string|nil
local function normalize_shell_command(candidate)
  if type(candidate) ~= "string" then
    return nil
  end

  local ok_expand, expanded = pcall(vim.fn.expandcmd, candidate)
  local cmd = ok_expand and expanded or candidate
  cmd = vim.trim(cmd)
  if cmd == "" then
    return nil
  end

  return cmd
end

---@param command string
---@return string[]|nil
---@return string|nil
local function parse_shell_argv(command)
  local argv = {}
  local current = {}
  local quote = nil
  local i = 1

  local function flush_current()
    if #current == 0 then
      return
    end

    table.insert(argv, table.concat(current))
    current = {}
  end

  while i <= #command do
    local ch = command:sub(i, i)

    if quote == "'" then
      if ch == "'" then
        quote = nil
      else
        table.insert(current, ch)
      end
    elseif quote == '"' then
      if ch == '"' then
        quote = nil
      elseif ch == "\\" and i < #command then
        i = i + 1
        table.insert(current, command:sub(i, i))
      else
        table.insert(current, ch)
      end
    else
      if ch:match("%s") then
        flush_current()
      elseif ch == "'" or ch == '"' then
        quote = ch
      elseif ch == "\\" and i < #command then
        i = i + 1
        table.insert(current, command:sub(i, i))
      else
        table.insert(current, ch)
      end
    end

    i = i + 1
  end

  if quote ~= nil then
    return nil, "unterminated " .. quote .. " quote"
  end

  flush_current()

  if #argv == 0 then
    return nil, "empty shell command"
  end

  return argv, nil
end

---@param opts table|nil
---@return table[]
---@return string[]
local function resolve_shell_candidates(opts)
  local raw_candidates = {
    { source = "opts.shell", raw = opts and opts.shell or nil },
    { source = "$SHELL", raw = vim.env.SHELL },
    { source = "vim.o.shell", raw = vim.o.shell },
  }
  vim.list_extend(raw_candidates, FALLBACK_SHELL_CANDIDATES)

  local candidates = {}
  local diagnostics = {}
  local seen = {}

  for _, entry in ipairs(raw_candidates) do
    local command = normalize_shell_command(entry.raw)
    local prefix = entry.source .. "=" .. format_value(entry.raw)

    if not command then
      table.insert(diagnostics, prefix .. " -> empty")
    else
      local argv, parse_err = parse_shell_argv(command)
      if not argv then
        table.insert(diagnostics, prefix .. " -> parse error (" .. parse_err .. ")")
      else
        local executable = argv[1]
        local resolved = vim.fn.exepath(executable)
        local key = table.concat(argv, "\n")

        if resolved == "" and vim.fn.executable(executable) == 1 then
          resolved = executable
        end

        if resolved == "" then
          table.insert(diagnostics, prefix .. " -> not executable (" .. executable .. ")")
        elseif seen[key] then
          table.insert(diagnostics, prefix .. " -> duplicate of " .. string.format("%q", table.concat(argv, " ")))
        else
          seen[key] = true
          table.insert(candidates, {
            source = entry.source,
            command = command,
            argv = argv,
            executable = executable,
            resolved = resolved,
          })
          table.insert(
            diagnostics,
            prefix .. " -> usable (" .. string.format("%q", table.concat(argv, " ")) .. " -> " .. resolved .. ")"
          )
        end
      end
    end
  end

  return candidates, diagnostics
end

---@param diagnostics string[]
---@param attempts string[]|nil
---@return string
local function format_failure_details(diagnostics, attempts)
  local parts = {}

  if attempts and #attempts > 0 then
    table.insert(parts, "attempts: " .. table.concat(attempts, "; "))
  end
  if #diagnostics > 0 then
    table.insert(parts, "candidates: " .. table.concat(diagnostics, "; "))
  end

  return table.concat(parts, " | ")
end

---@param state table
---@param message string
---@return string
local function remember_error(state, message)
  state.terminal_last_error = message
  return message
end

---@param terminal_win number
---@return number
local function prepare_terminal_buffer(terminal_win)
  vim.api.nvim_set_current_win(terminal_win)
  vim.cmd("enew")

  local terminal_buf = vim.api.nvim_get_current_buf()
  vim.bo[terminal_buf].bufhidden = "hide"
  vim.bo[terminal_buf].swapfile = false
  return terminal_buf
end

---@param terminal_win number
---@param terminal_buf number|nil
local function cleanup_terminal_window(terminal_win, terminal_buf)
  if terminal_buf and vim.api.nvim_buf_is_valid(terminal_buf) then
    pcall(vim.api.nvim_buf_delete, terminal_buf, { force = true })
  end
  if vim.api.nvim_win_is_valid(terminal_win) then
    pcall(vim.api.nvim_win_close, terminal_win, true)
  end
end

---@param job_id number|nil
---@return string
local function describe_job_status(job_id)
  if type(job_id) ~= "number" or job_id <= 0 then
    return "invalid job id"
  end

  local ok_wait, result = pcall(vim.fn.jobwait, { job_id }, 0)
  if not ok_wait then
    return "jobwait failed: " .. tostring(result)
  end

  local status = result[1]
  if status == -1 then
    return "running"
  end

  return "exit code " .. tostring(status)
end

---@param state table
---@return string
local function build_not_running_error(state)
  local details = {}

  if state.terminal_job_id ~= nil then
    table.insert(details, "job=" .. tostring(state.terminal_job_id) .. " (" .. describe_job_status(state.terminal_job_id) .. ")")
  end
  if state.terminal_shell_command then
    table.insert(
      details,
      "last shell=" .. string.format("%q", state.terminal_shell_command) .. " from " .. tostring(state.terminal_shell_source)
    )
  end
  if state.terminal_shell_diagnostics then
    table.insert(details, "candidates=" .. state.terminal_shell_diagnostics)
  end
  if state.terminal_last_error then
    table.insert(details, "last error=" .. state.terminal_last_error)
  end

  if #details == 0 then
    return "Neovim terminal is not running."
  end

  return "Neovim terminal is not running (" .. table.concat(details, "; ") .. ")"
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
    return false, remember_error(state, "Neovim terminal backend is unavailable.")
  end

  if M.is_alive(state) then
    state.terminal_last_error = nil
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
    return false, remember_error(state, "Failed to open a Neovim terminal split.")
  end

  local terminal_win = vim.api.nvim_get_current_win()
  local terminal_buf = prepare_terminal_buffer(terminal_win)

  local shell_candidates, shell_diagnostics = resolve_shell_candidates(opts)
  if #shell_candidates == 0 then
    cleanup_terminal_window(terminal_win, terminal_buf)
    return false, remember_error(
      state,
      "Failed to resolve a usable shell for Neovim terminal (" .. format_failure_details(shell_diagnostics) .. ")"
    )
  end

  local attempts = {}
  local active_candidate = nil
  local job_id = nil

  for index, candidate in ipairs(shell_candidates) do
    local ok_term, job_result = pcall(vim.fn.termopen, candidate.argv)
    if not ok_term then
      table.insert(attempts, string.format("%q -> exception (%s)", candidate.command, tostring(job_result)))
    elseif type(job_result) ~= "number" or job_result <= 0 then
      table.insert(attempts, string.format("%q -> termopen returned %s", candidate.command, tostring(job_result)))
    elseif not job_is_running(job_result) then
      table.insert(
        attempts,
        string.format("%q -> started then exited immediately (%s)", candidate.command, describe_job_status(job_result))
      )
    else
      active_candidate = candidate
      job_id = job_result
      break
    end

    if index < #shell_candidates then
      if vim.api.nvim_buf_is_valid(terminal_buf) then
        pcall(vim.api.nvim_buf_delete, terminal_buf, { force = true })
      end
      terminal_buf = prepare_terminal_buffer(terminal_win)
    end
  end

  if not active_candidate or not job_id then
    cleanup_terminal_window(terminal_win, terminal_buf)
    return false, remember_error(
      state,
      "Failed to start a Neovim terminal shell (" .. format_failure_details(shell_diagnostics, attempts) .. ")"
    )
  end

  pcall(vim.api.nvim_buf_set_name, terminal_buf, "[TerminalMateTerminal]")
  vim.wo[terminal_win].number = false
  vim.wo[terminal_win].relativenumber = false
  vim.wo[terminal_win].signcolumn = "no"

  state.terminal_win = terminal_win
  state.terminal_buf = terminal_buf
  state.terminal_job_id = job_id
  state.terminal_shell_command = active_candidate.command
  state.terminal_shell_source = active_candidate.source
  state.terminal_shell_diagnostics = table.concat(shell_diagnostics, "; ")
  state.terminal_last_error = nil

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
    return false, build_not_running_error(state)
  end

  local ok_send, err_send = pcall(vim.api.nvim_chan_send, state.terminal_job_id, text)
  if not ok_send then
    return false, remember_error(state, "Failed to send to Neovim terminal: " .. tostring(err_send))
  end

  if press_enter then
    local ok_enter, err_enter = pcall(vim.api.nvim_chan_send, state.terminal_job_id, "\r")
    if not ok_enter then
      return false, remember_error(state, "Failed to send Enter to Neovim terminal: " .. tostring(err_enter))
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
    return false, build_not_running_error(state)
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
    return false, remember_error(state, "Failed to send special key to Neovim terminal: " .. tostring(err_send))
  end

  return true, nil
end

return M
