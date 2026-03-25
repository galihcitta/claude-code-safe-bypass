#!/usr/bin/env bash
# Claude Code Safe Bypass — Installer
# Copies guard hooks to ~/.claude/hooks/ and configures your shell alias.

set -euo pipefail

HOOKS_DIR="$HOME/.claude/hooks"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
USERNAME="$(whoami)"
HOME_LOWER="$(echo "$HOME" | tr '[:upper:]' '[:lower:]')"

echo "Claude Code Safe Bypass — Installer"
echo "====================================="
echo ""

# Check dependencies
if ! command -v jq &>/dev/null; then
  echo "❌ jq is required but not installed."
  echo "   Install with: brew install jq"
  exit 1
fi

# Create hooks directory
mkdir -p "$HOOKS_DIR"

# Copy guard.sh
cp "$SCRIPT_DIR/hooks/guard.sh" "$HOOKS_DIR/guard.sh"
chmod +x "$HOOKS_DIR/guard.sh"
echo "✓ Installed guard.sh"

# Copy patterns.conf with username substitution
sed "s|YOUR_USERNAME|$USERNAME|g" "$SCRIPT_DIR/hooks/patterns.conf" > "$HOOKS_DIR/patterns.conf"
echo "✓ Installed patterns.conf (configured for user: $USERNAME)"

# Copy settings.json with absolute path
sed "s|~/.claude/hooks|$HOOKS_DIR|g" "$SCRIPT_DIR/hooks/settings.json" > "$HOOKS_DIR/settings.json"
echo "✓ Installed settings.json"

# Add shell alias
ALIAS_LINE="alias claudex=\"claude --dangerously-skip-permissions --settings $HOOKS_DIR/settings.json\""
SHELL_RC=""

if [[ -f "$HOME/.zshrc" ]]; then
  SHELL_RC="$HOME/.zshrc"
elif [[ -f "$HOME/.bashrc" ]]; then
  SHELL_RC="$HOME/.bashrc"
fi

if [[ -n "$SHELL_RC" ]]; then
  if grep -q "claudex" "$SHELL_RC" 2>/dev/null; then
    echo "✓ Shell alias already exists in $SHELL_RC"
  else
    echo "" >> "$SHELL_RC"
    echo "# Claude Code with bypass permissions (guarded by ~/.claude/hooks/guard.sh)" >> "$SHELL_RC"
    echo "$ALIAS_LINE" >> "$SHELL_RC"
    echo "✓ Added 'claudex' alias to $SHELL_RC"
  fi
else
  echo "⚠ Could not find .zshrc or .bashrc. Add this alias manually:"
  echo "  $ALIAS_LINE"
fi

echo ""
echo "Done! Run 'source $SHELL_RC' or open a new terminal, then:"
echo "  claudex        — bypass mode with guard protection"
echo "  claude          — normal mode with permission prompts"
echo ""
echo "To customize: edit $HOOKS_DIR/patterns.conf"
echo "To check logs: cat $HOOKS_DIR/guard.log"
echo "To disable temporarily: CLAUDE_GUARD_OFF=1 claudex"
