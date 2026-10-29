#!/usr/bin/env bash
# PreToolUse hook (Bash/PowerShell). Denies a `git commit` in the HARNESS repo whose
# staged content would abort scripts/publish-public.sh at its forbidden-token gate.
#
# Why pre-commit and not just the existing check: the gate only ran inside on-stop.sh's
# auto-publish, i.e. AFTER the commit. A forbidden token therefore broke the public mirror
# silently and the only trace was a harness-gaps.md line -- that happened twice in one day
# (a generic `ec2-*.<region>.compute.amazonaws.com` example in a skill doc, gate pattern
# `compute-1\.amazonaws`, no scrub-map literal covering it).
#
# Why it can't just call `--dry-run`: that path exports `git archive HEAD`, so pre-commit
# it would inspect the PREVIOUS commit and miss the one being made. publish-public.sh's
# `--check-paths` mode exists for this -- same combined scrub map, same scrub, same gate,
# against the working-tree copies of the staged paths, so a verdict here means what it
# means in a real publish. The export's own exclusion list lives in that script too
# (`excluded_from_export`), not duplicated here.
set -u

IFS= read -r -d '' payload || true
# Cheap raw-payload pre-filter before any jq fork (precedent: aggregation-secret-gate.sh,
# bare-cd-gate.sh) -- no "commit" substring means this cannot be a git commit.
case "$payload" in *commit*) ;; *) exit 0 ;; esac

cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty')"
command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"
[ -n "$command" ] || exit 0
printf '%s' "$command" | tr -d '\r' | grep -qP 'git\s+(-C\s+\S+\s+)?commit\b' || exit 0

# `git -C <path> commit` targets a repo other than cwd -- honor it, that's the form this
# harness actually uses for cross-repo commits.
. "$HOME/.claude/hooks/lib-git-target.sh" 2>/dev/null || exit 0
target="$(git_target_dir "$command" "$cwd")"
[ -n "$target" ] || exit 0

# The harness repo is wherever ~/.claude/skills points (same resolution as
# check-settings-parity.sh). FAIL CLOSED when that cannot be resolved: the action this
# gate guards is a secret reaching the PUBLIC mirror -- history, forks, crawlers -- which
# is not reversible, while a denied commit is. Fail direction follows the reversibility
# of the guarded action, not the convenience of the caller (GATES-AND-HOOKS.md). The
# two branches below that still fail open are the reversible ones: "not the harness
# repo" and "nothing staged".
# PUBLISH_SCRUB_SKILLS_DIR exists so check-gates.sh can point this at a non-repo and assert
# the deny -- the real junction must never be broken to test it.
harness="$(git -C "${PUBLISH_SCRUB_SKILLS_DIR:-$HOME/.claude/skills}" rev-parse --show-toplevel 2>/dev/null)"
if [ -z "$harness" ]; then
  jq -cn '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",
    permissionDecisionReason:"publish-scrub-gate could not resolve the harness repo from ~/.claude/skills, so it cannot tell whether this commit would reach the PUBLIC mirror. This gate fails CLOSED on purpose -- a secret on the mirror is not reversible, a denied commit is. Check the ~/.claude/skills junction (bash \"$HOME/.claude/scripts/harness-link-check.sh\" --repair) and re-run."}}'
  exit 0
fi
repo="$(git -C "$target" rev-parse --show-toplevel 2>/dev/null)" || exit 0
[ -n "$harness" ] && [ -n "$repo" ] || exit 0
norm() { printf '%s' "$1" | tr '\134' '/' | tr '[:upper:]' '[:lower:]' | sed -e 's:/*$::' -e 's|^/\([a-z]\)/|\1:/|'; }
[ "$(norm "$repo")" = "$(norm "$harness")" ] || exit 0

# What the commit carries: the staged files, PLUS changed files the command names itself.
# `git commit -- <paths>`, `--pathspec-from-file` and `-a` commit working-tree content that
# was never staged -- this gate used to see none of it, and pathspec commits are what
# SHARED-REPO.md tells every session to use (2026-10-28: a scrub-dodging fixture got in that
# way, 588d7f7). Matching changed paths against the command text and the pathspec file
# avoids parsing shell; `-a`/`--all` takes every changed tracked file. Nothing at all (an
# amend of an unchanged tree) -> nothing to check; the post-commit publish still gates it.
mapfile -t staged < <({
  git -C "$repo" diff --cached --name-only
  chg="$(git -C "$repo" diff --name-only)"
  if printf '%s' "$command" | grep -qP '\bcommit\b.*\s(--all|-[A-Za-z]*a[A-Za-z]*)(\s|$)'; then
    printf '%s\n' "$chg"
  else
    named="$command"
    pf="$(printf '%s' "$command" | grep -oP -- '--pathspec-from-file[= ]\K\S+' | tr -d "\"'" | head -n 1)"
    [ -z "$pf" ] || [ -f "$pf" ] || pf="$target/$pf"
    [ -n "$pf" ] && [ -f "$pf" ] && named="$named
$(cat "$pf")"
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      case "$named" in *"$f"*) printf '%s\n' "$f" ;; esac
    done <<< "$chg"
  fi
} 2>/dev/null | tr -d '\r' | sed '/^$/d' | sort -u)
[ "${#staged[@]}" -gt 0 ] || exit 0

out="$(bash "$harness/scripts/publish-public.sh" --check-paths "${staged[@]}" 2>&1)" && exit 0

jq -cn --arg o "$out" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: ("Staged content would abort the public-mirror publish at its forbidden-token gate, so this commit would break `scripts/publish-public.sh` (silently -- it only runs after the commit, in on-stop.sh). Fix the file(s) below first, then re-commit.\n\n" + $o + "\n\nEach line is `<repo-relative path>:<line>:<text>`. The matched pattern is one of `scripts/public-scrub-gate.txt`. Fix by MAPPING, not by rewording: add the literal to `scripts/public-scrub-map.txt` (real config values are auto-mapped instead -- add the matching key to `harness-config.example.json`). That holds for a deliberately generic placeholder too: a wildcard example reads as generic to a human and as a hit to the gate, and it gets its own map entry so the doc can keep the natural shape (see the generic-placeholder block in that file). Reword only when the token has no business being in the repo at all.")
  }
}'
