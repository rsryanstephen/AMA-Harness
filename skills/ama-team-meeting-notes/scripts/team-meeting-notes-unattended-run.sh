#!/usr/bin/env bash
# Unattended Monday 9:00 SAST team-meeting-notes run. Scheduled-task target
# (AMA-Harness-Team-Meeting-Notes-Ping, Monday only, InteractiveToken -- runs only while
# the user is logged on, same guarantee level as every other Ping).
#
# Unlike fleet-health/embs (detection-only), this drives the real ama-standup-notes'
# sibling `ama-team-meeting-notes` skill headlessly -- GENERATIVE. Unlike
# ama-standup-notes' own unattended companion, Step 6 here is a REAL Slack send, not a
# draft: the only reader is the user's own DM, and the whole point is the notification a
# draft can't give. See SKILL.md's "Unattended companion" section for the full reasoning
# behind every decision in this script.
set -uo pipefail

# Task Scheduler defaults a task's working directory to %windir%\System32 -- same trap
# documented in standup-unattended-run.sh (two dead sessions, unwritable cwd, no chat file).
harness="$(git -C "$HOME/.claude/skills" rev-parse --show-toplevel 2>/dev/null)"
cd "${harness:-$HOME}" 2>/dev/null || true

. "$HOME/.claude/hooks/lib-harness-repos.sh"
. "$HOME/.claude/hooks/lib-claude-paths.sh"

LOG="$(hstate logs team-meeting-notes-ping.log)"
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

LASTRUN="$(hstate standup .team-meeting-notes-lastrun)"
DIGEST="$(hstate standup .team-meeting-notes-digest)"

# FORCE seam (2026-09-01). Without it this script cannot be exercised on any day but Monday,
# so a change to it could only ever be validated by waiting a week for the real fire -- which
# is a large part of why its failures went unnoticed for as long as they did. Same idea as
# vpn-dns-probe.ps1's -SelfTest and vpn-dns-outage-logger.sh's VPN_DNS_TICKET_FILE.
# Bypasses ONLY the two scheduling guards; everything after this point is the real run,
# including the real Slack send and Step 8's Jira transitions. Never set it in the task.
FORCE="${TEAM_MEETING_FORCE_RUN:-0}"

# Belt-and-suspenders Monday check -- the Task Scheduler trigger is already Monday-only,
# this just guards against a drifted/misconfigured task.
dow="$(date +%u)"
if [ "$dow" -ne 1 ] && [ "$FORCE" != "1" ]; then
  log "skip: not Monday (day $dow)"
  exit 0
fi

today="$(date +%F)"
if [ -s "$LASTRUN" ] && [ "$FORCE" != "1" ]; then
  last="$(tr -d ' \r\n' < "$LASTRUN")"
  if [ "$last" = "$today" ]; then
    log "skip: already ran today ($today)"
    exit 0
  fi
fi
[ "$FORCE" = "1" ] && log "FORCED run (TEAM_MEETING_FORCE_RUN=1) -- scheduling guards bypassed"

# No dedicated "enabled" key -- an empty user.slackUserId is the off switch, same
# convention as standup's empty notifyTargets.$MODE.
TARGET="$(hr_config '.user.slackUserId' '')"
[ -n "$TARGET" ] || { log "no user.slackUserId configured -- nothing to send"; exit 0; }

if ! command -v claude >/dev/null 2>&1; then
  log "claude CLI not on PATH -- cannot run headless"
  printf 'Unattended team-meeting-notes run FAILED %s: claude CLI not on PATH (task env).\n' "$today" >> "$DIGEST"
  exit 1
fi

# Same post-wake race as standup's -- a caught-up fire lands before the network and the MCP
# connectors are back. See hooks/lib-unattended-ready.sh.
. "$HOME/.claude/hooks/lib-unattended-ready.sh"
wait_until_online log || true

