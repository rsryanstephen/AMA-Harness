#!/usr/bin/env bash
# Sourced from on-prompt.sh (not standalone-wired). Prompt-time half of the durable reminder
# queue (scripts/reminder.sh header has the design). Two jobs, every prompt, any interactive
# session (on-prompt.sh already exits for headless runs, so unattended sweeps never claim):
#   1. claim due reminders -> $reminder_notice tells the model to act on them NOW. A reminder
#      due while no session was open waits on disk and lands here on the next prompt.
#   2. no live watcher for this sid -> ask the model to start one (once per session per day),
#      so an IDLE open session still fires. Only asked while something is pending.
# Fork budget: empty queue = one glob, zero forks. Expects $sid and $HOOKS_DIR from on-prompt.
reminder_notice=""
_rm_dir="${CLAUDE_STATE_DIR:-$HOME/.claude/harness-state}/reminders"
_rm_pending=0
for _rm_f in "$_rm_dir"/pending/*.rem; do [ -f "$_rm_f" ] && { _rm_pending=1; break; }; done
# Never claim inside resume-rate-limited.sh's unattended `claude --resume -p` run: its transcript
# starts interactive (entrypoint cli), so on-prompt.sh's headless exit may not catch it, and that run
# is told to message nobody -- a reminder claimed there is lost (2026-10-21 review of 2589037).
if [ "$_rm_pending" = 1 ] && [ -n "${sid:-}" ] && [ -z "${AMA_LIMIT_RESUME_RUN:-}" ]; then
  _rm_script="$HOOKS_DIR/../scripts/reminder.sh"
  _rm_got="$(bash "$_rm_script" claim "$sid" 2>/dev/null)"
  if [ -n "$_rm_got" ]; then
    reminder_notice="DURABLE REMINDER(S) DUE, claimed by THIS session (no other session will get them) -- tell the user, then act on each now and ack each finished one with \`bash ~/.claude/scripts/reminder.sh done <id>\` (an unacked reminder is re-queued if this session is later cut off by the usage limit); if its precondition is not met yet, re-queue it with \`bash ~/.claude/scripts/reminder.sh add $sid \"<YYYY-MM-DD HH:MM>\" <full text>\`: ${_rm_got//$'\n'/ | }"
  fi
fi
# Watcher asked for whenever none is alive, reminders pending or not (2026-10-21): it is also what
# wakes an idle session cut off by the usage limit, and it must already be running when the limit hits.
if [ -n "${sid:-}" ] && [ -z "${AMA_LIMIT_RESUME_RUN:-}" ]; then   # an unattended resume run must not start one: it never exits, so the run hangs to its timeout
  _rm_pid=""   # builtin read, not $(cat): this now runs on every prompt of every session
  [ -f "$_rm_dir/watchers/$sid.pid" ] && IFS= read -r _rm_pid < "$_rm_dir/watchers/$sid.pid"
  . "$HOME/.claude/hooks/lib-proc-cmdline.sh"   # pid alive AND running a watcher for THIS sid -- pids restart after a reboot
  if ! proc_alive_running "$_rm_pid" "$sid"; then
    _rm_ask="$_rm_dir/watchers/$sid.asked"
    if [ "$(cat "$_rm_ask" 2>/dev/null)" != "$(date +%F)" ]; then
      date +%F > "$_rm_ask"
      reminder_notice="${reminder_notice:+$reminder_notice Also: }This session has no watcher. Start one now (Bash, run_in_background:true, no other output): \`bash ~/.claude/scripts/reminder-watch.sh $sid\` -- it sleeps at zero token cost and wakes this session only to deliver a due reminder or, after a usage limit cuts this session off, once the limit resets (scripts/limit-resume.py)."
    fi
  fi
fi
