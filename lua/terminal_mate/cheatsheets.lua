local M = {}

local SESSION_NS = vim.api.nvim_create_namespace("TerminalMateCheatsheetSession")
local DISPLAY_NS = vim.api.nvim_create_namespace("TerminalMateCheatsheetDisplay")

local state = {
  config = nil,
  active = nil,
  completion_generation = 0,
  command_cache = {},
}

local DEFAULT_FILE_HEADER = {
  "return {",
  "  -- {",
  '  --   description = "Checkout a git branch",',
  '  --   template = "git checkout {{branch}}",',
  "  --   variables = {",
  '  --     branch = { command = "git branch --format=\'%(refname:short)\'" },',
  "  --   },",
  "  -- },",
  "}",
}

local function notify(msg, level)
  if state.config and type(state.config.notify) == "function" then
    state.config.notify(msg, level)
    return
  end

  vim.notify("[TerminalMate] " .. msg, level or vim.log.levels.INFO)
end

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

local function fuzzy_score(str, query)
  if query == "" then
    return 1
  end

  local lower_str = str:lower()
  local lower_q = query:lower()
  local prefix_at = lower_str:find(lower_q, 1, true)
  if prefix_at == 1 then
    return 100000 - #str
  end
  if prefix_at then
    return 80000 - (prefix_at * 100) - #str
  end

  local si = 1
  local gaps = 0
  local last = 0
  for qi = 1, #lower_q do
    local ch = lower_q:sub(qi, qi)
    local found = lower_str:find(ch, si, true)
    if not found then
      return nil
    end
    if last > 0 then
      gaps = gaps + (found - last - 1)
    end
    last = found
    si = found + 1
  end

  return 50000 - (gaps * 10) - #str
end

local function sorted_pairs(tbl)
  local keys = vim.tbl_keys(tbl or {})
  table.sort(keys)

  local index = 0
  return function()
    index = index + 1
    local key = keys[index]
    if key == nil then
      return nil
    end
    return key, tbl[key]
  end
end

local function default_path()
  return vim.fs.normalize(vim.fn.stdpath("config") .. "/terminal_mate_cheatsheets.lua")
end

local function current_path()
  local configured = state.config and state.config.path or nil
  if type(configured) == "string" and configured ~= "" then
    return vim.fs.normalize(vim.fn.expand(configured))
  end
  return default_path()
end

local function ensure_file_exists()
  local path = current_path()
  if vim.fn.filereadable(path) == 1 then
    return path
  end

  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(DEFAULT_FILE_HEADER, path)
  return path
end

local function identifier_key(key)
  if key:match("^[A-Za-z_][A-Za-z0-9_]*$") then
    return key
  end
  return "[" .. string.format("%q", key) .. "]"
end

local function render_cheatsheet_file(entries)
  local lines = { "return {" }

  for _, entry in ipairs(entries) do
    table.insert(lines, "  {")
    if type(entry.name) == "string" and entry.name ~= "" then
      table.insert(lines, "    name = " .. string.format("%q", entry.name) .. ",")
    end
    table.insert(lines, "    description = " .. string.format("%q", entry.description or "") .. ",")
    table.insert(lines, "    template = " .. string.format("%q", entry.template or "") .. ",")

    local variables = entry.variables or {}
    if next(variables) ~= nil then
      table.insert(lines, "    variables = {")
      for key, variable in sorted_pairs(variables) do
        local parts = {}
        if type(variable.command) == "string" and variable.command ~= "" then
          table.insert(parts, "command = " .. string.format("%q", variable.command))
        end
        if type(variable.default) == "string" then
          table.insert(parts, "default = " .. string.format("%q", variable.default))
        end
        if type(variable.description) == "string" and variable.description ~= "" then
          table.insert(parts, "description = " .. string.format("%q", variable.description))
        end
        if type(variable.items) == "table" and #variable.items > 0 then
          local item_parts = {}
          for _, item in ipairs(variable.items) do
            table.insert(item_parts, string.format("%q", tostring(item)))
          end
          table.insert(parts, "items = { " .. table.concat(item_parts, ", ") .. " }")
        end

        if #parts == 0 then
          table.insert(lines, "      " .. identifier_key(key) .. " = {},")
        else
          table.insert(lines, "      " .. identifier_key(key) .. " = { " .. table.concat(parts, ", ") .. " },")
        end
      end
      table.insert(lines, "    },")
    end

    table.insert(lines, "  },")
  end

  table.insert(lines, "}")
  return lines
end

