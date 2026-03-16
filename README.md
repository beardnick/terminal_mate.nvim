# terminal_mate.nvim

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A Neovim plugin that provides a [Warp](https://www.warp.dev/)-like terminal workflow inside Neovim. By default it uses Neovim's built-in terminal and opens the terminal split below your editor; tmux remains available as a fallback backend.

## Features

- **Neovim-first backend**: `backend = "auto"` prefers Neovim's built-in terminal and falls back to tmux when needed.
- **Stable terminal layout**: Managed Neovim terminals open in a dedicated split below the editor by default and keep that placement when you hide, reopen, or switch instances.
- **Multiple terminal instances**: Create multiple managed Neovim terminals and keep sending to the most recently active one.
- **Slim terminal list sidebar**: Managed Neovim terminals get a compact right-side list with shell labels, active-row emphasis, and click/`Enter` switching.
- **Send Entire Buffer**: Press `Ctrl+S` to send all commands in the buffer at once, then clear the input buffer automatically.
- **Send Visual Selections From Anywhere**: Use the visual send action in any buffer, regardless of filetype.
- **Terminal Control**: Create, hide, clear, or interrupt terminals without leaving the input buffer.
- **Zsh History Integration**: Browse and search your zsh/bash history directly from the input buffer.
- **Zsh-like Autosuggestions**: Show history-backed ghost text in the input buffer and accept it with `<Right>`.
- **Native Zsh Completion**: Completion suggestions open automatically in the input buffer through a real background zsh session, with an option to switch back to `<Tab>`-triggered completion.
- **Multi-line Commands**: Write complex multi-line scripts in the buffer and send them as command blocks.
- **tmux Fallback**: When you select the tmux backend, TerminalMate reuses an adjacent tmux pane when possible or creates one above the current pane.

## Requirements

- [Neovim](https://neovim.io/) >= 0.8
- [zsh](https://www.zsh.org/) is recommended for native TerminalMate completion inside the input buffer
- [tmux](https://github.com/tmux/tmux) is optional and only required when using the tmux backend or fallback path

## Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "beardnick/terminal_mate.nvim",
  config = function()
    require("terminal_mate").setup()
  end,
}
```

## Usage

1. Run `:TerminalMateOpen` or press `<leader>to` to open the terminal pane only.
2. Run `:TerminalMateMode` or press `<leader>tm` to enter the dedicated TerminalMate input buffer.
3. With the default `auto` backend, the latest managed Neovim terminal opens below the editor. If none exists, TerminalMate creates one.
4. When the Neovim backend is visible, a compact terminal list appears on the right side of the terminal split.
5. The active row is emphasized with a stronger highlight and a slim left marker.
6. Click a terminal row or press `Enter` on it to switch to that managed terminal.
7. Type your command(s) in the input buffer.
8. Matching history entries appear as ghost text at the cursor, similar to zsh autosuggestions.
9. Press `<Right>` to accept the current history suggestion; zsh-backed completion opens automatically as you type and refreshes after edits like backspace.
10. Use `<Tab>` / `<S-Tab>` or `<Up>` / `<Down>` to move through the completion menu when it is visible; press `<Enter>` to confirm the current item.
11. Switch to `completion.trigger = "tab"` if you prefer manual completion.
12. Common insert-mode editing keys follow command-line habits such as `<C-a>`, `<C-e>`, `<C-w>`, `<C-u>`, `<C-k>`, and `<M-b>` / `<M-f>`.
13. Press `Ctrl+S` to send the buffer to the latest active terminal.
14. The buffer is cleared and you stay ready for the next command.

### Managing Multiple Terminals

- Run `:TerminalMateNew` or press `<leader>tn` to create a new managed Neovim terminal instance.
- Run `:TerminalMateNextTerminal` / `:TerminalMatePrevTerminal` to cycle between managed Neovim terminal instances.
- Run `:TerminalMateSwitch {id}` to jump directly to a managed Neovim terminal by id.
- Run `:TerminalMateHide` or press `<leader>th` to hide the current managed Neovim terminal without killing it.
- `:TerminalMateOpen` shows the latest active terminal again.
- The active terminal row is highlighted in the right-side list whenever the Neovim backend is visible.
- Send operations prefer the latest active terminal, fall back to the next live terminal if needed, and create a new one when no managed terminal remains.

### Sending a Visual Selection From Any Buffer

1. Select text in Visual mode from any buffer.
2. Press the configured visual send keymap or run `:TerminalMateSendSelection`.
3. If TerminalMate already manages terminals, the selection is sent to the latest active one.
4. Otherwise, TerminalMate creates or discovers a target using the active backend mode.
5. In tmux mode, adjacent pane detection prefers above, then below, then left, then right.

### History Navigation

- Press `Up` / `Down` to browse through previous commands (zsh history + session history) when the completion menu is not visible.
- Press `<Right>` to accept the current inline autosuggestion from history.
- Press `Ctrl+R` to open a fuzzy search picker over your entire command history.

### Native Zsh Completion

- Completion suggestions open automatically inside the TerminalMate input buffer as you type.
- Backspacing or other in-buffer edits refresh the completion candidates after a short debounce.
- Completion follows the current working directory of the active TerminalMate shell, so `cd` in the terminal updates later path suggestions.
- In tmux mode, completion prefers the pane currently adjacent to Neovim, so switching terminal panes updates later path suggestions too.
- TerminalMate reuses your normal zsh completion setup, including `compinit`, `compdef`, git completion, and any `bashcompinit` / `complete` configuration loaded from your shell startup files.
- Directory and file completion work the same way as your regular zsh prompt, so commands like `cd`, `ls`, script paths, and redirects complete naturally.
- Partial option queries widen the shell lookup before filtering, so inputs like `curl -d` can still surface both `-d` and `--data`.
- When multiple matches are available, the first candidate is preselected so you can tab through results immediately.
- Use `<Up>` / `<Down>` or `<Tab>` / `<S-Tab>` to move through the popup menu, and `<Enter>` to accept the current completion.
- Set `completion.trigger = "tab"` if you prefer to open completion manually with the configured trigger key.
- `<S-Tab>` moves backward through the popup menu when multiple matches are available.

## Commands

| Command | Description |
|---------|-------------|
| `:TerminalMateOpen` | Open the terminal pane |
| `:TerminalMateMode` | Enter terminal_mate input mode |
| `:TerminalMateNew` | Create a new terminal instance |
| `:TerminalMateSwitch {id}` | Switch to a specific managed terminal instance |
| `:TerminalMateNextTerminal` | Switch to the next managed terminal instance |
| `:TerminalMatePrevTerminal` | Switch to the previous managed terminal instance |
| `:TerminalMateHide` | Hide the current managed Neovim terminal without killing it |
| `:TerminalMateClose` | Close the terminal pane |
| `:TerminalMateToggle` | Toggle the current terminal pane visibility |
| `:TerminalMateSend [cmd]` | Send current buffer or `[cmd]` to the terminal |
| `:TerminalMateSendSelection` | Send the current visual selection to the active backend |
| `:TerminalMateClear` | Clear the terminal screen |
| `:TerminalMateInterrupt` | Send Ctrl-C to the terminal |
| `:TerminalMateHistorySearch` | Open history search picker |
| `:TerminalMateHistoryPrev` | Navigate to older history entry |
| `:TerminalMateHistoryNext` | Navigate to newer history entry |

## Default Keymaps

Keymaps active in the `terminal_mate` input buffer:

| Keymap | Mode | Description |
|--------|------|-------------|
| `<C-s>` | Normal / Insert | Send all buffer content to terminal |
| `<leader>ts` | Visual | Send visual selection to terminal |
| `<leader>tn` | Normal | Create a new terminal instance |
| `<leader>th` | Normal | Hide the current terminal pane |
| `<Up>` | Normal / Insert | Previous command from history / previous completion item |
| `<Down>` | Normal / Insert | Next command from history / next completion item |
| `<C-a>` | Insert | Move to start of current line |
| `<C-e>` | Insert | Move to end of current line |
| `<C-b>` | Insert | Move left |
| `<C-f>` | Insert | Move right |
| `<M-b>` | Insert | Move backward by shell word |
| `<M-f>` | Insert | Move forward by shell word |
| `<C-w>` | Insert | Delete previous shell word |
| `<C-u>` | Insert | Delete to start of current line |
| `<C-k>` | Insert | Delete to end of current line |
| `<C-d>` | Insert | Delete character under cursor |
| `<C-r>` | Normal / Insert | Search command history (fuzzy picker) |
| `<Right>` | Insert | Accept the current autosuggestion |
| `<CR>` | Insert | Confirm current completion item / insert newline |
| `<Tab>` | Insert | Move to next completion item / trigger completion when `completion.trigger = "tab"` |
| `<S-Tab>` | Insert | Move to previous completion item |
| `<C-l>` | Normal | Clear the terminal screen |
| `<C-c>` | Normal | Send interrupt signal (Ctrl-C) |

Global keymaps:

| Keymap | Mode | Description |
|--------|------|-------------|
| `<leader>ts` | Visual | Send selected text to terminal from any buffer |
| `<leader>to` | Normal | Open the terminal pane |
| `<leader>tm` | Normal | Enter terminal_mate input mode |
| `<leader>tn` | Normal | Create a new terminal instance |
| `<leader>th` | Normal | Hide the current terminal pane |
| `<leader>tc` | Normal | Close the terminal pane |
| `<leader>tt` | Normal | Toggle terminal pane visibility (without entering input mode) |

## Configuration

```lua
require("terminal_mate").setup({
  -- "auto" prefers Neovim's built-in terminal, then falls back to tmux.
  backend = "auto",
  -- Percentage of the editor height used by the terminal pane.
  split_percent = 50,
  -- Shell to run in the terminal pane (nil = default shell).
  shell = nil,
  -- Close managed tmux panes when exiting Neovim.
  close_on_exit = true,
  -- Clear the input buffer after sending commands.
  clear_input = true,

  keymap = {
    send_line = "<C-s>",
    send_visual = "<leader>ts",
    open = "<leader>to",
    mate_mode = "<leader>tm",
    new_terminal = "<leader>tn",
    hide = "<leader>th",
    close = "<leader>tc",
    toggle = "<leader>tt",
    clear = "<C-l>",
    interrupt = "<C-c>",
    history_prev = "<Up>",
    history_next = "<Down>",
    history_search = "<C-r>",
    accept_suggestion = "<Right>",
    completion_trigger = "<Tab>",
    completion_prev = "<S-Tab>",
  },

  buffer = {
    filetype = "terminal_mate",
    bufname = "[TerminalMate]",
  },

  completion = {
    enabled = true,
    -- "auto" = open completion as you type, "tab" = trigger with keymap.completion_trigger.
    trigger = "auto",
    -- Debounce for automatic completion refreshes, including backspace updates.
    debounce_ms = 120,
    -- nil = use $SHELL when it is zsh, otherwise fall back to `zsh`.
    shell = nil,
  },
})
```

### Backend Modes

- `auto`: prefer Neovim's built-in terminal, fall back to tmux if the Neovim backend is unavailable.
- `nvim`: always use Neovim's built-in terminal split.
- `tmux`: always use tmux panes.

## How History Works

When the terminal pane is first opened, the plugin loads your zsh history from `$HISTFILE` (defaults to `~/.zsh_history`). If that file is not found, it falls back to `~/.bash_history`. Commands you send during the session are also added to the in-memory history. The history is deduplicated, keeping the most recent occurrence of each command, and the newest prefix match is used for inline autosuggestions.

## License

This project is licensed under the MIT License. See the [LICENSE](./LICENSE) file for details.
