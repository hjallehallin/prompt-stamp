# prompt-stamp

A Claude Code plugin that tells Claude what time it is, how long you were away, and whether the repo changed while you were gone.

Claude only knows the date a session started. If you resume a session the next morning, or another agent merges a branch while this one sits idle, Claude keeps working from what it saw earlier. prompt-stamp adds one short line to your prompt when that is likely to matter:

```
[stamp] 2026-11-05 Thu 08:12 +0100 · idle 15h40m · git: feature/hero @a1b2c3d, 4 modified, ↓3, worktree, HEAD moved since your last reply (was @9f8e7d6)
```

It stays quiet the rest of the time.

## When it prints

- On the first prompt of a session
- When you were idle for 15 minutes or more, counted from the end of Claude's last reply (time Claude spends working doesn't count)
- When the branch or `HEAD` changed between Claude's last reply and your prompt, for example because another agent committed or merged. Commits and branch switches Claude makes itself don't count.

At session start, and again after `/compact`, it adds a short explanation of the stamp for Claude, so no CLAUDE.md changes are needed.

## What the line contains

| Part | Meaning |
|---|---|
| Date and time | Local time with UTC offset |
| `session start` / `idle 2h05m` | Time since Claude's last reply in this session |
| `git: branch @sha` | Current branch and short commit (`detached` if no branch) |
| `N modified` | Tracked files with uncommitted changes |
| `↑N` / `↓N` | Commits ahead of / behind the upstream, as of your last fetch |
| `worktree` | The directory is a linked git worktree |
| `REBASE IN PROGRESS` etc. | A rebase, merge, cherry-pick or revert is unfinished |
| `branch changed` / `HEAD moved` | Git state changed since Claude's last reply |

Git parts are left out when the working directory is not a git repo.

## Install

In Claude Code:

```
/plugin marketplace add hjallehallin/prompt-stamp
/plugin install prompt-stamp@prompt-stamp
```

Requires `bash` and `git`. JSON is read with `jq` if installed, otherwise with `plutil`, which is built into macOS. On Linux, install `jq`; without either tool the hook does nothing.

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

Three hooks run [`stamp.sh`](plugins/prompt-stamp/scripts/stamp.sh):

- `SessionStart` prints the explanation for Claude.
- `Stop` records the time, branch and commit when Claude finishes a reply. It prints nothing.
- `UserPromptSubmit` compares against that record and prints the stamp when something changed. Whatever it prints is added to Claude's context for that prompt.

- It never fetches from a remote, so it is fast and works offline.
- It runs git with `GIT_OPTIONAL_LOCKS=0`, so it never holds the index lock while other agents commit.
- It has a 5 second timeout and exits silently on any error, so it cannot block a prompt or a reply.
- It keeps one tiny state file per session (time, branch, commit and repo path). Files older than 30 days are removed.

Nothing is sent anywhere except as part of your normal prompt to Claude. Note that this includes your branch name.

## Credit

Inspired by [this post about an agent timestamp hook on nevyn.dev](https://nevyn.dev/blog/20260805-agent-timestamp-hook/).

## License

MIT
