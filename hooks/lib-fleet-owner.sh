#!/usr/bin/env bash
# Fleet ownership (user rule 2026-10-28, memory/fleet-owner-approval.md): every fleet -- the
# `fleet` tag on .harness-local.json reposRoots (app, etl) -- has an owner in harness-config.json
# .fleetOwners.<fleet> = {name, bitbucketUuid}. A change to a repo in a fleet the user does NOT
# own lands only through a pull request that owner approves. The user is recognised by
# .bitbucket.selfUuid. No .fleetOwners block -> no owners, every consumer passes.
#
# Consumers: fleet-owner-push-gate.sh (protected-branch push), create-bitbucket-pr.sh (owner
# added as reviewer), pr-merge-watch.sh (merges only on the owner's own approval).
# Sourceable; pulls in lib-harness-repos.sh for hr_config/hr_index/hr_repo_slug.
# Test seam: FLEET_OWNER_FLEETS="etl app" replaces the fleet lookup (HR_ROOTS_OVERRIDE's
# discovery leaves fleet empty, so fixtures cannot express a fleet any other way).

declare -F hr_config >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/lib-harness-repos.sh"

# fleet_owners_required <repo-dir | slug> -> "<fleet>\t<name>\t<bitbucket-uuid>" per owner whose
# approval a change there needs, de-duplicated by uuid; nothing when the user owns every fleet
# the repo is in. A slug cloned under two roots (yourproduct-backbone sits under both) answers
# for BOTH fleets: the stricter owner set wins. The harness repo is nobody's fleet.
fleet_owners_required() {
  local target="${1:-}" slug="" top="" fleets="" owners self
  [ -n "$target" ] && [ -f "$HR_CONFIG_FILE" ] || return 0
  owners="$(_jqr -c '.fleetOwners // {}' < "$HR_CONFIG_FILE")"
  [ -n "$owners" ] && [ "$owners" != "{}" ] || return 0
  self="$(hr_config '.bitbucket.selfUuid' '')"

  if [ -d "$target" ]; then
    top="$(git -C "$target" rev-parse --show-toplevel 2>/dev/null)" || return 0
    slug="$(hr_repo_slug "$top" 2>/dev/null)"
  else
    slug="$target"
  fi
  case "$slug" in ama-claude-harness*|"") return 0 ;; esac

  if [ -n "${FLEET_OWNER_FLEETS:-}" ]; then
    fleets="$FLEET_OWNER_FLEETS"
  else
    fleets="$(hr_index 2>/dev/null | awk -F'\t' -v s="$slug" '$1 == s && $4 != "" { print $4 }')"
    # Not indexed yet (fresh clone, worktree of an unindexed repo): the root its path sits under.
    if [ -z "$fleets" ] && [ -n "$top" ]; then
      local t p f
      t="$(cygpath -m "$top" 2>/dev/null || printf '%s' "$top")"
      while IFS=$'\t' read -r p f; do
        [ -n "${p:-}" ] && [ -n "${f:-}" ] || continue
        p="$(cygpath -m "$(hr_expand "$p")" 2>/dev/null || hr_expand "$p")"
        case "${t,,}/" in "${p,,}"/*) fleets="$fleets $f" ;; esac
      done <<< "$(_hr_root_pairs)"
    fi
  fi
  [ -n "$fleets" ] || return 0

  # shellcheck disable=SC2086
  printf '%s\n' $fleets | awk '!seen[$0]++' | while IFS= read -r f; do
    printf '%s' "$owners" | _jqr --arg f "$f" '.[$f] // empty | [$f, (.name // ""), (.bitbucketUuid // "")] | @tsv'
  done | awk -F'\t' -v self="$self" '$3 != "" && $3 != self && !seen[$3]++'
}
