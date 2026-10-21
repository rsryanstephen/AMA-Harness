#!/usr/bin/env bash
# Self-test for aws-notices-record.sh's refusal gates. NOT part of scripts/check-gates.sh
# -- that suite covers PreToolUse hooks, and none of this is a hook.
#
# 52 cases: the record script's refusal gates (including cross-field consistency and the
# mail ledger), plus the plan script's classification functions and region allowlist.
#
# Sensitivity is checked, not assumed: pointed at a MISSING record script the suite fails
# 46 of 52. The 6 survivors are the pure classification/region cases, which do not touch
# that script. Before the negative cases asserted refusal MESSAGES rather than merely a
# nonzero exit, deleting the script under test passed 12 of 18 -- "command not found" is
# nonzero too. Keep asserting the message.
#
# It exists because writing the first 17 cases found two real bugs that review had passed:
#   1. `case "$dband" in D0|D1|D2|D?)` -- unquoted `?` is a case-pattern GLOB, so `DX`,
#      `D9` and any other `D<char>` passed validation. Now `'D?'`.
#   2. (in aws-notices-plan.sh) jq -r emits CRLF on this build, so entity values arrived
#      as `name\r` and silently failed every ANCHORED classification pattern -- two
#      eu-west-1 production lambdas were classified `unclassified`.
# Both were invisible to reading the code and obvious the moment it ran. Re-run this
# after touching either script.
#
# Runs entirely against a throwaway CLAUDE_STATE_DIR -- never touches the real ledger.
#
# Usage: aws-notices-selftest.sh
# Exit: 0 = all passed, 1 = at least one failure.
set -uo pipefail
# Fixture ticket prefix as a variable: written literally after a printf tab escape, the token has a
# letter glued to its front, which defeats the publish scrub map's word boundary (2026-08-21..27).
# Pass it as a %s ARG, never inline: a single-quoted printf format does not expand ${TK}, so the
# fixture got the literal string while the double-quoted assertion got the real key -- 2 silent
# failures.
TK=PROJ

R="${BASH_SOURCE[0]%/*}/aws-notices-record.sh"
# Live state is never touched: every state path here AND in the scripts/hooks under test
# resolves through hstate, so exporting CLAUDE_STATE_DIR at a throwaway dir isolates the
# whole run. Replaces the old backup/truncate/restore machinery, whose non-atomic restore
# lost real ledger state when the Bash tool's 2m timeout SIGKILLed a run (2026-08-28) --
# with nothing live at stake, a hard kill now costs only a leaked temp dir. Safe since
# hstate's absorb branch is disabled under an overridden CLAUDE_STATE_DIR (it used to mv
# real ~/.claude leftovers into the override dir -- lib-claude-paths.sh).
export CLAUDE_STATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aws-notices-selftest.XXXXXX")"
trap 'rm -rf "$CLAUDE_STATE_DIR"' EXIT
. "$HOME/.claude/hooks/lib-claude-paths.sh"
SEEN="$(hstate notices .aws-notices-seen)"
MAILSEEN="$(hstate notices .aws-notices-mail-seen)"
: > "$SEEN"; : > "$MAILSEEN"

A1="arn:aws:health:us-east-1::event/ECS/X/SELFTEST-ONE"
A2="arn:aws:health:us-east-1::event/ELASTICACHE/Y/SELFTEST-TWO"

