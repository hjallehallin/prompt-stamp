# prompt-stamp

A Claude Code plugin that tells Claude what time it is, how long you were away, and whether the repo changed while you were gone.

Claude only knows the date a session started. If you resume a session the next morning, or another agent merges a branch while this one sits idle, Claude keeps working from what it saw earlier. prompt-stamp adds one short line to your prompt when that is likely to matter:

```
[stamp] 2026-11-05 Thu 08:12 +0100 · gap 15h40m · git: feature/hero @a1b2c3d, 4 modified, ↓3, worktree, HEAD moved since last prompt (was @9f8e7d6)
```

It stays quiet the rest of the time.

## When it prints

- On the first prompt of a session (with a two-line explanation of the stamp, so no CLAUDE.md changes are needed)
- When 15 minutes or more have passed since the previous prompt
- When `HEAD` has moved since the previous prompt, for example because another agent committed or merged

## What the line contains

| Part | Meaning |
|---|---|
| Date and time | Local time with UTC offset |
| `session start` / `gap 2h05m` | Time since the previous prompt in this session |
| `git: branch @sha` | Current branch and short commit (`detached` if no branch) |
| `N modified` | Tracked files with uncommitted changes |
| `↑N` / `↓N` | Commits ahead of / behind the upstream, as of your last fetch |
| `worktree` | The directory is a linked git worktree |
| `REBASE IN PROGRESS` etc. | A rebase, merge, cherry-pick or revert is unfinished |
| `HEAD moved` | The commit changed since your previous prompt |

Git parts are left out when the working directory is not a git repo.

## Install

In Claude Code:

```
/plugin marketplace add hjallehallin/prompt-stamp
/plugin install prompt-stamp@prompt-stamp
```

Requires `bash`, `git` and `jq`. `jq` ships with macOS 15 and later; on older macOS or Linux install it with your package manager. Without `jq` the hook does nothing.

## Settings

Change the gap threshold (in minutes) with an environment variable in `~/.claude/settings.json`:

```json
{
  "env": {
    "PROMPT_STAMP_GAP_MIN": "30"
  }
}
```

## How it works

A `UserPromptSubmit` hook runs [`stamp.sh`](plugins/prompt-stamp/scripts/stamp.sh). Whatever it prints is added to Claude's context for that prompt.

- It never fetches from a remote, so it is fast and works offline.
- It runs git with `GIT_OPTIONAL_LOCKS=0`, so it never holds the index lock while other agents commit.
- It has a 5 second timeout and exits silently on any error, so it cannot block a prompt.
- It keeps one tiny state file per session (last prompt time and commit). Files older than 30 days are removed.

Nothing is sent anywhere except as part of your normal prompt to Claude. Note that this includes your branch name.

## Credit

Inspired by [this post about an agent timestamp hook on nevyn.dev](https://nevyn.dev/blog/20260805-agent-timestamp-hook/).

## License

MIT
