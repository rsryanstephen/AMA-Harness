#!/usr/bin/env bash
# Open a Bitbucket pull request via the REST API.
# Requires $BITBUCKET_API_KEY (Basic auth as <email>:$BITBUCKET_API_KEY).
# Usage: create-bitbucket-pr.sh <repo-slug> <source-branch> <dest-branch> <title> [description]
set -uo pipefail

repo_slug="${1:?usage: create-bitbucket-pr.sh <repo-slug> <source-branch> <dest-branch> <title> [description]}"
source_branch="${2:?missing source-branch}"
dest_branch="${3:?missing dest-branch}"
title="${4:?missing title}"
description="${5:-}"
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

payload=$(node -e "
const p = {
  title: process.argv[1],
  source: { branch: { name: process.argv[2] } },
  destination: { branch: { name: process.argv[3] } },
  description: process.argv[4] || '',
  close_source_branch: true
};
console.log(JSON.stringify(p));
" "${title}" "${source_branch}" "${dest_branch}" "${description}")

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
