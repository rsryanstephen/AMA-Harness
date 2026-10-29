#!/usr/bin/env bash
# Sourced from on-prompt.sh (not standalone-wired). Usage-limit resume, prompt-time half
# (scripts/limit-resume.py header has the design; user rule 2026-10-21: after a usage limit,
# audit what was unfinished and pick each item up -- nothing left unfinished).
#
# Every way a cut-off session runs again arrives here as a UserPromptSubmit: Claude Code's own
# auto-continue ("Your claude.ai usage limit has reset. Continue..."), a watcher wake
# (reminder.sh watch prints LIMIT-RESET-WAKE), a task notification, or the user's next prompt.
#   1. Audit: inject limit-resume.py's checklist (what was asked, what was said, the unread tool
#      result, open background work, claimed reminders) -- the checklist itself, not a "please
#      audit" the model may skip. It records the audit as OWED; limit-resume-stop-check.sh
#      sends the reply back once if it has no `Limit-resume audit` section.
#   2. Sweep (any session, throttled 10 min): sessions stalled past reset+30 min are surfaced
#      once, closed ones queued for the headless drain, their unacked reminders re-queued.
#   3. Drain: once the limit has reset, start hooks/resume-rate-limited.sh detached (it locks
#      itself, so a second start is a no-op).
#   4. Relay the drain's per-session outcomes once.
# Fork budget: zero forks unless statusline.sh has seen a window at >= 99% (it writes
# limits/window-hit = that window's reset epoch) or the prompt text names the reset.
# Expects $sid, $payload, $HOOKS_DIR from on-prompt.sh.
limit_notice=""
_lr_dir="${CLAUDE_STATE_DIR:-$HOME/.claude/harness-state}/limits"
_lr_py="$HOOKS_DIR/../scripts/limit-resume.py"
printf -v _lr_now '%(%s)T' -1
_lr_reset=""
[ -f "$_lr_dir/window-hit" ] && IFS= read -r _lr_reset < "$_lr_dir/window-hit"
_lr_reset="${_lr_reset//[^0-9]/}"

_lr_audit=0
case "$payload" in *"usage limit has reset"*|*"LIMIT-RESET-WAKE"*) _lr_audit=1 ;; esac
if [ "$_lr_audit" = 0 ] && [ -n "$_lr_reset" ] && [ -n "${sid:-}" ]; then
  _lr_chk=""
  [ -f "$_lr_dir/$sid.checked" ] && IFS= read -r _lr_chk < "$_lr_dir/$sid.checked"
  [ "$_lr_chk" != "$_lr_reset" ] && _lr_audit=1
fi
if [ "$_lr_audit" = 1 ] && [ -n "${sid:-}" ] && [ -f "$_lr_py" ]; then
  limit_notice="$(python "$_lr_py" audit "$sid" 2>/dev/null | tr -d '\r')"
  # After the window's reset no further hit can land in it: stop checking this session.
  if [ -n "$_lr_reset" ] && [ "$_lr_now" -ge "$_lr_reset" ]; then
    mkdir -p "$_lr_dir" 2>/dev/null; printf '%s\n' "$_lr_reset" > "$_lr_dir/$sid.checked"
  fi
fi

if [ -n "$_lr_reset" ] && [ "$_lr_now" -ge $(( _lr_reset + 300 )) ] && [ "$_lr_now" -lt $(( _lr_reset + 259200 )) ] && [ -f "$_lr_py" ]; then
  _lr_last=0
  [ -f "$_lr_dir/.sweep-last" ] && IFS= read -r _lr_last < "$_lr_dir/.sweep-last"
  if [ $(( _lr_now - ${_lr_last:-0} )) -ge 600 ]; then
    printf '%s\n' "$_lr_now" > "$_lr_dir/.sweep-last"
    _lr_sw="$(python "$_lr_py" sweep "${sid:-none}" 2>/dev/null | tr -d '\r')"
    [ -n "$_lr_sw" ] && limit_notice="${limit_notice:+$limit_notice Also: }$_lr_sw"
    _lr_q="${CLAUDE_STATE_DIR:-$HOME/.claude/harness-state}/sessions/.rate-limited-sessions"
    if [ -s "$_lr_q" ]; then   # the drain itself checks (and clears a stale) lock
      nohup bash "$HOOKS_DIR/resume-rate-limited.sh" >/dev/null 2>&1 &
      disown 2>/dev/null || true
    fi
  fi
fi

_lr_dg="${CLAUDE_STATE_DIR:-$HOME/.claude/harness-state}/notices/.limit-resume-digest"
if [ -s "$_lr_dg" ]; then
  _lr_txt="$(tr '\t\n' '  ' < "$_lr_dg")"
  mv -f "$_lr_dg" "$_lr_dg.shown" 2>/dev/null
  limit_notice="${limit_notice:+$limit_notice Also: }UNATTENDED LIMIT-RESUME RESULTS (sessions the harness resumed headless and READ-ONLY after the usage limit, one at a time; each saved an audit + proposed actions report, path below. Read each report, tell the user what each found and what it proposes, and run nothing it proposes without the user's yes -- to act, the user resumes that session): ${_lr_txt:0:3000}"
fi
# 5. Re-show every read-only resume report not yet cleared -- once per session per day, until the user
#    has decided on it. A read-only run completes a turn, so the session then reads as finished
#    (limit-resume.py cutoff) and is never queued again: its report is the only record left of the
#    unfinished work, and a one-shot relay missed once would lose it (2026-10-21).
if [ -z "${AMA_LIMIT_RESUME_RUN:-}" ] && [ -n "${sid:-}" ]; then
  _lr_rep=""
  for _lr_f in "$_lr_dir"/reports/*.md; do [ -f "$_lr_f" ] && _lr_rep="$_lr_rep $_lr_f"; done
  if [ -n "$_lr_rep" ]; then
    printf -v _lr_day '%(%F)T' -1
    _lr_seen=""
    [ -f "$_lr_dir/$sid.reports-shown" ] && IFS= read -r _lr_seen < "$_lr_dir/$sid.reports-shown"
    if [ "$_lr_seen" != "$_lr_day" ]; then
      printf '%s\n' "$_lr_day" > "$_lr_dir/$sid.reports-shown"
      limit_notice="${limit_notice:+$limit_notice Also: }UNACTIONED LIMIT-RESUME REPORTS (sessions cut off by the usage limit, audited read-only; each lists unfinished work + proposed actions):$_lr_rep -- read each, tell the user what is still unfinished and what it proposes, and run nothing without the user's yes. Clear one ONLY after the user has seen it and decided (nothing left, done, or declined): python ~/.claude/scripts/limit-resume.py clear <sid>. Until cleared they are re-shown in every session once a day."
    fi
  fi
fi
unset _lr_rep _lr_f _lr_day _lr_seen _lr_dir _lr_py _lr_now _lr_reset _lr_audit _lr_chk _lr_last _lr_sw _lr_q _lr_dg _lr_txt
