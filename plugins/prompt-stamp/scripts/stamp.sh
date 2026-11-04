#!/usr/bin/env bash
# prompt-stamp: UserPromptSubmit hook that tells the model what time it is,
# how long it has been since the last prompt, and the git state of the cwd.
# Prints only on session start, after a gap, or when HEAD moved; otherwise silent.
# Every failure path exits 0 with no output so a prompt is never blocked.
set -u
export GIT_OPTIONAL_LOCKS=0   # never take index.lock; other agents may be committing

command -v jq >/dev/null 2>&1 || exit 0

GAP_MIN=${PROMPT_STAMP_GAP_MIN:-15}
case "$GAP_MIN" in ''|*[!0-9]*) GAP_MIN=15 ;; esac

input=$(cat)
sid=$(jq -r '.session_id // empty' <<<"$input" 2>/dev/null)
cwd=$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null)
[ -n "$sid" ] || exit 0
sid=${sid//[^A-Za-z0-9_-]/_}

state_dir=${CLAUDE_PLUGIN_DATA:-$HOME/.claude/state/prompt-stamp}
mkdir -p "$state_dir" 2>/dev/null || exit 0
state="$state_dir/$sid"

now=$(date +%s)
last=0; last_head=""
if [ -f "$state" ]; then
  read -r last last_head < "$state" || true
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
else
  find "$state_dir" -type f -mtime +30 -delete 2>/dev/null
fi

in_git=0; head=""
if [ -n "$cwd" ] && cd "$cwd" 2>/dev/null && git rev-parse --git-dir >/dev/null 2>&1; then
  in_git=1
  head=$(git rev-parse --short HEAD 2>/dev/null)   # empty in a repo with no commits
fi
printf '%s %s\n' "$now" "$head" > "$state" 2>/dev/null

gap=$(( now - last ))
moved=0
[ -n "$last_head" ] && [ -n "$head" ] && [ "$head" != "$last_head" ] && moved=1

if [ "$last" -ne 0 ] && [ "$gap" -lt $(( GAP_MIN * 60 )) ] && [ "$moved" -eq 0 ]; then
  exit 0
fi

fmt_gap() {
  local d=$(( $1 / 86400 )) h=$(( $1 % 86400 / 3600 )) m=$(( $1 % 3600 / 60 ))
  if [ "$d" -gt 0 ]; then echo "${d}d${h}h"
  elif [ "$h" -gt 0 ]; then echo "${h}h${m}m"
  elif [ "$m" -gt 0 ]; then echo "${m}m"
  else echo "<1m"; fi
}

out="[stamp] $(date '+%Y-%m-%d %a %H:%M %z')"
if [ "$last" -eq 0 ]; then out+=" · session start"; else out+=" · gap $(fmt_gap "$gap")"; fi

if [ "$in_git" -eq 1 ]; then
  branch=$(git symbolic-ref --short -q HEAD || echo "detached")
  g="git: $branch"
  [ -n "$head" ] && g+=" @$head"
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
  [ "$moved" -eq 1 ] && g+=", HEAD moved since last prompt (was @$last_head)"
  out+=" · $g"
fi

echo "$out"

if [ "$last" -eq 0 ]; then
  echo "(The [stamp] line is added by a hook, not typed by the user: local time, time since the previous prompt, and git state of the working directory. Treat it as background and don't mention it unless it matters. If the gap is over about an hour, or HEAD moved, re-check git status/log and anything else you would otherwise take from earlier in this conversation before acting on it. ↑/↓ are against the last fetch and may be stale.)"
fi

exit 0
