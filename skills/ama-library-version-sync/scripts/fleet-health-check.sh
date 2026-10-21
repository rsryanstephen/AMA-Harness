#!/usr/bin/env bash
# Nightly fleet-health sweep for PROJ-15111/15113 -- run headlessly by a Windows
# Scheduled Task (see ~/.claude/AGENTS.md), not meant to be run ad hoc for a quick answer
# (use the two underlying scripts directly for that).
#
# Runs check-pipeline-yaml.js + check-build-counter-reset.sh fleet-wide (plus the scheduled-
# task liveness, QA/Staging ECS rollout-stall and Jira tester-bounce arms below), stores the latest
# full snapshot of each (for other skills to consult -- see ama-library-version-sync's
# SKILL.md), and appends only the DELTA vs the previous run to results.log so the log stays
# readable instead of re-printing a clean fleet every night.
#
# Usage: BITBUCKET_API_KEY=... bash fleet-health-check.sh <repos-root>
# <harnessEpicKey>: this sweep had NO delivery path at all -- deltas sat in results.log
# unread until a session happened to go look, which never happened (7 findings -- 6 RISK
# build-counter-resets + one FAIL YAML parse error -- had been silently accumulating).
# Added below: ping .fleetHealth.reportTarget on newly-added RISK/FAIL lines only, never
# on OK churn (543 of results.log's lines are benign OK vs 159 RISK/FAIL -- "ping on any
# change" would DM nightly about build numbers and get muted within a week), deduped
# against .fleet-health-pinged since the same RISK lines are confirmed to flap in and out
# across runs (would otherwise re-ping on every flap).
set -uo pipefail

REPOS_ROOT="${1:?usage: fleet-health-check.sh <repos-root>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$HOME/.claude/fleet-health"
mkdir -p "${OUT_DIR}"

. "$HOME/.claude/hooks/lib-harness-repos.sh"
. "$HOME/.claude/hooks/lib-claude-paths.sh"

TS="$(date '+%Y-%m-%d %H:%M:%S')"
DELTA_TMP="$(mktemp)"
trap 'rm -f "$DELTA_TMP"' EXIT

# Direct function calls, not eval'd strings -- eval-ing a hand-built command string
# with nested quoting silently produced an empty build-counter check under one launch
# path (a hidden-window Task Scheduler runner) while working fine interactively.
# Calling a function by name is exactly as flexible here and has no quoting to get wrong.
check_pipeline_yaml() {
  node "${SCRIPT_DIR}/check-pipeline-yaml.js" "${REPOS_ROOT}"
}

check_build_counter() {
  bash "${SCRIPT_DIR}/check-build-counter-reset.sh" "${REPOS_ROOT}"
}

# Scheduled-task liveness (<harnessEpicKey>). Added because registration is NOT liveness: two
# AMA-Harness-* tasks were found on 2026-09-01 to have been State=Ready with a plausible
# NextRunTime while failing on every tick and doing nothing, for weeks, silently -- one of
# them the VPN-DNS probe that PROJ-15367 shipped precisely as a detector.
#
# Hosted here rather than in its own scheduled task on purpose: it inherits run_check's
# delta/dedupe and this script's ping-on-new-RISK/FAIL block for free, and adding a new task
# to watch for dead tasks just deepens the turtle stack. What watches THIS sweep is
# hooks/fleet-health-check.sh, which nudges in-session when run-history.log goes stale.
#
# NOT "${SCRIPT_DIR}/...": this script is launched as
# ~/.claude/skills/.../fleet-health-check.sh (see run-fleet-health-hidden.ps1), so SCRIPT_DIR
# sits under the ~/.claude JUNCTION -- and `powershell.exe -File` through a junction reports
# the file doesn't exist (PORTABILITY.md's junction note). Resolve the real repo root first.
check_scheduled_tasks() {
  local repo ps1 win
  repo="$(git -C "$HOME/.claude/hooks" rev-parse --show-toplevel 2>/dev/null)"
  ps1="${repo}/skills/ama-library-version-sync/scripts/check-scheduled-tasks.ps1"
  win="$(cygpath -w "${ps1}" 2>/dev/null)"
  if [ -z "${repo}" ] || [ ! -f "${ps1}" ] || [ -z "${win}" ]; then
    # Stable text, so this pings once rather than every night, and never leaves the snapshot
    # silently empty (an empty snapshot would read as "every task deleted").
    echo "FAIL scheduled-task-inventory checker-unavailable"
    return 0
  fi
  powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "${win}" 2>/dev/null | tr -d '\r'
}

