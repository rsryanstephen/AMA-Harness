#!/usr/bin/env bash
# Nightly fleet-health sweep for PROJ-15111/15113 -- run headlessly by a Windows
# Scheduled Task (see ~/.claude/AGENTS.md), not meant to be run ad hoc for a quick answer
# (use the two underlying scripts directly for that).
#
# Runs check-pipeline-yaml.js + check-build-counter-reset.sh fleet-wide, stores the latest
# full snapshot of each (for other skills to consult -- see ama-library-version-sync's
# SKILL.md), and appends only the DELTA vs the previous run to results.log so the log stays
# readable instead of re-printing a clean fleet every night.
#
# Usage: BITBUCKET_API_KEY=... bash fleet-health-check.sh <repos-root>
set -uo pipefail

REPOS_ROOT="${1:?usage: fleet-health-check.sh <repos-root>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$HOME/.claude/fleet-health"
mkdir -p "${OUT_DIR}"

TS="$(date '+%Y-%m-%d %H:%M:%S')"

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
  fi
  rm -f "${prev}"
}

run_check "pipeline-yaml" check_pipeline_yaml
run_check "build-counter" check_build_counter

echo "${TS} -- fleet health check complete, see ${OUT_DIR}/results.log for deltas" >> "${OUT_DIR}/run-history.log"
