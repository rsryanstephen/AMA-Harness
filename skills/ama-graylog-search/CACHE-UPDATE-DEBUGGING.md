# Cache updates — triggering, monitoring, and debugging a failure

Confirmed from the state machine definitions, the Admin UI's own calls, and real incidents.

## A report / SqlTemplate change does NOT take effect until a cache update runs

Deploying is not enough. `reports` caches templates and `search` caches the SqlTemplate set
(both Redis-backed, so they survive an ECS restart — a redeploy does NOT clear them). Until a
cache update runs, the API keeps serving the pre-change copy.

**Required after EVERY deploy of such a change, in EVERY environment it reaches** (qa, then
staging, then production — it does not carry over): run a **`main` update**.

**A `sqltemplates` update is NOT enough — confirmed live.** An `/update` with a single-type
cache-type runs ONLY that type's update lambda and skips every clear state (`ClearOnly:
false` short-circuits the "Update or Clear?" choice straight to the update task). For
`sqltemplates` that lambda is `export-cacheupdate` → `PUT {export}/sqlTemplate/update`, which
re-runs export's DB migration and nothing else — **`search`'s own Redis copy of the set
(`SQL_TEMPLATES_CACHE_<Loan|Pool>`, `SqlTemplateService`) is never cleared**, and search keeps
executing the stale SQL. The `main`/`all` chain is what fixes it: its Search leg runs
"Clear and Update Search" → search's `ClearMainCache()` = every key except curve, stale set
included. (`DELETE /clear?cache-type=sqltemplates` also clears it — cacheclear-lambda →
search's `/cache/sqltemplates`, pattern `SQL_TEMPLATES_CACHE*` — but then nothing repopulates
export's side, so prefer `main`.)

**Skipping it can 500 the report, not just serve stale data.** Removing SqlTemplate columns
leaves the *generated* `OTHERS_PCT` in search's stale cache still summing the removed aliases →
`42703: column "template_pct_<removed>" does not exist` → report returns 500 for everyone.
Nothing self-heals it; scheduled runs can be weeks apart.

## Triggering (same calls the Admin UI makes)

API Gateway `<env>-v1-cacheupdate-api-gateway-rest-api`, stage `cache`, **auth is `NONE`** —
no HMAC, no IAM signing, no API key needed. Resolve ids with
`aws apigateway get-rest-apis --query "items[?contains(name,'cache')]"`.

```bash
BASE="https://<api-id>.execute-api.us-east-1.amazonaws.com/cache"
curl -sS -X PUT    "$BASE/update?cache-type=main"    # the default — full clear+update chain
curl -sS -X DELETE "$BASE/clear?cache-type=<type>"   # clear only, no repopulate
```

Valid `cache-type`: `all`, `reportTransfers`, `curve`, `main`, `fieldtablemapper`,
`sqltemplates`, `notifications`, `reports`, `search`. The response echoes a **1-based**
`CacheType` int (`main`=1, `sqltemplates`=6, `reports`=8) — use it to confirm the right type
was hit. Single-type `/update`s carry the no-clear trap above — reach for them only when the
narrow semantics are actually what you want.

## Monitoring — HTTP 200 only means "queued"

The response is `"Message added to the waiting queue"`; the work is async. Confirm completion,
don't assume it:

```bash
aws stepfunctions list-executions --region us-east-1 \
  --state-machine-arn "arn:aws:states:us-east-1:<aws.accountNumber>:stateMachine:<env>-v1-cacheupdate-statemachine" \
  --max-items 5 --query "executions[].{name:name,status:status,start:startDate,stop:stopDate}" --output table
```

Console equivalent, for a human: `https://us-east-1.console.aws.amazon.com/states/home?region=us-east-1#/statemachines/view/arn%3Aaws%3Astates%3Aus-east-1%3A<aws.accountNumber>%3AstateMachine%3A<env>-v1-cacheupdate-statemachine`

