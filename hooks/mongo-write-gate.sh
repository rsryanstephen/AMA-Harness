#!/usr/bin/env bash
# dispatch: fail-closed-on-timeout-unless-nonprod -- timeout denies unless the text names only qa/staging (hooks/dispatch.sh).
# PreToolUse hook (Bash|PowerShell). Guards WRITES to the DocumentDB clusters. The tunnel
# (ama-mongo-access/docdb-query.sh) authenticates with the app's own READ-WRITE creds and
# there is no DB-level safety net -- the script's header says so itself; until this gate,
# read-only was convention, not enforcement. <harnessEpicKey>.
#
# Decisions:
#  - Write eval against `docdb-query.sh production` -> DENY. Prod data mutations don't go
#    through the harness. Escape hatch AMA_ALLOW_PROD_MONGO_WRITE=1, deliberately an env
#    var the USER sets (same lesson as prod-api-test-window-gate.sh: an "approved" marker
#    the agent can emit itself is no signal at all). Read from the hook's OWN process env,
#    so an inline `VAR=1 bash ...` prefix in a Bash tool call never reaches it -- deliberate.
#  - Any other Mongo write (qa/staging, or a raw mongosh/mongoimport/mongorestore where
#    the env can't be read off the command) -> DENY with its own hatch,
#    AMA_ALLOW_MONGO_WRITE=1 (does NOT unlock production). Deny-plus-hatch over "ask"
#    deliberately: a hatch re-run is an explicit approval that behaves identically in
#    every permission mode and leaves the approval visible in the transcript, where an
#    ask's y/n leaves no trace of what exactly was approved. For a data mutation that
#    audit trail is the point.
#  - Reads (find/countDocuments/getCollectionNames/plain aggregate) pass silently.
#
# Write detection wants `(` right after the method name, so a collection merely NAMED
# after a verb (`db.updates.find()`) doesn't trip it. Heredoc bodies are data, not
# commands -- only the region before the first `<<` is measured (same scoping as
# graylog-write-gate.sh, which this gate is modeled on).
set -u

payload="$(cat)"

# Cheap needle on the raw payload before any jq fork (precedent: graylog-write-gate.sh).
# The scratch/scratchpad arms are NOT redundant: `bash scratch/foo.sh` names no Mongo tool at
# all, and exiting here is exactly how the script-file bypass used to get through. They only
# buy a file read; the real needle below still runs on the resolved text.
case "$payload" in
  *docdb-query.sh*|*mongosh*|*mongoimport*|*mongorestore*) : ;;
  *scratch*|*Temp/claude*|*Temp\\\\claude*|*temp/claude*) : ;;
  *) exit 0 ;;
esac

# ONE jq fork, not two. Forks are what kill a gate on this host -- see psql-write-gate.sh's
# note: a gate that exceeds its timeout is killed mid-run and the call goes through
# unguarded, silently. Keep both DB gates fork-free past this point.
# Whitespace-tolerant: live payloads are compact, check-gates' are pretty-printed.
# `[[ ]]`, not a second `case`: build-needle-cache.sh ORs every `case "$payload"` block into
# the dispatch needle, and this alternative matches every Bash payload -- it made the needle
# above useless and spawned this gate on ~93% of Bash calls (<harnessEpicKey>, 2026-10-12).
[[ $payload == *'"tool_name"'*'"Bash"'* || $payload == *'"tool_name"'*'"PowerShell"'* ]] || exit 0
# Emit the command RAW -- never `@tsv` for a pair of fields: it escapes backslashes too, so
# Windows paths come back doubled (see psql-write-gate.sh's note).
command="$(printf '%s' "$payload" | jq -r '.tool_input.command // ""' 2>/dev/null)"
[ -n "$command" ] || exit 0

. "$HOME/.claude/hooks/lib-command-text.sh" 2>/dev/null || command_scan_region() { printf '%s' "$1"; }
head_region="$(command_scan_region "$command")"

# A write hidden in `bash scratch/foo.sh` shows this gate nothing. Pull in the contents of
# any scratch/scratchpad script the command runs and judge on those too. Script contents are
# appended WHOLE -- no heredoc scoping, because inside a script the heredoc body is the code
# (that is where the eval, and so the write, actually lives).
# shellcheck source=/dev/null
. "$HOME/.claude/hooks/lib-scan-script-refs.sh" 2>/dev/null || true
if command -v scan_referenced_scripts >/dev/null 2>&1; then
  head_region="$head_region
$(scan_referenced_scripts "$head_region")"
fi

# The needle must hold in the HEAD region too -- a commit message merely describing a
# mongosh eval lives in a heredoc body and is none of this gate's business.
case "$head_region" in
  *docdb-query.sh*|*mongosh*|*mongoimport*|*mongorestore*) : ;;
  *) exit 0 ;;
esac

WRITE_METHODS='insert|insertOne|insertMany|update|updateOne|updateMany|replaceOne|deleteOne|deleteMany|remove|drop|dropDatabase|dropIndex|dropIndexes|createIndex|createIndexes|createCollection|renameCollection|findOneAndUpdate|findOneAndReplace|findOneAndDelete|findAndModify|bulkWrite|save'

matched_op=''
if [[ $head_region =~ \.(${WRITE_METHODS})[[:space:]]*\( ]]; then
  matched_op="${BASH_REMATCH[1]}"
else
  # $out/$merge make an aggregate a write; mongoimport/mongorestore are writes by nature
  # (matched at a command position so prose about them in an argument doesn't count).
  if [[ $head_region =~ \$(out|merge)([^a-zA-Z0-9_]|$) ]]; then
    matched_op='aggregate with $out/$merge'
  elif [[ $head_region =~ (^|[\|\;\&[:space:]])(mongoimport|mongorestore)([^a-zA-Z0-9_]|$) ]]; then
    matched_op="${BASH_REMATCH[2]}"
  fi
fi
[ -n "$matched_op" ] || exit 0

if [[ $head_region =~ docdb-query\.sh[\"\']?[[:space:]]+[\"\']?production ]]; then
  [ "${AMA_ALLOW_PROD_MONGO_WRITE:-}" = "1" ] && exit 0
  jq -cn --arg op "$matched_op" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: ("Mongo write (" + $op + ") against the PRODUCTION DocumentDB cluster. The tunnel uses the application'\''s own read-write credentials with no DB-level read-only enforcement (ama-mongo-access/SKILL.md) -- production data mutations do not go through this harness. If the user has explicitly instructed this specific write, the hatch is AMA_ALLOW_PROD_MONGO_WRITE=1 set in the environment Claude Code was LAUNCHED from (or settings.json env), then re-run -- an inline `AMA_ALLOW_PROD_MONGO_WRITE=1 bash ...` prefix in the Bash tool never reaches this gate, which reads its own process env.")
    }
  }'
  exit 0
fi

[ "${AMA_ALLOW_MONGO_WRITE:-}" = "1" ] && exit 0
jq -cn --arg op "$matched_op" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: ("Mongo WRITE operation (" + $op + ") stopped -- DocumentDB access here runs on the application'\''s read-write credentials with no DB-level read-only enforcement (ama-mongo-access/SKILL.md), so writes need explicit human approval per attempt. If the user has approved this specific write, the hatch is AMA_ALLOW_MONGO_WRITE=1 set in the environment Claude Code was LAUNCHED from (or settings.json env), then re-run -- an inline `AMA_ALLOW_MONGO_WRITE=1 bash ...` prefix in the Bash tool never reaches this gate, which reads its own process env (production has its own separate hatch). Reads (find/countDocuments/getCollectionNames/plain aggregate) are never blocked.")
  }
}'
exit 0
