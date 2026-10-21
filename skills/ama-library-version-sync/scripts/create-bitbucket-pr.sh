#!/usr/bin/env bash
# Open a Bitbucket pull request via the REST API.
# Requires $BITBUCKET_API_KEY (Basic auth as <email>:$BITBUCKET_API_KEY).
# Usage: create-bitbucket-pr.sh <repo-slug> <source-branch> <dest-branch> <title> <description> [reviewer-uuid ...]
#
# description is REQUIRED and must explain WHY the change was made (Your Name's rule, 2026-09-09) --
# the title and diff already say what changed. Brief is the point: two or three sentences.
# pr-description-why-gate.sh enforces the same rule on the raw-curl form; here the description
# is a clean argv element, so it is checked directly instead of by reparsing shell quoting.
#
# Reviewers default to .bitbucket.defaultPrReviewers. Until 2026-09-09 this script set no
# reviewers at all, so every PR it opened was assigned to nobody.
set -uo pipefail

usage="usage: create-bitbucket-pr.sh <repo-slug> <source-branch> <dest-branch> <title> <description> [reviewer-uuid ...]"
repo_slug="${1:?$usage}"
source_branch="${2:?missing source-branch}"
dest_branch="${3:?missing dest-branch}"
title="${4:?missing title}"
description="${5:?missing description -- it must briefly say WHY the change was made}"
shift 5 || true
reviewer_uuids=("$@")

MIN_DESCRIPTION_CHARS=60
if [ "${#description}" -lt "$MIN_DESCRIPTION_CHARS" ]; then
  echo "ERROR: description is ${#description} chars; it must briefly explain WHY the change was made (minimum ${MIN_DESCRIPTION_CHARS})" >&2
  exit 1
fi
. "$HOME/.claude/hooks/lib-harness-repos.sh"
# bb_org decides WHICH COMPANY'S Bitbucket a PR gets opened against -- no safe default.
# email: a wrong email 401s identically to a bad API token, so fail loud too.
bb_org="$(hr_config_required '.bitbucket.org')" || exit 1
email="${BITBUCKET_EMAIL:-$(hr_config '.user.email' '')}"
[ -n "$email" ] || { echo "user.email not set in harness-config.json (or export BITBUCKET_EMAIL) -- run /harness-setup" >&2; exit 1; }

if [ -z "${BITBUCKET_API_KEY:-}" ]; then
  echo "ERROR: BITBUCKET_API_KEY is not set" >&2
  exit 1
fi

# bitbucket.defaultPrReviewers are ADDED to any PR-specific reviewers, never replaced by
# them -- ama-bitbucket-api/SKILL.md's rule. This used to apply the defaults only when NO
# reviewers were passed, so every ETL-fix PR (which passes its own two) silently dropped the
# mandated defaults (found 2026-09-15). Union, de-duplicated. Empty/absent defaults are fine.
while IFS= read -r uuid; do
  [ -n "$uuid" ] && reviewer_uuids+=("$uuid")
done < <(hr_config '.bitbucket.defaultPrReviewers' '[]' | jq -r '.[]?.uuid // empty' | sed 's/\r$//')
if [ "${#reviewer_uuids[@]}" -gt 0 ]; then
  mapfile -t reviewer_uuids < <(printf '%s\n' "${reviewer_uuids[@]}" | awk '!seen[$0]++')
fi

payload=$(node -e "
const p = {
  title: process.argv[1],
  source: { branch: { name: process.argv[2] } },
  destination: { branch: { name: process.argv[3] } },
  description: process.argv[4] || '',
  close_source_branch: true
};
const reviewers = process.argv.slice(5).filter(Boolean);
if (reviewers.length) p.reviewers = reviewers.map(uuid => ({ uuid }));
console.log(JSON.stringify(p));
" "${title}" "${source_branch}" "${dest_branch}" "${description}" ${reviewer_uuids[@]+"${reviewer_uuids[@]}"})

response=$(curl -s -u "${email}:${BITBUCKET_API_KEY}" \
  -X POST \
  -H "Content-Type: application/json" \
  -d "${payload}" \
  "https://api.bitbucket.org/2.0/repositories/${bb_org}/${repo_slug}/pullrequests")

pr_url=$(node -e "
const d = JSON.parse(process.argv[1]);
if (d.error) { console.error('ERROR: ' + JSON.stringify(d.error)); process.exit(1); }
console.log(d.links && d.links.html && d.links.html.href || '');
" "${response}") || { echo "${response}" >&2; exit 1; }

echo "${pr_url}"
