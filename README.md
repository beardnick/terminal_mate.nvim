# terminal_mate.nvim

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A Neovim plugin that provides a [Warp](https://www.warp.dev/)-like terminal experience by integrating with [tmux](https://github.com/tmux/tmux). It creates a split-pane layout where you can type commands in a dedicated Neovim buffer and send them to an adjacent tmux pane for execution.

![demo](https://user-images.githubusercontent.com/assets/your-id/placeholder.png) <!-- Placeholder for a future demo gif -->

## ✨ Features

- **Warp-like Layout**: A large terminal pane at the top for output, and a slim Neovim buffer at the bottom for command input.
- **Seamless tmux Integration**: Automatically manages tmux panes for you.
- **Dedicated Input Buffer**: Write and edit your shell commands with the full power of Neovim.
- **Simple and Focused**: Does one thing well – sending commands from Neovim to tmux.
- **Configurable**: Customize keymaps, pane size, and more.

## 📋 Requirements

- [Neovim](https://neovim.io/) >= 0.8
- [tmux](https://github.com/tmux/tmux)
- You must be running Neovim from within a tmux session.

## 📦 Installation

Install the plugin with your favorite plugin manager.

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "your-github-username/terminal_mate.nvim",
  config = function()
    require("terminal_mate").setup({
      -- your custom config here
    })
  end,
}
```

## 🚀 Usage

1.  Run Neovim inside a tmux session.
2.  Run the `:TerminalMateOpen` command or use the configured keymap (`<leader>to` by default).
3.  This will create a new tmux pane above your Neovim session.
4.  The current Neovim window will switch to a dedicated input buffer.
5.  Type your command in the buffer.
6.  Press `Ctrl+S` in normal or insert mode to send the command to the terminal pane.

### Commands

- `:TerminalMateOpen`: Opens the terminal pane.
- `:TerminalMateClose`: Closes the terminal pane.
- `:TerminalMateToggle`: Toggles the terminal pane on and off.
- `:TerminalMateSend [command]`: Sends the current line or the provided `[command]` to the terminal.
- `:TerminalMateClear`: Clears the terminal screen (sends `clear`).
- `:TerminalMateInterrupt`: Sends a `Ctrl-C` interrupt signal to the terminal.

### Default Keymaps

These keymaps are active only in the special `terminal_mate` input buffer.

| Keymap      | Mode          | Description                      |
|-------------|---------------|----------------------------------|
| `<C-s>`     | Normal        | Send the current line            |
| `<C-s>`     | Insert        | Send the current line            |
| `<C-s>`     | Visual        | Send the visual selection        |
| `<C-l>`     | Normal        | Clear the terminal screen        |
| `<C-c>`     | Normal        | Send an interrupt signal (Ctrl-C) |

Global keymaps for managing the pane:

| Keymap        | Mode   | Description              |
|---------------|--------|--------------------------|
| `<leader>to`  | Normal | Open the terminal pane   |
| `<leader>tc`  | Normal | Close the terminal pane  |
| `<leader>tt`  | Normal | Toggle the terminal pane |

## ⚙️ Configuration

Call the `setup` function to customize the plugin. Here are the default settings:

```lua
require("terminal_mate").setup({
  -- The percentage of the screen the top terminal pane should occupy.
  split_percent = 80,
  -- The shell to run in the new pane (e.g., "zsh"). `nil` uses your default shell.
  shell = nil,
  -- If true, the terminal pane will be closed automatically when you exit Neovim.
  close_on_exit = true,
  -- If true, the input line in the Neovim buffer will be cleared after sending.
  clear_input = true,

  -- Keymaps for global actions
  keymap = {
    open = "<leader>to",
    close = "<leader>tc",
    toggle = "<leader>tt",
    -- The following keymaps are local to the input buffer
    send_line = '<C-s>',
    send_visual = '<C-s>',
    clear = "<C-l>",
    interrupt = "<C-c>",
  },

  -- Settings for the input buffer
  buffer = {
    filetype = "terminal_mate",
    bufname = "[TerminalMate]",
  },
})
```

## 📜 License

This project is licensed under the MIT License. See the [LICENSE](./LICENSE) file for details.
