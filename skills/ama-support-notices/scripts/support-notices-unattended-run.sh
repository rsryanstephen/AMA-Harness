#!/usr/bin/env bash
# Unattended hourly support-notification triage run. Scheduled-task target
# (AMA-Harness-Support-Notices-Ping, hourly, InteractiveToken -- runs only while the user
# is logged on, same caveat as fleet-health/embs/standup).
#
# PHASE 1 (construction, .supportNotices.mode). Unlike the standup runner (which drafts
# a real Slack message and stops there) or the AWS/<one entry per line; this element only declares the type> pings (detection only, no
# judgment), this one DOES triage -- verdict, proposed ack, proposed ticket, proposed
# fix -- but everything lands as PROPOSED TEXT in one Slack DM. It never posts to
# #<amaSupportChannelName>, never files a ticket, never Slacks Reviewer One, never touches code. That
# guarantee is enforced by the --allowedTools lists below, not by asking nicely in the
# prompt: withholding Write bought nothing on the standup runner while Bash was granted
# (the run reached the same effect by shell redirect, <harnessEpicKey> harness-gaps.md).
#
# The headless work runs as TWO legs, and the split is what keeps that guarantee while
# still letting the run investigate anything (see the block above prompt_a for the full
# reasoning -- a single no-Bash leg made "Investigated:" a hardcoded constant):
#   leg A -- scoped Bash (support-notices-investigate.sh only, read-only) + Gmail READ.
#            No Slack, no Write. Investigates, triages, drafts the DM text.
#   leg B -- slack_send_message ONLY. Relays leg A's text verbatim. No Bash, no Write.
# Neither leg can write locally: the wrapper does every local write (seen ledger,
# lastrun, lastday, digest) itself, around the headless calls, not inside them.
set -uo pipefail

# Task Scheduler defaults a task's working directory to %windir%\System32 when nothing
# sets one -- confirmed real via the standup-notes sibling of this script (two dead
# sessions logged with cwd C:\WINDOWS\system32, never got a chat file at all, unwritable
# there). Land somewhere real and writable before the headless `claude -p` call below
# inherits whatever cwd we're in.
harness="$(git -C "$HOME/.claude/skills" rev-parse --show-toplevel 2>/dev/null)"
cd "${harness:-$HOME}" 2>/dev/null || true

. "$HOME/.claude/hooks/lib-harness-repos.sh"
. "$HOME/.claude/hooks/lib-claude-paths.sh"

LOG="$(hstate logs support-notices-ping.log)"
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

# Catch-up (below) can now retry a persistently-failing run every hour instead of once a
# day -- throttle the DIGEST's FAILED line to at most one per local calendar day so a bad
# day doesn't spam ~15 lines instead of 1. The unthrottled LOG line above still records
# every attempt.
digest_fail_once() {  # $1 = formatted digest line
  local today last
  today="$(date +%F)"
  last="$(tr -d ' \r\n' < "$FAILDAY" 2>/dev/null || true)"
  if [ "$last" = "$today" ]; then
    log "digest FAILED suppressed (already recorded today): $1"
    return
  fi
  printf '%s\n' "$1" >> "$DIGEST"
  printf '%s\n' "$today" > "$FAILDAY"
}

DIGEST="$(hstate notices .support-notices-digest)"
LASTRUN="$(hstate notices .support-notices-lastrun)"
LASTDAY="$(hstate notices .support-notices-lastday)"
FAILDAY="$(hstate notices .support-notices-failday)"
RECORD="$HOME/.claude/skills/<amaSupportChannelName>-notices/scripts/support-notices-record.sh"
SKILLDIR="$HOME/.claude/skills/<amaSupportChannelName>-notices"
PLAN_ERR="$(hstate notices .support-notices-plan-err)"

