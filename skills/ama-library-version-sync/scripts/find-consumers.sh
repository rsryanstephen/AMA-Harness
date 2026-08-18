#!/usr/bin/env bash
# Find every csproj under $2 (repos root) with a PackageReference to package $1.
# Prints: <repo-name>\t<csproj-path>\t<current-version>
# Skips any repo listed in excluded-repos.txt (same directory as this script).
set -uo pipefail

package_name="${1:?usage: find-consumers.sh <package-name> <repos-root>}"
repos_root="${2:?usage: find-consumers.sh <package-name> <repos-root>}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exclude_file="${script_dir}/excluded-repos.txt"

matches=$(grep -rlP "PackageReference\s+Include=\"${package_name}\"" \
  --include="*.csproj" \
  --exclude-dir=bin --exclude-dir=obj \
  "${repos_root}" 2>/dev/null) || true

if [ -z "${matches}" ]; then
  exit 0
fi

printf '%s\n' "${matches}" | while IFS= read -r csproj; do
  repo_name=$(printf '%s\n' "${csproj#"${repos_root}"/}" | cut -d/ -f1)

  if [ -f "${exclude_file}" ] && grep -qxF "${repo_name}" <(grep -v '^#' "${exclude_file}" | grep -v '^\s*$'); then
    continue
  fi

  version=$(grep -oP "PackageReference\s+Include=\"${package_name}\"\s+Version=\"\K[^\"]+" "${csproj}" 2>/dev/null | head -1) || true
  printf '%s\t%s\t%s\n' "${repo_name}" "${csproj}" "${version}"
done
