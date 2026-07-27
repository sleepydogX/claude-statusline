# Statusline PR Badge & Payload-Sourced Git Context Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the open pull request for the current branch in row 3 of the status line, and source repo, branch, and worktree from the Claude Code payload and the filesystem instead of git subprocesses.

**Architecture:** Row 3 splits into two blocks divided by what the data costs. A new uncached "git context" block reads repo/worktree/PR straight from the stdin payload and resolves the branch with two file reads. The existing cached block shrinks to the two genuinely expensive lookups, `gh auth status` and `supabase status`, and keeps the old git subprocesses only as fallbacks for Claude Code builds that omit `workspace.repo`.

**Tech Stack:** Node.js (v18+), CommonJS, zero runtime dependencies. Tests are bash smoke tests driving `statusline.js` with JSON fixtures on stdin.

## Global Constraints

- **Node 18+, no dependencies.** `statusline.js` must stay a single dependency-free CommonJS file. Do not add `package.json` or imports beyond `fs`, `path`, `os`, `child_process`.
- **Never crash.** Every new segment gets its own silent `try/catch`. A missing or malformed field hides its segment; the status line must still render every other segment.
- **Never print `undefined` or `[object Object]`.** Guard every field read with a type check.
- **ANSI escapes are written as `\x1b[...m` string literals**, matching the existing file. Emoji are written as `\u{...}` escapes, not literal characters — the existing file does this and the Edit tool matches on it.
- **Silent failure only.** No `console.error`, no writes to stderr. Claude Code captures stdout; anything else pollutes the session.
- **Fixtures live in `scripts/fixtures/`, tests in `scripts/smoke-test.sh`.** Follow the existing `run_test "name" "$FIXTURES/x.json" "settings" "env" "pattern" "present|absent"` signature.
- **Test count must only grow.** `bash scripts/smoke-test.sh` currently reports `31 passed, 0 failed`. Every task ends with it passing.

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `statusline.js` | All rendering. Row 3 region is lines 303–384 (`── GitHub & Supabase info (cached) ──`) and line 460 (`row3Cells`). | Modify |
| `scripts/fixtures/*.json` | Payload fixtures fed to stdin. | Create |
| `scripts/smoke-test.sh` | Smoke test assertions. | Modify |
| `install.sh` | Module toggle prompts (line ~96), config template (line ~157), upgrade defaults (line ~177). | Modify |
| `README.md` | Segment documentation. | Modify |

`statusline.js` stays one file. It is 487 lines with every segment inline inside the stdin `end` callback; that is the established pattern and this plan follows it rather than restructuring.

The new helpers (`osc8`, `resolveGitDir`, `readBranch`) are defined at **module level, above the stdin handler**, because they are pure functions with no access to `data`. Everything else stays inline in the callback.

---

### Task 1: OSC 8 hyperlink helper

**Files:**
- Modify: `statusline.js` (add helper after the `require` block, around line 9)
- Test: `scripts/smoke-test.sh`, `scripts/fixtures/pr-open-approved.json`

**Interfaces:**
- Consumes: nothing
- Produces: `osc8(url, text)` → `string`. Returns `text` wrapped in an OSC 8 hyperlink when `url` is a safe http(s) URL; returns `text` unchanged otherwise. Used by Tasks 2 and 3.

- [ ] **Step 1: Write the failing test**

Create `scripts/fixtures/pr-open-approved.json`:

```json
{
  "session_id": "test-session-001",
  "model": { "display_name": "Claude Opus 4.7" },
  "workspace": { "current_dir": "/tmp/test", "project_dir": "/tmp/test" },
  "version": "2.1.220",
  "output_style": { "name": "default" },
  "pr": {
    "number": 412,
    "url": "https://github.com/JawaSec/secops-portal/pull/412",
    "review_state": "approved"
  }
}
```

Append to `scripts/smoke-test.sh`, immediately before the final `echo ""`:

```bash
# ── Task 1: OSC 8 helper ──

# Test 39: a valid https PR url is emitted as an OSC 8 hyperlink
run_test "39-osc8-emitted-for-https" "$FIXTURES/pr-open-approved.json" "" "" $'\x1b\\]8;;https://github.com/JawaSec/secops-portal/pull/412' "present"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/smoke-test.sh 2>&1 | grep '39-osc8'`
Expected: `FAIL: 39-osc8-emitted-for-https` — nothing renders the PR yet.

