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
#
# 2026-10-05: also checks every LIVE origin/release/* branch (tip <90 days) for missing master
# patches -- the hotfix -> release leg ama-hotfix requires, which had no mechanical backstop.
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

. "$HOME/.claude/hooks/lib-git-target.sh" 2>/dev/null || exit 0
git_push_rejected "$payload" && exit 0
target_dir="$(git_target_dir "$command" "$cwd")"
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
case "$stranded" in ''|*[!0-9]*) stranded=0 ;; esac

# Dead develop (2026-08-20 fleet sweep: common-models, common-mongo, exportproducer-messages,
# fieldtablemapper-client, mappingtool-web -- develop untouched since 2020-21, a pure stale
# ancestor of master): every master push would nag forever, and a usually-noise reminder gets
# ignored when real. Skip ONLY when BOTH hold -- zero develop-only patches AND develop's tip
# older than a year. The age half keeps a healthy repo that is merely even after a release.
if [ "$stranded" -gt 0 ]; then
  dev_only="$(git -C "$target_dir" cherry origin/master origin/develop 2>/dev/null | grep -c '^+' | tr -d ' ')"
  dev_age="$(git -C "$target_dir" log -1 --format=%ct origin/develop 2>/dev/null)"
  max_age="${BACKMERGE_DEAD_DEVELOP_SECS:-31536000}"
  if [ "${dev_only:-1}" = 0 ] && [ -n "$dev_age" ] && [ $(( $(date +%s) - dev_age )) -gt "$max_age" ]; then
    stranded=0
  fi
fi

# The THIRD target: a LIVE release/* branch, cut but not yet shipped. ama-hotfix says to merge
# a hotfix into it too, and nothing checked (2026-09-26): hotfix/129.0.17 never reached
# release/130.0.0, so Staging's release build rejected `Ends with` with a 500 that production
# had already fixed, and release regression tested a build missing a shipped hotfix. Same
# `git cherry` predicate per release branch. "Live" = tip within BACKMERGE_RELEASE_MAX_AGE_SECS
# (90 days): ama-deploy-release deletes a shipped branch, but a forgotten one must not nag
# every master push forever.
rel_lines=""
rel_max_age="${BACKMERGE_RELEASE_MAX_AGE_SECS:-7776000}"
now_s="$(date +%s)"
for rb in $(git -C "$target_dir" for-each-ref --format='%(refname:short)' 'refs/remotes/origin/release/*' 2>/dev/null); do
  rb_age="$(git -C "$target_dir" log -1 --format=%ct "$rb" 2>/dev/null)"
  [ -n "$rb_age" ] && [ $(( now_s - rb_age )) -gt "$rel_max_age" ] && continue
  rn="$(git -C "$target_dir" cherry "$rb" origin/master 2>/dev/null | grep -c '^+' | tr -d ' ')"
  case "$rn" in ''|0|*[!0-9]*) continue ;; esac
  rel_lines="${rel_lines}  ${rb}: ${rn} master patch(es) missing -- git -C ${target_dir} cherry -v ${rb} origin/master
"
done

[ "$stranded" -gt 0 ] || [ -n "$rel_lines" ] || exit 0

repo="$(basename "$target_dir")"

rel_text=""
if [ -n "$rel_lines" ]; then
  rel_text="

ALSO: a LIVE release/* branch is missing master patches. A hotfix that ships to production but not into the release being tested is UNDONE by that release (hotfix/129.0.17 vs release/130.0.0, 2026-09-26: Staging 500 on a bug production had fixed). Merge origin/master into each, build, push -- ama-hotfix \"A LIVE release/* branch needs the hotfix too\":
${rel_lines}"
fi

if [ "$stranded" -eq 0 ]; then
  jq -cn --arg r "$repo" --arg rt "$rel_text" '{decision: "block", reason: ("Just pushed to master in " + $r + ". develop is up to date, but:" + $rt)}'
  exit 0
fi

jq -cn --arg r "$repo" --arg d "$target_dir" --arg n "$stranded" --arg rt "$rel_text" '{
  decision: "block",
  reason: ("Just pushed to master in " + $r + ", and " + $n + " commit(s) on master have no equivalent patch on develop. Back-merge NOW, in this session -- do not defer it.\n\nSee exactly what is missing (the '+' lines):\n  git -C " + $d + " cherry -v origin/develop origin/master\n\n\nBack-merge is part of the push, not a later chore. Confirmed live 2026-08-18: hotfixes 128.0.1-128.0.7 each skipped this, and the drift only surfaced weeks later at a release wrap-up, when six repos had conflicting .csproj versions and one had a real semantic conflict nobody could still explain from memory.\n\n  git -C " + $d + " checkout develop && git -C " + $d + " pull --ff-only origin develop\n  git -C " + $d + " merge --no-ff origin/master\n\nConflicts: resolve them ON THE SPOT, now, while the reason for the change is still fresh -- that is the whole point of doing this at push time. Do NOT abort and leave it for later. Two rules that already have precedent:\n  - .csproj PackageReference conflicts -> take the LATEST version of each package, and confirm latest against CodeArtifact publish dates rather than assuming the higher version string is newer (the Bitbucket repo migration reset some build counters).\n  - A hotfix code conflict with develop -> master wins on the FIX BEHAVIOUR (that is what production runs), but NOT where the master shape is an artifact of the branch: master behind on a library major version (its back-ported call sites will not compile on develop), or master predating unrelated develop work (taking master deletes it). Either case -> do not encode the decision in the merge. Resolve EVERY conflict in develop favour, then assert `git diff origin/develop` is EMPTY -- that is an ancestry-only merge and the empty diff is the proof it changed no content -- and apply the intended change as a SEPARATE commit written against develop own dependencies.\nThen build + test before pushing develop.\n\nMERGE it, do NOT cherry-pick the same fix onto develop separately. A cherry-pick leaves two commits with different SHAs and identical content, so the branches never share ancestry for that work and EVERY later merge conflicts on those lines -- that is what produced release/129.0.0'"'"'s .csproj conflicts across six repos and the reports/UpdateUserReportService.cs semantic conflict nobody could still explain weeks later.\n\nIf this master push was a release or hotfix merge, this is ama-deploy-release Step 1 / ama-hotfix Step 4 -- the develop half of it." + $rt)
}'
