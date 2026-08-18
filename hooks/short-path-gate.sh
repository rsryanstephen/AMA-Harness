#!/usr/bin/env bash
# PreToolUse hook (Bash/PowerShell). Denies a command containing an 8.3 SHORT path segment
# (`RYAN~1.STE`, `PROGRA~1`). Claude Code's static analysis flags the tilde ("Tilde in
# assignment value -- bash may expand at assignment time"), refuses to delegate the call to
# the auto-approval classifier, and falls back to a manual permission prompt. A PreToolUse
# deny fires before that prompt, so the agent self-corrects instead of a human clicking Yes.
#
# Where the short form comes from: TEMP/TMP on this machine were
# C:\Users\RYAN~1.STE\AppData\Local\Temp, so every scratchpad path Claude Code injects
# carried it, and any command quoting that path tripped the guard. The ROOT fix is
# long-form TEMP/TMP (see bash-command-style) -- it only takes effect for sessions started
# after the change, and it does nothing about a short path typed from any other source, so
# this gate stays useful either way.
#
# Long and short forms name the SAME directory, so rewriting is always safe -- there is no
# case where the 8.3 form is required.
set -u

IFS= read -r -d '' payload || true
case "$payload" in *'~'*) ;; *) exit 0 ;; esac

command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"
[ -n "$command" ] || exit 0

# `~<digit>` optionally + `.<1-3 alnum>`, and REQUIRED to be followed by a path separator --
# that trailing separator is what keeps ordinary git revisions out of scope: `HEAD~1`,
# `HEAD~1..HEAD` and `HEAD~2^` never match, nor does `~/`-style home expansion (no digit).
hit="$(printf '%s' "$command" | tr -d '\r' | grep -oP '[A-Za-z0-9_]+~[0-9]+(\.[A-Za-z0-9]{1,3})?(?=[/\\])' | head -1)"
[ -n "$hit" ] || exit 0

jq -cn --arg h "$hit" --arg home "$HOME" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: ("Command contains the 8.3 short path segment `" + $h + "`. Claude Code'"'"'s static analysis treats the tilde as an unresolved expansion, refuses to delegate the call to the auto-approval classifier, and falls back to a MANUAL permission prompt -- every run, including for subagents nobody is watching. Rewrite the path in long form: this session'"'"'s home is " + $home + ", so prefer `$HOME/...` (or the full long-name path) over anything containing `~<digit>`. Both forms name the same directory, so nothing else about the command needs to change. Scratchpad paths are the usual source -- take the long form rather than the injected short one.")
  }
}'
