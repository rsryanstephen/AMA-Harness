#!/usr/bin/env bash
# Runs one hook script with Claude Code's stdio pipes ISOLATED from it.
# Usage (settings.json): bash "$HOME/.claude/hooks/hook-run.sh" "$HOME/.claude/hooks/<gate>.sh" [args]
#
# Why (<harnessEpicKey>, 2026-08-28): tool calls hung for 50+ min inside the PreToolUse
# chain. Cause: 13 orphaned `jq.exe` (hook children) alive for days, each 1 thread
# `WaitReason: Suspended`, CPU 0 -- cygwin fork children never resumed because the hook
# bash.exe died first (Claude Code's per-hook timeout kills only that one process). The
# orphan still holds the hook's inherited stdout/stderr pipe -> Claude Code waits for
# EOF forever -> "Percolating..." until the user kills the session. Got worse with more
# concurrent sessions x ~30 hook processes per Bash call.
#
# Fix: the script (and so every child it forks) gets FILES for stdin/stdout/stderr, never
# Claude Code's pipes. Only this wrapper holds them, so when it exits or is killed the
# pipes close. Wrapper adds exactly ONE fork (the inner bash); everything else is builtin
# (read/printf/$(<file)/mapfile) -- no mktemp/cat/rm. Exit code and stderr pass through
# (exit 2 + stderr = block, unchanged).
# Files: ~/.claude/scratch/hook-run/<pid>.{in,out,err}, truncated after use. NOT bounded by
# PID recycling (Windows PIDs run to 6 digits: 196,590 files by 2026-09-15) -- pruned once a
# day by on-session-end.sh, files older than 24h.
set -u

script="${1:-}"; shift || true
[ -n "$script" ] || exit 0

d="$HOME/.claude/scratch/hook-run"
[ -d "$d" ] || mkdir -p "$d" 2>/dev/null || { exec bash "$script" "$@"; }

payload=""; IFS= read -r -d '' payload || true
in="$d/$$.in"; out="$d/$$.out"; err="$d/$$.err"
printf '%s' "$payload" > "$in"
: > "$out"; : > "$err"

bash "$script" "$@" < "$in" > "$out" 2> "$err"
rc=$?

o="$(<"$out")"; e="$(<"$err")"
[ -n "$o" ] && printf '%s' "$o"
[ -n "$e" ] && printf '%s' "$e" >&2
: > "$in"; : > "$out"; : > "$err"
exit "$rc"