local function load_entries()
  local path = current_path()
  if vim.fn.filereadable(path) ~= 1 then
    return {}
  end

  local chunk, load_err = loadfile(path)
  if not chunk then
    notify("Failed to load cheatsheets: " .. tostring(load_err), vim.log.levels.ERROR)
    return {}
  end

  local ok, result = pcall(chunk)
  if not ok then
    notify("Failed to evaluate cheatsheets: " .. tostring(result), vim.log.levels.ERROR)
    return {}
  end

  if type(result) ~= "table" then
    notify("Cheatsheet file must return a list of entries.", vim.log.levels.ERROR)
    return {}
  end

  local entries = {}
  for _, entry in ipairs(result) do
    if type(entry) == "table" and type(entry.description) == "string" and type(entry.template) == "string" then
      table.insert(entries, {
        name = type(entry.name) == "string" and entry.name or nil,
        description = entry.description,
        template = entry.template,
        variables = type(entry.variables) == "table" and vim.deepcopy(entry.variables) or {},
      })
    end
  end

  return entries
end

local function parse_placeholders(template)
  local placeholders = {}
  local names = {}
  local seen = {}
  local output = {}
  local output_len = 0
  local index = 1

  while true do
    local start_pos, end_pos, name = template:find("{{%s*([A-Za-z_][A-Za-z0-9_]*)%s*}}", index)
    if not start_pos then
      local literal = template:sub(index)
      table.insert(output, literal)
      output_len = output_len + #literal
      break
    end

    local literal = template:sub(index, start_pos - 1)
    table.insert(output, literal)
    output_len = output_len + #literal

    table.insert(placeholders, {
      name = name,
      start_offset = output_len,
      end_offset = output_len,
    })
    if not seen[name] then
      table.insert(names, name)
      seen[name] = true
    end

    index = end_pos + 1
  end

  return table.concat(output), placeholders, names
end

local function offset_to_position(text, offset)
  if offset <= 0 then
    return 0, 0
  end

  local row = 0
  local line_start = 1
  while true do
    local newline = text:find("\n", line_start, true)
    if not newline then
      return row, offset - (line_start - 1)
    end
    if offset <= newline then
      return row, offset - line_start + 1
    end
    row = row + 1
    line_start = newline + 1
  end
end

local function get_session()
  local session = state.active
  if not session or not session.buf or not vim.api.nvim_buf_is_valid(session.buf) then
    state.active = nil
    return nil
  end

  return session
end

local function get_mark_position(buf, mark_id)
  local pos = vim.api.nvim_buf_get_extmark_by_id(buf, SESSION_NS, mark_id, {})
  if type(pos) ~= "table" or #pos < 2 then
    return nil
  end
  return pos[1], pos[2]
end

local function get_placeholder_range(buf, placeholder)
  local start_row, start_col = get_mark_position(buf, placeholder.start_mark)
  local end_row, end_col = get_mark_position(buf, placeholder.end_mark)
  if start_row == nil or end_row == nil then
    return nil
  end

  return {
    start_row = start_row,
    start_col = start_col,
    end_row = end_row,
    end_col = end_col,
  }
end

local function cursor_in_range(cursor_row, cursor_col, range)
  if cursor_row < range.start_row or cursor_row > range.end_row then
    return false
  end

  if range.start_row == range.end_row then
    return cursor_col >= range.start_col and cursor_col <= range.end_col
  end

  if cursor_row == range.start_row then
    return cursor_col >= range.start_col
  end

  if cursor_row == range.end_row then
    return cursor_col <= range.end_col
  end

  return true
end

local function current_placeholder(buf, win)
  local session = get_session()
  if not session or session.buf ~= buf or not win or not vim.api.nvim_win_is_valid(win) then
    return nil, nil
  end

  local cursor = vim.api.nvim_win_get_cursor(win)
  local row = cursor[1] - 1
  local col = cursor[2]

  for index, placeholder in ipairs(session.placeholders) do
    local range = get_placeholder_range(buf, placeholder)
    if range and cursor_in_range(row, col, range) then
      session.active_index = index
      return placeholder, range
    end
  end

  local active = session.placeholders[session.active_index or 0]
  if not active then
    return nil, nil
  end

  return active, get_placeholder_range(buf, active)
end

local function placeholder_at_cursor(buf, win)
  local session = get_session()
  if not session or session.buf ~= buf or not win or not vim.api.nvim_win_is_valid(win) then
    return nil, nil
  end

  local cursor = vim.api.nvim_win_get_cursor(win)
  local row = cursor[1] - 1
  local col = cursor[2]

  for index, placeholder in ipairs(session.placeholders) do
    local range = get_placeholder_range(buf, placeholder)
    if range and cursor_in_range(row, col, range) then
      session.active_index = index
      return placeholder, range
    end
  end

  return nil, nil
