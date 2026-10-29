#!/usr/bin/env bash
# Follow an Octopus deployment task to its end and report the outcome (user rule 2026-10-14:
# "I should not have to post here if deployments do not succeed"). Run as a Bash
# run_in_background task: silent while waiting, one notification when the task finishes.
#   SUCCESS  -> one line.
#   FAILED   -> the task's error lines (ANSI stripped, deduped), a known-cause classification,
#               and the instruction to DEBUG NOW without waiting for the user.
#   CANCELED / TIMEOUT -> one line each.
# Two hooks start it: octopus-deploy-watch-reminder.sh (after a deploy POST this session made)
# and octopus-approval-watch-check.sh (Stop: the reply asked the user to approve/deploy).
#
# usage:
#   octopus-task-watch.sh <ServerTasks-N> [sid]
#   octopus-task-watch.sh --next <Projects-N|project-slug> <Environments-N> [sid]
#       wait for the NEXT deployment of that project to that environment (created after now),
#       then follow it -- for "please deploy release X" replies where no task exists yet.
# One session per task: the first to claim (mkdir) follows it; a later caller exits quietly
# unless the claimant session is dead (lib-session-liveness.sh). Max wait 8h (approval gates
# can sit for hours); it then reports TIMEOUT so the session can re-arm.
set -u
. "$HOME/.claude/hooks/lib-claude-paths.sh"
. "$HOME/.claude/hooks/lib-session-liveness.sh" 2>/dev/null || session_is_live() { return 1; }
CONFIG="$HOME/.claude/harness-config.json"
SERVER="$(jq -r '.octopus.serverUrl // "https://yourorg.octopus.app"' "$CONFIG" 2>/dev/null | tr -d '\r')"
SPACE="$(jq -r '.octopus.spaceId // "Spaces-1"' "$CONFIG" 2>/dev/null | tr -d '\r')"
PROD_ENV="$(jq -r '.octopus.environmentIds.production // "<production>"' "$CONFIG" 2>/dev/null | tr -d '\r')"
O="$SERVER/api/$SPACE"; H="X-Octopus-ApiKey: ${OCTOPUS_API_KEY:-}"
[ -n "${OCTOPUS_API_KEY:-}" ] || { echo "OCTOPUS_API_KEY not set"; exit 2; }
POLL="${OCTO_WATCH_POLL:-20}"; MAX="${OCTO_WATCH_MAX:-28800}"
WATCHED="$(dirname "$(hstate octopus watched/.keep)")"; mkdir -p "$WATCHED"

api() { curl -sS --max-time 30 -H "$H" "$O/$1" 2>/dev/null | tr -d '\r'; }

task=""; sid=""
case "${1:-}" in
  --next)
    proj="${2:?project}"; env="${3:?environment}"; sid="${4:-}"
    pid="$(api "projects/$proj" | jq -r '.Id // empty')"; [ -n "$pid" ] || { echo "project $proj not found"; exit 2; }
    since="$(date -u +%Y-%m-%dT%H:%M:%S)"; t0=$(date +%s)
    while :; do
      task="$(api "deployments?projects=$pid&environments=$env&take=1" | jq -r --arg s "$since" '.Items[0] | select(.Created >= $s) | .TaskId // empty')"
      [ -n "$task" ] && break
      [ $(( $(date +%s) - t0 )) -lt "$MAX" ] || { echo "TIMEOUT: no new deployment of $proj to $env in $((MAX/3600))h -- re-arm the watcher if still expected."; exit 0; }
      sleep "$POLL"
    done ;;
  ServerTasks-*) task="$1"; sid="${2:-}" ;;
  *) sed -n 2,20p "$0"; exit 2 ;;
esac

# Claim.
if ! mkdir "$WATCHED/$task" 2>/dev/null; then
  owner="$(cat "$WATCHED/$task/sid" 2>/dev/null)"
  if [ -n "$owner" ] && [ "$owner" != "$sid" ] && session_is_live "$owner" 3600; then
    echo "$task is already watched by live session ${owner:0:8} -- nothing to do here."; exit 0
  fi
fi
printf '%s' "$sid" > "$WATCHED/$task/sid"
url="$SERVER/app#/$SPACE/tasks/$task"
# Durable (user rule 2026-10-22, scripts/durable-monitor.sh): register this run so a reboot
# restarts it (resolved <task> form, never --next: after a restart that would wait for a
# deployment newer than the one being watched). Unregistered on every exit. A restarted copy
# has no session reading its stdout, so its report goes out as a durable reminder instead.
DM="$HOME/.claude/scripts/durable-monitor.sh"
bash "$DM" add "octopus-$task" --pid $$ --until "$(date -d '+2 days' +%F)" "$0" "$task" $sid >/dev/null 2>&1
_out=""
if [ -n "${DURABLE_MONITOR_RESTART:-}" ]; then _out="$(mktemp)"; exec >"$_out" 2>&1; fi
trap 'bash "$DM" remove "octopus-$task" >/dev/null 2>&1; if [ -n "$_out" ] && [ -s "$_out" ]; then bash "$HOME/.claude/scripts/reminder.sh" add "${sid:-unknown}" now "Deploy watcher for $task (restarted after a reboot) finished: $(cat "$_out")" >/dev/null 2>&1; rm -f "$_out"; fi' EXIT

