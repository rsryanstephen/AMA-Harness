#!/usr/bin/env bash
# Sourced from on-prompt.sh (not standalone-wired). Surfaces transitions that
# ready-to-test-readiness-gate.sh had to refuse because it could not RUN its check -- no
# token, Jira unreachable, an unresolvable destination -- rather than because the ticket was
# short of anything.
#
# Why this exists (2026-09-11): the gate fails CLOSED, so an outage leaves the ticket sitting
# at its old status, often with the testing-steps and regression comments already posted, and
# only the STATUS stale. Nothing remembered the transition was owed -- if the session ended
# during the outage (IT-7829 has run ~25h), it was simply forgotten. git-push-ticket-reminder.sh
# only catches this on a LATER push in the same repo, which may never come.
#
# Entries are cleared by the gate itself, on the next transition of that ticket it can actually
# evaluate -- the delayed retry, or a move somewhere else. Nothing here writes.
#
# Pure bash, no network: on-prompt.sh runs on EVERY prompt and is fork-cost sensitive, and the
# outage that created the entry is often still live. Reading a status here would mean a curl on
# every prompt, timing out every time. Sets $pending_transition_notice (empty if nothing to
# say). Throttled once per calendar day, like backlog-stale-check.sh.
pending_transition_notice=""
. "$HOME/.claude/hooks/lib-claude-paths.sh"
# RTT_PENDING_FILE / RTT_PENDING_NUDGED are test seams, same role HR_CONFIG_FILE plays for the
# config -- the gate writes through the first one, so both sides have to honour it.
PENDING_FILE="${RTT_PENDING_FILE:-$(hstate tickets pending-transitions)}"
NUDGED_FILE="${RTT_PENDING_NUDGED:-$(hstate notices .pending-transition-nudged)}"
[ -s "$PENDING_FILE" ] || return 0

today="$(date +%F)"
last_nudge="$(cat "$NUDGED_FILE" 2>/dev/null || true)"
[ "$last_nudge" = "$today" ] && return 0

# KEY \t transition-id \t destination \t date \t cause -- one line per ticket.
listing=""
while IFS="$(printf '\t')" read -r k id tgt when cause; do
  [ -n "$k" ] || continue
  # "?" means the destination never resolved -- the outage hit before /transitions answered,
  # so the target is whatever the agent was aiming at, not a fact the gate observed.
  [ "$tgt" = "?" ] && tgt="destination unresolved"
  listing="${listing}${listing:+; }${k} -> ${tgt} (id ${id}, blocked ${when}: ${cause})"
done < "$PENDING_FILE"
[ -n "$listing" ] || return 0

pending_transition_notice="TRANSITION(S) STILL OWED, recorded when the Ready-to-Test readiness gate could not run its check: ${listing}. The ticket never moved. Re-run the transition now (\`jira-get-transitions.sh <KEY>\` first -- ids are per-ticket and may have changed). READ THE TICKET'S COMMENTS FIRST: the testing-steps and regression comments were very likely already posted before the block, and re-running the whole sequence would duplicate them. The entry clears itself once the gate can evaluate a transition for that ticket; if the ticket has already been moved by hand, drop its line from ${PENDING_FILE}."
printf '%s\n' "$today" > "$NUDGED_FILE"
