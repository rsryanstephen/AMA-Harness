#!/usr/bin/env bash
# Run a mongosh eval against a cohorts/cohort-reports DocumentDB cluster, tunneled through
# the SSH bastion. See ../SKILL.md for the why -- this is the how.
#
# Usage: docdb-query.sh <qa|staging|production> '<js eval>'
# Output: whatever mongosh --quiet --eval prints (raw, not TSV -- caller parses).
#
# Read-write creds, no DB-level safety net -- SKILL.md says so, this script doesn't
# enforce read-only itself.

set -euo pipefail

env="${1:?usage: docdb-query.sh <qa|staging|production> \"<js eval>\"}"
js="${2:?usage: docdb-query.sh <qa|staging|production> \"<js eval>\"}"

lib="$HOME/.claude/hooks/lib-harness-repos.sh"
# shellcheck source=/dev/null
. "$lib"

region="$(hr_config_required '.aws.region')" || exit 1
bastion_user="$(hr_config '.mongo.bastionUser' 'ubuntu')"
bastion_host="$(hr_config_required ".mongo.bastionHosts.$env")" || exit 1
local_port="$(hr_config '.mongo.localPort' '27018')"

ssh_key="${MONGO_SSH_KEY:-$HOME/.ssh/PROJ_RELEASE.pem}"
ca_cert="${MONGO_CA_CERT:-$HOME/.ssh/global-bundle.pem}"
[ -f "$ssh_key" ] || { echo "docdb-query.sh: SSH key not found at $ssh_key -- set MONGO_SSH_KEY" >&2; exit 1; }
[ -f "$ca_cert" ] || { echo "docdb-query.sh: CA bundle not found at $ca_cert -- set MONGO_CA_CERT (or curl https://truststore.pki.rds.amazonaws.com/global-bundle.pem)" >&2; exit 1; }
: "${MONGO_SSH_KEY_PASSPHRASE:?docdb-query.sh: MONGO_SSH_KEY_PASSPHRASE not set}"
# Windows-form for docker (native exe, same argv-conversion gotcha as $tmp above) --
# ssh itself is MSYS-compiled so it takes the posix $ca_cert/$ssh_key form fine.
ca_cert_win="$(cygpath -w "$ca_cert" | tr '\\' '/')"

# Windows-form path (cygpath -w), not mktemp's raw /tmp/... -- passing a bare posix path
# as an argument to a native (non-MSYS) exe like node.exe or docker.exe gets naively
# rewritten to "<drive>:\tmp\..." (literal /tmp -> C:\tmp, ignoring the real TEMP mapping),
# which doesn't exist -- confirmed ENOENT this way. Windows-form works for both bash's own
# redirection and native-exe args.
tmp="$(cygpath -w "$(mktemp -d)" | tr '\\' '/')"
askpass="$tmp/askpass.sh"
envfile="$tmp/mongoenv"
rawconn="$tmp/rawconn"
tunnel_pid=""

cleanup() {
  [ -n "$tunnel_pid" ] && kill "$tunnel_pid" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT

printf '#!/bin/sh\nprintf %%s "$MONGO_SSH_KEY_PASSPHRASE"\n' > "$askpass"
chmod 700 "$askpass"

# Task-def family: <env>-v1-cohortreports-api. Plaintext env entry -- same mechanism
# ama-postgres-access documents for the per-service Postgres DBs. Never echoed.
aws ecs describe-task-definition --task-definition "${env}-v1-cohortreports-api" --region "$region" \
  --query "taskDefinition.containerDefinitions[0].environment[?name=='MongoSettings__Connections__0__ConnectionString'].value" \
  --output text > "$rawconn"

docdb_host="$(sed -E 's#^mongodb://[^@]*@([^:/]+).*#\1#' "$rawconn")"

# Parse the connection string's actual keys (.NET-driver spellings -- ssl/sslVerifyCertificate/
# ssl_ca_certs/replicaSet -- none of which mongosh takes) into a mode-600 env file. Never
# shell-interpolate the password; mode0600 mirrors ama-postgres-access's pgenv convention.
node -e "
const fs=require('fs');
const c=fs.readFileSync('$rawconn','utf8').trim();
const m=c.match(/^mongodb:\/\/([^:]+):([^@]+)@/);
if(!m){process.stderr.write('docdb-query.sh: could not parse mongodb:// URI\n');process.exit(1);}
fs.writeFileSync('$envfile',
  'MONGO_USER='+decodeURIComponent(m[1])+'\nMONGO_PASS='+decodeURIComponent(m[2])+'\n',
  {mode:0o600});
"
rm -f "$rawconn"

# JS eval goes in base64, never interpolated raw into a shell command -- the caller's
# eval string can contain quotes/backslashes (confirmed: a bare '"cohort"' broke the old
# raw-interpolation approach with a shell quoting mismatch inside docker's sh -c).
js_b64="$(printf '%s' "$js" | base64 -w0)"

# SSH_ASKPASS_REQUIRE=force makes OpenSSH 9.9 invoke the helper instead of an interactive
# tty prompt (which would hang here). No setsid/pgrep on this Windows git-bash -- background
# with plain `&` and keep $! instead of ssh's own -f (which forks internally, losing the pid).
export SSH_ASKPASS="$askpass" SSH_ASKPASS_REQUIRE=force
ssh -N -o StrictHostKeyChecking=accept-new -o ExitOnForwardFailure=yes \
  -L "0.0.0.0:${local_port}:${docdb_host}:27017" \
  -i "$ssh_key" "${bastion_user}@${bastion_host}" < /dev/null &
tunnel_pid=$!
# Active wait, not a fixed sleep -- the 0.0.0.0 bind + remote handshake took anywhere from
# ~1s to ~4s across repeated runs here; a fixed `sleep 2` intermittently lost the race and
# handed docker a not-yet-listening port (confirmed: ECONNREFUSED on a fast rerun).
for _ in $(seq 1 30); do
  (exec 3<>"/dev/tcp/127.0.0.1/${local_port}") 2>/dev/null && exec 3>&- && break
  sleep 0.3
done

# mongo:4.0's legacy shell for wire version 7 (production, engine 4.0.0); mongo:7's
# mongosh for wire >= 8 (qa/staging, engine 5.0.1) -- MongoDB.Driver 3.x's own
# incompatibility with wire 7 (PROJ-15178) applies the same way to client shells.
if [ "$env" = "production" ]; then
  image="mongo:4.0"
  # shellcheck disable=SC2016
  shell='mongo --quiet --host host.docker.internal:'"$local_port"' -u "$MONGO_USER" -p "$MONGO_PASS" --authenticationDatabase admin --ssl --sslAllowInvalidHostnames --sslCAFile /ca/global-bundle.pem --eval "$JS_EVAL"'
else
  image="mongo:7"
  # shellcheck disable=SC2016
  shell='mongosh --quiet --host host.docker.internal:'"$local_port"' -u "$MONGO_USER" -p "$MONGO_PASS" --authenticationDatabase admin --tls --tlsCAFile /ca/global-bundle.pem --tlsAllowInvalidHostnames --eval "$JS_EVAL"'
fi
# shellcheck disable=SC2016
cmd='JS_EVAL="$(printf %s "$JS_EVAL_B64" | base64 -d)"; '"$shell"

docker run --rm --env-file "$envfile" -e JS_EVAL_B64="$js_b64" \
  -v "$ca_cert_win:/ca/global-bundle.pem:ro" "$image" sh -c "$cmd"
