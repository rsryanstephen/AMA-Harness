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
case "$payload" in *grep*|*scratch*|*Temp/claude*|*Temp\\claude*) ;; *) exit 0 ;; esac
tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty')"
command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"

[ "$tool" = "Bash" ] || [ "$tool" = "PowerShell" ] || exit 0
[ -n "$command" ] || exit 0

# A grep inside a scratch script the command runs (`bash <scratchpad>/x.sh`) is invisible
# in the command text -- two unguarded recursive greps ran that way while this gate was
# live and correct (2026-09-16). Append the referenced scratch scripts' contents; the
# newline->';' normalisation below treats each of their lines as a command.
. "$HOME/.claude/hooks/lib-scan-script-refs.sh" 2>/dev/null && command="$command
$(scan_referenced_scripts "$command")"

# Normalize before matching. Two problems at once:
#
# 1) grep -P's ^/$ anchor to EACH line, not the whole string. Confirmed false positive:
#    a commit message documenting this very hook (prose mentioning "grep -rn") got
#    denied because that example line's own start satisfied "^".
# 2) The original fix for (1) flattened newlines to SPACES, which silently opened three
#    bypasses -- a recursive grep on the 2nd line of a multi-line command, inside a
#    `for ... do ... done` body, or inside $( ) was preceded by a plain space, matched
#    no separator, and sailed through. That is how a 6.1GB grep.exe got past this gate
#    (session 9149fa95, 2026-09-15 -- free RAM to 0.6GB, machine unresponsive).
#
# So: drop QUOTED SPANS instead of flattening -- a grep in prose lives inside a commit
# message's quotes, a real invocation does not -- then turn newlines into ';', which is
# what a newline actually IS between commands. Keeps (1) fixed, closes (2). A real
# grep's own pattern is quoted too, but only its FLAGS are tested below, so losing the
# pattern is harmless.
# tr -d '\r' first: jq -r emits CRLF here and grep -P treats bare \r as a line
# boundary (PCRE ANYCRLF) -- see git-commit-scope-gate.sh, same fix.
flat="$(printf '%s' "$command" | tr -d '\r' \
  | sed -E 's/"[^"]*"/ /g; s/'"'"'[^'"'"']*'"'"'/ /g' \
  | tr '\n' ';')"

# Separator class: start-of-string, ;/&/|, &&, and an opening ( or $( so a grep inside
# a subshell or command substitution counts as a real invocation.
_sep='(^|[;&|(]|&&|\$\()'

# Must be an actual grep invocation, not just the word "grep" somewhere in the command.
printf '%s' "$flat" | grep -qP "${_sep}\s*grep\b" || exit 0

# Recursive flag present? -r/-R as a standalone or packed short-opt (-rn, -rli, etc),
# or --recursive -- anywhere in that grep's args, not just first (`grep -n -r`, `--include=x -I`).
printf '%s' "$flat" | grep -qP "${_sep}\s*grep\b[^;&|]*\s(-[a-zA-Z]*[rR][a-zA-Z]*\b|--recursive\b)" || exit 0

# Already has -I (standalone or packed, e.g. -rI, -Ir)? Allow through.
printf '%s' "$flat" | grep -qP "${_sep}\s*grep\b[^;&|]*\s-[a-zA-Z]*I[a-zA-Z]*\b" && exit 0

jq -cn '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: "Recursive grep missing -I (binary-skip) -- confirmed real incident TWICE, grep.exe hit ~2GB then ~6GB RAM buffering a binary file as one giant line. Prefer the Grep tool instead (ripgrep-backed, skips binaries automatically). If a raw grep is genuinely needed: add -I, and see the grep-usage skill for scoping (--exclude-dir/--include, narrow the target directory)."
  }
}'
