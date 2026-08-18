#!/usr/bin/env bash
# PreToolUse hook (Bash/PowerShell). Mechanical backstop for the grep-memory-blowup
# problem -- prose guidance alone (resource-efficiency, then a dedicated grep-usage
# skill) didn't prevent a recurrence: confirmed real incident TWICE, grep.exe hit
# ~2GB then ~6GB RAM from an unscoped recursive grep buffering binary files as giant
# single "lines". Same class of fix as bare-cd-gate.sh/skill-bloat-gate.sh -- a rule
# that only lives in a skill depends on the model reading it that session; this
# catches the pattern regardless.
#
# Denies a recursive `grep` (-r/-R/--recursive) missing `-I` (binary-skip) -- that
# single flag fixes the confirmed root cause. Doesn't require --exclude-dir/--include
# too (that's strongly recommended in [[grep-usage]], not hard-gated here) to keep
# false positives low for genuinely small/safe recursive searches.
set -u

IFS= read -r -d '' payload || true
# Cheap raw-payload pre-filter before any jq fork (precedent:
# aggregation-secret-gate.sh) -- every command the deny-regex below can match
# contains the literal substring "grep", so a payload without it can exit on zero
# forks. False positives (e.g. "grep" in prose) just fall through to the unchanged
# full logic. Process spawns cost ~60ms each on this machine (Sysmon/Intune tax),
# so the common no-grep case dropping from 5 forks to 0 matters on every Bash call.
case "$payload" in *grep*) ;; *) exit 0 ;; esac
tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty')"
command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"

[ "$tool" = "Bash" ] || [ "$tool" = "PowerShell" ] || exit 0
[ -n "$command" ] || exit 0

# Flatten to one line first -- grep -P's ^/$ anchor to EACH line by default, not the
# whole string. Confirmed real false positive: a commit message documenting this very
# hook (prose mentioning "grep -rn" as an example) got denied because that example
# line's own start satisfied the "^" anchor. Flattening makes ^ mean true start-of-
# command, so a mid-prose example (not preceded by ;/&/|/&&) correctly stops matching.
# tr -d '\r' first: jq -r emits CRLF here and grep -P treats bare \r as a line
# boundary (PCRE ANYCRLF) -- see git-commit-scope-gate.sh, same fix.
flat="$(printf '%s' "$command" | tr -d '\r' | tr '\n' ' ')"

# Must be an actual grep invocation (anchored at start or after ;/&/|/&&), not just
# the word "grep" appearing inside a quoted argument/prose elsewhere in the command.
printf '%s' "$flat" | grep -qP '(^|[;&|]|&&)\s*grep\b' || exit 0

# Recursive flag present? -r/-R as a standalone or packed short-opt (-rn, -rli, etc),
# or --recursive.
printf '%s' "$flat" | grep -qP '(^|[;&|]|&&)\s*grep\s+(-[a-zA-Z]*[rR][a-zA-Z]*\b|--recursive\b)' || exit 0

# Already has -I (standalone or packed, e.g. -rI, -Ir)? Allow through.
printf '%s' "$flat" | grep -qP '(^|[;&|]|&&)\s*grep\s+-[a-zA-Z]*I[a-zA-Z]*\b' && exit 0

jq -cn '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: "Recursive grep missing -I (binary-skip) -- confirmed real incident TWICE, grep.exe hit ~2GB then ~6GB RAM buffering a binary file as one giant line. Prefer the Grep tool instead (ripgrep-backed, skips binaries automatically). If a raw grep is genuinely needed: add -I, and see the grep-usage skill for scoping (--exclude-dir/--include, narrow the target directory)."
  }
}'
