--- tmux interaction layer for terminal_mate.nvim
local M = {}

local function overlap_length(a_start, a_size, b_start, b_size)
  local overlap_start = math.max(a_start, b_start)
  local overlap_end = math.min(a_start + a_size, b_start + b_size)
  return math.max(0, overlap_end - overlap_start)
end

--- Check if we are running inside tmux
---@return boolean
function M.is_tmux()
  return vim.env.TMUX ~= nil and vim.env.TMUX ~= ""
end

--- Execute a tmux command and return the output
---@param args string[] tmux subcommand arguments
---@return string output
---@return number exit_code
function M.exec(args)
  local cmd = vim.list_extend({ "tmux" }, args)
  local result = vim.fn.system(cmd)
  local exit_code = vim.v.shell_error
  return vim.trim(result), exit_code
end

--- Get the current pane ID (the pane running nvim)
---@return string|nil pane_id
function M.current_pane_id()
  local output, code = M.exec({ "display-message", "-p", "#{pane_id}" })
  if code ~= 0 then
    return nil
  end
  return output
end

--- Get the current tmux window ID
---@return string|nil window_id
function M.current_window_id()
  local output, code = M.exec({ "display-message", "-p", "#{window_id}" })
  if code ~= 0 then
    return nil
  end
  return output
end

--- List panes in a tmux window with geometry information
---@param window_id string|nil
---@return table[]
function M.list_panes(window_id)
  local args = {
    "list-panes",
    "-F",
    table.concat({
      "#{pane_id}",
      "#{pane_left}",
      "#{pane_top}",
      "#{pane_width}",
      "#{pane_height}",
      "#{pane_active}",
    }, "\t"),
  }
  if window_id and window_id ~= "" then
    vim.list_extend(args, { "-t", window_id })
  end

  local output, code = M.exec(args)
  if code ~= 0 or output == "" then
    return {}
  end

  local panes = {}
  for line in output:gmatch("[^\n]+") do
    local pane_id, left, top, width, height, active = line:match(
      "^([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)$"
    )
    if pane_id then
      table.insert(panes, {
        pane_id = pane_id,
        left = tonumber(left),
        top = tonumber(top),
        width = tonumber(width),
        height = tonumber(height),
        active = active == "1",
      })
    end
  end

  return panes
end

--- Find an adjacent pane in the current tmux window.
--- Preference order is above, below, left, then right.
---@param pane_id string
---@return string|nil adjacent_pane_id
---@return string|nil direction
function M.find_adjacent_pane(pane_id)
  local window_id = M.current_window_id()
  if not window_id then
    return nil, nil
  end

  local panes = M.list_panes(window_id)
  local current
  for _, pane in ipairs(panes) do
    if pane.pane_id == pane_id then
      current = pane
      break
    end
  end

  if not current then
    return nil, nil
  end

  local best = {
    up = nil,
    down = nil,
    left = nil,
    right = nil,
  }

  for _, pane in ipairs(panes) do
    if pane.pane_id ~= current.pane_id then
      local horizontal_overlap = overlap_length(current.left, current.width, pane.left, pane.width)
      local vertical_overlap = overlap_length(current.top, current.height, pane.top, pane.height)

      if pane.top + pane.height == current.top and horizontal_overlap > 0 then
        if not best.up or horizontal_overlap > best.up.score then
          best.up = { pane_id = pane.pane_id, score = horizontal_overlap }
        end
      elseif current.top + current.height == pane.top and horizontal_overlap > 0 then
        if not best.down or horizontal_overlap > best.down.score then
          best.down = { pane_id = pane.pane_id, score = horizontal_overlap }
        end
      elseif pane.left + pane.width == current.left and vertical_overlap > 0 then
        if not best.left or vertical_overlap > best.left.score then
          best.left = { pane_id = pane.pane_id, score = vertical_overlap }
        end
      elseif current.left + current.width == pane.left and vertical_overlap > 0 then
        if not best.right or vertical_overlap > best.right.score then
          best.right = { pane_id = pane.pane_id, score = vertical_overlap }
        end
      end
    end
  end

  for _, direction in ipairs({ "up", "down", "left", "right" }) do
    if best[direction] then
      return best[direction].pane_id, direction
    end
  end

  return nil, nil
end