pass=0; fail=0
# Negative cases assert the REFUSAL MESSAGE, not merely a nonzero exit. With exit-code-only
# checking, deleting the script under test passed 12 of 18 cases -- "command not found" is
# nonzero too. `want` is 0 for success, or a substring the refusal must contain.
chk() { # chk <desc> <0|expected-stderr-substring> <cmd...>
  local d="$1" want="$2"; shift 2
  local out got
  out="$("$@" 2>&1)"; got=$?
  if [ "$want" = 0 ]; then
    if [ "$got" = 0 ]; then pass=$((pass+1)); printf 'PASS  %s\n' "$d"
    else fail=$((fail+1)); printf 'FAIL  %s (wanted success, got exit %s: %s)\n' "$d" "$got" "$(printf '%s' "$out" | head -1)"; fi
  else
    if [ "$got" = 0 ]; then
      fail=$((fail+1)); printf 'FAIL  %s (expected refusal, but it SUCCEEDED)\n' "$d"
    elif printf '%s' "$out" | grep -qF -- "$want"; then
      pass=$((pass+1)); printf 'PASS  %s (refused as expected)\n' "$d"
    else
      fail=$((fail+1)); printf 'FAIL  %s (refused, but not for the expected reason -- wanted %s, got: %s)\n' "$d" "$want" "$(printf '%s' "$out" | head -1)"
    fi
  fi
}

# --- classification: pure functions, sourced out of the plan script -------------------
# These had ZERO coverage, which is where BOTH of the bugs this suite is credited with
# finding actually lived. Sourced rather than duplicated so the test cannot drift.
PLAN="${BASH_SOURCE[0]%/*}/aws-notices-plan.sh"
eval "$(sed -n '/^classify_entity() {/,/^}/p' "$PLAN")"
eval "$(sed -n '/^roll_up_class() {/,/^}/p' "$PLAN")"

cls_chk() { # cls_chk <value> <expected-class>
  local v="$1" want="$2" got
  got="$(classify_entity "$v")"
  if [ "$got" = "$want" ]; then pass=$((pass+1)); printf 'PASS  classify %-46s -> %s\n' "$v" "$got"
  else fail=$((fail+1)); printf 'FAIL  classify %-46s -> %s (wanted %s)\n' "$v" "$got" "$want"; fi
}

cls_chk production-v1-hs-admin-esvc          prod
cls_chk hs-prod-exporter-v3                  prod
cls_chk hs-production-zip-files              prod
cls_chk lpc-adept-delta-prod                 prod
cls_chk staging-v1-search-api-isvc           nonprod
cls_chk hs-qa-exporter-v1                    nonprod
cls_chk Datadog-AWS-Integration-Dat-Fn       thirdparty
cls_chk vpn-66352807                         unclassified
# The CRLF trap: jq -r emits CRLF, and a trailing \r silently defeats ANCHORED patterns
# (`*-prod`) while unanchored ones (`*production*`) still match -- which is why the bug
# appeared on some resources and not others. The caller strips it; assert that it must.
cls_chk "$(printf 'lpc-adept-delta-prod\r')" unclassified

rollup_chk() { # rollup_chk <expected> <values...>
  local want="$1"; shift
  local got; got="$(roll_up_class "$@")"
  if [ "$got" = "$want" ]; then pass=$((pass+1)); printf 'PASS  rollup  %-46s -> %s\n' "$*" "$got"
  else fail=$((fail+1)); printf 'FAIL  rollup  %-46s -> %s (wanted %s)\n' "$*" "$got" "$want"; fi
}
rollup_chk prod         lpc-adept-delta-prod lpc-adept-delta-test
rollup_chk thirdparty   Datadog-AWS-Integration-Dat-Fn
rollup_chk none
rollup_chk unclassified staging-v1-search-api-isvc vpn-66352807

# --- the region allowlist: real resource names must survive it -------------------------
# The first implementation used the shape regex ^[a-z]{2}(-[a-z]+)+-[0-9]+$, which deleted
# hs-prod-1, hs-qa-2, db-main-2 and es-node-3 as "regions" before classification -- a
# production node's only entity, silently removed, leaving the event looking benign.
region_chk() { # region_chk <value> <keep|strip>
  local v="$1" want="$2" got
  if printf '%s' "$REGIONS_FIXTURE" | jq -e --arg v "$v" '. as $r | ($r | index($v))' >/dev/null 2>&1; then
    got=strip; else got=keep; fi
  if [ "$got" = "$want" ]; then pass=$((pass+1)); printf 'PASS  region  %-20s -> %s\n' "$v" "$got"
  else fail=$((fail+1)); printf 'FAIL  region  %-20s -> %s (wanted %s)\n' "$v" "$got" "$want"; fi
}
REGIONS_FIXTURE='["us-east-1","eu-west-1","eu-west-2","ap-south-1","me-central-1"]'
region_chk hs-prod-1   keep
region_chk hs-qa-2     keep
region_chk db-main-2   keep
region_chk es-node-3   keep
region_chk eu-west-2   strip
region_chk ap-south-1  strip

