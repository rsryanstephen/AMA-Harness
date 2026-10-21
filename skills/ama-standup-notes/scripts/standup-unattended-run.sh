#!/usr/bin/env bash
# Unattended weekday 9:00 SAST standup-notes run. Scheduled-task target
# (AMA-Harness-Standup-Notes-Ping, weekdays, InteractiveToken: runs only while the
# user is logged on -- same guarantee level as fleet-health/embs).
#
# Unlike the two existing unattended scheduled tasks (fleet-health, embs), which are
# deliberately DETECTION-only, this one drives the real GENERATIVE ama-standup-notes
# skill headlessly. That's safe here specifically because Step 6 is swapped: instead
# of a self-DM-and-send, it calls slack_send_message_draft targeting a configurable
# conversation (standup.notifyMode / .notifyTargets in harness-config.json -- "team",
# "supportChannel", or "selfDm", flip the one value to change target). Slack holds the
# draft unsent until the user reviews and sends it themselves. The draft IS the review
# gate; no custom approval plumbing needed.
set -uo pipefail

# Task Scheduler defaults a task's working directory to %windir%\System32 when nothing
# sets one -- confirmed real: two dead sessions (8959c344, be48d697) got logged with cwd
# C:\WINDOWS\system32 and never got a chat file at all (unwritable there), leaving
# permanent unnamed rows in sessions.txt/sessions.md. Land somewhere real and writable
# before the headless `claude -p` call below inherits whatever cwd we're in.
harness="$(git -C "$HOME/.claude/skills" rev-parse --show-toplevel 2>/dev/null)"
cd "${harness:-$HOME}" 2>/dev/null || true

. "$HOME/.claude/hooks/lib-harness-repos.sh"
. "$HOME/.claude/hooks/lib-claude-paths.sh"

LOG="$(hstate logs standup-notes-ping.log)"
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

LASTRUN="$(hstate standup .standup-notes-lastrun)"
DIGEST="$(hstate standup .standup-notes-digest)"

# Belt-and-suspenders weekday check -- the Task Scheduler trigger is already
# weekday-only, this just guards against a drifted/misconfigured task.
dow="$(date +%u)"
if [ "$dow" -ge 6 ]; then
  log "skip: weekend (day $dow)"
  exit 0
fi

today="$(date +%F)"
if [ -s "$LASTRUN" ]; then
  last="$(tr -d ' \r\n' < "$LASTRUN")"
  if [ "$last" = "$today" ]; then
    log "skip: already ran today ($today)"
    exit 0
  fi
fi

MODE="$(hr_config '.standup.notifyMode' 'team')"
TARGET="$(hr_config ".standup.notifyTargets.$MODE" '')"
TARGET_NAME="$(hr_config ".standup.notifyTargetNames.$MODE" "$MODE")"
# Greeting names real people, so it changes with the target. Empty for selfDm by design.
GREETING="$(hr_config ".standup.notifyGreetings.$MODE" '')"
[ -n "$TARGET" ] || { log "no .standup.notifyTargets.$MODE configured -- nothing to draft"; exit 0; }

if ! command -v claude >/dev/null 2>&1; then
  log "claude CLI not on PATH -- cannot run headless"
  printf 'Unattended standup run FAILED %s: claude CLI not on PATH (task env).\n' "$today" >> "$DIGEST"
  exit 1
fi

# With StartWhenAvailable now enabled, a fire missed while the machine was off/asleep
# arrives the instant it wakes -- ahead of the network and the MCP connectors. Wait for
# reachability first, or the run dies with "every mcp__claude_ai_Slack__* tool is
# unavailable" (confirmed live 2026-08-25). See hooks/lib-unattended-ready.sh.
. "$HOME/.claude/hooks/lib-unattended-ready.sh"
wait_until_online log || true
# 2700s (45min), raised from 1500s (25min) on 2026-09-01. 1500 was being hit for real --
# 2026-08-28 and 2026-09-01 both ended "run failed: empty reply -- likely hit the timeout
# 1500 timeout mid-run", i.e. two of the last five runs died with the work part-done. Nobody
# waits on this, so the cap costs nothing until it is actually needed.
#
# NOT paired with a retry, deliberately. The run sends its Slack message BEFORE replying
# DONE, so a timeout can land after the message went out -- retrying would post the standup
# twice. A longer cap is the safe half of the fix; making the send idempotent would be the
# other half and is a bigger change than this warrants.
TO=""; command -v timeout >/dev/null 2>&1 && TO="timeout 2700"

