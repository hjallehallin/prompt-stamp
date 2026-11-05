# prompt-stamp

A Claude Code plugin that tells Claude what time it is, how long you were away, and whether the repo changed while you were gone.

Claude only knows the date a session started. If you resume a session the next morning, or another agent merges a branch while this one sits idle, Claude keeps working from what it saw earlier. prompt-stamp adds one short line to your prompt when that is likely to matter:

```
[stamp] 2026-11-05 Thu 08:12 +0100 · idle 15h40m · git: feature/hero @a1b2c3d, 4 modified, 1 new, ↓3, fetched 2d1h ago, HEAD +2 commits since your last reply, last git action: pull: Fast-forward
```

It stays quiet the rest of the time.

## When it prints

- On the first prompt of a session
- When you were idle for 15 minutes or more, counted from the end of Claude's last reply (time Claude spends working doesn't count)
- On the first prompt after `/compact`, `/clear` or resuming a session, when Claude's picture of the repo is most likely out of date
- When git changed between Claude's last reply and your prompt: the branch, `HEAD`, the files in the working tree, or the remote branch being deleted (noticed after a `git fetch --prune`). Changes Claude makes itself during a reply don't count.

A prompt that arrives while Claude is still replying (a background task's notification, or a message you queue) gets no stamp, because whatever changed since the reply began is Claude's own work. The exception is a compact or clear, which still gets the time and git state. If you interrupt a reply and come back after more than 15 minutes (or the idle threshold, if you set it higher), the next prompt is stamped as usual, with idle time counted from Claude's last tool call.

Whenever a session starts, resumes, is cleared or is compacted, it adds a short explanation of the stamp for Claude, so no CLAUDE.md changes are needed. The explanation also tells Claude to fetch before pushing when the last fetch is old, and not to push a branch whose remote was deleted without asking you.

## What the line contains

| Part | Meaning |
|---|---|
| Date and time | Local time with UTC offset |
| `session start` / `idle 2h05m` | Time since Claude's last reply in this session |
| `resumed` / `after compact` / `after clear` | The session was just resumed, compacted or cleared |
| `git: branch @sha` | Current branch and short commit (`detached` if no branch) |
| `N modified` / `N new` | Tracked files with uncommitted changes / untracked files |
| `↑N` / `↓N` | Commits ahead of / behind the upstream, as of your last fetch |
| `fetched 2d ago` | When the repo last fetched, so Claude can judge how stale ↑/↓ are. Left out until the first fetch after a clone |
| `upstream gone` | The remote branch was deleted, usually after a merge. Pushing would recreate it |
| `worktree` | The directory is a linked git worktree |
| `REBASE IN PROGRESS` etc. | A rebase, merge, cherry-pick or revert is unfinished |
| `branch changed` | A different branch is checked out now than at Claude's last reply |
| `HEAD +N commits` / `moved back N commits` / `history rewritten` | How `HEAD` moved since Claude's last reply, with the last reflog entry (e.g. `pull: Fast-forward`) |
| `working tree changed` | Files were edited, discarded or added since Claude's last reply, while `HEAD` stayed put |

Git parts are left out when the working directory is not a git repo.

## Install

In Claude Code:

```
/plugin marketplace add hjallehallin/prompt-stamp
/plugin install prompt-stamp@prompt-stamp
```

To update later, run `/plugin marketplace update prompt-stamp` and start a new session.

Requires `bash` and `git`. JSON is read with `jq` if installed, otherwise with `plutil`, which is built into macOS. On Linux, install `jq`; without either tool the hook does nothing.

## Settings

The idle threshold is 15 minutes. Change it with an environment variable in `~/.claude/settings.json`:

```json
{
  "env": {
    "PROMPT_STAMP_GAP_MIN": "30"
  }
}
```

## How it works

Four hooks run [`stamp.sh`](plugins/prompt-stamp/scripts/stamp.sh):

- `SessionStart` prints the explanation for Claude.
- `Stop` records the time, branch, commit, upstream status and a checksum of the uncommitted changes when Claude finishes a reply. It prints nothing.
- `UserPromptSubmit` compares against that record and prints the stamp when one of the conditions under [When it prints](#when-it-prints) is met. Whatever it prints is added to Claude's context for that prompt. It also marks a reply as running, until `Stop` clears it.
- `PreToolUse` records when Claude was last seen working, so a long reply still counts as running. It prints nothing, runs no git, and does nothing between replies.

Design choices:

- It only reads local git state. It never fetches, so it is fast and works offline.
- It never runs scripts from the repo. A cloned repo could otherwise run code on every prompt without Claude Code's workspace trust check. Projects that need their own checks can add a project hook in `.claude/settings.json`, which is trust-gated.
- It runs git with `GIT_OPTIONAL_LOCKS=0`, so it never holds the index lock while other agents commit.
- It has a 5 second timeout and exits silently on any error, so it cannot block a prompt or a reply.
- It keeps a few tiny state files per session in the plugin's data folder (or `~/.claude/state/prompt-stamp/`). Files older than 30 days are removed.
- The working-tree check reads at most 2 MB of diff, and does not notice content edits to untracked or binary files.
- A command Claude leaves running in the background can still change the repo after the reply ends. The next prompt then reports that change as if it were yours.

`bash tests/run.sh` runs the tests, against throwaway repos and state.

Nothing is sent anywhere except as part of your normal prompt to Claude. Note that this includes your branch name and the latest reflog entry, which can contain a commit message.

## Credit

Inspired by [this post about an agent timestamp hook on nevyn.dev](https://nevyn.dev/blog/20260805-agent-timestamp-hook/).

## License

MIT