# --- the disposition gate: seen means triaged, never actioned -------------------------
chk "T1 with no disposition is refused" "REFUSING T1 row with no disposition" \
  bash "$R" add "$A1" 2026-08-20T10:00:00Z abc123def456 T1 2026-08-25 D0 prose prod - - t1-nodisp
chk "T5 with no disposition is allowed" 0 \
  bash "$R" add "$A1" 2026-08-20T10:00:00Z abc123def456 T5 - 'D?' - prod - - ecs-retire-noop
chk "duplicate arn is idempotent" 0 \
  bash "$R" add "$A1" 2026-08-20T10:00:00Z abc123def456 T5 - 'D?' - prod - - dup

# --- a park with no wake-up is a silent drop -----------------------------------------
chk "watch with no wake-up date is refused" "REFUSING watch row with no watchUntil" \
  bash "$R" add "$A2" 2026-08-20T10:00:00Z aaa111bbb222 T2 2027-03-03 D2 prose prod watch - far-nowake
chk "watch with a date is accepted" 0 \
  bash "$R" add "$A2" 2026-08-20T10:00:00Z aaa111bbb222 T2 2027-03-03 D2 prose prod watch 2027-02-01 lambda-far

# --- field validation ----------------------------------------------------------------
chk "bad tier is refused" "tier must be T1..T5" \
  bash "$R" add "arn:t" 2026-08-20T10:00:00Z h T9 - 'D?' - prod PROJ-1 - slug
chk "bad deadline band is refused (the D? glob bug)" "deadline band must be" \
  bash "$R" add "arn:d" 2026-08-20T10:00:00Z h T1 - DX - prod PROJ-1 - slug
chk "bad entityClass is refused" "entityClass must be" \
  bash "$R" add "arn:e" 2026-08-20T10:00:00Z h T1 2026-09-01 D0 prose wherever PROJ-1 - slug
chk "bad deadline-source is refused" "deadline source must be" \
  bash "$R" add "arn:s" 2026-08-20T10:00:00Z h T1 2026-09-01 D0 telepathy prod PROJ-1 - slug
chk "malformed deadline date is refused" "deadline must be YYYY-MM-DD" \
  bash "$R" add "arn:m" 2026-08-20T10:00:00Z h T1 25-08-2026 D0 prose prod PROJ-1 - slug

# --- cross-field consistency: the reason 7 live rows could never wake up --------------
chk "a dated band with no deadline is refused" "REFUSING D0 with no deadline" \
  bash "$R" add "arn:x1" 2026-08-20T10:00:00Z h T3 - D0 - prod PROJ-1 - slug
chk "D? carrying a real deadline is refused" "REFUSING D? with a real deadline" \
  bash "$R" add "arn:x2" 2026-08-20T10:00:00Z h T3 2026-09-01 'D?' prose prod PROJ-1 - slug
chk "a deadline with no provenance is refused" "REFUSING deadline 2026-09-01 with no source" \
  bash "$R" add "arn:x3" 2026-08-20T10:00:00Z h T3 2026-09-01 D0 - prod PROJ-1 - slug
chk "a provenance with no deadline is refused" "REFUSING deadline source prose with no deadline" \
  bash "$R" add "arn:x4" 2026-08-20T10:00:00Z h T3 - 'D?' prose prod PROJ-1 - slug

# --- retriage is the ONLY way to move a stored descHash ------------------------------
chk "retriage on unknown arn is refused" "no seen row for" \
  bash "$R" retriage "arn:nope" 2026-08-21T00:00:00Z newhash123456 T3 - 'D?' - prod PROJ-2 - s
