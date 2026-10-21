#!/usr/bin/env bash
# Sourced from on-prompt.sh (not standalone-wired). A PR merge-on-approval watcher
# (skills/ama-bitbucket-api/scripts/pr-merge-watch.sh, started detached by
# pr-created-reviewer-dm-reminder.sh) dies with a reboot or a killed process tree. Its pending
# marker (harness-state/prs/pending/<slug>-<id>: pid, origin sid, started, slug, id) outlives
# it, so every prompt in any interactive session restarts a dead one -- silently, no model
# involvement, same stance as reminder-check.sh. Fork budget: no markers = one glob.
_pw_dir="${CLAUDE_STATE_DIR:-$HOME/.claude/harness-state}/prs/pending"
for _pw_f in "$_pw_dir"/*; do
  [ -f "$_pw_f" ] || continue
  { read -r _pw_pid; read -r _pw_sid; read -r _; read -r _pw_slug; read -r _pw_id; } < "$_pw_f"
  [ -n "${_pw_pid:-}" ] && kill -0 "$_pw_pid" 2>/dev/null && continue
  [ -n "${_pw_slug:-}" ] && [ -n "${_pw_id:-}" ] || { rm -f "$_pw_f"; continue; }
  _pw_script="$HOME/.claude/skills/ama-bitbucket-api/scripts/pr-merge-watch.sh"
  [ -f "$_pw_script" ] || break
  rm -f "$_pw_f"   # the restarted watcher writes a fresh marker with its own pid
  { nohup bash "$_pw_script" "$_pw_slug" "$_pw_id" ${_pw_sid:+--sid "$_pw_sid"} >/dev/null 2>&1 & } 2>/dev/null
  disown 2>/dev/null || true
done
# Review-request monitor (pr-review-watch.sh, singleton): start it when no live pid -- covers
# fresh install, reboot and a cleaned pid file alike. One read + kill -0 per prompt.
_pw_pid=""; { read -r _pw_pid < "${CLAUDE_STATE_DIR:-$HOME/.claude/harness-state}/prs/review-watch.pid"; } 2>/dev/null
if ! { [ -n "$_pw_pid" ] && kill -0 "$_pw_pid" 2>/dev/null; }; then
  _pw_script="$HOME/.claude/skills/ama-bitbucket-api/scripts/pr-review-watch.sh"
  [ -f "$_pw_script" ] && [ -z "${PR_WATCH_NO_SPAWN:-}" ] && { { nohup bash "$_pw_script" >/dev/null 2>&1 & } 2>/dev/null; disown 2>/dev/null || true; }
fi
unset _pw_dir _pw_f _pw_pid _pw_sid _pw_slug _pw_id _pw_script
