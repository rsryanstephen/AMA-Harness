#!/usr/bin/env bash
# Drains the usage-limit resume queue (harness-state/sessions/.rate-limited-sessions): each
# queued session whose window is CLOSED is resumed headless, ONE AT A TIME, told it was cut off
# and that its work may already have been finished elsewhere, and asked to finish only what is
# still incomplete. Rows are appended by statusline.sh (window >= 99%) and by
# scripts/limit-resume.py sweep (a session stalled past its reset with no live owner).
#
# Started by the one-shot AMA-ResumeAtReset-<epoch> task (statusline.sh schedule_resume) AND by
# hooks/limit-resume-check.sh from any session's prompt once the limit has reset -- that task was
# found never to have fired (2026-10-21: no task, 13-row queue undrained, no log), so the drain
# no longer depends on it.
#
# Rules (user, 2026-10-21):
#   - Never clear the queue blind. A row leaves only once its session was resumed, or skipped
#     for a stated reason (owner window still open, transcript idle > 8 days).
#   - Sequential, never all at once: thirteen parallel `claude` processes plus the Defender
#     scan of each froze the PC class of problem. One runs, finishes (or times out), then the next.
#   - Never resume behind an open window: two copies of Claude on one transcript. An open
#     session is woken by its own watcher/auto-continue and audits itself (limit-resume-check.sh).
#   - Each resumed session reports what it found; the outcome goes to a digest relayed once by
#     limit-resume-check.sh, since nobody is watching a headless run.
set -u

. "$HOME/.claude/hooks/lib-claude-paths.sh"
QUEUE="$(hstate sessions .rate-limited-sessions)"
LOG="$(hstate logs resume-rate-limited.log)"
DIGEST="$(hstate notices .limit-resume-digest)"
REPORTS="$(dirname "$(hstate limits reports/.keep)")"
LOCK="${QUEUE}.drain.lock"
PROJECTS="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
PER_SESSION_TIMEOUT="${LIMIT_RESUME_TIMEOUT:-3600}"
CLAUDE_BIN="${LIMIT_RESUME_CLAUDE:-claude}"
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG" 2>/dev/null || true; }

[ -s "$QUEUE" ] || exit 0
# A drain killed by reboot/sleep never runs its EXIT trap; the lock is touched before every
# resume, so one idle past a full session timeout (+10 min) is stale, not a live drain.
if [ -d "$LOCK" ] && [ -n "$(find "$LOCK" -maxdepth 0 -mmin +$(( PER_SESSION_TIMEOUT / 60 + 10 )) 2>/dev/null)" ]; then
  log "stale drain lock (idle > $(( PER_SESSION_TIMEOUT / 60 + 10 )) min) -- removing"; rmdir "$LOCK" 2>/dev/null
fi
mkdir "$LOCK" 2>/dev/null || { log "drain already running (lock $LOCK) -- exit"; exit 0; }
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

# Same live-owner test reminder.sh uses: a ~/.claude/sessions/<pid>.json naming the sid with
# that pid still a claude process.
owner_alive() {
  local sid="$1" sd="${CLAUDE_SESSIONS_DIR:-$HOME/.claude/sessions}" f pid
  [ -d "$sd" ] || return 1
  for f in "$sd"/*.json; do
    [ -f "$f" ] || continue
    grep -q "\"sessionId\":\"$sid\"" "$f" 2>/dev/null || continue
    pid="${f##*/}"; pid="${pid%.json}"
    tasklist.exe //FI "PID eq $pid" //NH 2>/dev/null | grep -qi claude && return 0
  done
  return 1
}

drop_row() {  # remove every row for this sid (the queue held duplicates)
  local tmp="${QUEUE}.tmp.$$"
  # Same key the loop reads (field 1, CR stripped): a row with no `|` or a CRLF never matched
  # `^sid|`, so the loop re-read it forever holding the lock.
  awk -F"|" -v s="$1" '{ k = $1; sub(/\r$/, "", k) } k != s' "$QUEUE" > "$tmp" 2>/dev/null; mv -f "$tmp" "$QUEUE"
}

