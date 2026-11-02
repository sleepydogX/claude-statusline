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
node -e 'process.exit(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).statusLine.refreshInterval === 10 ? 0 : 1)' "$SETTINGS" \
  || { echo "FAIL: fresh install did not set statusLine.refreshInterval"; exit 1; }

for flag in effort output_style fast_mode pr subagents; do
  grep -q "\"$flag\"" "$CONFIG" || { echo "FAIL: $flag missing from config"; exit 1; }
done

# Toggles for removed segments must not be written back
for flag in permission_mode mcp_health; do
  grep -q "\"$flag\"" "$CONFIG" && { echo "FAIL: removed flag $flag still in config"; exit 1; }
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

# Upgrading a pre-cleanup config must drop the stale toggles and keep the rest
cat > "$CONFIG" <<'OLDCONFIG'
{
  "session_name": false,
  "cost": true,
  "permission_mode": true,
  "mcp_health": true
}
OLDCONFIG
HOME="$SANDBOX" bash "$REPO_DIR/install.sh" <<< "y
" >/dev/null

grep -q '"permission_mode"' "$CONFIG" && { echo "FAIL: permission_mode survived upgrade"; exit 1; }
grep -q '"mcp_health"' "$CONFIG" && { echo "FAIL: mcp_health survived upgrade"; exit 1; }
grep -q '"session_name": false' "$CONFIG" || { echo "FAIL: upgrade clobbered an existing user value"; exit 1; }
grep -q '"fast_mode"' "$CONFIG" || { echo "FAIL: upgrade did not add missing flags"; exit 1; }

# Upgrading an install from before refreshInterval adds it...
refresh_of() { node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).statusLine.refreshInterval)' "$SETTINGS"; }
node -e 'const f=process.argv[1],fs=require("fs"),c=JSON.parse(fs.readFileSync(f,"utf8"));delete c.statusLine.refreshInterval;fs.writeFileSync(f,JSON.stringify(c))' "$SETTINGS"
HOME="$SANDBOX" bash "$REPO_DIR/install.sh" <<< "y
" >/dev/null
[ "$(refresh_of)" = "10" ] || { echo "FAIL: upgrade did not add refreshInterval"; exit 1; }
# ...but keeps one the user chose.
node -e 'const f=process.argv[1],fs=require("fs"),c=JSON.parse(fs.readFileSync(f,"utf8"));c.statusLine.refreshInterval=3;fs.writeFileSync(f,JSON.stringify(c))' "$SETTINGS"
HOME="$SANDBOX" bash "$REPO_DIR/install.sh" <<< "y
" >/dev/null
[ "$(refresh_of)" = "3" ] || { echo "FAIL: upgrade overwrote the user's refreshInterval"; exit 1; }

echo "PASS: upgrade adds a missing refreshInterval and keeps a user-set one"
echo "PASS: slash command installed with correct repo path"
echo "PASS: idempotent upgrade"
echo "PASS: installer writes settings.json and all new module flags"
echo "PASS: upgrade prunes removed toggles and preserves user values"