end

local function is_insert_mode()
  local mode = vim.api.nvim_get_mode().mode
  return mode == "i" or mode == "ic" or mode == "ix"
end

local function close_popup_menu()
  if vim.fn.pumvisible() ~= 1 then
    return
  end
  pcall(vim.api.nvim_select_popupmenu_item, -1, false, true, {})
end

local function current_placeholder_text(buf, placeholder)
  local range = get_placeholder_range(buf, placeholder)
  if not range then
    return ""
  end

  local parts = vim.api.nvim_buf_get_text(
    buf,
    range.start_row,
    range.start_col,
    range.end_row,
    range.end_col,
    {}
  )
  return table.concat(parts, "\n")
end

local function current_shell()
  if state.config and type(state.config.shell_resolver) == "function" then
    local ok, shell = pcall(state.config.shell_resolver)
    if ok and type(shell) == "string" and shell ~= "" then
      return shell
    end
  end

  return vim.env.SHELL or vim.o.shell or "sh"
end

local function current_cwd()
  if state.config and type(state.config.cwd_resolver) == "function" then
    local ok, cwd = pcall(state.config.cwd_resolver)
    if ok and type(cwd) == "string" and cwd ~= "" then
      return cwd
    end
  end

  return vim.loop.cwd()
end

local function sanitize_command_items(lines)
  local items = {}
  local seen = {}
  for _, line in ipairs(lines) do
    local cleaned = vim.trim((line or ""):gsub("^%*%s*", ""))
    if cleaned ~= "" and not seen[cleaned] then
      seen[cleaned] = true
      table.insert(items, cleaned)
    end
  end
  return items
end

local function load_variable_items(variable)
  if type(variable) ~= "table" then
    return {}
  end

  if type(variable.items) == "table" and #variable.items > 0 then
    return sanitize_command_items(variable.items)
  end

  if type(variable.command) ~= "string" or variable.command == "" then
    return {}
  end

  local shell = current_shell()
  local cwd = current_cwd()
  local cache_key = table.concat({ shell, cwd, variable.command }, "\n")
  if state.command_cache[cache_key] then
    return state.command_cache[cache_key]
  end

  local result = vim.system({ shell, "-lc", variable.command }, {
    cwd = cwd,
    text = true,
  }):wait()

  if result.code ~= 0 then
    notify("Cheatsheet variable command failed: " .. variable.command, vim.log.levels.WARN)
    state.command_cache[cache_key] = {}
    return {}
  end

  local items = sanitize_command_items(vim.split(result.stdout or "", "\n", { plain = true }))
  state.command_cache[cache_key] = items
  return items
end

local function filtered_completion_items(items, query)
  local matches = {}
  for _, item in ipairs(items) do
    local score = fuzzy_score(item, query)
    if score ~= nil then
      table.insert(matches, {
        word = item,
        score = score,
      })
    end
  end

  table.sort(matches, function(left, right)
    if left.score ~= right.score then
      return left.score > right.score
    end
    return left.word < right.word
  end)

  local result = {}
  for _, match in ipairs(matches) do
    table.insert(result, {
      word = match.word,
      menu = "[cheatsheet]",
    })
  end
  return result
end

local function move_to_placeholder(win, index)
  local session = get_session()
  if not session or not vim.api.nvim_win_is_valid(win) then
    return false
  end

  local placeholder = session.placeholders[index]
  if not placeholder then
    return false
  end

  local range = get_placeholder_range(session.buf, placeholder)
  if not range then
    return false
  end

  session.active_index = index
  vim.api.nvim_win_set_cursor(win, { range.end_row + 1, range.end_col })
  M.refresh(session.buf, win)
  M.schedule_completion(session.buf, win)
  return true
end

function M.clear_active(buf)
  local session = get_session()
  if not session then
    return
  end

  if buf ~= nil and session.buf ~= buf then
    return
  end

  vim.api.nvim_buf_clear_namespace(session.buf, SESSION_NS, 0, -1)
  vim.api.nvim_buf_clear_namespace(session.buf, DISPLAY_NS, 0, -1)
  state.active = nil
  state.completion_generation = state.completion_generation + 1
end