# Wait for THIS SAME Monday's daily stand-up note before doing any real work. Two jobs,
# not one: (1) it's the freshest source for Thursday/Friday's per-ticket explanations --
# without it, that note doesn't exist until standup's OWN 9:00 run writes it; (2) it
# staggers this task's `claude -p` launch away from standup's, so the two don't append to
# sessions.txt's session-start log at the same instant. The task's own trigger stays a
# literal 9:00, matching the user's instruction -- the wait lives here, not in the schedule.
STANDUP_NOTE="$(hscratch standup "standup-notes-$today.md")"
sleep 60
waited=60
found=0
for i in $(seq 1 19); do
  if [ -f "$STANDUP_NOTE" ]; then
    found=1
    break
  fi
  sleep 60
  waited=$((waited + 60))
done
if [ "$found" = 1 ]; then
  log "standup note found after ${waited}s -- using it for Thursday/Friday coverage"
else
  log "standup note not found after ${waited}s -- proceeding on the Jira-changelog fallback"
fi

# 1500s (25min) -- same generous cap as standup's, for the same reason: no one waits on it.
TO=""; command -v timeout >/dev/null 2>&1 && TO="timeout 1500"

# Same fix as standup-unattended-run.sh, same root cause: `claude -p` terminates
# background tasks after 600s, which reads as a failure if any step is delegated and
# waited on. The prompt below forbids that; this is belt-and-braces.
export CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0

