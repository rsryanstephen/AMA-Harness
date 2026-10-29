#!/usr/bin/env bash
# Temporary monitor: tell a session the moment a client-feedback fix reaches PRODUCTION, so the
# owed reply to Dan goes out the same day (user rule 2026-10-21, PROJ-15834).
#
#   feedback-prod-watch.sh <TICKET> <repo>=<Projects-N> [<repo>=<Projects-N> ...]
#                          [--sid <origin-session-id>] [--once] [--max-days N]
#
# Started (detached) as soon as the fix lands on QA or Staging -- git-push-ticket-reminder.sh
# names the command when a pushed commit's ticket is in the feedback epic. Every poll
# ($FEEDBACK_WATCH_POLL s, 900), per repo: the project's newest release with a Production
# Success -> its version tail IS the Bitbucket build number -> that build's commit -> does a
# "<TICKET>:" commit sit in its history? (Message grep, not a sha: a hotfix cherry-pick and the
# develop original share no sha.) Every repo live -> durable reminder (scripts/reminder.sh) with
# the whole follow-up, exit. Gives up after --max-days (30) with a reminder saying so.
#
# --once: one poll, print per-repo verdicts; exit 0 all live, 3 not yet, 4 API/git unreachable.
# Marker harness-state/feedback/pending/<TICKET> (pid, sid, started, ticket, pairs) --
# hooks/pr-watch-check.sh restarts a watcher whose process died.
set -uo pipefail
. "$HOME/.claude/skills/ama-bitbucket-api/scripts/lib-bitbucket.sh"
. "$HOME/.claude/hooks/lib-claude-paths.sh"

usage="usage: feedback-prod-watch.sh <TICKET> <repo>=<Projects-N>... [--sid SID] [--once] [--max-days N]"
TICKET="${1:?$usage}"; shift
PAIRS=(); SID=""; ONCE=0; MAX_DAYS=30
while [ $# -gt 0 ]; do
  case "$1" in
    --sid) SID="${2:?}"; shift 2 ;;
    --once) ONCE=1; shift ;;
    --max-days) MAX_DAYS="${2:?}"; shift 2 ;;
    *=Projects-*) PAIRS+=("$1"); shift ;;
    *) echo "unknown arg $1" >&2; echo "$usage" >&2; exit 2 ;;
  esac
done
[ "${#PAIRS[@]}" -gt 0 ] || { echo "$usage" >&2; exit 2; }
OCT_S="$(hr_config_required '.octopus.serverUrl')" || exit 1
OCT_SPACE="$(hr_config_required '.octopus.spaceId')" || exit 1
PROD="$(hr_config '.octopus.environmentIds.production' '<production>')"
POLL="${FEEDBACK_WATCH_POLL:-900}"
LOG="$(hstate feedback "prod-watch-$TICKET.log")"
MARK="$(hstate feedback "pending/$TICKET")"

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG" 2>/dev/null; [ "$ONCE" = 1 ] && echo "$*"; }
notify() { bash "$HOME/.claude/scripts/reminder.sh" add "${SID:-feedback-watch}" now "$*" >/dev/null 2>&1 || true; log "$*"; }

# live_in_prod <repo> <Projects-N> -> prints "<version>" and returns 0 when the ticket's commit
# is in Production's build; 1 not yet; 4 cannot tell.
live_in_prod() {
  local repo="$1" pid="$2" dir ver n sha
  dir="$(bash "$HOME/.claude/hooks/lib-harness-repos.sh" path "$repo" 2>/dev/null)" || return 4
  ver="$(curl -sS --max-time 30 -H "X-Octopus-ApiKey: ${OCTOPUS_API_KEY:-}" "$OCT_S/api/$OCT_SPACE/projects/$pid/progression" 2>/dev/null \
    | jq -r --arg e "$PROD" '[.Releases[]? | select(any(.Deployments[$e][]?; .State == "Success"))][0].Release.Version // empty' 2>/dev/null | tr -d '\r')"
  [ -n "$ver" ] || return 4
  n="${ver##*.}"
  sha="$(bb_get --max-time 30 "$BB_API/$(bb_slug "$repo")/pipelines/$n" 2>/dev/null | jq -r '.target.commit.hash // empty' 2>/dev/null | tr -d '\r')"
  [ -n "$sha" ] || return 4
  git -C "$dir" cat-file -e "$sha^{commit}" 2>/dev/null || git -C "$dir" fetch -q origin 2>/dev/null
  git -C "$dir" cat-file -e "$sha^{commit}" 2>/dev/null || return 4
  printf '%s' "$ver"
  [ -n "$(git -C "$dir" log -1 --format=%h --grep="^$TICKET:" "$sha" 2>/dev/null)" ] && return 0
  return 1
}

if [ "$ONCE" = 0 ]; then
  if [ -f "$MARK" ] && { read -r oldpid < "$MARK"; } 2>/dev/null && [ -n "${oldpid:-}" ] && kill -0 "$oldpid" 2>/dev/null; then
    echo "already watching $TICKET (pid $oldpid)"; exit 0
  fi
  printf '%s\n%s\n%s\n%s\n%s\n' "$$" "${SID:-}" "$(date +%s)" "$TICKET" "${PAIRS[*]}" > "$MARK" 2>/dev/null
  trap 'rm -f "$MARK"' EXIT
  log "watching $TICKET in Production: ${PAIRS[*]} (poll ${POLL}s, max ${MAX_DAYS}d, origin ${SID:-none})"
fi

deadline=$(( $(date +%s) + MAX_DAYS * 86400 ))
while :; do
  all=0; unknown=0; seen=""
  for p in "${PAIRS[@]}"; do
    repo="${p%%=*}"; pid="${p#*=}"
    ver="$(live_in_prod "$repo" "$pid")"; rc=$?
    case $rc in
      0) seen="$seen $repo $ver;" ;;
      1) all=1; [ "$ONCE" = 1 ] && log "$repo: Production runs $ver, $TICKET not in it yet" ;;
      *) all=1; unknown=1; log "$repo ($pid): could not read Production state -- not a verdict" ;;
    esac
  done
  seen="${seen# }"; seen="${seen%;}"
  if [ "$all" = 0 ] && [ "$ONCE" = 1 ]; then log "$TICKET is live in Production ($seen)"; exit 0; fi
  if [ "$all" = 0 ]; then
    notify "FEEDBACK FIX LIVE IN PRODUCTION: $TICKET ($seen). Owed now, per ama-feedback-notices 'Prod follow-up': (1) screenshot the fix working on production (ama-ui-verify, production test user); (2) a REPLY DRAFT in the original feedback mail's Gmail thread (the ticket's Ref), to Dan, cc Reviewer Two, Reviewer One, ContactOne, business level: fixed and live, what the client can now do, the screenshot inline, and that he can answer the client; (3) never send it -- DM the user on Slack with the <@mention> that the draft is ready to send, then add the action item: feedback-reply-item.sh add <TICKET> <threadId> (ticks itself off once the reply is sent). Also: ticket to Done if the prod-deploy sweep has not."
    exit 0
  fi
  if [ "$ONCE" = 1 ]; then [ "$unknown" = 1 ] && exit 4; exit 3; fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    notify "Feedback prod watcher for $TICKET gave up after ${MAX_DAYS} days -- not in Production yet (${PAIRS[*]}). Check where the fix is, then restart: bash ~/.claude/skills/ama-feedback-notices/scripts/feedback-prod-watch.sh $TICKET ${PAIRS[*]}"
    exit 3
  fi
  sleep "$POLL"
done
