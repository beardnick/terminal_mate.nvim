local M = {}

local READY_MARKER = "<TM_READY>"
local FINISH_MARKER = "<TM_WIDGET><finish>"
local LBUFFER_START = "<TM_LBUFFER>"
local LBUFFER_END = "</TM_LBUFFER>"
local RBUFFER_START = "<TM_RBUFFER>"
local RBUFFER_END = "</TM_RBUFFER>"

local TYPE_KIND = {
  DI = "dir",
  FI = "file",
  EX = "exec",
  LN = "link",
  PI = "pipe",
  SO = "sock",
  BD = "block",
  CD = "char",
  NO = "text",
}

local state = {
  config = nil,
  job_id = nil,
  ready = false,
  init_sent = false,
  echo_disabled = false,
  init_script_path = nil,
  waiters = {},
  output = "",
  partial = "",
  pending = nil,
  warned_missing_zsh = false,
}

local function notify(msg, level)
  vim.notify("[TerminalMate] " .. msg, level or vim.log.levels.INFO)
end

local function strip_ansi(text)
  text = text:gsub("\27%[[0-9;?]*[ -/]*[@-~]", "")
  text = text:gsub("\27%][^\7]*\7", "")
  return text
end

local function strip_backspaces(text)
  local out = {}

  for i = 1, #text do
    local ch = text:sub(i, i)
    if ch == "\b" then
      out[#out] = nil
    else
      table.insert(out, ch)
    end
  end

  return table.concat(out)
end

local function trim(text)
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function current_shell_executable()
  local configured = state.config and state.config.shell or nil
  local shell = configured or vim.env.SHELL or "zsh"
  local executable = shell:match("^%s*([^%s]+)") or shell
  local base = vim.fn.fnamemodify(executable, ":t")

  if base:match("^zsh") then
    return executable
  end

  local zsh = vim.fn.exepath("zsh")
  if zsh ~= "" then
    return zsh
  end

  return nil
end

local function finish_waiters(ok, err)
  local waiters = state.waiters
  state.waiters = {}

  for _, waiter in ipairs(waiters) do
    waiter(ok, err)
  end
end

local function reset_session()
  local init_script_path = state.init_script_path

  if state.job_id and vim.fn.jobwait({ state.job_id }, 0)[1] == -1 then
    pcall(vim.fn.jobstop, state.job_id)
  end

  if init_script_path and vim.fn.filereadable(init_script_path) == 1 then
    pcall(vim.fn.delete, init_script_path)
  end

  state.job_id = nil
  state.ready = false
  state.init_sent = false
  state.echo_disabled = false
  state.init_script_path = nil
  state.output = ""
  state.partial = ""

  if state.pending then
    local callback = state.pending.callback
    state.pending = nil
    callback(nil, "zsh completion session stopped")
  end
end

local function sanitize_completion_word(text)
  local word = trim(text)
  word = word:gsub("%s+%-%-%s+.*$", "")
  return trim(word)
end

local function find_token_start(line, cursor_col)
  local i = 1
  local start_col = 1
  local escaped = false
  local single = false
  local double = false

  while i <= cursor_col do
    local ch = line:sub(i, i)

    if escaped then
      escaped = false
    elseif ch == "\\" and not single then
      escaped = true
    elseif ch == "'" and not double then
      single = not single
    elseif ch == '"' and not single then
      double = not double
    elseif not single and not double then
      if ch:match("%s") or ch:match("[|&;(){}]") then
        start_col = i + 1
      elseif ch == "=" or ch == ":" then
        start_col = i + 1
      end
    end

    i = i + 1
  end

  return start_col
end

local function parse_items(output)
  local items = {}
  local seen = {}
  local current_menu = nil

  for _, line in ipairs(vim.split(output, "\n", { plain = true, trimempty = false })) do
    local description = line:match("<DESCRIPTION>(.-)</DESCRIPTION>")
    if description then
      current_menu = trim(description)
    end

    local message = line:match("<MESSAGE>(.-)</MESSAGE>")
    if message then
      current_menu = trim(message)
    end

    for item_type, text in line:gmatch("<LC><(%u%u)><RC>(.-)<EC>") do
      local word = sanitize_completion_word(text)
      if word ~= "" and word ~= "--" and not word:match("^%-%- ") and not seen[word] then
        seen[word] = true
        table.insert(items, {
          word = word,
          abbr = trim(text),
          menu = current_menu,
          kind = TYPE_KIND[item_type] or "text",
          dup = 1,
        })
      end
    end
  end

  return items
end

local function parse_result(output)
  local cleaned = strip_backspaces(strip_ansi(output))
  cleaned = cleaned:gsub("\r", "")
  cleaned = cleaned:gsub("[\001-\008\011\012\014-\031]", "")
  local lbuffer = cleaned:match(vim.pesc(LBUFFER_START) .. "(.-)" .. vim.pesc(LBUFFER_END)) or ""
  local rbuffer = cleaned:match(vim.pesc(RBUFFER_START) .. "(.-)" .. vim.pesc(RBUFFER_END)) or ""

  return {
    lbuffer = lbuffer,
    rbuffer = rbuffer,
    line = lbuffer .. rbuffer,
    cursor_col = #lbuffer,
    items = parse_items(cleaned),
  }
end

local function insert_literal_tab(buf, win)
  if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_win_is_valid(win) then
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(win)
  local row = cursor[1] - 1
  local col = cursor[2]
  vim.api.nvim_buf_set_text(buf, row, col, row, col, { "\t" })
  vim.api.nvim_win_set_cursor(win, { cursor[1], col + 1 })
end

local function complete_pending_request()
  if not state.pending then
    return
  end

  local pending = state.pending
  state.pending = nil

  local result = parse_result(state.output)
  state.output = ""
  pending.callback(result, nil)
end

local function maybe_send_init_script()
  if not state.job_id or state.init_sent then
    return
  end

  if not state.echo_disabled then
    state.echo_disabled = true
    vim.api.nvim_chan_send(state.job_id, "stty -echo\n")
    vim.defer_fn(maybe_send_init_script, 100)
    return
  end

  state.init_sent = true

  local script = table.concat({
    "export TERM=vt100",
    "LISTMAX=10000000",
    "KEYTIMEOUT=1",
    "setopt zle noalwayslastprompt listrowsfirst completeinword",
    "autoload -Uz compinit",
    "(( $+functions[compdef] )) || compinit -u",
    "zmodload zsh/complist",
    "stty 38400 columns 120 rows 40 tabs -icanon -iexten",
    "precmd_functions=()",
    "preexec_functions=()",
    "PROMPT='<TM_PROMPT>'",
    "RPROMPT=''",
    "PS1=$PROMPT",
    "zstyle ':completion:*' group-name ''",
    "zstyle ':completion:*:default' list-colors \"no=<NO>\" \"fi=<FI>\" \"di=<DI>\" \"ln=<LN>\" \"pi=<PI>\" \"so=<SO>\" \"bd=<BD>\" \"cd=<CD>\" \"ex=<EX>\" \"lc=<LC>\" \"rc=<RC>\" \"ec=<EC>\"",
    "zstyle ':completion:*:messages' format $'<MESSAGE>%d</MESSAGE>\\n'",
    "zstyle ':completion:*:descriptions' format $'<DESCRIPTION>%d</DESCRIPTION>\\n'",
    "zstyle ':completion:*:options' verbose yes",
    "zstyle ':completion:*:values' verbose yes",
    "TM_completion_postfunc() {",
    "  compstate[list]='list force'",
    "}",
    "TM_complete_word_with_report() {",
    "  local +h -a comppostfuncs=( TM_completion_postfunc )",
    "  print -lr -- '<TM_WIDGET><complete-word>'",
    "  zle complete-word",
    "  print -lr -- \"<TM_LBUFFER>${(V)LBUFFER}</TM_LBUFFER>\" \"<TM_RBUFFER>${(V)RBUFFER}</TM_RBUFFER>\"",
    "  zle clear-screen",
    "  zle -R",
    "}",
    "TM_complete_finish() {",
    "  print -lr -- '<TM_WIDGET><finish>'",
    "  zle kill-whole-line",
    "  zle clear-screen",
    "  zle -R",
    "}",
    "zle -N TM_complete_word_with_report",
    "zle -N TM_complete_finish",
    "bindkey -M emacs '^I' TM_complete_word_with_report",
    "bindkey -M emacs '^X' TM_complete_finish",
    "bindkey -M viins '^I' TM_complete_word_with_report",
    "bindkey -M viins '^X' TM_complete_finish",
    "print -r -- '" .. READY_MARKER .. "'",
    "",
  }, "\n")
  local path = vim.fn.tempname() .. ".zsh"
  vim.fn.writefile(vim.split(script, "\n", { plain = true, trimempty = false }), path)
  state.init_script_path = path

  vim.api.nvim_chan_send(state.job_id, ". " .. vim.fn.shellescape(path) .. "\n")
end

local function handle_stdout(_, data)
  if not data then
    return
  end

  local lines = vim.deepcopy(data)
  if #lines == 0 then
    return
  end

  lines[1] = state.partial .. lines[1]
  if lines[#lines] == "" then
    state.partial = ""
    table.remove(lines, #lines)
  else
    state.partial = table.remove(lines, #lines)
  end

  local chunk = table.concat(lines, "\n")
  if chunk == "" then
    return
  end

  state.output = state.output .. chunk

  if not state.init_sent then
    maybe_send_init_script()
  end

  if not state.ready and state.output:find(READY_MARKER, 1, true) then
    state.ready = true
    state.output = ""
    finish_waiters(true)
    return
  end

  if state.pending and state.output:find(FINISH_MARKER, 1, true) then
    complete_pending_request()
  end
end

local function start_session()
  local executable = current_shell_executable()
  if not executable then
    if not state.warned_missing_zsh then
      state.warned_missing_zsh = true
      notify("zsh is not available; native shell completion is disabled.", vim.log.levels.WARN)
    end
    finish_waiters(false, "zsh is not available")
    return
  end

  local job_id = vim.fn.jobstart({ executable, "-i" }, {
    pty = true,
    on_stdout = handle_stdout,
    on_stderr = handle_stdout,
    on_exit = function(_, code)
      local had_waiters = #state.waiters > 0
      reset_session()
      if had_waiters then
        finish_waiters(false, "zsh completion session exited (" .. tostring(code) .. ")")
      end
    end,
  })

  if job_id <= 0 then
    finish_waiters(false, "failed to start zsh completion session")
    return
  end

  state.job_id = job_id
  vim.defer_fn(maybe_send_init_script, 200)
end

local function ensure_session(callback)
  if state.ready and state.job_id then
    callback(true)
    return
  end

  table.insert(state.waiters, callback)

  if state.job_id then
    return
  end

  start_session()
end

function M.setup(opts)
  state.config = opts or {}
end

function M.prime()
  ensure_session(function() end)
end

function M.stop()
  reset_session()
end

function M.request(line, cursor_col, callback)
  ensure_session(function(ok, err)
    if not ok then
      callback(nil, err)
      return
    end

    if state.pending then
      callback(nil, "zsh completion request already in flight")
      return
    end

    local left_moves = math.max(#line - cursor_col, 0)
    state.pending = { callback = callback }
    state.output = ""

    local keys = "\021" .. line
    if left_moves > 0 then
      keys = keys .. string.rep("\27[D", left_moves)
    end
    keys = keys .. "\t\024"

    vim.api.nvim_chan_send(state.job_id, keys)
  end)
end

function M.complete_at_cursor(buf, win)
  if vim.fn.pumvisible() == 1 then
    local rhs = vim.api.nvim_replace_termcodes("<C-n>", true, false, true)
    vim.api.nvim_feedkeys(rhs, "in", false)
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(win)
  local line_nr = cursor[1]
  local cursor_col = cursor[2]
  local line = vim.api.nvim_buf_get_lines(buf, line_nr - 1, line_nr, false)[1] or ""

  M.request(line, cursor_col, function(result, err)
    vim.schedule(function()
      if err or not result then
        insert_literal_tab(buf, win)
        return
      end

      if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_win_is_valid(win) then
        return
      end

      local current_cursor = vim.api.nvim_win_get_cursor(win)
      local current_line = vim.api.nvim_buf_get_lines(buf, line_nr - 1, line_nr, false)[1] or ""
      if current_cursor[1] ~= line_nr or current_cursor[2] ~= cursor_col or current_line ~= line then
        return
      end

      local updated_line = result.line ~= "" and result.line or line
      local updated_cursor = result.cursor_col

      if updated_line ~= line then
        vim.api.nvim_buf_set_lines(buf, line_nr - 1, line_nr, false, { updated_line })
        vim.api.nvim_win_set_cursor(win, { line_nr, updated_cursor })
      end

      if #result.items == 0 then
        if updated_line == line then
          insert_literal_tab(buf, win)
        end
        return
      end

      if #result.items == 1 and updated_line ~= line then
        return
      end

      local start_col = find_token_start(updated_line, updated_cursor)
      vim.fn.complete(start_col, result.items)
    end)
  end)
end

function M.select_prev()
  if vim.fn.pumvisible() == 1 then
    local rhs = vim.api.nvim_replace_termcodes("<C-p>", true, false, true)
    vim.api.nvim_feedkeys(rhs, "in", false)
  end
end

return M
