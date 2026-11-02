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
run_test "37-payload-session-name" "$FIXTURES/payload-session-name.json" "" "" "🔖 refactor payload sources" "present"

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

# Test 57: with workspace.repo present, git is never SPAWNED.
#
# An earlier version removed git from PATH and asserted the repo still
# rendered. That proves too little: the code swallows ENOENT, so a regression
# that re-enabled the git fallback would still have rendered and still passed.
# Instead, put a fake `git` first on PATH that records every invocation to a
# sentinel file. The repo must render AND the sentinel must stay empty.
#
# Only the interpreters the runner needs are mirrored, so this no longer pays
# the 3s+5s timeouts of a reachable `gh` and `supabase`.
SPYDIR="$(mktemp -d)"
SENTINEL="$SPYDIR/git-was-called"
mkdir -p "$SPYDIR/bin" "$SPYDIR/tmp" "$SPYDIR/work"
for _b in bash node env dirname pwd mktemp rm cp mkdir; do
  _p="$(command -v "$_b" 2>/dev/null)" && ln -sf "$_p" "$SPYDIR/bin/$_b"
done
cat > "$SPYDIR/bin/git" <<SPY
#!/bin/sh
echo "git \$*" >> "$SENTINEL"
exit 1
SPY
chmod +x "$SPYDIR/bin/git"

# current_dir must be a directory that EXISTS. With a non-existent cwd,
# execFileSync fails at the chdir before the binary is ever executed, so the
# spy would never fire and the assertion below would be vacuous.
# TMPDIR is isolated too, so a stale info-cache from an earlier run cannot
# short-circuit the block and empty the sentinel for the wrong reason.
_spy_run() {  # $1 = payload json, writes output to stdout
  printf '%s' "$1" > "$SPYDIR/payload.json"
  env -i HOME=/tmp TMPDIR="$SPYDIR/tmp" PATH="$SPYDIR/bin" \
    bash "$RUNNER" "$SPYDIR/payload.json" "" 2>/dev/null || true
}
_WITH_REPO='{"session_id":"spy-with-repo","model":{"display_name":"C"},"workspace":{"current_dir":"'"$SPYDIR/work"'","project_dir":"'"$SPYDIR/work"'","repo":{"host":"github.com","owner":"JawaSec","name":"secops-portal"}},"version":"2.1.220","output_style":{"name":"default"}}'
_NO_REPO='{"session_id":"spy-no-repo","model":{"display_name":"C"},"workspace":{"current_dir":"'"$SPYDIR/work"'","project_dir":"'"$SPYDIR/work"'"},"version":"2.1.220","output_style":{"name":"default"}}'

if _spy_run "$_WITH_REPO" | grep -q "JawaSec/secops-portal"; then
  PASS=$((PASS+1)); echo "  PASS: 57-repo-renders-from-payload"
else
  FAIL=$((FAIL+1)); FAILED_TESTS+=("57-repo-renders-from-payload"); echo "  FAIL: 57-repo-renders-from-payload"
fi
if [ -s "$SENTINEL" ]; then
  FAIL=$((FAIL+1)); FAILED_TESTS+=("57b-no-git-spawned (git was invoked: $(tr '\n' ';' < "$SENTINEL"))"); echo "  FAIL: 57b-no-git-spawned"
else
  PASS=$((PASS+1)); echo "  PASS: 57b-no-git-spawned"
fi

# Control: without workspace.repo the fallback SHOULD spawn git. This is what
# makes 57b meaningful — it proves the spy can detect a spawn at all, so an
# empty sentinel above is evidence rather than an artifact of a broken probe.
: > "$SENTINEL"
_spy_run "$_NO_REPO" > /dev/null
if [ -s "$SENTINEL" ]; then
  PASS=$((PASS+1)); echo "  PASS: 57c-fallback-does-spawn-git-without-payload-repo"
else
  FAIL=$((FAIL+1)); FAILED_TESTS+=("57c-fallback-does-spawn-git-without-payload-repo (spy never fired; 57b proves nothing)"); echo "  FAIL: 57c-fallback-does-spawn-git-without-payload-repo"
