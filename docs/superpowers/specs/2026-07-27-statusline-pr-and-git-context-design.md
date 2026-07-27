# Design — Statusline PR Badge & Payload-Sourced Git Context

**Date:** 2026-07-27
**Status:** Approved for planning
**Scope:** `statusline.js` (row 3), `install.sh`, `scripts/smoke-test.sh`, `scripts/fixtures/`, `README.md`

## Goal

Show the open pull request for the current branch in the status line, and source the
rest of row 3's git context from the payload instead of subprocesses. Row 3 stops
shelling out to git entirely, and the branch stops going stale behind a cache.

## Non-goals

- No `gh` API calls for PR data. The payload already carries `pr`; adding a network
  call would make the status line slower and rate-limited.
- No rework of the `gh auth status` or `supabase status` calls. They stay behind the
  existing 120-second session cache. Reducing them is a separate batch.
- No changes to rows 1 and 2.
- No general refactor of `statusline.js` into module-level helpers. This design
  changes one region of the file.

## Background — verified against Claude Code 2.1.220

The status line payload builder was read directly from the installed executable
(`~/.local/share/claude/versions/2.1.220`). Relevant fields it emits:

```js
workspace: { current_dir, project_dir, added_dirs, ...git_worktree, ...repo },
...pr && { pr: { number, url, ...review_state, ...kind } },
...worktree && { worktree: { name, path, branch, original_cwd, original_branch } }
```

- `workspace.repo` is `{ host, owner, name }`, parsed from the `origin` remote.
  Absent outside a git repo or with no `origin` remote.
- `workspace.git_worktree` is populated for **any** linked git worktree, not only
  `--worktree` sessions. This is why it is preferred over the `worktree` object.
- `pr` is present only while an open PR exists for the branch, and disappears once
  the PR merges or closes. `pr.review_state` may be absent independently.
- `pr.kind` exists in the binary but is undocumented; this design ignores it.

The status line re-runs on every assistant message, so no polling is needed.

## Architecture

Row 3 splits into two blocks, divided by what the data costs to obtain.

| Block | Data | I/O | Cache |
|---|---|---|---|
| **Git context** (new) | repo, worktree, PR, branch | none, or one file read | none — always fresh |
| **Integrations** (shrunk) | `gh_user`, `sb_project` | subprocesses | 120s per session, unchanged |

The existing `git remote get-url origin` and `git branch --show-current` calls move
into the cached block as **fallbacks**, executed only when their cheap source fails.
On current Claude Code builds they never run.

This boundary is the point of the change: "free and always fresh" is separated from
"expensive and cached", so a segment cannot accidentally inherit staleness it does
not need.

## Row 3 rendering

```
🐙 JawaSec/secops-portal ⎇ dev/kenneth 🌳 fix-auth @jawkgonzalez │ 🔀 #412 ✓ │ ⚡ my-project
```

| Piece | Source | Visible when |
|---|---|---|
| `🐙 owner/name` | `workspace.repo`; OSC 8 link to `https://{host}/{owner}/{name}` | repo known (payload, else git fallback) |
| `⎇ branch` | `.git/HEAD` | git dir resolves |
| `🌳 worktree` | `workspace.git_worktree` | inside a linked worktree |
| `@user` | `gh auth status` (cached) | unchanged from today |
| `🔀 #412 ✓` | `data.pr`; number is an OSC 8 link to `pr.url` | an open PR exists for the branch |

The repo link requires `workspace.repo.host`. On the git-remote fallback path the
host is not reconstructed, so the repo renders as plain text without a link.

### PR review state

| `review_state` | Symbol | ANSI color |
|---|---|---|
| `approved` | `✓` | green (`\x1b[32m`) |
| `changes_requested` | `✗` | orange (`\x1b[38;5;208m`) |
| `pending` | `●` | yellow (`\x1b[33m`) |
| `draft` | `○` | dim (`\x1b[2m`) |
| absent | none | default white (`\x1b[1;37m`) |

An unrecognized `review_state` renders as if absent: number only, no symbol. The
color applies to both the `#N` and the symbol so the badge reads as one unit.

## Branch resolution

Replaces `git branch --show-current` with a filesystem read, run on every
invocation.

1. Start at `workspace.current_dir`. Look for `.git`. If not found, walk up parent
   directories, stopping at the filesystem root or after 10 levels.
2. If `.git` is a **file** rather than a directory — the worktree and submodule case
   — read its `gitdir: <path>` line and continue from that path. Relative paths
   resolve against the directory containing the `.git` file.
3. Read `HEAD` from the resolved git dir. `ref: refs/heads/NAME` yields `NAME`.
   Anything else is a detached HEAD, rendered as the first 7 characters of the SHA.
4. On any failure, fall back to the cached `git branch --show-current`.

The 10-level cap bounds the walk on pathological paths; real repositories resolve
within a few levels.

## OSC 8 link safety

Links use `\x1b]8;;URL\x07TEXT\x1b]8;;\x07`.

A URL is wrapped only if it matches `^https?://` and contains no control characters
(`ESC`, `BEL`, `\n`, `\r`). Otherwise the text renders unwrapped, without a link.
URLs originate from Claude Code, so this is defense in depth rather than a live
threat: it guarantees a malformed URL cannot inject escape sequences into the
terminal or corrupt the rest of the row.

Terminals without OSC 8 support display the text and ignore the sequence.

## Error handling

Each new piece gets its own silent `try/catch`, matching the file's existing style.
A missing or malformed field hides its segment; it never crashes the status line or
prints `undefined`. The top-level `try/catch` around the whole render stays as the
last resort.

## Configuration

A new `pr` flag in `MODULES`, defaulting to `true`, with a matching prompt in
`install.sh` and a key in the generated config. Repo, branch, and worktree remain
under the existing `github` flag, since they are the same GitHub context.

The installer's upgrade path adds `pr` to existing configs as `true`, preserving
all other user values — the same merge behavior already in place.

## Testing

New fixtures and smoke tests in the existing harness:

**PR segment**
- Each of the four `review_state` values renders its symbol and color.
- `review_state` absent → `#N` with no symbol.
- Unrecognized `review_state` → treated as absent.
- `pr` absent → segment hidden entirely.
- `pr.url` non-http (e.g. `javascript:`) → number renders, no OSC 8 sequence emitted.
- Valid `pr.url` → output contains the OSC 8 sequence.

**Git context**
- `workspace.repo` present → `owner/name` renders.
- Run with `git` removed from `PATH` and `workspace.repo` present → repo and branch
  still render, proving no subprocess is involved.
- `workspace.git_worktree` present → worktree piece renders; absent → hidden.

**Branch resolution** — using temporary directories with a synthetic `.git`:
- `.git/HEAD` containing `ref: refs/heads/feature/x` → `feature/x`.
- `.git/HEAD` containing a bare SHA → 7-character short SHA.
- `.git` as a file containing `gitdir: <path>` → resolves through to that directory.
- `current_dir` two levels below the repo root → walk-up finds it.
- No `.git` anywhere → branch piece hidden, no crash.

## Risks

- **Branch read on every invocation.** It is two small file reads with no process
  spawn, well under the debounce window. The previous subprocess was the slower
  path even when cached.
- **Fallback paths are hard to exercise.** The git fallbacks only run on Claude Code
  builds that omit `workspace.repo`. Tests cover that the code path exists and does
  not crash; they do not assert the subprocess output.
- **Emoji width.** `🌳` and `🔀` are double-width. Row 3 grows by roughly 12 columns
  when both a worktree and a PR are present. Terminal-width-aware layout is a later
  batch and is explicitly out of scope here.
