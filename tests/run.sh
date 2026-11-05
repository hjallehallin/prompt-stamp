#!/usr/bin/env bash
# Tests for stamp.sh: drives it the way Claude Code does (JSON on stdin, one
# mode per hook) against throwaway git repos. Run from anywhere:
#
#   bash tests/run.sh
#
# Needs bash, git, and jq or plutil, like the plugin itself. Bash 3.2-safe.
set -u

here=$(cd "$(dirname "$0")" && pwd)
stamp="$here/../plugins/prompt-stamp/scripts/stamp.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
tmp=$(cd "$tmp" && pwd -P)

export CLAUDE_PLUGIN_DATA="$tmp/state"
# Keep the user's git config (signing, hooks, templates) out of the test repos.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
unset PROMPT_STAMP_GAP_MIN

pass=0; fail=0

# hook <mode> <session> <cwd> [extra JSON fields]
hook() {
  printf '{"session_id":"%s","cwd":"%s"%s}' "$2" "$3" "${4:+,$4}" | bash "$stamp" "$1"
}

# Pretend the last save and the last activity in a session were <seconds> ago.
backdate() {
  local f="$CLAUDE_PLUGIN_DATA/$1" t rest
  t=$(( $(date +%s) - $2 ))
  if [ -f "$f" ]; then
    read -r _ rest < "$f"
    printf '%s %s\n' "$t" "$rest" > "$f"
  fi
  [ -f "$f.turn" ] && echo "$t" > "$f.turn"
  return 0
}

ok()  { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1"; printf '       got: %s\n' "${2:-<nothing>}"; }
expect_has()   { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "$2" ;; esac; }
expect_lacks() { case "$2" in *"$3"*) bad "$1" "$2" ;; *) ok "$1" ;; esac; }
expect_empty() { if [ -z "$2" ]; then ok "$1"; else bad "$1" "$2"; fi; }

repo="$tmp/repo"
git init -q -b main "$repo"
git -C "$repo" commit -q --allow-empty -m init
commit() { git -C "$repo" commit -q --allow-empty -m "$1"; }

# --- the stamp's basics ---------------------------------------------------

out=$(hook prompt first "$repo")
expect_has "first prompt of a session says so" "$out" "session start"

out=$(hook prompt between "$repo"); hook tool between "$repo"; hook stop between "$repo"
commit "the user's own commit"
out=$(hook prompt between "$repo")
expect_has "a commit between replies is reported" "$out" "HEAD +1 commit since your last reply"

hook prompt away "$repo" >/dev/null; hook stop away "$repo"
backdate away 7200
out=$(hook prompt away "$repo")
expect_has "two hours away is stamped" "$out" "idle 2h"

# --- worktrees --------------------------------------------------------------

mkdir -p "$repo/sub/dir"
out=$(hook prompt subdir "$repo/sub/dir")
expect_lacks "a subdirectory of the main checkout is not a worktree" "$out" "worktree"

git -C "$repo" worktree add -q "$tmp/linked" -b linked
out=$(hook prompt linked "$tmp/linked")
expect_has "a linked worktree is reported" "$out" ", worktree"
mkdir -p "$tmp/linked/sub"
out=$(hook prompt linked-sub "$tmp/linked/sub")
expect_has "a subdirectory of a linked worktree is reported" "$out" ", worktree"

# --- prompts that arrive while Claude is still replying ------------------------
# A background task's notification, or a message the user queues, fires
# UserPromptSubmit mid-reply with no Stop before it. What changed since the
# reply began is Claude's own work.

hook prompt midturn "$repo" >/dev/null
commit "Claude's commit, mid-reply"
git -C "$repo" checkout -q -b claude-branch
out=$(hook prompt midturn "$repo")
expect_empty "a mid-reply prompt doesn't report Claude's own commit and checkout" "$out"
git -C "$repo" checkout -q main
hook stop midturn "$repo"
commit "the user's commit after the reply"
out=$(hook prompt midturn "$repo")
expect_has "after Stop, the user's commit is reported again" "$out" "HEAD +1 commit"

hook prompt longturn "$repo" >/dev/null
backdate longturn 1200            # the reply has been running for 20 minutes...
hook tool longturn "$repo"        # ...and is still calling tools
commit "Claude's commit in a long reply"
out=$(hook prompt longturn "$repo")
expect_empty "a long reply that is still using tools stays one turn" "$out"

export PROMPT_STAMP_GAP_MIN=2
hook prompt slowtool "$repo" >/dev/null; hook tool slowtool "$repo"
backdate slowtool 180             # one command ran 3 minutes, past the idle threshold
commit "Claude's commit during a slow command"
out=$(hook prompt slowtool "$repo")
expect_empty "a slow command doesn't end the reply early with a short idle threshold" "$out"
unset PROMPT_STAMP_GAP_MIN

hook prompt interrupted "$repo" >/dev/null; hook tool interrupted "$repo"
backdate interrupted 7200         # interrupted, so no Stop; back two hours later
out=$(hook prompt interrupted "$repo")
expect_has "an interrupted reply goes stale, and the idle time is stamped" "$out" "idle 2h"

hook prompt compacted "$repo" >/dev/null
commit "Claude's commit before an auto-compact"
hook start compacted "$repo" '"source":"compact"' >/dev/null
out=$(hook prompt compacted "$repo")
expect_has "a compact mid-reply still stamps" "$out" "after compact"
expect_lacks "...without calling Claude's commit a change" "$out" "since your last reply"
expect_lacks "...or counting the reply as idle time" "$out" "idle"

# --- tool hook ------------------------------------------------------------------

out=$(hook tool notool "$repo")
expect_empty "the tool hook prints nothing" "$out"
[ ! -e "$CLAUDE_PLUGIN_DATA/notool" ] && ok "the tool hook outside a turn writes no state" \
  || bad "the tool hook outside a turn writes no state" "$(ls "$CLAUDE_PLUGIN_DATA")"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
