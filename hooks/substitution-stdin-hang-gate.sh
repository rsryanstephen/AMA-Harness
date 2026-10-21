#!/usr/bin/env bash
# PreToolUse hook (Bash): deny a stdin-reading filter whose ONLY file operands come from an
# unquoted command substitution -- `grep -l PATTERN $(find ...)`.
#
# When the substitution matches nothing it expands to NOTHING, the filter is left with no file
# operand, and a filter with no file operand reads STDIN. Nothing is on stdin, so it blocks
# forever: the tool call never returns, with no output, no error and no timeout. Confirmed
# 2026-09-14 -- `grep -l ... $(find ~/.claude/debug -newermt ...)` over a window with zero matching
# files ran 10+ minutes and the USER had to notice and flag it. Third cause of a frozen call after
# suspended hook orphans and the VPN DNS outage, and unlike those two it leaves no trace at all:
# nothing to grep for afterwards, because nothing was ever written.
#
# Why a gate and not the skill line. The tag went into [[bash-command-correctness]] the same turn
# (commit 33183ee) -- but that skill's retrieval description is about output that came back WRONG
# (empty, garbled, mis-encoded), and a call that never returns produces no output to notice. So
# nothing surfaces the rule at the moment it matters. CLAUDE.md: mechanical triggers over
# self-recognition.
#
# Deliberately NARROW -- each exemption below is a real false positive it would otherwise hit:
#   - only an UNQUOTED substitution. `grep P "$(cat f)"` passes one empty arg, which errors
#     ("No such file"); it does not hang.
#   - only when EVERY operand is a substitution. `grep P real.txt $(find ...)` still has real.txt,
#     so the filter never falls through to stdin.
#   - only a segment that does NOT already have piped stdin. `find ... | grep P` is the right form.
#   - a `<` redirect in the segment feeds stdin explicitly -- allowed, that is one of the fixes.
#   - pattern-taking filters (grep/sed/awk/jq) skip their first non-option operand: that is the
#     pattern, not a file.
# The parse lives in substitution-stdin-scan.pl (inline perl control flow is itself denied by
# unanalyzable-script-gate.sh, so it could never be tested from a tool call).
set -u

IFS= read -r -d '' payload || true
# Raw-payload prefilter before any fork (precedent: background-pipe-gate.sh): no substitution
# anywhere in the payload means the rule cannot fire, at zero cost.
case "$payload" in *'$('*|*'`'*) ;; *) exit 0 ;; esac

command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null | tr -d '\r')"
[ -n "$command" ] || exit 0

# Second filter, on the COMMAND alone. The raw check above also sees `tool_input.description`, and
# a backtick there is ordinary prose ("check the `grep` output") -- that would pay a perl fork on a
# large share of calls for a rule only the command can ever trigger. Costs nothing: no fork.
case "$command" in *'$('*|*'`'*) ;; *) exit 0 ;; esac

hit="$(printf '%s' "$command" | perl "$(dirname "${BASH_SOURCE[0]}")/substitution-stdin-scan.pl" 2>/dev/null)"
[ -n "$hit" ] || exit 0

jq -cn --arg f "$hit" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: ("`" + $f + "` here takes ALL its file operands from an unquoted command substitution. If that substitution matches nothing it expands to nothing, `" + $f + "` is left with no file operand, and a filter with no file operand READS STDIN -- so it blocks forever. The tool call never returns: no output, no error, no timeout, and nothing written to grep for afterwards. Confirmed 2026-09-14, a `grep -l ... $(find ... -newermt ...)` over a window with zero matching files ran 10+ minutes until the user noticed. Use `find ... -exec " + $f + " ... {} +` (no match => the filter never runs at all), or add `</dev/null` so an empty expansion returns immediately instead of hanging. Piping in (`find ... | " + $f + " ...`) is fine and not denied. Full tag: bash-command-correctness skill.")
  }
}'
