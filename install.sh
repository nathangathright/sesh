#!/bin/bash
# sesh installer - Smart tmux session manager for Claude Code
# https://github.com/nathangathright/sesh
#
# Usage: curl -fsSL https://raw.githubusercontent.com/nathangathright/sesh/main/install.sh | bash

set -e

# Determine shell config file
SHELL_CONFIG=""
if [ -f "$HOME/.zshrc" ]; then
  SHELL_CONFIG="$HOME/.zshrc"
elif [ -f "$HOME/.bashrc" ]; then
  SHELL_CONFIG="$HOME/.bashrc"
elif [ -f "$HOME/.bash_profile" ]; then
  SHELL_CONFIG="$HOME/.bash_profile"
else
  echo "❌ Could not find shell config file (~/.zshrc, ~/.bashrc, or ~/.bash_profile)"
  exit 1
fi

# Check if already installed
if grep -q "sesh()" "$SHELL_CONFIG" 2>/dev/null; then
  echo "✅ sesh is already installed in $SHELL_CONFIG"
  echo ""
  echo "To update, first remove the existing installation:"
  echo "  Remove the _sesh_select() and sesh() functions from $SHELL_CONFIG"
  echo "  Then re-run this installer"
  exit 0
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
  trap "rm -f '$SESH_SOURCE'" EXIT
fi

# Append to shell config
echo "" >> "$SHELL_CONFIG"
cat "$SESH_SOURCE" >> "$SHELL_CONFIG"

echo "✅ sesh installed to $SHELL_CONFIG"
echo ""
echo "To start using sesh, run:"
echo "  source $SHELL_CONFIG"
echo ""
echo "Usage:"
echo "  sesh                        # Smart: detects sessions, prompts when needed"
echo "  sesh myproject ~/code       # Create/attach 'myproject' session at ~/code"
echo "  sesh -s work -p ~/app       # Using named parameters"
echo ""
echo "How it works:"
echo "  Inside tmux  → Resumes Claude Code"
echo "  0 sessions   → Prompts for name and path"
echo "  1 session    → Auto-attaches"
echo "  N sessions   → Interactive menu (arrow keys + enter)"
