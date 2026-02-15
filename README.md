# sesh

Smart tmux session manager for [Claude Code](https://docs.anthropic.com/en/docs/claude-code). One command to create, attach, and resume coding sessions.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/nathangathright/sesh/main/install.sh | bash
```

This appends the `sesh` function to your `~/.zshrc` (or `~/.bashrc`). After installing:

```bash
source ~/.zshrc
```

## Usage

```bash
sesh                        # Smart: does the right thing based on context
sesh myproject ~/code       # Create/attach 'myproject' at ~/code
sesh -s work -p ~/app       # Named parameters
```

## How it works

`sesh` detects your context and does the right thing:

| Context | Behavior |
|---------|----------|
| **Inside tmux** | Resumes Claude Code (`claude --dangerously-skip-permissions --continue`) |
| **0 sessions** | Prompts for session name and project path (smart defaults from `$PWD`) |
| **1 session** | Auto-attaches |
| **N sessions** | Interactive menu with arrow keys + enter |
| **With arguments** | Creates or attaches to the named session |

### Examples

```bash
# No sessions running - prompts for details
$ sesh
📝 Session name [myapp]: ↵
📂 Project path [/Users/you/myapp]: ↵
✨ Creating new session 'myapp' at /Users/you/myapp

# One session running - auto-attaches
$ sesh
🔗 Attaching to session: myapp

# Multiple sessions - interactive menu
$ sesh
📋 Select a session:
   > work
     side-project
     myapp
  [↑/↓: navigate | enter: select | q: cancel]

# Explicit session and path
$ sesh api ~/Developer/api-server
✨ Creating new session 'api' at /Users/you/Developer/api-server

# Inside tmux - resumes Claude Code
$ sesh
🔄 Starting Claude Code...
```

## Requirements

- [tmux](https://github.com/tmux/tmux) - `brew install tmux`
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) - `npm install -g @anthropic-ai/claude-code`
- zsh or bash

## Uninstall

Remove the `_sesh_select()` and `sesh()` functions from your shell config:

```bash
# Open your shell config in an editor
${EDITOR:-nano} ~/.zshrc
```

Search for `# sesh - Smart tmux session manager` and delete everything from that comment through the closing `}` of the `sesh()` function.

## License

MIT
