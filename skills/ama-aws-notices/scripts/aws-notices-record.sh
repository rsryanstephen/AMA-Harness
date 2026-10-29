#!/usr/bin/env bash
# Records AWS notice triage state. Eight subcommands (`seed` is the PROJ-15336
# backfill park -- see its own block for why it parks rather than suppresses).
#
#   add <arn> <lastUpdated> <descHash> <tier> <deadline|-> <Dband> <field|api|prose>
#       <entityClass> <ticket|stale|pending|watch|-> <watchUntil|-> <slug>
#       Appends one seen row. Idempotent on arn -- a re-run over the window overlap
#       can't duplicate rows.
#       T1/T2 REFUSE '-' in the disposition column: seen means TRIAGED, never ACTIONED,
#       so an actionable row must carry a ticket key ([A-Z][A-Z0-9]*-[0-9]+, the durable
#       due-dated store), `stale` (window closed / already remediated), `pending`
#       (blocked on an answer -- plan re-emits pending arns every run), or `watch` with
#       a date.
#       `watch` REQUIRES a watchUntil date, because a park with no wake-up is a silent
#       drop. It is earned by a DISTANT DEADLINE, never by event age -- an event type
#       open since 2025 carried a 10-day apply-by during design.
#
#   retriage <arn> <lastUpdated> <descHash> ... (same 11 args as add)
#       Overwrites an EXISTING row, INCLUDING its descHash. Exists because `add` is
#       idempotent on arn and therefore no-ops on a known event, `restamp` writes only
#       lastUpdatedTime and `settle` only tier/disposition -- so nothing could ever move
#       the hash. Consequence before this existed: AWS edits a description (adds an
#       apply-by date, escalates the wording), the plan script sees hash != stored hash
#       and emits a candidate, triage routes to `add`, `add` no-ops, the stored hash stays
#       stale, and the same event re-flags and re-Slacks every single week. That is the
#       exact muting failure the restamp mechanism was built to avoid.
#
#   mail-add <msg-id> <received-YYYY-MM-DD> <tier> <ticket|stale|pending|-> <slug>
#       Records a triaged item from the EMAIL leg, in a separate ledger keyed on Gmail
#       message id. The Health leg has a whole hash/restamp apparatus to avoid re-reporting
#       the same event; the mail leg had nothing at all, so the deliberate overlap window
#       re-read and could re-Slack the same forwarded notice every run. Same
#       T1/T2-refuses-`-` rule as `add`.
#
#   settle <arn> <tier> <ticket|stale|->
#       NOTE `stale` is overloaded: it means "window closed, nothing actionable now" AND
#       "the work is done", because it is also how a row is muted once its ticket ships.
#       Do not read a settled row as "we decided this didn't matter".
#       Resolves a `pending` (or `watch`) row in place once its answer arrives or its
#       deadline lands. `-` allowed only when the settled tier is T3/T4/T5.
#
#   restamp <arn> <lastUpdated>
#       Updates ONLY the lastUpdatedTime on an existing row, keeping tier and
#       disposition. For churn: Health moved the timestamp but the description hash is
#       unchanged. Refuses if no row exists (that would be an `add`, and would skip the
#       disposition gate).
#
#   finish --none | finish <candidate-arn ...>
#       Stamps lastrun ONLY if every candidate arn has a seen row -- coverage is checked
#       against the ledger, so an interrupted run FAILS here and re-fires. `--none` is
#       the explicit clean-window form; a bare `finish` is a usage error so laziness
#       can't stamp. Honest limit: it proves coverage of the candidate list passed in,
#       not of events describe-events never returned.
set -uo pipefail

. "$HOME/.claude/hooks/lib-claude-paths.sh"
SEEN="$(hstate notices .aws-notices-seen)"
MAILSEEN="$(hstate notices .aws-notices-mail-seen)"
LASTRUN="$(hstate notices .aws-notices-lastrun)"
touch "$SEEN"