function M.refresh(buf, win)
  local session = get_session()
  if not session or session.buf ~= buf or not vim.api.nvim_buf_is_valid(buf) then
    return false
  end

  if win and vim.api.nvim_win_is_valid(win) then
    current_placeholder(buf, win)
  end

  vim.api.nvim_buf_clear_namespace(buf, DISPLAY_NS, 0, -1)
  for index, placeholder in ipairs(session.placeholders) do
    local range = get_placeholder_range(buf, placeholder)
    if range then
      local active = index == session.active_index
      local text = current_placeholder_text(buf, placeholder)
      if text == "" then
        vim.api.nvim_buf_set_extmark(buf, DISPLAY_NS, range.start_row, range.start_col, {
          virt_text = {
            {
              placeholder.name,
              active and "TerminalMateCheatsheetActivePlaceholder" or "TerminalMateCheatsheetPlaceholder",
            },
          },
          virt_text_pos = "inline",
        })
      else
        vim.api.nvim_buf_set_extmark(buf, DISPLAY_NS, range.start_row, range.start_col, {
          end_row = range.end_row,
          end_col = range.end_col,
          hl_group = active and "TerminalMateCheatsheetActiveRange" or "TerminalMateCheatsheetRange",
        })
      end
    end
  end

  return true
end

function M.has_placeholder_context(buf, win)
  local placeholder = placeholder_at_cursor(buf, win)
  return placeholder ~= nil
end

function M.jump_next(win)
  if vim.fn.pumvisible() == 1 then
    return false
  end

  local session = get_session()
  if not session or #session.placeholders == 0 or not win or not vim.api.nvim_win_is_valid(win) then
    return false
  end

  local next_index = session.active_index + 1
  if next_index > #session.placeholders then
    next_index = 1
  end
  return move_to_placeholder(win, next_index)
end

function M.jump_prev(win)
  if vim.fn.pumvisible() == 1 then
    return false
  end

  local session = get_session()
  if not session or #session.placeholders == 0 or not win or not vim.api.nvim_win_is_valid(win) then
    return false
  end

  local prev_index = session.active_index - 1
  if prev_index < 1 then
    prev_index = #session.placeholders
  end
  return move_to_placeholder(win, prev_index)
end

function M.complete_at_cursor(buf, win)
  if not is_insert_mode() then
    return false
  end

  local placeholder, range = placeholder_at_cursor(buf, win)
  if not placeholder or not range then
    return false
  end

  local items = load_variable_items(placeholder.variable)
  if #items == 0 then
    close_popup_menu()
    return true
  end

  local query = current_placeholder_text(buf, placeholder)
  local completion_items = filtered_completion_items(items, query)
  if #completion_items == 0 then
    close_popup_menu()
    return true
  end

  vim.fn.complete(range.start_col + 1, completion_items)
  return true
end

