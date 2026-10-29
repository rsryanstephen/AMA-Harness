#!/usr/bin/env bash
# Merge a Bitbucket pull request the moment a reviewer approves it (user instruction
# 2026-10-14: every PR Claude opens gets a watcher, and merges as soon as it is approved).
#
#   pr-merge-watch.sh <repo> <pr-id> [--sid <origin-session-id>] [--post-merge "<work>"] [--once] [--max-days N]
#
# --post-merge (user rule 2026-10-28): the PR-creating session records what IT must do after the
# merge, so the user can close it meanwhile. Kept in harness-state/prs/post-merge/<slug>-<id>
# (sid, then the text), set any time; it only records and exits (with --once it also polls). The
# MERGED reminder then says work remains (ticket NOT to be moved) and names that session and its
# resume command (sessions.txt) for the user to reopen. Nothing recorded = nothing left: the
# generic follow-ups, ticket transition included. The creating session MUST decide which.
#
# Loop (default): poll the PR every $PR_WATCH_POLL s (300). OPEN + at least one REVIEWER
# approved + nobody requesting changes -> POST .../merge. Then a durable reminder
# (scripts/reminder.sh add) tells the ORIGIN session -- or, after its grace, any session --
# that the merge happened and what follow-ups are owed. MERGED/DECLINED/SUPERSEDED by someone
# else -> same reminder, exit. A merge the API refuses (branch restriction, failing build,
# unresolved task) is logged and retried next poll, not treated as final. Gives up after
# --max-days (14) with a reminder saying so.
#
# Build still running on the source tip -> no merge POST yet (2026-10-21, spark-jobs PR #39:
# approval landed while pipeline build 246 was mid-run; the POST was refused on "No in progress
# builds on last commit" and the one-shot "needs you to clear the cause" reminder was spent on a
# transient). The commit-statuses endpoint on `source.commit.hash` is read first; any INPROGRESS
# status -> wait $PR_WATCH_BUILD_POLL s (60) and look again, up to $PR_WATCH_BUILD_MAX s (7200)
# per tip, then fall through to the merge attempt so a stale status can't block forever. A new
# push (different tip) resets the wait. FAILED/absent statuses are NOT judged here: the merge
# POST is the oracle for whether the repo requires a green build at all.
#
# --once: one poll, print the verdict, exit: 0 merged (now or already), 1 merge refused,
# 2 declined/superseded, 3 open but not approved yet, 4 API unreachable, 5 approved but a build
# is still running on the source tip (try again when it finishes). The hook
# pr-created-reviewer-dm-reminder.sh starts the loop form detached (nohup) right after a PR is
# created; hooks/pr-watch-check.sh restarts a watcher whose process died (reboot, session
# closed) from the pending marker this script keeps under harness-state/prs/pending/.
#
# Seams (tests only): PR_WATCH_FIXTURE=<json file> replaces the GET; PR_WATCH_STATUS_FIXTURE=<json
# file> replaces the commit-statuses GET (unset under a PR fixture = no statuses); PR_WATCH_DRY_RUN=1
# replaces the merge POST with a fake MERGED answer; CLAUDE_STATE_DIR redirects the marker/log/reminder.
set -uo pipefail
. "$(dirname "$0")/lib-bitbucket.sh"
. "$HOME/.claude/hooks/lib-claude-paths.sh"

usage="usage: pr-merge-watch.sh <repo> <pr-id> [--sid <session-id>] [--post-merge \"<work>\"] [--once] [--max-days N]"
REPO="${1:?$usage}"; ID="${2:?$usage}"; shift 2
SID=""; ONCE=0; MAX_DAYS=14; POST_MERGE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --sid) SID="${2:?}"; shift 2 ;;
    --post-merge) POST_MERGE="${2:?}"; shift 2 ;;
    --once) ONCE=1; shift ;;
    --max-days) MAX_DAYS="${2:?}"; shift 2 ;;
    *) echo "unknown arg $1" >&2; echo "$usage" >&2; exit 2 ;;
  esac
