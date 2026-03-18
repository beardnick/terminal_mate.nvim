local M = {}
local uv = vim.uv or vim.loop

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
  queued_completion = nil,
  auto_request_generation = 0,
  session_cwd = nil,
}

local resolve_session_cwd

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
  state.session_cwd = nil

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

---@param line string
---@param cursor_col number
---@return string
local function current_completion_query(line, cursor_col)
  local start_col = find_token_start(line, cursor_col)
  if cursor_col < start_col then
    return ""
  end

  return line:sub(start_col, cursor_col)
end

---@param line string
---@param cursor_col number
---@return string[]
local function tokens_before_cursor(line, cursor_col)
  local tokens = {}
  local current = {}
  local escaped = false
  local single = false
  local double = false

  local function flush()
    if #current == 0 then
      return
    end

    table.insert(tokens, table.concat(current))
    current = {}
  end

  for i = 1, cursor_col do
    local ch = line:sub(i, i)

    if escaped then
      table.insert(current, ch)
      escaped = false
    elseif ch == "\\" and not single then
      escaped = true
      table.insert(current, ch)
    elseif ch == "'" and not double then
      single = not single
      table.insert(current, ch)
    elseif ch == '"' and not single then
      double = not double
      table.insert(current, ch)
    elseif not single and not double and (ch:match("%s") or ch:match("[|&;(){}]")) then
      flush()
    elseif not single and not double and (ch == "=" or ch == ":") then
      flush()
    else
      table.insert(current, ch)
    end
  end

  flush()
  return tokens
end

---@param line string
---@param cursor_col number
---@param query string
---@return boolean
local function is_path_query(line, cursor_col, query)
  if query == "" then
    return false
  end

  if query:match("^%-") then
    return false
  end

  if query:find("/", 1, true) or query:match("^[%.~/]") then
    return true
  end

  return find_token_start(line, cursor_col) > 1
end

---@param text string
---@return string
local function unescape_path_query(text)
  return (text:gsub("\\(.)", "%1"))
end

---@param path string
---@return string
local function normalize_fs_path(path)
  if vim.fs and vim.fs.normalize then
    return vim.fs.normalize(path)
  end

  return path
end

---@param path string
---@return string
local function trim_trailing_separator(path)
  if path == "/" then
    return path
  end

  return (path:gsub("/+$", ""))
end

---@param path string
---@return string
local function expand_tilde_prefix(path)
  local home = vim.env.HOME
  if type(home) ~= "string" or home == "" then
    return path
  end

  if path == "~" then
    return home
  end

  if path:sub(1, 2) == "~/" then
    return home .. path:sub(2)
  end

  return path
end

---@param base string
---@param name string
---@return string
local function join_fs_path(base, name)
  if base == "" or base == "." then
    return name
  end
  if base == "/" then
    return "/" .. name
  end

  return trim_trailing_separator(base) .. "/" .. name
end

---@param text string
---@return string
local function shell_escape_path_suffix(text)
  return (text:gsub("([\\%s\"'`$&;|<>()[%]{}*?!#])", "\\%1"))
end

---@class TerminalMatePathRequest
---@field query string
---@field prefix string
---@field filter string
---@field search_dir string
---@field path_only boolean

---@param line string
---@param cursor_col number
---@param query string
---@return TerminalMatePathRequest|nil
local function build_path_request(line, cursor_col, query)
  local tokens = tokens_before_cursor(line, cursor_col)
  local current_index = #tokens
  local command = tokens[1] or ""
  local path_only = current_index == 2 and (command == "cd" or command == "pushd")

  if not is_path_query(line, cursor_col, query) then
    return nil
  end

  local cwd = resolve_session_cwd()
  if type(cwd) ~= "string" or cwd == "" then
    return nil
  end

  local prefix, filter = query:match("^(.*[/])([^/]*)$")
  if prefix == nil then
    prefix = ""
    filter = query
  end

  local search_dir = prefix ~= "" and expand_tilde_prefix(unescape_path_query(prefix)) or cwd
  if search_dir:sub(1, 1) ~= "/" then
    search_dir = join_fs_path(cwd, search_dir)
  end

  search_dir = normalize_fs_path(trim_trailing_separator(search_dir))

  return {
    query = query,
    prefix = prefix,
    filter = filter,
    search_dir = search_dir,
    path_only = path_only,
  }
end

---@class TerminalMateCompletionRequest
---@field request_line string
---@field request_cursor_col number
---@field filter_query string
---@field preserve_input boolean
---@field path_request TerminalMatePathRequest|nil

---@param query string
---@return string
local function completion_filter_query(query)
  local segment = query:match(".*/([^/]*)$")
  if segment ~= nil then
    return segment
  end

  return query