t0=$(date +%s); announced=0
while :; do
  info="$(api "tasks/$task")"
  state="$(printf '%s' "$info" | jq -r '.State // empty')"
  [ -n "$state" ] || { sleep "$POLL"; continue; }
  done_="$(printf '%s' "$info" | jq -r '.IsCompleted')"
  if [ "$announced" = 0 ] && [ "$(printf '%s' "$info" | jq -r '.HasPendingInterruptions')" = true ]; then
    echo "[$(date +%H:%M)] $task awaiting manual approval: $url" >&2; announced=1
  fi
  [ "$done_" = true ] && break
  [ $(( $(date +%s) - t0 )) -lt "$MAX" ] || { echo "TIMEOUT: $task still $state after $((MAX/3600))h ($url). Re-arm: bash ~/.claude/scripts/octopus-task-watch.sh $task $sid"; exit 0; }
  sleep "$POLL"
done

desc="$(printf '%s' "$info" | jq -r '.Description // ""')"
case "$state" in
  Success) echo "DEPLOY SUCCESS: $desc ($task). Verify the environment as the task's runbook says (ECS rollout / Lambda version / Terraform result), then carry on."; exit 0 ;;
  Canceled|Cancelled) echo "DEPLOY CANCELED: $desc ($task, $url). Someone cancelled it -- tell the user, do not retry on your own."; exit 0 ;;
  TimedOut) echo "DEPLOY TIMED OUT in Octopus: $desc ($task, $url)." ;;
esac

# Failure: pull the error lines and classify.
raw="$(curl -sS --max-time 60 -H "$H" "$O/tasks/$task/raw" 2>/dev/null | tr -d '\r' | sed 's/\x1b\[[0-9;]*m//g')"
# Raw log lines are `HH:MM:SS   Category  |   text`. Keep Error/Fatal text minus pure boilerplate
# ("The step failed: ..." stays -- it carries the reason, e.g. 'The task was canceled').
errs="$(printf '%s\n' "$raw" | grep -E '^[0-9:]+ +(Error|Fatal) +\|' | sed -E 's/^[0-9:]+ +(Error|Fatal) +\| *//' | grep -vE '^\s*$|^The remote script failed|^The action .* failed$|^The following command|^With the working directory|^Failed with exit code|^The deployment failed because' | awk '!seen[$0]++' | head -25 | cut -c1-300)"
events="$(api "events?regarding=$task&take=20" | jq -r '.Items[] | select(.Category|test("Cancel|Abandon|Queued|Modified")) | "\(.Occurred[0:16]) \(.Category) by \(.Username)"' | head -5)"
cause="unclassified -- read the full log: curl -H \"X-Octopus-ApiKey: \$OCTOPUS_API_KEY\" $O/tasks/$task/raw"
case "$errs" in
  *"The task was canceled"*|*"task was cancelled"*) cause="a STEP WAS CANCELED mid-run (a person or a session cancelled it -- see events below; octopus-task-cancel-gate.sh logs session cancels). Check what the step had applied before the cancel; nothing is retried automatically." ;;
  *"timeout while waiting for plugin to start"*|*"Could not load plugin"*) cause="TRANSIENT worker contention (shared Hosted Ubuntu worker, aws provider slow to start; PROJ-15791). Nothing applied. Fix = retry the same release when the worker pool is quiet (check /tasks?states=Executing)." ;;
  *"state snapshot was created by Terraform v"*) cause="STATE VERSION: a local Terraform 1.x wrote this state; the 0.13.3 worker cannot read it. Nothing applied. See ama-terraform-backbone SKILL.md (apply locally with the version that wrote it, or wait for worker image 03)." ;;
  *DeleteConflict*) cause="IAM DeleteConflict: the entity still has policies/keys attached outside Terraform. Partial apply likely. Detach them (aws iam list-attached-*-policies), re-plan, rerun." ;;
  *"Error acquiring the state lock"*) cause="STATE LOCK held by another plan/apply (another session or task). Wait for it; force-unlock only if its holder is provably dead." ;;
  *"Unable to execute C:\\terraform"*) cause="Windows terraform exe path on the Linux worker (project-level setting). Nothing applied. PROJ-15794." ;;
  *AccessDenied*|*UnauthorizedOperation*|*"not authorized"*) cause="AWS permission denied for the deploy role/user -- identify the action+resource in the message, fix the IAM policy." ;;
  *"did not stabilize"*|*"failed to stabilize"*|*"rolloutState"*|*"tasks failed to start"*) cause="ECS rollout failed: the container is crashing or failing health checks. Read the task's CloudWatch logs (ama-cloudwatch-search) for the new task definition." ;;
  *"Cannot delete entity"*|*"in use"*|*DependencyViolation*) cause="Resource still in use by something not in this stack. Find the dependant, remove/detach, rerun." ;;
esac
is_prod=0; printf '%s' "$desc" | grep -qiE 'production' && is_prod=1
printf '%s' "$info" | jq -r '.Arguments.EnvironmentId // ""' | grep -qF "$PROD_ENV" && is_prod=1

echo "DEPLOY FAILED: $desc ($task) $url"
echo "Cause: $cause"
echo "Error lines:"; printf '%s\n' "$errs" | sed 's/^/  /'
[ -n "$events" ] && { echo "Task events:"; printf '%s\n' "$events" | sed 's/^/  /'; }
echo "DEBUG THIS NOW -- do not wait for the user to report it: confirm the cause from the log, check what (if anything) was applied before the failure, fix the cause, then"
if [ "$is_prod" = 1 ]; then echo "  this is PRODUCTION: prepare the retry (same release) and hand the user the exact step -- the user runs Production writes."
else echo "  retry the same release yourself (POST $O/deployments {ReleaseId, EnvironmentId}) and watch the new task with this script."; fi
echo "Then tell the user: what failed, why, what you did."
exit 0
