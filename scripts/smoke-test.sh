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

# ── Task 1: OSC 8 helper ──

# Test 39: a valid https PR url is emitted as an OSC 8 hyperlink
run_test "39-osc8-emitted-for-https" "$FIXTURES/pr-open-approved.json" "" "" $'\x1b\\]8;;https://github.com/JawaSec/secops-portal/pull/412' "present"

# ── Task 2: PR badge ──

# Test 40: approved renders a green check
run_test "40-pr-approved-symbol" "$FIXTURES/pr-open-approved.json" "" "" $'\x1b\\[32m.*#412 ✓' "present"

# Test 41: changes_requested renders an orange cross
run_test "41-pr-changes-symbol" "$FIXTURES/pr-open-changes.json" "" "" $'\x1b\\[38;5;208m.*#412 ✗' "present"

# Test 42: pending renders a yellow filled dot
run_test "42-pr-pending-symbol" "$FIXTURES/pr-open-pending.json" "" "" $'\x1b\\[33m.*#412 ●' "present"

# Test 43: draft renders a dim hollow dot
run_test "43-pr-draft-symbol" "$FIXTURES/pr-open-draft.json" "" "" $'\x1b\\[2m.*#412 ○' "present"

# Test 44: a missing review_state renders the number with no symbol
run_test "44-pr-no-state-number" "$FIXTURES/pr-no-review-state.json" "" "" "#412" "present"
run_test "44b-pr-no-state-no-symbol" "$FIXTURES/pr-no-review-state.json" "" "" $'✓|✗|●|○' "absent"

# Test 45: an unrecognized review_state is treated as absent
run_test "45-pr-unknown-state-no-symbol" "$FIXTURES/pr-open-unknown-state.json" "" "" $'✓|✗|●|○' "absent"
run_test "45b-pr-unknown-state-still-shows-number" "$FIXTURES/pr-open-unknown-state.json" "" "" "#412" "present"

# Test 46: no pr field hides the segment
run_test "46-pr-absent-hidden" "$FIXTURES/minimal.json" "" "" "🔀" "absent"

# Test 47: a non-http url is not linked, but the number still renders
run_test "47-pr-bad-url-no-link" "$FIXTURES/pr-bad-url.json" "" "" $'\x1b\\]8;;' "absent"
run_test "47b-pr-bad-url-number-shown" "$FIXTURES/pr-bad-url.json" "" "" "#99" "present"

# Test 48: a review_state of "__proto__" must not leak Object.prototype through
# the states lookup map and print the literal string "undefined"
run_test "48-pr-proto-state-no-undefined" "$FIXTURES/pr-open-proto-state.json" "" "" "undefined" "absent"

# ── Task 3: payload-sourced repo/worktree and filesystem branch ──

# Test 53: workspace.repo renders owner/name
run_test "53-repo-from-payload" "$FIXTURES/repo-and-worktree.json" "" "" "JawaSec/secops-portal" "present"

# Test 54: the repo is a clickable link built from host/owner/name
run_test "54-repo-linked" "$FIXTURES/repo-and-worktree.json" "" "" $'\x1b\\]8;;https://github.com/JawaSec/secops-portal' "present"

# Test 55: workspace.git_worktree renders the worktree name
run_test "55-worktree-shown" "$FIXTURES/repo-and-worktree.json" "" "" "🌳 fix-auth" "present"

# Test 56: no git_worktree hides the worktree piece
run_test "56-worktree-absent-hidden" "$FIXTURES/minimal.json" "" "" "🌳" "absent"

