#!/usr/bin/env bash
# PostToolUse hook (Bash/PowerShell). Nudges Claude to check/transition the session's
# resolved ticket right after a push to a branch that implies a status change --
# PROJ-15231 was fixed and deployed but its ticket sat stale, nothing prompted the
# transition. THIS hook doesn't read Jira, but that's a choice, not a limit -- a hook CAN
# (ATLASSIAN_API_TOKEN + harness-config.json's .atlassian.cloudId/.user.email; working
# precedent: ready-to-test-regression-reminder.sh's ready_to_test()). Here the target status
# comes from the pushed BRANCH, which needs no API call. No de-dupe: fires on every matching push, same
# philosophy as on-prompt.sh's queued-item reminder.
set -u

IFS= read -r -d '' payload || true
# Cheap raw-payload pre-filter before any jq fork (precedent:
# aggregation-secret-gate.sh) -- the push-matching regex below requires the literal
# substring "push", so a payload without it can exit on zero forks. ~60ms/fork.
case "$payload" in *push*) ;; *) exit 0 ;; esac
command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"
cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty')"
sid="$(printf '%s' "$payload" | jq -r '.session_id // empty')"

[ -n "$command" ] || exit 0
[ -n "$sid" ] || exit 0

printf '%s' "$command" | grep -qP '(^|[;&|]|&&)\s*git\s+(-C\s+\S+\s+)?push\b' || exit 0

# A branch DELETION is not a content push. `git push origin --delete <branch>` (and the
# `:<branch>` refspec form) ships no commits, so there is nothing to deploy and no ticket to
# move -- but the branch parsing below still reads the deleted name as the destination and
# then lists whatever tickets its last few commits mention. Confirmed live on the
# hotfix/129.0.17 cleanup: four deletions, each naming a different unrelated ticket trio
# (15411/15355/15226, 14948/14757/15261, 14800/15406) purely from log archaeology.
printf '%s' "$command" | grep -qE '(^|[[:space:]])--delete([[:space:]]|$)' && exit 0
printf '%s' "$command" | grep -qE 'push[^;&|]*[[:space:]]:[^[:space:];&|]+' && exit 0

. "$HOME/.claude/hooks/lib-git-target.sh" 2>/dev/null || exit 0
git_push_rejected "$payload" && exit 0
target_dir="$(git_target_dir "$command" "$cwd")"
[ -n "$target_dir" ] || exit 0
# ...and ANY other shell variable defeats it the same way. Claude routinely holds the repo
# path in a local (`W="C:/.../search-develop"; git -C "$W" push ...`) because
# bare-cd-gate.sh pushes it away from `cd`, so grep yields the literal `$W`, git -C fails,
# branch comes back empty, and this hook exits silent -- PROJ-15226 was pushed to
# develop and left at In Progress for exactly this reason (2026-09-14). An unexpandable
# path is no reason to go quiet: fall back to the session cwd rather than exiting.
# Predicate, not the lib's variable: that is set inside the `$(...)` above and never reaches
# this shell (2026-10-05) -- this line had read empty since the lib existed.
repo_unresolved=""; git_target_unresolved "$command" && repo_unresolved=1
if ! git -C "$target_dir" rev-parse --git-dir >/dev/null 2>&1; then
  target_dir="$cwd"; repo_unresolved=1
fi
[ -n "$target_dir" ] || exit 0

# An explicit refspec destination is what the push actually MOVED -- trust it over the
# checked-out branch, which differs whenever the push is `HEAD:develop` from a worktree, a
# detached head, or a repo left on another branch. Walk the words after `push`, skipping
# flags: first bare word is the remote, second is the refspec, and the destination is
# whatever follows the last colon (`HEAD:develop` -> develop, `develop` -> develop).
# Falls back to the checked-out branch for a bare `git push`.
push_args="$(printf '%s' "$command" | sed -n 's/.*[[:space:]]push\([[:space:]].*\)$/\1/p' | sed 's/[;&|].*//')"
remote=""; refspec=""
for tok in $push_args; do
  tok="${tok%\"}"; tok="${tok#\"}"; tok="${tok%\'}"; tok="${tok#\'}"
  case "$tok" in -*) continue ;; esac
  if [ -z "$remote" ]; then remote="$tok"; else refspec="$tok"; break; fi
done
branch=""
[ -n "$refspec" ] && branch="${refspec##*:}"
[ -n "$branch" ] || branch="$(git -C "$target_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)"
[ -n "$branch" ] || exit 0

