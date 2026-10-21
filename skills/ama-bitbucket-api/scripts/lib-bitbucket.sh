#!/usr/bin/env bash
# Sourced by the ama-bitbucket-api scripts. Auth is BASIC (email:token), never Bearer --
# a Bearer header against api.bitbucket.org 401s identically to a bad token.
. "$HOME/.claude/hooks/lib-harness-repos.sh"
BB_ORG="$(hr_config_required '.bitbucket.org')" || exit 1
BB_EMAIL="${BITBUCKET_EMAIL:-$(hr_config '.user.email' '')}"
[ -n "$BB_EMAIL" ] || { echo "user.email not set in harness-config.json" >&2; exit 1; }
: "${BITBUCKET_API_KEY:?BITBUCKET_API_KEY is not set}"
BB_API="https://api.bitbucket.org/2.0/repositories/$BB_ORG"

bb_get()  { curl -sS -u "$BB_EMAIL:$BITBUCKET_API_KEY" "$@"; }
bb_post() { curl -sS -u "$BB_EMAIL:$BITBUCKET_API_KEY" -X POST -H "Content-Type: application/json" "$@"; }

# bb_slug <repo-or-slug-or-dir> -- a folder name (api-testing), a slug (<repository>-api-testing)
# or a directory all resolve to the Bitbucket slug.
bb_slug() {
  local a="$1"
  if [ -d "$a" ]; then bash "$HOME/.claude/hooks/lib-harness-repos.sh" slug "$a" 2>/dev/null; return; fi
  case "$a" in yourproduct-*) printf '%s' "$a"; return ;; esac
  local p; p="$(bash "$HOME/.claude/hooks/lib-harness-repos.sh" path "$a" 2>/dev/null)"
  [ -n "$p" ] && bash "$HOME/.claude/hooks/lib-harness-repos.sh" slug "$p" 2>/dev/null || printf '%s' "$a"
}

# bb_enc_uuid {uuid} -> %7Buuid%7D  (the braces must be URL-encoded in a path segment)
bb_enc_uuid() { printf '%s' "$1" | sed 's/{/%7B/; s/}/%7D/'; }

# bb_junit <slug> <pipeline-uuid> -- prints "total=N passed=N failed=N errors=N skipped=N"
# summed across the pipeline's steps, then one line per FAILED/ERROR test case.
bb_junit() {
  local slug="$1" pu; pu="$(bb_enc_uuid "$2")"
  local steps; steps="$(bb_get "$BB_API/$slug/pipelines/$pu/steps/?pagelen=50" | jq -r '.values[]?.uuid')"
  local t=0 p=0 f=0 e=0 s=0 su r
  for su in $steps; do
    r="$(bb_get "$BB_API/$slug/pipelines/$pu/steps/$(bb_enc_uuid "$su")/test_reports" 2>/dev/null)"
    printf '%s' "$r" | jq -e '.number_of_test_cases' >/dev/null 2>&1 || continue
    t=$((t + $(printf '%s' "$r" | jq -r '.number_of_test_cases // 0')))
    p=$((p + $(printf '%s' "$r" | jq -r '.number_of_successful_test_cases // 0')))
    f=$((f + $(printf '%s' "$r" | jq -r '.number_of_failed_test_cases // 0')))
    e=$((e + $(printf '%s' "$r" | jq -r '.number_of_error_test_cases // 0')))
    s=$((s + $(printf '%s' "$r" | jq -r '.number_of_skipped_test_cases // 0')))
    if [ "$(printf '%s' "$r" | jq -r '(.number_of_failed_test_cases // 0) + (.number_of_error_test_cases // 0)')" -gt 0 ]; then
      bb_get "$BB_API/$slug/pipelines/$pu/steps/$(bb_enc_uuid "$su")/test_reports/test_cases?pagelen=100" \
        | jq -r '.values[]? | select(.status != "PASSED" and .status != "SKIPPED") | "  FAILED  \(.fully_qualified_name // .name)"'
    fi
  done
  printf 'total=%s passed=%s failed=%s errors=%s skipped=%s\n' "$t" "$p" "$f" "$e" "$s"
}
