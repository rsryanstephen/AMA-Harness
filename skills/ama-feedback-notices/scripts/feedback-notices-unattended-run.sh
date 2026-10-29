#!/usr/bin/env bash
# Daily unattended client-feedback monitor. Scheduled-task target
# (AMA-Harness-Feedback-Notices, daily 08:00 local = SAST on this box, InteractiveToken --
# runs only while the user is logged on, same caveat as the sibling monitors).
#
# The AMA feedback form arrives from .feedbackNotices.senders (no-reply@example-app.com)
# with subject "<.feedbackNotices.subjectPrefix> Ref:NNNNNNN". The SAME sender also mails
# temporary passwords and verification codes, so the Gmail query is sender AND subject
# prefix -- never sender alone -- and leg A is told to open matching threads only.
#
# Three parts, modelled on support-notices-unattended-run.sh (same two-leg guarantee: no
# LLM leg holds a write tool, the wrapper does every local write):
#   leg A  -- Gmail READ only (search_threads + get_thread). Returns one JSON object per
#             NEW feedback mail: summary, verbatim feedback, ticket sections.
#   wrapper -- dedupes on Gmail message id AND Ref number (feedback-notices-record.sh),
#             writes the Jira payload, creates the ticket under .feedbackNotices.epicKey
#             via jira-create-issue.sh (Task, assignee = user, backlog section by kind),
#             records the ledger row. A failed create is NOT recorded, so it retries tomorrow.
#   leg B  -- slack_send_message only. DMs .feedbackNotices.reportTarget with the @mention
#             (hr_self_mention; slack-brevity-gate rule 3) + one line per ticket with its link.
#             Sent only when something was created or failed -- a clean day is silent
#             (AGENTS.md: a monitor pings a human only when there is an ISSUE).
#
# Seams: FEEDBACK_NOTICES_DRAFT_ONLY=1 runs leg A for real and prints what WOULD be created
# (payload + DM text) -- no Jira, no Slack, no ledger, no stamp; FEEDBACK_NOTICES_LOOKBACK_DAYS=N
# overrides the search window (the ledger, not the window, is what prevents duplicates).
set -uo pipefail

# Task Scheduler's default cwd is System32 (unwritable) -- land somewhere real first.
harness="$(git -C "$HOME/.claude/skills" rev-parse --show-toplevel 2>/dev/null)"
cd "${harness:-$HOME}" 2>/dev/null || true

. "$HOME/.claude/hooks/lib-harness-repos.sh"
. "$HOME/.claude/hooks/lib-claude-paths.sh"

SKILLDIR="$HOME/.claude/skills/ama-feedback-notices"
RECORD="$SKILLDIR/scripts/feedback-notices-record.sh"
CREATE="$HOME/.claude/skills/ama-jira-api/scripts/jira-create-issue.sh"
LOG="$(hstate logs feedback-notices.log)"
DIGEST="$(hstate notices .feedback-notices-digest)"
LASTDAY="$(hstate notices .feedback-notices-lastday)"
TASK_OK="$(hstate notices .task-ok-AMA-Harness-Feedback-Notices)"
DRAFT="${FEEDBACK_NOTICES_DRAFT_ONLY:-0}"

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }
digest() { printf '%s\n' "$1" >> "$DIGEST"; }
blocked() { case "$1" in *"spend limit"*|*"usage limit"*|*"rate limit"*) printf '%s %s\n' "$(date '+%F %T')" "$(basename "$0")" >> "$(hstate notices unattended-blocked.txt)"; log "BLOCKED by a spend/usage limit -- no work done this run";; esac; }
fail() {  # $1 reason -> digest + log, exit 1
  log "FAILED: $1"
  digest "Client-feedback monitor FAILED $(date +%F): $(printf '%s' "$1" | head -c 1200)"
  exit 1
}

today="$(date +%F)"
# FEEDBACK_NOTICES_FORCE=1 (feedback-next.sh: mail that landed after today's 08:00 run) skips
# the once-a-day guard -- safe, the ledger is what prevents duplicate tickets.
if [ "$DRAFT" != "1" ] && [ "${FEEDBACK_NOTICES_FORCE:-0}" != "1" ] && [ -s "$LASTDAY" ] && [ "$(tr -d ' \r\n' < "$LASTDAY")" = "$today" ]; then
  log "skip: already ran today ($today)"
  exit 0
fi

