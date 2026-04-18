# Design — Statusline Effort & Observability

**Date:** 2026-04-18
**Status:** Approved for planning
**Scope:** `statusline.js`, `install.sh`, new `update.sh`, new `commands/statusline-update.md`

## Goal

Surface five new Claude Code runtime signals in the statusline — **read-only, passive** — so the user always sees the effective reasoning effort, output style, permission mode, fast-mode state, and MCP health at a glance. Also fix a gap in the installer (it never wires `statusLine` into `settings.json`) and add an idempotent update path.

## Non-goals

- No custom slash commands for effort/output-style/fast/permission (Claude Code ships `/effort`, `/output-style`, `/fast`, Shift+Tab — we only display, never duplicate).
- No hooks, watchers, daemons, or background processes. Claude Code re-runs the statusline on every state change; that is our refresh mechanism.
- No private state file (`~/.claude/effort-state.json` or similar). Effort is already persisted by Claude Code in `~/.claude/settings.json.effortLevel`.
- No changes to existing row 1 or row 3 layout.

## Background / findings from Claude Code 2.1.114 binary

Verified by inspecting the bundled JavaScript in the Claude Code executable:

- **`/effort` is built-in.** Persists `effortLevel` (enum `low|medium|high|xhigh`) in the user settings. `max` and `auto` are session-only. Env `CLAUDE_CODE_EFFORT_LEVEL` overrides. Model restrictions: `max` excludes Haiku; `xhigh` requires Opus 4.7.
- **Statusline stdin JSON schema** (confirmed present): `model`, `permissionMode`, `output_style`, `mcp_servers[{name,status}]`, `skills[]`, `plugins[]`, `slash_commands[]`, plus everything already consumed (`cost`, `rate_limits`, `context_window`, `workspace`, etc.).
- **`effortLevel` is NOT in the statusline JSON** — must be read from `~/.claude/settings.json` directly. `fastMode` likewise.

## Architecture

Five new passive segments added to `statusline.js`. Each follows the existing patterns: toggle flag in `MODULES`, individual `try/catch`, ANSI-colored string, `.filter(Boolean)` composition. All placed on **row 2** (before existing session/cost/duration/rate-limit cells).

### Segment table

| Segment | Source | Visibility |
|---|---|---|
| `effort` | `~/.claude/settings.json.effortLevel` + env `CLAUDE_CODE_EFFORT_LEVEL` | Always visible (includes `auto`) |
| `output_style` | `data.output_style` (stdin) | Only if value ≠ `"default"` |
| `permission_mode` | `data.permissionMode` (stdin) | Only if value ≠ `"default"` |
| `fast_mode` | `~/.claude/settings.json.fastMode` | Only if `true` |
| `mcp_health` | `data.mcp_servers[]` (stdin) | Only if any server has `status ≠ "connected"` |

### Visual spec

**Effort** — scale by level, always shown:

| Level | Render | ANSI color |
|---|---|---|
| `auto` | `🧠 auto` | dim italic (`\x1b[2;3m`) |
| `low` | `🧠 low` | gray (`\x1b[38;5;245m`) |
| `medium` | `🧠 MEDIUM` | green (`\x1b[32m`) |
| `high` | `🧠 HIGH` | yellow (`\x1b[33m`) |
| `xhigh` | `🧠 XHIGH` | orange (`\x1b[38;5;208m`) |
| `max` | `🧠 MAX` | bold magenta (`\x1b[1;35m`) |
| _invalid value_ | `🧠 ?` | dim |

If the displayed value came from the env var (not settings), append `*` (e.g. `🧠 HIGH*`). `CLAUDE_CODE_EFFORT_LEVEL=auto` or `=unset` do **not** mark as override — they pass through to settings.

**Output style** — cyan, name verbatim:
`✍ explanatory` (`\x1b[36m`)

**Permission mode** — color-coded by risk:
- `plan` → `📋 PLAN` (blue, `\x1b[34m`)
- `acceptEdits` → `✏ AUTO-EDIT` (yellow, `\x1b[33m`)
- `bypassPermissions` → `⚠ BYPASS` (blinking red, `\x1b[5;31m`)

