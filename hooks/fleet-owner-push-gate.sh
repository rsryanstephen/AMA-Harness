#!/usr/bin/env bash
# PreToolUse hook (Bash/PowerShell, dispatched). Denies `git push` to a protected branch
# (master, main, develop, release/*, hotfix/*) in a repo whose fleet the user does not own.
# User rule 2026-10-28: ETL changes need Reviewer One's approval, app changes need Your Name's -- both on a
# pull request. Owners: harness-config.json .fleetOwners (lib-fleet-owner.sh); rule:
# memory/fleet-owner-approval.md. A feature-branch push passes -- that is the PR route.
#
# Protected-target detection mirrors master-push-direct-gate.sh: explicit refspecs (dst side of
# src:dst, `+` and refs/heads/ stripped, so `:master` deletes count), --all/--mirror, or a bare
# push while a protected branch is checked out. Fails open on an unresolvable repo or no
# .fleetOwners. Hatch AMA_FLEET_OWNER_APPROVED=1 -- only after the OWNER's explicit OK for
# this specific push, quoted in the reply.
set -u

IFS= read -r -d '' payload || true
case "$payload" in
  *push*) ;;
  *) exit 0 ;;
esac
command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' | tr -d '\r' | tr '\n' ';')"
[ -n "$command" ] || exit 0
printf '%s' "$command" | grep -qP '(?:^|[;&|]|&&)\s*(?:\w+=\S*\s+)*git\s+(?:-C\s+(?:"[^"]+"|\S+)\s+)?push\b' || exit 0
case "$command" in *AMA_FLEET_OWNER_APPROVED=1*) exit 0 ;; esac
cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' | tr -d '\r')"
push_args="$(printf '%s' "$command" | grep -oP '(?:^|[;&|]|&&)\s*(?:\w+=\S*\s+)*git\s+(?:-C\s+(?:"[^"]+"|\S+)\s+)?push\s*\K[^&;|]*' | head -1)"

. "$HOME/.claude/hooks/lib-git-target.sh" 2>/dev/null || git_target_dir() { printf '%s' "$2"; }
repo="$(git_target_dir "$command" "$cwd")"
[ -n "$repo" ] && git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || exit 0

protected() { case "$1" in master|main|develop|release/*|hotfix/*) return 0 ;; esac; return 1; }
hit=""
remote_seen=0; refspecs=0; tags=0
set -f
# shellcheck disable=SC2086
for tok in $push_args; do
  case "$tok" in
    --all|--mirror) hit="$tok"; break ;;
    --tags) tags=1; continue ;;
    -*) continue ;;
  esac
  if [ "$remote_seen" = 0 ]; then remote_seen=1; continue; fi
  refspecs=1
  dst="${tok#+}"; dst="${dst##*:}"; dst="${dst#refs/heads/}"
  [ "$dst" = HEAD ] && dst="$(git -C "$repo" symbolic-ref --short -q HEAD 2>/dev/null)"
  protected "$dst" && { hit="$dst"; break; }
done
if [ -z "$hit" ] && [ "$refspecs" = 0 ] && [ "$tags" = 0 ]; then
  cur="$(git -C "$repo" symbolic-ref --short -q HEAD 2>/dev/null)"
  protected "$cur" && hit="$cur"
fi
[ -n "$hit" ] || exit 0

. "$(dirname "${BASH_SOURCE[0]}")/lib-fleet-owner.sh" 2>/dev/null || exit 0
owners="$(fleet_owners_required "$repo")"
[ -n "$owners" ] || exit 0
names="$(printf '%s\n' "$owners" | awk -F'\t' '{ printf "%s%s (%s fleet)", (NR > 1 ? ", " : ""), $2, $1 }')"
top="$(basename "$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)")"

jq -cn --arg r "$top" --arg b "$hit" --arg n "$names" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: ("Push to " + $b + " in " + $r + " denied: that repo is owned by " + $n + ", and changes there land only through a pull request the owner approves (user rule, memory/fleet-owner-approval.md; owners in harness-config.json .fleetOwners). Push a feature/PROJ-XXXXX-* branch instead and open the PR with create-bitbucket-pr.sh -- it adds the owner as reviewer, and its merge watcher merges only on the owner'"'"'s own approval. Only if the owner has explicitly OK'"'"'d this specific direct push: prefix AMA_FLEET_OWNER_APPROVED=1 and quote the OK in your reply.")
  }
}'
