# sesh - Smart tmux session manager for AI coding agents
# https://github.com/nathangathright/sesh

SESH_VERSION="0.1.1"

# Global: _sesh_select returns its result via $SELECTED

# Ensure state directory exists, print path
_sesh_state_dir() {
  local dir="${HOME}/.local/state/sesh"
  mkdir -p "$dir"
  printf '%s' "$dir"
}

# Write session name to state file for last-session toggle
_sesh_track_last() {
  local current="$1"
  local state_dir
  state_dir="$(_sesh_state_dir)"
  # Only track if different from what's already stored
  local prev=""
  [[ -f "${state_dir}/last" ]] && prev=$(< "${state_dir}/last")
  if [[ "$current" != "$prev" ]]; then
    printf '%s' "$prev" > "${state_dir}/second_last"
    printf '%s' "$current" > "${state_dir}/last"
  fi
}

# Sanitize session name: replace dots and colons (tmux separators) with hyphens
_sesh_sanitize_name() {
  local name="$1"
  name="${name//./-}"
  name="${name//:/-}"
  printf '%s' "$name"
}

# Git-aware default session name
_sesh_default_name() {
  local name=""
  # Try git remote origin URL → extract repo name
  if command -v git &>/dev/null && git rev-parse --is-inside-work-tree &>/dev/null; then
    local url
    url=$(git remote get-url origin 2>/dev/null)
    if [[ -n "$url" ]]; then
      name="${url##*/}"
      name="${name%.git}"
    fi
    # Fallback: basename of git root
    if [[ -z "$name" ]]; then
      local root
      root=$(git rev-parse --show-toplevel 2>/dev/null)
      [[ -n "$root" ]] && name="${root##*/}"
    fi
  fi
  # Final fallback: current directory name
  [[ -z "$name" ]] && name="${PWD##*/}"
  printf '%s' "$(_sesh_sanitize_name "$name")"
}

# Check if a coding agent is running in a tmux session
_sesh_status() {
  local target="$1"
  # Capture pane info in a single query to avoid race conditions
  local pane_info
  pane_info=$(tmux list-panes -t "=$target" -F '#{pane_current_command} #{pane_dead}' 2>/dev/null)
  if [[ -z "$pane_info" ]]; then
    printf 'dead'
    return
  fi

  # Determine process name from the session's agent profile
  local process_name="node"
  local agent_env
  agent_env=$(tmux show-environment -t "=$target" SESH_AGENT 2>/dev/null)
  if [[ -n "$agent_env" && "$agent_env" != "-SESH_AGENT" ]]; then
    local profile_process
    profile_process=$(_sesh_agent_profile "${agent_env#SESH_AGENT=}" process 2>/dev/null)
    [[ -n "$profile_process" ]] && process_name="$profile_process"
  fi

  if printf '%s' "$pane_info" | grep -q "$process_name"; then
    printf 'active'
  else
    # Check if all panes are dead (remain-on-exit keeps them visible)
    local total_count=0 dead_count=0
    local line
    while IFS= read -r line; do
      total_count=$((total_count + 1))
      [[ "$line" == *" 1" ]] && dead_count=$((dead_count + 1))
    done <<< "$pane_info"
    if [[ "$dead_count" -eq "$total_count" && "$total_count" -gt 0 ]]; then
      printf 'dead'
    else
      printf 'idle'
    fi
  fi
}

# Attach or switch to a tmux session
_sesh_attach() {
  local target="$1"
  if [[ -n "$TMUX" ]]; then
    tmux switch-client -t "=$target"
  else
    tmux attach -t "=$target"
  fi
}

# Resolve project path: expand ~, ensure directory exists (prompt to create)
# Prints resolved path to stdout; returns 1 on abort
_sesh_resolve_path() {
  local rpath="$1"
  rpath="${rpath/#\~/$HOME}"
  if [[ ! -d "$rpath" ]]; then
    printf "Directory '%s' does not exist. Create it? (y/n) " "$rpath" >/dev/tty
    local reply
    read -r reply </dev/tty
    if [[ $reply =~ ^[Yy] ]]; then
      mkdir -p "$rpath"
      echo "Created directory: $rpath" >/dev/tty
    else
      echo "Aborted." >/dev/tty
      return 1
    fi
  fi
  printf '%s' "$rpath"
}

