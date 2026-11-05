#!/usr/bin/env bash
# prompt-stamp: tells the model what time it is, how long the user was idle,
# and what changed in git between turns.
#
#   stamp.sh start   SessionStart: print the legend; after resume/compact/clear,
#                    force a stamp on the next prompt.
#   stamp.sh prompt  UserPromptSubmit: print a stamp on first prompt, after an
#                    idle gap, after resume/compact/clear, or when git changed.
#   stamp.sh stop    Stop: record time and git state when Claude finishes, so
#                    Claude's own work doesn't count as a change.
#   stamp.sh tool    PreToolUse: note that a reply is still running. A prompt
#                    that arrives mid-reply (a background task's notification,
#                    or a message the user queues) fires UserPromptSubmit with
#                    no Stop before it, and must not report Claude's own work.
#
# Local git only: never fetches, never runs repo-provided code.
# Every failure path exits 0 with no output so a prompt or stop is never blocked.
set -u
export GIT_OPTIONAL_LOCKS=0   # never take index.lock; other agents may be committing

mode=${1:-prompt}
input=$(cat)

legend() {
  echo "(prompt-stamp: some prompts start with a [stamp] line added by a hook, not typed by the user. It shows local time, how long the user was idle since your last reply, git state of the working directory, and anything in git that changed since your last reply. Treat it as background and don't mention it unless it matters. If idle time is over about an hour, or it reports a change, re-check git status/log and anything else you would otherwise take from earlier in this conversation before acting on it. ↑/↓ are as of the last fetch; if that fetch is old, run git fetch --prune before pushing or creating branches. \"upstream gone\" means the remote branch was deleted, usually after a merge: don't push it again without asking the user.)"
}

# jq when available, plutil (built into macOS) otherwise.
json_get() {
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg k "$1" '.[$k] // empty' <<<"$input" 2>/dev/null
  elif command -v plutil >/dev/null 2>&1; then
    plutil -extract "$1" raw -o - - <<<"$input" 2>/dev/null
  fi
}

[ "$mode" = start ] && legend

sid=$(json_get session_id)
[ -n "$sid" ] || exit 0
sid=${sid//[^A-Za-z0-9_-]/_}

state_dir=${CLAUDE_PLUGIN_DATA:-$HOME/.claude/state/prompt-stamp}
mkdir -p "$state_dir" 2>/dev/null || exit 0
state="$state_dir/$sid"
marker="$state.source"
# Present while a reply is running: written by a prompt, refreshed by every
# tool call, removed by Stop. Holds the time Claude was last seen working.
turn="$state.turn"

if [ "$mode" = start ]; then
  src=$(json_get source)
  case "$src" in resume|compact|clear) echo "$src" > "$marker" 2>/dev/null ;; esac
  exit 0
fi

now=$(date +%s)

# Cheap on purpose: it runs before every tool call. No git, and nothing at all
# outside a reply.
if [ "$mode" = tool ]; then
  [ -f "$turn" ] && echo "$now" > "$turn" 2>/dev/null
  exit 0
fi

GAP_MIN=${PROMPT_STAMP_GAP_MIN:-15}
case "$GAP_MIN" in ''|*[!0-9]*) GAP_MIN=15 ;; esac
# How long a reply may go without a tool call and still count as running. At
# least 15 minutes whatever the idle threshold: a single slow command (a build,
# a test run) must not make a reply look interrupted, or a mid-reply prompt
# reports Claude's own work again.
TURN_MIN=$(( GAP_MIN > 15 ? GAP_MIN : 15 ))
cwd=$(json_get cwd)

in_git=0; head="-"; branch="-"; top="-"; fp="-"; porc=""; upstream=""; track=""; upgone=0
if [ -n "$cwd" ] && cd "$cwd" 2>/dev/null && top=$(git rev-parse --show-toplevel 2>/dev/null); then
  in_git=1
  head=$(git rev-parse --short HEAD 2>/dev/null) || head="-"   # no commits yet
  branch=$(git symbolic-ref --short -q HEAD) || branch="detached"
  porc=$(git status --porcelain=v1 --untracked-files=normal 2>/dev/null)
  # Fingerprint of the uncommitted state. The diff is capped so huge trees stay
  # fast; content edits to untracked or binary files are not detected.
  fp=$( { printf '%s\n' "$porc"; git diff HEAD --no-ext-diff --no-color 2>/dev/null | head -c 2000000; } | cksum | cut -d' ' -f1)
  if [ "$branch" != detached ]; then
    # track is "[gone]", "[ahead N]", "[behind M]", "[ahead N, behind M]" or empty,
    # relative to the last fetch. upstream is empty when none is configured.
    IFS='|' read -r upstream track <<<"$(git for-each-ref --format='%(upstream:short)|%(upstream:track)' "refs/heads/$branch" 2>/dev/null)"
    case "$track" in *gone*) upgone=1 ;; esac
  fi
else
  top="-"
fi

# State line: <time> <head> <branch> <fingerprint> <upstream gone> <toplevel>.
# "-" marks empty; toplevel is last because it may contain spaces and `read`
# gives it the remainder.
save_state() { printf '%s %s %s %s %s %s\n' "$now" "$head" "$branch" "$fp" "$upgone" "$top" > "$state" 2>/dev/null; }

if [ "$mode" = stop ]; then
  save_state
  rm -f "$turn"
  exit 0
fi

last=0; last_head="-"; last_branch="-"; last_fp="-"; last_upgone=0; last_top="-"
if [ -f "$state" ]; then
  read -r last last_head last_branch last_fp last_upgone last_top < "$state" || true
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
else
  find "$state_dir" -type f -mtime +30 -delete 2>/dev/null
