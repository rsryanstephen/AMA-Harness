#!/usr/bin/env bash
# PostToolUse hook (Edit|Write). Makes "keep ama-claude-harness/AGENTS.md current"
# mechanical instead of prose-only (memory/ama-harness-no-epic-comments.md,
# commit-ticket/SKILL.md x2, AGENTS.md all state it, but nothing enforced it --
# CONFIRMED REAL, TWICE: install.ps1's symlink list edited without its section,
# and 099ecf4 rewired Jira writes across 4 README-named files without touching the
# section describing them, only fixed after the fact in b93fc14). CLAUDE.md's own
# "Mechanical Triggers Over Self-Recognition" rule applies here.
#
# README.md (human-facing) is deliberately a separate file, out of this loop --
# human-readme-edit-gate.sh covers it instead. Renamed from README.md to AGENTS.md
# (<harnessEpicKey>) when the human/agent docs split; see AGENTS.md's banner.
#
# PostToolUse decision:"block" DOES reach the model (unlike Stop-hook block, which
# on-stop.sh confirmed never works) -- verified against a real transcript
# (git-push-ticket-reminder.sh fired, the model acted on the very next turn), not
# assumed by analogy.
set -u

payload="$(cat)"
sid="$(printf '%s' "$payload" | jq -r '.session_id // empty')"
tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty')"
file_path="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty')"
[ -n "$sid" ] && [ -n "$file_path" ] || exit 0
[ -f "$file_path" ] || exit 0

harness="$(git -C "$HOME/.claude/skills" rev-parse --show-toplevel 2>/dev/null)"
[ -n "$harness" ] || exit 0
claude_root="$(git -C "$HOME/.claude" rev-parse --show-toplevel 2>/dev/null)"
[ -n "$claude_root" ] || claude_root="$HOME/.claude"

# Same translation harness-edit-hash.sh / on-stop.sh's auto_commit_push_harness use --
# kept byte-identical on purpose, see those files' own comments on why.
norm() { printf '%s' "$1" | tr '\134' '/' | tr '[:upper:]' '[:lower:]'; }
harness_lc="$(norm "$harness")"
skills_lc="$(norm "$claude_root/skills")"
hooks_lc="$(norm "$claude_root/hooks")"
claudemd_lc="$(norm "$claude_root/CLAUDE.md")"
config_lc="$(norm "$claude_root/harness-config.json")"
f_lc="$(norm "$file_path")"

case "$f_lc" in
  "$skills_lc"/*) rel="skills${f_lc#"$skills_lc"}" ;;
  "$hooks_lc"/*) rel="hooks${f_lc#"$hooks_lc"}" ;;
  "$claudemd_lc") exit 0 ;;  # unconditional README hit, no specific section -- excluded on purpose
  "$config_lc") rel="harness-config.json" ;;
  "$harness_lc"/*) rel="${f_lc#"$harness_lc"/}" ;;
  *) exit 0 ;;
esac

readme="$harness/AGENTS.md"
[ -f "$readme" ] || exit 0

STATED="$HOME/.claude/.session-chatfiles"
mkdir -p "$STATED" 2>/dev/null
NUDGEFILE="$STATED/$sid.readmenudge"
touch "$NUDGEFILE"

# Editing AGENTS.md itself clears any outstanding nudges for this session -- it's
# exactly the act the rule wants, no reason to keep pestering after it happens.
# When no change is actually warranted (edit was inside a file AGENTS.md already
# describes generically), readme-nudge-ack.sh clears the single per-key nudge instead --
# see that script's header.
if [ "$rel" = "agents.md" ]; then
  : > "$NUDGEFILE"
  exit 0
fi

# README.md (human-facing) is a separate file and never satisfies an AGENTS.md nudge --
# explicit exit here rather than relying on the case-sensitive grep below to just miss
# it (norm() lowercases rel to "readme.md", which would never match the literal
# "README.md" strings AGENTS.md still contains -- fragile if that grep is ever made
# case-insensitive). human-readme-edit-gate.sh is this file's own reminder.
if [ "$rel" = "readme.md" ]; then
  exit 0
fi

# Search key: hooks/x.sh -> x.sh; skills/<name>/** -> <name>; else basename.
case "$rel" in
  hooks/*.sh) key="$(basename "$rel")" ;;
  skills/*/*) key="$(printf '%s' "$rel" | cut -d/ -f2)" ;;
  *) key="$(basename "$rel")" ;;
esac

# Trivial-edit suppression: small Edits don't nudge until they accumulate. A Write is
# a full-file rewrite -- never trivial. Line counts come from the tool_input itself,
# not a diff -- old_string/new_string length is what Claude actually changed.
lines=999
if [ "$tool" = "Edit" ]; then
  old_n="$(printf '%s' "$payload" | jq -r '.tool_input.old_string // "" | split("\n") | length')"
  new_n="$(printf '%s' "$payload" | jq -r '.tool_input.new_string // "" | split("\n") | length')"
  if [ "${old_n:-99}" -le 4 ] && [ "${new_n:-99}" -le 4 ]; then
    lines=$(( old_n > new_n ? old_n : new_n ))
  fi
fi

prev_line="$(grep -P "^\Q$key\E\t" "$NUDGEFILE" 2>/dev/null | tail -1)"
prev_total="0"
already_nudged=""
if [ -n "$prev_line" ]; then
  prev_total="$(printf '%s' "$prev_line" | cut -f2)"
  already_nudged="$(printf '%s' "$prev_line" | cut -f3)"
fi
total=$(( prev_total + lines ))

if [ "$total" -le 5 ]; then
  grep -vP "^\Q$key\E\t" "$NUDGEFILE" > "$NUDGEFILE.tmp" 2>/dev/null || : > "$NUDGEFILE.tmp"
  printf '%s\t%s\t%s\n' "$key" "$total" "" >> "$NUDGEFILE.tmp"
  mv "$NUDGEFILE.tmp" "$NUDGEFILE"
  exit 0
fi

[ "$already_nudged" = "1" ] && exit 0

hits="$(grep -nF "$key" "$readme" 2>/dev/null | head -2)"

if [ -n "$hits" ]; then
  summary="$(printf '%s' "$hits" | cut -c1-160 | tr '\n' '|')"
  reason="Edited $rel, which AGENTS.md names ($summary) -- verify the description there still matches, update if not."
else
  # rel is lowercased by norm() -- patterns and the git pathspec must match
  # case-insensitively (bare "skills/*/SKILL.md" + exact pathspec was dead code:
  # never matched "skill.md", and lowercased paths miss the real-case index).
  case "$rel" in
    hooks/*.sh|skills/*/skill.md)
      tracked="no"
      git -C "$harness" ls-files --error-unmatch -- ":(icase)$rel" >/dev/null 2>&1 && tracked="yes"
      if [ "$tracked" = "no" ]; then
        reason="New harness file $rel has no AGENTS.md mention -- add a brief bullet if it's install-visible (a new hook/skill), otherwise ignore."
      fi
      ;;
  esac
fi

seen_flag="0"
[ -n "${reason:-}" ] && seen_flag="1"
grep -vP "^\Q$key\E\t" "$NUDGEFILE" > "$NUDGEFILE.tmp" 2>/dev/null || : > "$NUDGEFILE.tmp"
printf '%s\t%s\t%s\n' "$key" "$total" "$seen_flag" >> "$NUDGEFILE.tmp"
mv "$NUDGEFILE.tmp" "$NUDGEFILE"

[ -n "${reason:-}" ] || exit 0

jq -cn --arg r "$reason" '{decision:"block", reason:$r}'
