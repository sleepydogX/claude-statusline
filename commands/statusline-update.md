---
description: Update the Claude Code statusline to the latest version from git
---

Update the claude-statusline project to its latest version.

1. Run `git -C "__REPO_PATH__" pull --ff-only origin main` and report the output. If the pull fails (e.g. local changes), stop and explain.
2. Run `bash "__REPO_PATH__/install.sh"`. The installer enters upgrade mode automatically; it will not re-prompt.
3. Summarize what changed: new commits pulled (from `git log --oneline <old-sha>..HEAD` in the repo) and the installer's summary line.
4. Remind the user to restart their Claude Code session to see the new statusline.