plan_json="$("$HOME/.claude/skills/<amaSupportChannelName>-notices/scripts/support-notices-plan.sh" 2>"$PLAN_ERR")"
plan_rc=$?
if [ "$plan_rc" -ne 0 ]; then
  err="$(cat "$PLAN_ERR" 2>/dev/null)"
  if printf '%s' "$err" | grep -q 'SCHEDULE-UNRESOLVED'; then
    log "SCHEDULE-UNRESOLVED: $err"
    digest_fail_once "$(printf 'Support notification monitor FAILED %s: schedule could not be resolved -- %s' \
      "$(date +%F)" "$(printf '%s' "$err" | head -c 300)")"
    # Fail loud to the DM directly too -- a digest line waits for the next session, and
    # this failure mode (silently downgrading a processing day to one check) is exactly
    # what must never go unnoticed.
    target="$(hr_config '.supportNotices.targets.construction.ack' "$(hr_config '.user.slackUserId' '')")"
    if [ -n "$target" ] && command -v claude >/dev/null 2>&1; then
      timeout 120 claude -p "Call mcp__claude_ai_Slack__slack_send_message with channel_id $target and this exact text: $(hr_self_mention "$target")Support notification monitor could not resolve today's cadence ($err). No mail was checked this run. Then reply with ONLY the word DONE, or FAILED: and the error." \
        --model haiku --allowedTools mcp__claude_ai_Slack__slack_send_message >>"$LOG" 2>&1 || true
    fi
    exit 1
  fi
  log "plan failed (non-schedule): $err"
  exit 1
fi

# SUPPORT_NOTICES_DRAFT_ONLY=1 bypasses BOTH schedule guards below (today's cadence, and
# already-ran-this-hour). A draft-only run sends nothing and records nothing, so it is
# safe to re-run at any hour -- and the hour you most want to test is usually one the
# real run has already consumed.
act="$(printf '%s' "$plan_json" | jq -r '.act')"
if [ "$act" != "yes" ] && [ "${SUPPORT_NOTICES_DRAFT_ONLY:-0}" != "1" ]; then
  log "quiet exit: act=no (day=$(printf '%s' "$plan_json" | jq -r '.day'), cadence=$(printf '%s' "$plan_json" | jq -r '.cadence'))"
  exit 0
fi

this_hour="$(date -u +%FT%H)"
if [ -s "$LASTRUN" ] && [ "$(tr -d ' \r\n' < "$LASTRUN")" = "$this_hour" ] && [ "${SUPPORT_NOTICES_DRAFT_ONLY:-0}" != "1" ]; then
  log "skip: already ran this hour ($this_hour)"
  exit 0
fi

if ! command -v claude >/dev/null 2>&1; then
  log "claude CLI not on PATH -- cannot run headless"
  digest_fail_once "$(printf 'Support notification monitor FAILED %s: claude CLI not on PATH (task env).' "$(date +%F)")"
  exit 1
fi

TARGET="$(printf '%s' "$plan_json" | jq -r '.ackTarget')"
[ -n "$TARGET" ] && [ "$TARGET" != "null" ] || { log "no ackTarget resolved -- nothing to DM"; exit 0; }

# claude -p terminates background tasks after 600s -- the prompt below forbids
# spawning/waiting on any subagent (bit the standup runner twice, AGENTS.md).
export CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0
# Leg A reads Gmail and then investigates, so it needs materially longer than the old
# single leg's 900s. 900s died on a 3-mail run, and 1500s died the same way twice more --
# because the cost was N tool round-trips, one per mail, at 2-3 min each. That is now ONE
# `triage-batch` round-trip for the whole run, so 1500s is a real ceiling rather than a
# number the run was always going to walk into. Leg B only relays one message, so it stays
# short. Worst case 1500+300s still lands well inside the hourly schedule.
TO_A=""; TO_B=""
if command -v timeout >/dev/null 2>&1; then TO_A="timeout 1500"; TO_B="timeout 300"; fi

# TWO LEGS, deliberately (<harnessEpicKey>, 2026-08-31). Leg A investigates and drafts;
# leg B is the only one that can talk. Before this split there was ONE leg with no Bash,
# so every DM item read "Investigated: no, no tool to investigate from here" -- hardcoded
# into the prompt, not a finding, on items that were all perfectly investigable.
#
# Granting plain Bash back was the wrong fix: raw Bash can curl Slack and commit code,
# reopening the exact hole the tool list was closing. So leg A gets Bash scoped to
# support-notices-investigate.sh ONLY (read-only by construction), plus Gmail READ, and
# no Slack/Write at all -- it cannot reach a human even if it decides to. Leg B gets
# slack_send_message and nothing else -- it cannot run a command even if it decides to.
# Both halves are load-bearing; widening either collapses the guarantee back to "asking
# nicely".
#
# INVESTIGATE feeds BOTH the prompt text and the --allowedTools entry from one variable,
# so the allowlist prefix can never drift from the path the prompt tells it to call. If
# it ever does drift the leg fails safe and loud (tool denied -> "Investigated: no"),
# which is the pre-split behaviour, not something worse.
INVESTIGATE="$SKILLDIR/scripts/support-notices-investigate.sh"