fi
src=""
if [ -f "$marker" ]; then
  src=$(cat "$marker" 2>/dev/null); rm -f "$marker"
fi

# Is a reply still running? Only if Claude was seen working within TURN_MIN:
# an interrupted reply never fires Stop, and its turn file then goes stale,
# with idle time counted from Claude's last tool call.
midturn=0
if [ -f "$turn" ]; then
  active=$(cat "$turn" 2>/dev/null)
  case "$active" in ''|*[!0-9]*) active=0 ;; esac
  if [ $(( now - active )) -lt $(( TURN_MIN * 60 )) ]; then
    midturn=1
  elif [ "$active" -gt "$last" ]; then
    last=$active
  fi
fi
echo "$now" > "$turn" 2>/dev/null

# Fallback in case Stop never fires (e.g. the reply was interrupted). Mid-reply
# it also moves the baseline past Claude's own work so far.
save_state

# Mid-reply, what changed is Claude's own work and no one has been idle: stay
# quiet, unless a compact or clear just happened, which still deserves the
# time and git state.
[ "$midturn" -eq 1 ] && [ -z "$src" ] && exit 0

fmt_dur() {
  local d=$(( $1 / 86400 )) h=$(( $1 % 86400 / 3600 )) m=$(( $1 % 3600 / 60 ))
  if [ "$d" -gt 0 ]; then echo "${d}d${h}h"
  elif [ "$h" -gt 0 ]; then echo "${h}h${m}m"
  elif [ "$m" -gt 0 ]; then echo "${m}m"
  else echo "<1m"; fi
}

# Only compare git state within the same repo; a cd elsewhere isn't a change.
plural() { if [ "$1" -eq 1 ]; then echo "1 $2"; else echo "$1 ${2}s"; fi; }

changed=""; force=0
if [ "$midturn" -eq 0 ] && [ "$in_git" -eq 1 ] && [ "$top" = "$last_top" ]; then
  if [ "$branch" != "$last_branch" ]; then
    changed="branch changed since your last reply (was $last_branch @$last_head)"
  elif [ "$head" != "$last_head" ] && [ "$last_head" != "-" ]; then
    if git merge-base --is-ancestor "$last_head" HEAD 2>/dev/null; then
      changed="HEAD +$(plural "$(git rev-list --count "$last_head..HEAD")" commit) since your last reply"
    elif git merge-base --is-ancestor HEAD "$last_head" 2>/dev/null; then
      changed="HEAD moved back $(plural "$(git rev-list --count "HEAD..$last_head")" commit) since your last reply"
    else
      changed="history rewritten since your last reply (was @$last_head)"
    fi
    reflog=$(git reflog -1 --format=%gs 2>/dev/null | cut -c1-60)
    [ -n "$reflog" ] && changed+=", last git action: $reflog"
  elif [ "$fp" != "$last_fp" ] && [ "$last_fp" != "-" ]; then
    changed="working tree changed since your last reply"
  fi
  # The remote branch was deleted between turns: the next push would recreate it.
  [ "$branch" = "$last_branch" ] && [ "$upgone" = 1 ] && [ "$last_upgone" != 1 ] && force=1
fi

idle=$(( now - last ))

if [ "$last" -ne 0 ] && [ -z "$src" ] && [ "$idle" -lt $(( GAP_MIN * 60 )) ] && [ -z "$changed" ] && [ "$force" -eq 0 ]; then
  exit 0
fi

out="[stamp] $(date '+%Y-%m-%d %a %H:%M %z')"
if [ "$last" -eq 0 ]; then out+=" · session start"
elif [ "$midturn" -eq 0 ]; then out+=" · idle $(fmt_dur "$idle")"; fi
case "$src" in
  resume)  out+=" · resumed" ;;
  compact) out+=" · after compact" ;;
  clear)   out+=" · after clear" ;;
esac

if [ "$in_git" -eq 1 ]; then
  g="git: $branch"
  [ "$head" != "-" ] && g+=" @$head"
  if [ -n "$porc" ]; then
    modified=$(grep -vc '^??' <<<"$porc")
    new=$(grep -c '^??' <<<"$porc")
    [ "$modified" -gt 0 ] && g+=", $modified modified"
    [ "$new" -gt 0 ] && g+=", $new new"
  fi
  if [ -n "$upstream" ]; then
    if [ "$upgone" -eq 1 ]; then
      g+=", upstream gone ($upstream)"
    else
      ahead=$(sed -n 's/.*ahead \([0-9]*\).*/\1/p' <<<"$track")
      behind=$(sed -n 's/.*behind \([0-9]*\).*/\1/p' <<<"$track")
      [ -n "$ahead" ] && g+=", ↑$ahead"
      [ -n "$behind" ] && g+=", ↓$behind"
    fi
    fetch_head=$(git rev-parse --git-path FETCH_HEAD 2>/dev/null)
    # A fresh clone has no FETCH_HEAD; leave the age out rather than guess.
    if [ -f "$fetch_head" ] && fetched=$(date -r "$fetch_head" +%s 2>/dev/null); then
      g+=", fetched $(fmt_dur $(( now - fetched ))) ago"
    fi
  fi
  # Compared as resolved paths: from a subdirectory, --git-dir comes back
  # absolute and --git-common-dir relative, so the strings never match.
  gitdir=$(cd "$(git rev-parse --git-dir 2>/dev/null)" 2>/dev/null && pwd -P)
  commondir=$(cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)
  [ -n "$gitdir" ] && [ "$gitdir" != "$commondir" ] && g+=", worktree"
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
