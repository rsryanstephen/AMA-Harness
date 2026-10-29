#!/usr/bin/env bash
# Two wirings, one file:
#   PreToolUse  (Bash|PowerShell)            -- deny cancelling an Octopus task this session did not start
#   PostToolUse (Bash|PowerShell) --record   -- remember which ServerTasks ids this session's deploy POSTs created
#
# Why: 2026-10-13, session 7c2235b9 saw an unattended ExporterPlus Staging apply whose plan
# removed a CloudFront origin request policy, took it for drift, and cancelled it. It was
# session 042a8f63's deliberate PROJ-15654 test deploy (feature-branch release 2.0.0.83);
# that session only saw "cancelled by Automation Service Account" -- every session deploys
# under the same Octopus API key, so Octopus cannot say WHO cancelled. A task this session did
# not create belongs to someone else (another session, a pipeline push, a human) until proven
# otherwise.
#
# Ownership = this session's own ledger rows (tasks its deploy POSTs returned). Everything
# else is foreign: denied, naming any LIVE session whose transcript mentions the task id.
# Pipeline-started deploys are in nobody's ledger -- correctly foreign: they belong to whoever
# pushed the branch (pipeline-build.sh <repo> <build> names it).
#
# Limits: the cancel must name its ServerTasks ids literally (command or args) -- a cancel with
# no literal id is denied outright, since nothing can be checked. A scratch script that
# cancels by ids it computes itself, invoked with neither "cancel" nor an id on the command
# line, is not seen (needle).
#
# Hatch: AMA_CANCEL_FOREIGN_TASK=1 in the command -- only after the owner session was asked
# (ListAgents/SendMessage) or the user said yes. Fails open on unparseable payloads.
set -u
. "$HOME/.claude/hooks/lib-claude-paths.sh"

MODE="${1:-gate}"
IFS= read -r -d '' payload || true

ledger() { hstate sessions octopus-task-owners; }
US=$'\x1f'   # non-whitespace field separator: IFS=tab would collapse an empty session_id

# --- PostToolUse: record task ids a deploy POST of this session created -------------
if [ "$MODE" = "--record" ]; then
  case "$payload" in *ServerTasks-*) ;; *) exit 0 ;; esac
  IFS="$US" read -r sid command < <(printf '%s' "$payload" | jq -r '[(.session_id // ""), (.tool_input.command // "" | gsub("[\n\r]"; " "))] | join("\u001f")' | tr -d '\r')
  [ -n "${sid:-}" ] && [ -n "${command:-}" ] || exit 0
  region="$command"
  . "$HOME/.claude/hooks/lib-scan-script-refs.sh" 2>/dev/null && region="$region
$(scan_referenced_scripts "$command")"
  flat="$(printf '%s' "$region" | tr '\n' ' ')"
  # A deployment-creating POST: verb + a deployments endpoint ("$O/deployments" with O=.../api/Spaces-1
  # never spells api/Spaces-N/deployments, so match the endpoint token loosely).
  printf '%s' "$flat" | grep -qP '(-X\s*POST|--request\s*POST|-Method\s+Post)' || exit 0
  printf '%s' "$flat" | grep -qE '/deployments([^/[:alnum:]]|$)' || exit 0
  out="$(printf '%s' "$payload" | jq -r '.tool_response.stdout // .tool_response // "" | tostring' | tr -d '\r')"
  now="$(date +%s)"; f="$(ledger)"
  printf '%s' "$out" | grep -oE 'ServerTasks-[0-9]+' | sort -u | while read -r t; do
    printf '%s\t%s\t%s\n' "$t" "$sid" "$now" >> "$f"
  done
  exit 0
fi

# --- PreToolUse: gate a task cancel ---------------------------------------------------
case "$payload" in *cancel*|*ServerTasks-*) ;; *) exit 0 ;; esac
IFS="$US" read -r sid command < <(printf '%s' "$payload" | jq -r '[(.session_id // ""), (.tool_input.command // "" | gsub("[\n\r]"; " "))] | join("\u001f")' | tr -d '\r')
[ -n "${command:-}" ] || exit 0

. "$HOME/.claude/hooks/lib-command-text.sh" 2>/dev/null || command_scan_region() { printf '%s' "$1"; }
region="$(command_scan_region "$command")"
. "$HOME/.claude/hooks/lib-scan-script-refs.sh" 2>/dev/null && region="$region
$(scan_referenced_scripts "$command")"
flat="$(printf '%s' "$region" | tr '\n' ' ')"
# Octopus cancel = POST /api/tasks/<id>/cancel (curl or Invoke-RestMethod), or the octopus CLI.
printf '%s' "$flat" | grep -qE 'tasks/[^[:space:]"'"'"']*/cancel|octopus[[:space:]]+task[[:space:]]+cancel' || exit 0

case "$command" in *AMA_CANCEL_FOREIGN_TASK=1*) exit 0 ;; esac

deny() {
  jq -cn --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

ids="$(printf '%s' "$command" | grep -oE 'ServerTasks-[0-9]+' | sort -u)"
[ -n "$ids" ] || deny "Octopus task cancel blocked: no literal ServerTasks-N id in the command, so this gate cannot check who owns the task. Name the task ids explicitly (e.g. \`bash oct-cancel.sh ServerTasks-123\`) and re-run."

f="$(ledger)"
dir="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
foreign=""
for t in $ids; do
  owner="$(awk -F'\t' -v t="$t" '$1==t {o=$2} END {print o}' "$f" 2>/dev/null)"
  [ -n "$owner" ] && [ "$owner" = "${sid:-}" ] && continue
  # Live sessions (transcript written <10 min) other than this one that mention the task.
  # Tail-bounded: transcripts only grow (AGENTS.md, notify-sound incident).
  who=""
  while IFS= read -r tr; do
    [ -n "$tr" ] || continue
    s="$(basename "$tr" .jsonl)"
    [ "$s" = "${sid:-}" ] && continue
    tail -n 3000 "$tr" 2>/dev/null | grep -q "$t\b" && who="$who ${s:0:8}"
  done < <(find "$dir" -name '*.jsonl' -not -path '*/subagents/*' -newermt '-600 seconds' 2>/dev/null)
  line="$t"
  [ -n "$owner" ] && line="$line (started by session ${owner:0:8})"
  [ -n "$who" ] && line="$line (mentioned by live session(s):$who)"
  foreign="$foreign
  - $line"
done
[ -n "$foreign" ] || exit 0

deny "Octopus task cancel blocked: this session did not start these task(s):$foreign

All sessions deploy under one Octopus API key, so a cancel shows the owner only \"cancelled by Automation Service Account\" -- they cannot tell who did it. 2026-10-13: a session cancelled another session's deliberate PROJ-15654 Staging test deploy, mistaking its planned change for drift.

Before cancelling someone else's deploy:
1. Find the owner: ListAgents, then SendMessage the session named above (or one working that project/ticket). A pipeline-started deploy belongs to whoever pushed: read the release's package version and run ~/.claude/skills/ama-bitbucket-api/scripts/pipeline-build.sh <repo> <build> for its branch.
2. An unexpected plan change is usually someone's in-flight work, not drift -- check the branch/commit before calling it drift.
3. Tell the user what the deploy is and who owns it; cancel only on the user's explicit yes (or the owner's), then re-run with AMA_CANCEL_FOREIGN_TASK=1."
