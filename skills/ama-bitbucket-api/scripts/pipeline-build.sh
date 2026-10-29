#!/usr/bin/env bash
# usage: pipeline-build.sh <repo-or-slug-or-dir> <build-number>
# Resolve a Bitbucket pipeline BUILD NUMBER back to the branch, commit and result that
# produced it. The build number is the tail of every published package version
# (`<VersionPrefix>.<BITBUCKET_BUILD_NUMBER>`, see package_develop_branch.sh), so this is
# how you answer "which branch/commit is package X.Y.Z actually built from" -- the only
# reliable way. Publish date and version string both mislead here: the repo migration reset
# some build counters, and a hotfix-line backport can publish AFTER the mainline build it
# must not replace (Search.Shared 19.1.2.177 vs 19.2.0.173, 2026-09-18).
# Check `result` too -- `dotnet nuget push` runs mid-pipeline, so a package can exist from a
# build that later FAILED (Search.Shared 19.2.0.181).
# Used by: ama-hotfix (.csproj PackageReference conflict rule), ama-search-shared-version-sync.
. "$HOME/.claude/skills/ama-bitbucket-api/scripts/lib-bitbucket.sh"
slug="$(bb_slug "${1:?repo}")"
n="${2:?build number}"
bb_get "$BB_API/$slug/pipelines/$n" | jq -r '
  if .build_number then
    "build=\(.build_number)  state=\(.state.name)/\(.state.result.name // "?")  " +
    "branch=\(.target.ref_name // .target.branch // "?")  " +
    "sha=\(.target.commit.hash // "?" | .[0:8])  created=\(.created_on)"
  else "no such build: \(.error.message // "unknown")" end'
