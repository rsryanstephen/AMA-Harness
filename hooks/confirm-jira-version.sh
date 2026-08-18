#!/usr/bin/env bash
# Usage: confirm-jira-version.sh <version>
# Model-invoked (not a hook) ONLY after the user has explicitly confirmed a release/*
# or hotfix/* Fix Version was manually created in Jira project settings -- there's no
# MCP tool or REST credential here to create one. Records it so
# jira-fixversion-confirm-gate.sh stops blocking tags against that version. Persistent,
# not session-scoped -- a version that exists in Jira stays valid indefinitely.
set -u
version="${1:-}"
[ -n "$version" ] || { echo "usage: confirm-jira-version.sh <version>" >&2; exit 1; }

FILE="$HOME/.claude/.confirmed-jira-versions"
touch "$FILE"
grep -qxF "$version" "$FILE" || printf '%s\n' "$version" >> "$FILE"
echo "confirmed: $version"
# Mechanical nudge (script output reaches the model every time, unlike skill prose):
# Jira version descriptions surface as the Octopus Releases page's Description column.
echo "NOW SET ITS DESCRIPTION: fetch this version's description (GET /rest/api/3/project/PROJ/versions); if empty, PUT a plain 1-3 sentence description per ama-jira-api's 'Version descriptions' section (hotfix = the defect + the fix; release = the work by theme). Octopus shows it as the release's Description."
