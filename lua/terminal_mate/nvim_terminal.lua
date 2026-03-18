--- Neovim built-in terminal backend for terminal_mate.nvim
local M = {}
local uv = vim.uv or vim.loop

local FALLBACK_SHELL_CANDIDATES = {
  { source = "fallback:/bin/zsh", raw = "/bin/zsh" },
  { source = "fallback:/bin/bash", raw = "/bin/bash" },
  { source = "fallback:/bin/sh", raw = "/bin/sh" },
  { source = "fallback:sh", raw = "sh" },
}

local function join_paths(...)
  return table.concat({ ... }, "/")
end

local function file_basename(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end

  return path:match("([^/\\]+)$") or path
end

local function runtime_file(...)
  local source = debug.getinfo(1, "S").source
  if type(source) ~= "string" then
    return nil
  end

  local current = source:sub(1, 1) == "@" and source:sub(2) or source
  local lua_dir = vim.fn.fnamemodify(current, ":h")
  local root = vim.fn.fnamemodify(lua_dir, ":h:h:h")
  return join_paths(root, ...)
end

local function termrequest_is_available()
  return vim.fn.has("nvim-0.10") == 1
end

local function build_zsh_wrapper_lines(filename, include_integration, restore_real_zdotdir)
  local lines = {
    [[emulate -L zsh]],
    [[typeset -gx _TMATE_WRAPPER_ZDOTDIR="${ZDOTDIR:-}"]],
    [[typeset -gx _TMATE_REAL_ZDOTDIR="${TERMINAL_MATE_ORIG_ZDOTDIR:-$HOME}"]],
    string.format('if [[ -r "${_TMATE_REAL_ZDOTDIR}/%s" ]]; then', filename),
    [[  export ZDOTDIR="${_TMATE_REAL_ZDOTDIR}"]],
    string.format('  source "${ZDOTDIR}/%s"', filename),
    [[fi]],
  }

  if include_integration then
    table.insert(lines, 'if [[ -n "${TERMINAL_MATE_ZSH_INTEGRATION:-}" && -r "${TERMINAL_MATE_ZSH_INTEGRATION}" ]]; then')
    table.insert(lines, [[  source "${TERMINAL_MATE_ZSH_INTEGRATION}"]])
    table.insert(lines, [[fi]])
  end

  if restore_real_zdotdir then
    table.insert(lines, [[export ZDOTDIR="${_TMATE_REAL_ZDOTDIR}"]])
  else
    table.insert(lines, [[export ZDOTDIR="${_TMATE_WRAPPER_ZDOTDIR}"]])
  end

  table.insert(lines, [[unset _TMATE_WRAPPER_ZDOTDIR _TMATE_REAL_ZDOTDIR]])
  return lines
end

local function write_if_changed(path, lines)
  local current = nil
  if vim.fn.filereadable(path) == 1 then
    current = table.concat(vim.fn.readfile(path), "\n")
  end

  local content = table.concat(lines, "\n")
  if current == content then
    return true
  end

  return pcall(vim.fn.writefile, lines, path)
end

local function ensure_zsh_wrapper_dir()
  local wrapper_dir = join_paths(vim.fn.stdpath("cache"), "terminal_mate", "zsh")
  local ok_mkdir = pcall(vim.fn.mkdir, wrapper_dir, "p")
  if not ok_mkdir then
    return nil, "failed to create zsh wrapper directory"
  end

  local files = {
    [".zshenv"] = build_zsh_wrapper_lines(".zshenv", false, false),
    [".zprofile"] = build_zsh_wrapper_lines(".zprofile", false, false),
    [".zshrc"] = build_zsh_wrapper_lines(".zshrc", true, true),
    [".zlogin"] = build_zsh_wrapper_lines(".zlogin", false, true),
    [".zlogout"] = build_zsh_wrapper_lines(".zlogout", false, true),
  }

  for filename, lines in pairs(files) do
    local ok_write = write_if_changed(join_paths(wrapper_dir, filename), lines)
    if not ok_write then
      return nil, string.format("failed to write %s", filename)
    end
  end

  return wrapper_dir, nil
end

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

---@param terminal table|nil
---@return boolean
function M.is_alive(terminal)
  local job_id = nil
  if terminal and terminal.buf and vim.api.nvim_buf_is_valid(terminal.buf) then
    if vim.fn.exists("*term_getjob") == 1 then
      local ok_term_job, term_job = pcall(vim.fn.term_getjob, terminal.buf)
      if ok_term_job and type(term_job) == "number" and term_job > 0 then
        job_id = term_job
      end
    end

    if (not job_id or job_id <= 0) and vim.b[terminal.buf] then
      local buf_job = vim.b[terminal.buf].terminal_job_id
      if type(buf_job) == "number" and buf_job > 0 then
        job_id = buf_job
      end
    end
  end

  if (not job_id or job_id <= 0) and terminal then
    job_id = terminal.job_id
  end

  return terminal ~= nil
    and terminal.buf ~= nil
    and vim.api.nvim_buf_is_valid(terminal.buf)
    and job_is_running(job_id)
end

---@param terminal table
function M.reset(terminal)
  terminal.win = nil
  terminal.buf = nil
  terminal.job_id = nil
  terminal.shell_command = nil
  terminal.shell_source = nil
  terminal.shell_diagnostics = nil
  terminal.shell_integration = nil
  terminal.last_error = nil
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

local function integration_state(terminal)
  terminal.shell_integration = terminal.shell_integration or {
    enabled = false,
    available = termrequest_is_available(),
    kind = nil,
    source = nil,
    reason = nil,
    wrapper_dir = nil,
    script_path = nil,
    cwd = nil,
    prompt_active = false,
    prompt_ready = false,
    command_running = false,
    last_exit_status = nil,
    last_sequence = nil,
    last_cursor = nil,
    last_event_at = nil,
  }

  return terminal.shell_integration
end

local function shell_integration_opts(candidate, opts)
  local integration_opts = opts and opts.shell_integration or {}
  local state = {
    enabled = false,
    available = termrequest_is_available(),
    kind = nil,
    source = nil,
    reason = nil,
    wrapper_dir = nil,
    script_path = nil,
  }

  if not integration_opts.enabled then
    state.reason = "disabled"
    return nil, state
  end

  if not state.available then
    state.reason = "termrequest_unavailable"
    return nil, state
  end

  if file_basename(candidate and candidate.resolved) ~= "zsh" then
    state.reason = "unsupported_shell"
    return nil, state
  end

  for _, arg in ipairs(candidate.argv or {}) do
    if arg == "-f" or arg == "--no-rcs" then
      state.reason = "zsh_rcs_disabled"
      return nil, state
    end
  end

  local script_path = runtime_file("shell", "terminal_mate.zsh")
  if not script_path or vim.fn.filereadable(script_path) ~= 1 then
    state.reason = "integration_script_missing"
    return nil, state
  end

  local wrapper_dir, wrapper_err = ensure_zsh_wrapper_dir()
  if not wrapper_dir then
    state.reason = wrapper_err or "wrapper_setup_failed"
    return nil, state
  end

  local original_zdotdir = vim.env.ZDOTDIR or vim.env.HOME
  if type(original_zdotdir) ~= "string" or original_zdotdir == "" then
    state.reason = "original_zdotdir_missing"
    return nil, state
  end

  state.enabled = true
  state.kind = "zsh"
  state.source = "zdotdir_wrapper"
  state.wrapper_dir = wrapper_dir
  state.script_path = script_path

  return {
    env = {
      ZDOTDIR = wrapper_dir,
      TERMINAL_MATE_ORIG_ZDOTDIR = original_zdotdir,
      TERMINAL_MATE_ZSH_INTEGRATION = script_path,
    },
  }, state
end

local function strip_osc_terminator(payload)
  if type(payload) ~= "string" then
    return nil
  end

  if payload:sub(-2) == "\027\\" then
    return payload:sub(1, -3)
  end
  if payload:sub(-1) == "\007" then
    return payload:sub(1, -2)
  end

  return payload
end

local function osc_payload(sequence, code)
  local prefix = "\027]" .. code .. ";"
  if type(sequence) ~= "string" or sequence:sub(1, #prefix) ~= prefix then
    return nil
  end

  return strip_osc_terminator(sequence:sub(#prefix + 1))
end

local function process_current_path(terminal)
  if not terminal or not terminal.buf or not vim.api.nvim_buf_is_valid(terminal.buf) or vim.fn.exists("*jobpid") ~= 1 then
    return nil
  end

  local job_id = nil
  if vim.fn.exists("*term_getjob") == 1 then
    local ok_term_job, term_job = pcall(vim.fn.term_getjob, terminal.buf)
    if ok_term_job and type(term_job) == "number" and term_job > 0 then
      job_id = term_job
    end
  end

  if (not job_id or job_id <= 0) and vim.b[terminal.buf] then
    local buf_job = vim.b[terminal.buf].terminal_job_id
    if type(buf_job) == "number" and buf_job > 0 then
      job_id = buf_job
    end
  end

  if (not job_id or job_id <= 0) and terminal.job_id and terminal.job_id > 0 then
    job_id = terminal.job_id
  end

  if type(job_id) ~= "number" or job_id <= 0 or not job_is_running(job_id) then
    return nil
  end

  local ok_pid, pid = pcall(vim.fn.jobpid, job_id)
  if not ok_pid or type(pid) ~= "number" or pid <= 0 then
    return nil
  end

  local proc_cwd = string.format("/proc/%d/cwd", pid)
  local resolved = uv and uv.fs_realpath and uv.fs_realpath(proc_cwd) or nil
  if type(resolved) == "string" and resolved ~= "" then
    return resolved
  end

  local link = uv and uv.fs_readlink and uv.fs_readlink(proc_cwd) or nil
  if type(link) == "string" and link ~= "" then
    return link
  end

  if vim.fn.executable("readlink") == 1 then
    local output = vim.fn.system({ "readlink", "-f", proc_cwd })
    if vim.v.shell_error == 0 then
      output = vim.trim(output)
      if output ~= "" then
        return output
      end
    end
  end

  if vim.fn.executable("pwdx") == 1 then
    local output = vim.fn.system({ "pwdx", tostring(pid) })
    if vim.v.shell_error == 0 then
      local cwd = output:match("^%s*%d+:%s*(.-)%s*$")
      if cwd and cwd ~= "" then
        return cwd
      end
    end
  end

  return nil
end

---@param terminal table
---@param message string
---@return string
local function remember_error(terminal, message)
  terminal.last_error = message
  return message
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

---@param preferred_win number|nil
---@return number|nil
local function normalize_window(preferred_win)
  if preferred_win and vim.api.nvim_win_is_valid(preferred_win) then
    local cfg = vim.api.nvim_win_get_config(preferred_win)
    if cfg.relative == "" then
      return preferred_win
    end
  end

  return nil
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

---@param terminal_win number|nil
---@param terminal_buf number|nil
local function cleanup_terminal_window(terminal_win, terminal_buf)
  if terminal_buf and vim.api.nvim_buf_is_valid(terminal_buf) then
    pcall(vim.api.nvim_buf_delete, terminal_buf, { force = true })
  end
  if terminal_win and vim.api.nvim_win_is_valid(terminal_win) then
    pcall(vim.api.nvim_win_close, terminal_win, true)
  end
end

---@param terminal_win number
local function configure_terminal_window(terminal_win)
  if not vim.api.nvim_win_is_valid(terminal_win) then
    return
  end

  vim.wo[terminal_win].number = false
  vim.wo[terminal_win].relativenumber = false
  vim.wo[terminal_win].signcolumn = "no"
end

---@param terminal_win number|nil
---@param buffer number|nil
local function restore_window_buffer(terminal_win, buffer)
  if terminal_win and buffer and vim.api.nvim_win_is_valid(terminal_win) and vim.api.nvim_buf_is_valid(buffer) then
    pcall(vim.api.nvim_win_set_buf, terminal_win, buffer)
  end
end

---@param split_percent number
---@param reuse_win number|nil
---@return number|nil editor_win
---@return number|nil terminal_win
local function open_terminal_window(split_percent, reuse_win)
  local existing_win = normalize_window(reuse_win)
  if existing_win then
    return pick_split_anchor_win(), existing_win
  end

  local editor_win = pick_split_anchor_win()
  if vim.api.nvim_win_is_valid(editor_win) then
    vim.api.nvim_set_current_win(editor_win)
  end

  local editor_height = vim.api.nvim_win_get_height(editor_win)
  local terminal_height = math.max(3, math.floor(editor_height * (split_percent / 100)))

  local ok = pcall(vim.cmd, "botright " .. terminal_height .. "split")
  if not ok then
    return nil, nil
  end

  return editor_win, vim.api.nvim_get_current_win()
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

---@param terminal table
---@return string
local function build_not_running_error(terminal)
  local details = {}

  if terminal.job_id ~= nil then
    table.insert(details, "job=" .. tostring(terminal.job_id) .. " (" .. describe_job_status(terminal.job_id) .. ")")
  end
  if terminal.shell_command then
    table.insert(details, "last shell=" .. string.format("%q", terminal.shell_command) .. " from " .. tostring(terminal.shell_source))
  end
  if terminal.shell_diagnostics then
    table.insert(details, "candidates=" .. terminal.shell_diagnostics)
  end
  if terminal.last_error then
    table.insert(details, "last error=" .. terminal.last_error)
  end

  if #details == 0 then
    return "Neovim terminal is not running."
  end

  return "Neovim terminal is not running (" .. table.concat(details, "; ") .. ")"
end

---@param terminal table
---@param opts table
---@return boolean
---@return string|nil
function M.create(terminal, opts)
  if not M.is_available() then
    return false, remember_error(terminal, "Neovim terminal backend is unavailable.")
  end

  if M.is_alive(terminal) then
    terminal.last_error = nil
    return true, nil
  end

  local previous_win = vim.api.nvim_get_current_win()
  local reuse_win = normalize_window(opts.reuse_win)
  local previous_buf = reuse_win and vim.api.nvim_win_get_buf(reuse_win) or nil
  local editor_win, terminal_win = open_terminal_window(opts.split_percent, reuse_win)
  if not terminal_win then
    return false, remember_error(terminal, "Failed to open a Neovim terminal split.")
  end

  local terminal_buf = prepare_terminal_buffer(terminal_win)

  local shell_candidates, shell_diagnostics = resolve_shell_candidates(opts)
  if #shell_candidates == 0 then
    restore_window_buffer(reuse_win, previous_buf)
    cleanup_terminal_window(reuse_win and nil or terminal_win, terminal_buf)
    if editor_win and vim.api.nvim_win_is_valid(editor_win) then
      vim.api.nvim_set_current_win(editor_win)
    elseif previous_win and vim.api.nvim_win_is_valid(previous_win) then
      vim.api.nvim_set_current_win(previous_win)
    end
    return false, remember_error(
      terminal,
      "Failed to resolve a usable shell for Neovim terminal (" .. format_failure_details(shell_diagnostics) .. ")"
    )
  end

  local attempts = {}
  local active_candidate = nil
  local job_id = nil
  local active_integration = nil

  for index, candidate in ipairs(shell_candidates) do
    local termopen_opts, integration = shell_integration_opts(candidate, opts)
    local ok_term, job_result = pcall(vim.fn.termopen, candidate.argv, termopen_opts or {})
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
      active_integration = integration
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
    restore_window_buffer(reuse_win, previous_buf)
    cleanup_terminal_window(reuse_win and nil or terminal_win, terminal_buf)
    if editor_win and vim.api.nvim_win_is_valid(editor_win) then
      vim.api.nvim_set_current_win(editor_win)
    elseif previous_win and vim.api.nvim_win_is_valid(previous_win) then
      vim.api.nvim_set_current_win(previous_win)
    end
    return false, remember_error(
      terminal,
      "Failed to start a Neovim terminal shell (" .. format_failure_details(shell_diagnostics, attempts) .. ")"
    )
  end

  pcall(vim.api.nvim_buf_set_name, terminal_buf, string.format("[TerminalMateTerminal:%s]", terminal.id or "nvim"))
  configure_terminal_window(terminal_win)

  terminal.win = terminal_win
  terminal.buf = terminal_buf
  terminal.job_id = job_id
  terminal.shell_command = active_candidate.command
  terminal.shell_source = active_candidate.source
  terminal.shell_diagnostics = table.concat(shell_diagnostics, "; ")
  terminal.shell_integration = active_integration
  terminal.last_error = nil

  vim.b[terminal_buf].terminal_mate_managed = true
  vim.b[terminal_buf].terminal_mate_terminal_id = terminal.id

  if editor_win and vim.api.nvim_win_is_valid(editor_win) then
    vim.api.nvim_set_current_win(editor_win)
  elseif previous_win and vim.api.nvim_win_is_valid(previous_win) then
    vim.api.nvim_set_current_win(previous_win)
  end

  return true, nil
end

---@param terminal table
---@param opts table
---@return boolean
---@return string|nil
function M.show(terminal, opts)
  if not M.is_alive(terminal) then
    terminal.win = nil
    return false, build_not_running_error(terminal)
  end

  local previous_win = vim.api.nvim_get_current_win()
  local reuse_win = normalize_window(opts.reuse_win) or normalize_window(terminal.win)
  local editor_win, terminal_win = open_terminal_window(opts.split_percent, reuse_win)
  if not terminal_win then
    return false, remember_error(terminal, "Failed to open a Neovim terminal split.")
  end

  terminal.win = terminal_win
  vim.api.nvim_win_set_buf(terminal_win, terminal.buf)
  configure_terminal_window(terminal_win)

  if editor_win and vim.api.nvim_win_is_valid(editor_win) then
    vim.api.nvim_set_current_win(editor_win)
  elseif previous_win and vim.api.nvim_win_is_valid(previous_win) then
    vim.api.nvim_set_current_win(previous_win)
  end

  return true, nil
end

---@param terminal table
function M.hide(terminal)
  if terminal.win and vim.api.nvim_win_is_valid(terminal.win) then
    pcall(vim.api.nvim_win_close, terminal.win, true)
  end
  terminal.win = nil
end

---@param terminal table
function M.close(terminal)
  local terminal_win = terminal.win
  local terminal_buf = terminal.buf

  M.reset(terminal)

  if terminal_win and vim.api.nvim_win_is_valid(terminal_win) then
    pcall(vim.api.nvim_win_close, terminal_win, true)
  end
  if terminal_buf and vim.api.nvim_buf_is_valid(terminal_buf) then
    pcall(vim.api.nvim_buf_delete, terminal_buf, { force = true })
  end
end

---@param terminal table
---@param text string
---@param press_enter boolean
---@return boolean
---@return string|nil
function M.send_text(terminal, text, press_enter)
  if not M.is_alive(terminal) then
    return false, build_not_running_error(terminal)
  end

  local ok_send, err_send = pcall(vim.api.nvim_chan_send, terminal.job_id, text)
  if not ok_send then
    return false, remember_error(terminal, "Failed to send to Neovim terminal: " .. tostring(err_send))
  end

  if press_enter then
    local ok_enter, err_enter = pcall(vim.api.nvim_chan_send, terminal.job_id, "\r")
    if not ok_enter then
      return false, remember_error(terminal, "Failed to send Enter to Neovim terminal: " .. tostring(err_enter))
    end
  end

  if terminal.win and vim.api.nvim_win_is_valid(terminal.win) then
    local line_count = vim.api.nvim_buf_line_count(terminal.buf)
    pcall(vim.api.nvim_win_set_cursor, terminal.win, { math.max(line_count, 1), 0 })
  end

  return true, nil
end

---@param terminal table
---@param key string
---@return boolean
---@return string|nil
function M.send_special_key(terminal, key)
  if not M.is_alive(terminal) then
    return false, build_not_running_error(terminal)
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

  local ok_send, err_send = pcall(vim.api.nvim_chan_send, terminal.job_id, code)
  if not ok_send then
    return false, remember_error(terminal, "Failed to send special key to Neovim terminal: " .. tostring(err_send))
  end

  return true, nil
end

---@param terminal table|nil
---@return table
function M.current_path_context(terminal)
  local integration = terminal and terminal.shell_integration or nil
  if integration and type(integration.cwd) == "string" and integration.cwd ~= "" then
    return {
      cwd = integration.cwd,
      source = "shell_integration",
    }
  end

  local cwd = process_current_path(terminal)
  if cwd then
    return {
      cwd = cwd,
      source = "process",
    }
  end

  return {
    cwd = nil,
    source = "none",
  }
end

--- Get the current working directory for the shell running inside a managed Neovim terminal.
---@param terminal table|nil
---@return string|nil
function M.current_path(terminal)
  return M.current_path_context(terminal).cwd
end

---@param terminal table|nil
---@param data table|nil
---@return boolean
function M.handle_term_request(terminal, data)
  if not terminal or type(data) ~= "table" or type(data.sequence) ~= "string" then
    return false
  end

  local integration = integration_state(terminal)
  local sequence = data.sequence
  integration.last_sequence = sequence
  integration.last_cursor = data.cursor
  integration.last_event_at = uv and uv.now and uv.now() or nil

  local osc7 = osc_payload(sequence, "7")
  if osc7 and osc7:sub(1, 7) == "file://" then
    local normalized = osc7:gsub("^file://[^/]*", "file://")
    local ok_uri, cwd = pcall(vim.uri_to_fname, normalized)
    if ok_uri and type(cwd) == "string" and cwd ~= "" then
      integration.cwd = cwd
      pcall(vim.api.nvim_buf_set_var, terminal.buf, "terminal_mate_cwd", cwd)
      return true
    end
  end

  local osc133 = osc_payload(sequence, "133")
  if not osc133 then
    return false
  end

  local code, payload = osc133:match("^([^;]+);?(.*)$")
  if code == "A" then
    integration.prompt_active = true
    integration.prompt_ready = false
  elseif code == "B" then
    integration.prompt_active = true
    integration.prompt_ready = true
  elseif code == "C" then
    integration.prompt_active = false
    integration.prompt_ready = false
    integration.command_running = true
  elseif code == "D" then
    integration.prompt_active = false
    integration.prompt_ready = false
    integration.command_running = false
    integration.last_exit_status = tonumber(payload:match("^(-?%d+)"))
  else
    return false
  end

  pcall(vim.api.nvim_buf_set_var, terminal.buf, "terminal_mate_shell_integration", vim.deepcopy(integration))
  return true
end

---@param terminal table|nil
---@return table
function M.get_debug_state(terminal)
  if not terminal then
    return {
      exists = false,
    }
  end

  return {
    exists = true,
    id = terminal.id,
    buf = terminal.buf,
    win = terminal.win,
    job_id = terminal.job_id,
    shell_command = terminal.shell_command,
    shell_source = terminal.shell_source,
    cwd = M.current_path_context(terminal),
    shell_integration = vim.deepcopy(terminal.shell_integration),
  }
end

return M