function M.schedule_completion(buf, win)
  if not is_insert_mode() then
    close_popup_menu()
    return
  end

  local placeholder = placeholder_at_cursor(buf, win)
  if not placeholder then
    return
  end

  local variable = placeholder.variable or {}
  local has_source = (type(variable.command) == "string" and variable.command ~= "")
    or (type(variable.items) == "table" and #variable.items > 0)
  if not has_source then
    close_popup_menu()
    return
  end

  state.completion_generation = state.completion_generation + 1
  local generation = state.completion_generation
  local delay = math.max(0, math.floor(tonumber(state.config and state.config.debounce_ms or 0) or 0))

  vim.defer_fn(function()
    if generation ~= state.completion_generation then
      return
    end
    if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_win_is_valid(win) then
      return
    end
    M.complete_at_cursor(buf, win)
  end, delay)
end

local function create_session(buf, entry, output, placeholders)
  M.clear_active(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(output, "\n", { plain = true }))

  if #placeholders == 0 then
    return nil
  end

  local session = {
    buf = buf,
    entry = entry,
    placeholders = {},
    active_index = 1,
  }

  for _, placeholder in ipairs(placeholders) do
    local start_row, start_col = offset_to_position(output, placeholder.start_offset)
    local end_row, end_col = offset_to_position(output, placeholder.end_offset)
    table.insert(session.placeholders, {
      name = placeholder.name,
      variable = placeholder.variable or {},
      start_mark = vim.api.nvim_buf_set_extmark(buf, SESSION_NS, start_row, start_col, {
        right_gravity = false,
      }),
      end_mark = vim.api.nvim_buf_set_extmark(buf, SESSION_NS, end_row, end_col, {
        right_gravity = true,
      }),
    })
  end

  state.active = session
  return session
end

function M.apply_entry(entry, buf, win)
  if not entry or not buf or not vim.api.nvim_buf_is_valid(buf) then
    return false
  end

  local output, placeholders = parse_placeholders(entry.template)
  for _, placeholder in ipairs(placeholders) do
    placeholder.variable = type(entry.variables) == "table" and entry.variables[placeholder.name] or {}
  end

  local session = create_session(buf, entry, output, placeholders)
  if not session then
    return true
  end

  if win and vim.api.nvim_win_is_valid(win) then
    move_to_placeholder(win, 1)
  end
  return true
end

function M.edit_file()
  local path = ensure_file_exists()
  vim.cmd("edit " .. vim.fn.fnameescape(path))
end

function M.new_entry()
  ensure_file_exists()

  vim.ui.input({ prompt = "Cheatsheet description: " }, function(description)
    if not description or vim.trim(description) == "" then
      return
    end

    vim.ui.input({ prompt = "Cheatsheet template: " }, function(template)
      if not template or vim.trim(template) == "" then
        return
      end

      local _, _, names = parse_placeholders(template)
      local variables = {}

      local function prompt_variable(index)
        local name = names[index]
        if not name then
          local entries = load_entries()
          table.insert(entries, {
            description = description,
            template = template,
            variables = variables,
          })
          vim.fn.writefile(render_cheatsheet_file(entries), current_path())
          notify("Cheatsheet created. Edit the file to refine variable metadata.")
          return
        end

        vim.ui.input({ prompt = "Command for " .. name .. " (optional): " }, function(command)
          if command and vim.trim(command) ~= "" then
            variables[name] = {
              command = vim.trim(command),
            }
          else
            variables[name] = {}
          end
          prompt_variable(index + 1)
        end)
      end

      prompt_variable(1)
    end)
  end)
end

function M.search(buf, win)
  local entries = load_entries()
  if #entries == 0 then
    notify("No cheatsheets available. Use TerminalMateCheatsheetNew or edit the cheatsheet file first.", vim.log.levels.INFO)
    return
  end

  local caller_buf = buf
  local caller_win = win

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
    title = " Cheatsheets ",
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
    title = " Search description> ",
    title_pos = "left",
  })

  local picker = {
    query = "",
    filtered = vim.deepcopy(entries),
    selected = 1,
  }

  local function render()
    local lines = {}
    for _, item in ipairs(picker.filtered) do
      local template = item.template:gsub("\n", " \\ ")
      table.insert(lines, item.description .. " | " .. template)
    end
    vim.bo[results_buf].modifiable = true
    vim.api.nvim_buf_set_lines(results_buf, 0, -1, false, lines)
    vim.bo[results_buf].modifiable = false

    picker.selected = math.max(1, math.min(picker.selected, math.max(#picker.filtered, 1)))
    if #picker.filtered > 0 and vim.api.nvim_win_is_valid(results_win) then
      vim.api.nvim_win_set_cursor(results_win, { picker.selected, 0 })
    end
  end

  local function update_filter()
    picker.filtered = {}
    for _, item in ipairs(entries) do
      if fuzzy_match(item.description, picker.query) then
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
  end

  local function confirm()
    local choice = picker.filtered[picker.selected]
    close_picker()
    if not choice or not caller_buf or not vim.api.nvim_buf_is_valid(caller_buf) then
      return
    end

    local target_win = caller_win
    if not target_win or not vim.api.nvim_win_is_valid(target_win) or vim.api.nvim_win_get_buf(target_win) ~= caller_buf then
      for _, listed_win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(listed_win) == caller_buf then
          target_win = listed_win
          break
        end
      end
    end

    if target_win and vim.api.nvim_win_is_valid(target_win) then
      vim.api.nvim_set_current_win(target_win)
    end
    M.apply_entry(choice, caller_buf, target_win)
  end

  update_filter()
  vim.cmd("startinsert")

  local kopts = { buffer = input_buf, noremap = true, silent = true }
  vim.keymap.set({ "i", "n" }, "<Esc>", close_picker, kopts)
  vim.keymap.set("i", "<C-c>", close_picker, kopts)
  vim.keymap.set({ "i", "n" }, "<CR>", confirm, kopts)
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
      vim.schedule(close_picker)
    end,
  })
end

function M.setup(opts)
  state.config = opts or {}
  state.command_cache = {}

  vim.api.nvim_set_hl(0, "TerminalMateCheatsheetPlaceholder", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "TerminalMateCheatsheetActivePlaceholder", { default = true, link = "PmenuSel" })
  vim.api.nvim_set_hl(0, "TerminalMateCheatsheetRange", { default = true, link = "Visual" })
  vim.api.nvim_set_hl(0, "TerminalMateCheatsheetActiveRange", { default = true, link = "IncSearch" })
end

return M
