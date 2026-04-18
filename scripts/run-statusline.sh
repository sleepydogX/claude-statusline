#!/usr/bin/env bash
# Usage: run-statusline.sh <fixture.json> [settings.json]
# Runs statusline.js with a sandboxed $HOME and returns stdout.
set -e
FIXTURE="$1"
SETTINGS="$2"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

SANDBOX="$(mktemp -d)"
mkdir -p "$SANDBOX/.claude"
if [ -n "$SETTINGS" ] && [ -f "$SETTINGS" ]; then
  cp "$SETTINGS" "$SANDBOX/.claude/settings.json"
fi

HOME="$SANDBOX" node "$REPO_DIR/statusline.js" < "$FIXTURE"
rm -rf "$SANDBOX"
