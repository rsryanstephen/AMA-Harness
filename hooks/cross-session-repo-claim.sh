#!/usr/bin/env bash
# Two wirings, one file (the octopus-lambda-delete-gate.sh shape):
#   PostToolUse (Bash|PowerShell) --record  -- remember which branch this session left a repo on
#   PreToolUse  (Bash|PowerShell)           -- WARN when that collides with another live session
#
# TWO CHECKS in the PreToolUse half, deliberately in this one file rather than a second hook
# (the subagent-model-tiering-gate.sh precedent): the BRANCH collision below, and -- added
# 2026-09-01, PROJ-15368 -- a FILE collision at commit time, read out of the ledger
# file-claim-record.sh writes. A separate hook would pay another fork on every Bash call, and
# this one is already wired, already prefiltered on *git*, and already sources liveness.
#
# Why the file check fires at COMMIT and not at edit time: the raw collision rate is ~150
# same-file/different-session pairs a week and almost all are harmless, so warning per edit
# would be 150 interruptions for the two occurrences that actually hurt. Both of those were
# commits -- one session's uncommitted work swept into another's commit under an unrelated
# message, twice on 2026-09-01. See lib-file-claims.sh's header.
#
# Why. Every session shares ONE local clone per repo, so `git checkout` is global state:
# whichever session switches last wins, silently, for everyone else. Nothing in the harness
# knew another session existed. Confirmed live 2026-08-18: two sessions worked in the same
# clone root two minutes apart (export 15:29 develop->hotfix/129.0.3, exporterplus 15:31
# hotfix/129.0.2->master). Different repos, so nothing broke -- that is the near-miss
# window, not a safety margin. Separately, session 431272bb recorded "exporterplus is owned
# by another agent, that branch checked out in the shared local clone" in a plan file, which
# was true when written and false an hour later; 9 of 58 plan files carry a claim like that.
#
# WARNS, NEVER DENIES -- explicit user decision. A stale claim must never be able to wedge
# an urgent hotfix. PreToolUse warn shape is permissionDecision:"allow" WITH a reason (the
# chrome-verify-nudge.sh pattern); a deny here would be the wrong strength.
#
# Deliberately not a lock/lease: locks need releasing, and this harness has no reliable
# session end (nothing cleans .session-chatfiles/), so a lease would strand repos forever.
# A claim plus a liveness test degrades safely -- worst case, one missed warning.
#
# Fails open everywhere. Never the reason a git command cannot run.
set -u

MODE="${1:-gate}"
HERE="$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=lib-repo-claims.sh
. "$HERE/lib-repo-claims.sh" 2>/dev/null || exit 0
# shellcheck source=lib-session-liveness.sh
. "$HERE/lib-session-liveness.sh" 2>/dev/null || exit 0

IFS= read -r -d '' payload || true
case "$payload" in *git*) ;; *) exit 0 ;; esac

command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null | tr -d '\r')"
cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)"
sid="$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)"
[ -n "$command" ] && [ -n "$sid" ] || exit 0

# Resolve the command's REAL target dir, not the session cwd -- `git -C <path>` against a
# different repo is the common shape here, and using cwd would attribute it to the wrong
# repo entirely (the exact bug git-commit-ticket-gate.sh's header documents).
. "$HOME/.claude/hooks/lib-git-target.sh" 2>/dev/null || exit 0
target_dir="$(git_target_dir "$command" "$cwd")"
[ -n "$target_dir" ] || exit 0

root="$(claims_repo_root "$target_dir")"
[ -n "$root" ] || exit 0

# Single emitter -- the file check can exit early, and two copies of this jq drifted apart
# in an earlier version of this hook.
emit_warn() {
  jq -cn --arg r "$warn" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "allow",
      permissionDecisionReason: $r
    }
  }'
}

is_git_cmd() { printf '%s' "$command" | grep -qP "(^|[;&|]|&&)\s*git\s+(-C\s+\S+\s+)?$1\b"; }

# --- PostToolUse: record where this session left the repo -----------------------------
if [ "$MODE" = "--record" ]; then
  if is_git_cmd 'checkout' || is_git_cmd 'switch' || is_git_cmd 'commit' || is_git_cmd 'push'; then
    branch="$(git -C "$target_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    [ -n "$branch" ] && claims_put "$root" "$sid" "$branch"
  fi
  exit 0
fi

# --- PreToolUse: warn ------------------------------------------------------------------
warn=""

# Check 2 of 2: FILE collisions at commit time. Runs before the repo-claim early-exit below,
# because a file collision is real whether or not anyone recorded a branch claim.
if is_git_cmd 'commit' || printf '%s' "$command" | grep -qP "(^|[;&|]|&&)\s*git\s+(-C\s+\S+\s+)?add\s+(-A\b|--all\b|\.(\s|$))"; then
  # Sourced HERE, not at the top: the common case is a git command that is not a commit, and
  # this file is read on every Bash call that mentions git.
  [ -n "${FCLAIMS_FILE:-}" ] && FCLAIMS_FILE_WAS_SET=1
  if . "$HERE/lib-file-claims.sh" 2>/dev/null; then
    # One `git status` fork, paid only on commit/add-all. Porcelain v1: XY then the path.
    fc_hits=""; fc_n=0
    while IFS= read -r st_line; do
      rel="${st_line:3}"
      # Rename/copy entries read "old -> new"; the new path is the one being committed.
      case "$rel" in *' -> '*) rel="${rel##* -> }" ;; esac
      rel="${rel%\"}"; rel="${rel#\"}"
      [ -n "$rel" ] || continue
      while IFS=$'	' read -r o_sid o_ts; do
        [ -n "$o_sid" ] || continue
        session_is_live "$o_sid" || continue
        fc_n=$(( fc_n + 1 ))
        [ "$fc_n" -le 5 ] && fc_hits="${fc_hits:+$fc_hits
}  - $rel (session ${o_sid%%-*}, $(claims_describe_age "$o_ts") ago)"
      done <<FCEOF
