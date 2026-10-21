#!/usr/bin/env bash
# Sourced from on-prompt.sh (not standalone-wired). Once per calendar day, runs
# scripts/prune-headless-sessions.sh so headless `claude -p` runs never accumulate in
# sessions.md or `Chat files/` again.
#
# This is the scheduler. Per CLAUDE.md's mechanical-triggers rule a recurring task needs a
# hook behind it, not a skill-description match. The user's instruction was explicit:
# "Not only a rerunnable script but an auto rerun. I don't want to have to ask for this
# cleanup again."
#
# NOT hosted in log-session-start.sh, the harness's usual opportunistic-repair point:
# settings.json gives SessionStart a 5s timeout and that hook already spends it on a
# 20-row `find` sweep. UserPromptSubmit has 60s and already hosts every other throttled
# periodic check (aws-notices, embs-coverage, followup, fleet-health).
#
# BACKGROUNDED, unlike its neighbours. Those are pure-bash state-file reads costing
# milliseconds; this one runs two `find`s over ~/.claude/projects and walks ~1000
# statefiles, ~8s warm. Nobody should wait 8s on a prompt for a cleanup they didn't ask
# for, so it detaches and logs. The throttle marker is written BEFORE launching, so a
# crashed or hung run can't retrigger on every prompt for the rest of the day.
#
# Sets no notice variable -- there is nothing for Claude to say about it. Output goes to
# the log for a human (or a later session) to read if a cleanup ever looks wrong.
. "$HOME/.claude/hooks/lib-claude-paths.sh"
_hp_lastrun="$(hstate sessions .headless-prune-lastrun)"
_hp_log="$(hscratch sessions headless-prune.log)"
_hp_today="$(date +%F)"
_hp_prev=""
[ -f "$_hp_lastrun" ] && IFS= read -r _hp_prev < "$_hp_lastrun"

if [ "$_hp_prev" != "$_hp_today" ]; then
  printf '%s' "$_hp_today" > "$_hp_lastrun" 2>/dev/null
  # This hook is reached as ~/.claude/hooks/... , a symlink into the harness repo, so the
  # sibling scripts/ dir is found relative to THIS file, not to ~/.claude.
  _hp_script="$(dirname "${BASH_SOURCE[0]}")/../scripts/prune-headless-sessions.sh"
  if [ -f "$_hp_script" ]; then
    {
      printf '\n=== %s\n' "$(date '+%F %T')"
      nohup bash "$_hp_script" --apply --time-budget 5 2>&1
    } >> "$_hp_log" 2>&1 &
    disown 2>/dev/null || true
  fi
fi
unset _hp_lastrun _hp_log _hp_today _hp_prev _hp_script
