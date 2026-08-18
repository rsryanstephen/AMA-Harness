#!/usr/bin/env bash
# PreToolUse hook (Bash|PowerShell). Denies an in-place stream edit (sed -i, perl -i)
# against a path under ~/.claude.
#
# Shell sibling of symlink-write-gate.sh, and the more dangerous half. Every file under
# ~/.claude is a SymbolicLink into ama-claude-harness (dirs are Junctions). Edit/Write at
# least REFUSE to write through a symlink, which is what that gate turns into a useful
# message. `sed -i` has no such refusal: it writes a temp file and RENAMES it over the
# target, and rename replaces the link with a standalone file. The edit then lands outside
# the repo, `git status` shows clean, and the two copies diverge silently.
#
# Confirmed live 2026-08-17 on harness-gaps.md: sed -i reported success, the file held the
# new text, git saw nothing, and Get-Item showed LinkType empty -- the link was gone. Same
# rename hazard on-prompt.sh already comments on for its own state writes.
#
# Deliberately narrow: requires an in-place FLAG (not merely `sed`) plus a .claude path, so
# `sed -n 's/x/y/p' ~/.claude/f` and `grep -i pat ~/.claude/f` both pass untouched.
#
# The flag must be a real TOKEN -- whitespace, then `-`, then optional bundled letters, then
# `i`. Matching a bare `-i` anywhere in the argument region got it wrong both ways: it denied
# `sed -n '1,25p' ~/.claude/.../jira-edit-issue.sh` (the `-i` is inside `edit-issue`), and it
# MISSED `perl -pi -e` / `perl -npi.bak -e` -- the classic in-place perl idioms, where `-i` is
# bundled behind another letter -- which is the exact command this gate exists to stop.
set -u

payload="$(cat)"

# Cheap needle check on the RAW payload before any jq fork -- no .claude path, nothing to
# protect (precedent aggregation-secret-gate.sh).
case "$payload" in *.claude*) : ;; *) exit 0 ;; esac

command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
[ -n "$command" ] || exit 0

# Heredoc bodies are DATA, not commands -- measure only the region before the first `<<`
# (same scoping unanalyzable-script-gate.sh uses). Without this, a commit message that
# merely DESCRIBES this hazard self-denies: the first version of this gate blocked its own
# commit that way, the same quote-blind trap deploy-verify-confirm-gate.sh documents.
head_region="${command%%<<*}"
case "$head_region" in *.claude*) : ;; *) exit 0 ;; esac

# sed/perl must be at a COMMAND POSITION (start, or after a | ; & chain), and the in-place
# flag must sit in that same simple command -- not merely appear somewhere in the text.
printf '%s' "$head_region" \
  | grep -qE '(^|[|;&])[[:space:]]*(sed|perl)[[:space:]]+([^|;&]*[[:space:]])?(-[A-Za-z0-9]*i([[:space:]]|$|\.|[A-Za-z0-9_-])|--in-place)' \
  || exit 0

jq -cn '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: ("In-place stream edit (sed -i / perl -i) against a ~/.claude path. Every file there is a SymbolicLink into ama-claude-harness, and these tools RENAME a temp file over the target -- which replaces the link with a standalone file. The edit lands outside the repo, `git status` reports clean, and the two copies silently diverge. Confirmed live on harness-gaps.md: sed -i reported success and the link was gone. Use the Edit tool instead, or write through the resolved repo path (readlink -f the target). If you have already done it: `powershell -c \"(Get-Item '"'"'<path>'"'"' -Force).LinkType\"` returns empty when the link is broken -- copy the local content over the repo file, delete the local file, then recreate it with New-Item -ItemType SymbolicLink. Full detail in the bash-command-style skill.")
  }
}'