- [ ] **Step 3: Write minimal implementation**

In `statusline.js`, after the `const os = require('os');` line, add:

```js
// Wrap text in an OSC 8 hyperlink. Only http(s) URLs free of control characters
// are linked, so a malformed URL cannot inject escape sequences into the row.
// Terminals without OSC 8 support ignore the sequence and show the text.
function osc8(url, text) {
  if (typeof url !== 'string' || !/^https?:\/\//.test(url)) return text;
  if (/[\x00-\x1f\x7f]/.test(url)) return text;
  return `\x1b]8;;${url}\x07${text}\x1b]8;;\x07`;
}
```

Then, to make the test pass, add a temporary PR render. In the `// ── Layout ──`
section, just above `const row3Cells`, add:

```js
    // Placeholder wiring, replaced by the full badge in Task 2.
    const prPart = data.pr && data.pr.url && data.pr.number != null
      ? osc8(data.pr.url, `#${data.pr.number}`)
      : '';
```

And change line 460 to:

```js
    const row3Cells = [githubPart, prPart, supabasePart].filter(Boolean);
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash scripts/smoke-test.sh 2>&1 | tail -3`
Expected: `Results: 32 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add statusline.js scripts/smoke-test.sh scripts/fixtures/pr-open-approved.json
git commit -m "Add OSC 8 hyperlink helper with URL safety check"
```

---

### Task 2: PR badge with review state

**Files:**
- Modify: `statusline.js` (replace the Task 1 placeholder; add `pr` to `MODULES` at line 11)
- Test: `scripts/smoke-test.sh`, five new fixtures

**Interfaces:**
- Consumes: `osc8(url, text)` from Task 1
- Produces: `prPart` — a rendered string, or `''` when hidden. Consumed by `row3Cells`.

- [ ] **Step 1: Write the failing tests**

Create four fixtures by copying `pr-open-approved.json` and changing only
`review_state`. Name them `pr-open-changes.json` (`"changes_requested"`),
`pr-open-pending.json` (`"pending"`), `pr-open-draft.json` (`"draft"`), and
`pr-open-unknown-state.json` (`"weird_new_state"`).

Create `scripts/fixtures/pr-no-review-state.json` — identical, but with the
`review_state` key removed entirely:

```json
{
  "session_id": "test-session-001",
  "model": { "display_name": "Claude Opus 4.7" },
  "workspace": { "current_dir": "/tmp/test", "project_dir": "/tmp/test" },
  "version": "2.1.220",
  "output_style": { "name": "default" },
  "pr": {
    "number": 412,
    "url": "https://github.com/JawaSec/secops-portal/pull/412"
  }
}
```

Create `scripts/fixtures/pr-bad-url.json` — same shape, with a hostile URL:

```json
{
  "session_id": "test-session-001",
  "model": { "display_name": "Claude Opus 4.7" },
  "workspace": { "current_dir": "/tmp/test", "project_dir": "/tmp/test" },
  "version": "2.1.220",
  "output_style": { "name": "default" },
  "pr": {
    "number": 99,
    "url": "javascript:alert(1)",
    "review_state": "approved"
  }
}
```

Append to `scripts/smoke-test.sh` before the final `echo ""`:

```bash
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
run_test "46-pr-absent-hidden" "$FIXTURES/minimal.json" "" "" $'\U0001F500' "absent"

# Test 47: a non-http url is not linked, but the number still renders
run_test "47-pr-bad-url-no-link" "$FIXTURES/pr-bad-url.json" "" "" $'\x1b\\]8;;' "absent"
run_test "47b-pr-bad-url-number-shown" "$FIXTURES/pr-bad-url.json" "" "" "#99" "present"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash scripts/smoke-test.sh 2>&1 | grep -E 'FAIL'`
Expected: tests 40–43 fail (no symbols or colors yet); 44b and 45 pass vacuously.

- [ ] **Step 3: Write the implementation**

Add `pr: true,` to the `MODULES` object in `statusline.js` after the `fast_mode` line:

```js
  fast_mode: true,       // Fast mode indicator (added in T5)
  pr: true,              // Open pull request for the current branch
