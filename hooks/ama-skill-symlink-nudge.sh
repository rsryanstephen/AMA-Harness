#!/usr/bin/env bash
# PostToolUse nudge (Edit|Write). A skills/ama-*/SKILL.md write whose skills/ama/ browsing
# symlink is missing -> remind to create it. skills/ama/ is a browsing-only index (skill
# discovery never reads it), so a missing link is silently invisible forever -- exactly the
# write-only failure mode CLAUDE.md's "Mechanical Triggers Over Self-Recognition" names.
# Rule was prose-only in AGENTS.md until PROJ-15361's hookability audit.
set -u

IFS= read -r -d '' payload || true
case "$payload" in *SKILL.md*) ;; *) exit 0 ;; esac

path="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty' | tr -d '\r' | tr '\134' '/')"
case "$path" in */skills/ama-*/SKILL.md) ;; *) exit 0 ;; esac

skill="$(basename "$(dirname "$path")")"
harness="$(git -C "$HOME/.claude/hooks" rev-parse --show-toplevel 2>/dev/null)"
[ -n "$harness" ] || exit 0

# -e follows the link (true for a healthy relative symlink); -L catches one that exists
# but dangles. Either way the entry is present -- nothing to nudge.
{ [ -e "$harness/skills/ama/$skill" ] || [ -L "$harness/skills/ama/$skill" ]; } && exit 0

jq -cn --arg s "$skill" --arg h "$harness" '{
  decision: "block",
  reason: ($s + " has no skills/ama/ browsing symlink -- create it now (relative, like its siblings): MSYS=winsymlinks:nativestrict ln -s ../" + $s + " \"" + $h + "/skills/ama/" + $s + "\". The MSYS prefix is REQUIRED on Windows: a plain ln -s silently COPIES the directory (2026-09-07: a 198-line copy got committed as mode 100644 where every sibling is 120000). The index is browsing-only (discovery never reads it), so a missing link stays invisible forever.")
}'