fi
rm -rf "$SPYDIR"

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
  if branch_out "$dir" | grep -qE "$pattern"; then
    PASS=$((PASS+1)); echo "  PASS: $name"
  else
    FAIL=$((FAIL+1)); FAILED_TESTS+=("$name"); echo "  FAIL: $name"
  fi
}

branch_case_absent() {
  local name="$1" dir="$2" pattern="$3"
  if branch_out "$dir" | grep -qE "$pattern"; then
    FAIL=$((FAIL+1)); FAILED_TESTS+=("$name (expected pattern absent: $pattern)"); echo "  FAIL: $name"
  else
    PASS=$((PASS+1)); echo "  PASS: $name"
  fi
}

# Test 58: a normal repo reports its branch
branch_case "58-branch-from-head" "$BRANCHTMP/normal" "feature/x"

# Test 59: a detached HEAD reports a 7-character short SHA. Anchored so a
# non-hex (or end-of-line) character must immediately follow the 7th hex
# digit — a plain substring match would also pass against the untruncated
# 40-character SHA, which is exactly the regression this test is named for.
branch_case "59-branch-detached-short-sha" "$BRANCHTMP/detached" "4073f59([^0-9a-f]|$)"

# Test 60: a .git file with a gitdir: pointer resolves through it
branch_case "60-branch-through-gitdir-file" "$BRANCHTMP/wt" "worktree-branch"

# Test 61: a subdirectory walks up to the repo root
branch_case "61-branch-walks-up" "$BRANCHTMP/normal/src/deep" "feature/x"

# Test 62: with no .git anywhere, row 3 still renders its repo but shows no
# branch. Asserting on row 3 specifically: an earlier version of this test
# grepped for the model name, which lives in row 1, so it passed no matter what
# row 3 did — it could not detect the regression it is named for.
branch_case "62-no-git-row3-still-renders" "$BRANCHTMP/bare" "🐙"
branch_case_absent "62b-no-git-no-branch-glyph" "$BRANCHTMP/bare" "⎋"

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

# ── Final review fix: repoName/worktreeName sanitization ──

# Test 65: workspace.repo.owner carrying a control-char escape, with NO host
# key, must not leak it into the row. The plain-text fallback path (no host
# means no osc8 call) is exactly what test 63 didn't cover.
run_test "65-repo-owner-esc-no-host-not-leaked" "$FIXTURES/repo-owner-esc-no-host.json" "" "" $'\x1b\\[31mHACKED' "absent"

# Test 66: workspace.git_worktree carrying a control-char escape must not
# leak it into the row. git_worktree never passes through osc8 at all.
run_test "66-worktree-esc-not-leaked" "$FIXTURES/worktree-esc.json" "" "" $'\x1b\\[31mHACKED' "absent"

# ── Final review fix: cached gh_user/sb_project sanitization ──
# These fields are populated by regex over `git`/`gh`/`supabase` subprocess
# output and cached to a file in os.tmpdir(); build a poisoned cache entry
# directly (bypassing the subprocesses) and confirm none of its escape
# sequences reach the row. The escape is written as the six-character JSON
# escape sequence (backslash, u, 0, 0, 1, b) built below via $ESC_ESCAPE, not
# a raw ESC byte -- a raw byte is invalid JSON and JSON.parse would throw,
# making the cache silently discarded and the test pass for the wrong reason
# (same pitfall as the fixtures above).
#
# Critical: the child node process does NOT inherit TMPDIR from `env -i`, so
# it must be passed explicitly here -- otherwise this cache file is written
# to a directory statusline.js never reads, and the test passes vacuously.
CACHE_TMPDIR="$(mktemp -d)"
POISON_SESSION="test-cache-poison-1"
POISON_TS=$(( $(date +%s) * 1000 ))
BSLASH=$'\x5c'
ESC_ESCAPE="${BSLASH}u001b"
POISON_CACHE_JSON="{\"ts\": $POISON_TS, \"gh_repo\": \"safe/repo\", \"gh_user\": \"u${ESC_ESCAPE}[32mHACKUSER\", \"gh_branch\": \"br${ESC_ESCAPE}[31mHACKBRANCH\", \"sb_project\": \"p${ESC_ESCAPE}[33mHACKSB\"}"
printf '%s' "$POISON_CACHE_JSON" > "$CACHE_TMPDIR/claude-info-$POISON_SESSION.json"

