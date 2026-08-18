#!/usr/bin/env bash
# PostToolUse hook (Bash/PowerShell). Fires right after a push to `master` in a repo that
# also has a `develop`, when that pushed commit is NOT yet on develop -- i.e. the
# back-merge is outstanding.
#
# Why this exists. ama-hotfix Step 4 and ama-deploy-release Step 1 both say to merge to
# master AND develop, but nothing checked the develop half, and prose alone did not hold.
# Confirmed live 2026-08-18: hotfixes 128.0.1-128.0.7 went to master and production over
# several weeks and NONE were back-merged to develop. The drift only surfaced at the
# release/129.0.0 wrap-up, by which point six repos had conflicting .csproj library
# versions and `reports` had a real semantic conflict -- develop had dropped
# `report.Report = toUpdate;` that the hotfixes restored on master. Resolving that late
# means guessing at intent weeks after the fact; resolving it at back-merge time is
# trivial, because whoever wrote the fix still remembers why.
#
# Per CLAUDE.md's "Mechanical Triggers Over Self-Recognition" rule, an obligation that
# fires "after X happens" needs a hook, not a paragraph.
#
# Deliberately a reminder (decision:block -> Claude sees it), never a gate: the master
# push itself is correct and already done by the time this runs, and a production hotfix
# must never be blocked on a develop-branch chore.
#
# Fails open on anything it cannot resolve -- same tradeoff as git-push-ticket-reminder.sh.
set -u

IFS= read -r -d '' payload || true
# Cheap raw-payload pre-filter before any jq fork (precedent: aggregation-secret-gate.sh)
# -- the push-matching regex below requires the literal substring "push".
case "$payload" in *push*) ;; *) exit 0 ;; esac

command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"
cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty')"
[ -n "$command" ] || exit 0

# Anchored to a real command position, not just "the words appear somewhere" -- same
# false-positive class git-commit-ticket-gate.sh documents.
printf '%s' "$command" | grep -qP '(^|[;&|]|&&)\s*git\s+(-C\s+\S+\s+)?push\b' || exit 0

target_dir="$(printf '%s' "$command" | grep -oP -- '-C\s+"?\K[^"[:space:]]+' | head -1)"
[ -z "$target_dir" ] && target_dir="$(printf '%s' "$command" | grep -oP '^\s*cd\s+"?\K[^"[:space:];&]+' | head -1)"
[ -z "$target_dir" ] && target_dir="$cwd"
# An extracted `~/...` / literal `$HOME/...` is just text from grep, never shell-expanded
# -- git -C doesn't expand it either, so it silently fails. Same fix as
# git-push-ticket-reminder.sh.
target_dir="${target_dir/#\~/$HOME}"
target_dir="${target_dir/#\$HOME/$HOME}"
[ -n "$target_dir" ] || exit 0

branch="$(git -C "$target_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)"
[ "$branch" = "master" ] || exit 0

# No develop branch -> not a gitflow repo (ama-claude-harness itself is master-only).
git -C "$target_dir" rev-parse --verify -q origin/develop >/dev/null 2>&1 || exit 0

# `git cherry` is the predicate, and getting here took two wrong answers -- both worth
# recording, because each looked obviously right.
#
# WRONG #1, branch ancestry (`merge-base --is-ancestor HEAD origin/develop`):
# ama-deploy-release Step 1 deliberately sources BOTH merges from the release branch
# ("not chained through master"), so after a normal release master's own merge commit is
# never an ancestor of develop even though every line already landed there. Fires forever
# on healthy repos -- 7 of the 17 release/129.0.0 repos sat in exactly that state.
#
# WRONG #2, counting non-merge commits in origin/develop..origin/master:
# a fix committed on a release branch and separately CHERRY-PICKED onto develop exists as
# two commits with different SHAs and identical content. A commit count sees the master
# copy as missing. Confirmed live 2026-08-18: all 10 exporterplus commits flagged this way
# were already on develop with byte-identical patches (`git patch-id --stable` matched
# exactly), and the back-merges pushed for export/feedback/querybuilder produced empty
# file diffs for the same reason.
#
# `git cherry <upstream> <head>` compares PATCH IDs, not SHAs: '-' means an equivalent
# patch is already downstream, '+' means genuinely absent. That is the actual question,
# and it is immune to both failure modes above.
#
# NOTE: reads local refs without fetching, deliberately -- a hook must not add a network
# round-trip to every push. A stale origin/develop can only produce a spurious reminder
# (cheap), never a missed one, since a stale ref is behind, not ahead.
stranded="$(git -C "$target_dir" cherry origin/develop origin/master 2>/dev/null | grep -c '^+' | tr -d ' ')"
case "$stranded" in ''|0|*[!0-9]*) exit 0 ;; esac

repo="$(basename "$target_dir")"

jq -cn --arg r "$repo" --arg d "$target_dir" --arg n "$stranded" '{
  decision: "block",
  reason: ("Just pushed to master in " + $r + ", and " + $n + " commit(s) on master have no equivalent patch on develop. Back-merge NOW, in this session -- do not defer it.\n\nSee exactly what is missing (the '+' lines):\n  git -C " + $d + " cherry -v origin/develop origin/master\n\n\nBack-merge is part of the push, not a later chore. Confirmed live 2026-08-18: hotfixes 128.0.1-128.0.7 each skipped this, and the drift only surfaced weeks later at a release wrap-up, when six repos had conflicting .csproj versions and one had a real semantic conflict nobody could still explain from memory.\n\n  git -C " + $d + " checkout develop && git -C " + $d + " pull --ff-only origin develop\n  git -C " + $d + " merge --no-ff origin/master\n\nConflicts: resolve them ON THE SPOT, now, while the reason for the change is still fresh -- that is the whole point of doing this at push time. Do NOT abort and leave it for later. Two rules that already have precedent:\n  - .csproj PackageReference conflicts -> take the LATEST version of each package, and confirm latest against CodeArtifact publish dates rather than assuming the higher version string is newer (the Bitbucket repo migration reset some build counters).\n  - A hotfix'"'"'s own code conflicting with develop -> master wins; the hotfix is what production is actually running.\nThen build + test before pushing develop.\n\nMERGE it, do NOT cherry-pick the same fix onto develop separately. A cherry-pick leaves two commits with different SHAs and identical content, so the branches never share ancestry for that work and EVERY later merge conflicts on those lines -- that is what produced release/129.0.0'"'"'s .csproj conflicts across six repos and the reports/UpdateUserReportService.cs semantic conflict nobody could still explain weeks later.\n\nIf this master push was a release or hotfix merge, this is ama-deploy-release Step 1 / ama-hotfix Step 4 -- the develop half of it.")
}'
