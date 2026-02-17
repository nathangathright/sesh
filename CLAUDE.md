# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Sesh is a smart tmux session manager for Claude Code. It's a pure shell script (`sesh.sh`) that provides one command to create, attach, and resume tmux coding sessions with Claude Code. It gets installed by appending shell functions directly into the user's shell config file (`~/.zshrc` or `~/.bashrc`).

## Architecture

There are only two files that matter:

- **`sesh.sh`** — The entire application. Contains these functions:
  - `_sesh_state_dir()` — Ensures `~/.local/state/sesh/` exists, prints path.
  - `_sesh_track_last()` — Writes session name to state file for last-session toggle.
  - `_sesh_default_name()` — Git-aware default session name (remote origin → git root → basename).
  - `_sesh_sanitize_name()` — Replaces `.` and `:` (tmux separators) with `-` in session names.
  - `_sesh_status()` — Checks `#{pane_current_command}` for `node` to detect if Claude is running.
  - `_sesh_attach()` — Centralizes `tmux attach` vs `tmux switch-client` based on `$TMUX` context.
  - `_sesh_create()` — Creates a new tmux session with Claude Code (env vars, crash resilience, auto-resume).
  - `_sesh_select()` — Interactive terminal menu (raw mode, ANSI escape sequences, arrow/vim key navigation, inline kill with `d` key). Returns selection via the `$SELECTED` global variable.
  - `_sesh_build_list()` — Builds column-aligned session list (name, path, status) for pickers. Returns via `$SESSION_LIST` global array.
  - `_sesh_last()` — Subcommand: toggle to previous session via state file.
  - `_sesh_list()` — Subcommand: interactive session picker with path and status columns.
  - `_sesh_clone()` — Subcommand: git clone + session creation.
  - `_sesh_kill()` — Subcommand: kill sessions (by name, all, or via picker). `--all` only kills sesh-managed sessions (those with `SESH_SESSION` env var).
  - `_sesh_agent()` — Subcommand: starts Claude Code in the current tmux session (guards on `$TMUX`).
  - `_sesh_new()` — Subcommand: interactive session creation wizard (prompts for name and path).
  - `_sesh_update()` — Subcommand: self-update by downloading latest `sesh.sh` from GitHub and patching the shell config in place.
  - `_sesh_help()` — Prints usage information for `sesh help`.
  - `sesh()` — Core logic: subcommand routing → argument parsing → session creation/attachment. Naked `sesh` shows help.
- **`install.sh`** — Appends the contents of `sesh.sh` into the user's shell config file between `# >>> sesh >>>` / `# <<< sesh <<<` markers. Supports in-place updates when markers are present, and detects legacy (unmarked) installations.

Key design decisions:
- Functions are sourced into the shell (not run as a subprocess) so they can modify the user's terminal state and attach to tmux sessions.
- `_sesh_select` manages raw terminal mode directly via `stty` and restores state via trap handlers.
- The zsh-specific `read -k` and array syntax (`${(@f)...}`, 1-based indexing) means this currently targets zsh primarily.
- Subcommand names (`agent`, `new`, `last`, `list`, `ls`, `clone`, `kill`, `update`, `help`, `version`) are reserved — sessions with these names must use `sesh -s <name>`.
- All tmux `-t` targets use the `=` prefix (e.g., `-t "=$name"`) for exact session name matching. Session names are also sanitized (`_sesh_sanitize_name`) to replace `.` and `:` with `-`, since tmux parses these as window/pane separators even with the `=` prefix.
- Status detection: Claude Code runs as `node`. Check `#{pane_current_command}` for `node` → "active". Also detects `#{pane_dead}` for dead/crashed sessions.
- Picker annotations use double-space delimiter (`"session  path  [active]"`) and are stripped with `${SELECTED%%  *}`.
- State is stored in `~/.local/state/sesh/` (last and second_last files for session toggle).
- Config is loaded from `~/.config/sesh/config` (sourced as shell). Override path with `SESH_CONFIG` env var.
- Agent command defaults to `claude --dangerously-skip-permissions` but is configurable via `SESH_CMD` env var or config.
- Auto-resume detects `.claude/` directory in the project path and adds `--continue` to the claude command.
- Crash resilience: sessions use `remain-on-exit on` and `pane-died` hook for auto-respawn. This protects the session if the shell process crashes; for Claude exits, the shell continues naturally.
- Version is tracked in `SESH_VERSION` at the top of `sesh.sh`.
- Environment injection: `SESH_SESSION` and `SESH_PATH` are set in tmux session environment.
- Zoxide integration is optional and guarded by `command -v zoxide`.

## Development

There is no build step, test suite, or linter. To test changes locally:

```bash
source sesh.sh    # Load functions into current shell
sesh              # Run it
```

## Requirements

- tmux
- Claude Code CLI (`claude`)
- zsh (primary) or bash

### Optional

- zoxide — path resolution by project name
- git — git-aware naming and `sesh clone`
