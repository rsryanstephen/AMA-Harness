#!/usr/bin/env bash
# Sourced from on-prompt.sh (not standalone-wired). A PR merge-on-approval watcher
# (skills/ama-bitbucket-api/scripts/pr-merge-watch.sh, started detached by
# pr-created-reviewer-dm-reminder.sh) dies with a reboot or a killed process tree. Its pending
# marker (harness-state/prs/pending/<slug>-<id>: pid, origin sid, started, slug, id) outlives
# it, so every prompt in any interactive session restarts a dead one -- silently, no model
# involvement, same stance as reminder-check.sh. Fork budget: no markers = one glob.
. "$HOME/.claude/hooks/lib-proc-cmdline.sh"   # every "is the recorded pid alive" below: alive AND running that script
_pw_dir="${CLAUDE_STATE_DIR:-$HOME/.claude/harness-state}/prs/pending"
for _pw_f in "$_pw_dir"/*; do
  [ -f "$_pw_f" ] || continue
  { read -r _pw_pid; read -r _pw_sid; read -r _; read -r _pw_slug; read -r _pw_id; } < "$_pw_f"
  proc_alive_running "${_pw_pid:-}" pr-merge-watch && continue
  [ -n "${_pw_slug:-}" ] && [ -n "${_pw_id:-}" ] || { rm -f "$_pw_f"; continue; }
  _pw_script="$HOME/.claude/skills/ama-bitbucket-api/scripts/pr-merge-watch.sh"
  [ -f "$_pw_script" ] || break
  rm -f "$_pw_f"   # the restarted watcher writes a fresh marker with its own pid
  { nohup bash "$_pw_script" "$_pw_slug" "$_pw_id" ${_pw_sid:+--sid "$_pw_sid"} >/dev/null 2>&1 & } 2>/dev/null
  disown 2>/dev/null || true
done
# Feedback-fix Production watchers (ama-feedback-notices feedback-prod-watch.sh): same restart.
# Marker: pid, origin sid, started, ticket, "repo=Projects-N ..." pairs.
for _pw_f in "${CLAUDE_STATE_DIR:-$HOME/.claude/harness-state}"/feedback/pending/*; do
  [ -f "$_pw_f" ] || continue
  { read -r _pw_pid; read -r _pw_sid; read -r _; read -r _pw_slug; read -r _pw_id; } < "$_pw_f"
  proc_alive_running "${_pw_pid:-}" feedback-prod-watch && continue
  [ -n "${_pw_slug:-}" ] && [ -n "${_pw_id:-}" ] || { rm -f "$_pw_f"; continue; }
  _pw_script="$HOME/.claude/skills/ama-feedback-notices/scripts/feedback-prod-watch.sh"
  [ -f "$_pw_script" ] || break
  rm -f "$_pw_f"
  # shellcheck disable=SC2086  # pairs are space-separated repo=Projects-N words
  { nohup bash "$_pw_script" "$_pw_slug" $_pw_id ${_pw_sid:+--sid "$_pw_sid"} >/dev/null 2>&1 & } 2>/dev/null
  disown 2>/dev/null || true
done
# Feedback reply-sent checker (feedback-reply-item.sh watch): reply-pending exists while a
# "send the reply to Dan" action item is open; restart the checker when its pid is gone.
if [ -f "${CLAUDE_STATE_DIR:-$HOME/.claude/harness-state}/feedback/reply-pending" ]; then
  _pw_pid=""; { read -r _pw_pid < "${CLAUDE_STATE_DIR:-$HOME/.claude/harness-state}/feedback/reply-watch.pid"; } 2>/dev/null
  if ! proc_alive_running "$_pw_pid" feedback-reply-item; then
    _pw_script="$HOME/.claude/skills/ama-feedback-notices/scripts/feedback-reply-item.sh"
    [ -f "$_pw_script" ] && { { nohup bash "$_pw_script" watch >/dev/null 2>&1 & } 2>/dev/null; disown 2>/dev/null || true; }
  fi
fi
# Review-request monitor (pr-review-watch.sh, singleton): start it when no live pid -- covers
# fresh install, reboot and a cleaned pid file alike. One read + kill -0 per prompt.
_pw_pid=""; { read -r _pw_pid < "${CLAUDE_STATE_DIR:-$HOME/.claude/harness-state}/prs/review-watch.pid"; } 2>/dev/null
if ! proc_alive_running "$_pw_pid" pr-review-watch; then
  _pw_script="$HOME/.claude/skills/ama-bitbucket-api/scripts/pr-review-watch.sh"
  [ -f "$_pw_script" ] && [ -z "${PR_WATCH_NO_SPAWN:-}" ] && { { nohup bash "$_pw_script" >/dev/null 2>&1 & } 2>/dev/null; disown 2>/dev/null || true; }
fi
# Registered ad-hoc monitors (scripts/durable-monitor.sh): restart any whose pid is gone -- the
# reboot/crash path for things like a ticket-status watcher. Two file reads per marker, no fork.
[ -z "${PR_WATCH_NO_SPAWN:-}" ] && [ -d "${CLAUDE_STATE_DIR:-$HOME/.claude/harness-state}/monitors" ] \
  && bash "$HOME/.claude/scripts/durable-monitor.sh" ensure >/dev/null 2>&1
# Unclaimed-reminder Slack DM: only when the task runs this file directly. Sourced on-prompt means
# a session is open, and that session claims the reminder itself.
[ "${BASH_SOURCE[0]}" = "$0" ] && [ -z "${PR_WATCH_NO_SPAWN:-}" ] \
  && bash "$HOME/.claude/scripts/reminder.sh" slack-unclaimed >/dev/null 2>&1
unset _pw_dir _pw_f _pw_pid _pw_sid _pw_slug _pw_id _pw_script