# Agent profile lookup: returns agent-specific properties
# Keys: cmd, resume, prompt, process, state_dir, label
_sesh_agent_profile() {
  local agent="$1" key="$2"
  case "${agent}:${key}" in
    claude:cmd)        printf '%s' "claude --dangerously-skip-permissions" ;;
    claude:resume)     printf '%s' "--continue" ;;
    claude:prompt)     printf '%s' "-p" ;;
    claude:process)    printf '%s' "node" ;;
    claude:state_dir)  printf '%s' ".claude" ;;
    claude:label)      printf '%s' "Claude Code" ;;

    codex:cmd)         printf '%s' "codex --dangerously-bypass-approvals-and-sandbox" ;;
    codex:resume)      ;;
    codex:prompt)      ;;
    codex:process)     printf '%s' "node" ;;
    codex:state_dir)   printf '%s' ".codex" ;;
    codex:label)       printf '%s' "Codex" ;;

    gemini:cmd)        printf '%s' "gemini --yolo" ;;
    gemini:resume)     printf '%s' "--resume" ;;
    gemini:prompt)     printf '%s' "-p" ;;
    gemini:process)    printf '%s' "node" ;;
    gemini:state_dir)  printf '%s' ".gemini" ;;
    gemini:label)      printf '%s' "Gemini CLI" ;;

    *) return 1 ;;
  esac
}

# List of supported agent IDs
_SESH_AGENTS=("claude" "codex" "gemini")

# Build extra CLI args for auto-resume and initial prompt
# Sets _SESH_CMD_EXTRA array
_sesh_build_cmd() {
  local agent="$1"
  local project_path="$2"
  local initial_prompt="${3:-}"
  _SESH_CMD_EXTRA=()

  # Auto-resume: check for agent's state directory
  local state_dir resume_flag
  state_dir=$(_sesh_agent_profile "$agent" state_dir)
  resume_flag=$(_sesh_agent_profile "$agent" resume)
  if [[ -n "$resume_flag" && -d "${project_path}/${state_dir}" ]]; then
    _SESH_CMD_EXTRA+=("$resume_flag")
  fi

  # Initial prompt
  if [[ -n "$initial_prompt" ]]; then
    local prompt_flag
    prompt_flag=$(_sesh_agent_profile "$agent" prompt)
    if [[ -n "$prompt_flag" ]]; then
      _SESH_CMD_EXTRA+=("$prompt_flag" "$initial_prompt")
    else
      # Positional argument (e.g., Codex)
      _SESH_CMD_EXTRA+=("$initial_prompt")
    fi
  fi
}

# Create a new tmux session with a coding agent
_sesh_create() {
  local session_name="$1"
  local project_path="$2"
  local agent="$3"
  local initial_prompt="${4:-}"

  # Resolve command: SESH_CMD overrides the agent profile default
  local base_cmd="${SESH_CMD:-$(_sesh_agent_profile "$agent" cmd)}"

  # Build agent-specific extra args
  _sesh_build_cmd "$agent" "$project_path" "$initial_prompt"
  local full_cmd="$base_cmd"
  local arg
  for arg in "${_SESH_CMD_EXTRA[@]}"; do
    full_cmd="${full_cmd} $(printf '%q' "$arg")"
  done

  local label
  label=$(_sesh_agent_profile "$agent" label)
  echo "Creating new session '$session_name' at $project_path (${label})"
  tmux new-session -s "$session_name" -c "$project_path" -d

  # Inject environment variables so child processes know their context
  tmux set-environment -t "=$session_name" SESH_SESSION "$session_name"
  tmux set-environment -t "=$session_name" SESH_PATH "$project_path"
  tmux set-environment -t "=$session_name" SESH_AGENT "$agent"

  # Crash resilience: keep pane visible on exit and auto-respawn.
  tmux set-option -t "=$session_name" remain-on-exit on
  tmux set-hook -t "=$session_name" pane-died "respawn-pane -k"

  tmux send-keys -t "=$session_name" "$full_cmd" C-m
  _sesh_track_last "$session_name"
  _sesh_attach "$session_name"
}

