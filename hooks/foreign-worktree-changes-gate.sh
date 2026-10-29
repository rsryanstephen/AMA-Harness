#!/usr/bin/env bash
# PreToolUse (Bash|PowerShell): WARN before a sweeping `git add -A` / `git add .` / a
# pathspec-less `git commit` in a repo where another live session has modified files.
#
# Why this is not covered already. git-commit-scope-gate.sh denies `git add <files> &&
# git commit` with no trailing pathspec, because "a concurrent session's already-staged
# files got silently swept into the commit under an unrelated message" -- confirmed twice
# against ama-claude-harness. But its header is explicit that it only inspects the CURRENT
# command's text: it "never inspects the index, never looks at other sessions", and it
# deliberately declined to build session-state infrastructure for the cross-call case
# (staged earlier, committed later; or `add -A` sweeping files nobody staged at all).
# That state now exists -- .repo-claims -- so this covers the case it left open.
#
# Live proof at the time of writing: ama-claude-harness holds
# skills/ama-architecture-notes/EXPORT-DOWNLOADS.md and skills/ama-ui-verify/SKILL.md
# modified by another session, and on-stop.sh auto-commits that very repo. on-stop.sh
# guards ITS own auto-commit with a sha256 sidecar (<sid>.harnesshashes) after committing
# 3 files a concurrent session had just edited -- but a hand-run `git add -A` has no such
# protection.
#
# WARNS, never denies (user decision). `git add -A` is legitimate constantly -- on-stop's
# own auto-commit uses it -- so denying would be wrong and noisy. The warning fires only
# when another LIVE session is claiming the repo, which is what keeps it rare.
#
# Fails open on anything unresolvable.
set -u

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

# Only the sweeping shapes. `git add <specific paths>` and `git commit -- <paths>` are
# already scoped and cannot pick up a file the author didn't name.
# Matched against the text with heredoc bodies and single-quoted spans removed -- the commit
# branch below matches ANY pathspec-less commit, so without this a fixture string containing
# `git commit` would warn. Same "fixture text is not an invocation" class the two git gates
# already guard; lib-command-text.sh is the shared copy.
. "$HERE/lib-command-text.sh" 2>/dev/null || exit 0
scan="$(printf '%s\n' "$command" | command_text_stripped)"

sweeping=false
printf '%s' "$scan" | grep -qP "(^|[;&|]|&&)\s*git\s+(-C\s+\S+\s+)?add\s+(-A|--all|\.)(\s|$)" && sweeping=true
if [ "$sweeping" != true ]; then
  # Pathspec-less commit -- BARE `git commit` as well as -a/-am. The bare form was the shape
  # this header always claimed to cover and never did: requiring -a/--all/-am here let commit
  # 8b5a84d sweep another live session's in-flight settings.json edits into itself
  # (harness-gaps.md, 2026-09-14), silently, because that commit carried no -a.
  # A bare `git commit` takes the whole INDEX, which is exactly the cross-call case
  # git-commit-scope-gate.sh's header declined to chase for want of session state.
  printf '%s' "$scan" | grep -qP "(^|[;&|]|&&)\s*git\s+(-C\s+\S+\s+)?commit\b" \
    && ! printf '%s' "$scan" | grep -qP '\s--\s' && sweeping=true
fi
[ "$sweeping" = true ] || exit 0

. "$HOME/.claude/hooks/lib-git-target.sh" 2>/dev/null || exit 0
target_dir="$(git_target_dir "$command" "$cwd")"
[ -n "$target_dir" ] || exit 0

root="$(claims_repo_root "$target_dir")"
[ -n "$root" ] || exit 0

claim="$(claims_get "$root")"
[ -n "$claim" ] || exit 0
other_sid="$(printf '%s' "$claim" | cut -f1)"
other_when="$(printf '%s' "$claim" | cut -f3)"
[ -n "$other_sid" ] && [ "$other_sid" != "$sid" ] || exit 0
session_is_live "$other_sid" || exit 0

# Modified TRACKED files only -- untracked noise (build output, scratch) is not somebody's
# work being stolen, and warning about it would make this fire constantly.
changed="$(git -C "$target_dir" status --porcelain 2>/dev/null | grep -v '^??' | head -12)"
[ -n "$changed" ] || exit 0
count="$(git -C "$target_dir" status --porcelain 2>/dev/null | grep -vc '^??')"

# Reason assembled in shell, then passed via --arg. Building it inside the jq program
# instead is a trap: an apostrophe in ordinary prose ("another session's work") closes the
# shell single-quote and the hook dies with "unexpected EOF". Same reason the sibling hook
# does it this way.
repo_name="$(basename "$root")"
reason="This sweeps ALL $count modified file(s) in $repo_name, and session ${other_sid%%-*} (live, active $(claims_describe_age "$other_when") ago) is working in that same clone. Some of these are probably theirs:

$changed

Committing another session in-progress work under your own ticket ref is the exact failure git-commit-scope-gate.sh was written for, twice, in this repo.

Name your own paths instead:  git commit -m \"...\" -- <your paths>
Check who holds the repo:     bash ~/.claude/scripts/fleet-repo-state.sh $repo_name

If you have confirmed every one of these files is yours, proceed."

jq -cn --arg r "$reason" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "allow",
    permissionDecisionReason: $r
  }
}'
