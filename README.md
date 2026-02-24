# terminal_mate.nvim

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A Neovim plugin that provides a [Warp](https://www.warp.dev/)-like terminal experience by integrating with [tmux](https://github.com/tmux/tmux). It creates a split-pane layout where you can type commands in a dedicated Neovim buffer and send them to an adjacent tmux pane for execution.

## Features

- **Warp-like Layout**: A large terminal pane at the top for output, and a slim Neovim buffer at the bottom for command input.
- **Send Entire Buffer**: Press `Ctrl+S` to send all commands in the buffer at once, then the buffer is cleared automatically.
- **Stay in Current Mode**: After sending, you remain in whatever mode you were in (insert or normal).
- **Zsh History Integration**: Browse and search your zsh/bash history directly from the input buffer.
- **Multi-line Commands**: Write complex multi-line scripts in the buffer and send them all at once.
- **Seamless tmux Integration**: Automatically manages tmux panes for you.
- **Configurable**: Customize keymaps, pane size, and more.

## Requirements

- [Neovim](https://neovim.io/) >= 0.8
- [tmux](https://github.com/tmux/tmux)
- You must be running Neovim from within a tmux session.

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

1.  Run Neovim inside a tmux session.
2.  Run `:TerminalMateOpen` or press `<leader>to`.
3.  A new tmux pane appears above; Neovim switches to a dedicated input buffer below.
4.  Type your command(s) in the buffer (multi-line is supported).
5.  Press `Ctrl+S` to send **all buffer content** to the terminal pane.
6.  The buffer is cleared and you stay in your current mode, ready for the next command.

### History Navigation

- Press `Up` / `Down` to browse through previous commands (zsh history + session history).
- Press `Ctrl+R` to open a fuzzy search picker over your entire command history.

### Commands

| Command | Description |
|---------|-------------|
| `:TerminalMateOpen` | Open the terminal pane |
| `:TerminalMateClose` | Close the terminal pane |
| `:TerminalMateToggle` | Toggle the terminal pane |
| `:TerminalMateSend [cmd]` | Send current buffer or `[cmd]` to the terminal |
| `:TerminalMateClear` | Clear the terminal screen |
| `:TerminalMateInterrupt` | Send Ctrl-C to the terminal |
| `:TerminalMateHistorySearch` | Open history search picker |
| `:TerminalMateHistoryPrev` | Navigate to older history entry |
| `:TerminalMateHistoryNext` | Navigate to newer history entry |

### Default Keymaps

Keymaps active in the `terminal_mate` input buffer:

| Keymap   | Mode            | Description                             |
|----------|-----------------|-----------------------------------------|
| `<C-s>`  | Normal / Insert | Send all buffer content to terminal     |
| `<C-s>`  | Visual          | Send visual selection to terminal       |
| `<Up>`   | Normal / Insert | Previous command from history           |
| `<Down>` | Normal / Insert | Next command from history               |
| `<C-r>`  | Normal / Insert | Search command history (fuzzy picker)   |
| `<C-l>`  | Normal          | Clear the terminal screen               |
| `<C-c>`  | Normal          | Send interrupt signal (Ctrl-C)          |

Global keymaps:

| Keymap        | Mode   | Description              |
|---------------|--------|--------------------------|
| `<leader>to`  | Normal | Open the terminal pane   |
| `<leader>tc`  | Normal | Close the terminal pane  |
| `<leader>tt`  | Normal | Toggle the terminal pane |

## Configuration

```lua
require("terminal_mate").setup({
  -- Percentage of screen the top terminal pane occupies
  split_percent = 80,
  -- Shell to run in the new pane (nil = default shell)
  shell = nil,
  -- Close terminal pane when exiting Neovim
  close_on_exit = true,
  -- Clear the input buffer after sending commands
  clear_input = true,

  keymap = {
    -- Send all buffer content to terminal
    send_line = "<C-s>",
    send_visual = "<C-s>",
    -- Pane management
    open = "<leader>to",
    close = "<leader>tc",
    toggle = "<leader>tt",
    -- Terminal control
    clear = "<C-l>",
    interrupt = "<C-c>",
    -- History navigation
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

## How History Works

When the terminal pane is first opened, the plugin loads your zsh history from `$HISTFILE` (defaults to `~/.zsh_history`). If that file is not found, it falls back to `~/.bash_history`. Commands you send during the session are also added to the in-memory history. The history is deduplicated, keeping the most recent occurrence of each command.

## License

This project is licensed under the MIT License. See the [LICENSE](./LICENSE) file for details.
