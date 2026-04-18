# Claude Code Statusline

A rich, modular status bar for [Claude Code](https://claude.ai/claude-code) that displays session metrics, project context, and service integrations at a glance.

```
────────────────────────────────────────────────────────────────────────────
 ⬡ Opus 4.6 (1M context) v2.1.98 │ 📂 ~/projects/my-app │ +90 -17 │ ██░░░░░░░░ CTX 7%
────────────────────────────────────────────────────────────────────────────
 🏷 Tender Discovering Forest │ 💰 $1.84 │ ⏱ 23m15s │ ⚡5h 16% 3h42m │ 📅7d 17%
────────────────────────────────────────────────────────────────────────────
 🐙 user/repo ⎇ main @user │ ⚡ my-supabase-project
────────────────────────────────────────────────────────────────────────────
```

## Features

| Module | Description |
|--------|-------------|
| **Model & Version** | Current Claude model and Claude Code version |
| **Location** | Workspace and current directory |
| **Lines Changed** | Lines added/removed this session (`+N -N`) |
| **Context Window** | Visual progress bar with color-coded usage (green/yellow/orange/red) |
| **Session Name** | Auto-generated session slug |
| **Cost** | Projected API cost in USD |
| **Duration** | Session elapsed time |
| **Rate Limits** | 5-hour and 7-day usage with time until reset |
| **GitHub** | Repository, branch, and active account |
| **Supabase** | Linked project name |

### Configuration & runtime state (row 2)

| Segment | Visible when | Shows |
|---|---|---|
| 🧠 effort | always | Current reasoning effort (`auto`/`low`/`medium`/`high`/`xhigh`/`max`). Reads `~/.claude/settings.json.effortLevel` and `CLAUDE_CODE_EFFORT_LEVEL` env (appends `*` if env overrides). |
| ✍ output_style | value ≠ `default` | Active output style name (set via `/output-style`). |
| 📋 permission_mode | value ≠ `default` | `PLAN`, `AUTO-EDIT`, or `BYPASS` (toggle with Shift+Tab). |
| ⚡ fast_mode | `true` | Claude Code fast mode is on (toggled by `/fast`). |
| 🔌 mcp_health | any server not `connected` | Which MCP servers are down (name for ≤2 failed, count for ≥3). |

All five can be disabled individually in `~/.claude/statusline-config.json`.

### Context Window Colors

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

  🏷  Session name (random slug identifier) (Y/n):
  💰 Projected cost in USD (Y/n):
  ⏱  Session duration timer (Y/n):
  ⚡ Rate limits (5h + 7d usage) (Y/n):
  📊 Lines added/removed (Y/n):
  🔗 Context metrics bridge (for other hooks) (Y/n):

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
  "supabase": false
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