POISON_FIXTURE="$CACHE_TMPDIR/poison-payload.json"
printf '{"session_id":"%s","model":{"display_name":"Claude Opus 4.7"},"workspace":{"current_dir":"/tmp/test","project_dir":"/tmp/test"},"version":"2.1.220","output_style":{"name":"default"}}' "$POISON_SESSION" > "$POISON_FIXTURE"

out67="$(env -i HOME=/tmp PATH="$PATH" TMPDIR="$CACHE_TMPDIR" bash "$RUNNER" "$POISON_FIXTURE" "" 2>/dev/null || true)"

# Test 67: raw ESC bytes from a poisoned gh_user/sb_project cache
# entry must not leak into the rendered row.
if echo "$out67" | grep -qE $'\x1b\\[3[123]mHACK'; then
  FAIL=$((FAIL+1)); FAILED_TESTS+=("67-cached-fields-not-leaked"); echo "  FAIL: 67-cached-fields-not-leaked"
else
  PASS=$((PASS+1)); echo "  PASS: 67-cached-fields-not-leaked"
fi
rm -rf "$CACHE_TMPDIR"

# ── Deferred-findings cleanup ──

# Test 68: a non-integer pr.number is rejected rather than rendered as "#3.5".
# The previous guard was `typeof pr.number === 'number'`, which accepted it.
run_test "68-pr-number-non-integer-rejected" "$FIXTURES/pr-number-35.json" "" "" "#3\\.5" "absent"
run_test "68b-pr-number-non-integer-hides-badge" "$FIXTURES/pr-number-35.json" "" "" "🔀" "absent"

# Test 69: a negative pr.number is rejected rather than rendered as "#-5".
run_test "69-pr-number-negative-rejected" "$FIXTURES/pr-number-5.json" "" "" "#-5" "absent"
run_test "69b-pr-number-negative-hides-badge" "$FIXTURES/pr-number-5.json" "" "" "🔀" "absent"

# Test 70: a valid positive integer still renders, so the tighter guard did not
# break the normal case.
run_test "70-pr-number-valid-still-renders" "$FIXTURES/pr-open-approved.json" "" "" "#412" "present"

# ── Subagents row ──
# Builds the on-disk layout Claude Code writes beside a transcript:
# <session>.jsonl and <session>/subagents/agent-<id>.{meta.json,jsonl}.
SUB_TMP="$(mktemp -d)"
SUB_DIR="$SUB_TMP/sess/subagents"
mkdir -p "$SUB_DIR"
: > "$SUB_TMP/sess.jsonl"
usage_line() { printf '{"type":"assistant","message":{"usage":{"input_tokens":%s,"cache_read_input_tokens":%s,"cache_creation_input_tokens":%s}}}\n' "$1" "$2" "$3"; }

# running, 100k of a 200k window -> 50%; the earlier smaller usage must not win
printf '{"name":"research","agentType":"fork","model":"inherit"}' > "$SUB_DIR/agent-aaa.meta.json"
{ usage_line 2 1000 0; usage_line 2 99000 998; echo '{"type":"user","message":{"content":"x"}}'; } > "$SUB_DIR/agent-aaa.jsonl"
# finished -> hidden
printf '{"name":"doneagent","agentType":"general-purpose","model":"haiku","finished":true}' > "$SUB_DIR/agent-bbb.meta.json"
usage_line 1 5000 0 > "$SUB_DIR/agent-bbb.jsonl"
# unfinished but silent for an hour -> treated as gone
printf '{"name":"staleagent","agentType":"general-purpose","model":"haiku"}' > "$SUB_DIR/agent-ccc.meta.json"
usage_line 1 5000 0 > "$SUB_DIR/agent-ccc.jsonl"
touch -t "$(date -v-1H +%Y%m%d%H%M.%S 2>/dev/null || date -d '-1 hour' +%Y%m%d%H%M.%S)" "$SUB_DIR/agent-ccc.jsonl" "$SUB_DIR/agent-ccc.meta.json"
# running, name carries an escape sequence -> stripped
printf '{"name":"evil\\u001b[31mRED","agentType":"general-purpose","model":"haiku"}' > "$SUB_DIR/agent-ddd.meta.json"
usage_line 1 20000 0 > "$SUB_DIR/agent-ddd.jsonl"
# running, name carries a C1 CSI (U+009B) and a bidi override (U+202E) -> stripped
printf '{"name":"c1\\u009b32mGREEN\\u202eflip","agentType":"general-purpose","model":"haiku"}' > "$SUB_DIR/agent-eee.meta.json"
usage_line 1 20000 0 > "$SUB_DIR/agent-eee.jsonl"

