#!/usr/bin/env bash
# Builds the repo<TAB>source-ref mapping file cut-release-branches.sh consumes, so
# Claude doesn't hand-format one line per repo. Libraries no longer get a release
# branch cut (see Step 4's drift-check instead), so this only ever needs the
# deployables case: every repo gets "origin/develop" as its source-ref.
#
# Usage: build-mapping-file.sh <mapping-file> [repos-base-dir] [stale-days]
# Appends "<repo>\torigin/develop" for every repo list-deployable-repos.sh finds.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HOME/.claude/hooks/lib-harness-repos.sh"

MAPFILE="${1:?usage: build-mapping-file.sh <mapping-file> [repos-base-dir] [stale-days]}"
BASE="${2:-}"; [ -n "$BASE" ] || BASE="$(hr_roots app | head -1)"
[ -n "$BASE" ] || { echo "no app repos root resolved (see /harness-setup)" >&2; exit 1; }
STALE_DAYS="${3:-730}"

bash "${SCRIPT_DIR}/list-deployable-repos.sh" "$BASE" "$STALE_DAYS" | while IFS= read -r repo; do
  printf '%s\torigin/develop\n' "$repo" >> "$MAPFILE"
done