chk "retriage on known arn works" 0 \
  bash "$R" retriage "$A2" 2026-08-21T00:00:00Z newhash123456 T2 2027-03-03 D2 api prod PROJ-2 - lambda-far-v2
chk "retriage enforces the same cross-field rules" "REFUSING D1 with no deadline" \
  bash "$R" retriage "$A2" 2026-08-21T00:00:00Z h T2 - D1 - prod PROJ-2 - bad

# --- restamp never creates rows (that would skip the disposition gate) ----------------
chk "restamp on unknown arn is refused" "no seen row for" bash "$R" restamp "arn:unknown" 2026-08-21T00:00:00Z
chk "restamp on known arn works" 0 bash "$R" restamp "$A1" 2026-08-21T09:00:00Z

# --- the mail ledger: same refusal semantics, separate keyspace ----------------------
chk "mail T1 with no disposition is refused" "REFUSING T1 mail row with no disposition" \
  bash "$R" mail-add 18abc123def 2026-08-07 T1 - elasticache-eol-fwd
chk "mail-add with a ticket works" 0 \
  bash "$R" mail-add 18abc123def 2026-08-07 T1 PROJ-15333 elasticache-eol-fwd
chk "mail-add is idempotent on message id" 0 \
  bash "$R" mail-add 18abc123def 2026-08-07 T1 PROJ-15333 dup
chk "mail-add rejects a watch disposition" "watch is meaningless for a mail row" \
  bash "$R" mail-add 18other456 2026-08-07 T3 watch some-slug
chk "mail-add requires a real received date" "received must be a real" \
  bash "$R" mail-add 18other456 - T3 - some-slug

# --- settle resolves, never re-parks -------------------------------------------------
chk "settle back to pending is refused" "cannot stay pending" bash "$R" settle "$A2" T2 pending
chk "settle T2 to a bare dash is refused" "REFUSING: a settled T1/T2" bash "$R" settle "$A2" T2 -
chk "settle T2 to a ticket key works" 0 bash "$R" settle "$A2" T2 PROJ-99999

# --- finish proves coverage ----------------------------------------------------------
chk "bare finish is a usage error" "usage: aws-notices-record.sh finish" bash "$R" finish
chk "finish with an unrecorded arn is refused" "REFUSING to update lastrun" \
  bash "$R" finish "$A1" "arn:aws:health:us-east-1::event/S3/Z/SELFTEST-THREE"
chk "finish with every arn recorded works" 0 bash "$R" finish "$A1" "$A2"

# --- state assertions, not just exit codes -------------------------------------------
r1="$(awk -F'\t' -v a="$A1" '$1==a{print $2"|"$4"|"$9}' "$SEEN")"
if [ "$r1" = "2026-08-21T09:00:00Z|T5|-" ]; then
  pass=$((pass+1)); printf 'PASS  restamp moved the timestamp and kept tier+disposition\n'
else
  fail=$((fail+1)); printf 'FAIL  restamp side effects: got [%s]\n' "$r1"
fi
r2="$(awk -F'\t' -v a="$A2" '$1==a{print $4"|"$9"|"$10}' "$SEEN")"
if [ "$r2" = "T2|PROJ-99999|-" ]; then
  pass=$((pass+1)); printf 'PASS  settle set the ticket and cleared watchUntil\n'
else
  fail=$((fail+1)); printf 'FAIL  settle side effects: got [%s]\n' "$r2"
fi
rows="$(wc -l < "$SEEN" | tr -d ' ')"
if [ "$rows" = 2 ]; then
  pass=$((pass+1)); printf 'PASS  every refused add left no row behind (2 rows)\n'
else
  fail=$((fail+1)); printf 'FAIL  expected exactly 2 rows, found %s -- a refusal wrote anyway\n' "$rows"
fi