SUB_FIXTURE="$SUB_TMP/payload.json"
printf '{"session_id":"sub-test","transcript_path":"%s","model":{"display_name":"Claude Opus"},"workspace":{"current_dir":"/tmp","project_dir":"/tmp"},"context_window":{"context_window_size":200000,"remaining_percentage":90}}' "$SUB_TMP/sess.jsonl" > "$SUB_FIXTURE"

run_test "71-subagents-count-active-only" "$SUB_FIXTURE" "" "" "🤖 3 active" "present"
run_test "72-subagents-pct-from-last-usage" "$SUB_FIXTURE" "" "" "research.*█████░░░░░ 50%" "present"
run_test "73-subagents-finished-hidden" "$SUB_FIXTURE" "" "" "doneagent" "absent"
run_test "74-subagents-stale-hidden" "$SUB_FIXTURE" "" "" "staleagent" "absent"
run_test "75-subagents-name-escape-stripped" "$SUB_FIXTURE" "" "" $'\x1b\\[31mRED' "absent"
run_test "75b-subagents-name-still-shown" "$SUB_FIXTURE" "" "" "evil\\[31mRED" "present"
run_test "75c-subagents-c1-and-bidi-stripped" "$SUB_FIXTURE" "" "" $'\xc2\x9b|\xe2\x80\xae' "absent"
run_test "75d-subagents-c1-name-still-shown" "$SUB_FIXTURE" "" "" "c132mGREENflip" "present"

# no subagents dir -> no row, and nothing else breaks
NOSUB_FIXTURE="$SUB_TMP/payload-nosub.json"
printf '{"session_id":"sub-test2","transcript_path":"%s","model":{"display_name":"Claude Opus"},"workspace":{"current_dir":"/tmp"}}' "$SUB_TMP/missing.jsonl" > "$NOSUB_FIXTURE"
run_test "76-subagents-absent-dir-no-row" "$NOSUB_FIXTURE" "" "" "🤖" "absent"
run_test "76b-subagents-absent-dir-still-renders" "$NOSUB_FIXTURE" "" "" "Claude Opus" "present"
rm -rf "$SUB_TMP"

# ── Context %, rate-limit freshness, cache sweep ──
FX_TMP="$(mktemp -d)"
NOW=$(date +%s)
ctx_fixture() { printf '{"session_id":"fx","model":{"display_name":"Claude Opus"},"workspace":{"current_dir":"/tmp"},"context_window":{"context_window_size":%s,"remaining_percentage":50}}' "$1" > "$2"; }
ctx_fixture 1000000 "$FX_TMP/ctx-1m.json"
ctx_fixture 200000 "$FX_TMP/ctx-200k.json"

# Test 77: on a 1M window the 33k buffer is 3.3%, so 50% remaining is 52% used
# (the old fixed 16.5% buffer reported 60%).
run_test "77-ctx-1m-buffer-in-tokens" "$FX_TMP/ctx-1m.json" "" "" "CTX 52%" "present"
# Test 78: a 200k window keeps the previous behaviour.
run_test "78-ctx-200k-unchanged" "$FX_TMP/ctx-200k.json" "" "" "CTX 60%" "present"

