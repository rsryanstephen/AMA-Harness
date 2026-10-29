#!/usr/bin/env bash
# Sourced from on-prompt.sh (not standalone-wired). Nudges Claude to run the
# ama-aws-notices skill once the last sweep is older than .awsNotices.checkDays.
#
# This is the scheduler. Per CLAUDE.md's mechanical-triggers rule a weekly task needs a
# hook behind it, not a skill-description match -- self-recognition doesn't hold.
#
# Unlike the <one entry per line; this element only declares the type> equivalent, the primary source here (AWS Health API) IS reachable from
# plain bash, so an unattended weekly runner is possible later without the headless
# `claude -p` dance. Deliberately not built yet: the nudge covers every case except
# no-session-for-weeks, and an unattended wrong verdict would mark an event seen forever.
# The one-shot digest below is the hand-off point for that future runner, same
# read-once-then-truncate shape as .usage-notices.
#
# Pure bash, no network, three tiny state-file reads -- on-prompt.sh runs on EVERY prompt
# and is fork-cost/30s-timeout sensitive. No AWS call belongs here.
#
# Sets $aws_notices_notice (empty if nothing to say). Throttled once per calendar day.
aws_notices_notice=""
. "$HOME/.claude/hooks/lib-claude-paths.sh"
LASTRUN_FILE="$(hstate notices .aws-notices-lastrun)"
NUDGED_FILE="$(hstate notices .aws-notices-nudged)"
DIGEST_FILE="$(hstate notices .aws-notices-digest)"
today="$(date +%F)"

# One-shot digest wins over the staleness nudge -- it carries actual findings.
# NB: no `return || exit` idiom here, unlike embs-notices-check.sh. If that script's
# `exit 0` branch is ever reached while sourced, on-prompt.sh dies before its final jq
# emit and the whole turn's injected context is silently lost. A plain if/else can't.
if [ -s "$DIGEST_FILE" ]; then
  aws_notices_notice="AWS notice sweep found items needing attention: $(cat "$DIGEST_FILE") Surface these distinctly, then continue with the task."
  : > "$DIGEST_FILE"
else
  # Cadence read is deliberately defaulted, unlike the skill's reportTarget: a wrong
  # cadence nudges too often, a wrong target delivers findings nowhere. Only the latter
  # is a real bug, so only that one fails loud (in aws-notices-plan.sh).
  check_days=7
  if [ -f "$HOME/.claude/harness-config.json" ]; then
    v="$(jq -r '.awsNotices.checkDays // empty' < "$HOME/.claude/harness-config.json" 2>/dev/null | sed 's/\r$//')"
    case "$v" in ''|*[!0-9]*) ;; *) check_days="$v" ;; esac
  fi

  due=0
  if [ ! -s "$LASTRUN_FILE" ]; then
    due=1
  else
    last="$(tr -d ' \r\n' < "$LASTRUN_FILE")"
    cutoff="$(date -d "$check_days days ago" +%F 2>/dev/null || true)"
    # last < cutoff => overdue. String compare is safe on YYYY-MM-DD.
    [ -n "$last" ] && [ -n "$cutoff" ] && [ "$last" \< "$cutoff" ] && due=1
  fi

  if [ "$due" = "1" ]; then
    last_nudge="$(cat "$NUDGED_FILE" 2>/dev/null || true)"
    if [ "$last_nudge" != "$today" ]; then
      aws_notices_notice="AWS notifications have not been swept in over $check_days days -- run the ama-aws-notices skill. A missed ElastiCache EOL notice cost ~\$7.5k/yr in extended-support fees before this existed, so treat it as real work, not a chore."
      printf '%s\n' "$today" > "$NUDGED_FILE"
    fi
  fi
fi