$(fclaims_others "$root/$rel" "$sid")
FCEOF
    done <<STEOF
$(git -C "$target_dir" status --porcelain 2>/dev/null)
STEOF
    if [ -n "$fc_hits" ]; then
      repo_name_fc="${root##*/}"
      more=""
      [ "$fc_n" -gt 5 ] && more="
  ...and $(( fc_n - 5 )) more."
      # First real firing closes the PROJ-15368 reminder loop: write what happened into
      # the digest on-prompt.sh drains, drop the marker, and let the daily task delete itself
      # on its next fire (file-claim-firing-reminder.ps1). Event-driven, so nobody has to
      # remember to check.
      #
      # PRODUCTION ONLY. check-gates.sh exercises this very branch, and without this guard a
      # test run would clear the live marker and inject a fake firing line. Same test for
      # "am I really live" that lib-claude-paths.sh's absorb branch uses, plus FCLAIMS_FILE
      # being unset -- every test path overrides at least one of the two.
      if [ -z "${FCLAIMS_FILE_WAS_SET:-}" ] \
         && [ "${CLAUDE_STATE_DIR:-$HOME/.claude/harness-state}" = "$HOME/.claude/harness-state" ]; then
        _fc_notices="$HOME/.claude/harness-state/notices"
        if [ -f "$_fc_notices/.file-claim-firing-owed" ]; then
          printf '%s the file-claim commit guard FIRED for the first time -- %s file(s) in %s held by another live session, on: %s. PROJ-15368 can move off In Progress now; the daily reminder has cleared itself.\n' \
            "$(date '+%Y-%m-%d %H:%M')" "$fc_n" "$repo_name_fc" "$command" \
            >> "$_fc_notices/file-claim-reminder.txt" 2>/dev/null
          rm -f "$_fc_notices/.file-claim-firing-owed" 2>/dev/null
        fi
      fi
      warn="FILES IN YOUR TREE BELONG TO ANOTHER LIVE SESSION:
$fc_hits$more

A plain \`git commit\` takes the whole INDEX and \`git commit -- <paths>\` takes the whole WORKING TREE copy of those paths, so either one can ship their in-flight work under your message. That happened twice on 2026-09-01. Read \`git diff --cached\` before committing, and see commit-ticket/SHARED-REPO.md for the private-GIT_INDEX_FILE route when a file is genuinely shared."
    fi
  fi
fi

claim="$(claims_get "$root")"
if [ -z "$claim" ]; then
  if [ -n "$warn" ]; then emit_warn; fi
  exit 0
fi
other_sid="$(printf '%s' "$claim" | cut -f1)"
other_branch="$(printf '%s' "$claim" | cut -f2)"
other_when="$(printf '%s' "$claim" | cut -f3)"
[ -n "$other_sid" ] || exit 0

head_branch="$(git -C "$target_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)"
repo_name="$(basename "$root")"
age="$(claims_describe_age "$other_when")"

if [ "$other_sid" = "$sid" ]; then
  # Same session: the only interesting case is the tree having MOVED since we last acted.
  # That is the dangerous one -- committing or pushing onto a branch another session
  # switched us to, believing we are still on our own.
  if [ -n "$head_branch" ] && [ -n "$other_branch" ] && [ "$head_branch" != "$other_branch" ] \
     && { is_git_cmd 'commit' || is_git_cmd 'push'; }; then
    warn="${warn:+$warn

}$repo_name HAS MOVED UNDER YOU. You last acted on it while it was on \"$other_branch\" ($age ago); it is now on \"$head_branch\". Another session almost certainly checked out a different branch in this shared clone.\n\nYou are about to commit/push onto \"$head_branch\". Confirm that is the branch you mean BEFORE running this -- committing onto another session's branch is the worst outcome this guard exists to catch."
  fi
elif session_is_live "$other_sid"; then
  short="${other_sid%%-*}"
  if { is_git_cmd 'checkout' || is_git_cmd 'switch'; } \
     && [ -n "$other_branch" ] && [ "$other_branch" != "$head_branch" ]; then
    warn="${warn:+$warn

}$repo_name is claimed by ANOTHER LIVE SESSION ($short) on \"$other_branch\", last active $age ago.\n\nThis clone has one working tree, so switching branches here moves THEIR tree too -- and any uncommitted work they have goes with it.\n\nCheck live state first: bash ~/.claude/scripts/fleet-repo-state.sh $repo_name\n\nDon't switch here -- work in your own tree: bash ~/.claude/scripts/worktree-add.sh $repo_name <slug> <new-branch> [base]"
  fi
  # Same repo + both on hotfix branches = real Octopus Hotfix-channel contention.
  # Contention is per Octopus PROJECT, so same-repo is exactly the condition; two hotfixes
  # in different repos do not contend and must not warn.
  case "$other_branch" in
    hotfix/*)
      case "$command" in
        *hotfix/*)
          if [ "$other_branch" != "$head_branch" ]; then
            warn="${warn:+$warn\n\n}HOTFIX CONTENTION: session $short is already on $other_branch in $repo_name ($age ago). Two hotfixes in the SAME repo share one Octopus Hotfix channel and one Staging slot, so the second deploy overwrites the first. Coordinate before cutting another hotfix branch here -- a different repo would be fine."
          fi
          ;;
      esac
      ;;
  esac
fi

[ -n "$warn" ] || exit 0
emit_warn