done
SLUG="$(bb_slug "$REPO")"
POLL="${PR_WATCH_POLL:-300}"
BUILD_POLL="${PR_WATCH_BUILD_POLL:-60}"
BUILD_MAX="${PR_WATCH_BUILD_MAX:-7200}"
URL="https://bitbucket.org/$BB_ORG/$SLUG/pull-requests/$ID"
LOG="$(hstate prs "$SLUG-$ID.log")"
MARK="$(hstate prs "pending/$SLUG-$ID")"
PMF="$(hstate prs "post-merge/$SLUG-$ID")"
if [ -n "$POST_MERGE" ]; then
  [ -n "$SID" ] || { echo "--post-merge needs --sid <the session that will do the work>" >&2; exit 2; }
  printf '%s\n%s\n' "$SID" "$POST_MERGE" > "$PMF"
  echo "post-merge work recorded for $SLUG #$ID (session ${SID:0:8}); the merge reminder will name this session for the user to reopen"
  [ "$ONCE" = 1 ] || exit 0   # record-only: the running watcher reads it at merge time
fi
# Fleet owner (memory/fleet-owner-approval.md): in a repo the user does not own, only the
# owner's OWN approval merges -- another reviewer's (e.g. a second ETL reviewer) does not.
OWNERS=""
FO_LIB="$(dirname "$0")/../../../hooks/lib-fleet-owner.sh"
[ -f "$FO_LIB" ] && . "$FO_LIB" && OWNERS="$(fleet_owners_required "$SLUG")"

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG" 2>/dev/null; [ "$ONCE" = 1 ] && echo "$*"; }

# Durable, cross-session: the origin session claims it first (its reminder watcher wakes it);
# any other session picks it up after reminder.sh's origin grace. No origin -> any session.
notify() {
  bash "$HOME/.claude/scripts/reminder.sh" add "${SID:-pr-watch}" now "$*" >/dev/null 2>&1 || true
  log "$*"
}

# followups -> what the merge reminder asks for. Nothing recorded (--post-merge) = nothing left:
# the generic list, ticket transition included. Recorded = work remains, so the ticket must NOT
# move (a generic "push to master = Test Complete" would close work still owed -- PROJ-14687,
# PR #37), and the recorded session is named with its resume command. Seam: PR_WATCH_SESSIONS_FILE.
followups() {
  if [ ! -s "$PMF" ]; then
    printf 'Follow-ups now: ticket transition per commit-ticket rules (merge to develop = QA, push to master = Test Complete), library version sync if this repo publishes a package, and check whether the merge queued an Octopus deploy that needs approving or rejecting.'
    return 0
  fi
  local psid work row name cmd
  { IFS= read -r psid; work="$(cat)"; } < "$PMF"
  row="$(grep -F -- "$psid" "${PR_WATCH_SESSIONS_FILE:-$HOME/.claude/sessions.txt}" 2>/dev/null | head -1 | tr -d '\r')"
  name="${row%% cd *}"; cmd="cd ${row#* cd }"
  [ -n "$row" ] && [ "$row" != "$name" ] || { name="${psid:0:8}"; cmd="claude -r $psid"; }
  printf 'Work REMAINS after this merge -- do NOT transition the ticket(s). It belongs to session "%s" (%s): %s -- If you ARE that session, do it now (any ticket move comes after it). Otherwise do none of it here: tell the user to reopen that session (%s) so it continues with its own context.' \
    "$name" "${psid:0:8}" "$(printf '%s' "$work" | tr '\n' ' ')" "$cmd"
}

fetch() {
  if [ -n "${PR_WATCH_FIXTURE:-}" ]; then cat "$PR_WATCH_FIXTURE"; return; fi
  bb_get "$BB_API/$SLUG/pullrequests/$ID" 2>/dev/null
}

