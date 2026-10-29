#!/usr/bin/env bash
# Read-only: what state is every shared clone actually in, and who is holding it?
#
# Usage:
#   fleet-repo-state.sh              # every repo that needs attention
#   fleet-repo-state.sh <repo>       # one repo, always shown
#   fleet-repo-state.sh --all        # every repo, including boring ones
#
# THE POINT: a plan file or a note saying "repo X is owned by another session on branch Y"
# is a SNAPSHOT, never a fact. Session 431272bb wrote exactly that about exporterplus and
# hotfix/129.0.2; by the time the user read it the hotfix had shipped, been released, and
# the branch deleted. 9 of 58 plan files carry a claim of that shape. Run this before
# acting on any of them.
#
# Purely read-only -- no fetch, no checkout, no writes. Safe to run any time.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../hooks/lib-repo-claims.sh
. "$HERE/../hooks/lib-repo-claims.sh" 2>/dev/null || . "$HOME/.claude/hooks/lib-repo-claims.sh"
# shellcheck source=../hooks/lib-session-liveness.sh
. "$HERE/../hooks/lib-session-liveness.sh" 2>/dev/null || . "$HOME/.claude/hooks/lib-session-liveness.sh"

ROOT="${AMA_REPOS_ROOT:-$HOME/Repos/AMA_APP}"
[ -d "$ROOT" ] || ROOT="/c/Users/$(whoami | sed 's/.*\\//')/Repos/AMA_APP"

want="${1:-}"
show_all=false
[ "$want" = "--all" ] && { show_all=true; want=""; }

printf '%-28s %-32s %-7s %-9s %s\n' REPO BRANCH DIRTY WORKTREES "HELD BY"
printf '%.0s-' $(seq 1 104); echo

interesting=0; total=0
for d in "$ROOT"/*/; do
  [ -d "$d/.git" ] || [ -f "$d/.git" ] || continue
  name="$(basename "$d")"
  [ -n "$want" ] && [ "$name" != "$want" ] && continue
  total=$((total + 1))

  # tr -d '\n' on every field: an unborn-branch repo (mappingtool-service) makes rev-parse
  # emit "HEAD" AND fail, and `grep -c` prints 0 while exiting 1 -- so the obvious
  # `|| echo 0` fallback appends a SECOND 0 and the whole row wraps. Count with wc, not
  # grep -c, and flatten everything.
  branch="$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null | tr -d '\n')"
  [ -n "$branch" ] || branch='(unborn)'
  dirty="$(git -C "$d" status --porcelain 2>/dev/null | grep -v '^??' | wc -l | tr -d ' \n')"
  wt="$(git -C "$d" worktree list 2>/dev/null | wc -l | tr -d ' \n')"

  held="-"
  root="$(claims_repo_root "$d")"
  claim="$(claims_get "$root")"
  if [ -n "$claim" ]; then
    csid="$(printf '%s' "$claim" | cut -f1)"
    cbr="$(printf '%s' "$claim" | cut -f2)"
    cwhen="$(printf '%s' "$claim" | cut -f3)"
    if session_is_live "$csid"; then
      held="LIVE ${csid%%-*} on $cbr ($(claims_describe_age "$cwhen") ago)"
    else
      held="stale ${csid%%-*} on $cbr ($(claims_describe_age "$cwhen") ago)"
    fi
  fi

  # "Interesting" = anything a session could trip over: off default branch, uncommitted
  # tracked work, extra worktrees, or a live holder.
  odd=false
  case "$branch" in master|develop|main) ;; *) odd=true ;; esac
  [ "$dirty" -gt 0 ] 2>/dev/null && odd=true
  [ "$wt" -gt 1 ] 2>/dev/null && odd=true
  case "$held" in LIVE*) odd=true ;; esac

  if [ "$odd" = true ] || [ "$show_all" = true ] || [ -n "$want" ]; then
    interesting=$((interesting + 1))
    printf '%-28s %-32s %-7s %-9s %s\n' "$name" "$branch" "$dirty" "$wt" "$held"

    # A worktree count is not actionable -- "3" tells you nothing about which branches are
    # spoken for. List the LINKED trees: each is a working tree like any other, with its own
    # branch, its own dirty state and its own claim holder, and a branch held here cannot be
    # checked out or deleted in the main clone (worktree-branch-conflict-gate.sh warns about
    # exactly that). Without this, a session working inside C:/ep-worktrees/* is invisible to
    # this sweep, because the loop above only walks $ROOT/*/.
    if [ "$wt" -gt 1 ] 2>/dev/null; then
      main_top="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)"
      # --porcelain: stable worktree/branch/detached records. The human format's column
      # alignment makes a path containing spaces unparseable.
      git -C "$d" worktree list --porcelain 2>/dev/null \
        | awk '/^worktree /{p=substr($0,10)} /^branch /{b=$2; sub("refs/heads/","",b); print p "\t" b} /^detached/{print p "\t(detached)"}' \
        | while IFS="$(printf '\t')" read -r wpath wbranch; do
            [ -n "$wpath" ] || continue
            [ "$wpath" = "$main_top" ] && continue
            wdirty="$(git -C "$wpath" status --porcelain 2>/dev/null | grep -v '^??' | wc -l | tr -d ' \n')"
            wheld="-"
            wroot="$(claims_repo_root "$wpath")"
            wclaim="$(claims_get "$wroot")"
            if [ -n "$wclaim" ]; then
              wsid="$(printf '%s' "$wclaim" | cut -f1)"
              wwhen="$(printf '%s' "$wclaim" | cut -f3)"
              if session_is_live "$wsid"; then
                wheld="LIVE ${wsid%%-*} ($(claims_describe_age "$wwhen") ago)"
              else
                wheld="stale ${wsid%%-*} ($(claims_describe_age "$wwhen") ago)"
              fi
            fi
            printf '  └ worktree %-16s %-32s %-7s %-9s %s\n' "$(basename "$wpath")" "$wbranch" "$wdirty" "" "$wheld"
            printf '      %s\n' "$wpath"
          done
    fi
  fi
done

echo
if [ -n "$want" ]; then
  [ "$interesting" -eq 0 ] && echo "no repo named '$want' under $ROOT"
else
  echo "$interesting of $total repo(s) need attention (off-default branch, uncommitted tracked work, extra worktree, or a live holder)."
  [ "$show_all" != true ] && echo "Run with --all to list every repo."
fi
echo "A claim is 'who was last seen here', not a lock. 'stale' means that session's transcript has been idle >10 min."
