#!/usr/bin/env bash
# PostToolUse hook (Bash/PowerShell). Nudges Claude to run a library
# version-sync skill right after a git push that actually published a changed
# library -- PROJ-15259 fixed YourCompany.Product.Search.Shared and pushed
# to search's develop, but nothing prompted ama-search-shared-version-sync
# until the user asked. Same gap as git-push-ticket-reminder.sh existed for
# ticket status before that hook was added -- this is the same pattern applied
# to library-version-sync. No de-dupe: fires on every matching push, same
# philosophy as that sibling hook.
set -u

IFS= read -r -d '' payload || true
# Cheap raw-payload pre-filter before any jq fork (precedent:
# aggregation-secret-gate.sh) -- the push-matching regex below requires the literal
# substring "push", so a payload without it can exit on zero forks. ~60ms/fork.
case "$payload" in *push*) ;; *) exit 0 ;; esac
command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"
cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty')"

[ -n "$command" ] || exit 0

printf '%s' "$command" | grep -qP '(^|[;&|]|&&)\s*git\s+(-C\s+\S+\s+)?push\b' || exit 0
# A branch DELETION ships no code -- same guard as git-push-ticket-reminder.sh (this hook
# misfired on the hotfix/129.0.17 cleanup, claiming a published package's code changed).
printf '%s' "$command" | grep -qE '(^|[[:space:]])--delete([[:space:]]|$)' && exit 0
printf '%s' "$command" | grep -qE 'push[^;&|]*[[:space:]]:[^[:space:];&|]+' && exit 0

. "$HOME/.claude/hooks/lib-git-target.sh" 2>/dev/null || exit 0
git_push_rejected "$payload" && exit 0
target_dir="$(git_target_dir "$command" "$cwd")"
[ -n "$target_dir" ] || exit 0

branch="$(git -C "$target_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)"
# Destination branch from an explicit refspec wins over HEAD: a detached worktree pushing
# `HEAD:master` reads HEAD as "HEAD" and matched nothing (PROJ-15801, 2026-10-15).
if [[ "$command" =~ git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?push[[:space:]]+(-[^[:space:]]+[[:space:]]+)*[^-[:space:]][^[:space:]]*[[:space:]]+\+?([^[:space:];&|]+) ]]; then
  ref="${BASH_REMATCH[3]}"; ref="${ref##*:}"; ref="${ref#refs/heads/}"
  [ -n "$ref" ] && [ "$ref" != HEAD ] && branch="$ref"
fi
[ -n "$branch" ] || exit 0

slug="$(bash "$HOME/.claude/hooks/lib-harness-repos.sh" slug "$target_dir" 2>/dev/null)"
# Unknown to the fleet map -> name it by directory; the release/hotfix publish check below
# keys on the repo's own bitbucket-pipelines.yml, not on the map.
[ -n "$slug" ] || slug="$(basename "$target_dir")"

reason=""

if [ "$slug" = "product-service-search" ] && [ "$branch" = "develop" ]; then
  old="$(git -C "$target_dir" rev-parse 'refs/remotes/origin/develop@{1}' 2>/dev/null)"
  new="$(git -C "$target_dir" rev-parse origin/develop 2>/dev/null)"
  if [ -n "$old" ] && [ -n "$new" ]; then
    changed="$(git -C "$target_dir" diff --name-only "$old..$new" -- \
      YourCompany.Product.Search.Shared/ YourCompany.Product.Search.Cache/ 2>/dev/null)"
    if [ -n "$changed" ]; then
      reason="Just pushed ${old}..${new} to develop on product-service-search, and Search.Shared/Search.Cache changed -- invoke the ama-search-shared-version-sync skill now, don't wait to be asked. Start at its step 0/0b: if consumers do not NEED the change (dead code, comments, internal-only refactor), stop there -- no bump, no sync."
    fi
  fi
elif [ "$slug" = "product-service-search" ] && case "$branch" in hotfix/*|release/*) true ;; *) false ;; esac \
     && [ -n "$(git -C "$target_dir" diff --name-only "origin/master...origin/${branch}" -- YourCompany.Product.Search.Shared/ YourCompany.Product.Search.Cache/ 2>/dev/null)" ]; then
  # PROJ-15801: the search-api deploy fixed the grid, but resultsprocessor (exports)
  # pins Search.Shared as a NuGet package and kept failing in Production until its own hotfix.
  reason="Just pushed ${branch} on product-service-search and Search.Shared/Search.Cache changed. Deploying search-api does NOT fix the other services that pin these as NuGet packages (resultsprocessor = exports, and any other consumer): each needs its OWN ${branch%%/*} bumping its pin to this build's package, which publishes as <prefix>.<build>-${branch//\//-} (suffixed, not clean). Run ama-search-shared-version-sync for the master-line consumers (step 0b first), read the exact version from CodeArtifact after the pipeline is green, and ship those consumers in the same hotfix."
elif case "$branch" in release/*|hotfix/*) true ;; *) false ;; esac \
     && grep -qsF 'package.sh' "$target_dir/bitbucket-pipelines.yml"; then
  # A `package.sh` repo appends the branch name as a pre-release suffix on non-master
  # branches, and slashed branches FAILED to publish at all for two months with nobody
  # noticing (release/128.0.0 never published a Shared package -- PROJ-15418,
  # 2026-09-17). A push here is not a package until the pipeline says so.
  reason="Just pushed to ${branch} on ${slug}, which publishes via package.sh. A push is NOT a published package: on a non-master branch the image appends the branch as a pre-release suffix and slashed branches have silently failed to publish before. Confirm with \`bash ~/.claude/skills/ama-bitbucket-api/scripts/pipeline-status.sh ${slug} <build>\` that the pipeline went green and read the published version out of its step log before syncing any consumer (ama-library-version-sync step 4)."
elif [ "$branch" = "master" ] && [ "$slug" != "product-service-search" ]; then
  pkgs="$(bash "$HOME/.claude/skills/ama-library-version-sync/scripts/list-published-packages.sh" "$target_dir" 2>/dev/null \
    | awk -F'\t' 'NF >= 3 && $3 != ""')"
  if [ -n "$pkgs" ]; then
    old="$(git -C "$target_dir" rev-parse 'refs/remotes/origin/master@{1}' 2>/dev/null)"
    new="$(git -C "$target_dir" rev-parse origin/master 2>/dev/null)"
    if [ -z "$old" ] || [ -z "$new" ]; then
      reason="Just pushed to master on ${slug}, which publishes a NuGet package, but no reflog to confirm whether the published code changed -- check manually and invoke ama-library-version-sync if it did -- starting at its step 0, which stops if consumers do not need the change."
    else
      changed_any=""
      while IFS=$'\t' read -r _pkg csproj _prefix; do
        [ -n "$csproj" ] || continue
        pkg_dir="$(dirname "$csproj")"
        rel="${pkg_dir#"$target_dir"/}"
        c="$(git -C "$target_dir" diff --name-only "$old..$new" -- "$rel/" 2>/dev/null)"
        [ -n "$c" ] && changed_any="yes"
      done <<< "$pkgs"
      if [ -n "$changed_any" ]; then
        reason="Just pushed ${old}..${new} to master on ${slug}, and a published package's code changed -- invoke the ama-library-version-sync skill now, don't wait to be asked. Start at its step 0: if consumers do not NEED the change (dead code, comments, internal-only refactor), stop there -- no bump, no sync."
      fi
    fi
  fi
fi

[ -n "$reason" ] || exit 0

jq -cn --arg r "$reason" '{decision:"block", reason:$r}'