rl_fixture() { printf '{"session_id":"fx","model":{"display_name":"Claude Opus"},"workspace":{"current_dir":"/tmp"},"rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":%s,"resets_at":%s}}}' "$1" "$2" "$3" "$4" > "$5"; }
rl_fixture 90 $((NOW - 60)) 30 $((NOW + 3*86400 + 4*3600 + 120)) "$FX_TMP/rl.json"
# Test 79: a 5h window whose reset already passed shows 0%, not the stale 90%.
run_test "79-5h-past-reset-shows-zero" "$FX_TMP/rl.json" "" "" "5h.*0%" "present"
run_test "79b-5h-past-reset-hides-stale" "$FX_TMP/rl.json" "" "" "90%" "absent"
# Test 80: the 7-day window now shows its countdown, in days once past 24h.
run_test "80-7d-shows-reset-in-days" "$FX_TMP/rl.json" "" "" "7d.*30%.*3d04h" "present"

# Test 81: the sweep deletes our week-old per-session files only.
GC_TMP="$FX_TMP/gc"; mkdir -p "$GC_TMP"
OLD_STAMP="$(date -v-8d +%Y%m%d%H%M.%S 2>/dev/null || date -d '-8 days' +%Y%m%d%H%M.%S)"
for f in claude-info-old.json claude-ctx-old.json claude-slug-old unrelated-old.json; do : > "$GC_TMP/$f"; touch -t "$OLD_STAMP" "$GC_TMP/$f"; done
: > "$GC_TMP/claude-info-fresh.json"
env -i HOME=/tmp PATH="$PATH" TMPDIR="$GC_TMP" bash "$RUNNER" "$FIXTURES/minimal.json" "" >/dev/null 2>&1 || true
gc_check() {
  local ok=false
  if [ "$2" = "gone" ]; then [ ! -e "$GC_TMP/$1" ] && ok=true; else [ -e "$GC_TMP/$1" ] && ok=true; fi
  if $ok; then
    PASS=$((PASS+1)); echo "  PASS: 81-gc-$1-$2"
  else
    FAIL=$((FAIL+1)); FAILED_TESTS+=("81-gc-$1-$2"); echo "  FAIL: 81-gc-$1-$2"
  fi
}
gc_check claude-info-old.json gone
gc_check claude-ctx-old.json gone
gc_check claude-slug-old gone
gc_check claude-info-fresh.json kept
gc_check unrelated-old.json kept

# Test 82: a symlink planted at the marker path is not followed, so its
# target keeps its content, and the sweep is skipped.
LINK_TMP="$FX_TMP/link"; mkdir -p "$LINK_TMP"
printf 'precious' > "$FX_TMP/victim.txt"
# Old mtime, so a marker check that follows the link would see the sweep as due.
touch -t "$OLD_STAMP" "$FX_TMP/victim.txt"
ln -s "$FX_TMP/victim.txt" "$LINK_TMP/claude-statusline-gc"
: > "$LINK_TMP/claude-info-old.json"; touch -t "$OLD_STAMP" "$LINK_TMP/claude-info-old.json"
env -i HOME=/tmp PATH="$PATH" TMPDIR="$LINK_TMP" bash "$RUNNER" "$FIXTURES/minimal.json" "" >/dev/null 2>&1 || true
if [ "$(cat "$FX_TMP/victim.txt")" = "precious" ] && [ -e "$LINK_TMP/claude-info-old.json" ]; then
  PASS=$((PASS+1)); echo "  PASS: 82-gc-marker-symlink-not-followed"
else
  FAIL=$((FAIL+1)); FAILED_TESTS+=("82-gc-marker-symlink-not-followed"); echo "  FAIL: 82-gc-marker-symlink-not-followed"
fi

# ── Pace, limit ETA, cost rate, rule width ──
five_fixture() { printf '{"session_id":"fx","model":{"display_name":"Claude Opus"},"workspace":{"current_dir":"/tmp"},"rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":%s}}}' "$1" "$2" > "$3"; }
# half the 5h window gone (2.5h left)
five_fixture 70 $((NOW + 9000)) "$FX_TMP/pace-ahead.json"
five_fixture 20 $((NOW + 9000)) "$FX_TMP/pace-behind.json"
# 4h55m left: only 1.7% of the window elapsed
five_fixture 30 $((NOW + 17700)) "$FX_TMP/pace-early.json"