# THE failure mode that actually bit, twice, 2026-08-21: `claude -p` terminates background
# tasks after 600s ("Background tasks still running after 600s; terminating"), so a run that
# delegates the session sweep to a background subagent and waits on it never reaches DONE --
# it returns prose like "Waiting for the background session-sweep agent" and the case below
# reads that as a failure. The prompt forbids backgrounding (see below); this raises the
# ceiling as belt-and-braces. Safe because `timeout` above still bounds the whole run.
# NOTE: 600s was ALSO the old timeout value, which made this look like a plain timeout and
# sent the first diagnosis down the wrong path. It was never the timeout.
export CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0

# Built separately rather than inline in the prompt: an $() inside a backslash-continued
# string is exactly the shape bash-command-correctness warns about.
if [ -n "$GREETING" ]; then
  opening="the two lines '$GREETING' then 'Updates from me:'"
else
  opening="the single line 'Updates from me:' (no greeting for a self-DM)"
fi

prompt="Run the ama-standup-notes skill for today's window, unattended. Follow Steps \
1-4 exactly as written, INCLUDING Step 3a (mail sent from both configured addresses, \
client mail to/from any clientMail.domains address in BOTH directions -- becomes the \
'Client mail' section, omitted entirely if nothing is in-window; use search_threads ONLY \
to discover candidate thread ids, then call get_thread on EVERY candidate and judge \
reply-state from get_thread's result, NEVER from search_threads's message list -- it \
silently truncates to the 5 oldest messages per thread and can read backwards or drop a \
whole thread; also check ~/.claude/harness-state/standup/.standup-dismissed.json before \
rendering an item, dropping any whose key matches unless there is new activity after its \
dismissedOn date -- and the user's unanswered asks on Slack over 7 days, which becomes \
'Awaiting reply' phrased as an OBSERVATION never a demand, and leading with the ASK not \
with who owes it, e.g. 'GNM notice sign-off -- asked 25 Aug, no reply visible in Slack \
yet', not 'Dan must still respond', omitted if nothing is unanswered), \
Step 3b (the previous meeting's Zoom action items AND decisions the user \
owns or is party to, carried forward in the ledger until addressed/superseded -- becomes \
the 'Decisions' and 'Action items' sections; if the Zoom read fails, degrade to the ledger \
alone and say so, do NOT abort; NEVER add items from a note whose id is already in \
~/.claude/harness-state/standup/.action-items-pulled-docs -- the noon pull already ingested \
it, and re-reading it added reworded duplicates on 2026-10-12 -- append each note you do \
ingest to that file, and match every new item by MEANING against all existing entries \
before adding), and Step 3a's Slack-thread piggyback (decisions/action \
items from the SAME thread reads Step 3a already does for unanswered-asks, no second \
sweep -- also feeds the ledger, kind/source fields per Step 3b). For the Today section, \
work down this ordered list until 5-6 bullets or the sources genuinely run dry -- padding \
is forbidden, a short section from exhausted real sources is correct: (1) movements \
already made today, (2) tickets still In Progress for the user, (3) other active tickets \
expected to move today (status not in Done/Test Complete/Canceled), (4) tickets in To Do \
for the user EXCLUDING anything deprioritized back to To Do this run, (5) open ledger \
action items the user owns -- promote into Today and DROP from Action items that day, \
never render in both, (6) chases -- an unanswered ask or client mail owing the user's \
reply, phrased as the user's OWN next action and naming the BLOCKER not the person, e.g. \
'Follow up on the 15352 decision (blocks 15351)', NEVER 'Chase Reviewer Two for a decision' -- \
these notes go to the very people they name, (7) AMA backlog page next items in page \
order, (8) today's Google Calendar events. \
Once the ledger is written, run \
skills/ama-standup-notes/scripts/standup-forms-mirror.sh (Atlassian Forms) and then \
skills/ama-standup-notes/scripts/standup-confluence-mirror.sh (the action-items Confluence page) -- \
run the second even when the first fails; if either exits non-zero, log the message and carry on, never abort the run. \
Write the notes file with \
the Write tool, never a Bash redirect -- the redirect bypasses standup-empty-section-gate.sh. \
For Step 6: instead of a self-DM, call \
mcp__claude_ai_Slack__slack_send_message_draft targeting channel $TARGET, using Step 6's \
Slack format EXACTLY -- open with $opening, then NO date and NO window line, then related \
tickets grouped under one shared context line, every ticket saying what was actually DONE \
rather than a bare label like 'WAM_HIST annotation', then Client mail, then Decisions, \
then Action items, then Awaiting reply last, each block omitted entirely when empty. The \
literal line 'Updates from me:' \
is required -- the brevity gate keys its raised 320-word ceiling on it. Readers have no \
prior context on this work. Do NOT send a \
real message -- draft only, so the user can review before it actually posts. Skip the \
'anything to add' follow-up question entirely, no one is here to answer it. Make \
reasonable judgment calls the way the skill already directs; do not stop to ask \
anything. Do ALL of the work SYNCHRONOUSLY in this process -- never spawn a subagent or \
background task and never wait on one; the session sweep especially must run inline. \
Apply Step 4a's sanity gates: if the session sweep finds ZERO sessions, ABORT -- write no \
file, draft nothing, reply 'FAILED: session sweep empty' -- because Jira alone silently \
drops all unticketed work. Reply with ONLY the word DONE, or FAILED: and the error."

