#!/usr/bin/env bash
# Weekly unattended "address harness gaps" run. Scheduled-task target
# (AMA-Harness-Gaps-Review, DAILY 15:00 local, InteractiveToken -- runs only while the user
# is logged on, same caveat as the other Ping tasks). Daily on purpose: the weekly usage
# window's reset may not sit on a fixed weekday, so the task fires every afternoon and THIS
# script decides whether today is the day before the reset, from the live resets_at.
#
# Guards, in order (HARNESS_GAPS_FORCE_RUN=1 skips all four; HARNESS_GAPS_NOW=<epoch>
# overrides the clock for tests):
#   1. live weekly usage via hooks/lib-claude-usage.sh -- unknown => statusline state file
#      if <24h old, else skip (never assume 0%);
#   2. reset must fall on TOMORROW's local date;
#   3. not already run for this reset (LASTRUN holds the reset's local date);
#   4. ACCOUNT-WIDE weekly usage >= 90% => postponed to next week (no stamp, so next week's
#      trigger runs); a model at its own weekly cap is dropped from HARNESS_GAPS_MODELS
#      instead, and only all-candidates-capped postpones;
#   5. no unreviewed `- [session ` lines => stamp and exit.
#
# Then two headless legs on ONE session (Claude Code can't approve ExitPlanMode headless):
#   leg 1 -- --permission-mode plan, strongest model that resolves: HARNESS_GAPS_MODELS
#            (default "fable opus") tried in order, an unrecognized/unserved alias => next.
#            Reads the ledger + AGENTS.md, replies PLANNED + the plan. Read-only by Claude
#            Code's own enforcement, not by asking nicely.
#   leg 2 -- --resume the same session, acceptEdits, same model as leg 1. Executes the plan,
#            commits its own paths only, pushes, replies DONE + ---DIGEST---.
# The wrapper does every local write (lastrun, digest, saved plan) itself.
set -uo pipefail

harness="$(git -C "$HOME/.claude/skills" rev-parse --show-toplevel 2>/dev/null)"
cd "${harness:-$HOME}" 2>/dev/null || true

. "$HOME/.claude/hooks/lib-claude-paths.sh"
. "$HOME/.claude/hooks/lib-claude-usage.sh"

LOG="$(hstate logs harness-gaps-review.log)"
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }
DIGEST="$(hstate notices harness-gaps-review.txt)"
LASTRUN="$(hstate harness .harness-gaps-lastrun)"
GAPS="${HARNESS_GAPS_FILE:-$HOME/.claude/harness-gaps.md}"
FORCE="${HARNESS_GAPS_FORCE_RUN:-0}"
now="${HARNESS_GAPS_NOW:-$(date +%s)}"
today="$(date -d "@$now" +%F)"
tomorrow="$(date -d "@$((now + 86400))" +%F)"

digest() { printf '%s\n' "$1" >> "$DIGEST"; log "digest: $1"; }
decide() { log "$1"; [ "${HARNESS_GAPS_DRY_RUN:-0}" = "1" ] && printf 'DECISION: %s\n' "$1"; }

# --- 1. live weekly usage -------------------------------------------------------------
pct=""; reset_epoch=""; capped=""
if ufile="$(claude_usage_fetch)" && usage="$(claude_usage_weekly "$ufile")"; then
  capped="$(claude_usage_capped "$ufile" | paste -sd' ')"
  pct="${usage%%$'\t'*}"; reset_epoch="${usage#*$'\t'}"