EPIC="$(hr_config_required '.feedbackNotices.epicKey')" || { log "config missing: .feedbackNotices.epicKey"; exit 1; }
PREFIX="$(hr_config_required '.feedbackNotices.subjectPrefix')" || { log "config missing: .feedbackNotices.subjectPrefix"; exit 1; }
TARGET="$(hr_config '.feedbackNotices.reportTarget' '')"
FROMS="$(jq -r '[.feedbackNotices.senders[]? | "from:" + .] | join(" ")' < "$HR_CONFIG_FILE" 2>/dev/null | sed 's/\r$//')"
[ -n "$FROMS" ] || { log "config missing: .feedbackNotices.senders"; exit 1; }
LOOKBACK="${FEEDBACK_NOTICES_LOOKBACK_DAYS:-$(hr_config '.feedbackNotices.lookbackDays' 7)}"
ASSIGNEE="$(hr_config_required '.user.jiraAccountId')" || exit 1
EPIC_FIELD="$(hr_config '.atlassian.epicLinkFieldId' '<epicLinkFieldId>')"
JIRA_HOST="$(hr_config_required '.atlassian.cloudId')" || exit 1
PROJECT="${EPIC%%-*}"
since_q="$(date -d "$LOOKBACK days ago" +%Y/%m/%d 2>/dev/null)" || { log "date arithmetic failed"; exit 1; }

if ! command -v claude >/dev/null 2>&1; then
  log "claude CLI not on PATH -- cannot run headless"
  digest "Client-feedback monitor FAILED $today: claude CLI not on PATH (task env)."
  exit 1
fi
if [ "$DRAFT" != "1" ]; then
  . "$HOME/.claude/hooks/lib-unattended-ready.sh"
  wait_until_online log || true
fi
# claude -p terminates background tasks after 600s -- both prompts forbid them anyway.
export CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0
TO_A=""; TO_B=""
if command -v timeout >/dev/null 2>&1; then TO_A="timeout 900"; TO_B="timeout 300"; fi

# Already-handled list goes INTO the prompt so leg A does not spend a get_thread on each old
# mail; the wrapper re-checks the ledger anyway before creating anything.
skip_list="$(bash "$RECORD" list | awk -F'\t' '{printf "%s Ref:%s; ", $1, $3}')"

prompt_a="Unattended sweep of the AMA client-feedback form mailbox. Use ONLY the two Gmail tools \
named here, do all work synchronously (never spawn or wait on a subagent or background task), \
and create nothing anywhere.

1. Call mcp__claude_ai_Gmail__search_threads ONCE: query {$FROMS} subject:\"$PREFIX\" after:$since_q \
-- view THREAD_VIEW_MINIMAL, pageSize 50.
2. A candidate is a thread whose FIRST message is from one of those senders AND whose subject \
starts with '$PREFIX'. Ignore every other mail from these senders -- they also send temporary \
passwords and verification codes; never open those and never repeat any credential.
3. Skip a candidate whose first-message Gmail id OR whose Ref number is in this already-handled \
list: ${skip_list:-(none)}
4. For each remaining candidate call mcp__claude_ai_Gmail__get_thread with messageFormat \
PLAIN_TEXT and read ONLY its first message -- the form submission: 'I would like to find out \
about: <category>', 'Description:' (the feedback itself), 'Contact preferences', the contact's \
email, a phone number, 'Additional comments'.

Then reply in EXACTLY this shape and nothing else (no code fences):
DONE
---JSON---
<a JSON array with one object per remaining candidate, or [] when there is none>
---END---

Object fields, all strings unless noted: msgid (Gmail id of the FIRST message), received \
(YYYY-MM-DD, that message's UTC date), ref (the digits after 'Ref:' in the subject), category, \
contactEmail, contactName (the name if the mail gives one, else the email's local part in Title \
Case with dots as spaces, e.g. robert.smith -> Jacob Smith), \
organisation (the contact email's domain), feedback (the Description text plus any Additional \
comments, verbatim, phone number left out), kind (one of: bug, question, feature), summary \
(at most 90 characters: what the client wants, no 'Ref:' prefix, no client name), requirements \
(array of 1-3 short strings: what must be done to resolve it), acceptance (array of 1-2 \
observable outcomes), howToTest (array of 1 string: environment + the action a human repeats). \
kind: a report of wrong data or broken behaviour is bug; a request for something AMA does not \
offer is feature; anything else is question.
On failure reply with ONLY 'FAILED: <reason>'."

raw_a="$($TO_A claude -p "$prompt_a" \
  --model sonnet \
  --allowedTools mcp__claude_ai_Gmail__search_threads,mcp__claude_ai_Gmail__get_thread \
  2>>"$LOG")"; rc_a=$?
blocked "$raw_a"

# Confirm by a line that is exactly DONE (prose may precede it); FAILED: checked first so an
# explanation containing DONE cannot pass (support-notices parse lesson, <harnessEpicKey>).
case "$raw_a" in *"FAILED:"*) fail "leg A reported: $(printf '%s' "$raw_a" | head -c 600)";; esac
printf '%s\n' "$raw_a" | grep -qx '[[:space:]]*DONE[[:space:]]*' \
  || fail "$(printf 'leg A did not confirm (rc=%s): %s' "$rc_a" "$(printf '%s' "$raw_a" | head -c 600)")"
