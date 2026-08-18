#!/usr/bin/env bash
# Mechanical branch-cutting for a release, driven by a repo->source-ref mapping file so
# Claude spends tokens on the diagnostic work (version/repo-list resolution,
# verification) instead of one tool call per repo for fetch/checkout/push.
#
# Usage: cut-release-branches.sh <version e.g. 129.0.0> <mapping-file> [repos-base-dir]
#
# mapping-file: one "repo<TAB>source-ref" per line, blank lines/leading # ignored.
#   source-ref = "origin/develop" for every deployable repo (Step 3 -- libraries no
#   longer get a release branch cut, see Step 4's drift-check instead).
#
# Prints one line per repo: "<repo>: cut" / "<repo>: skip (branch exists, tip matches)"
# / "<repo>: MISMATCH existing=<sha> resolved=<sha>" / "<repo>: FAILED <reason>".
# Exits non-zero if ANY repo failed outright (not counting skip/mismatch, which are
# reported for Claude to judge, not hard failures of the script itself).
set -uo pipefail
. "$HOME/.claude/hooks/lib-harness-repos.sh"

VERSION="${1:?usage: cut-release-branches.sh <version> <mapping-file> [repos-base-dir]}"
MAPFILE="${2:?usage: cut-release-branches.sh <version> <mapping-file> [repos-base-dir]}"
BASE="${3:-}"; [ -n "$BASE" ] || BASE="$(hr_roots app | head -1)"
[ -n "$BASE" ] || { echo "no app repos root resolved (see /harness-setup)" >&2; exit 1; }
BRANCH="release/${VERSION}"

[ -f "$MAPFILE" ] || { echo "mapping file not found: $MAPFILE" >&2; exit 1; }

had_failure=0

while IFS=$'\t' read -r repo ref; do
  [ -z "${repo:-}" ] && continue
  case "$repo" in \#*) continue ;; esac
  [ -z "${ref:-}" ] && { echo "${repo}: FAILED no source-ref given"; had_failure=1; continue; }

  dir="${BASE}/${repo}"
  [ -d "${dir}/.git" ] || { echo "${repo}: FAILED not a git repo at ${dir}"; had_failure=1; continue; }

  if ! git -C "$dir" fetch origin >/dev/null 2>&1; then
    echo "${repo}: FAILED fetch (network/DNS? see commit-ticket skill's DNS-blip rule)"
    had_failure=1
    continue
  fi

  existing="$(git -C "$dir" rev-parse --verify -q "origin/${BRANCH}" 2>/dev/null || true)"
  if [ -n "$existing" ]; then
    resolved="$(git -C "$dir" rev-parse --verify -q "$ref" 2>/dev/null || true)"
    if [ -n "$resolved" ] && [ "$existing" = "$resolved" ]; then
      echo "${repo}: skip (branch exists, tip matches ${ref})"
    else
      echo "${repo}: MISMATCH existing=${existing} resolved=${resolved:-unresolved} ref=${ref}"
    fi
    continue
  fi

  if ! git -C "$dir" checkout -b "$BRANCH" "$ref" >/dev/null 2>&1; then
    echo "${repo}: FAILED checkout -b ${BRANCH} ${ref}"
    had_failure=1
    continue
  fi

  if ! git -C "$dir" push -u origin "$BRANCH" >/dev/null 2>&1; then
    echo "${repo}: FAILED push ${BRANCH}"
    had_failure=1
    continue
  fi

  echo "${repo}: cut"
done < "$MAPFILE"

exit "$had_failure"