# --- the derived deadline reminder in hooks/aws-notices-check.sh ----------------------
# Derived from the ledger, so it is testable by writing rows and sourcing the hook. The
# hook resolves its statefiles through hstate too, and CLAUDE_STATE_DIR is exported, so
# the sourced subshells below also stay inside the throwaway dir.
DLN="$(hstate notices .aws-notices-deadline-nudged)"

fire_nudge() { rm -f "$DLN"; bash -c 'HOOKS_DIR="$HOME/.claude/hooks"; source "$HOME/.claude/hooks/aws-notices-check.sh"; printf "%s" "$aws_notices_notice"'; }
refire_nudge() { bash -c 'HOOKS_DIR="$HOME/.claude/hooks"; source "$HOME/.claude/hooks/aws-notices-check.sh"; printf "%s" "$aws_notices_notice"'; }

has() { # has <desc> <substring> <haystack>
  if printf '%s' "$3" | grep -qF -- "$2"; then pass=$((pass+1)); printf 'PASS  nudge   %s\n' "$1"
  else fail=$((fail+1)); printf 'FAIL  nudge   %s (missing %s)\n' "$1" "$2"; fi; }
hasnt() {
  if printf '%s' "$3" | grep -qF -- "$2"; then fail=$((fail+1)); printf 'FAIL  nudge   %s (should not contain %s)\n' "$1" "$2"
  else pass=$((pass+1)); printf 'PASS  nudge   %s\n' "$1"; fi; }

dl_inside="$(date -d '+40 days' +%F 2>/dev/null)"
dl_outside="$(date -d '+200 days' +%F 2>/dev/null)"
: > "$SEEN"
printf 'manual:in\t2026-01-01T00:00:00Z\th1\tT1\t%s\tD1\tapi\tprod\t%s-11111\t-\tinside-horizon\n' "$dl_inside" "$TK" >> "$SEEN"
printf 'manual:out\t2026-01-01T00:00:00Z\th2\tT1\t%s\tD2\tapi\tprod\t%s-22222\t-\tbeyond-horizon\n' "$dl_outside" "$TK" >> "$SEEN"
printf 'manual:unk\t2026-01-01T00:00:00Z\th3\tT2\t-\tD?\t-\tprod\t%s-33333\t-\tno-date-known\n' "$TK" >> "$SEEN"
printf 'manual:done\t2026-01-01T00:00:00Z\th4\tT1\t%s\tD1\tapi\tprod\tstale\t-\talready-settled\n' "$dl_inside" >> "$SEEN"
printf 'manual:dup\t2026-01-01T00:00:00Z\th5\tT1\t%s\tD1\tapi\tprod\t%s-11111\t-\tsame-ticket-second-event\n' "$dl_inside" "$TK" >> "$SEEN"

dl_out="$(fire_nudge)"
has   "a deadline inside the horizon appears"   "${TK}-11111" "$dl_out"
hasnt "one beyond the horizon does not"         "${TK}-22222" "$dl_out"
has   "D? appears despite having no date"       "${TK}-33333" "$dl_out"
has   "D? renders as 'no date'"                 "no date"         "$dl_out"
hasnt "a settled row is silent"                 "already-settled" "$dl_out"
has   "two events on one ticket collapse to one line" "(+1 more event(s))" "$dl_out"
hasnt "the collapsed duplicate is not listed separately" "same-ticket-second-event" "$dl_out"
hasnt "same-day re-fire is throttled"           "AWS deadlines inside" "$(refire_nudge)"
: > "$SEEN"
hasnt "an empty ledger says nothing"            "AWS deadlines inside" "$(fire_nudge)"

# --- PROJ-15336: the non-Health surfaces ----------------------------------------
# Calibration cases for the five added legs. The API reads themselves are not exercised
# here (this suite is offline and must stay that way), so what is asserted is the part
# that is judgement rather than plumbing: the `seed` refusals, and the two traps that were
# only found by running the legs against the real account.
: > "$SEEN"
S="${BASH_SOURCE[0]%/*}/aws-notices-surfaces.sh"
PLANF="${BASH_SOURCE[0]%/*}/aws-notices-plan.sh"