json="${raw_a#*---JSON---}"
[ "$json" != "$raw_a" ] || fail "leg A reply has no ---JSON--- section"
json="${json%%---END---*}"
json="$(printf '%s\n' "$json" | sed '/^[[:space:]]*```/d')"
printf '%s' "$json" | jq -e 'type=="array"' >/dev/null 2>&1 || fail "leg A JSON did not parse as an array: $(printf '%s' "$json" | head -c 400)"
n_items="$(printf '%s' "$json" | jq 'length')"
log "leg A: $n_items candidate(s) after the skip list (window since $since_q)"

if [ "${n_items:-0}" -eq 0 ]; then
  log "clean window -- nothing new, no DM"
  if [ "$DRAFT" != "1" ]; then printf '%s\n' "$today" > "$LASTDAY"; : > "$TASK_OK"; fi
  exit 0
fi

created=""; failed=""; draft_out=""
while IFS= read -r item; do
  [ -n "$item" ] || continue
  msgid="$(printf '%s' "$item" | jq -r '.msgid // ""' | tr -d '\r')"
  ref="$(printf '%s' "$item" | jq -r '.ref // ""' | tr -d '\r')"
  received="$(printf '%s' "$item" | jq -r '.received // ""' | tr -d '\r')"
  kind="$(printf '%s' "$item" | jq -r '.kind // "question"' | tr -d '\r')"
  name="$(printf '%s' "$item" | jq -r '.contactName // "unknown"' | tr -d '\r')"
  org="$(printf '%s' "$item" | jq -r '.organisation // "-"' | tr -d '\r')"
  summary="$(printf '%s' "$item" | jq -r '.summary // ""' | tr -d '\r' | sed -E 's/^[[:space:]]*Ref:[0-9]+[[:space:]]*-?[[:space:]]*//' | head -c 120)"
  printf '%s' "$msgid" | grep -qE '^[0-9a-f]{16}$' || { log "skip item with bad msgid '$msgid' (Ref:$ref)"; continue; }
  printf '%s' "$ref" | grep -qE '^[0-9]{4,12}$' || { log "skip item $msgid with bad ref '$ref'"; continue; }
  printf '%s' "$received" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' || received="$today"
  [ -n "$summary" ] || summary="Client feedback (see description)"
  if bash "$RECORD" has "$msgid" "$ref"; then log "already handled: $msgid Ref:$ref"; continue; fi

  desc="$(printf '%s' "$item" | jq -r '
    def bullets(a): ((a // []) | if length == 0 then ["(not stated in the mail)"] else . end | map("* " + .) | join("\n"));
    "Client feedback via the AMA feedback form, received \(.received // "-") (Ref:\(.ref)), category: \(.category // "-").\n"
    + "From: \(.contactName // "-") <\(.contactEmail // "-")> (\(.organisation // "-"))\n"
    + "Kind: \(.kind // "-")\n"
    + "Gmail message: \(.msgid // "-") -- once the fix is in Production, reply to Dan in this thread (ama-feedback-notices Prod follow-up). Ship as a hotfix unless regression risk is high.\n\n"
    + "{quote}\n\(.feedback // "(empty)")\n{quote}\n\n"
    + "h2. Requirements\n" + bullets(.requirements) + "\n\n"
    + "h2. Acceptance criteria\n" + bullets(.acceptance) + "\n\n"
    + "h2. How to test\n" + bullets(.howToTest) + "\n"')"
  section="Features"; [ "$kind" = "bug" ] && section="Bugs"

  if [ "$DRAFT" = "1" ]; then
    draft_out="$draft_out
=== WOULD CREATE $PROJECT Task under $EPIC (backlog: $section) ===
Summary: Ref:$ref - $summary
$desc"
    created="$created
PENDING|$ref|$name|$org|$summary"
    continue
  fi

  PAYLOAD="$(hstate tickets ".jira-write-payload-feedback-$ref.json")"
  jq -n --arg s "Ref:$ref - $summary" --arg a "$ASSIGNEE" --arg d "$desc" --arg f "$EPIC_FIELD" --arg e "$EPIC" \
    '{summary: $s, assignee_account_id: $a, description: $d, additional_fields: {($f): $e, priority: {name: "Normal"}}}' > "$PAYLOAD"
  out="$(JIRA_PAYLOAD_FILE="$PAYLOAD" BACKLOG_SECTION="$section" bash "$CREATE" "$PROJECT" Task 2>>"$LOG")"; rc_c=$?
  key="$(printf '%s' "$out" | grep -oE "^$PROJECT-[0-9]+" | head -1)"
  if [ -n "$key" ]; then
    [ "$rc_c" -eq 0 ] || log "$key created with a warning (rc=$rc_c) -- see the lines above"
    bash "$RECORD" add "$msgid" "$received" "$ref" "$key" >>"$LOG" 2>&1 || log "ledger add failed for $msgid"
    created="$created
$key|$ref|$name|$org|$summary"
    log "created $key for Ref:$ref ($name, $org)"
  else
    failed="$failed
$ref|$name|$org"
    log "ticket creation FAILED for Ref:$ref (rc=$rc_c): $(printf '%s' "$out" | head -c 300)"
  fi
done <<< "$(printf '%s' "$json" | jq -c '.[]')"

n_created="$(printf '%s' "$created" | grep -c '|' || true)"
n_failed="$(printf '%s' "$failed" | grep -c '|' || true)"
if [ "$n_created" -eq 0 ] && [ "$n_failed" -eq 0 ]; then
  log "every candidate was already in the ledger -- nothing to report"
  if [ "$DRAFT" != "1" ]; then printf '%s\n' "$today" > "$LASTDAY"; : > "$TASK_OK"; fi
  exit 0
fi

# DM body: one short line per ticket; summary capped to 16 words so four items still clear
# slack-brevity-gate.sh's 120-word ceiling.
plural="tickets"; [ "$n_created" -eq 1 ] && plural="ticket"
body="New client feedback ($n_created $plural created):"
while IFS='|' read -r key ref name org summary; do
  [ -n "$key" ] || continue
  short="$(printf '%s' "$summary" | tr -s ' ' | cut -d' ' -f1-16)"
  body="$body
- Ref:$ref from $name ($org): $short -> https://$JIRA_HOST/browse/$key"
done <<< "$created"
while IFS='|' read -r ref name org; do
  [ -n "$ref" ] || continue
  body="$body
- Ref:$ref from $name ($org): ticket creation FAILED, see $LOG"
done <<< "$failed"

if [ "$DRAFT" = "1" ]; then
  printf '%s\n' "--- leg A JSON ---" "$json" "$draft_out" "--- would DM $TARGET ---" "$(hr_self_mention "$TARGET")" "$body" \
    "--- DRAFT_ONLY: nothing created, sent, recorded or stamped ---"
  log "DRAFT_ONLY: leg A completed, $n_items candidate(s), nothing created or sent"
  exit 0
fi

keys="$(printf '%s' "$created" | awk -F'|' 'NF{printf "%s ", $1}')"
# Tickets exist and are in the ledger from here on -- whatever the DM does, today is done.
printf '%s\n' "$today" > "$LASTDAY"

if [ -z "$TARGET" ]; then
  digest "Client-feedback monitor $today: $n_created ticket(s) created ($keys), $n_failed failed; no .feedbackNotices.reportTarget so no DM."
  log "no reportTarget -- DM skipped; created: $keys"
  : > "$TASK_OK"
  exit 0
fi

mention="$(hr_self_mention "$TARGET")"
[ -n "$mention" ] && body="${mention% }

$body"
prompt_b="Call mcp__claude_ai_Slack__slack_send_message with channel_id $TARGET and, as the \
message text, EXACTLY the text between the two marker lines below -- verbatim, no edits, no \
additions, no signature line, the marker lines themselves excluded. Then reply with ONLY the \
word DONE, or 'FAILED: <reason>'.
---BEGIN MESSAGE---
$body
---END MESSAGE---"
out_b="$($TO_B claude -p "$prompt_b" --model haiku --allowedTools mcp__claude_ai_Slack__slack_send_message 2>>"$LOG")"; rc_b=$?
blocked "$out_b"
case "$(printf '%s' "$out_b" | tr -d '[:space:]')" in
  DONE*)
    digest "Client-feedback monitor $today: $n_created ticket(s) created ($keys)$([ "$n_failed" -gt 0 ] && printf ', %s FAILED' "$n_failed"); DM sent to $TARGET."
    log "DM sent to $TARGET: created $keys; failed $n_failed"
    : > "$TASK_OK"
    ;;
  *)
    reason="$(printf '%s' "$out_b" | head -c 1200)"
    [ -n "$reason" ] || reason="$(printf 'empty reply from the Slack send leg, exit code %s' "$rc_b")"
    digest "Client-feedback monitor $today: $n_created ticket(s) created ($keys) but the Slack DM FAILED ($reason)."
    log "leg B failed (rc=$rc_b): $reason"
    exit 1
    ;;
esac