status=""
case "$branch" in
  master) status="Test Complete" ;;
  develop) status="QA" ;;
  release/*|hotfix/*) status="__conditional__" ;;
  *) exit 0 ;;
esac

# The session ticket is a FALLBACK, never a precondition. It used to be
# `[ -f "$TF" ] || exit 0`, which silently disabled this whole hook whenever
# set-session-ticket.sh hadn't run yet -- and it routinely hasn't, because that script
# resolves the session by CHAT FILENAME and Claude Code auto-renames the chat log
# mid-session, so the first call fails and gets retried late (PROJ-15330: the .ticket
# file landed 14:23, every one of the nine pushes was 13:48-14:14, the nudge never fired
# once, the ticket sat In Progress for two days). The tickets that actually get named below
# come from the pushed COMMIT SUBJECTS, which are always present on a push this hook cares
# about -- so the file being absent is no reason to stay quiet.
TF="$HOME/.claude/.session-chatfiles/$sid.ticket"
ticket=""
[ -f "$TF" ] && ticket="$(cat "$TF")"

# Harness work (commits against the harness epic directly, per commit-ticket's
# "Harness work" section) has no ticket lifecycle at all -- a status-transition
# reminder here would be actively wrong (ama-claude-harness pushes straight to
# master, which would otherwise read as "move to Test Complete").
harness_epic="<harnessEpicKey>"
CONFIG="$HOME/.claude/harness-config.json"
[ -f "$CONFIG" ] && harness_epic="$(jq -r '.atlassian.harnessEpicKey // "<harnessEpicKey>"' "$CONFIG" 2>/dev/null | sed 's/\r$//')"
[ -n "$harness_epic" ] || harness_epic="<harnessEpicKey>"
if [ -n "$ticket" ] && [ "$ticket" = "$harness_epic" ]; then exit 0; fi
# The session ticket is not the whole story: a harness commit made DURING a product-ticket
# session leaves $ticket at the product key, so the check above passes and the nudge fires
# on a harness push anyway (seen live 2026-08-18: session ticket PROJ-15307, commit
# <harnessEpicKey>, nudge said to move 15307 to Test Complete -- it was mid-investigation).
# The pushed commit's own ref is the authority on what was actually pushed.
# Skipped when the pushed repo could not be resolved -- target_dir is then some other
# repo's checkout, and its last commit says nothing about what this push carried.
if [ -z "$repo_unresolved" ]; then
  pushed_ticket="$(git -C "$target_dir" log -1 --pretty=%s 2>/dev/null | grep -oP 'PROJ-\d+' | head -1)"
  [ "$pushed_ticket" != "$harness_epic" ] || exit 0
else
  # Unresolvable -C path, so target_dir is the session cwd. If THAT repo's newest commit is
  # harness work, this push almost certainly was too -- and the fallback below would name
  # the SESSION ticket, i.e. tell the agent to move a product ticket sitting in QA to Test
  # Complete on the strength of a harness push (PROJ-15430, 2026-09-18). Stay silent.
  cwd_ticket="$(git -C "$target_dir" log -1 --pretty=%s 2>/dev/null | grep -oP 'PROJ-\d+' | head -1)"
  [ -n "$cwd_ticket" ] && [ "$cwd_ticket" = "$harness_epic" ] && exit 0
  # ...and an EMPTY cwd_ticket is not permission to guess either: the cwd is not a git repo
  # (or has no commits), so nothing here says what the push carried, and the fallback below
  # would name the SESSION ticket. That is 15430 again through a different door -- reproduced
  # 2026-09-21 with `git -C "$H" push origin master`, where the -C path is a shell variable
  # the hook cannot resolve: a harness-epic push told the agent to move PROJ-15263, a
  # product ticket sitting in QA, to Test Complete. Silence is the only safe answer with no
  # evidence; a real product push from a real repo cwd still resolves and still nudges.
  [ -n "$cwd_ticket" ] || exit 0
fi

# Nudge the tickets actually IN the push, not the session ticket (2026-08-20: pushed 15330's
# commit, nudge said "move 15317" -- the session ticket, absent from that push). Enumerate
# every key in the commits the push moved (`@{1}` = the pre-push upstream via the remote-ref
# reflog; fall back to the last 20 subjects when there is no reflog entry yet). Session ticket
# only when the pushed commits name none. Harness-epic-only pushes stay silent.
# An unresolved -C path reaching this line has passed the vetting above: the cwd IS a repo
# and its newest commit is product work, so its subjects are the best evidence there is
# (PROJ-15226 shape: `W="<repo>"; git -C "$W" push` from that very repo). Until
# 2026-10-05 $repo_unresolved was never actually set (lib-git-target.sh header), so this
# branch had always enumerated the cwd -- the pinned, correct behaviour; the dead
# "session ticket only" arm that would have gone silent here was removed.
tickets="$(git -C "$target_dir" log --pretty=%s "origin/$branch@{1}..HEAD" 2>/dev/null \
  | grep -oP 'PROJ-\d+' | grep -vxF "$harness_epic" | awk '!s[$0]++')"
[ -n "$tickets" ] || tickets="$(git -C "$target_dir" log -20 --pretty=%s 2>/dev/null \
  | grep -oP 'PROJ-\d+' | grep -vxF "$harness_epic" | awk '!s[$0]++' | head -3)"
[ -n "$tickets" ] || tickets="$ticket"
# Status-aware (2026-09-18): a ticket already AT or PAST the branch's target gets no nudge.
# Branch-only inference nagged "hop PROJ-15411 through Review -> QA -> Ready to Test"
# on a release-branch pin bump when 15411 had been Ready to Test (09-15), Test Complete by
# the tester (09-17) and Done via Deployed Prod (09-18) -- every hoop already cleared. Same
# lib + fail-OPEN as ticket-in-progress-reminder.sh: empty/unknown status keeps the nudge.
# Rank order is the board's forward path; anything terminal ranks past every target.
# Trade-off: a skipped ticket also loses the Fix-Version reminder below --
# ticket-worked-while-open-gate.sh already enforces that at commit time.
. "$HOME/.claude/hooks/lib-jira-status.sh" 2>/dev/null || jira_status() { :; }
status_rank() {
  case "$1" in
    "To Do") echo 0 ;; "In Progress") echo 1 ;; Review) echo 2 ;; QA) echo 3 ;;
    "Ready to Test") echo 4 ;; "Test Complete") echo 5 ;;
    Done|Closed|Canceled|Cancelled) echo 9 ;; *) echo "" ;;
  esac
}
case "$status" in QA) target_rank=3 ;; "Test Complete") target_rank=5 ;; *) target_rank=4 ;; esac
kept=""
for k in $tickets; do
  rank="$(status_rank "$(jira_status "$k")")"
  if [ -n "$rank" ] && [ "$rank" -ge "$target_rank" ]; then continue; fi
  kept="${kept}${k}
"
done
tickets="$kept"

ticket="$(printf '%s' "$tickets" | tr '\n' ' ')"; ticket="${ticket% }"
# Neither the pushed commits nor the (now-optional) session ticket named a key -- or every
# named ticket is already at/past target -- nothing to nudge about, so stay silent rather
# than emitting a reason with an empty ticket in it.
[ -n "$ticket" ] || exit 0
case "$ticket" in *" "*) many=" (several tickets in this push -- each one separately, and ONLY a ticket whose work is fully delivered by this push moves; partial work stays where it is)" ;; *) many="" ;; esac

if [ "$status" = "__conditional__" ]; then
  jq -cn --arg t "$ticket$many" --arg b "$branch" '{decision:"block", reason:("Just pushed to " + $b + " -- release/hotfix branch. Watch for this Staging deploy to land stable and follow up AUTOMATICALLY, do not wait to be asked -- ticket bookkeeping, not a deploy action. Once stable: board blocks a direct In Progress -> Ready to Test/Test Complete hop -- hop " + $t + " through Review -> QA first (confirm each hop via getTransitionsForJiraIssue, do not assume). Then route on BLAST RADIUS, not on UI-testability: could anything downstream of the change break? If yes -> transition to Ready to Test (a distinct status, id 10171, NOT the QA status id 10121 despite similar wording) + TWO comments, step-by-step testing steps AND a SEPARATE regression-steps comment (investigate the diff'"'"'s blast radius and exercise the affected surfaces first). Not easily UI-testable is NOT a reason to skip Ready to Test -- the steps just become a log/DB/API check. Only a change with nothing downstream of it -> Test Complete. See ama-hotfix Step 2a and memory/ready-to-test-regression-comment.md. Also confirm " + $t + "'"'"'s Fix Version includes \"" + $b + "\" (exact match) -- a fix committed straight onto an already-cut release/hotfix branch needs the same tag Step 3a gives tickets included at cut time; editJiraIssue now if it'"'"'s missing.")}'
else
  jq -cn --arg t "$ticket$many" --arg b "$branch" --arg s "$status" '{decision:"block", reason:("Just pushed to " + $b + " -- per commit-ticket-jira'"'"'s Ticket status transitions table, " + $t + " should move to " + $s + " if it hasn'"'"'t already AND the ticket'"'"'s work is fully delivered by this push (partial work on a still-In-Progress ticket does not move). Check its current status and transition it now.")}'
fi