prompt_a="Run the <amaSupportChannelName>-notices skill's triage, unattended, PHASE 1 ONLY (construction \
mode -- propose, never write). Plan JSON (already computed, do not recompute): $plan_json

FIRST, Read $SKILLDIR/SKILL.md's 'Known no-action patterns' and 'Transient noise' \
sections and check each new mail against every pattern/rule listed there before triaging \
a verdict -- a matching mail is no-action regardless of how it looks in isolation. \
For 'Transient noise': compute the alert cluster's span from the Gmail thread's own \
timestamps (last minus first) -- no external tool needed for that one.

Search Gmail (mcp__claude_ai_Gmail__search_threads) for mail from the configured senders \
since the plan's 'since' date, THREAD_VIEW_FULL for anything found, then get_thread to read \
the body of each candidate. Skip any Gmail message id already in the plan's seenIds.

THEN INVESTIGATE the remaining mails before you settle any verdict. You DO have an \
investigation tool on this leg -- a read-only script. Make exactly ONE call for the WHOLE \
run, listing every candidate mail as a (timestamp, query) pair. Invoke it with the path \
exactly as written below, unquoted, but DO quote each argument:
  bash $INVESTIGATE triage-batch '<iso8601-utc>' '<lucene-query>' '<iso8601-utc>' '<lucene-query>' ...
<iso8601-utc> is that mail's error first-seen time; <lucene-query> is a distinctive \
VERBATIM fragment of its error text. Keep each query narrow -- all of this output lands \
in your own context.
ONE call, not one per mail: each tool round-trip costs minutes here, and three successive \
runs died on their timeout making a separate call per mail. Do NOT call the 'triage', \
'graylog' or 'pipeline' subcommands separately. If a mail needs a re-check with a \
different query afterwards, one extra call is fine -- just never N calls up front.
The output is split by '===== mail N: <timestamp> =====' headers, in the order you passed \
the pairs. Under each header:
  1. pipeline, at that mail's own first-seen timestamp. An OVERLAPS line means the error \
is probably caused by an automated api-testing run rather than a live fault -- say so, \
and per the skill's 'Uncertain verdict' rules that is a test bug to fix, not a support \
alert. A 'no ... overlaps' line rules that explanation out; say so, it is a real finding. \
An INCONCLUSIVE line means the check could not reach back that far and proves NOTHING -- \
never report it as 'not test-caused'; say the check was inconclusive and why.
  2. graylog -- how many times, is it still happening now, one burst or a steady drip. \
A single occurrence a week ago and a 49-hit cluster still firing this morning are \
completely different reports.

Verdict each mail (etl, sparc, app, or no-action) per the skill's rules, informed by what \
the checks actually returned -- do NOT record 'pending' merely because a mail looks \
ambiguous, that is what these checks are for. Record 'pending' only if a check itself \
failed or genuinely could not settle it, and then say which check and why.

Do NOT create anything anywhere -- no ticket tool, no Write, no Slack on this leg, and \
this is Phase 1 by design. Do ALL work SYNCHRONOUSLY -- never spawn or wait on a \
subagent or background task.

Then reply in EXACTLY this shape and nothing else:
DONE
<one Gmail message id per line for every mail you triaged, or the single word NONE>
---DM---
<the Slack message body, drafted per the rules below>

The Slack body opens with the literal line 'Support notification triage:' on its own line \
(the brevity gate keys its raised ceiling off it). Per flagged mail a TERSE block only -- \
NO message ids, NO restating the plan JSON, no proposed-message essays:
  line 1: one-line subject/description
  line 2: the VERBATIM error text wrapped in backticks, then ' -- first seen <time>'
  line 3: 'Investigated: yes. <one-line outcome from what the checks actually returned, \
e.g. 47 hits over 7d still firing 09:39 today, no pipeline overlap; or coincides with \
api-testing build 222, test-caused>'. Write 'Investigated: no' ONLY if a check errored, \
and then name the error.
  line 4: 'Ticket: none yet' (this leg never creates one, Phase 1 by design)