# --- Deadline reminder: DERIVED from the ledger, never stored ------------------------
#
# Answers "does a time-sensitive finding get a recurring reminder" without any new state.
# Recomputed here every prompt, throttled to weekly, sorted soonest-first.
#
# Computed OUTSIDE the digest/staleness if/else above and APPENDED, deliberately. As a
# third arm it would fire only in weeks the sweep was already overdue, and never while a
# digest was pending -- which defeats the whole point of decoupling a deadline from sweep
# staleness. A ticket sitting on the backlog page with a real date is exactly the thing
# that gets missed while the sweep itself looks healthy.
#
# Why derived rather than a row somewhere:
#   * harness-state/notices/.pending-followups has no recurrence field -- the convention is one row
#     rewritten in place per fire, so N dated findings means N rows to rewrite weekly and
#     a missed rewrite is a silent drop. Its schema also encodes a Slack escalation ladder
#     (slack-user-id, stage); nobody owes a reply here, a date just approaches. And it
#     would duplicate the deadline into a second file with nothing reconciling the two.
#   * `watch`/`watchDue` fires ONCE when the lead window opens, not weekly -- and
#     aws-notices-plan.sh selects `$9=="watch"`, so a row carrying a TICKET KEY (precisely
#     the row worth reminding about) can never appear in watchDue[]. `watch` keeps its own
#     job: parking a D2 item that has no ticket yet.
# Derived means nothing to seed and nothing to dedupe.
SEEN_FILE="$(hstate notices .aws-notices-seen)"
DL_NUDGED_FILE="$(hstate notices .aws-notices-deadline-nudged)"
if [ -s "$SEEN_FILE" ]; then
  horizon_days=90
  if [ -f "$HOME/.claude/harness-config.json" ]; then
    hv="$(jq -r '.awsNotices.deadlineHorizonDays // empty' < "$HOME/.claude/harness-config.json" 2>/dev/null | sed 's/\r$//')"
    case "$hv" in ''|*[!0-9]*) ;; *) horizon_days="$hv" ;; esac
  fi
  dl_last="$(cat "$DL_NUDGED_FILE" 2>/dev/null || true)"
  dl_due=1
  if [ -n "$dl_last" ]; then
    dl_next="$(date -d "$dl_last +7 days" +%F 2>/dev/null || true)"
    # Guarded: an unguarded `date` failure inside a sourced hook would kill on-prompt.sh
    # before its final emit and silently lose the whole turn's injected context.
    [ -n "$dl_next" ] && [ "$today" \< "$dl_next" ] && dl_due=0
  fi
  if [ "$dl_due" = "1" ]; then
    horizon="$(date -d "+$horizon_days days" +%F 2>/dev/null || true)"
    if [ -n "$horizon" ]; then
      # Selection is on the DATE, not the stored D-band: a band is computed at triage time
      # and goes stale, so a D2 item silently becomes D1 as the calendar moves. The
      # $6=="D?" arm is load-bearing -- validate_row forces deadline="-" for D?, so a
      # date-only filter would drop exactly the class this skill is most paranoid about.
      # COLLAPSED BY TICKET KEY, keeping the soonest date. One ticket usually covers many
      # ledger rows -- the ElastiCache backlog alone is 7 events under PROJ-15333 -- and
      # a first cut printed one line per row: 9 lines for 2 distinct tickets. That is the
      # "list gets muted" failure this reminder exists to avoid. A reminder is about the unit
      # of WORK (the ticket), not each underlying event.
      dl_rows="$(awk -F'\t' -v cut="$horizon" '
        $9 != "stale" && $9 != "pending" && $9 != "watch" && $9 != "-" &&
        ( ($6=="D?") || ($5!="-" && $5<=cut) ) {
          k = $9
          n[k]++
          d = ($5=="-") ? "9999-99-99" : $5
          if (!(k in soonest) || d < soonest[k]) { soonest[k] = d; band[k] = $4 "/" $6; slug[k] = $11 }
        }
        END {
          for (k in soonest) {
            shown = (soonest[k] == "9999-99-99") ? "no date   " : soonest[k]
            extra = (n[k] > 1) ? sprintf("  (+%d more event(s))", n[k] - 1) : ""
            printf "  %s  %s  %s  %s%s\n", shown, band[k], k, slug[k], extra
          }
        }' "$SEEN_FILE" | sort)"
      if [ -n "$dl_rows" ]; then
        dl_count="$(printf '%s\n' "$dl_rows" | grep -c .)"
        aws_notices_notice="$aws_notices_notice AWS deadlines inside $horizon_days days (weekly reminder, $dl_count item(s), soonest first):
$dl_rows
Closed one out? \`aws-notices-record.sh settle <arn> <tier> stale\` -- per item, with a reason, never globally."
        printf '%s\n' "$today" > "$DL_NUDGED_FILE"
      fi
    fi
  fi
fi