Graylog confirmation line per step: `"<Step> Cache Update Completed"` (e.g. `SqlTemplates Cache
Update Completed`, `Reports Migration & Report Templates Cache Update Completed`), carrying the
CorrelationId the trigger returned. `GET $BASE/latest` gives the last recorded state;
`GET $BASE/states` currently 500s (pre-existing, unrelated to your change).

Failed or stuck → the rest of this file.

## Debugging a failure — the one thing that will mislead you

**`<env>-v1-cacheclear-lambda` is the universal messenger, not the failing component.**
Every step (FieldTableMapper, SqlTemplates, Reports, Search, Notifications, Curve...)
calls this SAME lambda to clear/report status, so it's what logs "Cache Update failed"
in Graylog for literally every step's failure. Don't stop there thinking you've found
the culprit — the real failing lambda is a *different*, per-step function, and its name
often has **no obvious relation to the step name**. Resolve it from the state machine's
own definition, not by guessing from the step name:

```bash
MSYS_NO_PATHCONV=1 aws stepfunctions describe-state-machine \
  --state-machine-arn "arn:aws:states:us-east-1:000000000000:stateMachine:<environment>-v1-cacheupdate-statemachine" \
  | jq -r '.definition' > /tmp/def.json
grep -A3 '"Update <Step>"' /tmp/def.json   # e.g. "Update Search", "Update Reports"
```
Look for the `Resource`/`FunctionName` in that state's block — that's the real target.
The account number in the ARN above is mirrored as `aws.accountNumber` in
`~/.claude/harness-config.json` — swap it for a different adopter.

## Step → real Lambda function (confirmed, `<env>-v1-` prefix, same pattern across qa/production/staging)

| State machine step | Real Lambda function suffix | Name matches step? |
|---|---|---|
| FieldTableMapper | `fieldtablemapper-cacheupdate` | yes |
| SqlTemplates | `export-cacheupdate` | **no** — maps to `export`, not `sqltemplates` |
| Reports | `reports-cacheupdate` | yes |
| Search | `selenium-crawlers-cacheupdate` | **no** — maps to `selenium-crawlers`, not `search`/anything search-related |
| Notifications | `notifications-cacheupdate` | yes |
| Curve | `curve-cacheupdate` | yes |
| Report Transfers | `report-transfers` (no `-cacheupdate` suffix) | yes, but no suffix |
| Cascade to next environment | `cacheupdate-cascade-lambda` | yes |
| Cache-clear step for ALL of the above | `cacheclear-lambda` | — universal, see above |

State machine name itself: `<environment>-v1-cacheupdate-statemachine` (confirmed `production`/`qa`/`staging`).

## Practical debugging order

1. **Graylog** — find the `CacheClear Lambda - Cache Update failed` message, get its exact timestamp and `Step` field (tells you WHICH step failed, e.g. `"Step": "Search"`).
2. **Step Functions** — `query-cacheupdate-stepfunction.sh <environment> <approx-time>` (see main SKILL.md rule 10) for the execution's real error/cause. If you need the specific failing Lambda's name (not just the error), pull the state machine's own definition per the table above — don't guess from the step name.
3. **CloudWatch** — `cloudwatch-find-log-group.sh <lambda-suffix-from-table>` to get the real log group, then `cloudwatch-search-logs.sh` around the exact failure time. Check invocation *history* too (`aws logs describe-log-streams --order-by LastEventTime`) — a Lambda invoked rarely (e.g. once a month) is essentially always a cold start, which explains transient `CodeArtifactUserPendingException`-style init-timing failures that resolve themselves on the next run.

## Other confirmed gotchas (apply throughout this whole flow)

- `MSYS_NO_PATHCONV=1` on every `aws` call whose args start with `/` or need exact ARN strings, and `PYTHONUTF8=1` on every `aws logs` call — see [[ama-cloudwatch-search]]'s gotchas section.
- A GUID field match in Graylog (`CorrelationId:"..."`) is NOT exact here — use a narrow absolute time window (`/api/search/universal/absolute`) to correlate precisely instead.
- `graylog-search.sh`'s `range` is relative-to-now — for a past incident hours/days old, use the absolute endpoint, not a huge relative range that happens to cover it by luck.