else
  # Fallback: statusline's own state file, trusted only when fresh. notified>=90 is a
  # sound ">=90% now" signal (re-arms only under 75%); notified<90 says nothing precise,
  # so the fallback yields a conservative pct of 0/90 plus the file's resets_at.
  sf="$(hstate sessions .usage-state/seven_day)"
  if [ -f "$sf" ] && [ "$(( now - $(date -r "$sf" +%s 2>/dev/null || echo 0) ))" -lt 86400 ]; then
    line="$(head -1 "$sf" 2>/dev/null)"
    [[ "$line" =~ \"notified\":([0-9]+) ]] && { [ "${BASH_REMATCH[1]}" -ge 90 ] && pct=90 || pct=0; }
    [[ "$line" =~ \"resets_at\":\"([0-9]+)\" ]] && reset_epoch="${BASH_REMATCH[1]}"
    log "usage API unavailable -- using statusline state (<24h old): pct=$pct"
  fi
fi
if [ -z "$pct" ] || [ -z "$reset_epoch" ]; then
  if [ "$FORCE" != "1" ]; then
    decide "skip: weekly usage unknown (API failed, statusline state stale/missing)"
    digest "Harness-gaps auto-review $today: SKIPPED -- weekly usage unknown (usage API failed and no fresh statusline state). Re-probe: bash ~/.claude/hooks/lib-claude-usage.sh weekly"
    exit 0
  fi
  pct="${pct:-0}"; reset_epoch="${reset_epoch:-$((now + 3600))}"
fi
reset_day="$(date -d "@$reset_epoch" +%F)"

# --- 2-5. schedule guards -------------------------------------------------------------
if [ "$FORCE" != "1" ]; then
  if [ "$reset_day" != "$tomorrow" ]; then
    decide "skip: not the day before the weekly reset (reset $reset_day, today $today)"; exit 0
  fi
  if [ -s "$LASTRUN" ] && [ "$(tr -d ' \r\n' < "$LASTRUN")" = "$reset_day" ]; then
    decide "skip: already ran for the $reset_day reset"; exit 0
  fi
  if [ "$pct" -ge 90 ]; then
    decide "postponed: weekly usage at ${pct}% (>=90) -- next week"
    digest "Harness-gaps auto-review $today: POSTPONED to next week -- weekly usage already at ${pct}%."
    exit 0
  fi
fi
# A model at its OWN weekly cap is dropped, not the run: account-wide room means the next
# candidate (opus) can still do it. All candidates capped => postponed like the >=90% case.
if [ -n "$capped" ]; then
  keep=""; for m in ${HARNESS_GAPS_MODELS:-fable opus}; do
    case " $capped " in *" $m "*) ;; *) keep="$keep $m" ;; esac
  done
  HARNESS_GAPS_MODELS="${keep# }"
  if [ -z "$HARNESS_GAPS_MODELS" ] && [ "$FORCE" != "1" ]; then
    decide "postponed: every candidate model at its weekly cap ($capped) -- next week"
    digest "Harness-gaps auto-review $today: POSTPONED to next week -- every candidate model at its weekly cap ($capped)."
    exit 0
  fi
  log "model(s) at weekly cap, dropped: $capped -> candidates: ${HARNESS_GAPS_MODELS:-none}"
fi
gapcount="$(grep -cE '^- \[session ' "$GAPS" 2>/dev/null | tr -d '\r\n')"
if [ "${gapcount:-0}" -eq 0 ]; then
  decide "no gaps: ledger has no unreviewed entries"
  [ "$FORCE" = "1" ] || printf '%s\n' "$reset_day" > "$LASTRUN"
  exit 0
fi
decide "would run: weekly ${pct}%, reset $reset_day, $gapcount gap(s), models ${HARNESS_GAPS_MODELS:-fable opus}"
[ "${HARNESS_GAPS_DRY_RUN:-0}" = "1" ] && exit 0

if ! command -v claude >/dev/null 2>&1; then
  log "claude CLI not on PATH -- cannot run headless"
  digest "Harness-gaps auto-review $today: FAILED -- claude CLI not on PATH (task env)."
  exit 1
fi

. "$HOME/.claude/hooks/lib-unattended-ready.sh"
wait_until_online log || true
# claude -p kills background tasks after 600s; both prompts forbid subagents/background.
export CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0
TO1=""; TO2=""
if command -v timeout >/dev/null 2>&1; then TO1="timeout 1800"; TO2="timeout 10800"; fi
new_sid() { powershell.exe -NoProfile -Command '[guid]::NewGuid().ToString()' 2>/dev/null | tr -d '\r\n '; }
SID="$(new_sid)"
[ -n "$SID" ] || { log "could not mint a session id"; exit 1; }
sid8="${SID:0:8}"
PLAN_OUT="$(hscratch harness-gaps "plan-$today-$sid8.md")"
# Strongest model first. Aliases, not ids, so "fable" keeps meaning the latest Fable.
MODELS="${HARNESS_GAPS_MODELS:-fable opus}"; MODEL=""

blocked() { case "$1" in *"spend limit"*|*"usage limit"*|*"rate limit"*) printf '%s %s\n' "$(date '+%F %T')" "$(basename "$0")" >> "$(hstate notices unattended-blocked.txt)"; log "BLOCKED by a spend/usage limit -- no work done this run";; esac; }
# A reply is confirmed by a line that is EXACTLY the marker (prose may precede it);
# FAILED: is checked first so an explanation containing the marker cannot pass.
confirmed() { # $1=text $2=marker
  case "$1" in *"FAILED:"*) return 1;; esac
  printf '%s\n' "$1" | grep -qx "[[:space:]]*$2[[:space:]]*"
}
opus_tier() { # $1 = --output-format json body
  printf '%s' "$1" | jq -r '.modelUsage // {} | keys[]' 2>/dev/null | grep -qiE 'opus|fable|mythos'
}

