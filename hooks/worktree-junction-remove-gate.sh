#!/usr/bin/env bash
# PreToolUse (Bash|PowerShell): DENY `git worktree remove <path>` while <path> still holds a
# junction/symlink (a `mklink /J node_modules` into the main clone, the usual shape).
#
# Why deny: git's remove deletes ignored files too and FOLLOWS the junction, emptying the
# target -- the MAIN clone's node_modules. Hit twice on 2026-10-21 (exporterplus; the second
# time it broke the user's running `ng serve`, recovery `npm ci`). The prose rule in
# commit-ticket/SHARED-REPO.md did not hold either time.
#
# Fix the deny names: remove the link itself first (`rm <link>` on the link, no -r, or
# `cmd //c rmdir <link>`), then re-run the remove. No hatch -- once the link is gone the gate
# passes on its own. Fails open (unparseable path, missing dir).
set -u

IFS= read -r -d '' payload || true
case "$payload" in *worktree*remove*) ;; *) exit 0 ;; esac

command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null | tr -d '\r')"
cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null | tr -d '\r')"
[ -n "$command" ] || exit 0

# git [-C <dir>] worktree remove [-f|--force]... <path>
re='git[[:space:]]+(-C[[:space:]]+("[^"]+"|[^[:space:]]+)[[:space:]]+)?worktree[[:space:]]+remove[[:space:]]+((-f|--force)[[:space:]]+)*("[^"]+"|[^[:space:];&|]+)'
[[ $command =~ $re ]] || exit 0
gdir="${BASH_REMATCH[2]}"; wt="${BASH_REMATCH[5]}"
gdir="${gdir#\"}"; gdir="${gdir%\"}"; wt="${wt#\"}"; wt="${wt%\"}"

case "$wt" in
  /*|[A-Za-z]:*) ;;
  *) base="${gdir:-$cwd}"; [ -n "$base" ] || exit 0; wt="$base/$wt" ;;
esac
command -v cygpath >/dev/null 2>&1 && wt="$(cygpath -u "$wt" 2>/dev/null || printf '%s' "$wt")"
[ -d "$wt" ] || exit 0

# Links within 3 levels (node_modules can sit in a sub-project). A REAL node_modules or .git
# dir is pruned, not walked -- walking one costs seconds.
links=""; wt_real="$(readlink -f "$wt" 2>/dev/null)"
while IFS= read -r l; do
  # A link resolving INSIDE this tree (the harness repo tracks skills/ama/* -> ../ama-*) deletes
  # nothing outside it; only an outside or unresolvable target is the hazard. Fail-safe: an
  # empty readlink keeps the link in the deny list.
  t="$(readlink -f "$l" 2>/dev/null)"
  [ -n "$wt_real" ] && [ -n "$t" ] && case "$t" in "$wt_real"/*) continue ;; esac
  links="${links:+$links
}$l"
done < <(find "$wt" -maxdepth 3 \( -type l -print \) -o \( -type d \( -name node_modules -o -name .git \) -prune \) 2>/dev/null | head -50)
links="$(printf '%s\n' "$links" | head -5)"
[ -n "$links" ] || exit 0

jq -cn --arg l "$links" --arg w "$wt" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: ("`git worktree remove` would follow a junction/symlink inside " + $w + " and delete the TARGET'\''s contents (2026-10-21: emptied exporterplus main-clone node_modules twice). Remove the link itself first -- `rm <link>` (no -r) or `cmd //c rmdir <link>` -- then re-run. Links found:\n" + $l)
  }
}'
exit 0