# Strip CR from every argument before validating. This build's `jq -r` emits CRLF, so any
# caller piping plan-script output into this script (the normal path) hands over values
# like "prod\r" -- which failed validation with the maximally confusing
# "entityClass must be prod/nonprod/... got prod". Normalising at the validation boundary
# kills the whole class rather than making each caller remember. Same trap that silently
# broke anchored classification patterns in aws-notices-plan.sh.
if [ $# -gt 0 ]; then
  _args=()
  for _a in "$@"; do _args+=("$(printf '%s' "$_a" | tr -d '\r')"); done
  set -- "${_args[@]}"
  unset _args _a
fi

valid_disposition() {
  case "$1" in
    stale|pending|watch|-) return 0 ;;
    *) printf '%s' "$1" | grep -qE '^[A-Z][A-Z0-9]*-[0-9]+$' ;;
  esac
}

valid_date_or_dash() {
  [ "$1" = "-" ] && return 0
  printf '%s' "$1" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
}

seen_has() { cut -f1 "$SEEN" | grep -qxF -- "$1"; }

# Shared by `add` and `retriage` so the two can never drift. Args in ledger order:
#   <tier> <deadline> <dband> <dsrc> <cls> <disp> <watch>
#
# The CROSS-FIELD rules are the point. Validating each field alone let the live ledger
# reach a state where 7 rows read "D0" (due within 14 days) with no date recorded, and
# watchUntil was `-` on every single row -- which made watchDue, the only date-driven
# re-surface mechanism in the design, unable to fire for anything at all.
validate_row() {
  local tier="$1" deadline="$2" dband="$3" dsrc="$4" cls="$5" disp="$6" watch="$7"
  case "$tier" in T1|T2|T3|T4|T5) ;; *) printf 'tier must be T1..T5, got %s\n' "$tier" >&2; return 1 ;; esac
  # "D?" MUST be quoted: unquoted, `?` is a case-pattern glob matching any single
  # character, so `DX`/`D9`/any `D<char>` sailed through validation. Caught by the
  # gate tests, not by review.
  case "$dband" in D0|D1|D2|'D?') ;; *) printf 'deadline band must be D0/D1/D2/D?, got %s\n' "$dband" >&2; return 1 ;; esac
  case "$dsrc" in field|api|prose|-) ;; *) printf 'deadline source must be field/api/prose/-, got %s\n' "$dsrc" >&2; return 1 ;; esac
  case "$cls" in prod|nonprod|thirdparty|unclassified|none) ;; *) printf 'entityClass must be prod/nonprod/thirdparty/unclassified/none, got %s\n' "$cls" >&2; return 1 ;; esac
  valid_disposition "$disp" || { printf 'disposition must be a ticket key, stale, pending, watch, or -; got %s\n' "$disp" >&2; return 1; }
  valid_date_or_dash "$deadline" || { printf 'deadline must be YYYY-MM-DD or -; got %s\n' "$deadline" >&2; return 1; }
  valid_date_or_dash "$watch" || { printf 'watchUntil must be YYYY-MM-DD or -; got %s\n' "$watch" >&2; return 1; }

  # A dated band needs a date, and an undated row must say so with D?. Otherwise "D0"
  # is an assertion about a deadline nobody recorded.
  if [ "$dband" = 'D?' ] && [ "$deadline" != "-" ]; then
    printf 'REFUSING D? with a real deadline (%s): D? means no date was findable -- use D0/D1/D2\n' "$deadline" >&2
    return 1
  fi
  if [ "$dband" != 'D?' ] && [ "$deadline" = "-" ]; then
    printf 'REFUSING %s with no deadline: a dated band needs the date it is derived from, or use D?\n' "$dband" >&2
    return 1
  fi
  # Provenance and date travel together -- a date with no source is unauditable, and a
  # source with no date is meaningless.
  if [ "$deadline" = "-" ] && [ "$dsrc" != "-" ]; then
    printf 'REFUSING deadline source %s with no deadline\n' "$dsrc" >&2
    return 1
  fi
  if [ "$deadline" != "-" ] && [ "$dsrc" = "-" ]; then
    printf 'REFUSING deadline %s with no source: record field, api, or prose\n' "$deadline" >&2
    return 1
  fi

  case "$tier" in
    T1|T2)
      if [ "$disp" = "-" ]; then
        printf 'REFUSING %s row with no disposition: needs a ticket key, `stale`, `pending`, or `watch` -- seen means triaged, never actioned\n' "$tier" >&2
        return 1
      fi ;;
  esac
  if [ "$disp" = "watch" ] && [ "$watch" = "-" ]; then
    printf 'REFUSING watch row with no watchUntil date -- a park with no wake-up is a silent drop\n' >&2
    return 1
  fi
  return 0
}

