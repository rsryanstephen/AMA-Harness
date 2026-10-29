#!/usr/bin/env bash
# PostToolUse hook (Bash/PowerShell), warn-only. "Next time someone changes repo X, also do Y" --
# a deferred per-repo follow-up with no event of its own to hang on. After a `git commit` in a repo
# that has an open row in `hstate tickets repo-followups`, names the follow-up so it rides along in
# the same change instead of being remembered. Once per repo+branch (`repo-followups-nudged`).
#
# Row, TAB-separated:  <slug> <ticket> <file>:<fixed string> <what to do>
#   product-service-common-models  PROJ-15915  bitbucket-pipelines.yml:sbom-publish.sh  Add ...
# Self-clearing: silent while the committed HEAD's <file> contains <fixed string> (it is in this change);
# the row is dropped once the DEFAULT branch (origin/HEAD, else origin/master) contains it too.
# Nothing to remember to delete.
#
# Why (PROJ-15915, user 2026-10-28): master-only library repos take the SBOM pipeline step with
# their NEXT real change rather than a YAML-only PR each (~20 PRs for one reviewer). A memory note
# relies on a session recognising the moment; this fires on the commit itself.
# Seam: CLAUDE_STATE_DIR. Fails open everywhere.
set -u

IFS= read -r -d '' payload || true
case "$payload" in
  *commit*) : ;;
  *) exit 0 ;;
esac

rows="${CLAUDE_STATE_DIR:-$HOME/.claude/harness-state}/tickets/repo-followups"
[ -s "$rows" ] || exit 0   # no open follow-ups: zero forks

command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null | tr -d '\r')"
cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null | tr -d '\r')"
[ -n "$command" ] || exit 0
printf '%s' "$command" | grep -qP '(^|[;&|]|&&)\s*git\s+(-C\s+\S+\s+)?commit\b' || exit 0

. "$HOME/.claude/hooks/lib-git-target.sh" 2>/dev/null || exit 0
git_target_unresolved "$command" commit && exit 0
target_dir="$(git_target_dir "$command" "$cwd" commit)"
[ -n "$target_dir" ] || exit 0
slug="$(git -C "$target_dir" remote get-url origin 2>/dev/null | tr -d '\r' | sed -E 's#.*[/:]##; s#\.git$##')"
[ -n "$slug" ] || exit 0
grep -q "^$slug	" "$rows" 2>/dev/null || exit 0

branch="$(git -C "$target_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)"
# The row is DONE only once the default branch has it; a branch that has it is "in this change" (no
# nudge) but may never merge -- clearing on HEAD dropped common-logging's row off an unmerged pilot branch.
def="$(git -C "$target_dir" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)"
[ -n "$def" ] || def=origin/master
has() { git -C "$target_dir" show "$1:${2%%:*}" 2>/dev/null | grep -qF -- "${2#*:}"; }
seen="${rows}-nudged"
msg="" done_any=""
while IFS=$'\t' read -r s ticket check todo; do
  [ "$s" = "$slug" ] || continue
  file="${check%%:*}"; want="${check#*:}"
  if has HEAD "$check"; then
    has "$def" "$check" && done_any=1
    continue
  fi
  grep -qxF "$slug	$branch	$ticket" "$seen" 2>/dev/null && continue
  printf '%s\t%s\t%s\n' "$slug" "$branch" "$ticket" >> "$seen" 2>/dev/null
  msg="${msg}Owed follow-up for $slug ($ticket): $todo Put it in this same change (branch $branch) before it merges -- it was deferred to ride along with this repo's next real change. Silent once this branch's $file contains '$want'; the row clears once $def has it.
"
done < "$rows"

# drop finished rows (temp + mv: never a half-written ledger)
if [ -n "$done_any" ]; then
  tmp="$rows.tmp.$$"
  while IFS=$'\t' read -r s ticket check todo; do
    if [ "$s" = "$slug" ] && has "$def" "$check"; then continue; fi
    printf '%s\t%s\t%s\t%s\n' "$s" "$ticket" "$check" "$todo"
  done < "$rows" > "$tmp" && mv -f "$tmp" "$rows"
fi

[ -n "$msg" ] || exit 0
jq -cn --arg r "${msg%$'\n'}" '{decision:"block", reason:$r}'