# Test 57: with workspace.repo present, no git binary is needed at all.
# PATH_NO_GIT mirrors every executable reachable from the real PATH (so the
# runner, bash, node and other standard tools still work) except any binary
# literally named "git" — that omission is the whole point of the test.
PATH_NO_GIT="$(mktemp -d)"
IFS=':' read -ra _no_git_dirs <<< "$PATH"
for _d in "${_no_git_dirs[@]}"; do
  [ -d "$_d" ] || continue
  for _f in "$_d"/*; do
    [ -e "$_f" ] || continue
    _b="$(basename "$_f")"
    [ "$_b" = "git" ] && continue
    [ -e "$PATH_NO_GIT/$_b" ] || ln -s "$_f" "$PATH_NO_GIT/$_b" 2>/dev/null
  done
done
if env -i HOME=/tmp PATH="$PATH_NO_GIT" bash "$RUNNER" "$FIXTURES/repo-and-worktree.json" "" 2>/dev/null | grep -q "JawaSec/secops-portal"; then
  PASS=$((PASS+1)); echo "  PASS: 57-repo-without-git-binary"
else
  FAIL=$((FAIL+1)); FAILED_TESTS+=("57-repo-without-git-binary"); echo "  FAIL: 57-repo-without-git-binary"
fi
rm -rf "$PATH_NO_GIT"

# ── Branch resolution from .git/HEAD ──
# These build real directories with synthetic .git entries, so they call
# PASS/FAIL directly rather than run_test, which takes a fixed fixture path.

BRANCHTMP="$(mktemp -d)"
trap 'rm -rf "$BRANCHTMP"' EXIT

# (a) ordinary repo on a branch
mkdir -p "$BRANCHTMP/normal/.git"
echo "ref: refs/heads/feature/x" > "$BRANCHTMP/normal/.git/HEAD"

# (b) detached HEAD
mkdir -p "$BRANCHTMP/detached/.git"
echo "4073f59596e272f39393db4f96abc5f4b10eff21" > "$BRANCHTMP/detached/.git/HEAD"

# (c) worktree: .git is a FILE pointing elsewhere
mkdir -p "$BRANCHTMP/wt-real"
echo "ref: refs/heads/worktree-branch" > "$BRANCHTMP/wt-real/HEAD"
mkdir -p "$BRANCHTMP/wt"
echo "gitdir: $BRANCHTMP/wt-real" > "$BRANCHTMP/wt/.git"

# (d) nested two levels below the repo root
mkdir -p "$BRANCHTMP/normal/src/deep"

# (e) no .git anywhere
mkdir -p "$BRANCHTMP/bare"

# (f) HEAD ref containing raw control characters (ANSI injection attempt)
mkdir -p "$BRANCHTMP/malicious/.git"
printf 'ref: refs/heads/ma\x1b[31mHACKED\x1b[0m\n' > "$BRANCHTMP/malicious/.git/HEAD"

# Emit a payload whose repo comes from the payload (so githubPart renders without
# git) but whose current_dir points at the directory under test.
branch_out() {
  local dir="$1"
  printf '{"session_id":"t","model":{"display_name":"Claude Opus 4.7"},"workspace":{"current_dir":"%s","project_dir":"%s","repo":{"host":"github.com","owner":"o","name":"n"}},"version":"2.1.220","output_style":{"name":"default"}}' "$dir" "$dir" \
    > "$BRANCHTMP/payload.json"
  env -i HOME=/tmp PATH="$PATH" bash "$RUNNER" "$BRANCHTMP/payload.json" "" 2>/dev/null || true
}

branch_case() {
  local name="$1" dir="$2" pattern="$3"
  if branch_out "$dir" | grep -q "$pattern"; then
    PASS=$((PASS+1)); echo "  PASS: $name"
  else
    FAIL=$((FAIL+1)); FAILED_TESTS+=("$name"); echo "  FAIL: $name"
  fi
}

# Test 58: a normal repo reports its branch
branch_case "58-branch-from-head" "$BRANCHTMP/normal" "feature/x"

# Test 59: a detached HEAD reports a 7-character short SHA
branch_case "59-branch-detached-short-sha" "$BRANCHTMP/detached" "4073f59"

# Test 60: a .git file with a gitdir: pointer resolves through it
branch_case "60-branch-through-gitdir-file" "$BRANCHTMP/wt" "worktree-branch"

# Test 61: a subdirectory walks up to the repo root
branch_case "61-branch-walks-up" "$BRANCHTMP/normal/src/deep" "feature/x"

# Test 62: no .git anywhere renders without a branch and without crashing
branch_case "62-no-git-still-renders" "$BRANCHTMP/bare" "Claude Opus"

# ── Fix round 1: sanitization findings ──

# Test 63: a non-string workspace.repo.owner must not render as [object Object]
run_test "63-repo-owner-nonstring-no-object-literal" "$FIXTURES/repo-owner-nonstring.json" "" "" "\\[object Object\\]" "absent"

# Test 64: a HEAD ref carrying raw control characters must not leak them into
# the rendered row (readBranch must treat a ref that required stripping as
# untrustworthy and return '', rather than emit a silently altered value).
out64="$(branch_out "$BRANCHTMP/malicious")"
if echo "$out64" | grep -qE $'\x1b\\[31mHACKED'; then
  FAIL=$((FAIL+1)); FAILED_TESTS+=("64-branch-control-chars-not-leaked"); echo "  FAIL: 64-branch-control-chars-not-leaked"
else
  PASS=$((PASS+1)); echo "  PASS: 64-branch-control-chars-not-leaked"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ $FAIL -gt 0 ]; then
  printf '  - %s\n' "${FAILED_TESTS[@]}"
  exit 1
fi