A mail matching a Known no-action pattern or the Transient-noise rule gets ONE LINE \
instead of a block: '<subject> -- no-action, known pattern: <short reason>'. \
Do NOT type a 'Sent using @Claude' signature line -- Slack adds its own automatically, \
and typing one in produces a visible duplicate. If there is nothing new at all, reply NONE \
for the id list and make the body a single short line saying so -- the wrapper suppresses \
the send on a NONE, so nobody will read that line; do not pad it out. Only a real issue \
gets DM'd. NONE means exactly 'no new mail to triage' -- if you SAW mail but could not \
settle it, that is NOT a clean window: list its id and say so in the body, so it reaches a \
human.
On failure reply with ONLY 'FAILED: <reason>'."

raw_a="$($TO_A claude -p "$prompt_a" \
  --model sonnet \
  --allowedTools "Bash(bash $INVESTIGATE:*)",Read,Grep,Glob,mcp__claude_ai_Gmail__search_threads,mcp__claude_ai_Gmail__get_thread \
  2>>"$LOG")"; rc_a=$?
# Keep the output even when the exit code is non-zero. `|| raw_a=""` threw away a
# COMPLETE reply whenever the process was killed while lingering on teardown -- and
# CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 above exists precisely because `claude -p`
# lingers. Let the parser below decide: a reply that parses is a success whatever rc says.
case "$raw_a" in *"spend limit"*|*"usage limit"*|*"rate limit"*) printf '%s %s\n' "$(date '+%F %T')" "$(basename "$0")" >> "$(hstate notices unattended-blocked.txt)"; log "BLOCKED by a spend/usage limit -- no work done this run";; esac

# Split leg A's reply on the sentinel. ids come only from the HEADER section, never from
# the DM body -- a 16-hex-looking string inside a quoted error message would otherwise be
# recorded as a triaged Gmail id and silently mark a real mail as seen.
head_a="${raw_a%%---DM---*}"
body_a="${raw_a#*---DM---}"
[ "$body_a" = "$raw_a" ] && body_a=""
# Strip leading blank lines. NOT cosmetic: slack-brevity-gate.sh matches the
# 'Support notification triage:' opener with `head -1`, so one leading newline drops the
# message to the DEFAULT length limit and the gate denies a normal multi-item triage.
# Leg B then never replies DONE, the wrapper exits without stamping lastrun, and the run
# re-fires into the same denial every hour -- permanently stuck, and invisible to
# DRAFT_ONLY, which exits before leg B.
body_a="$(printf '%s' "$body_a" | sed '/./,$!d')"

# Fixtures for this parser, including the real reply below: support-notices-parse-test.sh.
# Change one and run the other.
#
# Confirm leg A by finding a line that is EXACTLY 'DONE' anywhere in the header, not by
# `case "$head_a" in DONE*)`. That prefix anchor threw away a perfectly good run on
# 2026-09-02: the reply opened with one line of prose ("Confirmed: mailbox live...") and
# then gave DONE, NONE and a valid DM body, and all of it was discarded as a failure.
# Leg B's anchor stays strict -- see the note there; its reply is one word by construction.
#
# FAILED is checked FIRST so a reply that explains why it could not finish, and happens to
# contain the word DONE somewhere, cannot be read as a success.
id_start="$(printf '%s\n' "$head_a" | grep -nx '[[:space:]]*DONE[[:space:]]*' | head -1 | cut -d: -f1)"
case "$head_a" in
  *"FAILED:"*) id_start="" ;;
esac
if [ -n "$id_start" ]; then
  # ids come from the lines AFTER the DONE line only. Scanning all of head_a was safe
  # while nothing could precede DONE; now that prose can, a 16-hex string in that prose
  # would be recorded as a triaged mail id -- the exact hazard the split above guards.
  ids_region="$(printf '%s\n' "$head_a" | tail -n "+$((id_start + 1))")"
