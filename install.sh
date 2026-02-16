#!/bin/bash
# sesh installer - Smart tmux session manager for Claude Code
# https://github.com/nathangathright/sesh
#
# Usage: curl -fsSL https://raw.githubusercontent.com/nathangathright/sesh/main/install.sh | bash

set -e

SESH_MARKER_START="# >>> sesh >>>"
SESH_MARKER_END="# <<< sesh <<<"

# Determine shell config file (prefer the user's login shell)
SHELL_CONFIG=""
case "${SHELL##*/}" in
  zsh)  [ -f "$HOME/.zshrc" ] && SHELL_CONFIG="$HOME/.zshrc" ;;
  bash)
    if [ -f "$HOME/.bashrc" ]; then
      SHELL_CONFIG="$HOME/.bashrc"
    elif [ -f "$HOME/.bash_profile" ]; then
      SHELL_CONFIG="$HOME/.bash_profile"
    fi
    ;;
esac
# Fallback: try common configs regardless of $SHELL
if [ -z "$SHELL_CONFIG" ]; then
  if [ -f "$HOME/.zshrc" ]; then
    SHELL_CONFIG="$HOME/.zshrc"
  elif [ -f "$HOME/.bashrc" ]; then
    SHELL_CONFIG="$HOME/.bashrc"
  elif [ -f "$HOME/.bash_profile" ]; then
    SHELL_CONFIG="$HOME/.bash_profile"
  fi
fi
if [ -z "$SHELL_CONFIG" ]; then
  echo "Could not find shell config file (~/.zshrc, ~/.bashrc, or ~/.bash_profile)"
  exit 1
fi

# Fetch sesh.sh from the repo (or use local copy if running from repo)
SESH_SOURCE=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}" 2>/dev/null)" && pwd 2>/dev/null)"

if [ -f "$SCRIPT_DIR/sesh.sh" ]; then
  SESH_SOURCE="$SCRIPT_DIR/sesh.sh"
else
  # Download from GitHub
  SESH_SOURCE=$(mktemp)
  curl -fsSL "https://raw.githubusercontent.com/nathangathright/sesh/main/sesh.sh" -o "$SESH_SOURCE"
  trap 'rm -f "$SESH_SOURCE"' EXIT
fi

UPDATING=0

# Check for existing installation
if grep -q "$SESH_MARKER_START" "$SHELL_CONFIG" 2>/dev/null; then
  # Marked installation exists — update in place
  UPDATING=1
  TMP_CONFIG=$(mktemp)
  awk -v start="$SESH_MARKER_START" -v end="$SESH_MARKER_END" '
    $0 == start { skip=1; next }
    $0 == end { skip=0; next }
    !skip { print }
  ' "$SHELL_CONFIG" > "$TMP_CONFIG"
  mv "$TMP_CONFIG" "$SHELL_CONFIG"
elif grep -q "sesh()" "$SHELL_CONFIG" 2>/dev/null; then
  # Legacy installation without markers
  echo "sesh is installed in $SHELL_CONFIG but without update markers."
  echo ""
  echo "To update, first remove the existing installation:"
  echo "  Search for '# sesh - Smart tmux session manager' in $SHELL_CONFIG"
  echo "  Delete from that line through the closing } of the sesh() function"
  echo "  Then re-run this installer"
  exit 0
fi

# Append marked content to shell config
if [ "$UPDATING" -eq 0 ]; then
  echo "" >> "$SHELL_CONFIG"
fi
{
  echo "$SESH_MARKER_START"
  cat "$SESH_SOURCE"
  echo "$SESH_MARKER_END"
} >> "$SHELL_CONFIG"

if [ "$UPDATING" -eq 1 ]; then
  echo "sesh updated in $SHELL_CONFIG"
else
  echo "sesh installed to $SHELL_CONFIG"
fi
echo ""
echo "To start using sesh, run:"
echo "  source $SHELL_CONFIG"
echo ""
echo "Usage:"
echo "  sesh new                    # Interactive session creation wizard"
echo "  sesh myproject ~/code       # Create/attach 'myproject' session at ~/code"
echo "  sesh agent                  # Start Claude Code (inside tmux)"
echo "  sesh help                   # Show all commands and options"