# tip_build_states <sha> -> comma-joined distinct commit-status states on that commit
# (SUCCESSFUL, INPROGRESS, FAILED, STOPPED), empty when there are none or the call fails.
tip_build_states() {
  local j
  if [ -n "${PR_WATCH_FIXTURE:-}" ]; then
    if [ -n "${PR_WATCH_STATUS_FIXTURE:-}" ]; then j="$(cat "$PR_WATCH_STATUS_FIXTURE")"; else j='{"values":[]}'; fi
  else
    j="$(bb_get "$BB_API/$SLUG/commit/$1/statuses" 2>/dev/null)" || j=""
  fi
  printf '%s' "$j" | jq -r '[.values[]?.state] | unique | join(",")' 2>/dev/null | tr -d '\r'
}

# prints "<http-code> <body>"
merge() {
  if [ -n "${PR_WATCH_DRY_RUN:-}" ]; then echo '200 {"state":"MERGED","dry_run":true}'; return; fi
  local body code
  body="$(bb_post -w '\n%{http_code}' -d '{"type":"pullrequest","close_source_branch":true,"merge_strategy":"merge_commit"}' \
            "$BB_API/$SLUG/pullrequests/$ID/merge" 2>/dev/null)" || { echo "000 "; return; }
  code="${body##*$'\n'}"; body="${body%$'\n'*}"
  printf '%s %s' "$code" "$body"
}

if [ "$ONCE" = 0 ]; then
  # One watcher per PR: a live marker pid means someone (the hook, a restart, a hand start)
  # already has it. Two watchers raced the same merge on 2026-10-14 and double-logged.
  if [ -f "$MARK" ] && { read -r oldpid < "$MARK"; } 2>/dev/null && [ -n "${oldpid:-}" ] && kill -0 "$oldpid" 2>/dev/null; then
    echo "already watching $URL (pid $oldpid)"; exit 0
  fi
  # marker: pid, origin sid, started epoch, slug, id -- pr-watch-check.sh restarts a dead pid.
  printf '%s\n%s\n%s\n%s\n%s\n' "$$" "${SID:-}" "$(date +%s)" "$SLUG" "$ID" > "$MARK" 2>/dev/null
  trap 'rm -f "$MARK"' EXIT
  log "watching $URL (poll ${POLL}s, max ${MAX_DAYS}d, origin ${SID:-none})"
fi

