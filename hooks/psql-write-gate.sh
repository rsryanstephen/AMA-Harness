#!/usr/bin/env bash
# dispatch: fail-closed-on-timeout-unless-nonprod -- timeout denies unless the text names only qa/staging (hooks/dispatch.sh).
# PreToolUse hook (Bash|PowerShell). Guards WRITES to the fleet's Postgres/RDS databases,
# the sibling of mongo-write-gate.sh. <harnessEpicKey>.
#
# Why it exists: ama-postgres-access resolves the APPLICATION's own connection string off
# the live ECS task definition -- including `production-v1-reports-api` -- so a psql session
# here holds read-write credentials against production app data, with no DB-level safety net
# and, until this gate, no friction whatsoever. The skill even documents a production
# single-row datafix recipe. (Redshift is the exception and needs no guarding: `ama_qa`/
# `ama_staging`/`ama_production` are read-only DB roles, enforced at the database.)
#
# Decisions, mirroring mongo-write-gate.sh:
#  - Write whose text names production -> DENY, hatch AMA_ALLOW_PROD_PG_WRITE=1.
#  - Any other psql write -> DENY, hatch AMA_ALLOW_PG_WRITE=1 (does NOT unlock production).
#  - Reads (SELECT, \dt, \dn, \d) pass silently.
#
# COVERS `pg-connect.sh` BY NAME, not just `psql` (added 2026-09-18). The skill's own entry
# point names no psql on the command line, so until now every write routed through the
# documented path -- including a production DELETE -- passed this gate in silence. Replayed
# before the fix, silent; after, denied. Mongo's sibling always named `docdb-query.sh`; this
# one was written before `pg-connect.sh` existed and nobody re-pointed it when it shipped.
# Both hatches are env vars the USER sets: an "approved" marker the agent can emit itself is
# no signal at all (same reasoning as prod-api-test-window-gate.sh). The hook reads its OWN
# process env, so an inline `VAR=1 bash ...` prefix in a Bash tool call never reaches it --
# deliberate (hit twice 2026-10-05, PROJ-15459; the deny text now says so).
#
# ENVIRONMENT DETECTION IS BEST-EFFORT HERE, and deliberately fails towards the generic
# denial rather than towards allowing. Unlike Mongo -- where the env is a literal argument to
# docdb-query.sh -- the psql recipe writes host/user/password into a temp env file in an
# EARLIER, separate tool call, so the psql command itself often names no environment at all.
# That is why the generic branch denies too instead of passing anything it cannot classify.
set -u

payload="$(cat)"

# Cheap needle before any jq fork. The scratch/scratchpad arms are not redundant:
# `bash scratch/foo.sh` names no psql at all -- that shape is the whole reason this gate and
# its Mongo sibling scan script files (see lib-scan-script-refs.sh).
case "$payload" in
  *psql*|*pg_restore*|*pg-connect.sh*) : ;;
  *scratch*|*Temp/claude*|*Temp\\\\claude*|*temp/claude*) : ;;
  *) exit 0 ;;
esac

# ONE jq fork, and it emits the command RAW. The tool name is a pure-bash needle instead of
# a second fork. Do NOT go back to `@tsv` for the pair: @tsv escapes backslashes as well as
# tabs, so every Windows path in the command comes back doubled -- `-f C:\Users\...\fix.sql`
# then fails its `[ -f ]` test and the write inside that file is never seen. Fixtures using
# forward slashes cannot catch it; check-gates pins a backslash path for exactly this.
# Tolerate whitespace after the key -- the live payload is compact, check-gates' fixtures are
# pretty-printed, and a needle pinned to one spelling passes the suite while missing reality
# (or the reverse, which is how this was caught).
# `[[ ]]`, not a second `case`: build-needle-cache.sh ORs every `case "$payload"` block into
# the dispatch needle, and this alternative matches every Bash payload -- it made the needle
# above useless and spawned this gate on ~93% of Bash calls (<harnessEpicKey>, 2026-10-12).
[[ $payload == *'"tool_name"'*'"Bash"'* || $payload == *'"tool_name"'*'"PowerShell"'* ]] || exit 0
command="$(printf '%s' "$payload" | jq -r '.tool_input.command // ""' 2>/dev/null)"
[ -n "$command" ] || exit 0

