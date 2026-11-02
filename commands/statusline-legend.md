---
description: Explain every icon and value in the status line
---

Show the user the legend below and nothing else: no preamble, no follow-up
question. Print it as given, translating the descriptions (not the icons or
examples) into the language the user writes in. Do not run any tools.

**Row 1 — model and workspace**

| Shown | Meaning |
|---|---|
| `⬡ Opus 4.6 v2.1.98` | Model and Claude Code version |
| `📁 app › 📂 ~/app/src` | Project folder › current folder |
| `+90 -17` | Lines added / removed this session |
| `███░░░░░░░ CTX 36%` | Context used before autocompact. Green < 50%, yellow < 65%, orange < 80%, red with 💀 from 80% |

**Row 2 — session**

| Shown | Meaning |
|---|---|
| `🧠 HIGH` | Reasoning effort. `*` = set by environment variable, `?` = invalid value |
| `📝 style: explanatory` | Active output style (hidden when default) |
| `⚡ FAST` | Fast mode is on |
| `🔖 Session name` | Session name or title |
| `💰 $1.84 ($4.7/h)` | Estimated cost at API list price, and per hour after 5 minutes. Resets on `/clear` |
| `🧊 42m 98%` | Prompt cache: time left to reply while the conversation is still cached (cheaper and faster), and the share served from cache. Yellow < 10 min, red < 2 min |
| `🧊 cold (234k to rewrite)` | Cache expired: the next message pays full price for those tokens |
| `⌛ 23m15s` | Session duration |
| `⚡5h 40%` / `📅7d 17%` | Usage of the 5-hour and 7-day limits |
| `⇡20%` / `⇣10%` | Ahead of / behind the clock: usage % minus the share of the window elapsed |
| `3h40m` / `4d06h` | Time until that limit resets |
| `→ limit 15:40` | At the current pace you reach the limit at that time, before the reset |

**Subagents row** (only while subagents work)

| Shown | Meaning |
|---|---|
| `🤖 2 active` | Subagents generating right now |
| `research ███░░░ 48%` | Each one's context use; up to 3, then `+N more` |

**Row 3 — repository**

| Shown | Meaning |
|---|---|
| `🐙 owner/repo` | GitHub repository (clickable in iTerm2, Kitty, WezTerm) |
| `⎋ main` | Current branch |
| `🌳 name` | Linked git worktree |
| `@user` | Active GitHub CLI account |
| `🔀 #412 ✓` | Open PR: ✓ approved, ✗ changes requested, ● pending, ○ draft |
| `⚡ project` | Linked Supabase project |
