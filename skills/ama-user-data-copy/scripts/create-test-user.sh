#!/usr/bin/env bash
# create-test-user.sh -- add a second harness test user to a NON-production env, through the app.
# Usage: create-test-user.sh <qa|staging> <new-username> <template-username>
#   template-username = an existing test user (claude_<env>_3500) whose tier/roles/org/email are
#   copied, and whose token (needs UserManagement) performs the create.
# Goes through manage's POST /users so Cognito user, groups and organization_users row are all
# written by the app, then sets the shared test password as PERMANENT (manage's own password
# endpoint only sets a TEMPORARY one, which leaves the user in FORCE_CHANGE_PASSWORD and makes
# USER_PASSWORD_AUTH answer with a challenge instead of a token). Records the username under
# .users.<env>.tier3500b in ~/.claude/.ama-ui-credentials.json. Refuses production.
set -uo pipefail
# this box's jq emits CRLF: every jq -r value goes through jr() so no trailing \r leaks into ids, paths or JSON
jr() { jq -r "$@" | tr -d '\r'; }
HERE="${BASH_SOURCE[0]%/*}"

ENV="${1:?usage: create-test-user.sh <qa|staging> <new-username> <template-username>}"
NEW="${2:?usage: create-test-user.sh <qa|staging> <new-username> <template-username>}"
TPL="${3:?usage: create-test-user.sh <qa|staging> <new-username> <template-username>}"
case "$ENV" in
  qa)      POOL=us-east-1_EZPzT4PvW ;;
  staging) POOL=us-east-1_mAGKqTZ5f ;;
  production)
    # A production test user is a deliberate step (the prod rehearsal copies a real user's data
    # onto it); require the explicit opt-in so a typo cannot land here.
    [ "${ALLOW_PROD_TEST_USER:-}" = "1" ] || { echo "create-test-user.sh: production needs ALLOW_PROD_TEST_USER=1" >&2; exit 1; }
    POOL=us-east-1_lTBs66UDQ ;;
  *) echo "create-test-user.sh: bad env $ENV" >&2; exit 1 ;;
esac
[[ "$NEW" =~ ^claude_[a-z]+_[0-9]+[a-z]?$ ]] || { echo "new username must look like claude_<env>_<tier>[b]" >&2; exit 1; }

CREDS="$HOME/.claude/.ama-ui-credentials.json"
PW_VAR="$(jr '.passwordEnvVar // "claude_ama_pw"' "$CREDS")"
[ -n "${!PW_VAR:-}" ] || { echo "password env var $PW_VAR not set" >&2; exit 1; }

umask 077
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
bash "$HERE/cognito-token.sh" "$ENV" "$TPL" "$TMP/tok.json" || exit 1

tpl_json="$(bash "$HERE/api.sh" "$ENV" "$TMP/tok.json" GET "/manage/users/username/$TPL" 2>/dev/null)" || { echo "could not read template user $TPL" >&2; exit 1; }

# manage is System.Text.Json: enums are INTS both ways (a name answers 400 "could not be
# converted to ...Tier"). Tier 0 Admin, 1 Tier3500, 2 Tier1800; Role 0 UserManagement,
# 1 TrialUser, 2 YbUser, 3 McfHeaderCohortReport, 4 MonthlyDownloads, 5 RequestedDownloads,
# 6 PoolLoanView (PROJ-15475, manage >= 2.0.0.68), then None.
jq -n --arg u "$NEW" --arg pw "${!PW_VAR}" --argjson t "$tpl_json" '
  { Username: $u, Email: $t.email, Tier: $t.tier, Roles: $t.roles,
    Organisation: $t.organisation, TrialEndDate: null, Password: $pw }' > "$TMP/add-user.json"

echo "creating $NEW on $ENV from template $TPL (tier $(jr .Tier "$TMP/add-user.json"), roles $(jq -c .Roles "$TMP/add-user.json"), org $(jr .Organisation.name "$TMP/add-user.json"))" >&2
resp="$(bash "$HERE/api.sh" "$ENV" "$TMP/tok.json" POST /manage/users "$TMP/add-user.json" 2>"$TMP/status")"; rc=$?
cat "$TMP/status" >&2
if [ $rc -ne 0 ]; then echo "create failed: $resp" >&2; exit 1; fi

# Permanent password, parameters through a file so the value is never on a command line.
jq -n --arg p "$POOL" --arg u "$NEW" --arg pw "${!PW_VAR}" '{UserPoolId:$p, Username:$u, Password:$pw, Permanent:true}' > "$TMP/setpw.json"
aws cognito-idp admin-set-user-password --region us-east-1 --cli-input-json "file://$(cygpath -w "$TMP/setpw.json" | tr '\\' '/')" || { echo "admin-set-user-password failed" >&2; exit 1; }

echo "--- verify" >&2
aws cognito-idp admin-get-user --user-pool-id "$POOL" --username "$NEW" --region us-east-1 \
  --query '{status:UserStatus,enabled:Enabled,sub:UserAttributes[?Name==`sub`].Value|[0]}' --output json >&2
aws cognito-idp admin-list-groups-for-user --user-pool-id "$POOL" --username "$NEW" --region us-east-1 --query 'Groups[].GroupName' --output text >&2
bash "$HERE/api.sh" "$ENV" "$TMP/tok.json" GET "/manage/users/username/$NEW" 2>/dev/null | jq -c '{username, tier, roles, org: .organisation.name, status: .accountStatus}' >&2

# Record it next to the six standing users (key tier3500b) so other scripts can find it.
jq --arg e "$ENV" --arg u "$NEW" '.users[$e].tier3500b = $u' "$CREDS" > "$TMP/creds.json" && cat "$TMP/creds.json" > "$CREDS"
echo "recorded as .users.$ENV.tier3500b in $CREDS" >&2
