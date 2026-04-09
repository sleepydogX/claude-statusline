#!/bin/bash
# Claude Statusline — Uninstaller

set -e

BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
RESET='\033[0m'

CLAUDE_DIR="$HOME/.claude"
HOOKS_DIR="$CLAUDE_DIR/hooks"
CONFIG_FILE="$CLAUDE_DIR/statusline-config.json"

echo ""
echo -e "${YELLOW}${BOLD}  Claude Code Statusline — Uninstaller${RESET}"
echo ""

removed=0

if [ -f "$HOOKS_DIR/gsd-statusline.js" ]; then
  rm "$HOOKS_DIR/gsd-statusline.js"
  echo -e "${GREEN}  ✓ Removed statusline hook${RESET}"
  removed=1
fi

if [ -f "$CONFIG_FILE" ]; then
  rm "$CONFIG_FILE"
  echo -e "${GREEN}  ✓ Removed config file${RESET}"
  removed=1
fi

# Clean up backups
for backup in "$HOOKS_DIR"/gsd-statusline.js.backup.*; do
  if [ -f "$backup" ]; then
    rm "$backup"
    echo -e "${GREEN}  ✓ Removed backup: $(basename "$backup")${RESET}"
    removed=1
  fi
done

if [ "$removed" -eq 0 ]; then
  echo -e "${DIM}  Nothing to remove — statusline was not installed.${RESET}"
else
  echo ""
  echo -e "${GREEN}${BOLD}  ✓ Uninstall complete.${RESET}"
  echo -e "${DIM}  Restart Claude Code to apply changes.${RESET}"
fi

echo ""
