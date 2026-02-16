# sesh - Smart tmux session manager for Claude Code
# https://github.com/nathangathright/sesh

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
  local cmds
  cmds=$(tmux list-panes -t "$target" -F '#{pane_current_command}' 2>/dev/null)
  if [[ -z "$cmds" ]]; then
    printf 'dead'
  elif printf '%s' "$cmds" | grep -q 'node'; then
    printf 'active'
  else
    # Check if all panes are dead (remain-on-exit keeps them visible)
    local dead_count
    dead_count=$(tmux list-panes -t "$target" -F '#{pane_dead}' 2>/dev/null | grep -c '1')
    local total_count
    total_count=$(tmux list-panes -t "$target" -F '#{pane_dead}' 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$dead_count" -eq "$total_count" && "$total_count" -gt 0 ]]; then
      printf 'dead'
    else
      printf 'idle'
    fi
  fi
}

# Interactive menu helper (arrow keys + enter)
# Usage: _sesh_select [--kill] "prompt" option1 option2 ...
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
          tmux kill-session -t "$target" 2>/dev/null
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

  if ! tmux has-session -t "$target" 2>/dev/null; then
    echo "Previous session '$target' no longer exists."
    return 1
  fi

  _sesh_track_last "$target"
  if [[ -n "$TMUX" ]]; then
    tmux switch-client -t "$target"
  else
    tmux attach -t "$target"
  fi
}

# Subcommand: non-interactive session listing
_sesh_list() {
  local sessions
  sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null)
  if [[ -z "$sessions" ]]; then
    echo "No active sessions."
    return 0
  fi

  printf "%-20s %-40s %s\n" "SESSION" "PATH" "STATUS"
  printf "%-20s %-40s %s\n" "-------" "----" "------"

  local name path status
  while IFS= read -r name; do
    path=$(tmux display-message -p -t "${name}:" '#{pane_current_path}' 2>/dev/null)
    status=$(_sesh_status "$name")
    printf "%-20s %-40s %s\n" "$name" "$path" "[$status]"
  done <<< "$sessions"
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
      local name
      while IFS= read -r name; do
        tmux kill-session -t "$name" 2>/dev/null && echo "Killed session: $name"
      done <<< "$sessions"
      ;;
    "")
      # No args: show picker
      local sessions
      sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null)
      if [[ -z "$sessions" ]]; then
        echo "No sessions to kill."
        return 0
      fi
      local -a session_list=("${(@f)sessions}")
      if _sesh_select --kill "Kill a session:" "${session_list[@]}"; then
        local target="${SELECTED%%  \[*}"
        tmux kill-session -t "$target" 2>/dev/null && echo "Killed session: $target"
      fi
      ;;
    *)
      # Kill named session
      if tmux has-session -t "$1" 2>/dev/null; then
        tmux kill-session -t "$1" && echo "Killed session: $1"
      else
        echo "Session '$1' not found."
        return 1
      fi
      ;;
  esac
}

# Smart tmux session manager for Claude Code
sesh() {
  # Load user config if it exists
  local _sesh_config="${SESH_CONFIG:-${HOME}/.config/sesh/config}"
  [[ -f "$_sesh_config" ]] && source "$_sesh_config"

  # Subcommand routing
  case "${1:-}" in
    last)
      shift; _sesh_last "$@"; return $? ;;
    list|ls)
      shift; _sesh_list "$@"; return $? ;;
    clone)
      shift; _sesh_clone "$@"; return $? ;;
    kill)
      shift; _sesh_kill "$@"; return $? ;;
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
        # Positional: first=session, second=path, third=prompt
        if [[ -z "$session_name" ]]; then
          session_name="$1"
        elif [[ -z "$project_path" ]]; then
          project_path="$1"
        elif [[ -z "$initial_prompt" ]]; then
          initial_prompt="$1"
        fi
        shift
        ;;
    esac
  done

  local base_cmd="${SESH_CMD:-claude --dangerously-skip-permissions}"

  # Check if we're already inside a tmux session
  if [[ -n "$TMUX" ]]; then
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
    return
  fi

  # Zoxide integration: resolve path when name given but no path
  if [[ -n "$session_name" && -z "$project_path" ]]; then
    if command -v zoxide &>/dev/null; then
      local zoxide_result
      zoxide_result=$(zoxide query "$session_name" 2>/dev/null)
      if [[ -n "$zoxide_result" ]]; then
        project_path="$zoxide_result"
      fi
    fi
  fi

  # If no session name provided, check existing sessions
  if [[ -z "$session_name" ]]; then
    local sessions
    sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null)
    local session_count=0

    if [[ -n "$sessions" ]]; then
      session_count=$(echo "$sessions" | wc -l | tr -d ' ')
    fi

    if [[ "$session_count" -eq 1 ]]; then
      session_name=$(echo "$sessions" | head -1)
      echo "Attaching to session: $session_name"
      _sesh_track_last "$session_name"
      tmux attach -t "$session_name"
      return
    elif [[ "$session_count" -gt 1 ]]; then
      # Build display list with status annotations
      local -a session_list=()
      local name status
      while IFS= read -r name; do
        status=$(_sesh_status "$name")
        session_list+=("${name}  [${status}]")
      done <<< "$sessions"

      if _sesh_select --kill "Select a session:" "${session_list[@]}"; then
        # Strip status annotation
        session_name="${SELECTED%%  \[*}"
        echo "Attaching to session: $session_name"
        _sesh_track_last "$session_name"
        tmux attach -t "$session_name"
        return
      else
        echo "Cancelled."
        return 1
      fi
    else
      # No sessions exist - prompt for new session details
      local default_name
      default_name=$(_sesh_default_name)
      printf "Session name [%s]: " "$default_name"
      read session_name
      if [[ -z "$session_name" ]]; then
        session_name="$default_name"
      fi

      local default_path="$PWD"
      printf "Project path [%s]: " "$default_path"
      read project_path
      if [[ -z "$project_path" ]]; then
        project_path="$default_path"
      fi
    fi
  fi

  # Check if session already exists (when session name was provided)
  if tmux has-session -t "$session_name" 2>/dev/null; then
    echo "Attaching to existing session: $session_name"
    _sesh_track_last "$session_name"
    tmux attach -t "$session_name"
    return
  fi

  # If no path provided yet, prompt for it
  if [[ -z "$project_path" ]]; then
    local default_path="$PWD"
    printf "Project path [%s]: " "$default_path"
    read project_path
    if [[ -z "$project_path" ]]; then
      project_path="$default_path"
    fi
  fi

  # Expand ~ to home directory
  project_path="${project_path/#\~/$HOME}"

  # Check if directory exists
  if [[ ! -d "$project_path" ]]; then
    printf "Directory '%s' does not exist. Create it? (y/n) " "$project_path"
    read REPLY
    if [[ $REPLY =~ ^[Yy] ]]; then
      mkdir -p "$project_path"
      echo "Created directory: $project_path"
    else
      echo "Aborted."
      return 1
    fi
  fi

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
  tmux set-environment -t "$session_name" SESH_SESSION "$session_name"
  tmux set-environment -t "$session_name" SESH_PATH "$project_path"

  # Crash resilience: keep pane visible on exit and auto-respawn
  tmux set-option -t "$session_name" remain-on-exit on
  tmux set-hook -t "$session_name" pane-died "respawn-pane -k"

  tmux send-keys -t "$session_name" "$claude_cmd" C-m
  _sesh_track_last "$session_name"
  tmux attach -t "$session_name"
}
