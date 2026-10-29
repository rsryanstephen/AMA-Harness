#!/usr/bin/env bash
# Clears the "check-gates pass owed" reminder, running the SMALLEST run that actually proves
# what the reminder is about (<harnessEpicKey> follow-up: the 2026-09-01 vpn-dns-logger fix
# shipped hand-verified because the machine was fork-exhausted -- 0xC0000142/EAGAIN under 9
# concurrent sessions -- and the suite couldn't run).
#
# Three things this fixes, all from session edcd4fbd on 2026-09-14:
#
#   1. SCOPE. check-gates-currency-gate.sh now records WHICH gate sections an edit needs
#      re-run, as `G:<gate>` / `N:` lines in the marker. A full pass is ~10 min over 73
#      gates; one gate filtered is ~30-60s, and the ~24 suite-level assertions run under
#      EVERY filter. So an edit to a non-gate file needs no full pass at all. The case that
#      prompted this: two commits to scripts/mutate-gates.sh armed the reminder, and the
#      full pass that followed could not cover anything a filtered run already had.
#      Fallback is always the FULL pass, never a partial one -- unknown state costs time,
#      never coverage.
#   2. LOAD. The old header said "run it when the machine is quiet" and measured nothing, so
#      this got launched while the user was mid-`/exit` with several sessions live. Refuses
#      now, rather than producing a spurious red that proves nothing.
#   3. VISIBILITY. The run used to be captured into a shell variable, so it produced a
#      0-byte log and ~14 minutes of silence in which a hang and progress looked identical.
#      It streams to a file now, and check-gates.sh already prints `gate N: <name>` per gate.
set -u
repo="$(git -C "$HOME/.claude/hooks" rev-parse --show-toplevel 2>/dev/null)"
[ -n "$repo" ] || { echo "cannot resolve harness repo root" >&2; exit 1; }
. "$HOME/.claude/hooks/lib-claude-paths.sh"
. "$HOME/.claude/hooks/lib-session-liveness.sh"
MARKER="$(hstate notices .check-gates-full-run-owed)"

# --- 1. load check ---------------------------------------------------------------------
# Counts this session too, so the default of 3 allows two others. The documented incident
# was 9 concurrent sessions, so this is conservative on purpose.
LIVE="$(live_session_count 600)"
MAXLIVE="${CHECK_GATES_MAX_LIVE:-3}"
if [ "$LIVE" -gt "$MAXLIVE" ] && [ "${CHECK_GATES_FORCE:-0}" != "1" ]; then
  echo "REFUSED: $LIVE Claude sessions wrote a transcript in the last 10 min (limit $MAXLIVE)." >&2
  echo "The suite is fork-heavy; under contention its cases fail spuriously and prove nothing," >&2
  echo "and a full pass has been killed by a low-memory supervisor. The reminder stays armed." >&2
  echo "Run it when the machine is quiet, or CHECK_GATES_FORCE=1 to override." >&2
  exit 2
fi

# --- 2. scope from the reminder ledger --------------------------------------------------
# `G:<gate>` = that section is owed. `N:` = an edit only the always-on suite-level
# assertions cover. Anything else in the file (a legacy free-text marker, a comment) is
# ignored, and a marker with no usable lines falls back to the full pass.
GATES=""; HAS_N=0
if [ -r "$MARKER" ]; then
  GATES="$(grep '^G:' "$MARKER" 2>/dev/null | cut -c3- | sort -u)"
  grep -q '^N:' "$MARKER" 2>/dev/null && HAS_N=1
fi
NGATES="$(printf '%s' "$GATES" | grep -c . || true)"

# The cap is a sanity valve, NOT a cost break-even. Every named section runs in ONE suite
# invocation (check-gates.sh takes a colon-separated set), so N sections cost the ~30-60s
# suite-level floor plus N gates -- always cheaper than all 73, for any N. An earlier cap of
# 8 came from assuming N separate runs and made the whole feature moot in practice: one edit
# to AGENTS.md maps to 10+ sections, because every gate that asserts about AGENTS.md content
# legitimately mentions it, so the common case fell straight back to the full pass.
MAXGATES="${CHECK_GATES_MAX_SECTIONS:-40}"
if [ -n "$GATES" ] && [ "$NGATES" -le "$MAXGATES" ]; then
  ONLY="$(printf '%s' "$GATES" | tr '\n' ':' | sed 's/:$//')"
  SCOPE="scoped: $NGATES gate section(s) the reminder names"
elif [ "$HAS_N" = 1 ] && [ -z "$GATES" ]; then
  # Only non-gate edits. The suite-level assertions are the whole relevant coverage, but a
  # filter matching NO gate exits non-zero by design (GATES-AND-HOOKS.md), so pin the
  # suite's first section to carry them. Costs one gate's cases, proves the rest.
  ONLY="$(grep -m1 -oE '^G=[a-z0-9-]+\.sh' "$repo/scripts/check-gates.sh" | sed 's/^G=//')"
  SCOPE="suite-level only (no edited file maps to a gate section)"
else
  ONLY=""
  SCOPE="FULL pass (marker empty, unreadable, legacy, or names more than 8 sections)"
fi

LOG="$(hscratch check-gates "run-$(date '+%Y%m%d-%H%M%S').log")"
echo "check-gates: $SCOPE"
echo "check-gates: streaming to $LOG"

if [ -n "$ONLY" ]; then
  CHECK_GATES_ONLY="$ONLY" bash "$repo/scripts/check-gates.sh" > "$LOG" 2>&1; rc=$?
else
  CHECK_GATES_FULL=1 bash "$repo/scripts/check-gates.sh" > "$LOG" 2>&1; rc=$?
fi
tail -5 "$LOG"

if [ "$rc" -eq 0 ]; then
  rm -f "$MARKER"
  # Task deletion needs doubled slashes under MSYS (PORTABILITY.md's schtasks gotcha).
  schtasks //Delete //TN "AMA-Harness-CheckGates-Reminder" //F >/dev/null 2>&1
  echo "GREEN -- reminder marker + scheduled task cleared."
else
  echo "NOT GREEN (rc=$rc) -- reminder stays armed, nothing was cleared. Full log: $LOG" >&2
  echo "If failures look like fork exhaustion (0xC0000142 / Resource temporarily" >&2
  echo "unavailable), quiet the machine and re-run." >&2
fi
exit "$rc"
