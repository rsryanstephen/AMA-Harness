#!/usr/bin/env bash
# Live plan-usage read for scripts that will SPEND real tokens unattended (the weekly
# harness-gaps review) and must not start a run the week is already out of budget for.
#
# Source of truth: GET https://api.anthropic.com/api/oauth/usage with the Claude Code OAuth
# access token from ~/.claude/.credentials.json (claudeAiOauth.accessToken) and the
# `anthropic-beta: oauth-2025-04-20` header. Probed live 2026-09-07: returns
# five_hour/seven_day {utilization, resets_at} plus a `limits[]` array whose weekly-group
# entries include a MODEL-SCOPED weekly cap (weekly_scoped, Fable 23% while weekly_all was
# 19%). `weekly` reports the ACCOUNT-WIDE figure (scope null); model caps are reported
# separately by `capped`, so a caller can drop that model instead of skipping the whole run
# (2026-10-12: Fable 100% while account 70% postponed the harness-gaps review a week, though
# Opus had room). UNDOCUMENTED endpoint (community-observed, not in the Claude Code
# docs); every jq read falls back to empty, and callers treat a non-zero return as
# "unknown", never as 0%. Before this, the only place the percentage existed was the
# statusLine stdin payload (hooks/statusline.sh), which goes stale the moment no
# interactive session is rendering -- useless to a 15:00 scheduled task on a quiet day.
#
# Token is read into a variable and put on the curl command line via -H; it is never
# echoed, logged, or written anywhere. Test seam: CLAUDE_USAGE_JSON=<file> skips the
# network and parses that file instead.
set -u

. "$HOME/.claude/hooks/lib-claude-paths.sh"

CLAUDE_USAGE_URL="${CLAUDE_USAGE_URL:-https://api.anthropic.com/api/oauth/usage}"
CLAUDE_CREDS="${CLAUDE_CREDS:-$HOME/.claude/.credentials.json}"

# claude_usage_fetch [out-file] -> writes the raw JSON body to out-file (default: scratch)
# and prints its path. Returns 1 on any failure (no creds, HTTP != 200, body not JSON).
# On an expired/rejected token it runs one trivial `claude -p` so Claude Code refreshes
# .credentials.json itself, then retries once.
claude_usage_fetch() {
  local out="${1:-$(hscratch usage oauth-usage.json)}" tok="" exp="" now code="" tries=0
  if [ -n "${CLAUDE_USAGE_JSON:-}" ]; then
    [ -s "$CLAUDE_USAGE_JSON" ] || return 1
    cp -f "$CLAUDE_USAGE_JSON" "$out" 2>/dev/null || return 1
    printf '%s' "$out"; return 0
  fi
  [ -s "$CLAUDE_CREDS" ] || return 1
  now="$(date +%s)"
  while [ "$tries" -lt 2 ]; do
    tok="$(jq -r '.claudeAiOauth.accessToken // empty' "$CLAUDE_CREDS" 2>/dev/null | tr -d '\r')"
    exp="$(jq -r '.claudeAiOauth.expiresAt // empty' "$CLAUDE_CREDS" 2>/dev/null | tr -d '\r')"
    # expiresAt is epoch MILLISECONDS.
    if [ -n "$tok" ] && { [ -z "$exp" ] || [ "${exp%???}" -gt "$now" ] 2>/dev/null; }; then
      code="$(curl -sS -m 30 -o "$out" -w '%{http_code}' \
        -H "Authorization: Bearer $tok" -H "anthropic-beta: oauth-2025-04-20" \
        -H "Accept: application/json" "$CLAUDE_USAGE_URL" 2>/dev/null)"
      if [ "$code" = "200" ] && jq -e '.seven_day // .limits' "$out" >/dev/null 2>&1; then
        printf '%s' "$out"; return 0
      fi
    fi
    tries=$((tries + 1))
    # Expired or refused: let Claude Code refresh the token (it does so on startup),
    # cheapest model, one turn, output discarded.
    [ "$tries" -lt 2 ] && command -v claude >/dev/null 2>&1 && \
      timeout 120 claude -p "Reply with only the word OK." --model haiku >/dev/null 2>&1 || true
  done
  return 1
}

# claude_usage_weekly [json-file] -> prints "<weekly_pct>\t<weekly_resets_epoch>".
# weekly_pct = max percent over UNSCOPED limits[] where group=="weekly", else seven_day.utilization,
# rounded down to an integer. Fetches when no file is given. Returns 1 if nothing usable.
claude_usage_weekly() {
  local f="${1:-}" pct="" reset_iso="" reset_epoch=""
  [ -n "$f" ] || f="$(claude_usage_fetch)" || return 1
  pct="$(jq -r '
    ([.limits[]? | select(.group=="weekly" and .scope == null) | .percent] | map(select(. != null)) | max)
      // .seven_day.utilization // empty
    | floor' "$f" 2>/dev/null | tr -d '\r')"
  reset_iso="$(jq -r '.seven_day.resets_at // ([.limits[]? | select(.group=="weekly") | .resets_at] | map(select(. != null)) | .[0]) // empty' "$f" 2>/dev/null | tr -d '\r')"
  [ -n "$pct" ] || return 1
  if [ -n "$reset_iso" ]; then
    # GNU date (git-bash) parses the ISO offset form directly; trim sub-second digits first.
    reset_epoch="$(date -d "$(printf '%s' "$reset_iso" | sed -E 's/\.[0-9]+//')" +%s 2>/dev/null)"
  fi
  printf '%s\t%s\n' "$pct" "${reset_epoch:-}"
}

# claude_usage_capped [json-file] [threshold=90] -> one lowercase model display name per line
# for each model-scoped weekly limit at/over threshold (e.g. "fable"). Empty = none capped.
claude_usage_capped() {
  local f="${1:-}" th="${2:-90}"
  [ -n "$f" ] || f="$(claude_usage_fetch)" || return 1
  jq -r --argjson th "$th" '.limits[]? | select(.group=="weekly" and .scope != null and (.percent // 0) >= $th)
    | .scope.model.display_name // empty | ascii_downcase' "$f" 2>/dev/null | tr -d '\r'
}

# Direct-execution dispatch, same shape as lib-claude-paths.sh.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-weekly}" in
    weekly) claude_usage_weekly "${2:-}" ;;
    fetch)  claude_usage_fetch "${2:-}" ;;
    capped) claude_usage_capped "${2:-}" "${3:-90}" ;;
    *) echo "usage: lib-claude-usage.sh {weekly|fetch|capped} [file]" >&2; exit 1 ;;
  esac
fi