else
  # 1200, not 200: this reaches the user via the digest, and a 200-char cap truncates
  # mid-word. Sibling defect to team-meeting-notes' (7892af6), which hid a security finding.
  reason="$(printf '%s' "$raw_a" | head -c 1200)"
  # Say what actually happened instead of guessing. The old message asserted "likely hit
  # the timeout" for every empty reply, which is what made the 2026-09-01 report
  # unactionable without reading the script.
  [ -n "$reason" ] || reason="$(printf 'empty reply, exit code %s (%s)' "$rc_a" \
    "$([ "$rc_a" = 124 ] && printf 'killed by %s' "${TO_A:-no timeout}" || printf 'not a timeout kill')")"
  digest_fail_once "$(printf 'Support notification monitor FAILED %s: investigation leg did not confirm (%s).' "$(date +%F)" "$reason")"
  log "leg A failed (rc=$rc_a): $reason"
  exit 1
fi

if [ -z "$(printf '%s' "$body_a" | tr -d '[:space:]')" ]; then
  digest_fail_once "$(printf 'Support notification monitor FAILED %s: investigation leg returned no DM body.' "$(date +%F)")"
  log "leg A returned no DM body"
  exit 1
fi

# SUPPORT_NOTICES_DRAFT_ONLY=1 stops here: leg A has run for real, the draft is printed,
# and NOTHING is sent or recorded -- no Slack, no seen ledger, no lastrun/lastday/digest.
# This is the only safe way to exercise the real code path (not a hand-copied replica of
# it) when changing the prompts, because a full run marks mail as seen and a later real
# run then skips it.
# Computed BEFORE the DRAFT_ONLY exit on purpose, so a draft run reports the send/suppress
# verdict too. Without that, DRAFT_ONLY silently stops short of the one decision most
# likely to be wrong after a prompt change.
ids_trimmed="$(printf '%s' "$ids_region" | tr -d '[:space:]')"
if [ "$ids_trimmed" = "NONE" ]; then would="SUPPRESS (clean window, nothing to report)"; else would="SEND"; fi

# NEVER FAIL TO SEND (user rule 2026-10-15; a 301-word DM was denied by
# slack-brevity-gate.sh and nothing went out). The REAL gate is the oracle
# (lib-support-dm-fit.sh): as-is -> summarize leg (no tools) -> deterministic shrink, which
# always ends on something the gate passes. Full text kept in FULLDM, pointer line names it.
. "$SKILLDIR/scripts/lib-support-dm-fit.sh"
FULLDM="$(hstate notices .support-notices-lastdm-full)"
POINTER="(Shortened to fit Slack. Full triage: $FULLDM)"
n_items="$(printf '%s' "$ids_region" | grep -oE '[0-9a-f]{16}' | sort -u | grep -c . || true)"
[ "${n_items:-0}" -gt 0 ] || n_items="some"
body_full="$body_a"
words_full="$(dm_words "$body_a")"
send_path="as-is"
if [ "$ids_trimmed" != "NONE" ]; then
  body_a="$(dm_ensure_header "$body_a")"
  if ! dm_gate_ok "$body_a"; then
    target_w=$(( SLACK_LIMIT_SUPPORT - 60 ))
    prompt_s="Rewrite the Slack message between the marker lines to UNDER $target_w words. \
Keep line 1 exactly 'Support notification triage:'. Keep EVERY item; for each keep its \
subject, its verbatim error text in backticks, the investigation outcome, and every ticket \
key and link. Drop restated background and filler. Wrap every IP address/CIDR in its own \
backticks. Reply with ONLY the rewritten message, nothing before or after it.
---BEGIN MESSAGE---
$body_a
---END MESSAGE---"
    summ="$($TO_B claude -p "$prompt_s" --model sonnet --tools "" --strict-mcp-config 2>>"$LOG")" || true   # no tools, no MCP: text in, text out
    summ="$(printf '%s' "$summ" | sed -e '/^---BEGIN MESSAGE---$/d' -e '/^---END MESSAGE---$/d')"
    if [ -n "$(printf '%s' "$summ" | tr -d '[:space:]')" ] && summ="$(dm_ensure_header "$summ")" && dm_gate_ok "$summ"; then
      body_a="$summ"; send_path="summarized"
    else
      dm_shrink "$body_a" "$n_items" "$POINTER"
      body_a="$DM_FIT_TEXT"; send_path="$DM_FIT_PATH"
    fi
  fi