**Fast mode** — bold bright cyan:
`⚡ FAST` (`\x1b[1;96m`)

**MCP health** — red, name if ≤2 failed, else count:
- 1 failed: `🔌 supabase down`
- 2 failed: `🔌 supabase, github down`
- ≥3 failed: `🔌 3 MCPs down`

### Row 2 order

```
{effort} │ {output_style} │ {permission_mode} │ {fast_mode} │ {mcp_health} │ {sessionName} │ {cost} │ {duration} │ {rateLimits}
```

Separators (`│`, dim) appear only between visible segments via the existing `.filter(Boolean)` + `join(sep)` pattern.

### Module toggles

Extend the `MODULES` object (all default `true`):

```js
const MODULES = {
  // ... existing ...
  effort: true,
  output_style: true,
  permission_mode: true,
  fast_mode: true,
  mcp_health: true,
};
```

Users can disable any via `~/.claude/statusline-config.json` (existing override mechanism).

## Data flow per render

```
1. Parse stdin JSON
   └─ read: output_style, permissionMode, mcp_servers[]

2. Read ~/.claude/settings.json (one sync read, small file, OS page cache handles repeats)
   └─ read: effortLevel, fastMode
   └─ on ENOENT / parse error → silent defaults

3. Env override check
   └─ CLAUDE_CODE_EFFORT_LEVEL (normalize lowercase)
   └─ Special values `auto` and `unset` mean "no override" (mirrors binary behavior)
   └─ Invalid values are ignored (fall through to settings)

4. Build segments per visibility rules

5. Render existing layout + new segments on row 2

6. stdout only; never stderr
```

## Error handling

Follows the script's established silent-fail pattern:

- **Per-segment `try/catch`.** One failure never cascades.
- **Malformed `settings.json`.** Treat as empty; effort/fast segments hide or show defaults.
- **Invalid `effortLevel` value.** Show `🧠 ?` dim. Do not crash.
- **MCP field missing from stdin.** Segment hides.
- **No stderr output.** Statusline UI never writes to stderr; any write would corrupt the display.

## Installer changes (`install.sh`)

### Fix existing gap

The current installer copies `statusline.js` and writes `statusline-config.json` but **does not wire `statusLine` into `settings.json`**. New users see nothing. Fix this by writing the `statusLine` block automatically.

### New wizard question: install scope

Prompt early in the flow (after prerequisite checks):

```
  Where should this statusline be active?

  [1] Global — every Claude Code session everywhere  (recommended, default)
  [2] This project only  (writes to ./.claude/settings.json)
  [3] Skip — I'll wire settings.json myself  (advanced)
```

- **[1]** merges `statusLine` block into `~/.claude/settings.json`
- **[2]** merges into `<pwd>/.claude/settings.json` (creates file/dir if missing)
- **[3]** prints final instructions showing the block to paste manually

### Idempotent merge logic

The installer must safely merge into existing JSON. Approach: use Node to read-modify-write, never `sed` or string concatenation:

```bash
node -e "
  const fs = require('fs');
  const path = process.argv[1];
  let cfg = {};
  try { cfg = JSON.parse(fs.readFileSync(path, 'utf8')); } catch(e) {}
  cfg.statusLine = { type: 'command', command: 'node \"' + process.argv[2] + '\"' };
  fs.writeFileSync(path, JSON.stringify(cfg, null, 2));
" "$SETTINGS_PATH" "$STATUSLINE_PATH"
```

### Upgrade-mode detection

Before asking scope, detect existing install:

