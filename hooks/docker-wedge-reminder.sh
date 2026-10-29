#!/usr/bin/env bash
# PostToolUseFailure hook (Bash/PowerShell). A `docker` command just hung (killed by
# `timeout` -> exit 124, or by the tool's own timeout) -> tell Claude to run
# docker-wedge-diagnose.sh before suggesting any fix. The script, not this hook, decides
# whether the Resource-Saver-then-sleep cause applies (user instruction 2026-09-23: check
# first, never suggest the setting blindly). Hook stays cheap: no probe here.
#
# PostToolUseFailure, not PostToolUse: PostToolUse does not fire on a non-zero exit
# (confirmed 2026-09-23 from gate-invocations.log -- zero dispatch lines for a failed call).
#
# Once per session (a wedge fails every docker call; one nudge is enough). Fails open.
set -u

IFS= read -r -d '' payload || true

case "$payload" in
  *docker*) ;;
  *) exit 0 ;;
esac
case "$payload" in
  *"Exit code 124"*|*"timed out"*|*"Timed out"*|*"interrupted"*) ;;
  *) exit 0 ;;
esac

IFS=$'\t' read -r sid command < <(printf '%s' "$payload" | jq -r '[.session_id // "", (.tool_input.command // "" | gsub("[\t\n]"; " "))] | @tsv')
sid="${sid%$'\r'}"; command="${command%$'\r'}"
[ -n "$command" ] || exit 0

# A real docker invocation, not a grep/cat of a log that mentions docker.
[[ "$command" =~ (^|[;\&\|\(\)\{\}])[[:space:]]*(timeout[[:space:]]+[^[:space:]]+[[:space:]]+)?docker[[:space:]] ]] || exit 0

stamp="${CLAUDE_STATE_DIR:-$HOME/.claude/harness-state}/sessions/docker-wedge-nudged-${sid:-nosid}"
[ -e "$stamp" ] && exit 0
mkdir -p "${stamp%/*}" 2>/dev/null && : > "$stamp"

jq -cn '{hookSpecificOutput: {hookEventName: "PostToolUseFailure", additionalContext:
  "A docker command just hung -- likely the wedged Docker Desktop engine (tray says running, every call blocks). BEFORE suggesting any fix run: bash \"$HOME/.claude/skills/ama-postgres-access/scripts/docker-wedge-diagnose.sh\". VERDICT: RESOURCE_SAVER_SLEEP -> recommend the user restart Docker Desktop (docker desktop restart --timeout 240) AND turn Resource Saver off (Settings -> Resources -> Advanced, README prerequisite). WEDGED_OTHER -> recommend the restart only; do NOT suggest the Resource Saver setting. HEALTHY -> not a wedge, look elsewhere. Restart kills every container machine-wide incl. other sessions -- recommend, let the user time it. Redshift work needs no Docker: rs-query.sh. Detail: ama-postgres-access SKILL.md."}}'
