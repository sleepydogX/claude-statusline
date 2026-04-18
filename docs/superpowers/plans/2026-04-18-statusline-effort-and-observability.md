# Statusline Effort & Observability — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add 5 passive read-only segments to the statusline (effort, output_style, permission_mode, fast_mode, mcp_health), fix the installer so it wires `settings.json` automatically, add a scope wizard (global/project/skip), make the installer idempotent for upgrades, and ship a `/statusline-update` convenience slash command.

**Architecture:** All segments are pure read-only: stdin JSON from Claude Code plus a single sync read of `~/.claude/settings.json` per render. No new state files, no custom slash commands, no hooks, no daemons. Installer merges JSON safely via Node (never `sed`). Slash command wraps `git pull + install.sh` for in-chat updates.

**Tech Stack:** Node.js (statusline script), Bash (installer + smoke tests), Claude Code slash command markdown.

**Spec reference:** `docs/superpowers/specs/2026-04-18-statusline-effort-and-observability-design.md`

---

## File Structure

**Modify:**
- `statusline.js` — add 5 segments, extend `MODULES`, update row 2 composition
- `install.sh` — scope wizard, JSON-safe merge, upgrade detection, install slash command file
- `README.md` — document new segments and update workflow

**Create:**
- `scripts/smoke-test.sh` — fixture-driven smoke test runner
- `scripts/fixtures/` — JSON fixtures for each scenario (12 files)
- `scripts/run-statusline.sh` — helper: pipes a fixture into `statusline.js` with a sandboxed `$HOME`
- `commands/statusline-update.md` — slash command template (repo path substituted at install time)

**Commit granularity:** each task = one commit. Tasks are independent where possible; where they depend on earlier work, the dependency is stated.

---

## Task 1: Scaffold smoke test infrastructure

**Files:**
- Create: `scripts/run-statusline.sh`
- Create: `scripts/smoke-test.sh`
- Create: `scripts/fixtures/minimal.json`

- [ ] **Step 1: Create fixture for minimal JSON input**

Write `scripts/fixtures/minimal.json`:

```json
{
  "session_id": "test-session-001",
  "model": { "display_name": "Claude Opus 4.7" },
  "workspace": { "current_dir": "/tmp/test", "project_dir": "/tmp/test" },
  "version": "2.1.114",
  "context_window": { "remaining_percentage": 80 },
  "cost": { "total_cost_usd": 0.42, "total_duration_ms": 750000, "total_lines_added": 10, "total_lines_removed": 5 },
  "rate_limits": {
    "five_hour": { "used_percentage": 35, "resets_at": 9999999999 },
    "seven_day": { "used_percentage": 12 }
  },
  "output_style": "default",
  "permissionMode": "default",
  "mcp_servers": []
}
```

- [ ] **Step 2: Create the runner helper**

Write `scripts/run-statusline.sh`:

```bash
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
```

Then: `chmod +x scripts/run-statusline.sh`

- [ ] **Step 3: Create the smoke test harness**

Write `scripts/smoke-test.sh`:

```bash
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

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ $FAIL -gt 0 ]; then
  printf '  - %s\n' "${FAILED_TESTS[@]}"
  exit 1
fi
```

Then: `chmod +x scripts/smoke-test.sh`

- [ ] **Step 4: Run the smoke test**

Run: `bash scripts/smoke-test.sh`

Expected output contains: `PASS: 1-minimal-renders` and `Results: 1 passed, 0 failed`, exit code 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/
git commit -m "Add smoke test scaffold with minimal fixture"
```

---

## Task 2: Add `effort` segment

**Files:**
- Modify: `statusline.js` (add `MODULES.effort`, add `effortPart` builder, insert into row 2)
- Create: `scripts/fixtures/settings-effort-high.json`
- Create: `scripts/fixtures/settings-effort-xhigh.json`
- Create: `scripts/fixtures/settings-effort-invalid.json`
- Modify: `scripts/smoke-test.sh` (add effort-related tests)

- [ ] **Step 1: Write failing tests for effort**

Create fixture `scripts/fixtures/settings-effort-high.json`:

```json
{ "effortLevel": "high" }
```

Create fixture `scripts/fixtures/settings-effort-xhigh.json`:

```json
{ "effortLevel": "xhigh" }
```

Create fixture `scripts/fixtures/settings-effort-invalid.json`:

```json
{ "effortLevel": "turbo" }
```

Append to `scripts/smoke-test.sh` after Test 1:

```bash
# Test 2: effort high from settings renders "HIGH" with yellow ANSI
run_test "2-effort-high-from-settings" "$FIXTURES/minimal.json" "$FIXTURES/settings-effort-high.json" "" $'\x1b\\[33mHIGH' "present"

# Test 3: env override with xhigh appends asterisk
run_test "3-effort-env-override-marker" "$FIXTURES/minimal.json" "" "CLAUDE_CODE_EFFORT_LEVEL=xhigh" "XHIGH\\*" "present"