# ATLASSIAN ACCESS, stated up front (2026-09-01). This run FAILED on 2026-08-31 with
# "the claude.ai Atlassian MCP connector is not authenticated in this session, so Step 1's
# CQL lookup and Step 3's HTML read can't run -- there is no other way", and gave up. There
# IS another way, and it was already permitted: --allowedTools grants Skill and Bash, and the
# harness has ama-confluence-api / ama-jira-api, which are REST + $ATLASSIAN_API_TOKEN and
# need no connector at all. A headless task can never complete an interactive OAuth consent,
# so the MCP connector is the ONE Atlassian path that structurally cannot work here -- and
# nothing told the run that. Now it does, explicitly, before it can conclude otherwise.
prompt="Run the ama-team-meeting-notes skill, unattended, for the current cycle. \
ATLASSIAN ACCESS FIRST: the claude.ai Atlassian MCP connector is NOT available on this \
unattended path and never will be -- a headless run cannot complete its OAuth consent. Do \
NOT test for it, do NOT report it as a blocker, and do NOT conclude a step is impossible \
because of it. Every Confluence and Jira operation here goes through REST with \
\$ATLASSIAN_API_TOKEN via Skill(ama-confluence-api) and Skill(ama-jira-api) -- CQL search, \
reading page HTML, reading changelogs, listing transitions and transitioning issues all \
have documented REST recipes there. Use \
Step 1's UNATTENDED VARIANT (a single reference page via CQL limit=1, window = \
[referencePage.created, now) -- do NOT look for a page pair, do NOT stop to ask whether \
this week's page exists, it deliberately does not yet). Follow Steps 2-7 exactly as \
written, INCLUDING Step 4's real-movement changelog filter: a Done/Test Complete \
candidate only counts if it moved into Ready to Test/Test Complete/Done FROM something \
else DURING the window -- exclude any ticket already sitting in one of those three at \
window start (check its first in-window status-change fromString per the skill's exact \
rule). ALSO apply Step 6's bulk-sweep collapse (same transition, same day, 3+ tickets -> \
ONE line, never N bare links) and the 12-item importance cap with NO 'no epic' bucket -- \
rank production bug/hotfix > regression > epic-summary line > routine task, same cap and \
ranking for This week. Also the optional-explanation rule under Step 7's ticket list: most tickets \
get NOTHING beneath their link, a ticket earns 1-2 lines only when its title alone would \
not tell a reader what happened. Source those explanations from that week's \
~/.claude/scratch/standup/standup-notes-<date>.md files first (Read/Glob them for the window's weekdays) \
-- use an explanation only if it signals a real complication (bounced status, hotfix, \
blocked, defect found in review/deploy), never routine 'shipped, verified' text; a ticket \
not covered by any daily note falls back to its own Jira changelog, add a line only if the \
transition path itself is non-trivial. ALSO produce Step 7's client-mail/decisions/action-items \
block, week-window variant: two extra Gmail search_threads queries \
(to:<user.email> from:(clientMail.domains) and the reverse, after:<windowStart date>) for \
Client mail DISCOVERY ONLY -- for every candidate thread id, call get_thread(threadId, \
'MINIMAL') and judge reply-state from get_thread's result, NEVER from search_threads's \
message list (it silently truncates to the 5 oldest messages per thread and can read \
backwards or drop a whole thread), one bullet per thread naming who and the ask's state; \
before rendering, check ~/.claude/harness-state/standup/.standup-dismissed.json and drop \
any item whose key matches unless there is new activity after its dismissedOn date; every \
Zoom summary \
(stand-ups AND team meetings, both kinds) within [windowStart, windowEnd) for Decisions and \
Action items -- discovered per ama-standup-notes Step 3b's Zoom search, NOT from a Slack \
channel, dropping only notes whose title matches standup.actionItems.meetingTitleExcludePatterns \
(titles only, NOT a privacy boundary -- judge each item's content and drop anything \
personal before it reaches the shared Jira issue) -- \
read via hub_get_file_content, merged into the SAME ledger file \
(~/.claude/harness-state/standup/.standup-action-items.json) that ama-standup-notes writes -- do not create a \
second store, and never rewrite firstSeen on an existing entry, and once it is written run \
skills/ama-standup-notes/scripts/standup-forms-mirror.sh then skills/ama-standup-notes/scripts/standup-confluence-mirror.sh \
to mirror it into Atlassian Forms and onto the action-items Confluence page, the second even when the first fails \
(non-zero exit -- log it and carry on, never abort); plus a Slack sweep \
(slack_search_public_and_private, from:<user.slackUserId>, mpim/im, over the window) read \
via slack_read_thread/slack_read_channel for decisions/action items anyone posted in a \
thread the user is in. Persist ledger changes only after Step 4's gates in the main skill \
would apply (i.e. once you have real data, not speculatively). Do NOT stop for approval on \
Step 7's blocks -- \
no one is here to give it, and nothing here writes to a shared surface yet. Proceed to \
Step 8: promote the selected This-week LEAF tickets to To Do exactly as Step 8 specifies \
(skip anything already at/past To Do, never move backward, list each ticket's available \
transitions via Skill(ama-jira-api)'s REST recipe first -- NOT the \
getTransitionsForJiraIssue MCP tool, which is unavailable here per the note above -- and \
never hardcode a transition id). Before promoting, compare the \
This-week pick count to last week's completed count PER WEEK (completedCount divided by \
Step 2's windowWeeks, never the raw window total -- a skipped meeting inflates it) -- if \
picks exceed that per-week count*1.5 \
(or +3 for a small week), still promote, but note the excess explicitly in your final \
reply so the log carries a visible warning. Then Step 9: write the fixed file \
'~/.claude/scratch/standup/update for team meeting notes.md' with the Write tool (overwrite), exactly as \
Step 9 specifies. Then send a REAL Slack message (mcp__claude_ai_Slack__slack_send_message, \
never the _draft variant) to channel $TARGET with this EXACT shape: line 1 is \
'<@$TARGET>' alone (triggers the notification), then a blank line, then the literal \
'*Team meeting notes*' on its own line (required -- the brevity gate keys its raised \
ceiling on this exact text), then a blank line, then '*Last week*' with its prose summary \
and ticket list (bare https:// URLs, never Slack-link-formatted -- Confluence needs the \
literal URL on paste; ONE ticket URL per bullet line, never two on a line, per Step 7), \
then a blank line, then '*This week*' with its prose estimate and \
ticket list, same URL rules, then a blank line, then '*Client mail*', '*Decisions*', and \
'*Action items*' as separate blocks in that order (each omitted entirely if empty -- \
never a bare heading), then a blank line, then a line 'Promoted to To Do: <keys>' or \
'Promoted to To Do: none'. Before sending, count this message's prose words the same way \
slack-brevity-gate.sh does (strip fenced/inline-code spans, count whitespace-separated \
tokens containing an alnum) and remember the number. If the send tool call is DENIED, put \
the gate's own deny reason verbatim in your final reply along with 'FAILED:' -- it already \
states the exact count and limit, don't paraphrase it. Do ALL of this SYNCHRONOUSLY in \
this process -- never spawn a subagent or background task and never wait on one. Reply \
with ONLY the word DONE (optionally followed by the over-promotion warning or the word \
count you computed), or FAILED: and the error."

