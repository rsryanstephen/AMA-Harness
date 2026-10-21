#!/usr/bin/env bash
# Pick up every Bitbucket PR that names the user as a REVIEWER (user instruction 2026-10-16:
# AI agents may not approve PRs, so Claude comments + advises whenever the user must review).
#
#   pr-review-watch.sh [--once]
#
# Loop (default, singleton): every $PR_REVIEW_POLL s (900) query each locally-cloned repo
# (lib-harness-repos.sh index, both fleets) for OPEN PRs with reviewers.uuid = selfUuid.
# A PR (or a new source commit on it) not seen before, updated in the last 30 days, and not
# already approved by the user -> durable reminder (scripts/reminder.sh, any session claims it)
# telling that session to run ama-pr-review on it. Seen rows: harness-state/prs/review-seen.
# Restarted when dead by hooks/pr-watch-check.sh (pid file harness-state/prs/review-watch.pid).
#
# --once: one sweep, print each new PR, exit. Seams (tests only): PR_REVIEW_FIXTURE=<json>
# replaces every per-repo GET; PR_REVIEW_SLUGS="a b" replaces the repo index;
# CLAUDE_STATE_DIR redirects seen/pid/reminders.
set -uo pipefail
. "$(dirname "$0")/lib-bitbucket.sh"
. "$HOME/.claude/hooks/lib-claude-paths.sh"

ONCE=0; [ "${1:-}" = "--once" ] && ONCE=1
POLL="${PR_REVIEW_POLL:-900}"
SELF="$(hr_config '.bitbucket.selfUuid' '' | tr -d '\r')"
[ -n "$SELF" ] || { echo "bitbucket.selfUuid not set in harness-config.json" >&2; exit 1; }
SEEN="$(hstate prs review-seen)"; touch "$SEEN" 2>/dev/null
PIDF="$(hstate prs review-watch.pid)"
LOG="$(hstate prs review-watch.log)"
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG" 2>/dev/null; }

if [ "$ONCE" = 0 ]; then
  if { read -r oldpid < "$PIDF"; } 2>/dev/null && [ -n "${oldpid:-}" ] && [ "$oldpid" != "$$" ] && kill -0 "$oldpid" 2>/dev/null; then
    echo "already running (pid $oldpid)"; exit 0
  fi
  printf '%s\n' "$$" > "$PIDF"
  trap 'rm -f "$PIDF"' EXIT
  log "started (poll ${POLL}s)"
fi

slugs() {
  if [ -n "${PR_REVIEW_SLUGS:-}" ]; then printf '%s\n' $PR_REVIEW_SLUGS; return; fi
  bash "$HOME/.claude/hooks/lib-harness-repos.sh" index 2>/dev/null | cut -f1 | tr -d '\r' | sort -u
}

fetch() {  # fetch <slug>
  if [ -n "${PR_REVIEW_FIXTURE:-}" ]; then cat "$PR_REVIEW_FIXTURE"; return; fi
  bb_get --get "$BB_API/$1/pullrequests" --data-urlencode "q=state=\"OPEN\" AND reviewers.uuid=\"$SELF\"" \
    --data-urlencode 'pagelen=50' --data-urlencode 'fields=values.id,values.state,values.title,values.updated_on,values.author.display_name,values.source.branch.name,values.source.commit.hash,values.destination.branch.name,values.participants.user.uuid,values.participants.approved' 2>/dev/null
}

sweep() {
  local cutoff slug j rows id title upd author src dst hash key text
  cutoff="$(date -u -d '30 days ago' +%FT%T)"
  for slug in $(slugs); do
    j="$(fetch "$slug")"
    # Not a verdict: 429 / transport / auth error -> skip this repo this sweep.
    printf '%s' "$j" | jq -e 'objects | has("values")' >/dev/null 2>&1 || { log "$slug: API not answering ($(printf '%s' "$j" | jq -r '.error.message // "transport"' 2>/dev/null | head -c 120))"; continue; }
    # Re-assert OPEN locally: a q clause can silently override the state filter.
    rows="$(printf '%s' "$j" | jq -r --arg me "$SELF" --arg cut "$cutoff" '
      .values[] | select(.state == "OPEN") | select((.updated_on // "") >= $cut)
      | select([.participants[]? | select(.user.uuid == $me and .approved == true)] | length == 0)
      | [.id, (.source.commit.hash // "")[0:12], .updated_on, .author.display_name, .source.branch.name, .destination.branch.name, (.title | gsub("[\t\n\r]"; " "))] | @tsv' 2>/dev/null | tr -d '\r')"
    [ -n "$rows" ] || continue
    while IFS=$'\t' read -r id hash upd author src dst title; do
      [ -n "$id" ] || continue
      key="$slug-$id@$hash"
      grep -qxF "$key" "$SEEN" 2>/dev/null && continue
      url="https://bitbucket.org/$BB_ORG/$slug/pull-requests/$id"
      text="REVIEW REQUESTED: $url -- \"$title\" by $author ($src -> $dst, commit $hash). The user is a reviewer. Run the ama-pr-review skill on THIS ONE PR (repo $slug, PR $id), Steps 3-4: fetch-only local context, inline comments signed '-- Reviewed by Claude' plus the author DM ONLY for real verified issues. Then ADVISE the user per Step 5: verdict Approve / Hold / Request changes, key points and link, in-session AND as a Slack DM to the user (opening with their @-mention). NEVER approve it -- policy: AI agents may not approve PRs (bitbucket-pr-approve-gate.sh denies it); the user approves it themselves."
      if bash "$HOME/.claude/scripts/reminder.sh" add pr-review now "$text" >/dev/null 2>&1; then
        printf '%s\n' "$key" >> "$SEEN"
        log "queued review: $url @ $hash"
        [ "$ONCE" = 1 ] && echo "NEW  $url  ($title, by $author, $hash)"
      else
        log "reminder add failed for $url -- will retry next sweep"
      fi
    done <<< "$rows"
  done
}

if [ "$ONCE" = 1 ]; then sweep; exit 0; fi
while :; do sweep; sleep "$POLL"; done
