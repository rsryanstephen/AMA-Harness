#!/usr/bin/env bash
# End-to-end deployment verification: Bitbucket Pipeline -> Octopus Deploy (Spaces-1) ->
# live AWS state. Extends verify-qa-deploy.sh (ECS/CloudWatch check) with the two stages
# in front of it. Offer-only -- never run this without the user's go-ahead, see
# DEPLOY-VERIFICATION.md.
#
# Usage: verify-deployment-e2e.sh <repo> [bitbucket-repo-slug-override] [ecs-short-name-override]
#
# Version-matching is the cross-system key: build-and-publish.sh hardcodes ECS Docker
# tags as "2.0.0.<BITBUCKET_BUILD_NUMBER>" (confirmed -- no VersionPrefix, no branch
# suffix, unlike the NuGet path in package.sh). The Octopus release version for that
# same build is identical (confirmed empirically: search build 2.0.0.101 == Octopus
# release 2.0.0.101 == deployed ECS image tag 2.0.0.101). Used here to both resolve
# which Octopus project is the live one (when repo name maps to multiple candidates)
# and to confirm the AWS-deployed image is actually the one just built.
set -uo pipefail

REPO="${1:?usage: verify-deployment-e2e.sh <repo> [bitbucket-repo-slug-override] [ecs-short-name-override]}"
ECS_SHORT="${3:-${REPO}}"

if [ -z "${BITBUCKET_API_KEY:-}" ]; then
  echo "BITBUCKET_API_KEY not set -- see the bitbucket-api skill for setup." >&2
  exit 1
fi
if [ -z "${OCTOPUS_API_KEY:-}" ]; then
  echo "OCTOPUS_API_KEY not set." >&2
  exit 1
fi
. "$HOME/.claude/hooks/lib-harness-repos.sh"
# hr_config value-checks the read (`v` non-empty) rather than trusting jq's exit code --
# jq exits 0 even when it fails to OPEN the config file (confirmed: prints its error to
# stderr, "$(...)" captures empty), so the old `[ -f "$CONFIG" ] && jq ...` form here
# silently fell back to the hardcoded defaults below on ANY read failure, not just a
# missing file. Same class of bug as the MSYS_NO_PATHCONV gap this script already fixed.
OCTOPUS_HOST="$(hr_config '.octopus.serverUrl' 'https://yourorg.octopus.app')"
OCTOPUS_SPACE="$(hr_config '.octopus.spaceId' 'Spaces-1')"
# No safe default -- a wrong email 401s identically to a bad API token. Fail loud.
BB_USER="${BITBUCKET_USER_EMAIL:-$(hr_config '.user.email' '')}"
[ -n "$BB_USER" ] || { echo "user.email not set in harness-config.json (or export BITBUCKET_USER_EMAIL) -- run /harness-setup" >&2; exit 1; }
# bitbucket.org decides WHICH COMPANY'S Bitbucket STAGE 1 hits -- this file never read
# it at all before (the URL below hardcoded "yourorg" directly), no safe default.
BB_ORG="$(hr_config_required '.bitbucket.org')" || exit 1
# Naming-pattern default, not a wrong-org risk (an explicit $2 override always wins) --
# safe to leave defaulted, unlike the fatal reads above.
BB_SLUG="${2:-$(hr_config '.bitbucket.repoSlugPrefix' 'product-service-')${REPO}}"

echo "=================================================="
echo "STAGE 1: Bitbucket Pipeline (${BB_SLUG}, develop)"
echo "=================================================="
pipeline_json="$(curl -sS -u "${BB_USER}:${BITBUCKET_API_KEY}" \
  "https://api.bitbucket.org/2.0/repositories/${BB_ORG}/${BB_SLUG}/pipelines/?sort=-created_on&pagelen=1&target.branch=develop")"
if ! printf '%s' "${pipeline_json}" | jq -e '.values[0]' >/dev/null 2>&1; then
  echo "Couldn't fetch pipeline status:" >&2
  echo "${pipeline_json}" >&2
  exit 1
fi
bb_state="$(printf '%s' "${pipeline_json}" | jq -r '.values[0].state.name')"
bb_result="$(printf '%s' "${pipeline_json}" | jq -r '.values[0].state.result.name // "n/a"')"
bb_build_number="$(printf '%s' "${pipeline_json}" | jq -r '.values[0].build_number')"
echo "Latest develop build: #${bb_build_number} -- state=${bb_state} result=${bb_result}"

if [ "${bb_state}" = "IN_PROGRESS" ] || [ "${bb_result}" = "FAILED" ] || [ "${bb_result}" = "ERROR" ]; then
  echo "RESULT: Bitbucket build is ${bb_state}/${bb_result} -- stopping here, not a rollout to trace yet."
  echo "Fetch logs: bash \"\$(dirname \"\$0\")/../bitbucket-api\" skill, pipeline UUID from the JSON above."
  exit 1
fi

EXPECTED_VERSION="2.0.0.${bb_build_number}"
echo "Expected version (from build-and-publish.sh convention): ${EXPECTED_VERSION}"

