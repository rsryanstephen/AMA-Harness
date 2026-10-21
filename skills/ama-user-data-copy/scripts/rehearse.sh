#!/usr/bin/env bash
# rehearse.sh -- the full non-production rehearsal, end to end, on one env:
#   seed fixture (if none) -> copy -> verify (DB) -> verify-as-target (API) -> ui-check (browser)
#   -> rollback -> prove clean -> copy again -> verify -> verify-as-target
# Usage: rehearse.sh <qa|staging> <samples-dir> [--keep]
#   source  = .users.<env>.tier3500, target = .users.<env>.tier3500b (create-test-user.sh),
#   temp    = .users.<env>.tier1800 (its UserManagement satisfies Roles.DynamicCohorts)
#   --keep  = leave the second copy in place (default: roll it back too, so the env is clean)
# Needs AMA_ALLOW_PG_WRITE=1 + AMA_ALLOW_MONGO_WRITE=1 in Claude Code's own environment and the
# claude_ama_pw password var. Expect ~10 min per cohort of generation time on QA per copy pass.
set -uo pipefail
# this box's jq emits CRLF: every jq -r value goes through jr() so no trailing \r leaks into ids, paths or JSON
jr() { jq -r "$@" | tr -d '\r'; }
HERE="${BASH_SOURCE[0]%/*}"
ENV="${1:?usage: rehearse.sh <qa|staging> <samples-dir> [--keep]}"; SAMPLES="${2:?}"; KEEP="${3:-}"
case "$ENV" in qa|staging) ;; *) echo "rehearse.sh: qa/staging only" >&2; exit 1 ;; esac
case "$ENV" in qa) POOL=us-east-1_EZPzT4PvW ;; staging) POOL=us-east-1_mAGKqTZ5f ;; esac
CREDS="$HOME/.claude/.ama-ui-credentials.json"
SRC="$(jr --arg e "$ENV" '.users[$e].tier3500' "$CREDS")"; TGT="$(jr --arg e "$ENV" '.users[$e].tier3500b // empty' "$CREDS")"; TMPU="$(jr --arg e "$ENV" '.users[$e].tier1800' "$CREDS")"
[ -n "$TGT" ] || { echo "rehearse.sh: no tier3500b user for $ENV -- run create-test-user.sh $ENV claude_${ENV/staging/st}_3500b $SRC first" >&2; exit 1; }
sub() { aws cognito-idp admin-get-user --user-pool-id "$POOL" --username "$1" --region us-east-1 --query 'UserAttributes[?Name==`sub`].Value' --output text | tr -d '\r'; }
SRC_SUB="$(sub "$SRC")"; TGT_SUB="$(sub "$TGT")"
STATE="${CLAUDE_STATE_DIR:-$HOME/.claude/harness-state}"; DIR="$STATE/logs/user-data-copy"; mkdir -p "$DIR"
FIX="$DIR/fixture-$ENV-$SRC.json"; MAN="$DIR/copy-$ENV-$SRC-$TGT.json"
step() { echo; echo "######## $1" >&2; shift; "$@" || { echo "rehearse.sh: FAILED at: $*" >&2; exit 1; }; }

[ -s "$FIX" ] || step "seed fixture under $SRC" bash "$HERE/seed-fixture.sh" "$ENV" "$SAMPLES" "$FIX"
[ -f "$MAN" ] && { echo "rehearse.sh: $MAN exists -- roll it back or remove it before a fresh rehearsal" >&2; exit 1; }
step "copy #1 $SRC -> $TGT"     bash "$HERE/run.sh" "$ENV" "$SRC" "$SRC_SUB" "$TGT" "$TGT_SUB" --temp-user "$TMPU"
step "verify-as-target #1"      bash "$HERE/verify-as-target.sh" "$MAN"
step "ui-check target #1"       bash "$HERE/run-ui-check.sh" "$MAN" target
step "ui-check source #1"       bash "$HERE/run-ui-check.sh" "$MAN" source
step "rollback #1"              bash "$HERE/rollback.sh" "$MAN"
step "target clean after rollback" bash -c '
  n=$(bash "$1/inventory.sh" "$2" "$3" "$4" 2>/dev/null | grep -E "^(reports owned|bands owned|cohorts owned|cohort reports owned)" | awk "{s+=\$NF} END{print s+0}")
  echo "target owns $n items after rollback"; [ "$n" = 0 ]' _ "$HERE" "$ENV" "$TGT" "$TGT_SUB"
step "source fingerprint intact" bash -c '
  h=$(bash "$1/source-hash.sh" "$2" "$3" "$4" 2>/dev/null); h0=$(jq -r .sourceHash "$5"); echo "$h0 -> $h"; [ "$h" = "$h0" ]' _ "$HERE" "$ENV" "$SRC" "$SRC_SUB" "$MAN"
mv "$MAN" "${MAN%.json}.rehearsal1.json"
step "copy #2 $SRC -> $TGT"     bash "$HERE/run.sh" "$ENV" "$SRC" "$SRC_SUB" "$TGT" "$TGT_SUB" --temp-user "$TMPU"
step "verify-as-target #2"      bash "$HERE/verify-as-target.sh" "$MAN"
if [ "$KEEP" != "--keep" ]; then
  step "rollback #2" bash "$HERE/rollback.sh" "$MAN"
  mv "$MAN" "${MAN%.json}.rehearsal2.json"
fi
echo; echo "rehearse.sh: $ENV rehearsal complete${KEEP:+ (copy #2 kept)}" >&2
