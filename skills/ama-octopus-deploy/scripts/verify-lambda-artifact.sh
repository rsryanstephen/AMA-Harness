#!/usr/bin/env bash
# Did an Octopus Lambda deploy actually ship new code?
# Usage: verify-lambda-artifact.sh <function-suffix>   e.g. cacheupdate-updatecachestate-lambda
#        verify-lambda-artifact.sh <full-function-name>  (a name already carrying <env>-v1-)
#
# WHY NOT THE DLL DATES. ama-octopus-deploy/SKILL.md's "Deploying a Lambda" section says to
# verify the ARTIFACT, and used to say: pull Code.Location and check the DLL dates are
# today's build. That instrument does NOT discriminate for the cacheupdate Lambdas --
# deterministic builds stamp every sibling with the same old date. Confirmed 2026-09-15:
# a just-redeployed staging-v1-cacheupdate-updatecachestate-lambda read 2026-08-17 18:58,
# and so did BOTH siblings that had deployed cleanly hours earlier (18:55 / 19:00), while
# QA's read 2026-07-24. Reading that as "stale code" nearly reverted a good deploy.
#
# CodeSha256 across environments is what actually separates a new artifact from a stale
# one: three distinct hashes = three distinct builds; staging identical to production =
# genuinely stale, which is the PROJ-15297 failure the skill's warning is about.
set -uo pipefail
export MSYS_NO_PATHCONV=1

ARG="${1:?usage: verify-lambda-artifact.sh <function-suffix|full-function-name>}"

case "$ARG" in
  staging-*|qa-*|production-*) SUFFIX="${ARG#*-v1-}" ;;
  *) SUFFIX="$ARG" ;;
esac

printf '%-12s %-46s %-12s %s\n' ENV SHA256 SIZE MODIFIED
STAGING_SHA=""; PROD_SHA=""; MISSING=0
for ENVNAME in staging qa production; do
  FN="${ENVNAME}-v1-${SUFFIX}"
  J="$(PYTHONUTF8=1 aws lambda get-function --function-name "$FN" 2>/dev/null)"
  if [ -z "$J" ]; then
    printf '%-12s %s\n' "$ENVNAME" "NOT FOUND ($FN)"
    MISSING=$((MISSING+1))
    continue
  fi
  SHA="$(printf '%s' "$J" | jq -r '.Configuration.CodeSha256')"
  printf '%-12s %-46s %-12s %s\n' "$ENVNAME" "$SHA" \
    "$(printf '%s' "$J" | jq -r '.Configuration.CodeSize')" \
    "$(printf '%s' "$J" | jq -r '.Configuration.LastModified')"
  [ "$ENVNAME" = "staging" ] && STAGING_SHA="$SHA"
  [ "$ENVNAME" = "production" ] && PROD_SHA="$SHA"
done

echo
if [ -z "$STAGING_SHA" ] || [ -z "$PROD_SHA" ]; then
  echo "INCONCLUSIVE: need both staging and production to compare ($MISSING function(s) not found)."
  exit 2
fi
if [ "$STAGING_SHA" = "$PROD_SHA" ]; then
  echo "STALE: staging CodeSha256 is IDENTICAL to production -- the deploy did not ship new"
  echo "code, whatever Octopus and LastModified say. Delete the function and redeploy:"
  echo "  aws lambda delete-function --function-name staging-v1-${SUFFIX}"
  exit 1
fi
echo "OK: staging and production carry different artifacts -- the deploy shipped new code."
