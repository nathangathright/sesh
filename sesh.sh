# sesh - Smart tmux session manager for Claude Code
# https://github.com/nathangathright/sesh

SESH_VERSION="0.1.0"

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
  printf '%s' "$name"
}

# Check if Claude is running in a tmux session
_sesh_status() {
  local target="$1"
  # Capture pane info in a single query to avoid race conditions
  local pane_info
  pane_info=$(tmux list-panes -t "=$target" -F '#{pane_current_command} #{pane_dead}' 2>/dev/null)
  if [[ -z "$pane_info" ]]; then
    printf 'dead'
  elif printf '%s' "$pane_info" | grep -q 'node'; then
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

# Create a new tmux session with Claude Code
_sesh_create() {
  local session_name="$1"
  local project_path="$2"
  local base_cmd="$3"
  local initial_prompt="${4:-}"

  # Build claude command with auto-resume and initial prompt
  local claude_cmd="$base_cmd"
  if [[ -d "${project_path}/.claude" ]]; then
    claude_cmd="${claude_cmd} --continue"
  fi
  if [[ -n "$initial_prompt" ]]; then
    claude_cmd="${claude_cmd} -p $(printf '%q' "$initial_prompt")"
  fi

  # Create new session, navigate to path, and start Claude Code
  echo "Creating new session '$session_name' at $project_path"
  tmux new-session -s "$session_name" -c "$project_path" -d

  # Inject environment variables so child processes know their context
  tmux set-environment -t "=$session_name" SESH_SESSION "$session_name"
  tmux set-environment -t "=$session_name" SESH_PATH "$project_path"

  # Crash resilience: keep pane visible on exit and auto-respawn.
  tmux set-option -t "=$session_name" remain-on-exit on
  tmux set-hook -t "=$session_name" pane-died "respawn-pane -k"

  tmux send-keys -t "=$session_name" "$claude_cmd" C-m
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
  }

  trap '_sesh_select_cleanup; return 1' INT TERM HUP

  printf "${ESC}[?25l" >/dev/tty
  command stty -echo raw 2>/dev/null

  local footer_hint="[↑/↓: navigate | enter: select"
  [[ $kill_enabled -eq 1 ]] && footer_hint="${footer_hint} | d: kill"
  footer_hint="${footer_hint} | q: cancel]"

  _sesh_select_draw() {
    local i
    local lines_to_move=$((prev_num_options + 2))
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
    # Clear any leftover lines from previous draw (after deletion)
    if [[ $prev_num_options -gt $num_options ]]; then
      local extra=$(( prev_num_options - num_options ))
      for ((i = 0; i < extra; i++)); do
        printf "${ESC}[2K\r\n" >/dev/tty
      done
      # Move cursor back up to footer position
      printf "${ESC}[${extra}A" >/dev/tty
    fi
    printf "${ESC}[2K\r${ESC}[2m  %s${ESC}[0m" "$footer_hint" >/dev/tty
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
          # Strip status annotation (e.g. "session  [active]" → "session")
          target="${target%%  \[*}"
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

# Subcommand: non-interactive session listing
_sesh_list() {
  local sessions
  sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null)
  if [[ -z "$sessions" ]]; then
    echo "No active sessions."
    return 0
  fi

  # Collect data and find max name width
  local -a names=() paths=() statuses=()
  local name sess_path sess_status max_name=7
  while IFS= read -r name; do
    sess_path=$(tmux display-message -p -t "=${name}:" '#{pane_current_path}' 2>/dev/null)
    # Fallback: try SESH_PATH from session environment
    if [[ -z "$sess_path" ]]; then
      sess_path=$(tmux show-environment -t "=$name" SESH_PATH 2>/dev/null)
      sess_path="${sess_path#SESH_PATH=}"
    fi
    sess_status=$(_sesh_status "$name")
    names+=("$name")
    paths+=("$sess_path")
    statuses+=("$sess_status")
    (( ${#name} > max_name )) && max_name=${#name}
  done <<< "$sessions"

  local col1=$((max_name + 2))
  printf "%-${col1}s %-40s %s\n" "SESSION" "PATH" "STATUS"
  printf "%-${col1}s %-40s %s\n" "-------" "----" "------"

  local i
  for ((i = 1; i <= ${#names[@]}; i++)); do
    printf "%-${col1}s %-40s %s\n" "${names[$i]}" "${paths[$i]}" "[${statuses[$i]}]"
  done
}

# Subcommand: git clone + create session
_sesh_clone() {
  local url="$1"
  local name="${2:-}"

  if [[ -z "$url" ]]; then
    echo "Usage: sesh clone <url> [name]"
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
  sesh "$name" "$clone_path"
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
      local sessions
      sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null)
      if [[ -z "$sessions" ]]; then
        echo "No sessions to kill."
        return 0
      fi
      local -a session_list=()
      local name sess_status
      while IFS= read -r name; do
        sess_status=$(_sesh_status "$name")
        session_list+=("${name}  [${sess_status}]")
      done <<< "$sessions"
      if _sesh_select --kill "Kill a session:" "${session_list[@]}"; then
        local target="${SELECTED%%  \[*}"
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

# Subcommand: start Claude Code in current tmux session
_sesh_agent() {
  local base_cmd="$1"
  local initial_prompt="${2:-}"

  if [[ -z "$TMUX" ]]; then
    echo "Error: 'sesh agent' must be run inside a tmux session."
    echo "Use 'sesh new' to create a session first."
    return 1
  fi

  local claude_cmd="$base_cmd"
  local current_path
  current_path=$(tmux display-message -p '#{pane_current_path}' 2>/dev/null)
  if [[ -d "${current_path}/.claude" ]]; then
    claude_cmd="${claude_cmd} --continue"
  fi
  if [[ -n "$initial_prompt" ]]; then
    claude_cmd="${claude_cmd} -p $(printf '%q' "$initial_prompt")"
  fi
  echo "Starting Claude Code..."
  eval "$claude_cmd"
}

# Subcommand: interactive session creation wizard
_sesh_new() {
  local base_cmd="$1"
  local initial_prompt="${2:-}"

  # Prompt for session name
  local default_name
  default_name=$(_sesh_default_name)
  printf "Session name [%s]: " "$default_name"
  read -r session_name
  if [[ -z "$session_name" ]]; then
    session_name="$default_name"
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

  # Expand ~ to home directory
  project_path="${project_path/#\~/$HOME}"

  # Check if directory exists
  if [[ ! -d "$project_path" ]]; then
    printf "Directory '%s' does not exist. Create it? (y/n) " "$project_path"
    read -r REPLY
    if [[ $REPLY =~ ^[Yy] ]]; then
      mkdir -p "$project_path"
      echo "Created directory: $project_path"
    else
      echo "Aborted."
      return 1
    fi
  fi

  _sesh_create "$session_name" "$project_path" "$base_cmd" "$initial_prompt"
}

# Print usage information
_sesh_help() {
  cat <<'EOF'
Usage: sesh <command> [options]

Commands:
  sesh new                        Interactive session creation wizard
  sesh <name> [path]              Create or attach to a session
  sesh agent                      Start Claude Code in current session
  sesh last                       Toggle to previous session
  sesh list, ls                   Show all sessions with status
  sesh clone <url> [name]         Git clone + create session
  sesh kill [name|--all]          Kill sessions
  sesh help                       Show this help message
  sesh version                    Show version

Options:
  -s, --session <name>    Session name
  -p, --path <path>       Project path
  -m, --message <text>    Initial prompt for Claude
EOF
}

# Smart tmux session manager for Claude Code
sesh() {
  # Load user config if it exists
  local _sesh_config="${SESH_CONFIG:-${HOME}/.config/sesh/config}"
  [[ -f "$_sesh_config" ]] && source "$_sesh_config"

  local base_cmd="${SESH_CMD:-claude --dangerously-skip-permissions}"

  # Subcommand routing
  case "${1:-}" in
    help|--help|-h)
      _sesh_help; return 0 ;;
    version|--version|-v)
      echo "sesh $SESH_VERSION"; return 0 ;;
    last)
      shift; _sesh_last "$@"; return $? ;;
    list|ls)
      shift; _sesh_list "$@"; return $? ;;
    clone)
      shift; _sesh_clone "$@"; return $? ;;
    kill)
      shift; _sesh_kill "$@"; return $? ;;
    agent)
      shift
      local initial_prompt=""
      while [[ $# -gt 0 ]]; do
        case $1 in
          -m|--message) initial_prompt="$2"; shift 2 ;;
          *) initial_prompt="$1"; shift ;;
        esac
      done
      _sesh_agent "$base_cmd" "$initial_prompt"; return $? ;;
    new)
      shift
      local initial_prompt=""
      while [[ $# -gt 0 ]]; do
        case $1 in
          -m|--message) initial_prompt="$2"; shift 2 ;;
          *) shift ;;
        esac
      done
      _sesh_new "$base_cmd" "$initial_prompt"; return $? ;;
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
        session_name="$2"
        shift 2
        ;;
      -p|--path)
        project_path="$2"
        shift 2
        ;;
      -m|--message)
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

  # Expand ~ to home directory
  project_path="${project_path/#\~/$HOME}"

  # Check if directory exists
  if [[ ! -d "$project_path" ]]; then
    printf "Directory '%s' does not exist. Create it? (y/n) " "$project_path"
    read -r REPLY
    if [[ $REPLY =~ ^[Yy] ]]; then
      mkdir -p "$project_path"
      echo "Created directory: $project_path"
    else
      echo "Aborted."
      return 1
    fi
  fi

  _sesh_create "$session_name" "$project_path" "$base_cmd" "$initial_prompt"
}
