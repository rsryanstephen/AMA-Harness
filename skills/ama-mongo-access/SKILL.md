---
name: ama-mongo-access
description: Get a real read-write connection to the cohorts / cohort-reports Amazon DocumentDB clusters (QA/Staging/Production) via SSH-tunneled mongosh in a throwaway Docker container -- no local mongosh/driver install needed. Use when a fix or investigation needs direct Mongo/cohort data (schema drift, data inspection, one-off datafix) that a code change or Graylog alone can't confirm. Companion to [[ama-postgres-access]] -- that skill covers the fleet's Postgres/Redshift DBs, this one covers cohorts/cohort-reports.
---

# Mongo/DocumentDB access -- cohorts + cohort-reports

Confirmed working end-to-end on **all three envs** (`docdb-query.sh <env> '<eval>'`, tunnel
+ Docker mongosh/mongo, real data read back each time) -- same bastion host serves QA,
Staging, and Production. Production's `mongo:4.0` legacy-shell fallback (engine 4.0.0, wire
7) works too; the `--sslAllowInvalidHostnames` hostname-mismatch line it logs on connect
(`Hostname: host.docker.internal does not match SAN(s): production-v1-cohorts...`) is
expected noise, not a failure -- that flag exists specifically because a tunneled
connection's hostname never matches the cert's real SANs.

## Not self-hosted Mongo -- it's DocumentDB, private VPC, SSH bastion required

Studio 3T screenshot showing an EC2 host + SSH tunnel is the tell: the cluster itself has
no public endpoint. `ec2-*.<region>.compute.amazonaws.com` box = bastion, not the DB. Every
connection tunnels through it first. `global-bundle.pem` = AWS's public RDS/DocumentDB CA
bundle, not a secret -- `curl -o ~/.ssh/global-bundle.pem
https://truststore.pki.rds.amazonaws.com/global-bundle.pem`, no hand-off needed.

## No connection string ever pasted or stored -- pull it from ECS, same trick as postgres

Same mechanism [[ama-postgres-access]] documents for Postgres: Octopus rewrites
`appsettings.{Env}.json` placeholders at deploy time -> plaintext `environment` entry on
the ECS task def.

```bash
aws ecs describe-task-definition --task-definition <env>-v1-cohortreports-api --region us-east-1 \
  --query "taskDefinition.containerDefinitions[0].environment[?name=='MongoSettings__Connections__0__ConnectionString'].value" \
  --output text
```

Task-def family: `<env>-v1-cohortreports-api` (`qa`/`staging`/`production`). Never print the
resolved value in a reply -- straight to a temp file, same handling as the Octopus API key
and postgres passwords.

## URI params are .NET-driver spellings -- don't pass the string through to mongosh

Real QA value shape:
`mongodb://<user>:<pass>@qa-v1-cohorts.cluster-*.docdb.amazonaws.com:27017/?ssl=true&sslVerifyCertificate=false&ssl_ca_certs=rds-combined-ca-bundle.pem&replicaSet=rs0&readPreference=secondaryPreferred&retryWrites=false`

None of `ssl`/`sslVerifyCertificate`/`ssl_ca_certs` are mongosh flags, and `replicaSet=rs0`
makes SDAM chase internal VPC hostnames the tunnel doesn't forward. Parse user/pass out,
rebuild as `--host host.docker.internal:<port> --tls --tlsCAFile /ca/global-bundle.pem
--tlsAllowInvalidHostnames` (hostname mismatch is inherent to tunneling, not a real cert
problem) `--authenticationDatabase admin`.

## Engine version picks the shell -- same wire-version wall as PROJ-15178

| Cluster | Engine | Wire | Client |
|---|---|---|---|
| `qa-v1-cohorts` | 5.0.1 | >= 8 | `mongo:7`'s `mongosh` |
| `staging-v1-cohorts` | 5.0.1 | >= 8 | same |
| `production-v1-cohorts` | **4.0.0** | 7 | `mongo:4.0`'s legacy `mongo` shell + `--ssl --sslAllowInvalidHostnames --sslCAFile` |

`qa-v1-cohort-search`/`production-v1-cohort-search` (also DocumentDB 4.0.0) have zero
consumers -- don't route there, nothing lives in them. PROJ-15178/PROJ-15275 have
the full history of why 4.0 is still around on prod and 5.0.1 elsewhere.

## Use the script -- handles tunnel + shell pick + no-echo

```bash
bash skills/ama-mongo-access/scripts/docdb-query.sh qa 'db.adminCommand({listDatabases:1})'
bash skills/ama-mongo-access/scripts/docdb-query.sh qa 'db.getSiblingDB("cohort-reports").getCollectionNames()'
```

Needs `MONGO_SSH_KEY_PASSPHRASE` set (no default, fails loud). `MONGO_SSH_KEY` defaults to
`~/.ssh/PROJ_RELEASE.pem`, `MONGO_CA_CERT` to `~/.ssh/global-bundle.pem` -- override
either if yours live elsewhere. Bastion host per env comes from `harness-config.json`'s
`mongo.bastionHosts.<env>` -- populate via `/harness-setup` (a stopped/restarted EC2 instance
gets a new public DNS name unless it's an Elastic IP; that's why this is config, not a
constant in the script).

Tunnel binds `0.0.0.0`, not loopback -- confirmed necessary, not just theorized: a
loopback-only (`127.0.0.1`) bind reliably `MongoServerSelectionError`s from inside the
container (Docker Desktop's `host.docker.internal` doesn't proxy to the host's loopback),
while `0.0.0.0` connects every time. LAN-visible for the tunnel's lifetime as a result;
script kills the tunnel and shreds the temp env file on every exit path (`trap ... EXIT`).

Script actively polls the local port (`/dev/tcp` probe, up to ~9s) rather than a fixed
`sleep` before handing off to Docker -- the SSH handshake + `0.0.0.0` bind took anywhere
from ~1s to ~4s across repeated runs here, and a flat `sleep 2` intermittently lost that
race (confirmed: `ECONNREFUSED` on a fast rerun where SSH was still mid-handshake).

One database, not two: confirmed on QA, the whole cluster's data is under a single DB
literally named `cohort` (not `cohorts`/`cohort-reports` as the connection string's empty
DB segment might suggest) -- collections `cohort`, `cohortreport`, `export`, `_migrations`.
`db.getSiblingDB("cohort").getCollectionNames()`.

## These are read-write app creds -- no DB-level safety net

Unlike [[ama-postgres-access]]'s Redshift users (`ama_qa`/etc, all read-only by design),
this is the application's own DocumentDB user -- it can write and drop. There's no
enforced read-only mode here; be as careful with a write/delete eval as you'd be editing
prod data directly, because that's exactly what it is.

## No local mongosh/mongo -- Docker throwaway container, same premise as postgres:16

Neither `mongosh` nor `mongo` is installed on this machine (checked). `docker run --rm
mongo:7|mongo:4.0 ...` pulls a client-only image -- the real DB is the remote DocumentDB
cluster the tunnel points at. First pull after a while is slow, not hung -- same Docker
Desktop wedged-vs-down distinction [[ama-postgres-access]] covers (`timeout 60 docker
images` probe, `docker desktop restart --timeout 240` fix).

## Config

`harness-config.json`:
```json
"mongo": {
  "bastionUser": "ubuntu",
  "bastionHosts": { "qa": "", "staging": "", "production": "" },
  "localPort": 27018
}
```
`bastionHosts.<env>` populated per env as each one gets used -- don't extrapolate QA's
bastion to staging/production, confirm live the same way.
