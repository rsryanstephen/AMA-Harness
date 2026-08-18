#!/usr/bin/env bash
# Audits every AMA_APP library for Bitbucket build-counter-reset risk -- PROJ-15113.
# Confirmed real incident: product-service-reportclient's build counter was reset
# (likely during the AMA->AMA_APP workspace migration), so a fresh push computed a
# LOWER version than what consumers already referenced -- a genuine downgrade that
# NuGet's resolver happened to catch. Found by accident, for one library, mid-cascade.
# This checks every library up front instead of waiting to stumble onto the next one.
#
# For each library: compares its live Bitbucket build count against the highest
# build-number component any consumer already references. Live count lower than a
# consumer's reference -> same reset almost certainly happened here too.
#
# Usage: BITBUCKET_API_KEY=... bash check-build-counter-reset.sh <repos-root>
set -uo pipefail

REPOS_ROOT="${1:?usage: check-build-counter-reset.sh <repos-root>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HOME/.claude/hooks/lib-harness-repos.sh"
# BB_ORG decides WHICH COMPANY'S Bitbucket gets hit -- no safe default. EMAIL: a wrong
# email 401s identically to a bad API token, so fail loud rather than defaulting.
BB_ORG="$(hr_config_required '.bitbucket.org')" || exit 1
EMAIL="${BITBUCKET_EMAIL:-$(hr_config '.user.email' '')}"
[ -n "$EMAIL" ] || { echo "user.email not set in harness-config.json (or export BITBUCKET_EMAIL) -- run /harness-setup" >&2; exit 1; }

[ -n "${BITBUCKET_API_KEY:-}" ] || { echo "BITBUCKET_API_KEY not set" >&2; exit 1; }

for repo_path in "${REPOS_ROOT}"/*/; do
  repo_name="$(basename "${repo_path}")"
  packages="$(bash "${SCRIPT_DIR}/list-published-packages.sh" "${repo_path}" 2>/dev/null | cut -f1 | sort -u)"
  [ -n "${packages}" ] || continue

  # Local folder names were shortened in an earlier session (e.g. "auth", not
  # "product-service-auth") -- the Bitbucket repo slugs themselves were NOT renamed,
  # and don't all follow the same prefix convention (e.g. cacheupdate-infrastructure's
  # real slug is "yourproduct-cacheupdate-infrastructure", no "exporter"). Reconstructing
  # the slug by guessing a prefix would silently hit the wrong repo for some of these --
  # read it from the repo's own git remote instead, which is always correct.
  remote_url="$(git -C "${repo_path}" remote get-url origin 2>/dev/null)"
  bb_slug="$(printf '%s' "${remote_url}" | grep -oP "(?<=${BB_ORG}/)[^/.]+(?=(\.git)?\$)")"
  if [ -z "${bb_slug}" ]; then
    echo "SKIP  ${repo_name}: couldn't resolve Bitbucket slug from git remote"
    continue
  fi

  # Live build count: highest build_number Bitbucket has ever assigned this repo.
  # Note: Bitbucket's pipelines API rejects sort=-build_number ("invalid sort attribute") --
  # sort by created_on instead, which orders the same way for this purpose.
  live_build="$(curl -s -u "${EMAIL}:${BITBUCKET_API_KEY}" \
    "https://api.bitbucket.org/2.0/repositories/${BB_ORG}/${bb_slug}/pipelines/?sort=-created_on&pagelen=1" \
    2>/dev/null | grep -oP '"build_number":\s*\K[0-9]+' | head -1)"
  if [ -z "${live_build}" ]; then
    echo "SKIP  ${repo_name} (${bb_slug}): no pipeline history found"
    continue
  fi

  while IFS= read -r package_name; do
    [ -n "${package_name}" ] || continue
    max_ref_build=0
    while IFS=$'\t' read -r consumer_repo csproj current_version; do
      [ -n "${current_version}" ] || continue
      build="${current_version##*.}"
      case "${build}" in ''|*[!0-9]*) continue ;; esac
      [ "${build}" -gt "${max_ref_build}" ] && max_ref_build="${build}"
    done < <(bash "${SCRIPT_DIR}/find-consumers.sh" "${package_name}" "${REPOS_ROOT}" 2>/dev/null)

    if [ "${max_ref_build}" -gt "${live_build}" ]; then
      echo "RISK  ${repo_name} (${package_name}): live build ${live_build} < consumer-referenced build ${max_ref_build} -- likely counter reset, treat next bump like reportclient"
    else
      echo "OK    ${repo_name} (${package_name}): live build ${live_build} >= highest referenced ${max_ref_build}"
    fi
  done <<< "${packages}"
done
