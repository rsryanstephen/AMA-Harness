#!/usr/bin/env bash
# Sourced from on-prompt.sh (not standalone-wired). PROJ-15653: QA/Staging sleep
# schedule (skills/ama-env-sleep) -- AWS scales both to 0 at 22:00 SAST nightly, the PC
# task wakes them weekdays 07:00. Three one-liners, fork-free (on-prompt hot path):
#  1. morning-wake failure digest -> relayed once, then cleared.
#  2. (retired 2026-10-21) the "ask whether to put a woken env back to sleep" reminder --
#     a woken env stays up for the day, the nightly Lambda sleeps it.
#  3. inside the asleep window -> once per session per day: envs are probably down, wake
#     them yourself if the task needs them. Mechanical trigger: a session hitting a dead
#     QA endpoint at 23:00 will not self-recognise "it's the sleep schedule".
# Sets $env_sleep_notice. Expects $sid and $_nudge_due from on-prompt.sh.
env_sleep_notice=""
_es_dir="$HOME/.claude/skills/ama-env-sleep/scripts"
_es_state="${CLAUDE_STATE_DIR:-$HOME/.claude/harness-state}"
_es_digest="$_es_state/notices/.env-sleep-digest"
_es_woken="$_es_state/notices/.env-sleep-woken"
_es_hinted="$_es_state/sessions/.env-sleep-hinted"

if [ -s "$_es_digest" ]; then
  IFS= read -r _es_line < "$_es_digest"
  env_sleep_notice="$_es_line Surface this distinctly (skill ama-env-sleep)."
  : > "$_es_digest"
fi

if [ -f "$_es_dir/lib-env-sleep.sh" ]; then
  . "$_es_dir/lib-env-sleep.sh"
  env_sleep_now
fi

# No "put it back to sleep?" nudge any more (user rule 2026-10-21): an env a session woke
# stays up for the day and the nightly 22:00 Lambda sleeps it. The scale-env.sh ledger
# ($_es_woken) is still written, for the record only. Never scale an env down unasked.

if [ -n "${ES_WINDOW:-}" ] && [ -n "${sid:-}" ]; then
  if [ "$ES_WINDOW" = asleep ]; then
    _es_key="$sid $ES_DAY"
    _es_seen=""
    [ -f "$_es_hinted" ] && read -r -d '' _es_seen < "$_es_hinted"
    case "$_es_seen" in
      *"$_es_key"*) ;;
      *)
        mkdir -p "${_es_hinted%/*}"
        # Keep the ledger small: reset it on the first hint of a new day.
        case "$_es_seen" in *" $ES_DAY"*) printf '%s\n' "$_es_key" >> "$_es_hinted" ;; *) printf '%s\n' "$_es_key" > "$_es_hinted" ;; esac
        env_sleep_notice="$env_sleep_notice QA/Staging are likely ASLEEP now (nightly 22:00 / weekend auto-shutdown to save cost; awake Mon-Fri 07:00-22:00 SAST). If the task needs QA or Staging, wake it yourself without asking: bash $_es_dir/scale-env.sh qa 1 (or staging), allow ~3-5 min for tasks to start. Leave it awake afterwards -- the nightly 22:00 shutdown puts it back to sleep; never ask about, or do, an early scale-down. Skill: ama-env-sleep."
        ;;
    esac
  fi
fi
