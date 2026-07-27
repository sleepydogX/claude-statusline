#!/usr/bin/env bash
# Smoke tests for statusline.js. Each test runs a fixture and greps output.
set -u
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="$REPO_DIR/scripts/run-statusline.sh"
FIXTURES="$REPO_DIR/scripts/fixtures"
PASS=0
FAIL=0
FAILED_TESTS=()

run_test() {
  local name="$1"
  local fixture="$2"
  local settings="$3"
  local env_kv="$4"
  local pattern="$5"
  local expect="$6"  # "present" or "absent"

  local out
  out=$(env -i HOME=/tmp PATH="$PATH" $env_kv bash "$RUNNER" "$fixture" "$settings" 2>/dev/null || true)

  if [ "$expect" = "present" ]; then
    if echo "$out" | grep -qE "$pattern"; then
      PASS=$((PASS+1))
      echo "  PASS: $name"
    else
      FAIL=$((FAIL+1))
      FAILED_TESTS+=("$name (expected pattern present: $pattern)")
      echo "  FAIL: $name"
    fi
  else
    if echo "$out" | grep -qE "$pattern"; then
      FAIL=$((FAIL+1))
      FAILED_TESTS+=("$name (expected pattern absent: $pattern)")
      echo "  FAIL: $name"
    else
      PASS=$((PASS+1))
      echo "  PASS: $name"
    fi
  fi
}

# Test 1: baseline renders without crashing
run_test "1-minimal-renders" "$FIXTURES/minimal.json" "" "" "Claude Opus" "present"

# Test 2: effort high from settings renders "HIGH" with yellow ANSI
run_test "2-effort-high-from-settings" "$FIXTURES/minimal.json" "$FIXTURES/settings-effort-high.json" "" $'\x1b\\[33m.*HIGH' "present"

# Test 3: env override with xhigh appends asterisk
run_test "3-effort-env-override-marker" "$FIXTURES/minimal.json" "" "CLAUDE_CODE_EFFORT_LEVEL=xhigh" "XHIGH\\*" "present"

# Test 4: env auto does NOT mark as override
run_test "4-effort-env-auto-no-marker" "$FIXTURES/minimal.json" "$FIXTURES/settings-effort-high.json" "CLAUDE_CODE_EFFORT_LEVEL=auto" "HIGH\\*" "absent"

# Test 5: invalid effort value renders "?" placeholder
run_test "5-effort-invalid-placeholder" "$FIXTURES/minimal.json" "$FIXTURES/settings-effort-invalid.json" "" "🧠 \\?" "present"

# Test 6: no settings and no env shows "auto" default
run_test "6-effort-auto-default" "$FIXTURES/minimal.json" "" "" "🧠 auto" "present"

# Test 7: output_style default is hidden
run_test "7-output-style-default-hidden" "$FIXTURES/minimal.json" "" "" "explanatory" "absent"

# Test 8: output_style non-default renders in cyan
run_test "8-output-style-explanatory-shown" "$FIXTURES/output-style-explanatory.json" "" "" $'\x1b\\[36m.*style: explanatory' "present"

# Test 12: fastMode=true renders "FAST" in bold bright cyan
run_test "12-fast-mode-on" "$FIXTURES/minimal.json" "$FIXTURES/settings-fastmode.json" "" $'\x1b\\[1;96m.*FAST' "present"

# Test 13: fastMode absent is hidden
run_test "13-fast-mode-off-hidden" "$FIXTURES/minimal.json" "" "" "FAST" "absent"

# Test 18: malformed settings.json does not crash; other segments render
run_test "18-malformed-settings-survives" "$FIXTURES/minimal.json" "$FIXTURES/settings-malformed.txt" "" "Claude Opus" "present"

# Test 19: malformed settings.json does not show effort HIGH (settings unreadable)
run_test "19-malformed-settings-no-effort-value" "$FIXTURES/minimal.json" "$FIXTURES/settings-malformed.txt" "" "HIGH" "absent"

# Test 23: fastMode as string "true" is rejected (strict equality)
run_test "23-fastmode-string-rejected" "$FIXTURES/minimal.json" "$FIXTURES/settings-fastmode-string.json" "" "FAST" "absent"