# Interactive menu helper (arrow keys + enter)
# Usage: _sesh_select [--kill] "prompt" option1 option2 ...
# Returns selection via the global $SELECTED variable
_sesh_select() {
  local kill_enabled=0
  if [[ "${1:-}" == "--kill" ]]; then
    kill_enabled=1
    shift
  fi

  local prompt="$1"
  shift
  local -a options=("$@")
  local num_options=${#options[@]}
  local selected=0
  local prev_num_options=$num_options
  local key
  local ESC=$'\e'

  local saved_stty
  saved_stty=$(command stty -g 2>/dev/null)

  _sesh_select_cleanup() {
    printf "${ESC}[?25h" >/dev/tty 2>/dev/null
    [[ -n "$saved_stty" ]] && command stty "$saved_stty" 2>/dev/null
    unset -f _sesh_select_cleanup _sesh_select_draw
  }

  trap '_sesh_select_cleanup; return 1' INT TERM HUP

  printf "${ESC}[?25l" >/dev/tty
  command stty -echo raw 2>/dev/null

  local footer_hint="[↑/↓: navigate | enter: select"
  [[ $kill_enabled -eq 1 ]] && footer_hint="${footer_hint} | d: kill"
  footer_hint="${footer_hint} | q: cancel]"

  _sesh_select_draw() {
    local i
    local lines_to_move=$((prev_num_options + 1))
    [[ ${1:-0} -eq 1 ]] && printf "${ESC}[${lines_to_move}A" >/dev/tty
    printf "${ESC}[2K\r${ESC}[1m%s${ESC}[0m\r\n" "$prompt" >/dev/tty
    for ((i = 0; i < num_options; i++)); do
      printf "${ESC}[2K\r" >/dev/tty
      if [[ $i -eq $selected ]]; then
        printf "  ${ESC}[7m${ESC}[1m > %s ${ESC}[0m" "${options[$((i + 1))]}" >/dev/tty
      else
        printf "  ${ESC}[2m   %s${ESC}[0m" "${options[$((i + 1))]}" >/dev/tty
      fi
      printf "\r\n" >/dev/tty
    done
    # Clear from cursor to end of screen (removes stale lines after item deletion)
    printf "${ESC}[J${ESC}[2m  %s${ESC}[0m" "$footer_hint" >/dev/tty
    prev_num_options=$num_options
  }

  _sesh_select_draw 0

  while true; do
    read -r -k 1 key 2>/dev/null
    case "$key" in
      $'\r'|$'\n')
        printf "\r\n" >/dev/tty
        _sesh_select_cleanup
        trap - INT TERM HUP
        SELECTED="${options[$((selected + 1))]}"
        return 0
        ;;
      q|Q)
        printf "\r\n" >/dev/tty
        _sesh_select_cleanup
        trap - INT TERM HUP
        SELECTED=""
        return 1
        ;;
      d|D)
        if [[ $kill_enabled -eq 1 && $num_options -gt 0 ]]; then
          local target="${options[$((selected + 1))]}"
          # Strip annotation (e.g. "session  [active]" or "session  path  [active]" → "session")
          target="${target%%  *}"
          tmux kill-session -t "=$target" 2>/dev/null
          # Remove from array (zsh 1-based)
          options[$((selected + 1))]=()
          num_options=${#options[@]}
          if [[ $num_options -eq 0 ]]; then
            printf "\r\n" >/dev/tty
            _sesh_select_cleanup
            trap - INT TERM HUP
            SELECTED=""
            return 1
          fi
          # Adjust selected index if needed
          if [[ $selected -ge $num_options ]]; then
            selected=$((num_options - 1))
          fi
          _sesh_select_draw 1
        fi
        ;;
      "$ESC")
        local seq1="" seq2=""
        read -r -k 1 -t 0.1 seq1 2>/dev/null
        read -r -k 1 -t 0.1 seq2 2>/dev/null
        if [[ "$seq1" == "[" || "$seq1" == "O" ]]; then
          case "$seq2" in
            A) selected=$(( (selected - 1 + num_options) % num_options )) ;;
            B) selected=$(( (selected + 1) % num_options )) ;;
          esac
        elif [[ -z "$seq1" ]]; then
          printf "\r\n" >/dev/tty
          _sesh_select_cleanup
          trap - INT TERM HUP
          SELECTED=""
          return 1
        fi
        _sesh_select_draw 1
        ;;
      k) selected=$(( (selected - 1 + num_options) % num_options ))
        _sesh_select_draw 1
        ;;
      j) selected=$(( (selected + 1) % num_options ))
        _sesh_select_draw 1
        ;;
      *)
        _sesh_select_draw 1
        ;;
    esac
  done
}

