# `.claude/` — Claude Code agent state

This directory holds configuration for the [Claude Code](https://claude.com/claude-code)
CLI agent. Most files in here are **per-developer state and are gitignored**.

## What lives here

| File | Tracked? | Purpose |
|------|----------|---------|
| `README.md` | yes | This file. Documents what is and isn't shared. |
| `settings.json` | yes (if present) | Repo-wide Claude Code policy. Currently absent — add only if the team agrees on a shared allowlist. |
| `settings.local.json` | **no** | Per-developer agent allowlist. Holds the local set of pre-approved Bash commands, MCP servers, etc. |
| `scheduled_tasks.lock` | no | Runtime lock file written by the agent. |
| `worktrees/` | no | Isolation worktrees the agent creates while working on multiple branches in parallel. |

The `.gitignore` rule is `.claude/*` with explicit re-includes for `README.md`
and `settings.json` — anything else dropped in here will be ignored without
further configuration.

## Why `settings.local.json` is local

The file contains a long allowlist of pre-approved shell commands. Some are
benign (e.g. `swift test --filter ...`), but it also accumulates destructive
or machine-specific entries over time — `git push` to specific remotes,
`pkill -f ManifoldDemo`, `rm -rf ~/Library/Containers/...`, paths under your
home directory, etc. None of that is appropriate to share, and the set you
need depends on your machine and habits. Keep it local.

If you want a starter list, run a few sessions, accept the prompts as they
come up, and Claude Code will write the file for you.

## Adding a shared `settings.json`

If we ever agree on a small, audited set of repo-wide allowlist entries
(say, "always allow `swift build` and `swift test`"), put them in
`.claude/settings.json` and commit that file. Keep it minimal — anything
destructive belongs in each developer's `settings.local.json`.