```

Delete the Task 1 placeholder block and put the real segment in its place, just
above `const row3Cells`:

```js
    // ── Pull request ──
    // data.pr is present only while an open PR exists for the branch; it
    // disappears once the PR merges or closes. review_state may be absent on
    // its own, so the symbol is optional while the number is not.
    let prPart = '';
    if (MODULES.pr) {
      try {
        const pr = data.pr;
        const number = pr && typeof pr.number === 'number' ? pr.number : null;
        if (number != null) {
          const states = {
            approved:          { symbol: '✓', color: '\x1b[32m' },
            changes_requested: { symbol: '✗', color: '\x1b[38;5;208m' },
            pending:           { symbol: '●', color: '\x1b[33m' },
            draft:             { symbol: '○', color: '\x1b[2m' },
          };
          const state = states[pr.review_state] || { symbol: '', color: '\x1b[1;37m' };
          const label = state.symbol ? `#${number} ${state.symbol}` : `#${number}`;
          const linked = osc8(pr.url, label);
          prPart = `${state.color}\u{1F500} ${linked}\x1b[0m`;
        }
      } catch (e) { /* silent */ }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash scripts/smoke-test.sh 2>&1 | tail -3`
Expected: `Results: 43 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add statusline.js scripts/smoke-test.sh scripts/fixtures/
git commit -m "Add PR badge with review state symbol and clickable number"
```

---

### Task 3: Row 3 rewrite — filesystem branch, payload repo and worktree

**Files:**
- Modify: `statusline.js` (helpers at module level below `osc8`; replace lines 303–384, the `── GitHub & Supabase info (cached) ──` block)
- Modify: `scripts/run-statusline.sh` (absolute node interpreter)
- Test: `scripts/smoke-test.sh`, `scripts/fixtures/repo-and-worktree.json`

**Interfaces:**
- Consumes: `osc8(url, text)` from Task 1
- Produces:
  - `resolveGitDir(startDir)` → absolute path string, or `''`. Walks up at most 10 levels looking for `.git`, following a `gitdir:` pointer file when it finds one.
  - `readBranch(startDir)` → branch name string, short SHA for a detached HEAD, or `''`.
  - `githubPart` — repo, branch, worktree and user rendered as one cell.

This task merges the branch reader with the block rewrite because the reader is
not observable on its own: the branch only reaches the output through the block,
and the current block gates it behind `infoCache.gh_repo`. Splitting them would
produce a task whose tests cannot pass.

- [ ] **Step 1: Fix the test runner so it survives an empty PATH**

Test 57 below runs with `PATH` pointing at an empty directory to prove no
subprocess is used. `run-statusline.sh` currently invokes `node` by name, which
would fail for the wrong reason. Change its last line to resolve the interpreter
in the parent shell, which still has a normal `PATH`:

```bash
HOME="$SANDBOX" "$(command -v node)" "$REPO_DIR/statusline.js" < "$FIXTURE"
```

- [ ] **Step 2: Write the failing tests**

Create `scripts/fixtures/repo-and-worktree.json`:

```json
{
  "session_id": "test-session-001",
  "model": { "display_name": "Claude Opus 4.7" },
  "workspace": {
    "current_dir": "/tmp/test",
    "project_dir": "/tmp/test",
    "git_worktree": "fix-auth",
    "repo": { "host": "github.com", "owner": "JawaSec", "name": "secops-portal" }
  },
  "version": "2.1.220",
  "output_style": { "name": "default" }
}
```

Append to `scripts/smoke-test.sh` before the final `echo ""`:

```bash
# ── Task 3: payload-sourced repo/worktree and filesystem branch ──

# Test 53: workspace.repo renders owner/name
run_test "53-repo-from-payload" "$FIXTURES/repo-and-worktree.json" "" "" "JawaSec/secops-portal" "present"

# Test 54: the repo is a clickable link built from host/owner/name
run_test "54-repo-linked" "$FIXTURES/repo-and-worktree.json" "" "" $'\x1b\\]8;;https://github.com/JawaSec/secops-portal' "present"

# Test 55: workspace.git_worktree renders the worktree name
run_test "55-worktree-shown" "$FIXTURES/repo-and-worktree.json" "" "" $'\U0001F333 fix-auth' "present"

# Test 56: no git_worktree hides the worktree piece
run_test "56-worktree-absent-hidden" "$FIXTURES/minimal.json" "" "" $'\U0001F333' "absent"

# Test 57: with workspace.repo present, no git binary is needed at all
PATH_NO_GIT="$(mktemp -d)"
if env -i HOME=/tmp PATH="$PATH_NO_GIT" bash "$RUNNER" "$FIXTURES/repo-and-worktree.json" "" 2>/dev/null | grep -q "JawaSec/secops-portal"; then
  PASS=$((PASS+1)); echo "  PASS: 57-repo-without-git-binary"
else
  FAIL=$((FAIL+1)); FAILED_TESTS+=("57-repo-without-git-binary"); echo "  FAIL: 57-repo-without-git-binary"
fi
rmdir "$PATH_NO_GIT"

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
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `bash scripts/smoke-test.sh 2>&1 | grep -E '5[3-9]-|6[0-2]-'`
Expected: 53, 54, 55, 57, 58, 59, 60, 61 FAIL. 56 and 62 pass vacuously — they
only assert absence and non-crash.

- [ ] **Step 4: Add the git helpers**

Add to `statusline.js` at module level, directly below the `osc8` function:

```js
// Resolve the git directory for startDir, walking up at most MAX_GIT_WALKUP
// levels. A .git FILE rather than a directory means a worktree or submodule; it
// holds a "gitdir: <path>" pointer, which may be relative to the file's own
// directory. Returns '' when nothing is found.
const MAX_GIT_WALKUP = 10;
function resolveGitDir(startDir) {
  let dir = startDir;
  for (let i = 0; i < MAX_GIT_WALKUP; i++) {
    const candidate = path.join(dir, '.git');
    try {
      const stat = fs.statSync(candidate);
      if (stat.isDirectory()) return candidate;
      if (stat.isFile()) {
        const pointer = fs.readFileSync(candidate, 'utf8').match(/gitdir:\s*(.+)/);
        if (!pointer) return '';
        const target = pointer[1].trim();
        return path.isAbsolute(target) ? target : path.resolve(dir, target);
      }
    } catch (e) { /* not here; keep walking */ }
    const parent = path.dirname(dir);
    if (parent === dir) break;  // filesystem root
    dir = parent;
  }
  return '';
}

// Read the current branch from HEAD. A "ref: refs/heads/NAME" line yields NAME;
// anything else is a detached HEAD, reported as a 7-character short SHA.
function readBranch(startDir) {
  try {
    const gitDir = resolveGitDir(startDir);
    if (!gitDir) return '';
    const head = fs.readFileSync(path.join(gitDir, 'HEAD'), 'utf8').trim();
    const ref = head.match(/^ref:\s*refs\/heads\/(.+)$/);
    if (ref) return ref[1].trim();
    if (/^[0-9a-f]{7,40}$/i.test(head)) return head.slice(0, 7);
    return '';
  } catch (e) {
    return '';
  }
}
```

- [ ] **Step 5: Rewrite the row 3 block**

Replace everything from `// ── GitHub & Supabase info (cached) ──` through the
closing brace before `// ── Build display components ──` with:

```js
    // ── Row 3: git context (payload-sourced, uncached) ──
    // repo, worktree and branch cost nothing to obtain, so they are read fresh on
    // every invocation. Only gh/supabase go through the cache below.
    const { execFileSync } = require('child_process');
    let githubPart = '';
    let supabasePart = '';

    const repoInfo = data.workspace?.repo;
    const payloadRepo = repoInfo && repoInfo.owner && repoInfo.name
      ? `${repoInfo.owner}/${repoInfo.name}`
      : '';
    const payloadRepoUrl = payloadRepo && repoInfo.host
      ? `https://${repoInfo.host}/${repoInfo.owner}/${repoInfo.name}`
      : '';
    const branchName = readBranch(data.workspace?.current_dir || dir);
    const worktreeName = typeof data.workspace?.git_worktree === 'string'
      ? data.workspace.git_worktree
      : '';

    if (MODULES.github || MODULES.supabase) {
      const sessionSafeForCache = session && !/[/\\]|\.\./.test(session);
      const infoCachePath = sessionSafeForCache ? path.join(os.tmpdir(), `claude-info-${session}.json`) : null;
      const CACHE_TTL_MS = 120000;

      let infoCache = null;
      if (infoCachePath && fs.existsSync(infoCachePath)) {
        try {
          infoCache = JSON.parse(fs.readFileSync(infoCachePath, 'utf8'));
          if (Date.now() - infoCache.ts > CACHE_TTL_MS) infoCache = null;
        } catch (e) { infoCache = null; }
      }

      if (!infoCache) {
        infoCache = { ts: Date.now(), gh_repo: '', gh_user: '', gh_branch: '', sb_project: '' };
        const cwd = data.workspace?.project_dir || dir;

        if (MODULES.github) {
          // Fallbacks only: Claude Code builds that predate workspace.repo, or a
          // repo with no origin remote. Skipped entirely when the payload has it.
          if (!payloadRepo) {
            try {
              const remote = execFileSync('git', ['remote', 'get-url', 'origin'], { cwd, timeout: 3000 }).toString().trim();
              const repoMatch = remote.match(/github\.com[:/](.+?)(?:\.git)?$/);
              if (repoMatch) infoCache.gh_repo = repoMatch[1];
            } catch (e) {}
          }
          if (!branchName) {
            try {
              const branch = execFileSync('git', ['branch', '--show-current'], { cwd, timeout: 2000 }).toString().trim();
              if (branch) infoCache.gh_branch = branch;
            } catch (e) {}
          }
          try {
            const ghStatus = execFileSync('gh', ['auth', 'status'], { timeout: 3000, stdio: ['pipe', 'pipe', 'pipe'] });
            const combined = ghStatus.toString();
            const activeMatch = combined.match(/account (\S+)[\s\S]*?Active account: true/);
            if (activeMatch) infoCache.gh_user = activeMatch[1];
          } catch (e) {
            if (e.stderr) {
              const errStr = e.stderr.toString();
              const activeMatch = errStr.match(/account (\S+)[\s\S]*?Active account: true/);
              if (activeMatch) infoCache.gh_user = activeMatch[1];
            }
          }
        }

        if (MODULES.supabase) {
          try {
            const sbStatus = execFileSync('supabase', ['status'], { cwd, timeout: 5000, stdio: ['pipe', 'pipe', 'pipe'] }).toString();
            const refMatch = sbStatus.match(/(?:API URL|Project ref):\s*(?:https?:\/\/)?(\S+)/);
            if (refMatch) {
              const ref = refMatch[1].replace('.supabase.co', '');
              infoCache.sb_project = ref;
              try {
                const sbList = execFileSync('supabase', ['projects', 'list'], { timeout: 5000, stdio: ['pipe', 'pipe', 'pipe'] }).toString();
                for (const line of sbList.split('\n')) {
                  if (line.includes(ref)) {
                    const cols = line.split('|').map(c => c.trim());
                    if (cols.length >= 4 && cols[3]) infoCache.sb_project = cols[3];
                    break;
                  }
                }
              } catch (e) {}
            }
          } catch (e) {}
        }

        if (infoCachePath) {
          try { fs.writeFileSync(infoCachePath, JSON.stringify(infoCache)); } catch (e) {}
        }
      }

      if (MODULES.github) {
        const repoName = payloadRepo || infoCache.gh_repo;
        const branch = branchName || infoCache.gh_branch;
        if (repoName) {
          // The link needs host, which the git fallback does not reconstruct;
          // without it the repo renders as plain text.
          const repoLabel = payloadRepoUrl ? osc8(payloadRepoUrl, repoName) : repoName;
          const repoStr = `\x1b[1;37m\u{1F419} ${repoLabel}\x1b[0m`;
          const branchStr = branch ? ` \x1b[1;32m\u238B ${branch}\x1b[0m` : '';
          const worktreeStr = worktreeName ? ` \x1b[1;38;5;114m\u{1F333} ${worktreeName}\x1b[0m` : '';
          const userStr = infoCache.gh_user ? ` \x1b[2m@${infoCache.gh_user}\x1b[0m` : '';
          githubPart = `${repoStr}${branchStr}${worktreeStr}${userStr}`;
        }
      }

      if (MODULES.supabase && infoCache.sb_project) {
        supabasePart = `\x1b[1;38;5;42m\u26A1 ${infoCache.sb_project}\x1b[0m`;
      }
    }
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `bash scripts/smoke-test.sh 2>&1 | tail -3`
Expected: `Results: 53 passed, 0 failed`

- [ ] **Step 7: Commit**

```bash
git add statusline.js scripts/smoke-test.sh scripts/run-statusline.sh scripts/fixtures/repo-and-worktree.json
git commit -m "Source row 3 repo, branch and worktree without git subprocesses"
```

---

### Task 4: Installer toggle and documentation

**Files:**
- Modify: `install.sh` (prompt near line 96, config template near line 157, upgrade defaults near line 177)
- Modify: `README.md`
- Test: `scripts/test-installer.sh`

**Interfaces:**
- Consumes: the `pr` flag added to `MODULES` in Task 2
- Produces: nothing consumed by later tasks

- [ ] **Step 1: Write the failing test**

In `scripts/test-installer.sh`, add `pr` to the required-flags loop:

```bash
for flag in effort output_style fast_mode pr; do
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/test-installer.sh`
Expected: `FAIL: pr missing from config`

- [ ] **Step 3: Write the implementation**

In `install.sh`, add a prompt after the `mod_fast_mode` line:

```bash
  mod_pr=$(ask_module "pr" "Open pull request badge" "y" "🔀")
```

In the config template, change the `fast_mode` line to add `pr`:

```bash
  "fast_mode": $mod_fast_mode,
  "pr": $mod_pr
```

In the upgrade defaults object, add `pr: true`:

```js
      effort: true, output_style: true, fast_mode: true, pr: true,
```

- [ ] **Step 4: Update the README**

Replace the row-3 description in `README.md` with:

```markdown
### Row 3 — repository context

\`\`\`
🐙 JawaSec/secops-portal ⎋ dev/kenneth 🌳 fix-auth @jawkgonzalez │ 🔀 #412 ✓ │ ⚡ my-project
\`\`\`

| Segment | Source | Visible when |
|---|---|---|
| 🐙 repo | \`workspace.repo\` from the payload; the name links to the repo | inside a git repo with an \`origin\` remote |
| ⎋ branch | \`.git/HEAD\`, read directly — no \`git\` subprocess, so it never lags behind a checkout | a git directory resolves |
| 🌳 worktree | \`workspace.git_worktree\` | the current directory is inside a linked git worktree |
| @user | \`gh auth status\` (cached 120s) | the GitHub CLI is installed and authenticated |
| 🔀 PR | \`pr\` from the payload; the number links to the PR | an open PR exists for the current branch |
| ⚡ supabase | \`supabase status\` (cached 120s) | the project is linked to a Supabase project |

The PR badge marks the review state: ✓ approved, ✗ changes requested,
● pending, ○ draft. A PR with no review state shows the number alone.

Repo, branch, worktree and PR come from the status line payload or a plain file
read, so they cost no subprocess and refresh on every update. Only the GitHub
account and Supabase project still shell out, behind a 120-second cache.

Links use OSC 8 escape sequences, clickable in iTerm2, Kitty and WezTerm. Other
terminals show the text and ignore the sequence.
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash scripts/test-installer.sh && bash scripts/smoke-test.sh 2>&1 | tail -3`
Expected: all installer PASS lines, then `Results: 53 passed, 0 failed`

- [ ] **Step 6: Commit**

```bash
git add install.sh README.md scripts/test-installer.sh
git commit -m "Add pr module toggle and document row 3 changes"
```

---

## Verification

After Task 4, confirm end to end with a realistic payload:

```bash
bash scripts/run-statusline.sh scripts/fixtures/repo-and-worktree.json "" | cat -v
```

Row 3 should show the repo wrapped in `]8;;https://github.com/...`, the worktree
name after the branch, and no `undefined` anywhere.