log "drain start: $(cut -d'|' -f1 "$QUEUE" | sort -u | wc -l) session(s) queued"
while :; do
  sid="$(head -n 1 "$QUEUE" 2>/dev/null | cut -d'|' -f1 | tr -d '\r')"
  [ -n "$sid" ] || break
  # Age is no reason to skip (user, 2026-10-21: "just because they're old doesn't mean the
  # unfinished tasks don't matter") -- the run is read-only, so an old session is as safe to audit
  # as a new one. Only a missing transcript is skipped, and it still reaches the digest for review.
  if [ -z "$(find "$PROJECTS" -maxdepth 2 -name "$sid.jsonl" -print -quit 2>/dev/null)" ]; then
    log "skip $sid: transcript missing"; drop_row "$sid"
    printf '%s\t%s\t-\tskipped\ttranscript missing -- check its chat file by hand for unfinished work\n' "$(date '+%F %T')" "$sid" >> "$DIGEST"
    continue
  fi
  # Queued at 99% of a window, before any hit: most rows never got cut off at all (2026-10-21: 3 of
  # the 4 old rows had no usage_limit_reached record; the 4th had finished). No hit left unfinished
  # -> nothing to resume, and a resume would only spend a Claude run.
  if ! python "$HOME/.claude/scripts/limit-resume.py" cutoff "$sid" >/dev/null 2>&1; then
    log "skip $sid: not cut off (no usage-limit hit left unfinished)"; drop_row "$sid"; continue
  fi
  if owner_alive "$sid"; then
    log "skip $sid: its window is still open -- it resumes and audits itself there"; drop_row "$sid"; continue
  fi
  # Read-only by Claude Code's own enforcement (--permission-mode plan), not by asking nicely: an
  # unattended run with nobody watching could otherwise commit and push, and a develop/hotfix push
  # deploys QA/Staging (user, 2026-10-21: "review what each of these is doing"). The run audits and
  # PROPOSES; nothing it proposes happens until someone reviews the report and resumes the session.
  # The drain runs the audit itself, so the checklist does not depend on plan mode allowing Bash.
  audit="$(python "$HOME/.claude/scripts/limit-resume.py" audit "$sid" 2>/dev/null | tr -d '\r')"
  prompt="Your claude.ai usage limit has reset. This session was cut off by the usage limit and is being resumed UNATTENDED by the harness, possibly hours or days later; nobody is watching, and you are in PLAN MODE: read-only, no edits, commits, pushes, deploys, messages or Jira writes. Do NOT call ExitPlanMode and do NOT start background tasks or watchers. The harness audit of what was in flight when the limit hit: ${audit:-<empty: this session finished its turn after the hit>}. Much of that work may have been finished since by another session or by the user, so check the LIVE state read-only (Jira status, git log on origin -- run git -C <repo> fetch first, local origin/* refs are often stale --, what is deployed, bash ~/.claude/scripts/reminder.sh fired, other sessions' chat files under ~/.claude/Chat files/). No report-scale Redshift queries or API test suites Mon-Fri 9am-5pm ET. Reply with a section headed 'Limit-resume audit': each item, and whether it is already done elsewhere, still incomplete, or needs the user; then a section 'Proposed actions': the exact steps you would take to finish what is incomplete (repo, branch, commands, what each push or deploy would trigger). A human reviews this before anything runs."
  touch "$LOCK" 2>/dev/null
  log "resume $sid read-only (timeout ${PER_SESSION_TIMEOUT}s)"
  out="$(AMA_LIMIT_RESUME_RUN=1 timeout "$PER_SESSION_TIMEOUT" "$CLAUDE_BIN" --resume "$sid" -p "$prompt" --permission-mode plan --no-chrome < /dev/null 2>&1)"; rc=$?
  log "done $sid rc=$rc"
  report="$REPORTS/$sid.$(date +%Y%m%d-%H%M).md"
  printf '%s\n' "$out" > "$report" 2>/dev/null
  name="$(grep -F "$sid" "$HOME/.claude/sessions.txt" 2>/dev/null | head -n 1 | cut -d' ' -f1)"
  printf '%s\t%s\t%s\trc=%s\treport %s -- resume with: claude --resume %s\t%s\n' "$(date '+%F %T')" "$sid" "${name:-?}" "$rc" \
    "$report" "$sid" "$(printf '%s' "$out" | tr '\r\n\t' '   ' | tail -c 600)" >> "$DIGEST"
  drop_row "$sid"
done
log "drain end"

# Delete whichever AMA-ResumeAtReset-* task has fired -- only those whose time has passed.
export MSYS_NO_PATHCONV=1
for t in $(schtasks.exe //query //fo csv //nh 2>/dev/null | grep -oP 'AMA-ResumeAtReset-[0-9]+'); do
  epoch="${t#AMA-ResumeAtReset-}"
  [ "$epoch" -le "$(date +%s)" ] && schtasks.exe //delete //tn "$t" //f >/dev/null 2>&1
done
exit 0
