#!/usr/bin/env bash
# List NuGet package names a repo publishes: every non-test, non-exe csproj IN A REPO
# THAT ACTUALLY PUBLISHES SOMETHING. Prints: <package-name>\t<csproj-path>\t<version-prefix-or-version>
set -euo pipefail

repo_path="${1:?usage: list-published-packages.sh <repo-path>}"

# A repo is only a "library" if its pipeline actually publishes a NuGet -- having a
# VersionPrefix in a csproj is NOT sufficient (confirmed real bug, PROJ-15112:
# 13+ app/service repos across the fleet were false-flagged as libraries this way,
# wasting cascade time hunting for consumers of packages never actually published).
# Real signal: a dotnet pack/nuget push step, or the shared package.sh/
# package_develop_branch.sh script (the convention most repos actually use).
pipeline_yml="${repo_path}/bitbucket-pipelines.yml"
if [ -f "${pipeline_yml}" ]; then
  if ! grep -qE "dotnet (pack|nuget push)|package\.sh|package_develop_branch\.sh" "${pipeline_yml}"; then
    exit 0
  fi
else
  # No pipeline at all -> can't publish anything.
  exit 0
fi

find "${repo_path}" -iname "*.csproj" \
  -not -path "*/bin/*" -not -path "*/obj/*" \
  -not -iname "*.Tests.csproj" -not -iname "*.Test.csproj" | while IFS= read -r csproj; do
    # skip exe/console/web apps - not packed as libraries
    if grep -qP "<OutputType>\s*Exe\s*</OutputType>" "${csproj}" 2>/dev/null; then
      continue
    fi

    package_id=$(grep -oP "<PackageId>\K[^<]+" "${csproj}" 2>/dev/null | head -1) || true
    if [ -z "${package_id}" ]; then
      package_id=$(basename "${csproj}" .csproj)
    fi

    version=$(grep -oP "<VersionPrefix>\K[^<]+" "${csproj}" 2>/dev/null | head -1) || true
    if [ -z "${version}" ]; then
      version=$(grep -oP "<Version>\K[^<]+" "${csproj}" 2>/dev/null | head -1) || true
    fi

    printf '%s\t%s\t%s\n' "${package_id}" "${csproj}" "${version}"
done
