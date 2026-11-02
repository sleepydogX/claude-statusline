# Claude Code Statusline

A rich, modular status bar for [Claude Code](https://claude.ai/claude-code) that displays session metrics, project context, and service integrations at a glance.

```
────────────────────────────────────────────────────────────────────────────────────────────────────
 ⬡ Opus 4.6 (1M context) v2.1.98 │ 📂 ~/projects/my-app │ +90 -17 │ ░░░░░░░░░░ CTX 8%
────────────────────────────────────────────────────────────────────────────────────────────────────
 🧠 HIGH │ 📝 style: explanatory │ ⚡ FAST │ 🔖 Tender Discovering Forest │ 💰 $1.84 ($4.7/h) │ ⌛ 23m15s │ ⚡5h 16% ⇣10% 3h40m │ 📅7d 17% ⇣22% 4d06h
────────────────────────────────────────────────────────────────────────────────────────────────────
 🐙 JawaSec/secops-portal ⎋ dev/kenneth 🌳 fix-auth @jawkgonzalez │ 🔀 #412 ✓
────────────────────────────────────────────────────────────────────────────────────────────────────
```

## Features

| Module | Description |
|--------|-------------|
| **Model & Version** | Current Claude model and Claude Code version |
| **Location** | Workspace and current directory |
| **Lines Changed** | Lines added/removed this session (`+N -N`) |
| **Context Window** | Visual progress bar with color-coded usage (green/yellow/orange/red) |
| **Session Name** | Auto-generated session slug |
| **Cost** | Projected API cost in USD, plus the hourly rate after five minutes (`$4.7/h`). Estimated at list price; resets on `/clear` |
| **Duration** | Session elapsed time |
| **Rate Limits** | 5-hour and 7-day usage with time until reset; a window whose reset has passed shows 0% |
| **Pace** | `⇡8%` ahead of / `⇣8%` behind the clock for each window, once 5% of it has elapsed; `→ limit 15:40` when the current rate runs out before the reset |
| **Subagents** | Count of subagents currently working, with each one's context usage |
| **GitHub** | Repository, branch, and active account |
| **Supabase** | Linked project name |

### Configuration & runtime state (row 2)

| Segment | Visible when | Shows |
|---|---|---|
| 🧠 effort | always | Current reasoning effort (`auto`/`low`/`medium`/`high`/`xhigh`/`max`), read from the payload's `effort.level` so it tracks mid-session `/effort` changes. Falls back to `~/.claude/settings.json.effortLevel` and `CLAUDE_CODE_EFFORT_LEVEL` (appends `*`) when the payload omits the field. |
| 📝 output_style | value ≠ `default` | Active output style name, prefixed with `style:` (e.g. `style: explanatory`, set via `/output-style`). |
| ⚡ fast_mode | `true` | Claude Code fast mode is on, read from the payload's `fast_mode` (toggled by `/fast`). |

All three can be disabled individually in `~/.claude/statusline-config.json`.

The 🔖 session name comes from the payload's `session_name` — a `/rename` or `--name` value, otherwise the AI-generated title — and falls back to the transcript slug when neither exists.

> **Removed in the payload-field cleanup:** the `permission_mode` and `mcp_health` segments read `permissionMode` and `mcp_servers`, which Claude Code does not send to status line commands, so they never rendered. Claude Code already shows the permission mode in its own footer and surfaces MCP errors beside the status line. Upgrading drops both toggles from your config automatically.

### Subagents row

```
🤖 2 active │ research ███████░░░ 48% │ verify-docs ██░░░░░░░░ 15%
```

Shown only while at least one subagent is generating; up to three are listed,
then `+N more`. The payload carries no subagent data, so the row reads what
Claude Code writes beside the transcript, in `<session>/subagents/`:

- `agent-<id>.meta.json` gains `"finished": true` when the agent stops
  generating — including while it waits on its own background command, so such
  an agent drops off the row until it resumes. One silent for 15 minutes is
  treated as gone, since a killed agent never gets the flag.
- `agent-<id>.jsonl` holds its responses; the last one's input + cache tokens
  give the context size. The window is 200k, the main session's window for an
  agent that inherits its model, or 1M once usage passes 200k.

This layout is undocumented and may change between Claude Code releases; the
row then disappears rather than breaking the status line.

### Refresh

Claude Code reruns the status line on new messages and, with
`statusLine.refreshInterval` (seconds) set, on a timer. Without the timer the
cost, countdowns and subagents row freeze while the session is idle. The
installer sets it to 10 on a fresh install, and adds it on upgrade when it is
missing; a value you set yourself is kept.

### Row 3 — repository context

```
🐙 JawaSec/secops-portal ⎋ dev/kenneth 🌳 fix-auth @jawkgonzalez │ 🔀 #412 ✓ │ ⚡ my-project
```

| Segment | Source | Visible when |
|---|---|---|
| 🐙 repo | `workspace.repo` from the payload, falling back to `git remote get-url origin` when the payload omits it | the `github` module is on and a repo name resolves |
| ⎋ branch | `.git/HEAD`, read directly — no `git` subprocess in the common case | rendered together with repo, once a repo name resolves |
| 🌳 worktree | `workspace.git_worktree` from the payload | rendered together with repo, when the current directory is inside a linked git worktree |
| @user | `gh auth status` (cached 120s) | rendered together with repo, when the GitHub CLI is installed and authenticated |
| 🔀 PR | `pr` from the payload; the number links to the PR | the `pr` module is on and an open PR exists for the current branch |
| ⚡ supabase | `supabase status` (cached 120s) | the `supabase` module is on and the project is linked to a Supabase project |

Repo, branch, worktree and account render as a single group: they only appear
when the `github` module is enabled *and* a repo name resolves. Inside a git
directory with `github` disabled, or with no resolvable repo name (no
`workspace.repo` and no `origin` remote), none of the four show — even if the
directory has a branch or an active worktree.

The PR badge marks the review state: ✓ approved, ✗ changes requested,
● pending, ○ draft. A PR with no review state shows the number alone. The
`pr` module is independent of `github` — it renders whenever the payload's
`pr` object has a numeric `number` field, whether or not the repo/branch
group is visible. A `pr` object without a numeric `number` renders nothing.

Repo, branch and worktree come from the status line payload or a direct
`.git/HEAD` read, so in the common case they cost no subprocess and refresh
on every update. Only the GitHub account and Supabase project still shell
out, behind a 120-second cache.

Links use OSC 8 escape sequences, clickable in iTerm2, Kitty and WezTerm. Other
terminals show the text and ignore the sequence.

### Context Window Colors

`CTX` is the share of the window used before autocompact, which reserves a
fixed ~33k-token buffer: 16.5% of a 200k window, 3.3% of a 1M one. The window
size comes from the payload's `context_window.context_window_size`.

| Color | Usage | Meaning |
|-------|-------|---------|
| Green | < 50% | Plenty of context remaining |
| Yellow | 50-64% | Getting warm |
| Orange | 65-79% | Running low |
| Red (blinking) | 80%+ | Critical — autocompact imminent |

### Rate Limit Colors

| Color | Usage | Meaning |
|-------|-------|---------|
| Green | < 50% | Comfortable |
| Yellow | 50-74% | Moderate usage |
| Orange | 75-89% | Approaching limit |
| Red (blinking) | 90%+ | Near rate limit |

## Requirements

- [Claude Code](https://claude.ai/claude-code) (v2.0+)
- Node.js (v18+)
- **Optional:** [GitHub CLI](https://cli.github.com/) (`gh`) for GitHub integration
- **Optional:** [Supabase CLI](https://supabase.com/docs/guides/cli) for Supabase integration

## Installation

```bash
git clone https://github.com/sleepydogX/claude-statusline.git
cd claude-statusline
bash install.sh
```

The interactive installer will guide you through module selection:

```
  ╔══════════════════════════════════════════════╗
  ║     Claude Code Statusline — Installer      ║
  ╚══════════════════════════════════════════════╝

  Select which modules to enable:

  🔖  Session name (random slug identifier) (Y/n):
  💰 Projected cost in USD (Y/n):
  ⌛  Session duration timer (Y/n):
  ⚡ Rate limits (5h + 7d usage) (Y/n):
  📊 Lines added/removed (Y/n):
  🔗 Context metrics bridge (for other hooks) (Y/n):
  🧠 Reasoning effort (/effort level) (Y/n):
  📝  Output style (/output-style) (Y/n):
  ⚡ Fast mode indicator (Y/n):
  🔀 Open pull request badge (Y/n):

  External integrations (require CLI tools):

  🐙 GitHub repo, branch & account (gh CLI detected) (Y/n):
  ⚡ Supabase linked project (supabase CLI detected) (Y/n):
```

## Configuration

Module toggles are stored in `~/.claude/statusline-config.json`:

```json
{
  "session_name": true,
  "cost": true,
  "duration": true,
  "rate_limits": true,
  "lines_changed": true,
  "context_bridge": true,
  "github": true,
  "supabase": false,
  "effort": true,
  "output_style": true,
  "fast_mode": true,
  "pr": true
}
```

Edit this file directly or re-run `bash install.sh` to reconfigure.

## Updating

Two equivalent ways to update after a `git pull`:

**From the shell:** re-run `bash install.sh`. The installer auto-detects the existing install and enters upgrade mode — no prompts, config preserved, `statusline.js` refreshed.

**From Claude Code:** run `/statusline-update`. The slash command pulls the repo and runs the installer for you.

After updating, restart your Claude Code session to see the new statusline.

## Uninstall

```bash
cd claude-statusline
bash uninstall.sh
```

## How It Works

The statusline hook is a Node.js script that Claude Code invokes to render the status bar. It receives session data as JSON via stdin and outputs ANSI-formatted text to stdout.

External data (GitHub, Supabase) is cached in `/tmp/` with a 2-minute TTL to avoid slow CLI calls on every render.

## License

MIT