# Test 24: empty CLAUDE_CODE_EFFORT_LEVEL env is no-op (falls through to settings/auto)
run_test "24-effort-env-empty-no-override" "$FIXTURES/minimal.json" "$FIXTURES/settings-effort-high.json" "CLAUDE_CODE_EFFORT_LEVEL=" "HIGH\\*" "absent"

# Test 25: CLAUDE_CODE_EFFORT_LEVEL=unset is no-op (falls through)
run_test "25-effort-env-unset-no-override" "$FIXTURES/minimal.json" "$FIXTURES/settings-effort-high.json" "CLAUDE_CODE_EFFORT_LEVEL=unset" "HIGH\\*" "absent"

# Test 26: invalid env value (junk) renders invalid placeholder
run_test "26-effort-env-invalid-placeholder" "$FIXTURES/minimal.json" "" "CLAUDE_CODE_EFFORT_LEVEL=junk" "🧠 \\?" "present"

# Test 27: effortLevel as non-string (number) falls through to auto
run_test "27-effort-nonstring-falls-to-auto" "$FIXTURES/minimal.json" "$FIXTURES/settings-effortLevel-nonstring.json" "" "🧠 auto" "present"

# Test 28: output_style as object with .name is rendered using the name
run_test "28-output-style-object-name" "$FIXTURES/output-style-object.json" "" "" $'\x1b\\[36m.*style: explanatory' "present"

# Test 29: output_style as malformed object (no .name) is hidden, no [object Object]
run_test "29-output-style-malformed-hidden" "$FIXTURES/output-style-malformed.json" "" "" "\\[object Object\\]|explanatory" "absent"

# ── Payload-sourced segments (effort.level, fast_mode, session_name) ──

# Test 30: effort.level from the payload renders, colored for that level
run_test "30-effort-from-payload" "$FIXTURES/payload-effort-max.json" "" "" $'\x1b\\[1;35m.*MAX' "present"

# Test 31: payload effort.level wins over settings.json effortLevel
run_test "31-payload-effort-beats-settings" "$FIXTURES/payload-effort-max.json" "$FIXTURES/settings-effort-high.json" "" "MAX" "present"
run_test "31b-payload-effort-hides-settings-value" "$FIXTURES/payload-effort-max.json" "$FIXTURES/settings-effort-high.json" "" "HIGH" "absent"

# Test 32: payload effort.level wins over the env var, and carries no override marker
run_test "32-payload-effort-beats-env" "$FIXTURES/payload-effort-max.json" "" "CLAUDE_CODE_EFFORT_LEVEL=xhigh" "XHIGH" "absent"
run_test "32b-payload-effort-no-override-marker" "$FIXTURES/payload-effort-max.json" "" "CLAUDE_CODE_EFFORT_LEVEL=xhigh" "MAX\\*" "absent"

# Test 33: an unrecognized level from a newer Claude Code still renders instead of "?"
run_test "33-effort-unknown-level-renders" "$FIXTURES/payload-effort-unknown-level.json" "" "" "🧠 ULTRA" "present"

# Test 34: non-string effort.level falls back to the settings/auto path
run_test "34-effort-nonstring-payload-falls-back" "$FIXTURES/payload-effort-nonstring.json" "" "" "🧠 auto" "present"

# Test 35: fast_mode=true in the payload renders FAST
run_test "35-payload-fastmode-on" "$FIXTURES/payload-fastmode-on.json" "" "" $'\x1b\\[1;96m.*FAST' "present"

# Test 36: fast_mode=false in the payload overrides a stale settings.json fastMode
run_test "36-payload-fastmode-off-beats-settings" "$FIXTURES/payload-fastmode-off.json" "$FIXTURES/settings-fastmode.json" "" "FAST" "absent"

# Test 37: native session_name renders without title-casing it
run_test "37-payload-session-name" "$FIXTURES/payload-session-name.json" "" "" "🏷 refactor payload sources" "present"

# Test 38: an overlong session_name is truncated with an ellipsis
run_test "38-session-name-truncated" "$FIXTURES/payload-session-name-long.json" "" "" "…" "present"
run_test "38b-session-name-not-full-length" "$FIXTURES/payload-session-name-long.json" "" "" "wrecks the row" "absent"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ $FAIL -gt 0 ]; then
  printf '  - %s\n' "${FAILED_TESTS[@]}"
  exit 1
fi
