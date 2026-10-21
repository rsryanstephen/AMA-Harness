#!/usr/bin/env bash
# Shared: was this session started headless (`claude -p` / SDK) or by a human in a terminal?
#
# Claude Code stamps `"entrypoint":"cli"` (real interactive terminal) or
# `"entrypoint":"sdk-cli"` (headless `-p`/SDK) onto the session's own transcript, so this
# needs no cooperation from the invoking script -- it classifies the four unattended
# scheduled runners (standup-notes, support-notices, embs-notices, team-meeting-notes),
# scripts/findability-eval.sh, and anything else that shells out to `claude -p`, including
# runs that predate this file.
#
# Bounded by LINE, never by bytes. The field is on line 3 in almost every transcript, but
# its BYTE offset swings by two orders of magnitude with the size of line 1 -- measured
# 4403-4730 for unattended runs (line 1 is the long unattended prompt) and 86061 for a real
# interactive session (line 1 an 86 KB context blob). A `head -c 4000` window was tried
# first and silently never matched anything, so the suppression it guarded never once fired
# (<harnessEpicKey>). Deepest observed across every transcript on this machine: line 7
# (ai-title/mode/file-history-snapshot preamble ahead of it), and line 1 or 3 for all 44
# known headless sessions -- 20 is a wide margin on both. The bound also matters for cost:
# a transcript here reached 101 MB, and scanning one whole is what once killed
# notify-sound.sh before it could do anything (PROJ-15356).
#
# NO FORKS. Bash builtins only, no `head`/`grep`/`$( )`. Process spawn on this machine
# measured ~0.55s (20 `cat` calls took 11s), so the obvious `head -n 20 | grep` version cost
# over a second per call -- unaffordable in on-prompt.sh (every prompt), session-name-sync.sh
# (every tool call), and fatal in a bulk pass over hundreds of sessions.
#
# Matched explicitly as `sdk-cli`, never as "anything != cli", so an unknown future
# interactive entrypoint fails toward KEEPING a session's bookkeeping rather than silently
# erasing a real session's chat file. Unescaped JSON key only, so a session merely PRINTING
# the string (this comment, for one) can't false-match.
#
# Sourced, not executed. Callers: on-prompt.sh, on-stop.sh, on-session-end.sh,
# session-name-sync.sh, log-session-start.sh, notify-sound.sh, graylog-write-gate.sh,
# scripts/prune-headless-sessions.sh.

# $1 = transcript_path. Sets SESSION_ENTRYPOINT to the entrypoint value ("cli",
# "sdk-cli") or to "" when it can't be read -- a caller caching a verdict must never cache
# a failed read. Sets a variable rather than echoing precisely to stay fork-free: `$(...)`
# is a subshell, which is the ~0.55s this file exists to avoid.
session_read_entrypoint() {
  SESSION_ENTRYPOINT=""
  [ -n "${1:-}" ] && [ -f "$1" ] || return 0
  local line n=0 rest
  while [ "$n" -lt 20 ] && IFS= read -r line; do
    n=$((n + 1))
    case "$line" in
      *'"entrypoint":"'*)
        rest="${line#*'"entrypoint":"'}"
        SESSION_ENTRYPOINT="${rest%%\"*}"
        return 0
        ;;
    esac
  done < "$1"
  return 0
}

# $1 = transcript_path. 0 = headless. Non-zero = interactive, unknown, or unreadable.
#
# Own-session fast path: env CLAUDE_CODE_ENTRYPOINT, trusted ONLY when
# CLAUDE_CODE_SESSION_ID names this transcript. On the FIRST UserPromptSubmit the user line
# carrying "entrypoint" isn't in the transcript yet, so the transcript read alone missed and
# every headless run got a sessions.txt row (2026-10-08, CLI 2.1.294, repro'd with
# `claude -p`). The id match stops a headless process classifying OTHER sessions
# (log-session-start sweep, prune) from calling them all headless.
session_is_headless() {
  local _b="${1:-}"; _b="${_b##*[/\\]}"; _b="${_b%.jsonl}"
  if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] && [ "$_b" = "$CLAUDE_CODE_SESSION_ID" ] \
     && [ "${CLAUDE_CODE_ENTRYPOINT:-}" = "sdk-cli" ]; then
    return 0
  fi
  session_read_entrypoint "${1:-}"
  [ "$SESSION_ENTRYPOINT" = "sdk-cli" ]
}
