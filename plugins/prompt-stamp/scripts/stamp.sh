#!/usr/bin/env bash
# prompt-stamp: tells the model what time it is, how long the user was idle,
# and whether git state changed between turns.
#
#   stamp.sh start   SessionStart: print the legend (also after /compact).
#   stamp.sh prompt  UserPromptSubmit: print a stamp on first prompt, after an
#                    idle gap, or when the branch/HEAD changed between turns.
#   stamp.sh stop    Stop: record time and git state when Claude finishes, so
#                    Claude's own work and commits don't count as changes.
#
# Every failure path exits 0 with no output so a prompt or stop is never blocked.
set -u
export GIT_OPTIONAL_LOCKS=0   # never take index.lock; other agents may be committing

mode=${1:-prompt}

if [ "$mode" = start ]; then
  echo "(prompt-stamp: some prompts start with a [stamp] line added by a hook, not typed by the user. It shows local time, how long the user was idle since your last reply, and git state of the working directory. Treat it as background and don't mention it unless it matters. If idle time is over about an hour, or it says the branch or HEAD changed, re-check git status/log and anything else you would otherwise take from earlier in this conversation before acting on it. ↑/↓ are against the last fetch and may be stale.)"
  exit 0
fi

input=$(cat)

# jq when available, plutil (built into macOS) otherwise.
json_get() {
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg k "$1" '.[$k] // empty' <<<"$input" 2>/dev/null
  elif command -v plutil >/dev/null 2>&1; then
    plutil -extract "$1" raw -o - - <<<"$input" 2>/dev/null
  fi
}

sid=$(json_get session_id)
cwd=$(json_get cwd)
[ -n "$sid" ] || exit 0
sid=${sid//[^A-Za-z0-9_-]/_}

state_dir=${CLAUDE_PLUGIN_DATA:-$HOME/.claude/state/prompt-stamp}
mkdir -p "$state_dir" 2>/dev/null || exit 0
state="$state_dir/$sid"
now=$(date +%s)

in_git=0; head="-"; branch="-"; top="-"
if [ -n "$cwd" ] && cd "$cwd" 2>/dev/null && top=$(git rev-parse --show-toplevel 2>/dev/null); then
  in_git=1
  head=$(git rev-parse --short HEAD 2>/dev/null) || head="-"   # no commits yet
  branch=$(git symbolic-ref --short -q HEAD) || branch="detached"
else
  top="-"
fi

# State line: <time> <head> <branch> <toplevel>. "-" marks empty; toplevel is
# last because it may contain spaces and `read` gives the remainder to it.
save_state() { printf '%s %s %s %s\n' "$now" "$head" "$branch" "$top" > "$state" 2>/dev/null; }

if [ "$mode" = stop ]; then
  save_state
  exit 0
fi

last=0; last_head="-"; last_branch="-"; last_top="-"
if [ -f "$state" ]; then
  read -r last last_head last_branch last_top < "$state" || true
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
else
  find "$state_dir" -type f -mtime +30 -delete 2>/dev/null
fi
# Fallback in case Stop never fires (e.g. the reply was interrupted).
save_state

GAP_MIN=${PROMPT_STAMP_GAP_MIN:-15}
case "$GAP_MIN" in ''|*[!0-9]*) GAP_MIN=15 ;; esac
idle=$(( now - last ))

# Only compare git state within the same repo; a cd elsewhere isn't a change.
changed=""
if [ "$in_git" -eq 1 ] && [ "$top" = "$last_top" ]; then
  if [ "$branch" != "$last_branch" ]; then
    changed="branch changed since your last reply (was $last_branch @$last_head)"
  elif [ "$head" != "$last_head" ] && [ "$last_head" != "-" ]; then
    changed="HEAD moved since your last reply (was @$last_head)"
  fi
fi

if [ "$last" -ne 0 ] && [ "$idle" -lt $(( GAP_MIN * 60 )) ] && [ -z "$changed" ]; then
  exit 0
fi

fmt_dur() {
  local d=$(( $1 / 86400 )) h=$(( $1 % 86400 / 3600 )) m=$(( $1 % 3600 / 60 ))
  if [ "$d" -gt 0 ]; then echo "${d}d${h}h"
  elif [ "$h" -gt 0 ]; then echo "${h}h${m}m"
  elif [ "$m" -gt 0 ]; then echo "${m}m"
  else echo "<1m"; fi
}

out="[stamp] $(date '+%Y-%m-%d %a %H:%M %z')"
if [ "$last" -eq 0 ]; then out+=" · session start"; else out+=" · idle $(fmt_dur "$idle")"; fi

if [ "$in_git" -eq 1 ]; then
  g="git: $branch"
  [ "$head" != "-" ] && g+=" @$head"
  modified=$(git status --porcelain --untracked-files=no 2>/dev/null | wc -l | tr -d ' ')
  [ "${modified:-0}" -gt 0 ] && g+=", $modified modified"
  # Counts are against the last fetch; fetching here would be slow and hit the network.
  if ab=$(git rev-list --left-right --count '@{u}...HEAD' 2>/dev/null); then
    read -r behind ahead <<<"$ab"
    [ "$ahead" -gt 0 ] && g+=", ↑$ahead"
    [ "$behind" -gt 0 ] && g+=", ↓$behind"
  fi
  [ "$(git rev-parse --git-dir)" != "$(git rev-parse --git-common-dir)" ] && g+=", worktree"
  for op in rebase-merge:REBASE rebase-apply:REBASE MERGE_HEAD:MERGE CHERRY_PICK_HEAD:CHERRY-PICK REVERT_HEAD:REVERT; do
    if [ -e "$(git rev-parse --git-path "${op%%:*}")" ]; then
      g+=", ${op##*:} IN PROGRESS"
      break
    fi
  done
  [ -n "$changed" ] && g+=", $changed"
  out+=" · $g"
fi

echo "$out"
exit 0