chk "surfaces script parses"            0 bash -n "$S"
chk "seed rejects a non-ISO date"       "must be YYYY-MM-DD" \
    bash -c "echo '{\"candidates\":[]}' | '$R' seed 'next week' pfx"
chk "seed rejects stdin that is not a plan" "not plan output" \
    bash -c "echo '{}' | '$R' seed 2099-01-01 pfx"
# The park-that-parks-nothing trap: a date inside watchLeadDays sends every seeded row
# straight back out via watchDue on the next sweep. Measured live before the guard existed:
# candidates 0, suppressed 308, watchDue 308 -- a run that reads as clean while handing the
# caller the entire backfill again.
near="$(date -d '+3 days' +%F 2>/dev/null)"
chk "seed refuses a park inside watchLeadDays" "a park that parks nothing" \
    bash -c "echo '{\"candidates\":[]}' | '$R' seed '$near' pfx"
far="$(date -d '+400 days' +%F 2>/dev/null)"
chk "seed accepts a park beyond watchLeadDays" 0 \
    bash -c "echo '{\"candidates\":[]}' | '$R' seed '$far' pfx"

# Seeded rows are PARKED, never judged: T5 with a watch date, so nothing is asserted stale
# and nothing can be silently dropped.
: > "$SEEN"
seedjson='{"candidates":[{"arn":"synthetic:ta:selftest-1","lastUpdatedTime":"resolved/error","descHash":"abc123","entityClass":"prod"}]}'
printf '%s' "$seedjson" | "$R" seed "$far" h15336 >/dev/null 2>&1
has "seed writes a T5 row"        "$(printf 'T5')"  "$(cut -f4 "$SEEN")"
has "seed writes a watch row"     "watch"           "$(cut -f9 "$SEEN")"
has "seed carries the watch date" "$far"            "$(cut -f10 "$SEEN")"
hasnt "seed never asserts stale"  "stale"           "$(cut -f9 "$SEEN")"
# Idempotent: re-seeding after a partial triage must not undo the triage.
"$R" retriage "synthetic:ta:selftest-1" "resolved/error" "abc123" T1 - 'D?' - prod "${TK}-44444" - "triaged" >/dev/null 2>&1
printf '%s' "$seedjson" | "$R" seed "$far" h15336 >/dev/null 2>&1
has "re-seed leaves a triaged row alone" "${TK}-44444" "$(cut -f9 "$SEEN")"
rows_after="$(wc -l < "$SEEN" | tr -d ' ')"
has "re-seed creates no duplicate row"   "1" "$rows_after"

# Synthetic arns must never reach the Health detail API: there is no event behind one, and
# describe-event-details fails the WHOLE chunk of 10 it lands in, marking nine real events
# unfetched. Asserted against the source because the call itself is online-only.
has "plan routes synthetic arns out of the detail fetch" \
    'case "$arn" in synthetic:*) continue ;; esac' "$(cat "$PLANF")"
# DocDB clusters are RDS-backed and the rds call already returns them; running both gave
# 166 rows of which all 83 pairs were duplicates under two synthetic arns.
hasnt "surfaces does not also poll docdb for pending maintenance" \
    "leg_pending_maintenance docdb" "$(grep -v '^ *#' "$S")"
# The ACM rule is the reverse of the obvious one -- a NotAfter that MOVED means something
# is renewing the certificate, so it must NOT alarm.
has "ACM leg skips a certificate whose NotAfter moved" \
    'if [ -n "$prior" ] && [ "$prior" != "$notafter" ]; then continue; fi' "$(cat "$S")"
# Trusted Advisor: two 2024 CA-certificate checks report status=error with
# lifecycleStage=resolved, and all live CA certs expire 2027. A status-only filter alarms
# on them forever.
has "TA leg filters on lifecycleStage, not status alone" \
    'resolved' "$(grep -A2 'select((.lifecycleStage' "$S")"

printf '\nRESULT: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