# --- leg 1: plan --------------------------------------------------------------------
prompt_plan="You are the WEEKLY UNATTENDED harness-gaps review for this harness clone (ticket \
<harnessEpicKey>; never post a Jira wrap-up comment for harness work). No human is watching \
and nobody can answer a question. You are in plan mode: read only, plan now, execute later.

Read ~/.claude/harness-gaps.md (the ledger; its header states the review order: 1 bloat, \
2 did the fix fully fix it, 3 room for improvement, 4 at most one related improvement), \
AGENTS.md, and whatever GATES-AND-HOOKS.md / skill files each entry touches. For EVERY line \
starting '- [session ' decide one of: CLEAR (reviewed, nothing more to do -- delete the line), \
FIX (a concrete code/doc change, then delete the line), or NEEDS USER (a design call or \
question only the user can settle -- the line stays, tagged). Verify each cited SELF-FIXED \
commit exists (git log --oneline) before clearing it. Group the fixes into a short ordered \
plan naming the exact files. Do NOT call ExitPlanMode. Do NOT spawn subagents, agents, or \
background tasks -- work synchronously. Do NOT touch anything under Local Chat Files, \
README.md, or files another session has modified (git status shows them; leave them alone).

Reply with a line that is exactly PLANNED, then the plan (entry-by-entry verdicts, then \
the ordered fix list). On failure reply with ONLY 'FAILED: <reason>'."

for MODEL in $MODELS; do
  log "leg 1 (plan) starting, session $SID, model $MODEL"
  raw1="$($TO1 claude -p "$prompt_plan" \
    --model "$MODEL" --permission-mode plan --session-id "$SID" --output-format json \
    2>>"$LOG")"; rc1=$?
  # Two reasons to try the next alias, both meaning THIS model did no work:
  #  - alias unknown to this CLI (probed 2026-09-14: rc=1, "[claude-code:unrecognized_model]",
  #    empty modelUsage) or not served to this account;
  #  - a spend/usage/rate limit on this model. The weekly pre-check above reads the shared
  #    seven_day bucket, so a per-model cap (Fable's own) can still bite; opus may have room.
  #    If the limit is account-wide the opus attempt fails the same way, one cheap call later,
  #    and the normal FAILED/blocked path below reports it.
  # Anything else (a real reply, a timeout) is not a model problem -- keep it.
  # A failed attempt burns its session id, so mint a fresh one for the retry.
  if [ "$rc1" -ne 0 ] && ! printf '%s' "$raw1" | jq -e '.modelUsage // {} | length > 0' >/dev/null 2>&1 \
     && printf '%s' "$raw1" | grep -qiE 'unrecognized_model|not_found_error|model.*(not (found|available|supported)|does not exist)|spend limit|usage limit|rate limit'; then
    log "model $MODEL unavailable or limited (rc=$rc1) -- trying the next candidate"
    SID="$(new_sid)"; sid8="${SID:0:8}"; PLAN_OUT="$(hscratch harness-gaps "plan-$today-$sid8.md")"
    continue
  fi
  break
