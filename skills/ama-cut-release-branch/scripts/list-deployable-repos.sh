#!/usr/bin/env bash
# List AMA_APP repos that are actually deployable (have an origin/develop branch).
# Confirmed real gap: libraries.md/api-services.md conflate "publishes a NuGet
# package" with "is deployable" -- `search` is classified as a library (it does
# publish Search.Cache/Search.Shared NuGet packages) but ALSO has a develop branch
# and deploys real Lambdas. Empirically checking for origin/develop is the correct
# test, not the classification lists.
set -uo pipefail
. "$HOME/.claude/hooks/lib-harness-repos.sh"

# Confirmed second real gap: raw branch existence alone isn't enough either -- some
# repos (common-models, common-mongo, exportproducer-messages, fieldtablemapper-client)
# have an origin/develop branch that's a dead 2020/2021 leftover, no longer touched,
# while master is where all real activity happens. And bitbucket-pipelines.yml content
# isn't a reliable signal either -- some repos (e.g. manage) use one `default:` pipeline
# for ANY branch (no literal "develop" string appears at all), so grepping the YAML for
# "develop" would wrongly exclude a true deployable repo. Recency of the develop
# branch's last commit is the actual reliable signal: real deployable repos get pushed
# to develop routinely; dead ones haven't moved in years.
# Confirmed real gap testing this: a 180-day cutoff wrongly excluded
# selenium-crawlers (a genuinely live, stable Lambda, just infrequently changed -- last
# touched 7 months ago) while the truly abandoned repos are 5+ years stale (2020/2021,
# initial-commit era). The two failure modes differ by an order of magnitude -- a
# wide threshold (2 years) separates them safely without excluding quiet-but-real repos.
BASE="${1:-}"; [ -n "$BASE" ] || BASE="$(hr_roots app | head -1)"
[ -n "$BASE" ] || { echo "no app repos root resolved (see /harness-setup)" >&2; exit 1; }
STALE_DAYS="${2:-730}"
now_epoch="$(date +%s)"

for dir in "${BASE}"/*/; do
  repo="$(basename "${dir}")"
  [ -d "${dir}.git" ] || continue
  git -C "${dir}" branch -r 2>/dev/null | grep -q "origin/develop$" || continue
  last_commit_epoch="$(git -C "${dir}" log -1 --format=%ct origin/develop 2>/dev/null)"
  [ -z "${last_commit_epoch}" ] && continue
  age_days=$(( (now_epoch - last_commit_epoch) / 86400 ))
  if [ "${age_days}" -le "${STALE_DAYS}" ]; then
    echo "${repo}"
  fi
done