# Subcommand: toggle to previous session
_sesh_last() {
  local state_dir
  state_dir="$(_sesh_state_dir)"
  local last_file="${state_dir}/last"
  local second_last_file="${state_dir}/second_last"

  if [[ ! -f "$second_last_file" ]]; then
    echo "No previous session to toggle to."
    return 1
  fi

  local target
  target=$(< "$second_last_file")
  if [[ -z "$target" ]]; then
    echo "No previous session to toggle to."
    return 1
  fi

  if ! tmux has-session -t "=$target" 2>/dev/null; then
    echo "Previous session '$target' no longer exists."
    return 1
  fi

  _sesh_track_last "$target"
  _sesh_attach "$target"
}

# Build annotated session list for pickers. Sets SESSION_LIST array.
_sesh_build_list() {
  SESSION_LIST=()
  local sessions
  sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null)
  [[ -z "$sessions" ]] && return 1

  local -a names=() paths=() agents=() statuses=()
  local name sess_path sess_agent sess_status max_name=0 max_path=0 max_agent=0
  local agent_env
  while IFS= read -r name; do
    sess_path=$(tmux display-message -p -t "=${name}:" '#{pane_current_path}' 2>/dev/null)
    if [[ -z "$sess_path" ]]; then
      sess_path=$(tmux show-environment -t "=$name" SESH_PATH 2>/dev/null)
      sess_path="${sess_path#SESH_PATH=}"
    fi
    sess_path="${sess_path/#$HOME/~}"

    agent_env=$(tmux show-environment -t "=$name" SESH_AGENT 2>/dev/null)
    if [[ -n "$agent_env" && "$agent_env" != "-SESH_AGENT" ]]; then
      sess_agent="${agent_env#SESH_AGENT=}"
    else
      sess_agent=""
    fi

    sess_status=$(_sesh_status "$name")
    names+=("$name")
    paths+=("$sess_path")
    agents+=("$sess_agent")
    statuses+=("$sess_status")
    (( ${#name} > max_name )) && max_name=${#name}
    (( ${#sess_path} > max_path )) && max_path=${#sess_path}
    (( ${#sess_agent} > max_agent )) && max_agent=${#sess_agent}
  done <<< "$sessions"

  local i name_pad path_pad agent_pad
  for ((i = 1; i <= ${#names[@]}; i++)); do
    name_pad=$((max_name - ${#names[$i]} + 2))
    path_pad=$((max_path - ${#paths[$i]} + 2))
    if [[ $max_agent -gt 0 ]]; then
      agent_pad=$((max_agent - ${#agents[$i]} + 2))
      SESSION_LIST+=("${names[$i]}$(printf '%*s' $name_pad '')${paths[$i]}$(printf '%*s' $path_pad '')${agents[$i]}$(printf '%*s' $agent_pad '')[${statuses[$i]}]")
    else
      SESSION_LIST+=("${names[$i]}$(printf '%*s' $name_pad '')${paths[$i]}$(printf '%*s' $path_pad '')[${statuses[$i]}]")
    fi
  done
}

# Subcommand: interactive session picker
_sesh_list() {
  if ! _sesh_build_list; then
    echo "No active sessions."
    return 0
  fi

  if _sesh_select --kill "Select a session:" "${SESSION_LIST[@]}"; then
    local target="${SELECTED%%  *}"
    _sesh_track_last "$target"
    _sesh_attach "$target"
  fi
}

# Subcommand: git clone + create session
_sesh_clone() {
  local agent="$1"
  local url="$2"
  local name="${3:-}"

  if [[ -z "$url" ]]; then
    echo "Usage: sesh clone <url> [name]"
    return 1
  fi

  if [[ "$url" == -* ]]; then
    echo "Invalid URL: $url"
    return 1
  fi

  # Extract name from URL if not provided
  if [[ -z "$name" ]]; then
    name="${url##*/}"
    name="${name%.git}"
  fi

  echo "Cloning $url..."
  if ! git clone "$url" "$name"; then
    echo "Clone failed."
    return 1
  fi

  local clone_path="${PWD}/${name}"
  _sesh_create "$(_sesh_sanitize_name "$name")" "$clone_path" "$agent"
}

# Subcommand: kill sessions
_sesh_kill() {
  case "${1:-}" in
    --all|-a)
      local sessions
      sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null)
      if [[ -z "$sessions" ]]; then
        echo "No sessions to kill."
        return 0
      fi
      local name killed=0
      while IFS= read -r name; do
        # Only kill sesh-managed sessions (those with SESH_SESSION env var)
        if tmux show-environment -t "=$name" SESH_SESSION &>/dev/null; then
          tmux kill-session -t "=$name" 2>/dev/null && echo "Killed session: $name" && killed=$((killed + 1))
        fi
      done <<< "$sessions"
      if [[ $killed -eq 0 ]]; then
        echo "No sesh-managed sessions to kill."
      fi
      ;;
    "")
      # No args: show picker with status annotations
      if ! _sesh_build_list; then
        echo "No sessions to kill."
        return 0
      fi
      if _sesh_select --kill "Kill a session:" "${SESSION_LIST[@]}"; then
        local target="${SELECTED%%  *}"
        tmux kill-session -t "=$target" 2>/dev/null && echo "Killed session: $target"
      fi
      ;;
    *)
      # Kill named session
      if tmux has-session -t "=$1" 2>/dev/null; then
        tmux kill-session -t "=$1" && echo "Killed session: $1"
      else
        echo "Session '$1' not found."
        return 1
      fi
      ;;
  esac
}

# Subcommand: start coding agent in current tmux session
_sesh_agent() {
  local agent="$1"
  local initial_prompt="${2:-}"

  if [[ -z "$TMUX" ]]; then
    echo "Error: 'sesh agent' must be run inside a tmux session."
    echo "Use 'sesh new' to create a session first."
    return 1
  fi

  local base_cmd="${SESH_CMD:-$(_sesh_agent_profile "$agent" cmd)}"
  local current_path
  current_path=$(tmux display-message -p '#{pane_current_path}' 2>/dev/null)
  _sesh_build_cmd "$agent" "$current_path" "$initial_prompt"
  local -a cmd_args=(${(z)base_cmd})
  cmd_args+=("${_SESH_CMD_EXTRA[@]}")
  local label
  label=$(_sesh_agent_profile "$agent" label)
  echo "Starting ${label}..."
  "${cmd_args[@]}"
}

# Subcommand: interactive session creation wizard
_sesh_new() {
  local agent="$1"
  local initial_prompt="${2:-}"
  local show_picker="${3:-1}"

  # Agent selection (only when --agent was not explicitly passed)
  if [[ "$show_picker" -eq 1 ]]; then
    if _sesh_select "Select agent:" "${_SESH_AGENTS[@]}"; then
      agent="$SELECTED"
    else
      return 1
    fi
  fi

  # Prompt for session name
  local default_name
  default_name=$(_sesh_default_name)
  printf "Session name [%s]: " "$default_name"
  read -r session_name
  if [[ -z "$session_name" ]]; then
    session_name="$default_name"
  else
    session_name=$(_sesh_sanitize_name "$session_name")
  fi

  # If session already exists, attach to it
  if tmux has-session -t "=$session_name" 2>/dev/null; then
    echo "Attaching to existing session: $session_name"
    _sesh_track_last "$session_name"
    _sesh_attach "$session_name"
    return
  fi

  # Prompt for project path
  local default_path="$PWD"
  printf "Project path [%s]: " "$default_path"
  read -r project_path
  if [[ -z "$project_path" ]]; then
    project_path="$default_path"
  fi

  project_path=$(_sesh_resolve_path "$project_path") || return 1

  _sesh_create "$session_name" "$project_path" "$agent" "$initial_prompt"
}

# Subcommand: check for and install updates
_sesh_update() {
  local current_version="$SESH_VERSION"

  # Detect shell config file (same logic as install.sh)
  local shell_config=""
  case "${SHELL##*/}" in
    zsh)  [[ -f "$HOME/.zshrc" ]] && shell_config="$HOME/.zshrc" ;;
    bash)
      if [[ -f "$HOME/.bashrc" ]]; then
        shell_config="$HOME/.bashrc"
      elif [[ -f "$HOME/.bash_profile" ]]; then
        shell_config="$HOME/.bash_profile"
      fi
      ;;
  esac
  if [[ -z "$shell_config" ]]; then
    if [[ -f "$HOME/.zshrc" ]]; then
      shell_config="$HOME/.zshrc"
    elif [[ -f "$HOME/.bashrc" ]]; then
      shell_config="$HOME/.bashrc"
    elif [[ -f "$HOME/.bash_profile" ]]; then
      shell_config="$HOME/.bash_profile"
    fi
  fi
  if [[ -z "$shell_config" ]]; then
    echo "Could not find shell config file (~/.zshrc, ~/.bashrc, or ~/.bash_profile)"
    return 1
  fi

  # Verify markers exist
  if ! grep -q "# >>> sesh >>>" "$shell_config" 2>/dev/null; then
    echo "Sesh markers not found in $shell_config."
    echo "Please reinstall: curl -fsSL https://raw.githubusercontent.com/nathangathright/sesh/main/install.sh | bash"
    return 1
  fi

  # Download latest sesh.sh to temp file
  local tmpfile
  tmpfile=$(mktemp)

  echo "Checking for updates..."
  if ! curl -fsSL "https://raw.githubusercontent.com/nathangathright/sesh/main/sesh.sh" -o "$tmpfile" 2>/dev/null; then
    echo "Failed to download update."
    rm -f "$tmpfile"
    return 1
  fi

  # Validate download
  if ! grep -q 'SESH_VERSION=' "$tmpfile" || ! grep -q 'sesh()' "$tmpfile"; then
    echo "Downloaded file is invalid."
    rm -f "$tmpfile"
    return 1
  fi

  # Compare versions
  local remote_version
  remote_version=$(grep '^SESH_VERSION=' "$tmpfile" | head -1)
  remote_version="${remote_version#SESH_VERSION=\"}"
  remote_version="${remote_version%\"}"

  if [[ "$current_version" == "$remote_version" ]]; then
    echo "Already up to date (v${current_version})."
    rm -f "$tmpfile"
    return 0
  fi

  # Strip old markers from shell config
  local tmp_config
  tmp_config=$(mktemp)
  awk -v start="# >>> sesh >>>" -v end="# <<< sesh <<<" '
    $0 == start { skip=1; next }
    $0 == end { skip=0; next }
    !skip { print }
  ' "$shell_config" > "$tmp_config"
  mv "$tmp_config" "$shell_config"

  # Append new marked content
  {
    echo "# >>> sesh >>>"
    cat "$tmpfile"
    echo "# <<< sesh <<<"
  } >> "$shell_config"

  # Source the new version directly
  source "$tmpfile"
  rm -f "$tmpfile"

  echo "Updated sesh: v${current_version} -> v${remote_version}"
}

# Print usage information
_sesh_help() {
  cat <<'EOF'
Usage: sesh <command> [options]

Commands:
  sesh new                        Interactive session creation wizard
  sesh <name> [path]              Create or attach to a session
  sesh agent                      Start coding agent in current session
  sesh last                       Toggle to previous session
  sesh list, ls                   Interactive session picker
  sesh clone <url> [name]         Git clone + create session
  sesh kill [name|--all]          Kill sessions
  sesh update                     Check for and install updates
  sesh help                       Show this help message
  sesh version                    Show version

Options:
  -s, --session <name>    Session name
  -p, --path <path>       Project path
  -m, --message <text>    Initial prompt for agent
  --agent <name>          Agent to use (claude, codex, gemini)

Agents:
  claude    Claude Code (default)
  codex     OpenAI Codex
  gemini    Google Gemini CLI

Environment:
  SESH_AGENT    Default agent (default: claude)
  SESH_CMD      Override agent command entirely
  SESH_CONFIG   Config file path (default: ~/.config/sesh/config)
EOF
}

# Smart tmux session manager
sesh() {
  # Load user config if it exists
  local _sesh_config="${SESH_CONFIG:-${HOME}/.config/sesh/config}"
  [[ -f "$_sesh_config" ]] && source "$_sesh_config"

  # Pre-scan for --agent flag (must happen before subcommand routing)
  local agent="${SESH_AGENT:-claude}"
  local agent_explicit=0
  local -a _sesh_args=("$@")
  local -a _sesh_filtered=()
  local i=1
  while [[ $i -le ${#_sesh_args[@]} ]]; do
    case "${_sesh_args[$i]}" in
      --agent)
        if [[ $i -lt ${#_sesh_args[@]} ]]; then
          agent="${_sesh_args[$((i + 1))]}"
          agent_explicit=1
          i=$((i + 2))
        else
          echo "Error: --agent requires an argument." >&2
          return 1
        fi
        ;;
      *)
        _sesh_filtered+=("${_sesh_args[$i]}")
        i=$((i + 1))
        ;;
    esac
  done
  set -- "${_sesh_filtered[@]}"

  # Validate agent
  if ! _sesh_agent_profile "$agent" cmd &>/dev/null; then
    echo "Error: unknown agent '$agent'. Supported: claude, codex, gemini" >&2
    return 1
  fi

  # Subcommand routing
  case "${1:-}" in
    help|--help|-h)
      _sesh_help; return 0 ;;
    version|--version|-v)
      echo "sesh $SESH_VERSION"; return 0 ;;
    update)
      shift; _sesh_update "$@"; return $? ;;
    last)
      shift; _sesh_last "$@"; return $? ;;
    list|ls)
      shift; _sesh_list "$@"; return $? ;;
    clone)
      shift; _sesh_clone "$agent" "$@"; return $? ;;
    kill)
      shift; _sesh_kill "$@"; return $? ;;
    agent)
      shift
      local initial_prompt=""
      while [[ $# -gt 0 ]]; do
        case $1 in
          -m|--message)
            if [[ $# -lt 2 ]]; then echo "Error: $1 requires an argument." >&2; return 1; fi
            initial_prompt="$2"; shift 2 ;;
          *) initial_prompt="$1"; shift ;;
        esac
      done
      _sesh_agent "$agent" "$initial_prompt"; return $? ;;
    new)
      shift
      local initial_prompt=""
      while [[ $# -gt 0 ]]; do
        case $1 in
          -m|--message)
            if [[ $# -lt 2 ]]; then echo "Error: $1 requires an argument." >&2; return 1; fi
            initial_prompt="$2"; shift 2 ;;
          *) shift ;;
        esac
      done
      _sesh_new "$agent" "$initial_prompt" "$((1 - agent_explicit))"; return $? ;;
    "")
      _sesh_help; return 0 ;;
  esac

  local session_name=""
  local project_path=""
  local initial_prompt=""

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case $1 in
      -s|--session)
        if [[ $# -lt 2 ]]; then echo "Error: $1 requires an argument." >&2; return 1; fi
        session_name="$2"
        shift 2
        ;;
      -p|--path)
        if [[ $# -lt 2 ]]; then echo "Error: $1 requires an argument." >&2; return 1; fi
        project_path="$2"
        shift 2
        ;;
      -m|--message)
        if [[ $# -lt 2 ]]; then echo "Error: $1 requires an argument." >&2; return 1; fi
        initial_prompt="$2"
        shift 2
        ;;
      *)
        # Positional: first=session, second=path
        if [[ -z "$session_name" ]]; then
          session_name="$1"
        elif [[ -z "$project_path" ]]; then
          project_path="$1"
        fi
        shift
        ;;
    esac
  done

  # Session name is required at this point
  if [[ -z "$session_name" ]]; then
    _sesh_help
    return 1
  fi

  session_name=$(_sesh_sanitize_name "$session_name")

  # Block reserved subcommand names
  case "$session_name" in
    help|version|update|last|list|ls|clone|kill|agent|new)
      echo "Error: '$session_name' is a reserved subcommand name." >&2
      return 1
      ;;
  esac

  # Check if session already exists
  if tmux has-session -t "=$session_name" 2>/dev/null; then
    echo "Attaching to existing session: $session_name"
    _sesh_track_last "$session_name"
    _sesh_attach "$session_name"
    return
  fi

  # Zoxide integration: resolve path when name given but no path
  if [[ -z "$project_path" ]]; then
    if command -v zoxide &>/dev/null; then
      local zoxide_result
      zoxide_result=$(zoxide query "$session_name" 2>/dev/null)
      if [[ -n "$zoxide_result" ]]; then
        project_path="$zoxide_result"
      fi
    fi
  fi

  # If no path provided yet, prompt for it
  if [[ -z "$project_path" ]]; then
    local default_path="$PWD"
    printf "Project path [%s]: " "$default_path"
    read -r project_path
    if [[ -z "$project_path" ]]; then
      project_path="$default_path"
    fi
  fi

  project_path=$(_sesh_resolve_path "$project_path") || return 1

  _sesh_create "$session_name" "$project_path" "$agent" "$initial_prompt"
}
