#!/usr/bin/env bash
# PreToolUse (Bash|PowerShell): WARN before a git command that a linked worktree will make
# hard-fail -- checking out, switching to, or deleting a branch that is checked out in a
# DIFFERENT worktree of the same repo.
#
# git already refuses these ("fatal: 'X' is already used by worktree at ..."), so why warn?
# Because the failure lands MID-SEQUENCE. Release cleanup deletes branches across a dozen
# repos in one pass; a fatal in the middle of that reads as "the cleanup broke" rather than
# "this one branch lives in a worktree". Predicting it turns a confusing stop into an
# expected one, with the fix already named. Confirmed real: the release/129.0.0 plan had to
# carry the note "`search` has release/129.0.0 checked out in a linked worktree -- `git
# checkout master` in the main clone will fail", worked out by hand.
#
# Live at the time of writing: exporterplus has three worktrees and hotfix/129.0.3 is held
# by C:/ep-worktrees/hf-129-0-3, so both `checkout hotfix/129.0.3` and `branch -D
# hotfix/129.0.3` in the main clone fail right now.
#
# NOT a cross-session guard, despite the resemblance. Separate worktrees are the SOLUTION
# to the shared-clone problem (commit-ticket's worktree section tells agents to add one
# rather than switch someone else's branch) -- cross-session-repo-claim.sh deliberately
# stays silent between them because they do not share a working tree. This hook is about a
# mechanical git constraint that applies even to a single session working alone.
#
# Warn, never deny -- same strength as the other coordination guards. Fails open.
set -u

IFS= read -r -d '' payload || true
case "$payload" in *git*) ;; *) exit 0 ;; esac

command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null | tr -d '\r')"
cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)"
[ -n "$command" ] || exit 0

. "$HOME/.claude/hooks/lib-git-target.sh" 2>/dev/null || exit 0
target_dir="$(git_target_dir "$command" "$cwd")"
[ -n "$target_dir" ] || exit 0

# Which branch is this command about?
#
# Deliberately excludes the branch-CREATING forms (-b / -c / --orphan): those fail on "already
# exists" long before any worktree rule applies, so warning about a worktree would point at the
# wrong problem. Also excludes `checkout -- <path>` and `checkout .`, which restore files and
# have nothing to do with branches -- the single most likely false positive here.
branch=""
action=""
# The create-flag test is anchored IMMEDIATELY AFTER the subcommand, not searched across the
# whole command. An unanchored `-C` test collides with git's own global `git -C <path>` --
# which is the dominant shape in this harness -- and silently skipped every real case.
if printf '%s' "$command" | grep -qP '(^|[;&|]|&&)\s*git\s+(-C\s+\S+\s+)?(checkout|switch)\b' \
   && ! printf '%s' "$command" | grep -qP '(checkout|switch)\s+(-b|-c|-B|-C|--orphan)\b' \
   && ! printf '%s' "$command" | grep -qP '\s--\s' ; then
  branch="$(printf '%s' "$command" \
    | grep -oP '(^|[;&|]|&&)\s*git\s+(-C\s+\S+\s+)?(checkout|switch)\s+\K[^\s;&|]+' | head -1)"
  action="check out"
elif printf '%s' "$command" | grep -qP '(^|[;&|]|&&)\s*git\s+(-C\s+\S+\s+)?branch\s+(-d|-D|--delete)\b'; then
  branch="$(printf '%s' "$command" \
    | grep -oP 'branch\s+(-d|-D|--delete)\s+\K[^\s;&|]+' | head -1)"
  action="delete"
fi
[ -n "$branch" ] || exit 0
case "$branch" in -*|.|./*) exit 0 ;; esac
branch="${branch%\"}"; branch="${branch#\"}"

# --porcelain, not the human format: stable records (worktree / branch / detached), and the
# human format's alignment makes path-with-spaces parsing guesswork.
wt="$(git -C "$target_dir" worktree list --porcelain 2>/dev/null)"
[ -n "$wt" ] || exit 0
here="$(git -C "$target_dir" rev-parse --show-toplevel 2>/dev/null)"

holder="$(printf '%s\n' "$wt" | awk -v want="refs/heads/$branch" -v here="$here" '
  /^worktree /{ path=substr($0,10) }
  /^branch /  { if ($2 == want && path != here) { print path; exit } }
')"
[ -n "$holder" ] || exit 0

reason="git will REFUSE to $action \"$branch\" here: it is already checked out in another worktree of this repo.

  held by:  $holder
  you are:  ${here:-$target_dir}

This is a hard git constraint (fatal: '$branch' is already used by worktree at ...), not a policy -- the command will fail, so expect it rather than reading it as the sequence breaking. It bit the release/129.0.0 cleanup already.

Options:
  - Work in that worktree instead:            cd $holder
  - Doing release cleanup? Remove it first:   git -C ${here:-$target_dir} worktree remove $holder
  - Need your own tree for this branch?       see commit-ticket's worktree section (add one, never check out over another tree)

See every worktree and who holds what:  bash ~/.claude/scripts/fleet-repo-state.sh"

jq -cn --arg r "$reason" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "allow",
    permissionDecisionReason: $r
  }
}'