--- Split window above the current pane (terminal on top, nvim stays at bottom)
---@param percent number percentage for the new (upper) pane
---@param shell string|nil shell command to run
---@return string|nil pane_id of the new terminal pane
function M.split_above(percent, shell)
  local args = {
    "split-window",
    "-bv",                    -- -b: before (above), -v: vertical split
    "-p", tostring(percent),  -- percentage for the new pane
    "-d",                     -- don't switch focus to new pane
    "-P",                     -- print pane info
    "-F", "#{pane_id}",       -- format: just the pane id
  }
  if shell and shell ~= "" then
    table.insert(args, shell)
  end
  local output, code = M.exec(args)
  if code ~= 0 then
    return nil
  end
  return vim.trim(output)
end

--- Send keys (a command string) to a target pane
---@param pane_id string target pane identifier
---@param text string the text/command to send
---@param press_enter boolean whether to press Enter after sending
function M.send_keys(pane_id, text, press_enter)
  -- Use literal flag (-l) to send text as-is, then send Enter separately
  local args = { "send-keys", "-t", pane_id, "-l", text }
  M.exec(args)
  if press_enter then
    M.exec({ "send-keys", "-t", pane_id, "Enter" })
  end
end

--- Send a complete text block to a target pane using set-buffer + paste-buffer.
--- This preserves multi-line commands with backslash continuations intact,
--- because the text is pasted as-is without line-by-line Enter presses.
---@param pane_id string target pane identifier
---@param text string the full text block to send
---@param press_enter boolean whether to press Enter after pasting
function M.send_text(pane_id, text, press_enter)
  local buffer_name = string.format(
    "terminal_mate_%s_%s",
    pane_id:gsub("[^%w]", ""),
    tostring((vim.loop and vim.loop.hrtime and vim.loop.hrtime()) or os.time())
  )

  -- Use a temporary named tmux buffer so multi-line text is pasted atomically
  -- without clobbering the user's default tmux paste buffer.
  M.exec({ "set-buffer", "-b", buffer_name, "--", text })
  M.exec({ "paste-buffer", "-b", buffer_name, "-t", pane_id, "-d", "-p" })
  if press_enter then
    M.exec({ "send-keys", "-t", pane_id, "Enter" })
  end
end

--- Send a special key (like C-c, C-l) to a target pane
---@param pane_id string target pane identifier
---@param key string the key to send (e.g., "C-c", "C-l")
function M.send_special_key(pane_id, key)
  M.exec({ "send-keys", "-t", pane_id, key })
end

--- Check if a pane still exists
---@param pane_id string
---@return boolean
function M.pane_exists(pane_id)
  local _, code = M.exec({ "has-session", "-t", pane_id })
  if code ~= 0 then
    -- Fallback: try listing panes
    local output, code2 = M.exec({ "list-panes", "-F", "#{pane_id}" })
    if code2 ~= 0 then
      return false
    end
    for line in output:gmatch("[^\n]+") do
      if vim.trim(line) == pane_id then
        return true
      end
    end
    return false
  end
  return true
end

--- Kill (close) a pane
---@param pane_id string
function M.kill_pane(pane_id)
  M.exec({ "kill-pane", "-t", pane_id })
end

--- Resize a pane to a given percentage of the window height
---@param pane_id string target pane identifier
---@param percent number percentage of total window height
function M.resize_pane_percent(pane_id, percent)
  M.exec({ "resize-pane", "-t", pane_id, "-y", tostring(percent) .. "%" })
end

--- Get the current height of a pane in rows
---@param pane_id string
---@return number|nil height
function M.get_pane_height(pane_id)
  local output, code = M.exec({
    "display-message", "-t", pane_id, "-p", "#{pane_height}"
  })
  if code ~= 0 then
    return nil
  end
  return tonumber(output)
end

--- Get the total window height in rows
---@return number|nil height
function M.get_window_height()
  local output, code = M.exec({
    "display-message", "-p", "#{window_height}"
  })
  if code ~= 0 then
    return nil
  end
  return tonumber(output)
end

--- Resize a pane to a specific number of rows
---@param pane_id string
---@param rows number
function M.resize_pane_rows(pane_id, rows)
  M.exec({ "resize-pane", "-t", pane_id, "-y", tostring(rows) })
end

--- Scroll the pane to the bottom (exit copy mode if active)
---@param pane_id string
function M.scroll_to_bottom(pane_id)
  M.exec({ "send-keys", "-t", pane_id, "q" })
  -- Cancel any copy mode first, then it's at the bottom
  M.exec({ "copy-mode", "-t", pane_id })
  M.exec({ "send-keys", "-t", pane_id, "q" })
end

return M
