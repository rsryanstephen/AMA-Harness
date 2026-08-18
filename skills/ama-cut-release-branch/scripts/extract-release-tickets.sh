#!/usr/bin/env bash
# Extracts every ticket reference carried by a release branch that ISN'T already on
# master -- i.e. included in this release but not yet deployed to production (master
# only gets the merge during ama-deploy-release's actual production deploy). Purely
# mechanical text extraction; Claude still does the diagnostic part (check each
# ticket's current status, skip anything already Done, set the Fix Version field).
#
# Usage: extract-release-tickets.sh <version> <repo-list-file> [repos-base-dir]
#   repo-list-file: one repo name per line (e.g. Step 2's list-deployable-repos.sh
#   output, or the repo column of a cut-release-branches.sh mapping file).
#
# Prints one unique ticket key (e.g. PROJ-15234) per line, sorted, across all
# listed repos combined.
set -uo pipefail
. "$HOME/.claude/hooks/lib-harness-repos.sh"

VERSION="${1:?usage: extract-release-tickets.sh <version> <repo-list-file> [repos-base-dir]}"
REPOLIST="${2:?usage: extract-release-tickets.sh <version> <repo-list-file> [repos-base-dir]}"
BASE="${3:-}"; [ -n "$BASE" ] || BASE="$(hr_roots app | head -1)"
[ -n "$BASE" ] || { echo "no app repos root resolved (see /harness-setup)" >&2; exit 1; }
BRANCH="release/${VERSION}"
# Wrong/missing project key silently returns zero tickets, not an error -- required,
# not defaulted, same "fail loud" fix wave 2 applies to Bitbucket/AWS/Graylog reads.
PROJECT_KEY="$(hr_config_required '.atlassian.jiraProjectKey')" || exit 1

[ -f "$REPOLIST" ] || { echo "repo list file not found: $REPOLIST" >&2; exit 1; }

while IFS=$'\t' read -r repo _rest; do
  [ -z "${repo:-}" ] && continue
  case "$repo" in \#*) continue ;; esac
  dir="${BASE}/${repo}"
  [ -d "${dir}/.git" ] || continue
  git -C "$dir" rev-parse --verify -q "origin/${BRANCH}" >/dev/null 2>&1 || continue
  git -C "$dir" rev-parse --verify -q "origin/master" >/dev/null 2>&1 || continue
  git -C "$dir" log "origin/master..origin/${BRANCH}" --format=%s 2>/dev/null
done < "$REPOLIST" | grep -oE "${PROJECT_KEY}-[0-9]+" | sort -u -t- -k2 -n
