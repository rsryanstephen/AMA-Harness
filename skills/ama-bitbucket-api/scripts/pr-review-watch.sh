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
# --once: one sweep, print each new PR, exit.
# --still-needed <slug> <id>: exit 0 = OPEN and approved by nobody yet, 1 = approved (by anyone) /
#   merged / declined (nothing to review), 2 = API not answering (review anyway, say so).
#   Re-run it right before the verdict DM and before any later mention of the verdict: a
#   review takes ~15 min, long enough for the PR to be approved and merged under it.
#   The queued reminder text runs it first, and every sweep drops PENDING review reminders
#   whose PR it says 1 for -- a review reminder for a PR approved hours earlier kept being
#   worked and re-asked about (PR #30, 2026-10-22).
# Seams (tests only): PR_REVIEW_FIXTURE=<json> replaces every per-repo GET;
# PR_REVIEW_PR_FIXTURE=<json> replaces the single-PR GET; PR_REVIEW_SLUGS="a b" replaces the
# repo index; CLAUDE_STATE_DIR redirects seen/pid/reminders.
set -uo pipefail
. "$(dirname "$0")/lib-bitbucket.sh"
. "$HOME/.claude/hooks/lib-claude-paths.sh"

ONCE=0; [ "${1:-}" = "--once" ] && ONCE=1
CHECK=0; [ "${1:-}" = "--still-needed" ] && CHECK=1
POLL="${PR_REVIEW_POLL:-900}"
SELF="$(hr_config '.bitbucket.selfUuid' '' | tr -d '\r')"
[ -n "$SELF" ] || { echo "bitbucket.selfUuid not set in harness-config.json" >&2; exit 1; }
SEEN="$(hstate prs review-seen)"; touch "$SEEN" 2>/dev/null
PIDF="$(hstate prs review-watch.pid)"
LOG="$(hstate prs review-watch.log)"
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG" 2>/dev/null; }

still_needed() {  # <slug> <id> -> 0 review needed, 1 not, 2 unknown
  local j
  if [ -n "${PR_REVIEW_PR_FIXTURE:-}" ]; then j="$(cat "$PR_REVIEW_PR_FIXTURE")"
  else j="$(bb_get --get "$BB_API/$1/pullrequests/$2" --data-urlencode 'fields=state,participants.user.uuid,participants.approved' 2>/dev/null)"; fi
  printf '%s' "$j" | jq -e 'objects | has("state")' >/dev/null 2>&1 || return 2
  # ANY participant's approval ends it, not just the user's: this team merges on one approval
  # (PR #35, 2026-10-27: another reviewer approved 21:35, our verdict DM went 21:37, merged 21:38).
  printf '%s' "$j" | jq -e '.state == "OPEN" and ([.participants[]? | select(.approved == true)] | length == 0)' >/dev/null 2>&1 && return 0
  return 1
}

if [ "$CHECK" = 1 ]; then
  still_needed "${2:?slug}" "${3:?id}"; rc=$?
  case $rc in 0) echo "STILL NEEDED: $2 PR $3 is open and not approved by you" ;;
    1) echo "NOT NEEDED: $2 PR $3 is already approved by you, merged or declined -- ack the reminder done, tell the user nothing" ;;
    *) echo "UNKNOWN: Bitbucket API not answering -- review anyway and say the approval state could not be checked" ;; esac
  exit $rc
fi

# Drop PENDING review reminders whose PR no longer needs the user (approved/merged/declined).
RDIR="$(dirname "$(hstate reminders pending/.keep)")"; RDIR="${RDIR%/pending}"
prune_pending() {
  local f url slug id rid
  for f in "$RDIR"/pending/*.rem; do
    [ -f "$f" ] || continue
    url="$(grep -oE "REVIEW REQUESTED: https://bitbucket.org/$BB_ORG/[^/ ]+/pull-requests/[0-9]+" "$f" 2>/dev/null | head -n 1)"
    [ -n "$url" ] || continue
    id="${url##*/}"; slug="${url%/pull-requests/*}"; slug="${slug##*/}"
    still_needed "$slug" "$id"; [ $? = 1 ] || continue
    rid="${f##*/}"; rid="${rid%.rem}"
    mv "$f" "$RDIR/fired/$rid.pr-review-watch.done" 2>/dev/null && log "dropped pending review reminder $rid: $slug PR $id already approved/merged/declined"
  done
}

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
      text="REVIEW REQUESTED: $url -- \"$title\" by $author ($src -> $dst, commit $hash). The user is a reviewer. FIRST run: bash ~/.claude/skills/ama-bitbucket-api/scripts/pr-review-watch.sh --still-needed $slug $id -- exit 1 means the user already approved it (or it was merged/declined): ack this reminder done and do NOTHING else, no review, no DM, no question to the user. Exit 0 or 2: run the ama-pr-review skill on THIS ONE PR (repo $slug, PR $id), Steps 3-4: fetch-only local context, inline comments signed '-- Reviewed by Claude' plus the author DM ONLY for real verified issues. Then ADVISE the user per Step 5: verdict Approve / Hold / Request changes, key points and link, in-session AND as a Slack DM to the user (opening with their @-mention). NEVER approve it -- policy: AI agents may not approve PRs (bitbucket-pr-approve-gate.sh denies it); the user approves it themselves."
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

if [ "$ONCE" = 1 ]; then prune_pending; sweep; exit 0; fi
while :; do prune_pending; sweep; sleep "$POLL"; done