- If `~/.claude/settings.json` already has a `statusLine.command` that mentions `claude-statusline` or `gsd-statusline.js` → **upgrade mode**:
  - Skip scope question
  - Just copy the new `statusline.js` over the existing target
  - Merge new module flags (`effort`, `output_style`, `permission_mode`, `fast_mode`, `mcp_health`) into the existing `statusline-config.json` as `true` (preserve user's existing false values for older modules)
  - Print "upgraded" confirmation
- Else → fresh install flow

### Preservation guarantees

- Existing `statusline-config.json` values survive upgrade (never overwritten wholesale).
- Existing `settings.json` keys unrelated to `statusLine` survive (JSON merge, not overwrite).
- Backup of previous `statusline.js` copied to `~/.claude/hooks/gsd-statusline.js.backup.<timestamp>` (existing behavior retained).

## Update path

Two entry points for post-install updates:

### 1. `install.sh` (primary)

Re-running `install.sh` on an existing install enters upgrade mode automatically (see above). Safe to run any number of times. No duplicate `settings.json` entries, no wiped config.

### 2. Slash command `/statusline-update` (convenience)

Ship a markdown file at `~/.claude/commands/statusline-update.md` that instructs Claude to:

1. `git -C <repo-path> pull --ff-only origin main`
2. `bash <repo-path>/install.sh` (which enters upgrade mode)
3. Report what changed (new commits pulled + upgrade result)

The installer installs this command file as part of the fresh-install flow. The repo path is substituted at install time so the command knows where to look.

## Testing

No test framework exists (single-file Node script). Plan:

### Automated smoke tests (`scripts/smoke-test.sh`)

Fixture-driven. Each fixture is a JSON file piped to `statusline.js`; output is grep-matched for expected patterns.

| # | Fixture / env | Expected |
|---|---|---|
| 1 | Minimal JSON, no user `settings.json` | Row 1 renders; no crash |
| 2 | `settings.json.effortLevel = "high"` | Stdout contains `HIGH` + yellow ANSI |
| 3 | Env `CLAUDE_CODE_EFFORT_LEVEL=xhigh` | Contains `xhigh*` (override marker) |
| 4 | `output_style: "default"` | output_style segment absent |
| 5 | `output_style: "explanatory"` | Segment present in cyan |
| 6 | `permissionMode: "plan"` | `PLAN` in blue |
| 7 | `permissionMode: "bypassPermissions"` | `BYPASS` with blink ANSI |
| 8 | `settings.json.fastMode = true` | `FAST` visible |
| 9 | `mcp_servers: [{name:"supabase",status:"failed"}]` | `supabase down` |
| 10 | All defaults / healthy | Row 2 shows only `effort` + existing cells |
| 11 | Malformed `settings.json` | Other segments render; process exits 0 |
| 12 | `effortLevel: "turbo"` (invalid) | Shows `🧠 ?` dim; no crash |

Smoke test uses a temp `$HOME` to avoid polluting real user settings. Nothing is persisted to the real system during tests.

### Manual validation in a real session

1. Install via `install.sh` into a disposable `$HOME`
2. Exercise each slash: `/effort low`, `/effort high`, `/effort xhigh`, `/output-style explanatory`, `/fast`, Shift+Tab (permission mode)
3. Confirm statusline refreshes on each change with the expected visual
4. Disable a segment in `statusline-config.json`; confirm it vanishes without errors

### Installer verification

- Fresh install into a temp `$HOME`: `settings.json` ends up with `statusLine` block, `statusline-config.json` has all new flags true
- Re-run installer: no duplicate entries, config preserved, `.js` refreshed
- Existing user with older install (no new flags): upgrade adds new flags without touching existing ones

### Done criteria

- ✅ All 12 smoke fixtures pass with exit 0 and no stderr output
- ✅ Manual: 5 new segments respond to their respective slash commands
- ✅ `install.sh` is idempotent: two consecutive runs produce identical filesystem state
- ✅ `/statusline-update` slash command file is installed and references the correct repo path

## Out of scope (explicitly)

- Adding `skills[]` or `plugins[]` counts to the statusline (decorative, no clear action)
- Surfacing `alwaysThinkingEnabled` toggle (too rare to earn screen space)
- Animated effort indicator for `max` level (terminal animation is fragile and distracting)
- Project-level override of effort display (not requested; adds complexity)
- Telemetry or analytics of any kind
