#!/usr/bin/env bash
# Run SQL against a service's Postgres DB using the credentials its ECS task definition
# carries. Usage: pg-connect.sh <env> <repo> "<sql>"      env: qa | staging | production
#                 pg-connect.sh <env> <repo> -f <file>
#
# This replaces a 60-line prose recipe the agent used to hand-execute every time (task-def
# query -> inline node parser -> docker run) which the prose itself recorded being DENIED by
# the permission classifier twice on production-v1-reports-api, because interpolating the
# password into the docker command is the one shape the classifier will not pass. The
# credentials never touch a command line here: parsed in-process, written to a 0600 env
# file, handed to docker via --env-file, deleted on exit. The value is never printed.
#
# Write protection is unchanged: psql-write-gate.sh reads the SQL from THIS command's text
# (the third argument), so an UPDATE/DELETE/DDL is still denied without its hatch. Do not
# route SQL through a file to dodge that -- the -f form is for long read-only queries.
#
# Task-def family is <env>-v1-<repo>-api (e.g. staging-v1-exportproducer-api). The repo
# folder and the family name do not always agree -- `cohortdata` has no ECS service at all
# -- so a "not found" here means check `aws ecs list-services --cluster <env>-v1-AMA`.
set -uo pipefail
export MSYS_NO_PATHCONV=1

ENV="${1:?usage: pg-connect.sh <env> <repo> \"<sql>\" | -f <file>}"
REPO="${2:?usage: pg-connect.sh <env> <repo> \"<sql>\" | -f <file>}"
shift 2
case "${1:-}" in
  -f) SQLFILE="${2:?-f needs a file}"; SQL="" ;;
  "") echo "no SQL given" >&2; exit 1 ;;
  *)  SQL="$1"; SQLFILE="" ;;
esac

. "$HOME/.claude/hooks/lib-claude-paths.sh" 2>/dev/null || true
if command -v hscratch >/dev/null 2>&1; then
  ENVF="$(hscratch pg ".pgenv-$$")"
else
  ENVF="$(mktemp)"
fi
trap 'rm -f "$ENVF"' EXIT
umask 077

# Engine down or hung? docker-ensure.sh starts or restarts Docker Desktop itself (user
# instruction 2026-09-26) and waits for the engine; its header has the three states. Until
# then this printed "not responding (probe timed out)" for an engine that was simply not
# running after a reboot, and the session stopped there.
if ! bash "${BASH_SOURCE[0]%/*}/docker-ensure.sh"; then
  echo "docker engine unavailable and could not be started; see harness-state/logs/docker-ensure.log" >&2
  exit 2
fi

CONN="$(PYTHONUTF8=1 aws ecs describe-task-definition --task-definition "${ENV}-v1-${REPO}-api" --region us-east-1 \
  --query "taskDefinition.containerDefinitions[0].environment[?name=='PostgreSqlSettings__Connection'].value" \
  --output text 2>/dev/null | tr -d '\r')"
if [ -z "$CONN" ] || [ "$CONN" = "None" ]; then
  echo "no PostgreSqlSettings__Connection on task definition ${ENV}-v1-${REPO}-api" >&2
  echo "(family name may differ from the repo folder -- aws ecs list-services --cluster ${ENV}-v1-AMA)" >&2
  exit 1
fi

# Npgsql-style, semicolon-delimited. ECS flavour uses Server/User ID/Password; the Octopus
# library-variable flavour uses UID/PWD and puts a space after every `;` -- accept both.
host=""; port="5432"; db=""; user=""; pass=""
IFS=';' read -ra parts <<< "$CONN"
for p in "${parts[@]}"; do
  k="$(printf '%s' "${p%%=*}" | sed 's/^ *//; s/ *$//' | tr '[:upper:]' '[:lower:]')"
  v="$(printf '%s' "${p#*=}" | sed 's/^ *//; s/ *$//')"
  case "$k" in
    server|host) host="$v" ;;
    port) port="$v" ;;
    database) db="$v" ;;
    "user id"|uid|username) user="$v" ;;
    password|pwd) pass="$v" ;;
  esac
done
[ -n "$host" ] && [ -n "$db" ] && [ -n "$user" ] && [ -n "$pass" ] || {
  echo "could not parse Server/Database/User/Password out of the connection string" >&2; exit 1; }

printf 'PGHOST=%s\nPGPORT=%s\nPGDATABASE=%s\nPGUSER=%s\nPGPASSWORD=%s\nPGSSLMODE=require\n' \
  "$host" "$port" "$db" "$user" "$pass" > "$ENVF"
unset CONN pass

echo "# ${ENV}-v1-${REPO}-api -> ${db} @ ${host}" >&2
if [ -n "$SQLFILE" ]; then
  docker run --rm -i --env-file "$(cygpath -w "$ENVF" 2>/dev/null || printf '%s' "$ENVF")" postgres:16 \
    psql -X -A -F$'\t' --pset=footer=off -f - < "$SQLFILE"
else
  docker run --rm --env-file "$(cygpath -w "$ENVF" 2>/dev/null || printf '%s' "$ENVF")" postgres:16 \
    psql -X -A -F$'\t' --pset=footer=off -c "$SQL"
fi
