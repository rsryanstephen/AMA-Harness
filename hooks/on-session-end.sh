#!/usr/bin/env bash
# SessionEnd hook: when the CLI session ends (e.g. user types "exit"), append a
# "resume with" line to this session's chat log. Purely mechanical, zero LLM tokens.
# IMPORTANT: the backtick-quoted command is ONLY "claude --resume <id>" -- per
# `claude --help` ("Usage: claude [options] [command] [prompt]"), any trailing
# positional text is treated as an initial prompt and auto-submitted the moment the
# resumed session starts. Extra info (cwd) goes OUTSIDE the backticks as plain text,
# never appended to the runnable command itself.
payload="$(cat)"
sid="$(printf '%s' "$payload" | jq -r '.session_id // empty')"
cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty')"
tr_path="$(printf '%s' "$payload" | jq -r '.transcript_path // empty')"
[ -n "$sid" ] || exit 0
[ -n "$cwd" ] || exit 0
# Headless/`-p`/SDK run -- see on-prompt.sh's matching guard. Nothing to append a resume
# notice to (on-prompt.sh deleted this session's statefile and symlink on its first
# prompt), and attempt_fallback_rename below would otherwise MATERIALIZE a chat file for a
# session the user never started.
source "${BASH_SOURCE[0]%/*}/lib-session-kind.sh"
session_is_headless "$tr_path" && exit 0

# Kill a dev server THIS session started that is still holding its port. A reminder cannot
# cover this case -- nobody reads one at exit -- and it is a real process leak, not a
# cosmetic one: confirmed live 2026-09-14 that TaskStop kills the wrapper bash while the
# `npx ng serve` node CHILD keeps running and keeps the port, outliving the CLI itself.
# Scoped to markers dev-server-teardown-reminder.sh wrote FOR THIS SID, so a concurrent
# session's dev server on the same pinned port is never touched (this machine really does
# run sessions side by side). Fails silent -- housekeeping must never block an exit.
# Predicate lives in lib-devserver-teardown.sh, shared with the verify-tab-close hook.
source "${BASH_SOURCE[0]%/*}/lib-devserver-teardown.sh"
devserver_kill_session_ports "$sid" >/dev/null 2>&1
rm -f -- "$HOME/.claude/harness-state/sessions/.usage-state/devserver-probed-$sid" 2>/dev/null
# Normalize to forward slashes so "$cwd/<name>" never mixes separators.
cwd="$(printf '%s' "$cwd" | tr '\134' '/')"
# .session-chatfiles is internal bookkeeping, never a legitimate session cwd -- if it
# shows up here, a stray `cd` (in an earlier tool call) leaked into Claude Code's own
# reported cwd. Confirmed twice; fall back to the parent dir rather than corrupt paths.
case "$cwd" in */.session-chatfiles) cwd="${cwd%/.session-chatfiles}" ;; esac

source "$(dirname "${BASH_SOURCE[0]}")/lib-chatfile-link.sh"

STATED="$HOME/.claude/.session-chatfiles"; SF="$STATED/$sid"
default="$(chatfile_default_path "$cwd" "$sid")"
if [ -f "$SF" ]; then CHAT="$(cat "$SF")"; else CHAT="$default"; fi

# A session with zero real interaction (opened, exited, never sent a prompt) has no
# chat file yet, or one that's still empty -- don't create one just to hold a resume
# notice nobody will ever use. Confirmed real bug: when this ran anyway, the mechanical
# fallback rename below (nothing to name it from except the notice itself) slugified
# the notice's OWN text into a garbage filename ("resume-session-with-cd-claude-...").
[ -s "$CHAT" ] || exit 0

# Prefer OUR bookkeeping's directory over the payload's own cwd, when we have it --
# confirmed via a real incident: SessionEnd fired a second time reporting a STALE cwd
# (the pre-relocation directory) even though this session had already been correctly
# relocated, producing a second, wrong "resume with" notice pointing at the old location
# after the correct one. relocate-session.sh keeps our state file accurate the moment a
# real /cd happens; a payload field can lag behind that, so trust the state file instead.
resume_dir="$cwd"
[ -f "$SF" ] && resume_dir="$(chatfile_session_cwd "$CHAT")"

# Resuming a session needs to happen from its original cwd, so fold a "cd" into the
# copy-pasteable command. Convert cwd to a bash-friendly path: "C:/..." -> "/c/...",
# and shorten the home directory to "~".
slash_cwd="$resume_dir"
if [[ "$slash_cwd" =~ ^([A-Za-z]):(/.*)$ ]]; then
  drive="$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')"
  unix_cwd="/$drive${BASH_REMATCH[2]}"
else
  unix_cwd="$slash_cwd"
fi
if [[ "$unix_cwd" == "$HOME"* ]]; then
  display_cwd="~${unix_cwd#$HOME}"
else
  display_cwd="$unix_cwd"
fi

line="Resume session with \`cd $display_cwd && claude --resume $sid\`"

# Skip if the file's last block is already this exact notice -- SessionEnd can fire
# more than once for the same exit (confirmed via the incident above); don't stack
# duplicate/stale notices.
already_last="$(awk 'BEGIN{RS="\n---\n"} {b=$0} END{gsub(/^[\n]+|[\n]+$/,"",b); print b}' "$CHAT" 2>/dev/null)"
if [ "$already_last" != "$line" ]; then
  if [ -s "$CHAT" ]; then printf '\n---\n\n%s\n' "$line" >> "$CHAT"; else printf '%s\n' "$line" >> "$CHAT"; fi
