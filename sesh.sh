# sesh - Smart tmux session manager for Claude Code
# https://github.com/nathangathright/sesh

# Interactive menu helper (arrow keys + enter)
_sesh_select() {
  local prompt="$1"
  shift
  local -a options=("$@")
  local num_options=${#options[@]}
  local selected=0
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

  _sesh_select_draw() {
    local i
    [[ ${1:-0} -eq 1 ]] && printf "${ESC}[$((num_options + 2))A" >/dev/tty
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
    printf "${ESC}[2K\r${ESC}[2m  [↑/↓: navigate | enter: select | q: cancel]${ESC}[0m" >/dev/tty
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
        ;;
      k) selected=$(( (selected - 1 + num_options) % num_options )) ;;
      j) selected=$(( (selected + 1) % num_options )) ;;
    esac
    _sesh_select_draw 1
  done
}

# Smart tmux session manager for Claude Code
sesh() {
  local session_name=""
  local project_path=""

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
      *)
        # Positional arguments: first is session, second is path
        if [ -z "$session_name" ]; then
          session_name="$1"
        elif [ -z "$project_path" ]; then
          project_path="$1"
        fi
        shift
        ;;
    esac
  done

  # Check if we're already inside a tmux session
  if [ -n "$TMUX" ]; then
    # We're inside tmux - resume/start Claude Code
    echo "🔄 Starting Claude Code..."
    claude --dangerously-skip-permissions --continue
    return
  fi

  # If no session name provided, check existing sessions
  if [ -z "$session_name" ]; then
    # Get list of existing sessions
    local sessions=$(tmux list-sessions -F "#{session_name}" 2>/dev/null)
    local session_count=0

    if [ -n "$sessions" ]; then
      session_count=$(echo "$sessions" | wc -l | tr -d ' ')
    fi

    if [ "$session_count" -eq 1 ]; then
      # Only one session, attach to it
      session_name=$(echo "$sessions" | head -1)
      echo "🔗 Attaching to session: $session_name"
      tmux attach -t "$session_name"
      return
    elif [ "$session_count" -gt 1 ]; then
      # Multiple sessions, let user choose with interactive menu
      local -a session_list=("${(@f)sessions}")
      if _sesh_select "📋 Select a session:" "${session_list[@]}"; then
        session_name="$SELECTED"
        echo "🔗 Attaching to session: $session_name"
        tmux attach -t "$session_name"
        return
      else
        echo "❌ Cancelled"
        return 1
      fi
    else
      # No sessions exist - prompt for new session details
      local default_name=$(basename "$PWD")
      printf "📝 Session name [%s]: " "$default_name"
      read session_name
      if [ -z "$session_name" ]; then
        session_name="$default_name"
      fi

      local default_path="$PWD"
      printf "📂 Project path [%s]: " "$default_path"
      read project_path
      if [ -z "$project_path" ]; then
        project_path="$default_path"
      fi
    fi
  fi

  # Check if session already exists (when session name was provided)
  if tmux has-session -t "$session_name" 2>/dev/null; then
    echo "🔗 Attaching to existing session: $session_name"
    tmux attach -t "$session_name"
    return
  fi

  # If no path provided yet, prompt for it
  if [ -z "$project_path" ]; then
    local default_path="$PWD"
    printf "📂 Project path [%s]: " "$default_path"
    read project_path
    if [ -z "$project_path" ]; then
      project_path="$default_path"
    fi
  fi

  # Expand ~ to home directory
  project_path="${project_path/#\~/$HOME}"

  # Check if directory exists
  if [ ! -d "$project_path" ]; then
    printf "❓ Directory '%s' does not exist. Create it? (y/n) " "$project_path"
    read REPLY
    if [[ $REPLY =~ ^[Yy] ]]; then
      mkdir -p "$project_path"
      echo "✅ Created directory: $project_path"
    else
      echo "❌ Aborted."
      return 1
    fi
  fi

  # Create new session, navigate to path, and start Claude Code
  echo "✨ Creating new session '$session_name' at $project_path"
  tmux new-session -s "$session_name" -c "$project_path" -d
  tmux send-keys -t "$session_name" "claude --dangerously-skip-permissions" C-m
  tmux attach -t "$session_name"
}
