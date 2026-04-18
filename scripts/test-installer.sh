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

echo "PASS: installer writes settings.json and all new module flags"