echo
echo "=================================================="
echo "STAGE 2: Octopus Deploy release resolution (${OCTOPUS_SPACE})"
echo "=================================================="
projects_json="$(curl -sS -H "X-Octopus-ApiKey: ${OCTOPUS_API_KEY}" \
  "${OCTOPUS_HOST}/api/${OCTOPUS_SPACE}/projects/all")"
# Anchored match, not a raw substring -- confirmed real bug testing this: a loose
# `contains(repo)` on "search" also matched "etl-load-elasticsearch-emr" and
# "backbone-elasticsearch" (both contain "search" as a substring of "elasticsearch").
# Anchor to the known project-slug prefixes instead. Also require an "-ecs" suffix --
# confirmed real ambiguity: "search" resolves to BOTH product-service-search-api-ecs
# AND product-service-search-cacheupdate-lambda, which coincidentally shares the same
# build-number-derived version. This script only verifies ECS, so exclude non-ECS
# projects (Lambda-suffixed) up front rather than relying on the version match alone.
# Prefix list is a naming-pattern default (octopus.projectNamePatterns), same
# safe-to-default reasoning as BB_SLUG above.
PROJECT_PREFIXES="$(hr_config '.octopus.projectNamePatterns' '["product-service-","other-project-"]')"
pattern_alt="$(printf '%s' "${PROJECT_PREFIXES}" | jq -r --arg repo "${REPO}" '[.[] | . + $repo] | join("|")')"
candidates="$(printf '%s' "${projects_json}" | jq -r --arg alt "${pattern_alt}" \
  '.[] | select(.Slug | ascii_downcase | test("^(" + $alt + ").*-ecs$")) | "\(.Id)\t\(.Name)"')"

if [ -z "${candidates}" ]; then
  echo "No Octopus project found matching '${REPO}' -- can't proceed. Check the project name manually in ${OCTOPUS_HOST}." >&2
  exit 1
fi

echo "Candidate projects (by name match):"
echo "${candidates}"

matched_id=""
matched_name=""
match_count=0
while IFS=$'\t' read -r cand_id cand_name; do
  [ -z "${cand_id}" ] && continue
  rel="$(curl -sS -H "X-Octopus-ApiKey: ${OCTOPUS_API_KEY}" \
    "${OCTOPUS_HOST}/api/${OCTOPUS_SPACE}/projects/${cand_id}/releases?take=1")"
  rel_version="$(printf '%s' "${rel}" | jq -r '.Items[0].Version // empty')"
  if [ "${rel_version}" = "${EXPECTED_VERSION}" ]; then
    matched_id="${cand_id}"
    matched_name="${cand_name}"
    match_count=$((match_count + 1))
  fi
done <<< "${candidates}"

if [ "${match_count}" -ne 1 ]; then
  echo "RESULT: repository mapping cannot be implicitly derived -- ${match_count} candidate project(s) have a release matching ${EXPECTED_VERSION}." >&2
  echo "Flagging to user per the guardrail, not guessing. Candidates were:" >&2
  echo "${candidates}" >&2
  exit 1
fi
echo "Resolved: ${matched_name} (${matched_id}) -- release ${EXPECTED_VERSION} confirmed."

deployments_json="$(curl -sS -H "X-Octopus-ApiKey: ${OCTOPUS_API_KEY}" \
  "${OCTOPUS_HOST}/api/${OCTOPUS_SPACE}/projects/${matched_id}/releases?take=1")"
release_id="$(printf '%s' "${deployments_json}" | jq -r '.Items[0].Id // empty')"
task_json="$(curl -sS -H "X-Octopus-ApiKey: ${OCTOPUS_API_KEY}" \
  "${OCTOPUS_HOST}/api/${OCTOPUS_SPACE}/deployments?release=${release_id}&take=1")"
deploy_state="$(printf '%s' "${task_json}" | jq -r '.Items[0].TaskId // "unknown"')"
echo "Latest deployment task for this release: ${deploy_state}"

echo
echo "=================================================="
echo "STAGE 3: Live AWS state (delegating to verify-qa-deploy.sh)"
echo "=================================================="
# Needed here, not earlier -- exporting it before the config/jq reads above
# broke them (native jq.exe can't resolve the unconverted path), silently
# emptying BB_USER/OCTOPUS_HOST/OCTOPUS_SPACE. Only the AWS stage needs it.
export MSYS_NO_PATHCONV=1
bash "$(dirname "$0")/verify-qa-deploy.sh" "${REPO}" ecs 15 "${ECS_SHORT}" "${EXPECTED_VERSION}"
aws_exit=$?

echo
echo "=================================================="
echo "DEPLOYMENT VERIFICATION REPORT"
echo "=================================================="
echo "Bitbucket Build:    #${bb_build_number} (${bb_result})"
echo "Octopus Release:    ${EXPECTED_VERSION} (${matched_name}, ${OCTOPUS_SPACE})"
echo "AWS Infrastructure: $([ "${aws_exit}" -eq 0 ] && echo VERIFIED || echo "FAILED -- see STAGE 3 output above")"
exit "${aws_exit}"
