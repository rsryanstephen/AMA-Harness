#!/usr/bin/env bash
# PreToolUse (Bash|PowerShell). Denies `git cherry-pick` onto develop of a commit that lives
# on a release/* or hotfix/* branch.
#
# AGENTS.md's rule: fixes on a live release/hotfix branch reach develop through the MERGE,
# never a parallel cherry-pick -- the pick severs shared ancestry and every later merge
# conflicts. Priced already: release/129.0.0's six-repo `.csproj` conflict set. It was a
# prose rule with a trivially decidable predicate and no hook (2026-09-15 audit).
#
# Fails OPEN on anything it cannot parse -- a blocked cherry-pick is reversible, a wrong
# denial here only costs a re-run with the hatch, and the predicate needs a real repo to
# answer. Hatch: AMA_ALLOW_CHERRY_PICK=1 in the command (user's call, say why in the commit).
set -u
payload="$(cat)"
case "$payload" in *cherry-pick*) ;; *) exit 0 ;; esac
command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null | tr -d '\r')"
cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)"
[ -n "$command" ] || exit 0
case "$command" in *AMA_ALLOW_CHERRY_PICK=1*) exit 0 ;; esac

. "$HOME/.claude/hooks/lib-command-text.sh" 2>/dev/null || exit 0
. "$HOME/.claude/hooks/lib-git-target.sh" 2>/dev/null || exit 0
region="$(printf '%s' "$command" | command_text_stripped)"
printf '%s' "$region" | grep -qP '(^|[;&|]|&&)\s*git\s+(-C\s+\S+\s+)?cherry-pick\b' || exit 0

# First non-flag argument after cherry-pick is the commit-ish (ranges A..B take the end).
ref="$(printf '%s' "$region" | grep -oP 'cherry-pick\s+\K.*' | tr ' ' '\n' | grep -v '^-' | head -1)"
ref="${ref##*..}"
[ -n "$ref" ] || exit 0

dir="$(git_target_dir "$command" "$cwd")"
branch="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)" || exit 0
[ "$branch" = "develop" ] || exit 0
sha="$(git -C "$dir" rev-parse --verify -q "$ref^{commit}" 2>/dev/null)" || exit 0

for r in $(git -C "$dir" for-each-ref --format='%(refname)' 'refs/remotes/origin/release/*' 'refs/remotes/origin/hotfix/*' 'refs/heads/release/*' 'refs/heads/hotfix/*' 2>/dev/null); do
  if git -C "$dir" merge-base --is-ancestor "$sha" "$r" 2>/dev/null; then
    jq -cn --arg r "${r#refs/remotes/origin/}" --arg s "${sha:0:10}" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",
      permissionDecisionReason:("Cherry-picking " + $s + " onto develop -- that commit lives on " + ($r|sub("^refs/heads/";"")) + ". Fixes on a live release/hotfix branch reach develop through the MERGE of that branch, never a parallel cherry-pick: the pick severs shared ancestry and every later merge conflicts (release/129.0.0 cost six repos of .csproj conflicts this way). Merge the branch instead (develop-backmerge-reminder.sh covers the how). If the user has explicitly asked for a cherry-pick anyway, re-run with AMA_ALLOW_CHERRY_PICK=1 and say why in the commit message.")}}'
    exit 0
  fi
done
exit 0