# A QA/Staging deploy that never STARTS is invisible (<harnessEpicKey>, 2026-09-22): cohortreports'
# develop builds crash-looped on startup for a week, QA kept serving the previous image, and
# nothing noticed -- verify-qa-deploy.sh only runs right after a session's own push. Any service
# whose PRIMARY deployment is not COMPLETED, or that still has >1 deployment, more than 30 min
# after that deployment was created is stuck. Steady definition from ama-cloudwatch-search's
# wait-ecs-rollout.sh. Output stays volatile-free (no timestamps) per the OUTPUT CONTRACT in
# check-scheduled-tasks.ps1: a stuck service is one stable RISK line until it moves.
check_ecs_rollouts() {
  local env cluster cutoff json
  cutoff="$(( $(date +%s) - 1800 ))"
  for env in qa staging; do
    cluster="${env}-v1-AMA"
    json="$(MSYS_NO_PATHCONV=1 aws ecs list-services --cluster "${cluster}" --max-items 200 --output json 2>/dev/null)" || json=""
    local svcs
    svcs="$(printf '%s' "${json}" | jq -r '.serviceArns[]?' 2>/dev/null | sed 's|.*/||' | sort)"
    if [ -z "${svcs}" ]; then echo "FAIL ecs-rollout ${env} checker-unavailable"; continue; fi
    local found=0 chunk
    # describe-services takes at most 10 services per call.
    while read -r chunk; do
      [ -n "${chunk}" ] || continue
      # shellcheck disable=SC2086
      MSYS_NO_PATHCONV=1 aws ecs describe-services --cluster "${cluster}" --services ${chunk} --output json 2>/dev/null \
        | jq -r --argjson cut "${cutoff}" '
            .services[]? | . as $s
            | ($s.deployments | map(select(.status=="PRIMARY")) | .[0]) as $p
            | select($p != null and ($p.createdAt | tonumber) < $cut
                     and (($p.rolloutState // "COMPLETED") != "COMPLETED" or ($s.deployments | length) > 1))
            | "RISK ecs-rollout-stalled \($s.serviceName)"' 2>/dev/null \
        | while read -r line; do echo "${line}"; done
    done < <(printf '%s\n' "${svcs}" | awk 'NR%10==1{if(l)print l; l=$0; next}{l=l" "$0} END{print l}')
    # `found` cannot cross the pipe; recount from a second pass is wasteful, so emit the OK
    # line unconditionally -- run_check diffs lines, and OK + RISK for one env is readable.
    echo "OK ecs-rollout ${env} checked"
  done
}

# A tester bounce is invisible (<harnessEpicKey>, 2026-09-21): <uiTesterName> moved PROJ-14875
# Ready to Test -> To Do with a FAILED step in his test table, and backlog pickup read it as a
# plain To Do. Jira's changelog is the only record; poll it here. backlog-candidates.sh marks
# the same keys BOUNCED at pickup time; memory/ama-backlog-page.md says what to do with one.
check_tester_bounces() {
  local rows
  rows="$(bash "$HOME/.claude/skills/ama-jira-api/scripts/jira-search.sh" \
    'status CHANGED FROM "Ready to Test" TO "To Do" AFTER -30d AND status = "To Do" AND assignee = currentUser()' \
    "summary" 50 2>/dev/null)" || { echo "FAIL tester-bounce checker-unavailable"; return 0; }
  if [ -z "${rows}" ]; then echo "OK tester-bounce none"; return 0; fi
  printf '%s\n' "${rows}" | awk -F'\t' 'NF { printf "RISK tester-bounce %s returned-to-To-Do -- read its LAST comment before working it\n", $1 }'
}

run_check() {
  local name="$1"
  local fn="$2"
  local latest="${OUT_DIR}/latest-${name}.txt"
  local prev="${latest}.prev"
  [ -f "${latest}" ] && cp "${latest}" "${prev}" || : > "${prev}"

  "${fn}" > "${latest}.new" 2>&1
  mv "${latest}.new" "${latest}"

  local delta
  delta="$(diff "${prev}" "${latest}" 2>/dev/null | grep -E '^[<>]' || true)"
  if [ -n "${delta}" ]; then
    {
      echo "=== ${TS} -- ${name} changed ==="
      echo "${delta}"
      echo
    } >> "${OUT_DIR}/results.log"
    printf '%s\n' "${delta}" >> "${DELTA_TMP}"
  fi
  rm -f "${prev}"
}

run_check "pipeline-yaml" check_pipeline_yaml
run_check "build-counter" check_build_counter
run_check "scheduled-tasks" check_scheduled_tasks
run_check "ecs-rollouts" check_ecs_rollouts
run_check "tester-bounces" check_tester_bounces

# run-history.log lives under harness-state/logs (PROJ-15342), NOT alongside
# results.log/latest-*.txt in OUT_DIR -- those stay put, they're the fleet-wide snapshot
# other skills consult by that literal path (this file's own header). run-history.log is
# a completion marker, same "state" category as the dedupe files below, and
# hooks/fleet-health-check.sh already reads it via this exact hstate call -- writing it
# anywhere else would silently orphan that hook's staleness check after its one-time
# absorb-on-touch migrates the old file away.
RUN_HISTORY="$(hstate logs fleet-health/run-history.log)"
echo "${TS} -- fleet health check complete, see ${OUT_DIR}/results.log for deltas" >> "${RUN_HISTORY}"

# --- Ping on newly-added RISK/FAIL only -----------------------------------------------
PINGED_FILE="$(hstate notices .fleet-health-pinged)"
DIGEST_FILE="$(hstate notices .fleet-health-digest)"
touch "${PINGED_FILE}"

# `> ` = a line present in this run's output but not the previous one -- i.e. newly
# added, which is what "new finding" means here. A RISK/FAIL line that merely persists
# unchanged across runs never appears in the diff at all, so it can't re-ping.
new_problems="$(grep -E '^> *(RISK|FAIL)' "${DELTA_TMP}" 2>/dev/null | sed 's/^> *//' | sort -u || true)"
if [ -n "${new_problems}" ]; then
  # `grep -v` exits 1 whenever EVERY line is filtered out -- i.e. exactly the "fully
  # deduped, nothing unseen" case -- so an `|| fallback` here would silently defeat
  # dedup on every run that finds nothing new (confirmed live in a dry-run test before
  # this ever reached a real schedule). PINGED_FILE is `touch`ed above specifically so
  # `-f` never errors on a missing file, which is the one case a fallback would matter for.
  unseen="$(printf '%s\n' "${new_problems}" | grep -vFxf "${PINGED_FILE}" 2>/dev/null)"
  if [ -n "${unseen}" ]; then
    printf '%s\n' "${unseen}" >> "${PINGED_FILE}"

    count="$(printf '%s\n' "${unseen}" | grep -c .)"
    shown="$(printf '%s\n' "${unseen}" | head -10)"
    extra=""
    [ "${count}" -gt 10 ] && extra=" and $((count - 10)) more"

    printf 'Fleet health: %s new finding(s)%s. See %s/results.log.\n' "${count}" "${extra}" "${OUT_DIR}" >> "${DIGEST_FILE}"

    TARGET="$(hr_config '.fleetHealth.reportTarget' '')"
    if [ -n "${TARGET}" ] && command -v claude >/dev/null 2>&1; then
      # Backtick each repo/package token per slack-messages-terse; the log's own lines
      # already start with the repo/package name.
      msg="$(hr_self_mention "${TARGET}")Fleet health: ${count} new finding(s)${extra}. $(printf '%s' "${shown}" | sed -E 's/^([A-Za-z0-9_.-]+)/`\1`/' | tr '\n' ';' | sed 's/;/; /g')"
      TO=""; command -v timeout >/dev/null 2>&1 && TO="timeout 120"
      $TO claude -p "Call mcp__claude_ai_Slack__slack_send_message with channel_id ${TARGET} and this exact message text: ${msg} -- then reply with ONLY the word DONE, or FAILED: and the error." \
        --model haiku --allowedTools mcp__claude_ai_Slack__slack_send_message \
        >> "${OUT_DIR}/ping.log" 2>&1 || true
    fi
  fi
fi