fi

if [ "${SUPPORT_NOTICES_DRAFT_ONLY:-0}" = "1" ]; then
  printf '%s\n' "--- leg A header (ids) ---" "$head_a" "--- drafted DM ($words_full words, limit $SLACK_LIMIT_SUPPORT) ---" "$body_full" \
    "--- send path: $send_path ($(dm_words "$body_a") words) ---" "$body_a" "--- would $would ---"
  log "DRAFT_ONLY: leg A completed, would $would via $send_path ($words_full words), nothing sent or recorded"
  exit 0
fi
# After the DRAFT_ONLY exit on purpose: a draft run writes nothing.
[ "$send_path" = "as-is" ] || printf '%s\n' "$body_full" > "$FULLDM"

# CLEAN WINDOW -> NO DM AT ALL. Standing user instruction, 2026-09-08: DM only when there
# is actually an issue. At the current ~3h cadence this monitor sent EIGHT "nothing new
# since last check" DMs a day (support-notices-ping.log, 2026-09-06/07), which trains the
# reader to ignore the channel -- so the one message that matters gets ignored with them.
# The run itself still happens: the seen ledger and lastrun/lastday still advance, and the
# ping log still records the clean window.
#
# NOT written to the DIGEST either. support-notices-check.sh injects the digest into the
# next session's prompt "distinctly" and then drains it, so a per-run clean-window line
# would just relocate the same noise from Slack into every session's context. Real
# failures still reach the digest via digest_fail_once, unchanged.
#
# Keyed on leg A's EXPLICIT `NONE`, never on "the hex extraction found no ids" -- those are
# different claims. A run that saw mail but could not produce ids for it is NOT a clean
# window and MUST still reach the user; only a literal NONE suppresses. Silence has to be
# something leg A asserted, not something inferred from a parse coming up empty.
if [ "$ids_trimmed" = "NONE" ]; then
  bash "$RECORD" finish --none >>"$LOG" 2>&1 || true
  date -u +%FT%H > "$LASTRUN"
  printf '%s\n' "$(printf '%s' "$plan_json" | jq -r '.today')" > "$LASTDAY"
  log "clean window, zero candidates -- DM SUPPRESSED (nothing to report); lastrun/lastday stamped"
  exit 0
fi

# Leg B: send-only. Nothing but slack_send_message -- it relays leg A's text verbatim and
# cannot investigate, re-triage or edit it. Gates on slack_send_message still fire here.
send_leg_b() {  # $1 = message text; sets out, rc_b
  local prompt_b mention
  # Self-DM -> mention on its own line (slack-brevity-gate.sh rule 3); the gate's header
  # check skips that line, so the triage ceiling still applies.
  mention="$(hr_self_mention "$TARGET")"; [ -n "$mention" ] && set -- "${mention% }

$1"
  prompt_b="Call mcp__claude_ai_Slack__slack_send_message with channel_id $TARGET and, as the \
message text, EXACTLY the text between the two marker lines below -- verbatim, no edits, \
no additions, no signature line, the marker lines themselves excluded. Then reply with \
ONLY the word DONE, or 'FAILED: <reason>'.
---BEGIN MESSAGE---
$1
---END MESSAGE---"
  rc_b=0
  out="$($TO_B claude -p "$prompt_b" \
    --model haiku \
    --allowedTools mcp__claude_ai_Slack__slack_send_message \
    2>>"$LOG")" || rc_b=$?
  case "$out" in *"spend limit"*|*"usage limit"*|*"rate limit"*) printf '%s %s\n' "$(date '+%F %T')" "$(basename "$0")" >> "$(hstate notices unattended-blocked.txt)"; log "BLOCKED by a spend/usage limit -- no work done this run";; esac
}
send_leg_b "$body_a"