fi

# Mechanical fallback rename: CLAUDE.md tells the model to rename an unnamed session
# unprompted, mid-session, once the topic's clear -- but that needs a turn to fire in,
# and a session whose last real action was its final task (then straight to exit) never
# gets one. Confirmed via two real incidents: exited still fallback-named, nothing to
# catch it. A per-turn reminder helps if the user comes back and sends anything first,
# but can't cover this exact shape. This always runs at actual exit, no model needed.
# Shared with log-session-start.sh's retroactive sweep (same logic, different trigger --
# this covers a clean exit, that one covers an abrupt exit that skipped SessionEnd
# entirely).
source "$(dirname "${BASH_SOURCE[0]}")/lib-fallback-rename.sh"
attempt_fallback_rename "$sid" "$CHAT" "$resume_dir"

# Unconditional render at exit -- covers the case where this session's very last turn was
# the one that first captured its explicitname/aititle (on-stop.sh's own change-gated
# render already fired for that, but a session that never gets ANOTHER turn after that
# needs this as a backstop; cheap, one render per exit, sessions.md is gitignored so it's
# not auto-commit churn either way).
bash "$(dirname "${BASH_SOURCE[0]}")/render-sessions-md.sh" 2>/dev/null || true

# Throttled to once a day (same shape as headless-prune-check.sh). Measured 2026-09-01:
# this loop alone is 1.0s over 894 .session-chatfiles entries ON A QUIET BOX -- a `find`
# plus a per-file `ls` subshell -- and render_sessions_md above is another 1.0s, against a
# SessionEnd budget that was still 5s from when this hook only appended one line. Under the
# fork contention profiled on this machine (on-prompt.sh 11s solo, 59-72s with two other
# sessions) that overran, and the user saw `SessionEnd hook ... failed: Hook cancelled` on
# every exit. Timeout raised 5 -> 30 in the same pass; this throttle is the other half,
# since nothing about a 30-day-old file needs deciding at every single exit.
# hstate is NOT otherwise in scope here (this hook sources only lib-chatfile-link.sh and
# lib-session-kind.sh) -- without this source the marker path came back empty, _prune_due
# stayed 1, and the throttle would have been silently dead while looking correct.
source "$(dirname "${BASH_SOURCE[0]}")/lib-claude-paths.sh"
_prune_marker="$(hstate sessions .chatfiles-prune-lastrun 2>/dev/null || printf '')"
_prune_due=1
if [ -n "$_prune_marker" ] && [ -f "$_prune_marker" ]; then
  _prune_age=$(( $(date +%s) - $(stat -c %Y "$_prune_marker" 2>/dev/null || echo 0) ))
  [ "$_prune_age" -lt 86400 ] && [ "$_prune_age" -ge 0 ] && _prune_due=0
fi
[ "$_prune_due" = 1 ] || exit 0
[ -n "$_prune_marker" ] && touch "$_prune_marker" 2>/dev/null

# hook-run.sh's per-PID stdio files: its header used to claim PID recycling bounds them; on
# Windows it does not (196,590 files / 40MB by 2026-09-15). Same daily throttle as above,
# anything a day old is long dead. Fails silent. <harnessEpicKey>.
find "$HOME/.claude/scratch/hook-run" -maxdepth 1 -type f -mmin +1440 -delete 2>/dev/null

# dispatch.sh's gate-invocations.log (one line per gate run, names + rcs, never payloads):
# rotate at ~5MB, keep one generation. Same daily throttle.
_gil="$HOME/.claude/harness-state/logs/gate-invocations.log"
if [ -f "$_gil" ] && [ "$(stat -c %s "$_gil" 2>/dev/null || echo 0)" -gt 5000000 ]; then
  mv -f "$_gil" "$_gil.1" 2>/dev/null
fi

# Prune per-session bookkeeping nothing else deletes (~380 files by 2026-08-18): a
# .session-chatfiles/<sid>[.suffix] entry older than 30 days whose session has no transcript
# any more. Own session's files are never touched (still needed by the resume notice above).
# Fails silent -- housekeeping must never block an exit.
# Live transcripts are listed ONCE into a lookup table: the old per-file `ls` glob + `basename`
# forked twice per entry -- 142 entries measured 15.7s on a quiet box 2026-10-13, past the 30s
# timeout under contention, and the user saw `SessionEnd hook ... failed: Hook cancelled` again.
declare -A _live_sid
while IFS= read -r t; do t="${t##*/}"; _live_sid["${t%.jsonl}"]=1; done \
  < <(find "$HOME/.claude/projects" -mindepth 2 -maxdepth 2 -name '*.jsonl' 2>/dev/null)
find "$STATED" -maxdepth 1 -type f -mtime +30 ! -name "$sid*" ! -name 'check-gates-probe-*' 2>/dev/null \
  | while IFS= read -r f; do
      osid="${f##*/}"; osid="${osid%%.*}"
      [ "${#osid}" -eq 36 ] || continue
      [ -n "${_live_sid[$osid]:-}" ] && continue
      rm -f -- "$f" 2>/dev/null
    done
exit 0
