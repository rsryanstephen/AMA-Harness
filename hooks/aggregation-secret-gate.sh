#!/usr/bin/env bash
# PreToolUse hook (Bash/PowerShell). Blocks an invocation of
# get-aggregation-connection.sh whose output isn't consumed -- i.e. the shape whose
# `export PGPASSWORD=...` line lands in the transcript. ama-postgres-access's prose
# "never print the resolved value" rule failed in practice (a live credential got
# printed while testing the script), so this is the mechanical version, same pattern
# as bare-cd-gate.sh.
#
# Allows: `eval "$(... get-aggregation-connection.sh qa)"` (the prescribed form -- the
# secret goes into env, never stdout), assignment into a variable, a pipe into another
# command, and redirection to a file or /dev/null. Only the bare, output-to-transcript
# shape is denied.
set -u

IFS= read -r -d '' payload || true
# Hoisted needle check onto the RAW payload, before the jq fork -- same needle the
# command-level case below already used, just moved above the only exec on the common
# path so a non-matching call exits on zero forks (~60ms/fork on this machine).
case "$payload" in
  *get-aggregation-connection.sh*) : ;;
  *) exit 0 ;;
esac

command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"

[ -n "$command" ] || exit 0

case "$command" in
  *get-aggregation-connection.sh*) : ;;
  *) exit 0 ;;
esac

# Flatten newlines so a multi-line script is matched as one string, same idiom as
# bare-cd-gate.sh.
flat="$(printf '%s' "$command" | tr '\n' ';')"

# Consumed if the invocation is inside a command substitution feeding eval/export/a
# variable assignment, or is piped/redirected somewhere. Deliberately generous: a false
# ALLOW here just means the pre-existing prose rule applies, while a false DENY blocks
# legitimate use of the documented path.
case "$flat" in
  *eval*get-aggregation-connection.sh*) exit 0 ;;
  *=*'$('*get-aggregation-connection.sh*) exit 0 ;;
  *get-aggregation-connection.sh*'|'*) exit 0 ;;
  *get-aggregation-connection.sh*'>'*) exit 0 ;;
esac

jq -cn '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: "This runs get-aggregation-connection.sh without consuming its output, so its `export PGPASSWORD=...` line would print the live DB password into the transcript. Use the documented form instead, which puts the secret in env and prints nothing: `eval \"$(bash ~/.claude/skills/ama-postgres-access/scripts/get-aggregation-connection.sh qa)\"`. Only inspecting the host/user/db (no password)? Pipe it: `... | grep -v PGPASSWORD`. Querying the aggregation DB at all? Prefer `rs-query.sh` -- it uses the redshift-data API and involves no password whatsoever."
  }
}'
