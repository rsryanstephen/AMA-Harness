#!/usr/bin/env bash
# Checks whether any deployable repo's develop branch (== what's on QA, since develop
# auto-deploys there) references an older packages.libraryPrefix (harness-config.json)
# library version than what's actually latest-published in CodeArtifact. Read-only --
# reports drift, doesn't fix anything. Domain/repo: aws.codeArtifact.{domain,repository}
# in harness-config.json.
#
# Usage: check-library-drift.sh <repo-list-file> [repos-base-dir]
#   repo-list-file: one repo name per line (e.g. list-deployable-repos.sh output).
#
# Prints one line per OUT-OF-DATE (repo, library) pair:
#   <repo>\t<package>\t<current-version>\t<latest-version>
# Silent (no output) if everything's current. Exits 0 always -- this is a report, the
# decision to update is the user's, per ama-cut-release-branch's Step 4.
set -uo pipefail
export MSYS_NO_PATHCONV=1
. "$HOME/.claude/hooks/lib-harness-repos.sh"

REPOLIST="${1:?usage: check-library-drift.sh <repo-list-file> [repos-base-dir]}"
BASE="${2:-}"; [ -n "$BASE" ] || BASE="$(hr_roots app | head -1)"
[ -n "$BASE" ] || { echo "no app repos root resolved (see /harness-setup)" >&2; exit 1; }
DOMAIN="$(hr_config '.aws.codeArtifact.domain' 'yourorg')"
CA_REPO="$(hr_config '.aws.codeArtifact.repository' '<repository>')"
# Found while adding the above to the schema: this file never read aws.region at all,
# despite hardcoding us-east-1 directly in the actual CodeArtifact API call below (not
# just a display link) -- same wrong-region-silently class of bug as Batch A, in scope
# of this same audit, fixed here rather than filed separately.
AWS_REGION="$(hr_config_required '.aws.region')" || exit 1

[ -f "$REPOLIST" ] || { echo "repo list file not found: $REPOLIST" >&2; exit 1; }

declare -A latest_cache

latest_version() {
  local pkg_lc="$1"
  if [ -n "${latest_cache[$pkg_lc]+x}" ]; then
    printf '%s' "${latest_cache[$pkg_lc]}"
    return
  fi
  local v
  v="$(aws codeartifact list-package-versions --domain "$DOMAIN" --repository "$CA_REPO" \
        --format nuget --package "$pkg_lc" --region "$AWS_REGION" \
        --query 'versions[].version' --output text 2>/dev/null \
        | tr '\t' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)"
  latest_cache[$pkg_lc]="$v"
  printf '%s' "$v"
}

while IFS= read -r repo; do
  [ -z "${repo:-}" ] && continue
  case "$repo" in \#*) continue ;; esac
  dir="${BASE}/${repo}"
  [ -d "$dir" ] || continue

  while IFS='|' read -r pkg ver; do
    [ -z "${pkg:-}" ] && continue
    pkg_lc="$(printf '%s' "$pkg" | tr '[:upper:]' '[:lower:]')"
    latest="$(latest_version "$pkg_lc")"
    [ -z "$latest" ] && continue
    if [ "$ver" != "$latest" ]; then
      top="$(printf '%s\n%s\n' "$ver" "$latest" | sort -V | tail -1)"
      [ "$top" = "$latest" ] && echo -e "${repo}\t${pkg}\t${ver}\t${latest}"
    fi
  done < <(grep -rhoIE 'PackageReference Include="YourProduct\.Exporter[^"]*" Version="[^"]*"' \
              "${dir}" --include=*.csproj --exclude-dir=.git --exclude-dir=node_modules \
              --exclude-dir=bin --exclude-dir=obj 2>/dev/null \
            | sed -E 's/PackageReference Include="([^"]*)" Version="([^"]*)"/\1|\2/' | sort -u)
done < "$REPOLIST"