run_once() {
  out="$($TO claude -p "$prompt" \
    --model sonnet \
    --allowedTools Skill,Bash,Read,Write,Grep,Glob,mcp__claude_ai_Slack__slack_send_message,mcp__claude_ai_Gmail__search_threads,mcp__claude_ai_Gmail__get_thread,mcp__claude_ai_Slack__slack_search_public_and_private,mcp__claude_ai_Slack__slack_read_thread,mcp__claude_ai_Slack__slack_read_channel,mcp__claude_ai_Zoom_for_Claude__search,mcp__claude_ai_Zoom_for_Claude__hub_get_file_content,mcp__claude_ai_Google_Calendar__list_events \
    2>>"$LOG")" || out=""
}
run_once
case "$out" in *"spend limit"*|*"usage limit"*|*"rate limit"*) printf '%s %s\n' "$(date '+%F %T')" "$(basename "$0")" >> "$(hstate notices unattended-blocked.txt)"; log "BLOCKED by a spend/usage limit -- no work done this run";; esac
# The claude.ai Slack/Gmail connector tools are intermittently ABSENT from a headless session
# (2026-09-07 09:11 here, 2026-09-06 20:17 in the support monitor's send leg; the 09-01 forced
# run had them). One retry after a pause, then give up and hand the user the notes file.
case "$out" in
  *DONE*) ;;
  *)
    if printf '%s' "$out" | grep -qiE 'slack[^.]{0,80}(absent|unavailable|not available|no match|not found)|(absent|unavailable)[^.]{0,80}slack'; then
      log "Slack connector tools absent from the headless session -- retrying once in 120s"
      sleep 120
      run_once
    fi
    ;;
esac

case "$out" in
  *DONE*)
    printf '%s\n' "$today" > "$LASTRUN"
    # Success stamp read by check-scheduled-tasks.ps1: a forced/manual run never updates the
    # task's LastTaskResult, so without this a fixed task stays RISK until its next real fire.
    : > "$(hstate notices .task-ok-AMA-Harness-Team-Meeting-Notes-Ping)"
    printf 'Unattended team-meeting-notes run %s: sent to your DM.\n' "$today" >> "$DIGEST"
    # Canvas mirror in the wrapper, same reason as standup-unattended-run.sh. Degrades.
    bash "$HOME/.claude/skills/ama-standup-notes/scripts/standup-slack-canvas-mirror.sh" >> "$LOG" 2>&1 \
      || log "canvas mirror failed (exit $?) -- carry on"
    # 4000, not 200. The run's reply is the ONLY place its out-of-band findings surface, and
    # 200 chars silently ate a security-relevant one: the 2026-09-01 forced run reported a
    # prompt-injection attempt found while sweeping Slack, and the log cut off mid-sentence
    # at "a message posi" -- the substance was unrecoverable. A success reply is short in the
    # normal case, so a larger cap costs nothing and only pays out when there is something
    # unusual to say, which is exactly when it must not be truncated.
    log "sent to $TARGET -- reply: $(printf '%s' "$out" | head -c 4000)"
    ;;
  *)
    # Also raised from 200: this text goes into the DIGEST the user actually reads, and the
    # 2026-08-31 failure reached them cut off mid-word ("...there is no othe"), hiding that
    # the run had wrongly concluded no Atlassian path existed. Kept smaller than the success
    # cap because the digest is injected into prompt context.
    reason="$(printf '%s' "$out" | head -c 1200)"
    # Same caveat as standup's: the Slack send precedes the DONE reply, so an empty reply
    # does not mean nothing was posted.
    [ -n "$reason" ] || reason="empty reply -- likely hit the ${TO:-no} timeout mid-run; work may be part-done, CHECK whether the message was already posted before re-running"
    printf 'Unattended team-meeting-notes run FAILED %s: headless run did not confirm (%s). If the notes were written, they are at ~/.claude/scratch/standup/update for team meeting notes.md -- send them by hand.\n' "$today" "$reason" >> "$DIGEST"
    log "run failed: $reason"
    exit 1
    ;;
esac