# Test 83: 70% used at 50% elapsed is 20 points ahead, in red.
run_test "83-pace-ahead" "$FX_TMP/pace-ahead.json" "" "" $'\x1b\\[31m⇡20%' "present"
# Test 84: at that rate the window runs out (~1h04m) before the reset (2.5h).
run_test "84-eta-shown-when-limit-before-reset" "$FX_TMP/pace-ahead.json" "" "" "→ limit [0-9]{2}:[0-9]{2}" "present"
# Test 85: 20% at 50% elapsed is 30 points behind; no ETA since it lasts.
run_test "85-pace-behind" "$FX_TMP/pace-behind.json" "" "" "⇣30%" "present"
run_test "85b-no-eta-when-it-lasts" "$FX_TMP/pace-behind.json" "" "" "→ limit" "absent"
# Test 86: too early in the window to judge pace.
run_test "86-no-pace-early-in-window" "$FX_TMP/pace-early.json" "" "" "⇡|⇣" "absent"

# Test 87: 7d at 80% with half the week gone runs out in ~21h: weekday shown.
printf '{"session_id":"fx","model":{"display_name":"Claude Opus"},"workspace":{"current_dir":"/tmp"},"rate_limits":{"seven_day":{"used_percentage":80,"resets_at":%s}}}' $((NOW + 302400)) > "$FX_TMP/eta-7d.json"
run_test "87-eta-7d-has-weekday" "$FX_TMP/eta-7d.json" "" "" "→ limit (Sun|Mon|Tue|Wed|Thu|Fri|Sat) [0-9]{2}:[0-9]{2}" "present"

cost_fixture() { printf '{"session_id":"fx","model":{"display_name":"Claude Opus"},"workspace":{"current_dir":"/tmp"},"cost":{"total_cost_usd":%s,"total_duration_ms":%s}}' "$1" "$2" > "$3"; }
cost_fixture 2.0 1800000 "$FX_TMP/cost-30m.json"
cost_fixture 0.5 120000 "$FX_TMP/cost-2m.json"
# Test 88: $2 over 30 minutes is $4.0/h.
run_test "88-cost-per-hour" "$FX_TMP/cost-30m.json" "" "" "\\\$2\\.00.*\\(\\\$4\\.0/h\\)" "present"
# Test 89: under five minutes the rate is hidden.
run_test "89-cost-rate-hidden-early" "$FX_TMP/cost-2m.json" "" "" "/h\\)" "absent"

# Test 90: separator rules follow COLUMNS (minus a 4-column margin), else 100.
rule_len() {
  env -i HOME=/tmp PATH="$PATH" $1 bash "$RUNNER" "$FIXTURES/minimal.json" "" 2>/dev/null \
    | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const m=s.replace(/\x1b\[[0-9;]*m/g,"").split("\n").map(l=>(l.match(/^─+$/)||[""])[0].length);console.log(Math.max(...m))})'
}
for spec in "COLUMNS=60:56" "COLUMNS=181:177" ":100" "COLUMNS=abc:100" "COLUMNS=10:100"; do
  envkv="${spec%%:*}"; want="${spec##*:}"; got="$(rule_len "$envkv")"
  if [ "$got" = "$want" ]; then PASS=$((PASS+1)); echo "  PASS: 90-rule-width ${envkv:-unset}"
  else FAIL=$((FAIL+1)); FAILED_TESTS+=("90-rule-width ${envkv:-unset} (want $want, got $got)"); echo "  FAIL: 90-rule-width ${envkv:-unset}"; fi
done
rm -rf "$FX_TMP"

# ── Tmpdir caches refuse planted links ──
LT="$(mktemp -d)"
LT_TMP="$LT/tmp"; mkdir -p "$LT_TMP"
LSESS="link-test"
printf '{"session_id":"%s","model":{"display_name":"Claude Opus"},"workspace":{"current_dir":"/tmp","project_dir":"/tmp","repo":{"host":"github.com","owner":"o","name":"r"}},"context_window":{"remaining_percentage":80}}' "$LSESS" > "$LT/payload.json"
lt_check() {
  if eval "$2"; then PASS=$((PASS+1)); echo "  PASS: $1"
  else FAIL=$((FAIL+1)); FAILED_TESTS+=("$1"); echo "  FAIL: $1"; fi
}

