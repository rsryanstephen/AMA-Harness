#!/usr/bin/env bash
# PostToolUse hook (Bash/PowerShell). Sibling of octopus-prod-deploy-ticket-sweep-reminder.sh,
# same shape, but nudges the *Staging* cache-update gate documented in ama-hotfix (own
# heading, "Cache update gate") and ama-deploy-release Step 0d, instead of the ticket sweep.
#
# Why this exists. Confirmed live 2026-08-25: hotfix/129.0.9-.11 (GNM WAM/WALA basis fix,
# touching report fields AND SqlTemplates) shipped through Staging with ZERO Staging
# cache-update executions run at all -- the requirement existed as prose (a buried last
# paragraph of ama-hotfix Step 2) but nothing enforced it, so self-recognition alone missed
# it end to end. Same class of gap octopus-prod-deploy-ticket-sweep-reminder.sh already
# fixed for the ticket sweep -- see that hook's own header for the precedent.
#
# Two triggers, because Staging is reached two different ways in this fleet:
#   A) a release's Staging deploy via an explicit Octopus `POST .../deployments` call
#      (ama-deploy-release's flow) -- same EnvironmentId-match shape as the prod hook.
#   B) a `git push` on a `hotfix/*` branch -- hotfixes auto-deploy to Staging via the
#      Hotfix channel's lifecycle, there is no explicit deployments POST to catch
#      (ama-hotfix SKILL.md: "The push auto-deploys to Staging ... no manual promotion").
#
# Deliberately does NOT try to hard-classify "significant" itself -- per explicit user
# instruction (2026-08-25), this must fire only for changes that actually touch report
# fields or SqlTemplates, not every push. For trigger B this hook CAN check the real diff
# (the push already landed by PostToolUse time, so `origin/<branch>@{1}` is available via
# reflog -- same idiom ama-search-shared-version-sync's Step 0 uses for Search.Shared);
# for trigger A there is no local diff to inspect from a bare curl command, so that path
# stays a decision-nudge, same as the prod hook's own limitation.
set -u

IFS= read -r -d '' payload || true

