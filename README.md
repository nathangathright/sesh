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
sesh                              # Smart: does the right thing based on context
sesh myproject ~/code             # Create/attach 'myproject' at ~/code
sesh myproject ~/code "fix bugs"  # Create session with initial prompt
sesh -s work -p ~/app             # Named parameters
sesh -m "add tests"               # Pass initial prompt to Claude
sesh last                         # Toggle to previous session
sesh list                         # Show all sessions with status
sesh clone <url> [name]           # Git clone + create session
sesh kill <name>                  # Kill a specific session
sesh kill --all                   # Kill all sessions
sesh kill                         # Interactive session killer
sesh update                       # Check for and install updates
```

## How it works

`sesh` detects your context and does the right thing:

| Context | Behavior |
|---------|----------|
| **Inside tmux** | Resumes Claude Code (auto-detects `--continue` if `.claude/` exists) |
| **0 sessions** | Prompts for session name (git-aware default) and project path |
| **1 session** | Auto-attaches |
| **N sessions** | Interactive menu with status indicators and inline kill |
| **With arguments** | Creates or attaches to the named session |

### Subcommands

| Command | Description |
|---------|-------------|
| `sesh last` | Toggle to the previous session |
| `sesh list` / `sesh ls` | Non-interactive dashboard showing session name, path, and status |
| `sesh clone <url> [name]` | Git clone a repo and create a session for it |
| `sesh kill [name\|--all]` | Kill sessions by name, all at once, or via interactive picker |
| `sesh update` | Check for and install the latest version |

### Smart features

- **Git-aware naming** — Default session name comes from git remote origin, git root, or current directory
- **Auto-resume** — Detects `.claude/` in project directory and uses `--continue` automatically
- **Session status** — Shows `[active]` when Claude is running, `[idle]` when waiting, `[dead]` when crashed
- **Crash resilience** — Sessions auto-respawn if Claude crashes, with crash output preserved for debugging
- **Inline kill** — Press `d` in the session picker to kill sessions without leaving the menu
- **Initial prompt** — Pass a message to Claude via third positional arg or `-m` flag
- **Zoxide integration** — When only a name is given, resolves the path via `zoxide query`
- **Last session toggle** — `sesh last` quickly switches between your two most recent sessions
- **Configurable agent** — Override the default command via `SESH_CMD` env var or config file

### Examples

```bash
# No sessions running - prompts with git-aware defaults
$ sesh
Session name [my-repo]: ↵
Project path [/Users/you/my-repo]: ↵
Creating new session 'my-repo' at /Users/you/my-repo

# One session running - auto-attaches
$ sesh
Attaching to session: my-repo

# Multiple sessions - interactive menu with status
$ sesh
Select a session:
   > work  [active]
     side-project  [idle]
     my-repo  [active]
  [↑/↓: navigate | enter: select | d: kill | q: cancel]

# Clone and start coding
$ sesh clone git@github.com:user/repo.git
Cloning git@github.com:user/repo.git...
Creating new session 'repo' at /Users/you/repo

# Create session with initial prompt
$ sesh api ~/Developer/api "add authentication endpoints"
Creating new session 'api' at /Users/you/Developer/api

# Quick session status
$ sesh list
SESSION              PATH                                     STATUS
-------              ----                                     ------
work                 /Users/you/Developer/work                [active]
side-project         /Users/you/Developer/side-project        [idle]

# Toggle between sessions
$ sesh last
```

## Requirements

- [tmux](https://github.com/tmux/tmux) - `brew install tmux`
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) - `npm install -g @anthropic-ai/claude-code`
- zsh or bash

### Optional

- [zoxide](https://github.com/ajeetdsouza/zoxide) - `brew install zoxide` — enables path resolution by project name
- [git](https://git-scm.com) — enables git-aware session naming and `sesh clone`

## Configuration

Sesh loads `~/.config/sesh/config` on startup (override with `SESH_CONFIG` env var). This is a shell file that gets sourced, so you can set any variables:

```bash
# ~/.config/sesh/config
SESH_CMD="claude"                    # Custom agent command (default: claude --dangerously-skip-permissions)
```

### Environment variables

Sessions created by sesh have these env vars available:

| Variable | Description |
|----------|-------------|
| `SESH_SESSION` | Name of the current sesh session |
| `SESH_PATH` | Project path the session was created with |

These are useful in Claude Code hooks, shell scripts, or prompts to detect that you're inside a sesh-managed session.

## Notes

Subcommand names (`last`, `list`, `ls`, `clone`, `kill`, `update`) are reserved. If you need a session with one of these names, use `sesh -s last` instead.

## Uninstall

Remove the sesh functions from your shell config:

```bash
${EDITOR:-nano} ~/.zshrc
```

Search for `# sesh - Smart tmux session manager` and delete everything from that comment through the closing `}` of the `sesh()` function.

## License

MIT
