#!/usr/bin/env bash
# Shared: is another Claude session still alive?
#
# Sessions here share one local clone per repo, so several guards need to distinguish
# "another session is actively working in this repo" from "a session touched it days ago
# and is long gone". Getting that wrong in the pessimistic direction is what makes a
# coordination guard hostile: a claim left behind by a dead session would nag forever.
#
# The test is lifted from log-session-start.sh:76-81, which is the only liveness check
# that existed, and whose reasoning still holds: "a genuinely live concurrent session
# keeps writing to its own transcript continuously". A session's own transcript
# (~/.claude/projects/**/<sid>.jsonl) is written by Claude Code itself, so it needs no
# cooperation from the session -- nothing has to remember to release a lock or update a
# heartbeat. That matters here because this harness has NO reliable session-end cleanup:
# .session-chatfiles/ has ~380 files nothing ever deletes.
#
# Subagent transcripts are excluded (-not -path "*/subagents/*") -- same as the original;
# a subagent's file is not the session's own liveness signal.
#
# Default 600s matches the original. Callers wanting a different window pass one, but
# think first: too short and a session pausing to think looks dead.
#
# Sourced, not executed. Fails toward "not live" on anything unresolvable, so a guard
# built on this degrades to silence rather than to a false accusation.

# CLAUDE_PROJECTS_DIR exists so check-gates.sh can point liveness at a throwaway tree and
# seed a "live" vs "10-minute-stale" session deterministically. Without it the only way to
# test a liveness-dependent gate is to write into the real ~/.claude/projects, and a test
# that mutates real session state is one nobody dares run.
session_transcript_mtime() {
  local sid="${1:-}" tr dir
  [ -n "$sid" ] || { echo 0; return; }
  dir="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
  tr="$(find "$dir" -name "$sid.jsonl" -not -path "*/subagents/*" 2>/dev/null | head -1)"
  [ -n "$tr" ] || { echo 0; return; }
  stat -c %Y "$tr" 2>/dev/null || echo 0
}

# session_age_secs <sid> -> seconds since its transcript was last written.
# Prints a very large number when unknown, so `age > window` reads as "not live".
session_age_secs() {
  local mt; mt="$(session_transcript_mtime "${1:-}")"
  case "$mt" in ''|0|*[!0-9]*) echo 999999999; return ;; esac
  echo $(( $(date +%s) - mt ))
}

# session_is_live <sid> [max_age_secs=600] -> exit 0 if live
session_is_live() {
  local sid="${1:-}" max="${2:-600}" age
  [ -n "$sid" ] || return 1
  age="$(session_age_secs "$sid")"
  [ "$age" -le "$max" ]
}

# live_session_count [max_age_secs=600] -> how many sessions wrote a transcript inside the
# window. Counts the CALLER's own session too, so a caller asking "how busy is this machine"
# should compare against a threshold that allows for itself.
#
# Added for scripts/run-check-gates-full.sh: the gate suite is fork-heavy, its cases fail
# spuriously under contention, and a full pass has been killed by a low-memory supervisor --
# yet nothing measured load, so the only protection was a comment telling a human to run it
# when quiet. Deliberately ONE `find` and no per-file stat loop: there are hundreds of
# transcripts, and a load check that is itself expensive defeats its own purpose.
live_session_count() {
  local max="${1:-600}" dir n
  dir="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
  n="$(find "$dir" -name '*.jsonl' -not -path '*/subagents/*' \
         -newermt "-${max} seconds" 2>/dev/null | wc -l | tr -d ' ')"
  case "$n" in ''|*[!0-9]*) echo 0 ;; *) echo "$n" ;; esac
}