# Raw-payload needle before any jq fork, and the source dispatch.sh's extractor reads.
# Covers BOTH triggers or it would silently disarm one: `*deployments*|*octo-deploy*` is
# trigger A's own test below, `*hotfix/*` is what trigger B greps out of the push args.
# Without this the gate was @ALWAYS and forked on every shell command (626ms measured).
case "$payload" in
  *deployments*|*octo-deploy*|*hotfix/*|*release/*|*develop*) : ;;
  *) exit 0 ;;
esac

command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"
cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty')"
[ -n "$command" ] || exit 0

CONFIG="$HOME/.claude/harness-config.json"
staging_env="<staging>"
[ -f "$CONFIG" ] && staging_env="$(jq -r '.octopus.environmentIds.staging // "<staging>"' "$CONFIG" 2>/dev/null | sed 's/\r$//')"
[ -n "$staging_env" ] || staging_env="<staging>"

# Paths whose presence in a diff means "touched report fields, SqlTemplates or the SQL builders"
# live in lib-sql-emitting-paths.sh (history there), shared with release-preflight.sh's EXPLAIN
# shape sweep. Verification must never dodge a stale Redis result by sorting or editing
# criteria, and a tester or client must never have to (user rules 2026-09-27, 2026-10-05).
. "$HOME/.claude/hooks/lib-sql-emitting-paths.sh" 2>/dev/null || exit 0
PATTERN="$SQL_EMITTING_PATHS"

# --- Trigger A: explicit Octopus deploy POST to Staging ---
# Detection is lib-octopus-deploy-detect.sh's. This was the FOURTH private copy of the
# `.*`-joined regex found on 2026-09-15 (grep -P cannot span a newline, so a multi-line curl
# matched nothing); the other three were fixed that morning and this one was missed.
. "$HOME/.claude/hooks/lib-octopus-deploy-detect.sh" 2>/dev/null || exit 0
case "$command" in *deployments*|*octo-deploy*) is_deploy_post=1 ;; *) is_deploy_post=0 ;; esac
if [ "$is_deploy_post" = 1 ] && octo_is_deploy_post "$(octo_scan_region "$command")"; then
  normalized="$(octo_scan_region "$command" | sed 's/\\"/"/g')"
  if printf '%s' "$normalized" | grep -qF "\"EnvironmentId\":\"$staging_env\"" || \
     printf '%s' "$normalized" | grep -qF "\"EnvironmentId\": \"$staging_env\""; then
    jq -cn '{decision:"block", reason:"Staging deployment just triggered via Octopus. Did this release touch report fields, SqlTemplates or Search.Shared SQL builders (ama-hotfix/ama-deploy-release Step 0d'"'"'s trigger condition)? If so, run a `main` cache update against Staging (ama-graylog-search'"'"'s CACHE-UPDATE-DEBUGGING.md, <env>=staging) BEFORE trusting any Staging verification -- but only after every touched ECS service reads rolloutState: COMPLETED, or the update fails States.Timeout the same way the 2026-08-25 production incident did. If it did not touch either, no cache update is needed -- this is a decision to make, not an unconditional action."}'
    exit 0
  fi
  exit 0
fi

# --- Trigger B: git push on an auto-deploying branch ---
# hotfix/* and release/* auto-deploy to Staging, develop to QA. The rule is environment-blind
# (user instruction 2026-10-05): a change that alters the SQL a report emits, or the values it
# returns, ships with its cache invalidation wherever it is deployed -- QA included.
printf '%s' "$command" | grep -qP '(?:^|[;&|]|&&)\s*git\s+(?:-C\s+(?:"[^"]+"|\S+)\s+)?push\b' || exit 0
push_args="$(printf '%s' "$command" | grep -oP '(?:^|[;&|]|&&)\s*git\s+(?:-C\s+(?:"[^"]+"|\S+)\s+)?push\b\K.*' | head -1)"
# A branch DELETION deploys nothing (same guard as library-version-sync-reminder.sh) -- this
# fired on the hotfix/130.0.3 cleanup, PROJ-15801 2026-10-15.
[[ "$push_args" =~ (^|[[:space:]])(--delete|-d)([[:space:]]|$)|[[:space:]]:[^[:space:]] ]] && exit 0
branch="$(printf '%s' "$push_args" | grep -oP '(?:hotfix|release)/\S+|(?<![\w/])develop\b' | head -1)"
[ -n "$branch" ] || exit 0
# A push of HEAD:develop names the remote branch after the colon; the reflog ref is still origin/develop.
branch="${branch#*:}"
case "$branch" in develop) target_env="QA" ;; *) target_env="Staging" ;; esac

# Resolve the repo root: prefer an explicit `-C <path>`, else fall back to the hook's cwd.
. "$HOME/.claude/hooks/lib-git-target.sh" 2>/dev/null || exit 0
git_push_rejected "$payload" && exit 0
repo="$(git_target_dir "$command" "$cwd")"
[ -n "$repo" ] && [ -d "$repo" ] || exit 0

matched=""
# --verify -q: a bare rev-parse echoes an UNKNOWN ref name back on stdout, so both of these read as
# "present" in a clone with no reflog and the could-not-diff nudge below never fired (2026-10-05).
old_sha="$(git -C "$repo" rev-parse --verify -q "origin/$branch@{1}" 2>/dev/null || true)"
new_sha="$(git -C "$repo" rev-parse --verify -q "origin/$branch" 2>/dev/null || true)"
if [ -n "$old_sha" ] && [ -n "$new_sha" ] && [ "$old_sha" != "$new_sha" ]; then
  matched="$(sql_emitting_diff "$repo" "$old_sha" "$new_sha")"
fi

if [ -n "$matched" ]; then
  jq -cn --arg branch "$branch" --arg files "$matched" --arg env "$target_env" \
    '{decision:"block", reason:("Pushed " + $branch + " -- diff touches report-field/SqlTemplate/SQL-builder paths (matched:" + ($files | gsub("\n"; ", ")) + "). This auto-deploys to " + $env + " with no explicit deploy call to catch. A change that alters the SQL a report emits, or the values it returns, ships with its cache invalidation in EVERY environment it reaches (user rule 2026-10-05): run a `main` cache update against " + $env + " (ama-graylog-search'"'"'s CACHE-UPDATE-DEBUGGING.md, <env>=" + ($env | ascii_downcase) + ") BEFORE any verification there -- but only after the ECS rollout reads COMPLETED, or it fails States.Timeout the same way the 2026-08-25 production incident did. Then EXPLAIN every query SHAPE the new build emitted there (the cache update crawls them): `bash ~/.claude/skills/ama-postgres-access/scripts/rs-explain-shapes.sh graylog:<application>:" + ($env | ascii_downcase) + " --build <running 2.0.0.N> --inventory-hours 336` -- FAIL = the planner rejects SQL this change emits in some consumer shape; MISSING = a shape nobody ran yet. A change at a shared builder is a change to every shape that wraps it: ama-debugging-notes/SHARED-CHOKEPOINT-CHANGES.md (PROJ-15416 shipped five follow-up defects in shapes nobody ran).")}'
elif [ -z "$old_sha" ] || [ -z "$new_sha" ]; then
  # Reflog unavailable (fresh clone, or this session didn't push it) -- can't diff, so
  # fall back to the same decision-nudge shape as Trigger A rather than staying silent.
  jq -cn --arg branch "$branch" --arg env "$target_env" \
    '{decision:"block", reason:("Pushed " + $branch + " -- could not diff it (no reflog for origin/" + $branch + "@{1}). Did this push touch report fields, SqlTemplates or Search.Shared SQL builders, or otherwise change the SQL a report emits or the values it returns? If so, run a `main` cache update against " + $env + " (ama-graylog-search'"'"'s CACHE-UPDATE-DEBUGGING.md, <env>=" + ($env | ascii_downcase) + ") before verifying there, once its ECS rollout reads COMPLETED -- the rule holds in every environment, QA included.")}'
fi
exit 0