done
blocked "$raw1"
text1="$(printf '%s' "$raw1" | jq -r '.result // empty' 2>/dev/null)"
[ -n "$text1" ] || text1="$raw1"
if ! confirmed "$text1" "PLANNED"; then
  reason="$(printf '%s' "$text1" | head -c 1200)"
  [ -n "$reason" ] || reason="$(printf 'empty reply, exit code %s (%s)' "$rc1" "$([ "$rc1" = 124 ] && printf 'killed by %s' "${TO1:-no timeout}" || printf 'not a timeout kill')")"
  digest "Harness-gaps auto-review $today: FAILED -- plan leg did not confirm ($reason)."
  log "leg 1 failed (rc=$rc1): $reason"; exit 1
fi
if ! opus_tier "$raw1"; then
  digest "Harness-gaps auto-review $today: FAILED -- plan leg ran below Opus tier ($(printf '%s' "$raw1" | jq -r '.modelUsage // {} | keys | join(",")' 2>/dev/null)); nothing executed."
  log "leg 1 model below Opus tier"; exit 1
fi
printf '%s\n' "$text1" > "$PLAN_OUT"
log "leg 1 planned -> $PLAN_OUT"
if [ "${HARNESS_GAPS_PLAN_ONLY:-0}" = "1" ]; then
  printf '%s\n' "--- plan (session $SID) ---" "$text1"
  log "PLAN_ONLY: stopping after leg 1, nothing executed"; exit 0
fi

# --- leg 2: execute -----------------------------------------------------------------
prompt_exec="The plan you just wrote is APPROVED. Execute it now, completely, in this same \
session. Rules: work synchronously (no subagents, no background tasks); every changed hook \
or gate gets a scripts/check-gates.sh case and the suite runs from a temp copy (never edit \
a script while it runs); skill prose in caveman style; a line you decided NEEDS USER gets \
' **NEEDS USER (auto-review $today)**' appended and stays; every CLEAR/FIX line is deleted \
and one HTML comment '<!-- $today auto-review (session $sid8): N entries reviewed, F fixed, \
T tagged NEEDS USER. -->' is added below the header. Keep AGENTS.md current for any behaviour \
you change. Commit ONLY your own paths: 'git add <paths>' then 'git commit -m \"<harnessEpicKey>: \
<what>\" -- <paths>' -- never 'git add -A' or a bare 'git commit -a'; other sessions share \
this clone and their uncommitted files must not be swept in. Then 'git push origin master'.

Reply with a line that is exactly DONE, then a line ---DIGEST---, then at most 12 lines: \
counts (reviewed/fixed/cleared/tagged), commit hash(es), and each NEEDS USER line verbatim. \
On failure reply with ONLY 'FAILED: <reason>'."

log "leg 2 (execute) starting"
raw2="$($TO2 claude -p "$prompt_exec" \
  --resume "$SID" --model "$MODEL" --permission-mode acceptEdits --output-format json \
  2>>"$LOG")"; rc2=$?
blocked "$raw2"
text2="$(printf '%s' "$raw2" | jq -r '.result // empty' 2>/dev/null)"
[ -n "$text2" ] || text2="$raw2"
if confirmed "$text2" "DONE"; then
  body="${text2#*---DIGEST---}"; [ "$body" = "$text2" ] && body=""
  body="$(printf '%s' "$body" | sed '/./,$!d' | head -12)"
  [ "$FORCE" = "1" ] || printf '%s\n' "$reset_day" > "$LASTRUN"
  digest "Harness-gaps auto-review $today (session $sid8, plan $PLAN_OUT): DONE. ${body:-no digest body returned}"
  log "leg 2 done"
else
  reason="$(printf '%s' "$text2" | head -c 1200)"
  [ -n "$reason" ] || reason="$(printf 'empty reply, exit code %s (%s)' "$rc2" "$([ "$rc2" = 124 ] && printf 'killed by %s' "${TO2:-no timeout}" || printf 'not a timeout kill')")"
  digest "Harness-gaps auto-review $today (session $sid8): FAILED -- execute leg did not confirm ($reason). Plan saved at $PLAN_OUT; resume with: claude --resume $SID"
  log "leg 2 failed (rc=$rc2): $reason"; exit 1
fi
