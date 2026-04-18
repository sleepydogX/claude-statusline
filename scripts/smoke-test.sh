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
run_test "8-output-style-explanatory-shown" "$FIXTURES/output-style-explanatory.json" "" "" $'\x1b\\[36m.*explanatory' "present"

# Test 9: permission plan mode renders "PLAN" with blue
run_test "9-permission-plan" "$FIXTURES/permission-plan.json" "" "" $'\x1b\\[34m.*PLAN' "present"

# Test 10: permission bypass renders "BYPASS" with blinking red
run_test "10-permission-bypass" "$FIXTURES/permission-bypass.json" "" "" $'\x1b\\[5;31m.*BYPASS' "present"

# Test 11: permission default is hidden
run_test "11-permission-default-hidden" "$FIXTURES/minimal.json" "" "" "PLAN|BYPASS|AUTO-EDIT" "absent"

# Test 12: fastMode=true renders "FAST" in bold bright cyan
run_test "12-fast-mode-on" "$FIXTURES/minimal.json" "$FIXTURES/settings-fastmode.json" "" $'\x1b\\[1;96m.*FAST' "present"

# Test 13: fastMode absent is hidden
run_test "13-fast-mode-off-hidden" "$FIXTURES/minimal.json" "" "" "FAST" "absent"

# Test 14: 1 failed MCP shows name
run_test "14-mcp-one-failed-name" "$FIXTURES/mcp-one-failed.json" "" "" "supabase down" "present"

# Test 15: 2 failed MCPs show both names
run_test "15-mcp-two-failed-names" "$FIXTURES/mcp-two-failed.json" "" "" "supabase, github down" "present"

# Test 16: 3+ failed MCPs show count
run_test "16-mcp-three-failed-count" "$FIXTURES/mcp-three-failed.json" "" "" "3 MCPs down" "present"

# Test 17: all healthy hides segment
run_test "17-mcp-healthy-hidden" "$FIXTURES/minimal.json" "" "" "MCP.*down|🔌" "absent"

# Test 18: malformed settings.json does not crash; other segments render
run_test "18-malformed-settings-survives" "$FIXTURES/minimal.json" "$FIXTURES/settings-malformed.txt" "" "Claude Opus" "present"

# Test 19: malformed settings.json does not show effort HIGH (settings unreadable)
run_test "19-malformed-settings-no-effort-value" "$FIXTURES/minimal.json" "$FIXTURES/settings-malformed.txt" "" "HIGH" "absent"

# Test 20: mcp_servers field missing does not crash and segment is absent
run_test "20-mcp-field-missing-renders" "$FIXTURES/mcp-field-missing.json" "" "" "Claude Opus" "present"
run_test "20b-mcp-field-missing-no-segment" "$FIXTURES/mcp-field-missing.json" "" "" "MCP.*down|🔌" "absent"

# Test 21: MCP entry without name is silently dropped (no "undefined" / empty output)
run_test "21-mcp-nameless-dropped" "$FIXTURES/mcp-nameless.json" "" "" "🔌 *down|undefined|^🔌 , " "absent"

# Test 22: permission acceptEdits renders AUTO-EDIT with yellow
run_test "22-permission-acceptedits" "$FIXTURES/permission-acceptedits.json" "" "" $'\x1b\\[33m.*AUTO-EDIT' "present"

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
run_test "28-output-style-object-name" "$FIXTURES/output-style-object.json" "" "" $'\x1b\\[36m.*explanatory' "present"

# Test 29: output_style as malformed object (no .name) is hidden, no [object Object]
run_test "29-output-style-malformed-hidden" "$FIXTURES/output-style-malformed.json" "" "" "\\[object Object\\]|explanatory" "absent"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ $FAIL -gt 0 ]; then
  printf '  - %s\n' "${FAILED_TESTS[@]}"
  exit 1
fi
