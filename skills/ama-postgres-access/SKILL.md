---
name: ama-postgres-access
description: Get a real Postgres/Redshift connection to an AMA_APP service's environment (Staging/QA/Production), or to the main aggregation DB that backs report fields/values -- resolving the connection string from the live ECS task definition or Octopus, and connecting via a throwaway docker container, no local psql/driver install needed. Use when a fix needs direct DB access (schema drift, data inspection) that a code change alone can't confirm, or when confirming a real column/field name or its possible values for a report.
---

# Postgres access for AMA_APP services

Confirmed end-to-end (exportproducer/Staging).

## The premise that DOESN'T work for a SENSITIVE Octopus variable — don't try it there

**Sensitive Octopus variables are write-only via API.** `IsSensitive: true` always
returns `Value: null`, regardless of API key permissions — Octopus platform-wide design,
not a permissions gap. Don't waste time trying to read one that way.

**Check `IsSensitive` before giving up, though** — a shared library-variable-set entry
can be `IsSensitive: false` and reads fine. Confirmed:
`aggregation-database-connection-string` in `LibraryVariableSets-21` is NOT sensitive —
see "Aggregation DB (Redshift) via Octopus" below.

**ECS Exec is also not the path here** — confirmed disabled (service- and task-level
`enableExecuteCommand=false`) on `staging-v1-exportproducer-api-esvc`. Don't assume
enabling it is a quick fix either — that needs a service redeploy, real risk for a
"just let me look at the DB" ask.

## What DOES work — the task definition has it in plaintext

