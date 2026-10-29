#!/usr/bin/env bash
# PreToolUse hook (Bash/PowerShell): deny committing onto a pre-existing local hotfix
# branch that already carries unreviewed commits ahead of origin/master.
#
# Why this exists. Confirmed live 2026-08-05..07: a session cut local hotfix/128.0.1 in
# reports and cherry-picked two PROJ-15278 commits (sanctioned at the time), then
# aborted mid-flow to fight QA 500s -- branch left local, unpushed, repo left ON it. Two
# days later a different session (PROJ-15286) computed the same version number, found
# the repo already on a branch with exactly the name it wanted, committed on top, pushed
# and merged -- shipping the two stowaway 15278 commits to production inside a hotfix
# whose Jira version never mentioned them. The tell (a stash message naming the foreign
# HEAD) scrolled by in test output; nothing mechanical asked "what does this branch
# already carry?".
#
# Predicate: a `git commit` where the target repo's current branch is hotfix/* with NO
# upstream (never pushed -- once pushed, the cargo was shippable and review moves to the
# merge), and `origin/master..HEAD` contains at least one commit older than 2 hours.
# Fresh commits are this session's own work mid-flow; old ones are exactly the parked
# stowaways this gate exists to surface.
#
# Escape hatch: after REVIEWING the listed commits and deciding they are intended cargo,
# append "<repo-root>|<branch>|<HEAD-sha>" to ~/.claude/harness-state/tickets/.hotfix-stowaway-ack and retry.
# The ack pins the exact HEAD reviewed -- new stowaways re-trip it.
#
# Fails OPEN on anything it can't establish (no repo, no origin/master, unparseable).
set -u

IFS= read -r -d '' payload || true
case "$payload" in *git*commit*) ;; *) exit 0 ;; esac

command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' | tr -d '\r')"
[ -n "$command" ] || exit 0

# A real commit invocation, not prose mentioning one.
printf '%s' "$command" | grep -qE '(^|[;&|(]|&&)[[:space:]]*git([[:space:]]+-C[[:space:]]+("[^"]+"|'\''[^'\'']+'\''|[^[:space:]]+))?[[:space:]]+commit\b' || exit 0

# Repo dir: -C <path> wins, else a leading subshell cd, else the payload cwd.
dir="$(printf '%s' "$command" | grep -oE '\-C[[:space:]]+("[^"]+"|'\''[^'\'']+'\''|[^[:space:]]+)' | head -1 \
  | sed -E 's/^-C[[:space:]]+//; s/^["'\'']//; s/["'\'']$//')"
if [ -z "$dir" ]; then
  dir="$(printf '%s' "$command" | grep -oE 'cd[[:space:]]+("[^"]+"|'\''[^'\'']+'\''|[^[:space:]]+)' | head -1 \
    | sed -E 's/^cd[[:space:]]+//; s/^["'\'']//; s/["'\'']$//')"
fi
[ -n "$dir" ] || dir="$(printf '%s' "$payload" | jq -r '.cwd // empty' | tr -d '\r')"
[ -n "$dir" ] || exit 0
git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || exit 0

branch="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)"
case "$branch" in hotfix/*) ;; *) exit 0 ;; esac

# Upstream exists -> branch already pushed; its cargo is visible on the remote and the
# review point has moved past this gate.
git -C "$dir" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1 && exit 0

git -C "$dir" rev-parse --verify origin/master >/dev/null 2>&1 || exit 0

ahead="$(git -C "$dir" log origin/master..HEAD --format='%h %ct %s' 2>/dev/null)"
[ -n "$ahead" ] || exit 0

now="$(date +%s)"
stale=""
while IFS= read -r line; do
  ct="$(printf '%s' "$line" | awk '{print $2}')"
  case "$ct" in ''|*[!0-9]*) continue ;; esac
  if [ $((now - ct)) -gt 7200 ]; then
    stale="$stale$(printf '%s' "$line" | sed -E 's/^([0-9a-f]+) [0-9]+ /  \1  /')"$'\n'
  fi
done <<EOF
$ahead
EOF
[ -n "$stale" ] || exit 0

# Ack hatch: exact (repo-root, branch, HEAD) already reviewed this cargo.
root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)"
head_sha="$(git -C "$dir" rev-parse HEAD 2>/dev/null)"
. "$HOME/.claude/hooks/lib-claude-paths.sh"
ACK="$(hstate tickets .hotfix-stowaway-ack)"
if [ -f "$ACK" ] && [ -n "$root" ] && [ -n "$head_sha" ]; then
  grep -qxF "$root|$branch|$head_sha" "$ACK" 2>/dev/null && exit 0
fi

jq -cn --arg b "$branch" --arg s "$stale" --arg r "${root:-$dir}" --arg h "${head_sha:-?}" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: (
      "Branch " + $b + " already carries commits ahead of origin/master that predate this session'"'"'s work (never pushed, so never reviewed as cargo):\n"
      + $s
      + "\nA parked local hotfix branch is how PROJ-15278 commits shipped to production inside the unrelated hotfix/128.0.1 (2026-08-07). Before committing on top, decide what these commits are:\n"
      + "  - STOWAWAYS from an abandoned route -> do not build on this branch. Recreate it from origin/master (`git branch -m " + $b + " stowaway-backup && git checkout -b " + $b + " origin/master`) or rebase them away, then retry.\n"
      + "  - INTENDED cargo for THIS hotfix -> verify each commit'"'"'s ticket is (or will be) tagged to this hotfix version, then acknowledge and retry:\n"
      + "      echo \"" + $r + "|" + $b + "|" + $h + "\" >> ~/.claude/harness-state/tickets/.hotfix-stowaway-ack\n"
      + "The ack pins this exact HEAD -- new pre-existing commits re-trip the gate."
    )
  }
}'
