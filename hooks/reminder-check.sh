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
if [ "$_rm_pending" = 1 ] && [ -n "${sid:-}" ]; then
  _rm_script="$HOOKS_DIR/../scripts/reminder.sh"
  _rm_got="$(bash "$_rm_script" claim "$sid" 2>/dev/null)"
  if [ -n "$_rm_got" ]; then
    reminder_notice="DURABLE REMINDER(S) DUE, claimed by THIS session (no other session will get them) -- tell the user, then act on each now; if its precondition is not met yet, re-queue it with \`bash ~/.claude/scripts/reminder.sh add $sid \"<YYYY-MM-DD HH:MM>\" <full text>\`: ${_rm_got//$'\n'/ | }"
  fi
  _rm_pid="$(cat "$_rm_dir/watchers/$sid.pid" 2>/dev/null)"
  if [ -z "$_rm_pid" ] || ! kill -0 "$_rm_pid" 2>/dev/null; then
    _rm_ask="$_rm_dir/watchers/$sid.asked"
    if [ "$(cat "$_rm_ask" 2>/dev/null)" != "$(date +%F)" ]; then
      date +%F > "$_rm_ask"
      reminder_notice="${reminder_notice:+$reminder_notice Also: }Durable reminders are pending and this session has no watcher. Start one now (Bash, run_in_background:true, no other output): \`bash ~/.claude/scripts/reminder-watch.sh $sid\` -- it sleeps at zero token cost and wakes this session only if it claims a due reminder."
    fi
  fi
fi