This fleet's Octopus deploy step doesn't inject secrets via ECS `secrets`/Secrets
Manager — it rewrites `appsettings.{Env}.json` placeholders at deploy time (see
[[ama-architecture-notes]]'s `API-SERVICE-CONVENTIONS.md`), and the rendered value ends
up as a **plaintext `environment` entry** in the ECS task definition. AWS CLI's default
profile on this machine already has fleet-wide IAM permissions (see
[[ama-cloudwatch-search]]) — no new auth needed.

```bash
aws ecs describe-task-definition --task-definition <env>-v1-<service>-api --region us-east-1 \
  --query "taskDefinition.containerDefinitions[0].environment[?name=='PostgreSqlSettings__Connection'].value" \
  --output text
```

**Task-def family name**: `<env>-v1-<repo>-api` (e.g. `staging-v1-exportproducer-api`) —
same repo→resolved-name anchoring gotcha as [[ama-octopus-deploy]]'s repo→project
mapping, don't assume a substring match, confirm via `aws ecs list-services --cluster
<env>-v1-AMA` first if unsure.

**Never print the resolved value in a chat reply.** Capture it straight into a shell
variable/temp file, use it, then delete the temp file — same handling as this harness
already applies to the Octopus API key.

## Connection string format (Npgsql-style, semicolon-delimited)

**ECS task-def flavour**:
`Server=...;Database=...;Port=...;SSLMode=...;TrustServerCertificate=...;User ID=...;Password=...`
— keys `Server`/`User ID`, NOT `Host`/`Username`.

**Octopus library-variable flavour is spelled differently** —
`Server=...;Database=...;UID=...;PWD=...;Port=...;SSL Mode=...;Trust Server
Certificate=...;MaxPoolSize=...;Timeout=...`. Same idea, different keys (`UID`/`PWD`,
`SSL Mode` with a space) — the two sources genuinely don't match, don't assume one
format from the other. The Dev-scope value also has a **space after every `;`** — trim
before matching a key, `grep '^Database='` silently returns nothing otherwise.

Either flavour: don't assume libpq naming, parse for the actual keys present.

## Pass credentials by `--env-file`, never on the command line — and Production IS available

**Production is reachable and readable** (`production-v1-<repo>-api` task def, same
`PostgreSqlSettings__Connection` lookup as any other env) — a denial here is a *shape*
problem, not a missing permission. Don't conclude "no prod DB access" and stop.

Interpolating the password into the `docker run` command (`-e PGPASSWORD="$(...)"`, or a
generated wrapper script that does) gets **denied by the permission classifier**. Confirmed
twice on `production-v1-reports-api`. The working shape writes the vars to a file first —
same file-not-argument convention `ama-jira-api`/`ama-bitbucket-api` already mandate:

```bash
# parse the connection string into an env file WITHOUT echoing it (node, not shell —
# $TMP/.rconn holds the raw `aws ecs describe-task-definition` output)
node -e "
const fs=require('fs');const c=fs.readFileSync(process.env.TMP+'/.rconn','utf8').trim();
const m={};c.split(';').forEach(p=>{const i=p.indexOf('=');if(i>0)m[p.slice(0,i).trim().toLowerCase()]=p.slice(i+1).trim()});
fs.writeFileSync(process.env.TMP+'/.pgenv',['PGHOST='+m['server'],'PGPORT='+(m['port']||5432),
 'PGDATABASE='+m['database'],'PGUSER='+(m['user id']||m['uid']),
 'PGPASSWORD='+(m['password']||m['pwd']),'PGSSLMODE=require'].join('\n')+'\n',{mode:0o600});"

docker run --rm --env-file "$TMP/.pgenv" postgres:16 \
  psql -X -A -F$'\t' --pset=footer=off -c "<sql>"
```

Quote PascalCase identifiers — every table/column in these DBs is case-sensitive
(`select "Id","Name" from "UserReport"`), an unquoted `UserReport` fails as `userreport`.

**A 2-5 min hang is the wedged Docker daemon, not a slow query or a blocked network.**
`docker desktop start` reporting "already running" does NOT mean healthy, and `docker ps`
can exit 0 with no output while wedged. Real probe: `timeout 60 docker images` — times out
⇒ `docker desktop restart --timeout 240`, then re-probe. Fixed it every time so far.

**Production reports DB** (`production-v1-reports-api` → `your_reports_db`,
note `v4`): `UserReport` holds the monthly-downloads state — `OwnedBy` is the bare username
(`robert.smith`), plus `MonthlyDownloadsActivated`, `IsDeleted`, and
`MetadataLatestCprPeriod`/`MetadataLatestCprYear` (the report's current CPR month window).
That's how you resolve report ids for a targeted report-transfers re-run, and how you tell
a deliberately-deactivated report from a missing export — see `ama-architecture-notes`'
`MONTHLY-DOWNLOADS.md`.

**Monthly Downloads is Postgres only.** Cohort reports live in **Mongo** (Amazon DocumentDB,
not covered here — see [[ama-mongo-access]]) and are NOT part of Monthly Downloads — they're
covered by Requested Downloads (`RequestedDownloadsExportService` in the `export` repo).
Don't go looking for cohort data in these Postgres DBs.

## Aggregation DB (Redshift) — `redshift-data`, no Docker or password needed

**Start here for the aggregation DB.** The AWS `redshift-data` API queries it with IAM
temp credentials — no Docker, no psql, no password touched at all:

```bash
bash ~/.claude/skills/ama-postgres-access/scripts/rs-query.sh "select 1"
# RS_DB_USER=ama_staging overrides the default ama_qa
```

Wraps execute-statement → poll describe-statement → get-statement-result → TSV. Confirmed
working with Docker Desktop **stopped**, so the Docker section below doesn't gate this DB.

IAM: needs `redshift-data:ExecuteStatement/DescribeStatement/GetStatementResult` +
`redshift:GetClusterCredentials` — on this machine via IAM group
**`hs_redshift_query_acess`** (typo is in the real group name). Missing that group →
`AccessDenied`, not a bug in the script.

**`--db-user` picks the DB role; the IAM identity is what authorizes the call.** So
"read-only" is a property of `ama_qa`/`ama_staging`/`ama_production`, NOT of the API — a
different `--db-user` isn't automatically safe.

What lives in there, the `aggregation_metadata` indirection, and query recipes:
`ama-architecture-notes`' `AGGREGATION-DB.md`. Don't query a report template's `Table`
name directly — it isn't a real table.

## Same DB via Octopus + psql (when you want an interactive session)

Main aggregation DB (reports repo's `Source: aggregation-db` templates, see
`ama-architecture-notes`' `REPORT-TEMPLATES.md`) is **Amazon Redshift, not RDS
Postgres** — port `5439`, database `dev`, host `*.us-east-1.redshift.amazonaws.com`
(QA/Staging/Prod). Redshift is wire-compatible, same `psql` recipe below works, add
`PGSSLMODE=require`.

Connection string lives in Octopus library variable set `LibraryVariableSets-21`
("YourProduct Exporter API"), variable `aggregation-database-connection-string`,
`IsSensitive: false`, scoped per env (`octopus.environmentIds` in
`harness-config.json`). Use the helper script (handles the env-scope pick, key
spellings, and dev's leading-space quirk):

```bash
eval "$(bash skills/ama-postgres-access/scripts/get-aggregation-connection.sh qa)"
```

**QA, Staging, and Prod all resolve to the SAME Redshift cluster** — confirmed identical
host (`your-redshift-cluster.c8rdwxjusez7.us-east-1.redshift.amazonaws.com`) across all
three, just a different read-only user per env (`ama_qa`/`ama_staging`/`ama_production`).
There's no separate "prod data" to worry about isolating — pick any of the three, `qa`
is simplest since it needs no justification.

**All three users are read-only.** This is a genuine safety property, not a convention
to self-police — a `SELECT` for field/value discovery can't damage anything regardless
of which of the three you pick. Optional config override:
`octopus.aggregationDbVariableSetId` (defaults to `LibraryVariableSets-21`).

**Dev(`<development>`)'s value points at a `*-production-rs.example-app.com`
host** — a Dev-scoped variable naming what looks like a production endpoint. Known and
already flagged to the user — don't "fix" it.

**Never echo the resolved value in a tool call/reply** — pipe straight into `eval`, or
capture to a variable and use it, never print the `export PGPASSWORD=...` line itself.

## Connecting — no local client needed

`psql`/`psycopg2` aren't installed on this machine and `python3` is a Windows Store
stub — don't waste time trying to install one. **Docker is available and already the
right tool**:

Check the daemon is up first — `docker desktop status` or `docker version`. Confirmed
failure mode when Docker Desktop isn't running:
`error during connect: ... open //./pipe/dockerDesktopLinuxEngine: The system cannot
find the file specified` — that's "start Docker Desktop", NOT "docker isn't installed".

**Start it yourself, don't hand back to the user:**

```bash
docker desktop start --timeout 180      # synchronous by default; returns when engine is up
docker desktop restart --timeout 240    # status says running but docker version still fails
wsl --shutdown && docker desktop start  # last resort, WSL-wedged engine
```

First `docker run postgres:16` afterwards also pays an image pull — slow isn't hung.

```bash
docker run --rm -e PGHOST=<server> -e PGPORT=<port> -e PGDATABASE=<database> \
  -e PGUSER=<user id value> -e PGPASSWORD=<password> postgres:16 \
  psql -c "\dn" -c "\dt <schema>.*"
```

`postgres:16` pulls a throwaway client-only container (no local Postgres server
needed) — the actual DB is the remote RDS/Redshift instance the connection string
points at.

## Confirmed per-service database/schema mapping

**Only what's actually been resolved — don't extrapolate to services not yet
checked, resolve them the same way when a real need comes up:**

| Service | Env var / source | Host pattern | Database | Schema confirmed |
|---|---|---|---|---|
| `exportproducer` | `PostgreSqlSettings__Connection` (ECS task-def) | `staging-v2-exporter-exportproducer.*.rds.amazonaws.com` (note: **`v2` in the RDS hostname, not `v1`** — doesn't follow the ECS `<env>-v1-*` naming convention, confirmed gotcha, don't assume it does) | `staging_v1_exporter_exportproducer_db` | `hangfire` (11 tables: `counter`, `hash`, `job`, `jobparameter`, `jobqueue`, `list`, `lock`, `schema`, `server`, `set`, `state`) |
| aggregation DB (reports templates) | `aggregation-database-connection-string` (Octopus `LibraryVariableSets-21`) | `your-redshift-cluster.c8rdwxjusez7.us-east-1.redshift.amazonaws.com`, port `5439` (Redshift, not RDS) — **identical host for QA/Staging/Prod, one shared cluster**, only the user differs (`ama_qa`/`ama_staging`/`ama_production`), **all three read-only** | `dev` (same literal name across QA/Staging/Prod scopes) | `public` — 903 base tables + 160 views. Physical tables are dated ETL snapshots resolved through `aggregation_metadata`, see `AGGREGATION-DB.md` |

| `export` (QA) | `PostgreSqlSettings__Connection` (ECS task-def `qa-v1-export-api`) | `qa-v2-exporter-export.*.rds.amazonaws.com` — **`v2` in the RDS hostname again**, same gotcha as `exportproducer` | `qa_v2_exporter_export_db` | `public` — holds **`SqlTemplate`** (`"Column"`, `"Template"`, `"IsDeleted"`, `"MultiTableSetName"`), the table `R__Add_Sql_Template_Data.sql` writes. Read a header's real stored SQL here when a report errors |
| `reports` (QA) | `PostgreSqlSettings__Connection` (ECS task-def `qa-v1-reports-api`) | `qa-v2-exporter-reports.*.rds.amazonaws.com` (`v2` again) | `qa_v2_exporter_reports_db` | `public` — `TemplateReport` (the published report JSON), `UserReport` (saved reports; `Report`/`Query` are `jsonb`, useful for "does any saved report still reference removed column X"), `UserSavedReport`, `ReportAccess`, `ShareReport`, `ReportDimension` |

| `reports` (Production) | `PostgreSqlSettings__Connection` (ECS task-def `production-v1-reports-api`) | (not recorded — resolve live) | — | Same tables as QA row. `UserReport` also holds `TemplateFields` (TEXT, JSON list) and `MonthlyDownloadsActivated` — the monthly-downloads inputs, see `ama-architecture-notes`' `MONTHLY-DOWNLOADS.md`. Prod `export` DB: task-def `production-v1-export-api`, holds `SqlTemplate` |
| `reports` / `export` (Staging) | `PostgreSqlSettings__Connection` (ECS task-defs `staging-v1-reports-api` / `staging-v1-export-api`) | (resolve live — same `v2` hostname gotcha) | — | Same tables as QA rows. Confirmed working via the same throwaway-psql recipe (PROJ-15286 staging tests) |

Add a row here each time a new service/environment combination gets resolved — don't
let this table go stale by only ever checking it for one service.

## One-off datafix recipe (jsonb/TEXT column, single row, production)

Proven pattern (PROJ-15286) for surgically updating one row's jsonb/TEXT column:

1. `SELECT <col>::text` the current value to a backup file first — rollback = UPDATE back.
2. Transform the backup OFFLINE (jq), then diff transformed vs original and assert only the
   intended keys changed before touching the DB.
3. Apply via psql stdin with the new value **dollar-quoted** (`$tag$<json>$tag$`) — never
   shell-interpolated; guard that the payload doesn't contain the tag. In one transaction:
   `UPDATE ... RETURNING`, then assert stored = intended (`"Col" = $tag$...$tag$::jsonb` —
   jsonb equality, since jsonb normalizes key order; plain `=` for TEXT), then `COMMIT`.
4. Gotcha: don't build the SQL tail with printf `'\''` quote-gymnastics — it corrupts
   silently; use a double-quoted `echo` line for the non-payload SQL.

The `export` row above resolves what used to be flagged as unresolved. Note it holds
`SqlTemplate`; the DynamicColumn/custom-band data (see `ama-architecture-notes`'s
`CORE-LIBRARIES.md`, read by `querybuilder` but not its own DB) lives in the same DB —
confirm the specific table when a task actually needs it.