cmd="${1:-}"
case "$cmd" in
  add)
    [ $# -eq 12 ] || { printf 'usage: aws-notices-record.sh add <arn> <lastUpdated> <descHash> <tier> <deadline|-> <Dband> <field|api|prose> <entityClass> <disposition> <watchUntil|-> <slug>\n' >&2; exit 1; }
    arn="$2"; lastupd="$3"; hash="$4"; tier="$5"; deadline="$6"; dband="$7"
    dsrc="$8"; cls="$9"; disp="${10}"; watch="${11}"; slug="${12}"
    validate_row "$tier" "$deadline" "$dband" "$dsrc" "$cls" "$disp" "$watch" || exit 1
    case "$arn$slug$hash" in *"$(printf '\t')"*) printf 'tab in arn/slug/hash would corrupt the ledger\n' >&2; exit 1 ;; esac
    if seen_has "$arn"; then
      printf 'already recorded: %s -- use `retriage` to update a row whose description changed\n' "$arn"
      exit 0
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$arn" "$lastupd" "$hash" "$tier" "$deadline" "$dband" "$dsrc" "$cls" "$disp" "$watch" "$slug" >> "$SEEN"
    printf 'recorded %s (%s/%s, %s)\n' "$slug" "$tier" "$dband" "$disp"
    ;;
  seed)
    # Turning on the non-Health surfaces (PROJ-15336) makes the FIRST sweep a backfill,
    # not a week's news: ~270 standing conditions that have all been true for months. Left
    # alone that is one unreadable Slack message followed by permanent suppression, which is
    # the worst of both -- nobody reads it and nobody ever sees them again.
    #
    # Seeding parks them instead of suppressing them, and the distinction is the whole
    # point. This skill's invariant is that seen means TRIAGED, never merely recorded, so a
    # blind `stale` would be a fabricated judgement on 270 rows nobody has looked at. `watch`
    # is the honest state: not yet judged, guaranteed to come back. watchUntil is a REQUIRED
    # argument with no default for the same reason `add` refuses it -- a park with no wake-up
    # is a silent drop, and a seeded backfill is exactly where that would go unnoticed.
    #
    # Reads plan output on stdin so the caller cannot hand-type 270 rows; seeds candidates
    # only, never restamp/watchDue rows, and never overwrites an existing row (so re-running
    # it after a partial triage cannot undo the triage).
    [ $# -eq 3 ] || { printf 'usage: aws-notices-record.sh seed <watchUntil YYYY-MM-DD> <slug-prefix> < plan.json\n(parks every UNSEEN candidate as tier T5 / disposition watch; existing rows are left alone)\n' >&2; exit 1; }
    watch="$2"; slugpfx="$3"
    case "$watch" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
      *) printf 'seed: watchUntil must be YYYY-MM-DD, got %s\n' "$watch" >&2; exit 1 ;;
    esac
    # A seed date INSIDE watchLeadDays is a no-op park, and a silent one. The plan script
    # re-surfaces any watch row whose date falls within the lead window, so seeding 308 rows
    # to a date two weeks out puts all 308 straight back into watchDue on the very next
    # sweep -- the run looks clean (candidateCount 0) while the caller is handed the whole
    # backfill again under a different key. Measured exactly that way on the first end-to-end
    # test: candidates 0, suppressed 308, watchDue 308.
    _lead="$(. "$HOME/.claude/hooks/lib-harness-repos.sh" 2>/dev/null; hr_config '.awsNotices.watchLeadDays' 30)"
    _earliest="$(date -d "+$((_lead + 1)) days" +%F 2>/dev/null)"
    if [ -n "$_earliest" ] && [ "$watch" \< "$_earliest" ]; then
      printf 'seed: %s is inside watchLeadDays (%s), so every seeded row would re-surface via watchDue on the next sweep -- a park that parks nothing.\nEarliest date that actually parks: %s\n' \
        "$watch" "$_lead" "$_earliest" >&2
      exit 1
    fi
    seed_in="$(mktemp)"; trap 'rm -f "$seed_in"' EXIT
    cat > "$seed_in"
    jq -e '.candidates' < "$seed_in" >/dev/null 2>&1 || {
      printf 'seed: stdin is not plan output (no .candidates array)\n' >&2; exit 1; }
    added=0; skipped=0
    while IFS=$'\t' read -r arn lastupd hash cls; do
      [ -n "$arn" ] || continue
      if seen_has "$arn"; then skipped=$((skipped+1)); continue; fi
      case "$arn$hash" in *"$(printf '\t')"*) continue ;; esac
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$arn" "$lastupd" "$hash" "T5" "-" "D3" "-" "${cls:-unclassified}" "watch" "$watch" \
        "$slugpfx-seeded" >> "$SEEN"
      added=$((added+1))
    done < <(jq -r '.candidates[] | select(.descHash != null)
                    | [.arn, .lastUpdatedTime, .descHash, (.entityClass // "unclassified")]
                    | @tsv' < "$seed_in" | tr -d '\r')
    printf 'seeded %d row(s) as T5/watch until %s; %d already had a row and were left alone\n' \
      "$added" "$watch" "$skipped"
    printf 'These are PARKED, not judged. They all re-surface on %s via watchDue.\n' "$watch"
    ;;
  retriage)
    [ $# -eq 12 ] || { printf 'usage: aws-notices-record.sh retriage <arn> <lastUpdated> <descHash> <tier> <deadline|-> <Dband> <field|api|prose> <entityClass> <disposition> <watchUntil|-> <slug>\n(same args as `add`; overwrites an EXISTING row including its descHash)\n' >&2; exit 1; }
    arn="$2"; lastupd="$3"; hash="$4"; tier="$5"; deadline="$6"; dband="$7"
    dsrc="$8"; cls="$9"; disp="${10}"; watch="${11}"; slug="${12}"
    validate_row "$tier" "$deadline" "$dband" "$dsrc" "$cls" "$disp" "$watch" || exit 1
    case "$arn$slug$hash" in *"$(printf '\t')"*) printf 'tab in arn/slug/hash would corrupt the ledger\n' >&2; exit 1 ;; esac
    seen_has "$arn" || { printf 'no seen row for %s -- retriage only updates existing rows; use add\n' "$arn" >&2; exit 1; }
    old="$(awk -F'\t' -v a="$arn" '$1==a{print $3 "/" $4 "/" $9; exit}' "$SEEN")"
    tmp="$SEEN.tmp.$$"
    awk -F'\t' -v OFS='\t' -v a="$arn" -v u="$lastupd" -v h="$hash" -v t="$tier" \
        -v dl="$deadline" -v db="$dband" -v ds="$dsrc" -v c="$cls" -v dp="$disp" \
        -v w="$watch" -v s="$slug" \
        '$1==a{$2=u;$3=h;$4=t;$5=dl;$6=db;$7=ds;$8=c;$9=dp;$10=w;$11=s}1' \
        "$SEEN" > "$tmp" && mv "$tmp" "$SEEN"
    printf 're-triaged %s: %s -> %s/%s/%s\n' "$arn" "$old" "$hash" "$tier" "$disp"
    ;;
  mail-add)
    [ $# -eq 6 ] || { printf 'usage: aws-notices-record.sh mail-add <msg-id> <received-YYYY-MM-DD> <tier> <ticket|stale|pending|-> <slug>\n' >&2; exit 1; }
    msgid="$2"; received="$3"; tier="$4"; disp="$5"; slug="$6"
    case "$tier" in T1|T2|T3|T4|T5) ;; *) printf 'tier must be T1..T5, got %s\n' "$tier" >&2; exit 1 ;; esac
    valid_disposition "$disp" || { printf 'disposition must be a ticket key, stale, pending, watch, or -; got %s\n' "$disp" >&2; exit 1; }
    [ "$disp" != "watch" ] || { printf 'watch is meaningless for a mail row -- mail has no lastUpdatedTime to re-check\n' >&2; exit 1; }
    valid_date_or_dash "$received" && [ "$received" != "-" ] || { printf 'received must be a real YYYY-MM-DD date\n' >&2; exit 1; }
    case "$tier" in
      T1|T2)
        if [ "$disp" = "-" ]; then
          printf 'REFUSING %s mail row with no disposition: needs a ticket key, `stale`, or `pending`\n' "$tier" >&2
          exit 1
        fi ;;
    esac
    case "$msgid$slug" in *"$(printf '\t')"*) printf 'tab in msg-id/slug would corrupt the ledger\n' >&2; exit 1 ;; esac
    touch "$MAILSEEN"
    if cut -f1 "$MAILSEEN" | grep -qxF -- "$msgid"; then
      printf 'already recorded (mail): %s\n' "$msgid"
      exit 0
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$msgid" "$received" "$tier" "$disp" "$slug" >> "$MAILSEEN"
    printf 'recorded mail %s (%s, %s)\n' "$slug" "$tier" "$disp"
    ;;
  settle)
    [ $# -eq 4 ] || { printf 'usage: aws-notices-record.sh settle <arn> <tier> <ticket|stale|->\n' >&2; exit 1; }
    arn="$2"; tier="$3"; disp="$4"
    case "$tier" in T1|T2|T3|T4|T5) ;; *) printf 'tier must be T1..T5, got %s\n' "$tier" >&2; exit 1 ;; esac
    case "$disp" in pending|watch) printf 'settle resolves a pending/watch row -- it cannot stay %s\n' "$disp" >&2; exit 1 ;; esac
    valid_disposition "$disp" || { printf 'disposition must be a ticket key, stale, or -; got %s\n' "$disp" >&2; exit 1; }
    if [ "$disp" = "-" ]; then
      case "$tier" in T1|T2) printf 'REFUSING: a settled T1/T2 needs a ticket key or `stale`\n' >&2; exit 1 ;; esac
    fi
    old="$(awk -F'\t' -v a="$arn" '$1==a{print $4 "/" $9; exit}' "$SEEN")"
    [ -n "$old" ] || { printf 'no seen row for %s -- settle only updates existing rows\n' "$arn" >&2; exit 1; }
    tmp="$SEEN.tmp.$$"
    awk -F'\t' -v OFS='\t' -v a="$arn" -v t="$tier" -v d="$disp" \
      '$1==a{$4=t;$9=d;$10="-"}1' "$SEEN" > "$tmp" && mv "$tmp" "$SEEN"
    printf 'settled %s: %s -> %s/%s\n' "$arn" "$old" "$tier" "$disp"
    ;;
  restamp)
    [ $# -eq 3 ] || { printf 'usage: aws-notices-record.sh restamp <arn> <lastUpdated>\n' >&2; exit 1; }
    arn="$2"; lastupd="$3"
    seen_has "$arn" || { printf 'no seen row for %s -- restamp never creates rows (that would skip the disposition gate); use add\n' "$arn" >&2; exit 1; }
    tmp="$SEEN.tmp.$$"
    awk -F'\t' -v OFS='\t' -v a="$arn" -v u="$lastupd" '$1==a{$2=u}1' "$SEEN" > "$tmp" && mv "$tmp" "$SEEN"
    printf 'restamped %s -> %s (tier/disposition unchanged, no re-Slack)\n' "$arn" "$lastupd"
    ;;
  finish)
    shift
    [ $# -gt 0 ] || { printf 'usage: aws-notices-record.sh finish --none | finish <candidate-arn ...>\n(pass every candidate arn this run returned; --none only for a genuinely empty window)\n' >&2; exit 1; }
    if [ "$1" = "--none" ]; then
      [ $# -eq 1 ] || { printf -- '--none takes no other arguments\n' >&2; exit 1; }
      date +%F > "$LASTRUN"
      printf 'lastrun updated: %s (clean window, zero candidates)\n' "$(cat "$LASTRUN")"
      exit 0
    fi
    missing=""
    for a in "$@"; do
      seen_has "$a" || missing="$missing $a"
    done
    if [ -n "$missing" ]; then
      printf 'REFUSING to update lastrun: candidate arn(s) with no seen row:%s\ntriage + record them first -- run stays stale and will re-fire\n' "$missing" >&2
      exit 1
    fi
    date +%F > "$LASTRUN"
    printf 'lastrun updated: %s (%s candidate(s), every one covered by a seen row)\n' "$(cat "$LASTRUN")" "$#"
    ;;
  *)
    printf 'usage: aws-notices-record.sh {add|retriage|mail-add|settle|restamp|finish} ...\n' >&2
    exit 1
    ;;
esac
