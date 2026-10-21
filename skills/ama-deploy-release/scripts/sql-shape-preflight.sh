#!/usr/bin/env bash
# release-preflight.sh section 5: for every SQL-emitting app whose release/hotfix branch changes
# the SQL it emits (lib-sql-emitting-paths.sh: builder/template paths, or a Search.Shared pin
# bump), EXPLAIN every query shape the Staging build logged, and name shapes it never ran.
# Usage: sql-shape-preflight.sh <release/X.Y.Z|hotfix/X.Y.Z> [--inventory-hours N] [--changed-only]
# Exit 0 = clean or nothing to sweep | 1 = FAIL / MISSING / could not sweep (each a preflight issue).
# --changed-only: list the apps whose branch changes emitted SQL, sweep nothing; exit 0 = some, 3 = none
#   (release-preflight.sh --hotfix uses it to decide whether to run the api-testing Shapes subset).
#
# Why: PROJ-15416 was verified on one query shape and shipped five follow-up defects in
# shapes that wrap the same select list (15801 reached a client). See
# ama-debugging-notes/SHARED-CHOKEPOINT-CHANGES.md. The sweep only counts if Staging runs a build
# OF THIS BRANCH -- otherwise it would test some other branch's SQL, so that is checked first.
set -uo pipefail
BR="${1:?usage: sql-shape-preflight.sh <release/X.Y.Z|hotfix/X.Y.Z> [--inventory-hours N]}"; shift
INVH=336; CHANGED_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in --inventory-hours) INVH="${2:?}"; shift 2 ;; --changed-only) CHANGED_ONLY=1; shift ;; *) echo "unknown arg $1" >&2; exit 2 ;; esac
done
. "$HOME/.claude/hooks/lib-sql-emitting-paths.sh"
SK="$HOME/.claude/skills"
# slug : Graylog application : ECS service (staging). Add a row when another app emits report SQL.
APPS="search:product-service-search-api:staging-v1-search-api-isvc
resultsprocessor:product-service-resultsprocessor-api:staging-v1-resultsprocessor-api-esvc"

rc=0; changed=0
while IFS=: read -r slug app svc; do
  repo="$(bash "$HOME/.claude/hooks/lib-harness-repos.sh" path "$slug" 2>/dev/null)" || { echo "$slug: repo not found -- skipped"; continue; }
  git -C "$repo" fetch -q origin 2>/dev/null
  git -C "$repo" rev-parse -q --verify "origin/$BR" >/dev/null || { echo "$slug: no $BR -- not in this release"; continue; }
  m="$(sql_emitting_diff "$repo" origin/master "origin/$BR")"
  [ -n "$m" ] || { echo "$slug: $BR emits no new SQL -- skipped"; continue; }
  echo "$slug: $BR changes emitted SQL ($(printf '%s' "$m" | paste -sd, ))"
  [ "$CHANGED_ONLY" = 1 ] && { changed=1; continue; }
  arns="$(aws ecs list-tasks --cluster staging-v1-AMA --service-name "$svc" --desired-status RUNNING --query 'taskArns' --output text 2>/dev/null | tr -d '\r')"
  # shellcheck disable=SC2086
  ver="$(PYTHONUTF8=1 aws ecs describe-tasks --cluster staging-v1-AMA --tasks $arns --output json 2>/dev/null \
    | jq -r '[.tasks[].containers[0].image | sub(".*:"; "")] | unique | if length == 1 then .[0] else "MIXED" end' | tr -d '\r')"
  case "$ver" in ''|MIXED|null) echo "  could not sweep: $svc running image is '${ver:-none}' (rollout in progress?)"; rc=1; continue ;; esac
  built="$(bash "$SK/ama-bitbucket-api/scripts/pipeline-build.sh" "$slug" "${ver##*.}" 2>/dev/null | grep -oE 'branch=[^ ]+' | cut -d= -f2)"
  if [ "$built" != "$BR" ]; then
    echo "  could not sweep: Staging runs $ver, built from '${built:-?}', not $BR -- redeploy $BR to Staging first"; rc=1; continue
  fi
  out="$(bash "$SK/ama-postgres-access/scripts/rs-explain-shapes.sh" "graylog:$app:staging" --build "$ver" --hours 168 --inventory-hours "$INVH" 2>&1)"; src=$?
  printf '%s\n' "$out" | sed 's/^/  /'
  case "$src" in
    0) : ;;
    3) echo "  -> shapes never run on $ver: run the Staging \`main\` cache update / drive those reports, then re-run"; rc=1 ;;
    *) rc=1 ;;
  esac
done <<< "$APPS"
[ "$CHANGED_ONLY" = 1 ] && exit $(( changed ? 0 : 3 ))
exit "$rc"
