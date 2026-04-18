#!/usr/bin/env bash
# Tests install.sh by running it against a sandboxed $HOME.
set -e
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SANDBOX="$(mktemp -d)"
mkdir -p "$SANDBOX/.claude"

trap "rm -rf $SANDBOX" EXIT

# Run installer in global mode with all defaults accepted
# Choice 1 = global scope, then y/Y for every module prompt
HOME="$SANDBOX" bash "$REPO_DIR/install.sh" <<< "1
y
y
y
y
y
y
y
y
y
y
y
y
y
" >/dev/null

# Assertions
SETTINGS="$SANDBOX/.claude/settings.json"
CONFIG="$SANDBOX/.claude/statusline-config.json"
HOOK="$SANDBOX/.claude/hooks/gsd-statusline.js"

[ -f "$HOOK" ]     || { echo "FAIL: hook file missing"; exit 1; }
[ -f "$CONFIG" ]   || { echo "FAIL: config file missing"; exit 1; }
[ -f "$SETTINGS" ] || { echo "FAIL: settings.json not created"; exit 1; }

grep -q '"statusLine"' "$SETTINGS" || { echo "FAIL: statusLine block not in settings.json"; exit 1; }
grep -q 'gsd-statusline.js' "$SETTINGS" || { echo "FAIL: hook path not in statusLine.command"; exit 1; }

# New module flags must all be present in config
for flag in effort output_style permission_mode fast_mode mcp_health; do
  grep -q "\"$flag\"" "$CONFIG" || { echo "FAIL: $flag missing from config"; exit 1; }
done

# Snapshot state
BEFORE_SETTINGS=$(cat "$SETTINGS")
BEFORE_CONFIG=$(cat "$CONFIG")

# Re-run installer (upgrade mode should be detected; no prompts should change state)
HOME="$SANDBOX" bash "$REPO_DIR/install.sh" <<< "y
" >/dev/null

AFTER_SETTINGS=$(cat "$SETTINGS")
AFTER_CONFIG=$(cat "$CONFIG")

[ "$BEFORE_SETTINGS" = "$AFTER_SETTINGS" ] || { echo "FAIL: settings.json changed on re-run"; exit 1; }
[ "$BEFORE_CONFIG" = "$AFTER_CONFIG" ] || { echo "FAIL: config changed on re-run"; exit 1; }

# Slash command assertions
CMD_FILE="$SANDBOX/.claude/commands/statusline-update.md"
[ -f "$CMD_FILE" ] || { echo "FAIL: slash command not installed"; exit 1; }
grep -q "$REPO_DIR" "$CMD_FILE" || { echo "FAIL: repo path not substituted in slash command"; exit 1; }
grep -q '__REPO_PATH__' "$CMD_FILE" && { echo "FAIL: template placeholder still present"; exit 1; }

echo "PASS: slash command installed with correct repo path"
echo "PASS: idempotent upgrade"
echo "PASS: installer writes settings.json and all new module flags"