# Test 92: a symlink at the context-bridge path is not written through.
printf 'precious' > "$LT/victim-ctx"
ln -s "$LT/victim-ctx" "$LT_TMP/claude-ctx-$LSESS.json"
# Test 93: a symlink at the info-cache path is neither read nor written through,
# even when its target holds a fresh, well-formed cache entry.
printf '{"ts":%s000,"gh_repo":"","gh_user":"SYMUSER","sb_project":""}' "$(date +%s)" > "$LT/victim-info"
ln -s "$LT/victim-info" "$LT_TMP/claude-info-$LSESS.json"
VICTIM_INFO_BEFORE="$(cat "$LT/victim-info")"
out_lt="$(env -i HOME=/tmp PATH="$PATH" TMPDIR="$LT_TMP" bash "$RUNNER" "$LT/payload.json" "" 2>/dev/null || true)"
lt_check "92-bridge-symlink-not-followed" '[ "$(cat "$LT/victim-ctx")" = "precious" ]'
lt_check "93-info-symlink-not-read" '! echo "$out_lt" | grep -q SYMUSER'
lt_check "93b-info-symlink-not-written" '[ "$(cat "$LT/victim-info")" = "$VICTIM_INFO_BEFORE" ]'

# Test 94: a hardlink at the bridge path is not truncated or overwritten.
rm -f "$LT_TMP"/claude-*
printf 'precious' > "$LT/victim-hard"
ln "$LT/victim-hard" "$LT_TMP/claude-ctx-$LSESS.json"
env -i HOME=/tmp PATH="$PATH" TMPDIR="$LT_TMP" bash "$RUNNER" "$LT/payload.json" "" >/dev/null 2>&1 || true
lt_check "94-bridge-hardlink-not-written" '[ "$(cat "$LT/victim-hard")" = "precious" ]'

# Test 95: with nothing planted, the bridge is still written, owner-only.
rm -f "$LT_TMP"/claude-*
env -i HOME=/tmp PATH="$PATH" TMPDIR="$LT_TMP" bash "$RUNNER" "$LT/payload.json" "" >/dev/null 2>&1 || true
lt_check "95-bridge-written-normally" 'grep -q "\"remaining_percentage\":80" "$LT_TMP/claude-ctx-$LSESS.json"'
lt_check "95b-bridge-owner-only" '[ "$(stat -f %Lp "$LT_TMP/claude-ctx-$LSESS.json" 2>/dev/null || stat -c %a "$LT_TMP/claude-ctx-$LSESS.json")" = "600" ]'
rm -rf "$LT"

# Test 91: every pictograph the script prints must default to emoji
# presentation. Text-default ones (🏷 ⏱ ✍) get one width from Claude Code and
# another from tmux, so partial redraws drop characters after them.
AMBIG="$(node -e '
const src = require("fs").readFileSync(process.argv[1], "utf8")
  .replace(/\\u\{([0-9A-Fa-f]+)\}|\\u([0-9A-Fa-f]{4})/g, (_, a, b) => String.fromCodePoint(parseInt(a || b, 16)));
const bad = new Set();
for (const ch of src) if (/\p{Extended_Pictographic}/u.test(ch) && !/\p{Emoji_Presentation}/u.test(ch)) bad.add(ch);
process.stdout.write([...bad].join(" "));
' "$REPO_DIR/statusline.js")"
if [ -z "$AMBIG" ]; then PASS=$((PASS+1)); echo "  PASS: 91-no-ambiguous-width-emoji"
else FAIL=$((FAIL+1)); FAILED_TESTS+=("91-no-ambiguous-width-emoji (found: $AMBIG)"); echo "  FAIL: 91-no-ambiguous-width-emoji"; fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ $FAIL -gt 0 ]; then
  printf '  - %s\n' "${FAILED_TESTS[@]}"
  exit 1
fi
