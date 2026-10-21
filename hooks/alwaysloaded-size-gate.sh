#!/usr/bin/env bash
# PostToolUse hook (Edit|Write). PROJ-15364: size counter-pressure for the ALWAYS-LOADED
# surfaces besides AGENTS.md (readme-currency-gate.sh covers that one). Each has the same
# growth dynamics the 253KB AGENTS.md had -- every edit adds, nothing prunes -- and each
# costs every session, every turn:
#   - CLAUDE.md: injected whole into every session.       CLAUDEMD_SIZE_LIMIT  (10000 B)
#   - memory/*.md: one pointer line injected per matching UserPromptSubmit.
#     Guarded on COUNT of files, not one file's size.     MEMORY_COUNT_LIMIT   (40 files)
#   - skills/*/SKILL.md frontmatter description: loaded for EVERY skill in every session's
#     skill list, relevant or not.                        SKILL_DESC_LIMIT     (700 chars)
# Nudge-only ({decision:block} reason, same reach as readme-currency-gate.sh) -- never
# blocks the write itself (PostToolUse runs after). Baselines at 2026-08-31: CLAUDE.md
# 5.4KB, 27 memory files, longest description 598 chars.
set -u

payload="$(cat)"
file_path="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty' | tr -d '\r' | tr '\134' '/')"
[ -n "$file_path" ] || exit 0

harness="$(git -C "$HOME/.claude/hooks" rev-parse --show-toplevel 2>/dev/null)"
[ -n "$harness" ] || exit 0

norm() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -e 's|^/\([a-z]\)/|\1:/|'; }
f_lc="$(norm "$file_path")"
h_lc="$(norm "$harness")"
c_lc="$(norm "$HOME/.claude")"

reason=""
case "$f_lc" in
  "$h_lc"/claude.md|"$c_lc"/claude.md)
    limit="${CLAUDEMD_SIZE_LIMIT:-10000}"
    bytes="$(wc -c < "$file_path" 2>/dev/null)"
    if [ "${bytes:-0}" -gt "$limit" ]; then
      reason="CLAUDE.md is ${bytes} bytes (limit ${limit}) and is injected whole into EVERY session -- do not grow it: it holds trimmed summaries only, substance belongs in the skill/AGENTS.md section it points at (same relocate-not-append rule as AGENTS.md's routing note)."
    fi ;;
  "$h_lc"/memory/*.md|"$c_lc"/memory/*.md)
    limit="${MEMORY_COUNT_LIMIT:-40}"
    count="$(ls "$harness/memory/"*.md 2>/dev/null | grep -c .)"
    if [ "${count:-0}" -gt "$limit" ]; then
      reason="memory/ now holds ${count} files (limit ${limit}); every matching file adds an injected pointer line to every prompt. Before adding more: merge overlapping memories, delete stale ones, or narrow global scopes to a cwd (see harness-memory)."
    fi ;;
  "$h_lc"/skills/*/skill.md|"$c_lc"/skills/*/skill.md)
    limit="${SKILL_DESC_LIMIT:-700}"
    desc="$(sed -n '1,20p' "$file_path" 2>/dev/null | tr -d '\r' | grep '^description:' | head -1)"
    dlen="${#desc}"
    if [ "$dlen" -gt "$limit" ]; then
      reason="This SKILL.md's frontmatter description is ${dlen} chars (limit ${limit}) -- descriptions load for EVERY skill in every session's skill list, relevant or not. Keep it to trigger phrases + one-line purpose; mechanics belong in the body."
    fi ;;
  *) exit 0 ;;
esac

[ -n "$reason" ] || exit 0
jq -cn --arg r "$reason" '{decision:"block", reason:$r}'