deadline=$(( $(date +%s) + MAX_DAYS * 86400 ))
pending=""
build_tip=""; build_wait_since=0
while :; do
  j="$(fetch)"
  if ! printf '%s' "$j" | jq -e 'objects | has("state")' >/dev/null 2>&1; then
    err="$(printf '%s' "$j" | jq -r '.error.message // empty' 2>/dev/null)"
    log "API not answering (${err:-transport}) -- not a verdict"
    [ "$ONCE" = 1 ] && exit 4
    sleep "$POLL"; continue
  fi
  st="$(printf '%s' "$j" | jq -r '.state' | tr -d '\r')"
  case "$st" in
    MERGED)
      notify "PR $URL is MERGED (by someone else, or an earlier attempt). $(followups)"
      rm -f "$PMF"; exit 0 ;;
    DECLINED|SUPERSEDED)
      notify "PR $URL was $st -- NOT merged. Decide what happens to the change."
      rm -f "$PMF"; exit 2 ;;
  esac
  approvers="$(printf '%s' "$j" | jq -r '[.participants[]? | select(.approved == true and .role == "REVIEWER") | .user.display_name] | join(", ")' | tr -d '\r')"
  blockers="$(printf '%s' "$j" | jq -r '[.participants[]? | select(.state == "changes_requested") | .user.display_name] | join(", ")' | tr -d '\r')"
  owner_missing=""
  if [ -n "$OWNERS" ]; then
    ok_uuids="$(printf '%s' "$j" | jq -r '[.participants[]? | select(.approved == true) | .user.uuid] | join(" ")' | tr -d '\r')"
    owner_missing="$(printf '%s\n' "$OWNERS" | awk -F'\t' -v ok=" $ok_uuids " 'index(ok, " " $3 " ") == 0 { printf "%s%s", (n++ ? ", " : ""), $2 }')"
  fi
  if [ -n "$approvers" ] && [ -z "$blockers" ] && [ -z "$owner_missing" ]; then
    # A build still running on the source tip makes the merge POST a guaranteed refusal
    # ("No in progress builds on last commit") -- wait for it instead of spending the
    # one-shot refusal reminder on a transient. Bounded per tip; a new push resets the clock.
    sha="$(printf '%s' "$j" | jq -r '.source.commit.hash // empty' 2>/dev/null | tr -d '\r')"
    if [ -n "$sha" ]; then
      states="$(tip_build_states "$sha")"
      case ",$states," in
        *,INPROGRESS,*)
          now="$(date +%s)"
          if [ "$sha" != "$build_tip" ]; then build_tip="$sha"; build_wait_since="$now"; fi
          if [ $(( now - build_wait_since )) -lt "$BUILD_MAX" ]; then
            log "approved by $approvers; build still running on ${sha:0:12} ($states) -- waiting, no merge attempt yet"
            [ "$ONCE" = 1 ] && exit 5
            sleep "$BUILD_POLL"; continue
          fi
          log "build on ${sha:0:12} still INPROGRESS after ${BUILD_MAX}s -- attempting the merge anyway (stale status?)" ;;
      esac
    fi
    r="$(merge)"; code="${r%% *}"; body="${r#* }"
    mstate="$(printf '%s' "$body" | jq -r '.state // empty' 2>/dev/null | tr -d '\r')"
    if [ "$mstate" = MERGED ] || [ "$code" = 202 ]; then
      # 202 = Bitbucket merges asynchronously; confirm on the next read before announcing.
      if [ "$mstate" != MERGED ] && [ -z "${PR_WATCH_FIXTURE:-}" ]; then
        for _ in 1 2 3 4 5 6; do sleep 10; mstate="$(fetch | jq -r '.state // empty' 2>/dev/null | tr -d '\r')"; [ "$mstate" = MERGED ] && break; done
      fi
      if [ "$mstate" = MERGED ]; then
        notify "MERGED on approval: $URL (approved by $approvers). $(followups)"
        rm -f "$PMF"; exit 0
      fi
    fi
    reason="$(printf '%s' "$body" | jq -r '.error.message // empty' 2>/dev/null | tr -d '\r')"
    checks="$(printf '%s' "$body" | jq -r '.error.fields.merge_checks // [] | join("; ")' 2>/dev/null | tr -d '\r')"
    [ "$ONCE" = 1 ] && { log "approved by $approvers but merge refused (HTTP $code: ${reason:-no detail}${checks:+ -- $checks})"; exit 1; }
    # Tell the origin ONCE: an approved-but-stuck PR needs a human (fix the build, resolve the
    # task, bypass the check). Later refusals only log; the retry keeps going regardless.
    if [ "${refused_told:-0}" = 0 ]; then
      refused_told=1
      notify "PR $URL is APPROVED by $approvers but the merge was refused (HTTP $code: ${reason:-no detail}${checks:+ -- $checks}). The watcher keeps retrying every $((POLL / 60)) min; it needs you to clear the cause (a failed/missing build on the source tip, an open task, a branch rule) -- it will merge on its own once that is fixed."
    else
      log "approved by $approvers but merge refused (HTTP $code: ${reason:-no detail}${checks:+ -- $checks}) -- retrying next poll"
    fi
  else
    pending="$(printf '%s' "$j" | jq -r '[.participants[]? | select(.role == "REVIEWER" and .approved != true) | .user.display_name] | join(", ")' | tr -d '\r')"
    [ "$ONCE" = 1 ] && { log "OPEN, not approved yet (waiting on: ${pending:-no reviewers set}${blockers:+; changes requested by $blockers}${owner_missing:+; owner approval required: $owner_missing})"; exit 3; }
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    notify "PR $URL still OPEN after ${MAX_DAYS} days (waiting on: ${pending:-?}${blockers:+; changes requested by $blockers}) -- watcher stopped. Chase the reviewer or restart: bash ~/.claude/skills/ama-bitbucket-api/scripts/pr-merge-watch.sh $SLUG $ID"
    exit 3
  fi
  sleep "$POLL"
done
