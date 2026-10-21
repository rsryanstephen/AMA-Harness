#!/usr/bin/env bash
# Start a branch's DEFAULT pipeline (the one a push would have run) at the branch's current tip.
# Usage: trigger-branch-pipeline.sh <repo> <branch>
# run-pipeline.sh is custom-pipeline-only (it always sends a selector). This is for the case
# where a push LANDED but Bitbucket never created its pipeline (server-side lost event) -- seen
# 2026-10-15 on search hotfix/130.0.5 (see commit-ticket's GIT-TRANSPORT.md).
# Confirm with pipeline-status.sh --sha first; triggering twice builds/publishes/deploys twice.
set -uo pipefail
. "$(dirname "$0")/lib-bitbucket.sh"
REPO="${1:?usage: trigger-branch-pipeline.sh <repo> <branch>}"
BRANCH="${2:?usage: trigger-branch-pipeline.sh <repo> <branch>}"
SLUG="$(bb_slug "$REPO")"
body="$(jq -n --arg b "$BRANCH" '{target:{type:"pipeline_ref_target",ref_type:"branch",ref_name:$b}}')"
bb_post "$BB_API/$SLUG/pipelines/" -d "$body" \
  | jq -r 'if .type == "error" then "ERROR: \(.error.message)" else "build=\(.build_number) state=\(.state.name) sha=\(.target.commit.hash[0:12])" end'