# Gmail + Slack READ tools are needed by Step 3a, the Zoom doc read by Step 3b. The only
# tool that can reach ANOTHER PERSON is the Slack draft call -- and a draft sits unsent --
# so an unattended run cannot send anything to anyone (see AGENTS.md's "list what skills
# call" rule -- these also belong in settings.template.json's allowlist).
#
# `Write` is granted deliberately, and dropping it silently disables a gate. Local writes
# were always possible via `Bash`, so withholding `Write` bought no safety -- it only meant
# the run wrote standup-notes-<date>.md by redirect, which fires no PreToolUse hook, so
# standup-empty-section-gate.sh never once ran on the one path that executes every morning.
out="$($TO claude -p "$prompt" \
  --model sonnet \
  --allowedTools Skill,Bash,Read,Write,Grep,Glob,mcp__claude_ai_Gmail__search_threads,mcp__claude_ai_Gmail__get_thread,mcp__claude_ai_Slack__slack_search_public_and_private,mcp__claude_ai_Slack__slack_read_thread,mcp__claude_ai_Slack__slack_read_channel,mcp__claude_ai_Zoom_for_Claude__search,mcp__claude_ai_Zoom_for_Claude__hub_get_file_content,mcp__claude_ai_Slack__slack_send_message_draft,mcp__claude_ai_Google_Calendar__list_events \
  2>>"$LOG")" || out=""
case "$out" in *"spend limit"*|*"usage limit"*|*"rate limit"*) printf '%s %s\n' "$(date '+%F %T')" "$(basename "$0")" >> "$(hstate notices unattended-blocked.txt)"; log "BLOCKED by a spend/usage limit -- no work done this run";; esac

case "$out" in
  *DONE*)
    printf '%s\n' "$today" > "$LASTRUN"
    printf 'Unattended standup run %s: draft posted to %s, awaiting your review/send.\n' "$today" "$TARGET_NAME" >> "$DIGEST"
    log "drafted to $TARGET_NAME ($TARGET)"
    # Canvas mirror runs HERE, not in the prompt: it is a nested `claude -p` (~1 min) and
    # would eat the headless Bash tool's 2-min timeout. Degrades, never fails the run.
    bash "$HOME/.claude/skills/ama-standup-notes/scripts/standup-slack-canvas-mirror.sh" >> "$LOG" 2>&1 \
      || log "canvas mirror failed (exit $?) -- carry on"
    ;;
  *)
    reason="$(printf '%s' "$out" | head -c 1200)"
    # An empty reply means the run died without reporting, so the work may be PART-DONE --
    # in particular the Slack message is sent before DONE is returned, so "failed" here does
    # not mean "nothing was posted". Say so, rather than implying a clean no-op.
    [ -n "$reason" ] || reason="empty reply -- likely hit the ${TO:-no} timeout mid-run; work may be part-done, CHECK whether the message was already posted before re-running"
    printf 'Unattended standup run FAILED %s: headless run did not confirm (%s).\n' "$today" "$reason" >> "$DIGEST"
    log "run failed: $reason"
    exit 1
    ;;
esac
