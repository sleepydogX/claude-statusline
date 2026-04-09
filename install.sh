#!/bin/bash
# Claude Statusline — Interactive Installer
# https://github.com/sleepydogX/claude-statusline

set -e

# Colors
BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[36m'
MAGENTA='\033[35m'
RED='\033[31m'
RESET='\033[0m'

CLAUDE_DIR="$HOME/.claude"
HOOKS_DIR="$CLAUDE_DIR/hooks"
CONFIG_FILE="$CLAUDE_DIR/statusline-config.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo ""
echo -e "${MAGENTA}${BOLD}  ╔══════════════════════════════════════════════╗${RESET}"
echo -e "${MAGENTA}${BOLD}  ║     Claude Code Statusline — Installer      ║${RESET}"
echo -e "${MAGENTA}${BOLD}  ╚══════════════════════════════════════════════╝${RESET}"
echo ""

# Check prerequisites
if ! command -v node &> /dev/null; then
  echo -e "${RED}Error: Node.js is required but not installed.${RESET}"
  exit 1
fi

if [ ! -d "$CLAUDE_DIR" ]; then
  echo -e "${RED}Error: ~/.claude directory not found. Is Claude Code installed?${RESET}"
  exit 1
fi

# Create hooks directory if needed
mkdir -p "$HOOKS_DIR"

# Check for existing statusline
if [ -f "$HOOKS_DIR/gsd-statusline.js" ]; then
  echo -e "${YELLOW}An existing statusline was found at:${RESET}"
  echo -e "${DIM}  $HOOKS_DIR/gsd-statusline.js${RESET}"
  echo ""
  read -p "  Overwrite it? (y/N): " overwrite
  if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Installation cancelled.${RESET}"
    exit 0
  fi
  # Backup
  cp "$HOOKS_DIR/gsd-statusline.js" "$HOOKS_DIR/gsd-statusline.js.backup.$(date +%s)"
  echo -e "${DIM}  Backup saved.${RESET}"
fi

echo ""
echo -e "${CYAN}${BOLD}  Select which modules to enable:${RESET}"
echo ""

# Module selection
ask_module() {
  local name="$1"
  local desc="$2"
  local default="$3"
  local emoji="$4"

  if [ "$default" = "y" ]; then
    prompt="(Y/n)"
  else
    prompt="(y/N)"
  fi

  read -p "  $emoji $desc $prompt: " answer
  answer="${answer:-$default}"

  if [[ "$answer" =~ ^[Yy]$ ]]; then
    echo "true"
  else
    echo "false"
  fi
}

mod_session_name=$(ask_module "session_name" "Session name (random slug identifier)" "y" "🏷 ")
mod_cost=$(ask_module "cost" "Projected cost in USD" "y" "💰")
mod_duration=$(ask_module "duration" "Session duration timer" "y" "⏱ ")
mod_rate_limits=$(ask_module "rate_limits" "Rate limits (5h + 7d usage)" "y" "⚡")
mod_lines_changed=$(ask_module "lines_changed" "Lines added/removed" "y" "📊")
mod_context_bridge=$(ask_module "context_bridge" "Context metrics bridge (for other hooks)" "y" "🔗")

echo ""
echo -e "${CYAN}${BOLD}  External integrations (require CLI tools):${RESET}"
echo ""

# Check if gh is available
mod_github="false"
if command -v gh &> /dev/null; then
  mod_github=$(ask_module "github" "GitHub repo, branch & account (gh CLI detected)" "y" "🐙")
else
  echo -e "  🐙 GitHub — ${DIM}skipped (gh CLI not found)${RESET}"
fi

# Check if supabase is available
mod_supabase="false"
if command -v supabase &> /dev/null; then
  mod_supabase=$(ask_module "supabase" "Supabase linked project (supabase CLI detected)" "y" "⚡")
else
  echo -e "  ⚡ Supabase — ${DIM}skipped (supabase CLI not found)${RESET}"
fi

# Write config
echo ""
echo -e "${DIM}  Writing configuration...${RESET}"

cat > "$CONFIG_FILE" << EOF
{
  "session_name": $mod_session_name,
  "cost": $mod_cost,
  "duration": $mod_duration,
  "rate_limits": $mod_rate_limits,
  "lines_changed": $mod_lines_changed,
  "context_bridge": $mod_context_bridge,
  "github": $mod_github,
  "supabase": $mod_supabase
}
EOF

echo -e "${GREEN}  Config saved to $CONFIG_FILE${RESET}"

# Copy statusline
echo -e "${DIM}  Installing statusline hook...${RESET}"
cp "$SCRIPT_DIR/statusline.js" "$HOOKS_DIR/gsd-statusline.js"
chmod +x "$HOOKS_DIR/gsd-statusline.js"

echo ""
echo -e "${GREEN}${BOLD}  ✓ Installation complete!${RESET}"
echo ""
echo -e "${DIM}  Statusline:  $HOOKS_DIR/gsd-statusline.js${RESET}"
echo -e "${DIM}  Config:      $CONFIG_FILE${RESET}"
echo ""
echo -e "  ${CYAN}Start a new Claude Code session to see your statusline.${RESET}"
echo -e "  ${DIM}To reconfigure, run this installer again or edit $CONFIG_FILE${RESET}"
echo ""
