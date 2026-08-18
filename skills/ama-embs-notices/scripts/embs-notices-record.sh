#!/usr/bin/env bash
# Records eMBS Data Notice triage state. Three subcommands.
#
#   add <msg-id> <received-YYYY-MM-DD> <tier> <ticket|stale|pending|-> <slug> <intact|clipped>
#       Appends one seen row. Idempotent -- re-adding a known id is a no-op, so a re-run
#       over the deliberate window overlap can't duplicate rows.
#       T1/T2 REFUSE '-' in the ticket column: seen means TRIAGED, never ACTIONED, so an
#       actionable row must carry a disposition -- a ticket key ([A-Z][A-Z0-9]*-[0-9]+,
#       the durable due-dated store), `stale` (change already landed / window already
#       closed, nothing actionable now), or `pending` (verdict blocked on an answer;
#       the plan script re-emits pending ids on every run until settled).
#       Final field is a body-completeness marker, not a size guess: `intact` (body ends
#       with the vendor footer/sign-off) or `clipped` (ends mid-content -- re-fetch or
#       escalate per SKILL.md; a clipped row is the one worth reopening). Rows recorded
#       before this contract carry legacy values (char guesses / `unmeasured`).
#
#   settle <msg-id> <tier> <ticket|stale|->
#       Resolves a `pending` row in place (tier + ticket column) once the blocking
#       answer arrives. `-` allowed only when the settled tier is T3/T4.
#
#   finish --none | finish <candidate-msg-id ...>
#       Stamps lastrun ONLY if every candidate id from THIS run's two searches has a
#       seen row -- coverage is checked against the ledger itself, so an interrupted
#       run FAILS here and re-fires instead of being marked done. `--none` is the
#       explicit clean-window form; a bare `finish` is a usage error, so laziness can't
#       stamp. Honest limit: the candidate list still comes from the caller's searches
#       (Gmail is MCP-only, bash can't re-derive it) -- this gate proves coverage of
#       what the searches reported, not of notices they never surfaced.
set -uo pipefail

SEEN="$HOME/.claude/.embs-notices-seen"
LASTRUN="$HOME/.claude/.embs-notices-lastrun"
touch "$SEEN"

valid_ticket() {
  case "$1" in
    stale|pending|-) return 0 ;;
    *) printf '%s' "$1" | grep -qE '^[A-Z][A-Z0-9]*-[0-9]+$' ;;
  esac
}

seen_has() { cut -f1 "$SEEN" | grep -qxF -- "$1"; }

cmd="${1:-}"
case "$cmd" in
  add)
    [ $# -eq 7 ] || { printf 'usage: embs-notices-record.sh add <msg-id> <received> <tier> <ticket|stale|pending|-> <slug> <intact|clipped>\n' >&2; exit 1; }
    msgid="$2"; received="$3"; tier="$4"; ticket="$5"; slug="$6"; body="$7"
    case "$tier" in T1|T2|T3|T4) ;; *) printf 'tier must be T1..T4, got %s\n' "$tier" >&2; exit 1 ;; esac
    valid_ticket "$ticket" || { printf 'ticket column must be a ticket key, stale, pending, or -; got %s\n' "$ticket" >&2; exit 1; }
    case "$tier" in
      T1|T2)
        if [ "$ticket" = "-" ]; then
          printf 'REFUSING %s row with no disposition: T1/T2 needs a ticket key, `stale`, or `pending` -- seen means triaged, never actioned\n' "$tier" >&2
          exit 1
        fi ;;
    esac
    case "$body" in intact|clipped) ;; *) printf 'body marker must be `intact` (vendor footer present) or `clipped` (ends mid-content), got %s\n' "$body" >&2; exit 1 ;; esac
    case "$msgid$slug" in *"$(printf '\t')"*) printf 'tab in msg-id/slug would corrupt the ledger\n' >&2; exit 1 ;; esac
    if seen_has "$msgid"; then
      printf 'already recorded: %s\n' "$msgid"
      exit 0
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$msgid" "$received" "$tier" "$ticket" "$slug" "$body" >> "$SEEN"
    printf 'recorded %s (%s, %s)\n' "$msgid" "$tier" "$ticket"
    ;;
  settle)
    [ $# -eq 4 ] || { printf 'usage: embs-notices-record.sh settle <msg-id> <tier> <ticket|stale|->\n' >&2; exit 1; }
    msgid="$2"; tier="$3"; ticket="$4"
    case "$tier" in T1|T2|T3|T4) ;; *) printf 'tier must be T1..T4, got %s\n' "$tier" >&2; exit 1 ;; esac
    [ "$ticket" != "pending" ] || { printf 'settle resolves a pending row -- it cannot stay pending\n' >&2; exit 1; }
    valid_ticket "$ticket" || { printf 'ticket column must be a ticket key, stale, or -; got %s\n' "$ticket" >&2; exit 1; }
    if [ "$ticket" = "-" ]; then
      case "$tier" in T1|T2) printf 'REFUSING: a settled T1/T2 needs a ticket key or `stale`\n' >&2; exit 1 ;; esac
    fi
    old="$(awk -F'\t' -v id="$msgid" '$1==id{print $3 "/" $4; exit}' "$SEEN")"
    [ -n "$old" ] || { printf 'no seen row for %s -- settle only updates existing rows\n' "$msgid" >&2; exit 1; }
    tmp="$SEEN.tmp.$$"
    awk -F'\t' -v OFS='\t' -v id="$msgid" -v t="$tier" -v k="$ticket" '$1==id{$3=t;$4=k}1' "$SEEN" > "$tmp" && mv "$tmp" "$SEEN"
    printf 'settled %s: %s -> %s/%s\n' "$msgid" "$old" "$tier" "$ticket"
    ;;
  finish)
    shift
    [ $# -gt 0 ] || { printf 'usage: embs-notices-record.sh finish --none | finish <candidate-msg-id ...>\n(pass every candidate id this run'\''s searches returned; --none only for a genuinely empty window)\n' >&2; exit 1; }
    if [ "$1" = "--none" ]; then
      [ $# -eq 1 ] || { printf -- '--none takes no other arguments\n' >&2; exit 1; }
      date +%F > "$LASTRUN"
      printf 'lastrun updated: %s (clean window, zero candidates)\n' "$(cat "$LASTRUN")"
      exit 0
    fi
    missing=""
    for id in "$@"; do
      seen_has "$id" || missing="$missing $id"
    done
    if [ -n "$missing" ]; then
      printf 'REFUSING to update lastrun: candidate id(s) with no seen row:%s\ntriage + record them first -- run stays stale and will re-fire\n' "$missing" >&2
      exit 1
    fi
    date +%F > "$LASTRUN"
    printf 'lastrun updated: %s (%s candidate(s), every one covered by a seen row)\n' "$(cat "$LASTRUN")" "$#"
    ;;
  *)
    printf 'usage: embs-notices-record.sh {add|settle|finish} ...\n' >&2
    exit 1
    ;;
esac
