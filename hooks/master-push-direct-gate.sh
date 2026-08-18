#!/usr/bin/env bash
# PreToolUse hook (Bash/PowerShell). Mechanically blocks pushing DIRECT commits to
# master on an AMA_APP repo -- master is the production branch fleet-wide, and every
# out-of-cycle production change must ride a hotfix/<version> branch (ama-hotfix:
# branch off master -> Staging auto-deploy -> verify -> --no-ff merge to master AND
# develop). Confirmed real: PROJ-15297's fix got cherry-picked straight onto
# master and pushed, bypassing the hotfix flow entirely -- required a revert + redo
# through hotfix/128.0.5. The "commit directly, no PRs" convention (solo repo) is
# about skipping pull requests, NOT about skipping the hotfix branch; this gate
# encodes that distinction mechanically, per CLAUDE.md's "Mechanical Triggers Over
# Self-Recognition" rule.
#
# Allowed through:
# - Pushes whose only outgoing master commits are merges plus commits already
#   reachable from a hotfix/* or release/* ref (local or origin) -- the legitimate
#   --no-ff hotfix/release merge shape.
# - Any repo under ~/.claude or named ama-claude-harness (the harness repo lives ON
#   master; gating it would block every harness commit).
# - Pushes that don't target master at all (pushing a hotfix branch while master is
#   checked out is fine).
#
# Heuristic, fails open on anything it can't confidently parse (same tradeoff as
# git-commit-scope-gate.sh): only catches an explicit master refspec in the push
# command, or a bare `git push` while master is checked out. Reads only local refs --
# no network calls in a hook -- so origin/master may be slightly stale; that skews
# toward extra denials only when master was pushed by someone else moments ago, which
# doesn't happen on a solo repo.
set -u

IFS= read -r -d '' payload || true
# Cheap raw-payload pre-filter before any jq/grep fork (precedent:
# aggregation-secret-gate.sh). Just "push", NOT "push"+"master" -- a bare `git push`
# while master is checked out carries no "master" text anywhere in the payload
# (caught live by the test matrix's bare-push case).
case "$payload" in *push*) ;; *) exit 0 ;; esac
command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"
[ -n "$command" ] || exit 0
cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty')"

# Flatten newlines to `;` and strip carriage returns before matching -- both are
# confirmed-live grep -P failure modes documented in git-commit-scope-gate.sh.
command="$(printf '%s' "$command" | tr -d '\r' | tr '\n' ';')"

# Capture a real `git push` invocation's argument text (anchored to a command
# position, not just the words appearing somewhere -- the quote-blind false-positive
# class git-commit-ticket-gate.sh documents).
push_args="$(printf '%s' "$command" | grep -oP '(?:^|[;&|]|&&)\s*git\s+(?:-C\s+(?:"[^"]+"|\S+)\s+)?push\s*\K[^&;|]*' | head -1)"
printf '%s' "$command" | grep -qP '(?:^|[;&|]|&&)\s*git\s+(?:-C\s+(?:"[^"]+"|\S+)\s+)?push\b' || exit 0

# Resolve the repo the push runs against: -C <path> wins, else the tool call's cwd.
repo="$(printf '%s' "$command" | grep -oP '(?:^|[;&|]|&&)\s*git\s+-C\s+\K(?:"[^"]+"|\S+)' | head -1 | sed -e 's/^"//' -e 's/"$//')"
[ -n "$repo" ] || repo="$cwd"
[ -n "$repo" ] || exit 0
git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || exit 0

# Harness exclusions: the harness repo lives on master by design, and ~/.claude's
# own repo does too.
toplevel="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || exit 0
case "$toplevel" in
  *ama-claude-harness*|*/.claude|*\\.claude) exit 0 ;;
esac

# Does this push target master? Either an explicit master refspec in the args, or a
# bare push (no refspec) while master is checked out.
targets_master=0
if printf '%s' "$push_args" | grep -qP '(^|\s|:)master(\s|$)'; then
  targets_master=1
elif ! printf '%s' "$push_args" | grep -qP '(^|\s)[^-][^ ]*\s+\S'; then
  # No "<remote> <refspec>" pair -- bare `git push` (or push with flags only):
  # current branch decides.
  branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  [ "$branch" = "master" ] && targets_master=1
fi
[ "$targets_master" = "1" ] || exit 0

# Outgoing commits: local master beyond origin/master. Fail open if either ref is
# missing (fresh clone shapes).
git -C "$repo" rev-parse --verify -q refs/heads/master >/dev/null || exit 0
git -C "$repo" rev-parse --verify -q refs/remotes/origin/master >/dev/null || exit 0

# Every outgoing NON-MERGE commit must be reachable from a hotfix/* or release/* ref
# -- that's what a legitimate --no-ff hotfix/release merge looks like from master's
# side. Direct commits (cherry-picks, reverts, ordinary work) are reachable from no
# such ref and get denied.
exclusions="$(git -C "$repo" for-each-ref --format='^%(refname)' \
  'refs/heads/hotfix/*' 'refs/heads/release/*' \
  'refs/remotes/origin/hotfix/*' 'refs/remotes/origin/release/*' 2>/dev/null)"
# shellcheck disable=SC2086
bad="$(git -C "$repo" rev-list --no-merges refs/remotes/origin/master..refs/heads/master $exclusions 2>/dev/null | head -5)"
[ -n "$bad" ] || exit 0

short="$(printf '%s' "$bad" | head -3 | cut -c1-8 | paste -sd', ' -)"
jq -cn --arg c "$short" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: ("Pushing DIRECT commits to master (" + $c + " ...) -- master is the production branch, and out-of-cycle production changes must ride a hotfix/<version> branch per the ama-hotfix skill: branch off master, push (auto-deploys Staging), verify, then --no-ff merge to master AND develop. The solo-repo \"commit directly, no PRs\" convention skips pull requests, not the hotfix flow -- this exact bypass already happened once (PROJ-15297) and needed a revert to fix. If the user has explicitly instructed a direct master push (e.g. history repair with git revert), ask them to confirm this specific push before proceeding.")
  }
}'
