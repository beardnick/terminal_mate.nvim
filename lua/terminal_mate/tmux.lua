--- tmux interaction layer for terminal_mate.nvim
local M = {}

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
  -- Use set-buffer to load text, then paste-buffer to insert it into the pane
  -- The -p flag pastes and deletes the buffer afterwards
  M.exec({ "set-buffer", "--", text })
  M.exec({ "paste-buffer", "-t", pane_id, "-d", "-p" })
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
