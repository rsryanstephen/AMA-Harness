#!/usr/bin/env bash
# PostToolUse hook (Bash/PowerShell): after a `git commit`, check the ticket that commit
# names. Two things go wrong at exactly this moment, and both were invisible until a
# release wrap-up weeks later.
#
# 1. THE TICKET IS STILL "Open". commit-ticket-jira says a ticket moves to In Progress the
#    moment Claude takes ownership, and to Ready to Test / Test Complete once it lands on
#    a release branch. Nothing enforced either. Confirmed live 2026-08-18: PROJ-15268
#    and -15269 were committed, merged, released and deployed to production while sitting
#    at Open, AND were simultaneously listed on the AMA Backlog page as unstarted work
#    anyone picking up the backlog would have redone. ama-deploy-release Step 7a's sweep
#    could not catch them either, because a ticket worked straight from Open never enters
#    the columns that sweep queries. Widening the sweep treats the symptom; this is the
#    cause - work landed and the ticket never moved.
#
# 2. A COMMIT ON A release/* OR hotfix/* BRANCH WHOSE TICKET ISN'T TAGGED FOR IT.
#    commit-ticket-jira already requires the Fix Version to match the branch you commit onto,
#    so the release actually contains what its ticket list claims. Also unenforced.
#
# Fires on the COMMIT, not the push: the commit is when the ticket demonstrably started
# being worked, and it is the earliest point where both facts are knowable.
#
# Reads the real HEAD commit rather than parsing the command, so it covers every commit
# shape -- `-m`, `-F file`, heredoc, `--amend`. git-commit-ticket-gate.sh can only inspect
# the forms it can parse out of the command text and fails open on the rest; this one
# cannot miss a shape.
#
# Reminder, never a gate: the commit already exists by the time this runs, and Jira
# bookkeeping must never be able to block committing. Fails open on no token, no network,
# or an unparseable response.
set -u

IFS= read -r -d '' payload || true
case "$payload" in *commit*) ;; *) exit 0 ;; esac

command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' | tr -d '\r')"
cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty')"
[ -n "$command" ] || exit 0

printf '%s' "$command" | grep -qP '(^|[;&|]|&&)\s*git\s+(-C\s+\S+\s+)?commit\b' || exit 0

. "$HOME/.claude/hooks/lib-git-target.sh" 2>/dev/null || exit 0
target_dir="$(git_target_dir "$command" "$cwd")"
[ -n "$target_dir" ] || exit 0

# A path held in a shell variable (`git -C "$W" commit`) cannot be expanded here, and the cwd
# fallback is the MAIN clone -- whose HEAD is another worktree's, often another session's,
# commit. 2026-09-26: a worktree commit of PROJ-15416 was reported as "Just committed
# PROJ-15411 (branch: hotfix/129.0.20)" with an instruction to tag THAT ticket. Never
# name a ticket read from a guessed repo; remind generically instead.
if git_target_unresolved "$command"; then
  jq -cn '{decision: "block", reason: "Just committed, but the repo path in this command sits in a shell variable this hook cannot expand -- so it will NOT read HEAD from the session cwd (the main clone, whose HEAD may be another worktree'"'"'s or another session'"'"'s commit; on 2026-09-26 that named the wrong ticket). Do the bookkeeping yourself for the ticket in the commit you just made: In Progress if it was Open/To Do, and the branch'"'"'s Fix Version if this was a release/* or hotfix/* commit. Next time pass the path literally (`git -C C:/... commit`) so the hook can check for you."}'
  exit 0
fi

subject="$(git -C "$target_dir" log -1 --pretty=%s 2>/dev/null)"
[ -n "$subject" ] || exit 0
ticket="$(printf '%s' "$subject" | grep -oP '^[A-Z]+-\d+' | head -1)"
[ -n "$ticket" ] || exit 0

CONFIG="$HOME/.claude/harness-config.json"
[ -f "$CONFIG" ] || exit 0
email="$(jq -r '.user.email // empty' "$CONFIG" 2>/dev/null | tr -d '\r')"
host="$(jq -r '.atlassian.cloudId // "yourorg.atlassian.net"' "$CONFIG" 2>/dev/null | tr -d '\r')"
harness_epic="$(jq -r '.atlassian.harnessEpicKey // "<harnessEpicKey>"' "$CONFIG" 2>/dev/null | tr -d '\r')"
regressions="$(jq -r '.atlassian.regressionsTicketKey // empty' "$CONFIG" 2>/dev/null | tr -d '\r')"
[ -n "$email" ] || exit 0
[ -n "${ATLASSIAN_API_TOKEN:-}" ] || exit 0

# Both of these are documented never-transition tickets. The Regressions ticket is
# deliberately parked at Open (so it stays out of the pickup queries), so without this
# exemption every regression fix would trip the Open check by design.
[ "$ticket" != "$harness_epic" ] || exit 0
[ -n "$regressions" ] && [ "$ticket" = "$regressions" ] && exit 0

issue="$(curl -sS --max-time 8 -u "$email:$ATLASSIAN_API_TOKEN" \
  "https://$host/rest/api/3/issue/$ticket?fields=status,fixVersions" 2>/dev/null)"
[ -n "$issue" ] || exit 0
status="$(printf '%s' "$issue" | jq -r '.fields.status.name // empty' 2>/dev/null)"
[ -n "$status" ] || exit 0

branch="$(git -C "$target_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)"
versions="$(printf '%s' "$issue" | jq -r '[.fields.fixVersions[]?.name] | join(", ")' 2>/dev/null)"

problems=""
case "$status" in
  Open|"To Do")
    problems="$problems- $ticket is still \"$status\" but a commit for it just landed. Move it to In Progress NOW (commit-ticket-jira: a ticket moves to In Progress the moment ownership starts). Left at Open it ships invisibly: PROJ-15268 and -15269 reached production at Open while still listed on the AMA Backlog as unstarted work, and Step 7a's sweep could not see them.\n"
    ;;
esac

case "$branch" in
  release/*|hotfix/*)
    case ",$versions," in
      *",$branch,"*) ;;
      *)
        problems="$problems- $ticket's Fix Version does not include \"$branch\" (currently: ${versions:-none}). A commit made directly onto a release/hotfix branch needs that branch tagged, or the release's own ticket list will not contain what the release actually ships. Add it alongside any existing version, do not replace.\n"
        ;;
    esac
    ;;
esac

[ -n "$problems" ] || exit 0

jq -cn --arg t "$ticket" --arg s "$status" --arg b "$branch" --arg p "$problems" '{
  decision: "block",
  reason: ("Just committed " + $t + " (status: " + $s + ", branch: " + $b + ") -- fix the ticket bookkeeping now, while it is one API call:\n\n" + $p + "\nUse jira-get-transitions.sh first (ids differ per ticket); from Open the hops are usually Open -> To Do -> In Progress. This hook reads the real HEAD commit, so it sees every commit shape -- it cannot be sidestepped by using -F instead of -m.")
}'