# Heredoc bodies on the COMMAND LINE are data (a commit message describing a datafix is none
# of this gate's business). Script CONTENTS are appended whole -- there the heredoc body is
# the code, and that is where the SQL lives.
. "$HOME/.claude/hooks/lib-command-text.sh" 2>/dev/null || command_scan_region() { printf '%s' "$1"; }
head_region="$(command_scan_region "$command")"

# shellcheck source=/dev/null
. "$HOME/.claude/hooks/lib-scan-script-refs.sh" 2>/dev/null || true
if command -v scan_referenced_scripts >/dev/null 2>&1; then
  head_region="$head_region
$(scan_referenced_scripts "$head_region")"
fi

# `pg-connect.sh -f <file>` puts the SQL in a file and nothing in argv, so the write verb is
# invisible above. lib-scan-script-refs.sh only reads scratch/scratchpad paths (deliberate --
# see its header), and a query file legitimately lives anywhere, so read the one file this
# command explicitly names. Nothing arbitrary: the token has to follow `-f` on a pg-connect.sh
# command line. Without this the documented long-query form is a blanket bypass.
case "$head_region" in
  *pg-connect.sh*)
    sqlfile=''
    [[ $head_region =~ pg-connect\.sh[^\|\;\&]*-f[[:space:]]+([^[:space:]\|\;\&]+) ]] && sqlfile="${BASH_REMATCH[1]}"
    sqlfile="${sqlfile%\"}"; sqlfile="${sqlfile#\"}"; sqlfile="${sqlfile%\'}"; sqlfile="${sqlfile#\'}"
    case "$sqlfile" in
      '$HOME'/*)   sqlfile="$HOME/${sqlfile#\$HOME/}" ;;
      '${HOME}'/*) sqlfile="$HOME/${sqlfile#\$\{HOME\}/}" ;;
      '~'/*)       sqlfile="$HOME/${sqlfile#\~/}" ;;
    esac
    case "$sqlfile" in
      ''|*'$'*|*'`'*|*'*'*|*'?'*) : ;;
      *) [ -f "$sqlfile" ] && head_region="$head_region
$(head -c 65536 "$sqlfile" 2>/dev/null)" ;;
    esac
    ;;
esac

# The resolved text must INVOKE psql/pg_restore/pg-connect.sh, not merely name a file that
# contains the word: `git add hooks/psql-write-gate.sh confluence-update-page.sh` was denied
# as a Postgres UPDATE (2026-10-20). psql/pg_restore = a command word (next char is space,
# quote, operator or end, so `psql-write-gate.sh` is out, `Q=psql;` is in); pg-connect.sh =
# run by bash/sh, in command position (start, or after ; & | ( ), or the VALUE of an
# assignment (`export P=.../pg-connect.sh; bash $P ...` -- variable-held paths are the style
# bare-cd-gate steers sessions into; a git-add filename is never preceded by `=`).
I_cmd='(^|[^a-z0-9_.-])(psql|pg_restore)([[:space:]"'\'';&|)]|$)'
I_pgc='((^|[;&|(])[[:space:]]*|(bash|sh)[[:space:]]+|=["'\'']?)[^[:space:];&|]*pg-connect\.sh'
lc_inv="${head_region,,}"
[[ $lc_inv =~ $I_cmd || $lc_inv =~ $I_pgc ]] || exit 0

# Write detection. Anchored to statement shape rather than the bare verb, so a SELECT over a
# column or table merely NAMED for one ("updated_at", "deleted_flag") doesn't trip it.
#
# Bash's own =~, NOT ten `printf | grep -qiE` pipelines. Those cost more than this gate's own
# 15s timeout on this host (measured 12-22s, ~1s per fork under Sysmon/Intune), so the CLI
# killed it mid-run and the call went through UNGUARDED -- a silent fail-open that looks
# exactly like a pass. Live-proven 2026-09-18: a `pg-connect.sh qa reports 'update ...'` ran
# while the same payload replayed straight into the gate denied. Keep this gate fork-free.
# Bash ERE has no \b, so word edges are spelled out.
lc="${head_region,,}"
B='(^|[^a-z0-9_])'; E='([^a-z0-9_]|$)'
matched_op=''
if   [[ $lc =~ ${B}insert[[:space:]]+into${E} ]];  then matched_op='INSERT'
elif [[ $lc =~ ${B}update${E}[^\;]+${B}set${E} ]]; then matched_op='UPDATE'
elif [[ $lc =~ ${B}delete[[:space:]]+from${E} ]];  then matched_op='DELETE'
elif [[ $lc =~ ${B}truncate${E} ]];                then matched_op='TRUNCATE'
elif [[ $lc =~ ${B}drop[[:space:]]+(table|database|schema|index|view|column|role|user)${E} ]];  then matched_op='DROP'
elif [[ $lc =~ ${B}alter[[:space:]]+(table|database|schema|role|user|sequence)${E} ]];          then matched_op='ALTER'
elif [[ $lc =~ ${B}create[[:space:]]+(table|database|schema|index|view|role|user)${E} ]];       then matched_op='CREATE'
elif [[ $lc =~ ${B}(grant|revoke)[[:space:]] ]];   then matched_op='GRANT/REVOKE'
elif [[ $lc =~ ${B}copy${E}[^\;]+${B}from${E} ]];  then matched_op='COPY ... FROM'
elif [[ $lc =~ (^|[\|\;\&[:space:]])pg_restore${E} ]]; then matched_op='pg_restore'
fi
[ -n "$matched_op" ] || exit 0

# Best-effort environment read -- see the header. Matches the task-def/host naming the skill
# actually uses (`production-v1-<repo>-api`, `production_v4_...`, `*-production-rs.*`).
if [[ $lc == *production* || $lc == *prod-v1* || $lc == *prod_v1* ]]; then
  [ "${AMA_ALLOW_PROD_PG_WRITE:-}" = "1" ] && exit 0
  jq -cn --arg op "$matched_op" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: ("Postgres write (" + $op + ") and the command names PRODUCTION. ama-postgres-access connects with the application'\''s own read-write credentials from the production ECS task definition -- there is no DB-level read-only enforcement, so production data mutations do not go through this harness unattended. If the user has explicitly instructed this specific write, the hatch is AMA_ALLOW_PROD_PG_WRITE=1 set in the environment Claude Code was LAUNCHED from (or settings.json env), then re-run -- an inline `AMA_ALLOW_PROD_PG_WRITE=1 bash ...` prefix in the Bash tool never reaches this gate, which reads its own process env.")
    }
  }'
  exit 0
fi

[ "${AMA_ALLOW_PG_WRITE:-}" = "1" ] && exit 0
jq -cn --arg op "$matched_op" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: ("Postgres WRITE operation (" + $op + ") stopped -- psql access here runs on the application'\''s read-write credentials with no DB-level read-only enforcement, and the environment cannot be read off this command (the connection lives in an env file built earlier), so it could be any environment including production. If the user has approved this specific write, the hatch is AMA_ALLOW_PG_WRITE=1 set in the environment Claude Code was LAUNCHED from (or settings.json env), then re-run -- an inline `AMA_ALLOW_PG_WRITE=1 bash ...` prefix in the Bash tool never reaches this gate, which reads its own process env (production has its own separate hatch, AMA_ALLOW_PROD_PG_WRITE=1). Reads (SELECT, \\dt, \\dn) are never blocked.")
  }
}'
exit 0
