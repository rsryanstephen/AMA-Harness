# Graylog reference — fields, streams, existing alerts

Confirmed against the live instance (`/api/system/fields`, `/api/events/definitions`,
`/api/streams`). Read this before hand-rolling a query from scratch.

## Repo → `application` field value — see APP-NAME-MAPPING.md, don't guess

[APP-NAME-MAPPING.md](APP-NAME-MAPPING.md) has the confirmed real mapping (queried
directly from Graylog, not derived from repo names). Several genuinely don't follow the
`<repo>-api` pattern — check there before free-text searching to pin one down.

## Structured fields worth querying directly, not text-matching `Message`

The apps here log structured fields, not just a free-text message — query these directly instead of
regexing the message body:

- `ExceptionType`, `ExceptionMessage`, `ExceptionSource`, `StackTrace` — a real .NET exception has all
  four, structured. `ExceptionType:*` finds every exception regardless of message wording.
- `RequestPath`, `RequestMethod`, `StatusCode`, `Elapsed`/`ElapsedMs`/`DurationMs` — structured HTTP
  request logging (ASP.NET request logging middleware). `StatusCode:>=500 AND environment:qa` beats
  guessing at message text for "find server errors."
- `CorrelationId` (app-level, case varies: `CorrelationId`/`correlationId`/`Message_CorrelationId`/
  `cascadeMessage_CorrelationId`) and `request_headers_X-Correlation-Id` (the actual HTTP header) —
  two different correlation mechanisms, don't assume they're the same value without checking both.
  Neither is an exact-match keyword field here (see [KNOWN-SIGNATURES.md](KNOWN-SIGNATURES.md)'s
  sibling doc, [SKILL.md](SKILL.md)'s Do NOT section) — use a narrow absolute time window instead.
- `Severity`/`level`/`stringLevel` — three different severity representations coexist (numeric syslog
  level, a "Severity"-labelled string like `"Error (3)"`, and `stringLevel` e.g. `"Information"`).
  `level` is the reliable one for numeric comparison (`level:<=3`, roughly — see Do NOT below).
- `known_issue` — **not** "this specific bug is known," it's an *alert-suppression* marker a pipeline
  rule adds. Confirmed values seen: `"Suppress product-service-exportproducer"`, `"Suppress non
  prod alerts"`. A message having this field means alerting was deliberately silenced for it (noisy
  app, or non-prod) — it does NOT mean the error itself is benign or already diagnosed. Don't conflate
  with the [KNOWN-SIGNATURES.md](KNOWN-SIGNATURES.md) signatures, which are about specific root causes.
- `failed_message`, `failure_cause`, `failure_type` — these belong to Graylog's OWN ingestion pipeline
  (a message Graylog itself couldn't parse/index), not application errors. If something seems to be
  missing entirely from search results (not just absent — genuinely never indexed), check the
  `Processing and Indexing Failures` stream (id `000000000000000000000004`) for these fields.

## Recovering the full text of a truncated log line (e.g. long SQL) — via `full_message`

The short `message`/`Message` field is capped around 500 chars — a long SQL query logged
via a call like `ExecuteRawQuery::SQL` gets cut off mid-query in that field. The **full
untruncated text is already sitting in `full_message` on the same log entry** — no need
for a second query,
a different endpoint, or a multi-part convention (that's a different pattern, see
[KNOWN-SIGNATURES.md](KNOWN-SIGNATURES.md)/cohort's `COHORT_SQL`, not this one).

**The one thing that actually matters: which endpoint you hit, and whether you restrict `fields`.**

- `/api/search/universal/absolute` or `/relative` — hit it with **no `fields` param at
  all** (i.e. don't pass the 5th arg to `graylog-search.sh`, or omit `--data-urlencode
  fields=...` in a raw curl). The response's `messages[].message` object comes back with
  every field flattened at the top level, `full_message` included, with the complete
  text. Passing `fields=timestamp,full_message` explicitly breaks this — `full_message`
  comes back JSON `null`. Don't restrict fields when you need `full_message`; fetch full
  and pluck it out client-side instead.
- `/api/messages/<index>/<message-id>` (fetching one specific message by id, e.g. to
  follow up on a hit from the search above) — top-level `message.full_message` here is
  **stale/empty**, do NOT trust it. The real content is one level down, at
  `message.fields.full_message`. This is a different response shape than the search
  endpoints above — don't assume the same key path works on both.

Don't conclude "full_message is truncated too" or "full_message is empty" — both are
artifacts of the wrong endpoint/key-path combo above, not real; re-check both before
declaring the field missing.

## Real alerting already configured — check what's already paging someone before assuming silence

- **Active production alert**: `L1 support stream alert-New` ("YourProduct Level 3 support
  notification") watches the support alert stream (`graylog.alertStreamId` in
  `harness-config.json`), evaluated every 60s, fires when `sum(level) > 1` in that window —
  i.e. essentially any single error-level message. If investigating "what's currently
  paging support," scope the search to this stream id directly instead of searching everywhere.
- A second definition (`L1 support stream alert(TO REMOVE)`) exists but is marked for removal —
  don't treat it as live.
- List all current definitions yourself if this drifts: `GET /api/events/definitions?per_page=100`
  (same auth as everything else here).

## System streams worth knowing about

- `000000000000000000000001` — All messages (the default, unscoped search).
- `000000000000000000000002` — All events (Graylog's own event/alert firings, not application logs).
- `000000000000000000000003` — All system events.
- `000000000000000000000004` — Processing and Indexing Failures (Graylog's own ingestion failures —
  see `failed_message`/`failure_cause` above).
- `graylog.alertStreamId` (`harness-config.json`) — prod1 L1 support alert stream (see alerting section above).

Full current list: `bash ~/.claude/skills/ama-graylog-search/scripts/graylog-list-streams.sh`.
