#!/usr/bin/env bash
# mongo-dump.sh -- READ-ONLY. One JSON document per line for a user's cohorts or cohort reports.
# Usage: mongo-dump.sh <qa|staging|production> <cohort|cohortreport> <username> <out.jsonl> [--include-deleted]
# Output lines are JSON.stringify() of each document (dates as ISO strings, _id as the shell's
# own $binary shape -- udc.py mongo-id normalises it). Default excludes isDeleted:true.
set -uo pipefail
# this box's jq emits CRLF: every jq -r value goes through jr() so no trailing \r leaks into ids, paths or JSON
jr() { jq -r "$@" | tr -d '\r'; }
ENV="${1:?usage: mongo-dump.sh <env> <cohort|cohortreport> <username> <out.jsonl> [--include-deleted]}"
COLL="${2:?}"; USERNAME="${3:?}"; OUT="${4:?}"; INCL="${5:-}"
case "$COLL" in cohort|cohortreport) ;; *) echo "collection must be cohort or cohortreport" >&2; exit 1 ;; esac
[[ "$USERNAME" =~ ^[A-Za-z0-9._@+-]+$ ]] || { echo "bad username" >&2; exit 1; }
DOCDB="$HOME/.claude/skills/ama-mongo-access/scripts/docdb-query.sh"
filter="{user: \"$USERNAME\"}"
[ "$INCL" = "--include-deleted" ] || filter="{user: \"$USERNAME\", isDeleted: {\$ne: true}}"
JS="var c = db.getSiblingDB('cohort'); c.$COLL.find($filter).forEach(function(d){ print('DOC|' + JSON.stringify(d)); });"
bash "$DOCDB" "$ENV" "$JS" 2>"$OUT.err" | grep '^DOC|' | cut -d'|' -f2- > "$OUT"
n="$(wc -l < "$OUT" | tr -d ' ')"
echo "mongo-dump: $n $COLL docs for $USERNAME ($ENV) -> $OUT" >&2
[ -s "$OUT.err" ] && grep -viE 'Hostname: host.docker.internal|^$' "$OUT.err" | head -3 >&2
exit 0