# Blocked by a hook anyway (another gate, or the brevity gate disagreeing with the pre-check)
# -> retry ONCE with the deterministic short form, never report FAILED having sent nothing.
# Only on hook/deny wording: a reply that merely misreports a send that DID happen must
# not be retried, or the user gets the DM twice.
if ! printf '%s' "$out" | tr -d '[:space:]' | grep -q '^DONE' \
   && printf '%s' "$out" | grep -qiE 'hook|blocked|denied|deny|gate'; then
  printf '%s\n' "$body_full" > "$FULLDM"
  dm_shrink "$(dm_ensure_header "$body_full")" "$n_items" "$POINTER"
  retry_text="$DM_FIT_TEXT"
  [ "$retry_text" = "$body_a" ] && retry_text="$(dm_minimal "$n_items" "$POINTER")"
  log "leg B blocked by a hook ($(printf '%s' "$out" | head -c 300)) -- retrying once with the $DM_FIT_PATH short form"
  send_path="retry-$DM_FIT_PATH"
  send_leg_b "$retry_text"
fi

# Match leg B's reply with surrounding whitespace stripped. `case "$out" in DONE*)` is
# prefix-anchored, so a single leading newline or space in an otherwise perfect reply
# reads as failure -- and THAT failure re-fires the run every hour without ever stamping
# lastrun. Trimming is not cosmetic here. Still anchored, not `*DONE*`: a reply that
# explains why it could not send must not count as a send.
out_trimmed="$(printf '%s' "$out" | tr -d '[:space:]')"
case "$out_trimmed" in
  DONE*)
    # ids come from LEG A's reply, not from $out ($out is leg B's one-word reply), and
    # only from the lines AFTER its DONE line -- see the ids_region note above.
    ids="$(printf '%s' "$ids_region" | grep -oE '[0-9a-f]{16}' | sort -u)"
    if [ -n "$ids" ]; then
      log "triaged ids: $(printf '%s' "$ids" | tr '\n' ' ') -- recording as pending review (Phase 1 has no ticket tool to record a real disposition against)"
      while IFS= read -r mid; do
        [ -n "$mid" ] || continue
        bash "$RECORD" add "$mid" "$(date +%F)" no-action - "phase1-dm-only-see-digest" >>"$LOG" 2>&1 || true
      done <<< "$ids"
      # finish only if every id landed a seen row -- otherwise leave lastrun stale so it re-fires.
      # shellcheck disable=SC2046
      if bash "$RECORD" finish $ids >>"$LOG" 2>&1; then
        :
      else
        log "finish refused coverage -- lastrun left stale, will retry"
      fi
    else
      bash "$RECORD" finish --none >>"$LOG" 2>&1 || true
    fi
    date -u +%FT%H > "$LASTRUN"
    # Stamp today's LOCAL date from the plan's own computation (TZ_CFG) -- never
    # re-derive it here, LASTRUN right above is deliberately UTC-dated and copying that
    # idiom for LASTDAY would silently reintroduce the same tz mismatch.
    printf '%s\n' "$(printf '%s' "$plan_json" | jq -r '.today')" > "$LASTDAY"
    printf 'Support notification monitor %s: DM sent to %s (%s mail(s) triaged, %s%s).\n' \
      "$(date +%F)" "$TARGET" "$(printf '%s' "$ids" | grep -c . || echo 0)" "$send_path" \
      "$([ "$send_path" = as-is ] || printf ', full text in %s' "$FULLDM")" >> "$DIGEST"
    log "DM sent to $TARGET (path: $send_path, draft $words_full words)"
    ;;
  *)
    reason="$(printf '%s' "$out" | head -c 1200)"   # see the 1200 note above
    # Same shape as leg A's: say what happened, never "likely hit the timeout" for every
    # empty reply (this line used to name TO_A -- leg A's timeout -- for leg B's failure).
    [ -n "$reason" ] || reason="$(printf 'empty reply from the Slack send leg, exit code %s (%s); the 2026-09-06 instance coincided with the Slack MCP tools being absent from headless claude -p' "$rc_b" \
      "$([ "$rc_b" = 124 ] && printf 'killed by %s' "${TO_B:-no timeout}" || printf 'not a timeout kill')")"
    digest_fail_once "$(printf 'Support notification monitor FAILED %s: send leg did not confirm (%s).' "$(date +%F)" "$reason")"
    log "leg B failed (rc=$rc_b): $reason"
    exit 1
    ;;
esac
