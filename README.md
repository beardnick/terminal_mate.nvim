# terminal_mate.nvim

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A Neovim plugin that provides a [Warp](https://www.warp.dev/)-like terminal workflow inside Neovim. By default it uses Neovim's built-in terminal and opens the terminal split below your editor; tmux remains available as a fallback backend.

## Features

- **Neovim-first backend**: `backend = "auto"` prefers Neovim's built-in terminal and falls back to tmux when needed.
- **Terminal below the editor**: `:TerminalMateOpen` keeps you in a dedicated input buffer and opens the execution terminal underneath by default.
- **Send Entire Buffer**: Press `Ctrl+S` to send all commands in the buffer at once, then clear the input buffer automatically.
- **Send Visual Selections From Anywhere**: Use the visual send action in any buffer, regardless of filetype.
- **Terminal Control**: Clear the terminal or send `Ctrl-C` without leaving the input buffer.
- **Zsh History Integration**: Browse and search your zsh/bash history directly from the input buffer.
- **Multi-line Commands**: Write complex multi-line scripts in the buffer and send them as command blocks.
- **tmux Fallback**: When you select the tmux backend, TerminalMate reuses an adjacent tmux pane when possible or creates one above the current pane.

## Requirements

- [Neovim](https://neovim.io/) >= 0.8
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

1. Run `:TerminalMateOpen` or press `<leader>to`.
2. TerminalMate opens a dedicated input buffer and starts the configured backend.
3. With the default `auto` backend, a Neovim terminal split opens below the editor.
4. Type your command(s) in the input buffer.
5. Press `Ctrl+S` to send the buffer to the terminal.
6. The buffer is cleared and you stay ready for the next command.

### Sending a Visual Selection From Any Buffer

1. Select text in Visual mode from any buffer.
2. Press the configured visual send keymap or run `:TerminalMateSendSelection`.
3. If TerminalMate already manages a terminal, the selection is sent there.
4. Otherwise, TerminalMate creates or discovers a target using the active backend mode.
5. In tmux mode, adjacent pane detection prefers above, then below, then left, then right.

### History Navigation

- Press `Up` / `Down` to browse through previous commands (zsh history + session history).
- Press `Ctrl+R` to open a fuzzy search picker over your entire command history.

## Commands

| Command | Description |
|---------|-------------|
| `:TerminalMateOpen` | Open the terminal pane |
| `:TerminalMateClose` | Close the terminal pane |
| `:TerminalMateToggle` | Toggle the terminal pane |
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
| `<Up>` | Normal / Insert | Previous command from history |
| `<Down>` | Normal / Insert | Next command from history |
| `<C-r>` | Normal / Insert | Search command history (fuzzy picker) |
| `<C-l>` | Normal | Clear the terminal screen |
| `<C-c>` | Normal | Send interrupt signal (Ctrl-C) |

Global keymaps:

| Keymap | Mode | Description |
|--------|------|-------------|
| `<leader>ts` | Visual | Send selected text to terminal from any buffer |
| `<leader>to` | Normal | Open the terminal pane |
| `<leader>tc` | Normal | Close the terminal pane |
| `<leader>tt` | Normal | Toggle the terminal pane |

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
    close = "<leader>tc",
    toggle = "<leader>tt",
    clear = "<C-l>",
    interrupt = "<C-c>",
    history_prev = "<Up>",
    history_next = "<Down>",
    history_search = "<C-r>",
  },

  buffer = {
    filetype = "terminal_mate",
    bufname = "[TerminalMate]",
  },
})
```

### Backend Modes

- `auto`: prefer Neovim's built-in terminal, fall back to tmux if the Neovim backend is unavailable.
- `nvim`: always use Neovim's built-in terminal split.
- `tmux`: always use tmux panes.

## How History Works

When the terminal pane is first opened, the plugin loads your zsh history from `$HISTFILE` (defaults to `~/.zsh_history`). If that file is not found, it falls back to `~/.bash_history`. Commands you send during the session are also added to the in-memory history. The history is deduplicated, keeping the most recent occurrence of each command.

## License

This project is licensed under the MIT License. See the [LICENSE](./LICENSE) file for details.