end

---@param line string
---@param cursor_col number
---@param query string
---@param items table[]
---@return number
local function completion_replace_start(line, cursor_col, query, items)
  local token_start = find_token_start(line, cursor_col)
  local slash_offset = query:match("^.*()/")
  if not slash_offset then
    return token_start
  end

  local path_prefix = query:sub(1, slash_offset)
  for _, item in ipairs(items) do
    local word = item.word or ""
    if word:sub(1, #path_prefix) == path_prefix then
      return token_start
    end
  end

  return token_start + slash_offset
end

---@param line string
---@param cursor_col number
---@return TerminalMateCompletionRequest
local function build_completion_request(line, cursor_col)
  local query = current_completion_query(line, cursor_col)
  local request = {
    request_line = line,
    request_cursor_col = cursor_col,
    filter_query = completion_filter_query(query),
    preserve_input = false,
    path_request = build_path_request(line, cursor_col, query),
  }

  local option_prefix = query:match("^(%-%-?)[%w-]+$")
  if not option_prefix then
    return request
  end

  local start_col = find_token_start(line, cursor_col)
  request.request_line = line:sub(1, start_col - 1) .. option_prefix .. line:sub(cursor_col + 1)
  request.request_cursor_col = (start_col - 1) + #option_prefix
  request.preserve_input = true

  return request
end

---@param items table[]
---@param query string
---@return table[]
local function sort_items_by_word(items)
  table.sort(items, function(a, b)
    local a_word = a.word or ""
    local b_word = b.word or ""

    if #a_word == #b_word then
      return a_word < b_word
    end

    return #a_word < #b_word
  end)

  return items
end

---@param query string
---@return string|nil
local function option_query_body(query)
  local body = query:match("^%-%-?([%w-]+)$")
  if not body or body == "" then
    return nil
  end

  return body:lower()
end

---@param items table[]
---@param query string
---@return table[]|nil
local function fuzzy_sort_option_items(items, query)
  local body = option_query_body(query)
  if not body then
    return nil
  end

  local query_lower = query:lower()
  local exact_prefix = {}
  local body_prefix = {}
  local body_fuzzy = {}

  for _, item in ipairs(items) do
    local word = item.word or ""
    local lower_word = word:lower()
    local normalized = lower_word:gsub("^%-%-?", "")

    if lower_word:sub(1, #query_lower) == query_lower then
      table.insert(exact_prefix, item)
    elseif normalized:sub(1, #body) == body then
      table.insert(body_prefix, item)
    elseif #body > 1 and fuzzy_match(normalized, body) then
      table.insert(body_fuzzy, item)
    end
  end

  if #exact_prefix == 0 and #body_prefix == 0 and #body_fuzzy == 0 then
    return nil
  end

  sort_items_by_word(exact_prefix)
  sort_items_by_word(body_prefix)
  sort_items_by_word(body_fuzzy)

  local ordered = {}
  for _, group in ipairs({ exact_prefix, body_prefix, body_fuzzy }) do
    for _, item in ipairs(group) do
      table.insert(ordered, item)
    end
  end

  return ordered
end

---@param items table[]
---@param query string
---@return table[]
local function fuzzy_sort_items(items, query)
  if query == "" or #items <= 1 then
    return items
  end

  local option_items = fuzzy_sort_option_items(items, query)
  if option_items then
    return option_items
  end

  if vim.fn.exists("*matchfuzzy") == 1 then
    local ok, matches = pcall(vim.fn.matchfuzzy, items, query, { key = "word" })
    if ok and type(matches) == "table" and #matches > 0 then
      return matches
    end
  end

  local filtered = {}
  for _, item in ipairs(items) do
    if fuzzy_match(item.word or "", query) then
      table.insert(filtered, item)
    end
  end

  if #filtered > 0 then
    return filtered
  end

  return items
end

---@param path string
---@return boolean
local function is_directory(path)
  if not uv or not uv.fs_stat then
    return false
  end

  local stat = uv.fs_stat(path)
  return stat and stat.type == "directory" or false
end

---@param path_request TerminalMatePathRequest|nil
---@return table[]
local function filesystem_path_items(path_request)
  if not path_request then
    return {}
  end

  if vim.fn.isdirectory(path_request.search_dir) ~= 1 then
    return {}
  end

  if not uv or not uv.fs_scandir or not uv.fs_scandir_next then
    return {}
  end

  local handle = uv.fs_scandir(path_request.search_dir)
  if not handle then
    return {}
  end

  local include_hidden = path_request.filter:sub(1, 1) == "."
  local items = {}

  while true do
    local name, entry_type = uv.fs_scandir_next(handle)
    if not name then
      break
    end

    if not include_hidden and name:sub(1, 1) == "." then
      goto continue
    end

    if path_request.filter ~= "" and not fuzzy_match(name, path_request.filter) then
      goto continue
    end

    local full_path = join_fs_path(path_request.search_dir, name)
    local is_dir = entry_type == "directory" or is_directory(full_path)
    local suffix = shell_escape_path_suffix(name) .. (is_dir and "/" or "")
    table.insert(items, {
      word = path_request.prefix .. suffix,
      abbr = path_request.prefix .. name .. (is_dir and "/" or ""),
      menu = "[path]",
      kind = is_dir and "dir" or "file",
      dup = 1,
    })

    ::continue::
  end

  return items
end

---@param primary table[]
---@param secondary table[]
---@return table[]
local function merge_completion_items(primary, secondary)
  if #secondary == 0 then
    return primary
  end

  local merged = {}
  local seen = {}

  for _, item in ipairs(primary) do
    local word = item.word or ""
    if word ~= "" and not seen[word] then
      seen[word] = true
      table.insert(merged, item)
    end
  end

  for _, item in ipairs(secondary) do
    local word = item.word or ""
    if word ~= "" and not seen[word] then
      seen[word] = true
      table.insert(merged, item)
    end
  end

  return merged
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

---@param immediate boolean|nil
local function close_completion_menu(immediate)
  if vim.fn.pumvisible() ~= 1 then
    return
  end

  local rhs = vim.api.nvim_replace_termcodes("<C-e>", true, false, true)
  if immediate then
    vim.fn.feedkeys(rhs, "inx")
  else
    vim.api.nvim_feedkeys(rhs, "in", false)
  end
end

---@param keys string
local function feed_insert_keys(keys)
  local rhs = vim.api.nvim_replace_termcodes(keys, true, false, true)
  vim.api.nvim_feedkeys(rhs, "in", false)
end

---@param mode string
---@return boolean
local function is_insert_mode(mode)
  return mode == "i" or mode == "ic" or mode == "ix"
end

---@param buf number
---@param win number
---@return table|nil
local function current_completion_context(buf, win)
  if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_win_is_valid(win) then
    return nil
  end

  if vim.api.nvim_win_get_buf(win) ~= buf then
    return nil
  end

  local cursor = vim.api.nvim_win_get_cursor(win)
  local line_nr = cursor[1]
  local cursor_col = cursor[2]
  local line = vim.api.nvim_buf_get_lines(buf, line_nr - 1, line_nr, false)[1] or ""

  return {
    line_nr = line_nr,
    cursor_col = cursor_col,
    line = line,
  }
end

---@param ctx table
---@return boolean
local function has_auto_completion_context(ctx)
  return ctx.line:sub(1, ctx.cursor_col):match("%S") ~= nil
end

---@param opts table|nil
---@return table
local function normalize_complete_options(opts)
  return vim.tbl_extend("force", {
    allow_select_next = true,
    insert_tab_on_empty = true,
    preserve_input = false,
    auto = false,
  }, opts or {})
end

local function process_queued_completion()
  if state.pending or not state.queued_completion then
    return
  end

  local queued = state.queued_completion
  state.queued_completion = nil
  M.complete_at_cursor(queued.buf, queued.win, queued.opts)
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

local function handle_stdout(job_id, data)
  if job_id ~= state.job_id then
    return
  end

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

resolve_session_cwd = function()
  if not state.config or type(state.config.cwd_resolver) ~= "function" then
    return nil
  end

  local ok, cwd = pcall(state.config.cwd_resolver)
  if not ok or type(cwd) ~= "string" or cwd == "" then
    return nil
  end

  return cwd
end

local function start_session(cwd)
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
    cwd = cwd,
    on_stdout = handle_stdout,
    on_stderr = handle_stdout,
    on_exit = function(exited_job_id, code)
      if exited_job_id ~= state.job_id then
        return
      end

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
  state.session_cwd = cwd
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

  start_session(resolve_session_cwd())
end

function M.setup(opts)
  state.config = opts or {}
end

function M.prime()
  ensure_session(function() end)
end

function M.stop()
  reset_session()
  state.queued_completion = nil
  state.auto_request_generation = state.auto_request_generation + 1
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

    local cwd = resolve_session_cwd()
    if cwd then
      state.session_cwd = cwd
      keys = "builtin cd -- " .. vim.fn.shellescape(cwd) .. "\n" .. keys
    end

    vim.api.nvim_chan_send(state.job_id, keys)
  end)
end

function M.complete_at_cursor(buf, win, opts)
  local options = normalize_complete_options(opts)

  if options.allow_select_next and vim.fn.pumvisible() == 1 then
    local rhs = vim.api.nvim_replace_termcodes("<C-n>", true, false, true)
    vim.api.nvim_feedkeys(rhs, "in", false)
    return
  end

  local ctx = current_completion_context(buf, win)
  if not ctx then
    return
  end

  if options.auto and not is_insert_mode(vim.api.nvim_get_mode().mode) then
    return
  end

  if options.auto and not has_auto_completion_context(ctx) then
    close_completion_menu()
    return
  end

  if state.pending then
    state.queued_completion = {
      buf = buf,
      win = win,
      opts = options,
    }
    return
  end

  local line_nr = ctx.line_nr
  local cursor_col = ctx.cursor_col
  local line = ctx.line
  local request = build_completion_request(line, cursor_col)
  if options.preserve_input then
    request.preserve_input = true
  end

  M.request(request.request_line, request.request_cursor_col, function(result, err)
    vim.schedule(function()
      local function finish()
        if state.queued_completion then
          vim.schedule(process_queued_completion)
        end
      end

      if err or not result then
        if options.insert_tab_on_empty then
          insert_literal_tab(buf, win)
        else
          close_completion_menu()
        end
        finish()
        return
      end

      if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_win_is_valid(win) then
        finish()
        return
      end

      local current_cursor = vim.api.nvim_win_get_cursor(win)
      local current_line = vim.api.nvim_buf_get_lines(buf, line_nr - 1, line_nr, false)[1] or ""
      if current_cursor[1] ~= line_nr or current_cursor[2] ~= cursor_col or current_line ~= line then
        finish()
        return
      end

      local updated_line = request.preserve_input and line or (result.line ~= "" and result.line or line)
      local updated_cursor = request.preserve_input and cursor_col or result.cursor_col

      if updated_line ~= line then
        vim.api.nvim_buf_set_lines(buf, line_nr - 1, line_nr, false, { updated_line })
        vim.api.nvim_win_set_cursor(win, { line_nr, updated_cursor })
      end

      local path_items = filesystem_path_items(request.path_request)
      local completion_items = request.path_request and request.path_request.path_only
          and path_items
        or merge_completion_items(result.items, path_items)

      if #completion_items == 0 then
        if updated_line == line then
          if options.insert_tab_on_empty then
            insert_literal_tab(buf, win)
          else
            close_completion_menu()
          end
        end
        finish()
        return
      end

      local items = fuzzy_sort_items(completion_items, request.filter_query)

      if #items == 1 and updated_line ~= line then
        finish()
        return
      end

      local start_col = completion_replace_start(
        updated_line,
        updated_cursor,
        current_completion_query(updated_line, updated_cursor),
        items
      )
      vim.fn.complete(start_col, items)
      finish()
    end)
  end)
end

function M.handle_trigger_key(buf, win)
  if vim.fn.pumvisible() == 1 then
    feed_insert_keys("<C-n>")
    return
  end

  if state.config and state.config.trigger == "tab" then
    M.complete_at_cursor(buf, win)
    return
  end

  insert_literal_tab(buf, win)
end

function M.schedule_auto_complete(buf, win)
  if not state.config or state.config.trigger ~= "auto" then
    return
  end

  state.auto_request_generation = state.auto_request_generation + 1
  local generation = state.auto_request_generation
  local delay = math.max(0, math.floor(tonumber(state.config.debounce_ms) or 0))

  vim.defer_fn(function()
    if generation ~= state.auto_request_generation then
      return
    end

    M.complete_at_cursor(buf, win, {
      allow_select_next = false,
      insert_tab_on_empty = false,
      preserve_input = true,
      auto = true,
    })
  end, delay)
end

function M.cancel_auto_complete()
  state.auto_request_generation = state.auto_request_generation + 1
end

function M.dismiss()
  M.cancel_auto_complete()
  close_completion_menu(true)
end

---@return table
function M.get_debug_state()
  return {
    job_id = state.job_id,
    ready = state.ready,
    pending = state.pending ~= nil,
    session_cwd = state.session_cwd,
    queued_completion = state.queued_completion ~= nil,
  }
end

function M.select_next()
  if vim.fn.pumvisible() == 1 then
    feed_insert_keys("<C-n>")
    return true
  end

  return false
end

function M.select_prev()
  if vim.fn.pumvisible() == 1 then
    feed_insert_keys("<C-p>")
    return true
  end

  return false
end

function M.confirm()
  if vim.fn.pumvisible() == 1 then
    feed_insert_keys("<C-y>")
    return true
  end

  return false
end

return M