# Test 4: env auto does NOT mark as override
run_test "4-effort-env-auto-no-marker" "$FIXTURES/minimal.json" "$FIXTURES/settings-effort-high.json" "CLAUDE_CODE_EFFORT_LEVEL=auto" "HIGH\\*" "absent"

# Test 5: invalid effort value renders "?" placeholder
run_test "5-effort-invalid-placeholder" "$FIXTURES/minimal.json" "$FIXTURES/settings-effort-invalid.json" "" "🧠 \\?" "present"

# Test 6: no settings and no env shows "auto" default
run_test "6-effort-auto-default" "$FIXTURES/minimal.json" "" "" "🧠 auto" "present"
```

- [ ] **Step 2: Run tests to verify failures**

Run: `bash scripts/smoke-test.sh`

Expected: Tests 2-6 FAIL (segment not implemented yet). Test 1 still PASSes.

- [ ] **Step 3: Implement the effort segment in statusline.js**

Modify `statusline.js`. First, extend `MODULES` (line 11-20):

```js
const MODULES = {
  session_name: true,
  cost: true,
  duration: true,
  rate_limits: true,
  lines_changed: true,
  github: true,
  supabase: true,
  context_bridge: true,
  effort: true,           // NEW
  output_style: true,     // NEW (added in later tasks)
  permission_mode: true,  // NEW (added in later tasks)
  fast_mode: true,        // NEW (added in later tasks)
  mcp_health: true,       // NEW (added in later tasks)
};
```

Add a helper near the top of the `process.stdin.on('end', ...)` handler (right after the `try { const data = JSON.parse(input); ...` opening, before context bridge). Insert a new block after the context bridge section (around line 62):

```js
// ── User settings (effortLevel, fastMode) ──
let userSettings = {};
try {
  const settingsPath = path.join(os.homedir(), '.claude', 'settings.json');
  if (fs.existsSync(settingsPath)) {
    userSettings = JSON.parse(fs.readFileSync(settingsPath, 'utf8'));
  }
} catch (e) { /* silent; treat as empty */ }

// ── Effort ──
let effortPart = '';
if (MODULES.effort) {
  try {
    const validLevels = new Set(['low', 'medium', 'high', 'xhigh', 'max']);
    const envRaw = process.env.CLAUDE_CODE_EFFORT_LEVEL;
    const envVal = envRaw ? envRaw.toLowerCase() : '';
    const envOverrides = envVal && envVal !== 'auto' && envVal !== 'unset';
    const settingsVal = typeof userSettings.effortLevel === 'string'
      ? userSettings.effortLevel.toLowerCase()
      : '';

    let display;       // string to show
    let isOverride;    // whether env is in effect
    let invalid = false;

    if (envOverrides) {
      if (validLevels.has(envVal)) {
        display = envVal;
        isOverride = true;
      } else {
        invalid = true;
      }
    } else if (settingsVal) {
      if (validLevels.has(settingsVal)) {
        display = settingsVal;
        isOverride = false;
      } else {
        invalid = true;
      }
    } else {
      display = 'auto';
      isOverride = false;
    }

    if (invalid) {
      effortPart = `\x1b[2m\u{1F9E0} ?\x1b[0m`;
    } else {
      const colorMap = {
        auto:   '\x1b[2;3m',
        low:    '\x1b[38;5;245m',
        medium: '\x1b[32m',
        high:   '\x1b[33m',
        xhigh:  '\x1b[38;5;208m',
        max:    '\x1b[1;35m',
      };
      const color = colorMap[display] || '\x1b[0m';
      const label = display === 'auto' ? 'auto' : display.toUpperCase();
      const marker = isOverride ? '*' : '';
      effortPart = `${color}\u{1F9E0} ${label}${marker}\x1b[0m`;
    }
  } catch (e) { /* silent */ }
}
```

Then, update the row 2 composition (currently around line 333):

Change:
```js
const row2Cells = [sessionNamePart, costPart, durationPart, rateLimitPart].filter(Boolean);
```

To:
```js
const row2Cells = [effortPart, sessionNamePart, costPart, durationPart, rateLimitPart].filter(Boolean);
```

- [ ] **Step 4: Run tests to verify all pass**

Run: `bash scripts/smoke-test.sh`

Expected: `Results: 6 passed, 0 failed`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add statusline.js scripts/
git commit -m "Add effort segment reading settings.json and env override"
```

---

## Task 3: Add `output_style` segment

**Files:**
- Modify: `statusline.js` (add `outputStylePart` builder, insert into row 2)
- Create: `scripts/fixtures/output-style-explanatory.json`
- Modify: `scripts/smoke-test.sh`

- [ ] **Step 1: Write failing tests for output_style**

Create fixture `scripts/fixtures/output-style-explanatory.json` (full fixture, not just a patch):

```json
{
  "session_id": "test-session-001",
  "model": { "display_name": "Claude Opus 4.7" },
  "workspace": { "current_dir": "/tmp/test", "project_dir": "/tmp/test" },
  "version": "2.1.114",
  "context_window": { "remaining_percentage": 80 },
  "cost": { "total_cost_usd": 0.42, "total_duration_ms": 750000, "total_lines_added": 10, "total_lines_removed": 5 },
  "rate_limits": {
    "five_hour": { "used_percentage": 35, "resets_at": 9999999999 },
    "seven_day": { "used_percentage": 12 }
  },
  "output_style": "explanatory",
  "permissionMode": "default",
  "mcp_servers": []
}
```

Append to `scripts/smoke-test.sh`:

```bash
# Test 7: output_style default is hidden
run_test "7-output-style-default-hidden" "$FIXTURES/minimal.json" "" "" "explanatory" "absent"

# Test 8: output_style non-default renders in cyan
run_test "8-output-style-explanatory-shown" "$FIXTURES/output-style-explanatory.json" "" "" $'\x1b\\[36m.*explanatory' "present"
```

- [ ] **Step 2: Run tests to verify failures**

Run: `bash scripts/smoke-test.sh`

Expected: Test 8 FAILs; Test 7 may pass (no implementation renders no explanatory text).

- [ ] **Step 3: Implement output_style segment**

In `statusline.js`, right after the `effortPart` block, insert:

```js
// ── Output style ──
let outputStylePart = '';
if (MODULES.output_style) {
  try {
    const style = data.output_style;
    if (style && style !== 'default') {
      outputStylePart = `\x1b[36m\u270D ${style}\x1b[0m`;
    }
  } catch (e) { /* silent */ }
}
```

Update row 2 composition:

```js
const row2Cells = [effortPart, outputStylePart, sessionNamePart, costPart, durationPart, rateLimitPart].filter(Boolean);
```

- [ ] **Step 4: Run tests**

Run: `bash scripts/smoke-test.sh`

Expected: `Results: 8 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add statusline.js scripts/
git commit -m "Add output_style segment (visible only if non-default)"
```

---

## Task 4: Add `permission_mode` segment

**Files:**
- Modify: `statusline.js`
- Create: `scripts/fixtures/permission-plan.json`
- Create: `scripts/fixtures/permission-bypass.json`
- Modify: `scripts/smoke-test.sh`

- [ ] **Step 1: Write failing tests**

Create fixture `scripts/fixtures/permission-plan.json` (copy of minimal with `permissionMode: "plan"`):

```json
{
  "session_id": "test-session-001",
  "model": { "display_name": "Claude Opus 4.7" },
  "workspace": { "current_dir": "/tmp/test", "project_dir": "/tmp/test" },
  "version": "2.1.114",
  "context_window": { "remaining_percentage": 80 },
  "cost": { "total_cost_usd": 0.42, "total_duration_ms": 750000, "total_lines_added": 10, "total_lines_removed": 5 },
  "rate_limits": {
    "five_hour": { "used_percentage": 35, "resets_at": 9999999999 },
    "seven_day": { "used_percentage": 12 }
  },
  "output_style": "default",
  "permissionMode": "plan",
  "mcp_servers": []
}
```

Create fixture `scripts/fixtures/permission-bypass.json` (same but `permissionMode: "bypassPermissions"`):

```json
{
  "session_id": "test-session-001",
  "model": { "display_name": "Claude Opus 4.7" },
  "workspace": { "current_dir": "/tmp/test", "project_dir": "/tmp/test" },
  "version": "2.1.114",
  "context_window": { "remaining_percentage": 80 },
  "cost": { "total_cost_usd": 0.42, "total_duration_ms": 750000, "total_lines_added": 10, "total_lines_removed": 5 },
  "rate_limits": {
    "five_hour": { "used_percentage": 35, "resets_at": 9999999999 },
    "seven_day": { "used_percentage": 12 }
  },
  "output_style": "default",
  "permissionMode": "bypassPermissions",
  "mcp_servers": []
}
```

Append to `scripts/smoke-test.sh`:

```bash
# Test 9: permission plan mode renders "PLAN" with blue
run_test "9-permission-plan" "$FIXTURES/permission-plan.json" "" "" $'\x1b\\[34mPLAN' "present"

# Test 10: permission bypass renders "BYPASS" with blinking red
run_test "10-permission-bypass" "$FIXTURES/permission-bypass.json" "" "" $'\x1b\\[5;31m.*BYPASS' "present"

# Test 11: permission default is hidden
run_test "11-permission-default-hidden" "$FIXTURES/minimal.json" "" "" "PLAN|BYPASS|AUTO-EDIT" "absent"
```

- [ ] **Step 2: Run tests to verify failures**

Run: `bash scripts/smoke-test.sh`

Expected: Tests 9 and 10 FAIL; Test 11 passes (nothing rendered).

- [ ] **Step 3: Implement permission_mode segment**

In `statusline.js`, after the `outputStylePart` block:

```js
// ── Permission mode ──
let permissionModePart = '';
if (MODULES.permission_mode) {
  try {
    const mode = data.permissionMode;
    if (mode && mode !== 'default') {
      const specs = {
        plan:              { label: 'PLAN',       color: '\x1b[34m',   icon: '\u{1F4CB}' },
        acceptEdits:       { label: 'AUTO-EDIT',  color: '\x1b[33m',   icon: '\u270F' },
        bypassPermissions: { label: 'BYPASS',     color: '\x1b[5;31m', icon: '\u26A0' },
      };
      const spec = specs[mode];
      if (spec) {
        permissionModePart = `${spec.color}${spec.icon} ${spec.label}\x1b[0m`;
      }
    }
  } catch (e) { /* silent */ }
}
```

Update row 2 composition:

```js
const row2Cells = [effortPart, outputStylePart, permissionModePart, sessionNamePart, costPart, durationPart, rateLimitPart].filter(Boolean);
```

- [ ] **Step 4: Run tests**

Run: `bash scripts/smoke-test.sh`

Expected: `Results: 11 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add statusline.js scripts/
git commit -m "Add permission_mode segment for plan/acceptEdits/bypass"
```

---

## Task 5: Add `fast_mode` segment

**Files:**
- Modify: `statusline.js`
- Create: `scripts/fixtures/settings-fastmode.json`
- Modify: `scripts/smoke-test.sh`

- [ ] **Step 1: Write failing test**

Create fixture `scripts/fixtures/settings-fastmode.json`:

```json
{ "fastMode": true }
```

Append to `scripts/smoke-test.sh`:

```bash
# Test 12: fastMode=true renders "FAST" in bold cyan
run_test "12-fast-mode-on" "$FIXTURES/minimal.json" "$FIXTURES/settings-fastmode.json" "" $'\x1b\\[1;96m.*FAST' "present"

# Test 13: fastMode absent is hidden
run_test "13-fast-mode-off-hidden" "$FIXTURES/minimal.json" "" "" "FAST" "absent"
```

- [ ] **Step 2: Run to verify failures**

Run: `bash scripts/smoke-test.sh`

Expected: Test 12 FAILs; Test 13 passes.

- [ ] **Step 3: Implement fast_mode segment**

In `statusline.js`, after `permissionModePart` block:

```js
// ── Fast mode ──
let fastModePart = '';
if (MODULES.fast_mode) {
  try {
    if (userSettings.fastMode === true) {
      fastModePart = `\x1b[1;96m\u26A1 FAST\x1b[0m`;
    }
  } catch (e) { /* silent */ }
}
```

Update row 2 composition:

```js
const row2Cells = [effortPart, outputStylePart, permissionModePart, fastModePart, sessionNamePart, costPart, durationPart, rateLimitPart].filter(Boolean);
```

- [ ] **Step 4: Run tests**

Run: `bash scripts/smoke-test.sh`

Expected: `Results: 13 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add statusline.js scripts/
git commit -m "Add fast_mode segment (visible only when enabled)"
```

---

## Task 6: Add `mcp_health` segment

**Files:**
- Modify: `statusline.js`
- Create: `scripts/fixtures/mcp-one-failed.json`
- Create: `scripts/fixtures/mcp-two-failed.json`
- Create: `scripts/fixtures/mcp-three-failed.json`
- Modify: `scripts/smoke-test.sh`

- [ ] **Step 1: Write failing tests**

Create fixture `scripts/fixtures/mcp-one-failed.json`:

```json
{
  "session_id": "test-session-001",
  "model": { "display_name": "Claude Opus 4.7" },
  "workspace": { "current_dir": "/tmp/test", "project_dir": "/tmp/test" },
  "version": "2.1.114",
  "context_window": { "remaining_percentage": 80 },
  "cost": { "total_cost_usd": 0.42, "total_duration_ms": 750000, "total_lines_added": 10, "total_lines_removed": 5 },
  "rate_limits": {
    "five_hour": { "used_percentage": 35, "resets_at": 9999999999 },
    "seven_day": { "used_percentage": 12 }
  },
  "output_style": "default",
  "permissionMode": "default",
  "mcp_servers": [
    { "name": "supabase", "status": "failed" },
    { "name": "github", "status": "connected" }
  ]
}
```

Create `scripts/fixtures/mcp-two-failed.json` (same shape; two failed):

```json
{
  "session_id": "test-session-001",
  "model": { "display_name": "Claude Opus 4.7" },
  "workspace": { "current_dir": "/tmp/test", "project_dir": "/tmp/test" },
  "version": "2.1.114",
  "context_window": { "remaining_percentage": 80 },
  "cost": { "total_cost_usd": 0.42, "total_duration_ms": 750000, "total_lines_added": 10, "total_lines_removed": 5 },
  "rate_limits": {
    "five_hour": { "used_percentage": 35, "resets_at": 9999999999 },
    "seven_day": { "used_percentage": 12 }
  },
  "output_style": "default",
  "permissionMode": "default",
  "mcp_servers": [
    { "name": "supabase", "status": "failed" },
    { "name": "github", "status": "error" },
    { "name": "figma", "status": "connected" }
  ]
}
```

Create `scripts/fixtures/mcp-three-failed.json`:

```json
{
  "session_id": "test-session-001",
  "model": { "display_name": "Claude Opus 4.7" },
  "workspace": { "current_dir": "/tmp/test", "project_dir": "/tmp/test" },
  "version": "2.1.114",
  "context_window": { "remaining_percentage": 80 },
  "cost": { "total_cost_usd": 0.42, "total_duration_ms": 750000, "total_lines_added": 10, "total_lines_removed": 5 },
  "rate_limits": {
    "five_hour": { "used_percentage": 35, "resets_at": 9999999999 },
    "seven_day": { "used_percentage": 12 }
  },
  "output_style": "default",
  "permissionMode": "default",
  "mcp_servers": [
    { "name": "supabase", "status": "failed" },
    { "name": "github", "status": "error" },
    { "name": "figma", "status": "failed" },
    { "name": "n8n",    "status": "connected" }
  ]
}
```

Append to `scripts/smoke-test.sh`:

```bash
# Test 14: 1 failed MCP shows name
run_test "14-mcp-one-failed-name" "$FIXTURES/mcp-one-failed.json" "" "" "supabase down" "present"

# Test 15: 2 failed MCPs show both names
run_test "15-mcp-two-failed-names" "$FIXTURES/mcp-two-failed.json" "" "" "supabase, github down" "present"

# Test 16: 3+ failed MCPs show count
run_test "16-mcp-three-failed-count" "$FIXTURES/mcp-three-failed.json" "" "" "3 MCPs down" "present"

# Test 17: all healthy hides segment
run_test "17-mcp-healthy-hidden" "$FIXTURES/minimal.json" "" "" "MCP.*down|🔌" "absent"
```

- [ ] **Step 2: Run tests**

Run: `bash scripts/smoke-test.sh`

Expected: Tests 14-16 FAIL; Test 17 passes.

- [ ] **Step 3: Implement mcp_health segment**

In `statusline.js`, after `fastModePart` block:

```js
// ── MCP health ──
let mcpHealthPart = '';
if (MODULES.mcp_health) {
  try {
    const servers = Array.isArray(data.mcp_servers) ? data.mcp_servers : [];
    const unhealthy = servers.filter(s => s && s.status && s.status !== 'connected');
    if (unhealthy.length > 0) {
      let inner;
      if (unhealthy.length <= 2) {
        inner = unhealthy.map(s => s.name).join(', ') + ' down';
      } else {
        inner = `${unhealthy.length} MCPs down`;
      }
      mcpHealthPart = `\x1b[31m\u{1F50C} ${inner}\x1b[0m`;
    }
  } catch (e) { /* silent */ }
}
```

Update row 2 composition:

```js
const row2Cells = [effortPart, outputStylePart, permissionModePart, fastModePart, mcpHealthPart, sessionNamePart, costPart, durationPart, rateLimitPart].filter(Boolean);
```

- [ ] **Step 4: Run tests**

Run: `bash scripts/smoke-test.sh`

Expected: `Results: 17 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add statusline.js scripts/
git commit -m "Add mcp_health segment showing unhealthy servers"
```

---

## Task 7: Installer — write settings.json automatically (global scope default)

**Files:**
- Modify: `install.sh`
- Create: `scripts/test-installer.sh`

- [ ] **Step 1: Write installer integration test**

Create `scripts/test-installer.sh`:

```bash
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
```

Then: `chmod +x scripts/test-installer.sh`

- [ ] **Step 2: Run to verify failure**

Run: `bash scripts/test-installer.sh`

Expected: FAILs with either "statusLine block not in settings.json" (current installer never writes it) or "effort missing from config".

- [ ] **Step 3: Modify `install.sh` — add scope prompt, new module flags, settings.json merge**

In `install.sh`, make the following changes:

**(a)** After line 90 (end of existing module asks), and before the "External integrations" section, insert new module asks:

```bash
mod_effort=$(ask_module "effort" "Reasoning effort (/effort level)" "y" "🧠")
mod_output_style=$(ask_module "output_style" "Output style (/output-style)" "y" "✍ ")
mod_permission_mode=$(ask_module "permission_mode" "Permission mode indicator" "y" "📋")
mod_fast_mode=$(ask_module "fast_mode" "Fast mode indicator" "y" "⚡")
mod_mcp_health=$(ask_module "mcp_health" "MCP server health" "y" "🔌")
```

**(b)** Add scope prompt right before "Write config" (around line 111):

```bash
echo ""
echo -e "${CYAN}${BOLD}  Where should the statusline be active?${RESET}"
echo "  [1] Global — every Claude Code session (recommended)"
echo "  [2] This project only"
echo "  [3] Skip — I'll wire settings.json myself"
read -p "  Choose [1]: " scope_choice
scope_choice="${scope_choice:-1}"

SETTINGS_TARGET=""
case "$scope_choice" in
  1) SETTINGS_TARGET="$CLAUDE_DIR/settings.json" ;;
  2)
     mkdir -p "./.claude"
     SETTINGS_TARGET="./.claude/settings.json"
     ;;
  3) SETTINGS_TARGET="" ;;
  *) SETTINGS_TARGET="$CLAUDE_DIR/settings.json" ;;
esac
```

**(c)** Update the config write block to include new flags:

```bash
cat > "$CONFIG_FILE" << EOF
{
  "session_name": $mod_session_name,
  "cost": $mod_cost,
  "duration": $mod_duration,
  "rate_limits": $mod_rate_limits,
  "lines_changed": $mod_lines_changed,
  "context_bridge": $mod_context_bridge,
  "github": $mod_github,
  "supabase": $mod_supabase,
  "effort": $mod_effort,
  "output_style": $mod_output_style,
  "permission_mode": $mod_permission_mode,
  "fast_mode": $mod_fast_mode,
  "mcp_health": $mod_mcp_health
}
EOF
```

**(d)** After copying `statusline.js` to `$HOOKS_DIR/gsd-statusline.js` (around current line 133), add the merge step:

```bash
# Wire statusLine into settings.json (unless scope = skip)
if [ -n "$SETTINGS_TARGET" ]; then
  node -e '
    const fs = require("fs");
    const [target, hookPath] = process.argv.slice(1);
    let cfg = {};
    try {
      if (fs.existsSync(target)) cfg = JSON.parse(fs.readFileSync(target, "utf8"));
    } catch (e) {
      console.error("Existing settings.json is malformed; refusing to overwrite. Fix it or choose scope [3].");
      process.exit(1);
    }
    cfg.statusLine = { type: "command", command: "node \"" + hookPath + "\"" };
    fs.writeFileSync(target, JSON.stringify(cfg, null, 2) + "\n");
  ' "$SETTINGS_TARGET" "$HOOKS_DIR/gsd-statusline.js"
  echo -e "${GREEN}  statusLine wired into $SETTINGS_TARGET${RESET}"
else
  echo -e "${YELLOW}  Skipped settings.json wiring. Add this block manually:${RESET}"
  echo '  "statusLine": { "type": "command", "command": "node \"'"$HOOKS_DIR"'/gsd-statusline.js\"" }'
fi
```

- [ ] **Step 4: Run installer test again**

Run: `bash scripts/test-installer.sh`

Expected: `PASS: installer writes settings.json and all new module flags`.

- [ ] **Step 5: Commit**

```bash
git add install.sh scripts/test-installer.sh
git commit -m "Installer: auto-wire settings.json, add scope prompt and new module flags"
```

---

## Task 8: Installer — idempotent upgrade detection

**Files:**
- Modify: `install.sh`
- Modify: `scripts/test-installer.sh` (add re-run test)

- [ ] **Step 1: Add re-run assertion to test-installer.sh**

Append to `scripts/test-installer.sh` before the final `echo "PASS: ..."`:

```bash
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

echo "PASS: idempotent upgrade"
```

- [ ] **Step 2: Run to verify failure**

Run: `bash scripts/test-installer.sh`

Expected: FAIL — current installer re-prompts everything and likely changes state, or the overwrite prompt `y` causes a backup file.

- [ ] **Step 3: Add upgrade detection to install.sh**

At the top of `install.sh`, after the prerequisite checks (around line 37, before `mkdir -p "$HOOKS_DIR"`), add:

```bash
# ── Detect existing install ──
UPGRADE_MODE=false
USER_SETTINGS="$CLAUDE_DIR/settings.json"
if [ -f "$USER_SETTINGS" ] && grep -q 'statusLine' "$USER_SETTINGS" 2>/dev/null; then
  if grep -qE '(claude-statusline|gsd-statusline\.js)' "$USER_SETTINGS"; then
    UPGRADE_MODE=true
  fi
fi

if [ "$UPGRADE_MODE" = true ]; then
  echo -e "${CYAN}  Existing install detected — entering upgrade mode.${RESET}"
  echo -e "${DIM}  statusline.js will be refreshed; config merged (new flags added, existing values preserved).${RESET}"
  echo ""
fi
```

Replace the existing "Check for existing statusline" block (lines 42-55 in current install.sh) with:

```bash
# Back up existing statusline if present (keeps current safety behavior)
if [ -f "$HOOKS_DIR/gsd-statusline.js" ]; then
  cp "$HOOKS_DIR/gsd-statusline.js" "$HOOKS_DIR/gsd-statusline.js.backup.$(date +%s)"
fi
```

Wrap the module prompts and scope prompt so they are **skipped** when `UPGRADE_MODE=true`:

Find the block starting `echo -e "${CYAN}${BOLD}  Select which modules to enable:${RESET}"` and wrap the whole module + scope prompt section:

```bash
if [ "$UPGRADE_MODE" = false ]; then
  # ... existing module prompts + scope prompt ...
else
  # Upgrade: read existing config, defaulting new keys to true
  echo -e "${DIM}  Preserving existing module toggles...${RESET}"
  # No prompts; we'll merge new flags below.
  SETTINGS_TARGET=""  # upgrade leaves settings.json untouched
fi
```

Replace the `cat > "$CONFIG_FILE" << EOF` block with a Node-based merge that only adds missing keys:

```bash
if [ "$UPGRADE_MODE" = false ]; then
  # Fresh install: write config from prompts (existing block stays as-is)
  cat > "$CONFIG_FILE" << EOF
{
  "session_name": $mod_session_name,
  "cost": $mod_cost,
  "duration": $mod_duration,
  "rate_limits": $mod_rate_limits,
  "lines_changed": $mod_lines_changed,
  "context_bridge": $mod_context_bridge,
  "github": $mod_github,
  "supabase": $mod_supabase,
  "effort": $mod_effort,
  "output_style": $mod_output_style,
  "permission_mode": $mod_permission_mode,
  "fast_mode": $mod_fast_mode,
  "mcp_health": $mod_mcp_health
}
EOF
else
  # Upgrade: merge — add missing keys as true, preserve existing values
  node -e '
    const fs = require("fs");
    const p = process.argv[1];
    const defaults = {
      session_name: true, cost: true, duration: true, rate_limits: true,
      lines_changed: true, context_bridge: true, github: true, supabase: true,
      effort: true, output_style: true, permission_mode: true,
      fast_mode: true, mcp_health: true,
    };
    let cur = {};
    try { cur = JSON.parse(fs.readFileSync(p, "utf8")); } catch (e) {}
    const merged = { ...defaults, ...cur };
    fs.writeFileSync(p, JSON.stringify(merged, null, 2) + "\n");
  ' "$CONFIG_FILE"
fi
```

Finally, skip the settings.json wiring on upgrade (it's already wired):

```bash
if [ "$UPGRADE_MODE" = false ] && [ -n "$SETTINGS_TARGET" ]; then
  # ... existing Node merge for statusLine block ...
fi
```

- [ ] **Step 4: Run test**

Run: `bash scripts/test-installer.sh`

Expected: Both `PASS: installer writes settings.json ...` and `PASS: idempotent upgrade`.

- [ ] **Step 5: Commit**

```bash
git add install.sh scripts/test-installer.sh
git commit -m "Installer: idempotent upgrade mode preserves config and settings.json"
```

---

## Task 9: Ship `/statusline-update` slash command

**Files:**
- Create: `commands/statusline-update.md` (template with `__REPO_PATH__` placeholder)
- Modify: `install.sh` (copy command file with path substitution)
- Modify: `scripts/test-installer.sh`

- [ ] **Step 1: Write the slash command template**

Create `commands/statusline-update.md`:

```markdown
---
description: Update the Claude Code statusline to the latest version from git
---

Update the claude-statusline project to its latest version.

1. Run `git -C "__REPO_PATH__" pull --ff-only origin main` and report the output. If the pull fails (e.g. local changes), stop and explain.
2. Run `bash "__REPO_PATH__/install.sh"`. The installer enters upgrade mode automatically; it will not re-prompt.
3. Summarize what changed: new commits pulled (from `git log --oneline <old-sha>..HEAD` in the repo) and the installer's summary line.
4. Remind the user to restart their Claude Code session to see the new statusline.
```

- [ ] **Step 2: Add installer logic to drop the command file**

In `install.sh`, after the `statusline.js` copy (right before the final "Installation complete" block):

```bash
# Install the /statusline-update slash command
COMMANDS_DIR="$CLAUDE_DIR/commands"
mkdir -p "$COMMANDS_DIR"
sed "s|__REPO_PATH__|$SCRIPT_DIR|g" "$SCRIPT_DIR/commands/statusline-update.md" > "$COMMANDS_DIR/statusline-update.md"
echo -e "${GREEN}  Slash command installed: /statusline-update${RESET}"
```

- [ ] **Step 3: Add test assertion**

Append to `scripts/test-installer.sh` (right before `echo "PASS: idempotent upgrade"`):

```bash
# Slash command assertions
CMD_FILE="$SANDBOX/.claude/commands/statusline-update.md"
[ -f "$CMD_FILE" ] || { echo "FAIL: slash command not installed"; exit 1; }
grep -q "$REPO_DIR" "$CMD_FILE" || { echo "FAIL: repo path not substituted in slash command"; exit 1; }
grep -q '__REPO_PATH__' "$CMD_FILE" && { echo "FAIL: template placeholder still present"; exit 1; }

echo "PASS: slash command installed with correct repo path"
```

- [ ] **Step 4: Run test**

Run: `bash scripts/test-installer.sh`

Expected: All three PASS lines printed, exit 0.

- [ ] **Step 5: Commit**

```bash
git add commands/ install.sh scripts/test-installer.sh
git commit -m "Add /statusline-update slash command installed by installer"
```

---

## Task 10: Robustness — malformed settings.json and missing fields

**Files:**
- Create: `scripts/fixtures/settings-malformed.txt` (intentionally broken JSON)
- Modify: `scripts/smoke-test.sh`

- [ ] **Step 1: Add fixture and tests**

Create `scripts/fixtures/settings-malformed.txt` (file content is intentionally invalid JSON):

```
{ "effortLevel": "high", this is not valid json
```

Append to `scripts/smoke-test.sh`:

```bash
# Test 18: malformed settings.json does not crash; other segments render
run_test "18-malformed-settings-survives" "$FIXTURES/minimal.json" "$FIXTURES/settings-malformed.txt" "" "Claude Opus" "present"

# Test 19: malformed settings.json does not show effort HIGH (settings unreadable)
run_test "19-malformed-settings-no-effort-value" "$FIXTURES/minimal.json" "$FIXTURES/settings-malformed.txt" "" "HIGH" "absent"
```

Also a fixture for MCP segment when the field is missing entirely — create `scripts/fixtures/mcp-field-missing.json` as a copy of `minimal.json` **with the `mcp_servers` key removed**:

```json
{
  "session_id": "test-session-001",
  "model": { "display_name": "Claude Opus 4.7" },
  "workspace": { "current_dir": "/tmp/test", "project_dir": "/tmp/test" },
  "version": "2.1.114",
  "context_window": { "remaining_percentage": 80 },
  "cost": { "total_cost_usd": 0.42, "total_duration_ms": 750000, "total_lines_added": 10, "total_lines_removed": 5 },
  "rate_limits": {
    "five_hour": { "used_percentage": 35, "resets_at": 9999999999 },
    "seven_day": { "used_percentage": 12 }
  },
  "output_style": "default",
  "permissionMode": "default"
}
```

Append to `scripts/smoke-test.sh`:

```bash
# Test 20: mcp_servers field missing does not crash, segment absent
run_test "20-mcp-field-missing" "$FIXTURES/mcp-field-missing.json" "" "" "MCP.*down|🔌" "absent"
run_test "20b-mcp-field-missing-renders" "$FIXTURES/mcp-field-missing.json" "" "" "Claude Opus" "present"
```

- [ ] **Step 2: Run tests**

Run: `bash scripts/smoke-test.sh`

Expected: All pass (the existing try/catch patterns should already cover these). If any fail, narrow the relevant segment's try/catch and re-run.

- [ ] **Step 3: Commit**

```bash
git add scripts/
git commit -m "Add smoke tests for malformed settings and missing fields"
```

---

## Task 11: Update README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add a "What's shown" section**

Open `README.md` and locate the section that describes modules/features. Add (or extend) a table describing the 5 new segments, using the same format as existing sections. Use this content:

```markdown
### Configuration & runtime state (row 2)

| Segment | Visible when | Shows |
|---|---|---|
| 🧠 effort | always | Current reasoning effort (`auto`/`low`/`medium`/`high`/`xhigh`/`max`). Reads `~/.claude/settings.json.effortLevel` and `CLAUDE_CODE_EFFORT_LEVEL` env (appends `*` if env overrides). |
| ✍ output_style | value ≠ `default` | Active output style name (set via `/output-style`). |
| 📋 permission_mode | value ≠ `default` | `PLAN`, `AUTO-EDIT`, or `BYPASS` (toggle with Shift+Tab). |
| ⚡ fast_mode | `true` | Claude Code fast mode is on (toggled by `/fast`). |
| 🔌 mcp_health | any server not `connected` | Which MCP servers are down (name for ≤2 failed, count for ≥3). |

All five can be disabled individually in `~/.claude/statusline-config.json`.
```

- [ ] **Step 2: Add an "Updating" section**

Add (after the installation section) a new section:

```markdown
## Updating

Two equivalent ways to update after a `git pull`:

**From the shell:** re-run `bash install.sh`. The installer auto-detects the existing install and enters upgrade mode — no prompts, config preserved, `statusline.js` refreshed.

**From Claude Code:** run `/statusline-update`. The slash command pulls the repo and runs the installer for you.

After updating, restart your Claude Code session to see the new statusline.
```

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "README: document new segments and update workflow"
```

---

## Self-review notes

- **Spec coverage:** each of the 5 segments has a dedicated task (2–6); installer gaps have tasks 7–9; robustness + docs in 10–11. Spec items are all addressed.
- **No placeholders:** every code step shows full code; every command is exact.
- **Type consistency:** `MODULES` flag names (`effort`, `output_style`, `permission_mode`, `fast_mode`, `mcp_health`) match between statusline.js, installer config block, and smoke test assertions.
- **Row 2 order is locked:** `effort | output_style | permission_mode | fast_mode | mcp_health | sessionName | cost | duration | rateLimits`. Each task that touches row 2 updates the full composition line, not a partial one.
