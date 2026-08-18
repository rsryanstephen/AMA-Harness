---
name: ama-graylog-search
description: Search Graylog logs via its REST API — translates a plain-English ask into a Lucene query. Use for "search/check Graylog", "is X throwing errors", "check for exceptions in Y", "anything failing in qa/staging/production", or "what happened around <time>" for any AMA_APP service. Default first place to check for errors, even when Graylog isn't named.
---

# Graylog search

Instance: `http://your-graylog-host:9000` (Graylog 4.2.6).
Mirrored as `graylog.host` in `~/.claude/harness-config.json` — swap that field for a
different adopter (the message-link URL below uses the same host).

**Auth**: `$GRAYLOG_PAT` env var (Personal Access Token), used as Basic Auth — PAT as username, literal string `token` as password. Unset → stop, alert user, give exact cmd, wait for confirm:
```bash
echo 'export GRAYLOG_PAT="your_actual_graylog_pat_here"' >> ~/.bashrc
```

**Endpoint**: `/api/search/universal/relative` — this instance's version. The newer "Search Scripting API" (`/api/search/messages`, documented for later Graylog versions) 404s here — don't use it. **The `/terms` sub-endpoint (`.../absolute/terms`, per-field value counts) silently returns empty here too** — for a per-application/field breakdown, loop plain count queries per candidate value instead (confirmed 2026-08-13).

**Investigating a specific past window (not "last N")**: `graylog-search.sh`'s `range` param is relative-to-now — useless for "what happened around 06:05 UTC this morning" once it's hours later. Use `/api/search/universal/absolute` directly instead, with `from`/`to` ISO timestamps in place of `range`. No wrapper script — direct `curl`, same auth/base URL.

**Too-small `range` fails SILENTLY — 0 results, no error, looks like "nothing logged".** Long session ⇒ target event may be hours back, not minutes. Unexpected 0 → baseline `'*'` at same range, check newest `timestamp`, widen (deploy ~7h ago ⇒ `range=36000`). Never read empty as "didn't happen".

**Read [GRAYLOG-REFERENCE.md](GRAYLOG-REFERENCE.md) before hand-rolling a query** — confirmed structured fields to query directly instead of text-matching `Message` (exceptions, HTTP request fields, correlation ids), what `known_issue` actually means (alert suppression, not "known bug"), and the real production alerting stream/config already in place.

## Steps

1. Translate the user's ask into a Lucene query string, same syntax as the Graylog UI search box (e.g. `environment:qa AND level:3 AND NOT "exportproducer/ping"`). Known fields: `environment`, `level` (syslog severity, 3=error), `application`, `SourceClassName`, free text. **Any error search/sweep → build the `ExceptionType` exclusion into the query itself**: `AND NOT ExceptionType:"System.OperationCanceledException" AND NOT ExceptionType:"System.Threading.Tasks.TaskCanceledException"` (see [KNOWN-SIGNATURES.md](KNOWN-SIGNATURES.md)'s cancellation signature). Message text for these varies per call site — filtering the structured field is the only way to catch all of them; don't rely on recognizing the message text after the fact.
2. Convert their time range to seconds (`range` param): "last day"=86400, "last hour"=3600, "last 15 min"=900, etc.
3. Stream named, not just "search everywhere"? Resolve name → id first:
   ```bash
   bash ~/.claude/skills/ama-graylog-search/scripts/graylog-list-streams.sh
   ```
   Gives `<id>\t<title>` per line.
4. Run the search:
   ```bash
   bash ~/.claude/skills/ama-graylog-search/scripts/graylog-search.sh "<lucene-query>" <range-seconds> "<stream-id-or-empty>" <limit> "<fields-csv-or-empty>"
   ```
   Returns raw JSON — `total_results`, `messages[]` (each `.message.message` etc per selected fields), `used_indices`.
5. Summarize for the user: total match count, then the actual messages (timestamp + message text minimum) — don't just dump raw JSON at them unless they ask for it.
6. **Creating a bug ticket from a log finding** (user pointed it out, or you found it yourself while searching) — include a direct link to that exact log message in the ticket description:
   ```
   http://your-graylog-host:9000/messages/<index>/<message._id>
   ```
   `<index>` and `<message._id>` come straight off each hit in the search response (e.g. `index":"graylog_432"`, `message":{"_id":"fff9cb51-..."`) — grab them from the raw JSON, don't guess.
7. **Before triaging any error as new, check [KNOWN-SIGNATURES.md](KNOWN-SIGNATURES.md).** Confirmed real signatures already investigated to root cause — recognizing one saves re-diagnosing from scratch: a stale-cache condition that isn't a bug at all (stop diagnosing on sight), and a historic Shared-library DI regression that can still show up in repos that haven't yet picked up the fixed version.
8. **Correlate error bursts before triaging — a downstream error isn't a separate bug.** An error in `application:X`, followed within ~2-3 seconds by a burst of errors from calls *to* X (e.g. `application:querybuilder-api` errors, then `GetAsync`/`PostAsync` etc failures against `http://product-service-querybuilder...` from other apps) → the burst is caused by the original error, not independent incidents. Report/ticket the root error once; call out the burst as its consequence, don't triage each one separately.
9. **Tight clustering is itself a correlation signal, cross-service rule or not.** Any group of errors logged within ~0.5s of each other, regardless of which apps/fields they're from, is most likely all caused by the first error in that window — treat the earliest one as root cause, the rest as its fallout, not separate bugs.
9a. **A `responded 500` in the same second as a preceding logged error is caused by that error, full stop — not a separate issue.** Also, if the user told you to ignore an already-accounted-for error, ignore any resulting `responded 500` errors.
10. **"CacheClear Lambda - Cache Update failed" with no nearby Graylog error → check AWS Step Functions directly.** AWS CLI + this machine's default profile already have `states:ListExecutions`/`states:GetExecutionHistory` on the cacheupdate state machines — no extra setup, nothing to ask the user for.
    - First, per rule 8/9: search Graylog for an error shortly *before* the CacheClear log, same correlation rules apply — if found, that's the root cause, done.
    - Nothing in Graylog explaining it → query the state machine directly:
      ```bash
      bash ~/.claude/skills/ama-graylog-search/scripts/query-cacheupdate-stepfunction.sh <environment> <approx-failure-time-utc>
      ```
      State machine naming convention: `<environment>-v1-cacheupdate-statemachine` (`production`, `qa`, `staging`). Finds the closest `FAILED` execution within 10 minutes of the given time, prints its real error + cause straight from the execution history (surfaces errors Graylog never logged, e.g. an `HttpRequestException` connecting to `product-service-reports`), plus a direct AWS Console link to that execution — same "link the source" convention as rule 6's Graylog message links, don't just describe it in prose.
    - **Read [CACHE-UPDATE-DEBUGGING.md](CACHE-UPDATE-DEBUGGING.md) before going further** — confirmed step→real-Lambda mapping (the failing component is almost never the lambda whose name matches the step — e.g. `Search` step actually runs `selenium-crawlers-cacheupdate`), plus the exact commands to resolve any step's real target instead of guessing.
11. **Graylog has nothing at all for a suspected error → don't conclude "no error happened."** Infra-level failures (container crash, ECS task provisioning, missing env var, Lambda cold-start/OOM) happen outside the app's own logging pipeline and never reach Graylog. Fall back to [[ama-cloudwatch-search]] — it searches the actual ECS/Lambda CloudWatch logs directly.
12. **"What SQL caused this error?" — search for the SQL log line just before it, not around it.**
    - `search-api`: `Message` starting `ExecuteAsync::SQL`, within **1-2s before** the
      error. **Long queries are split across multiple messages** —
      `"ExecuteAsync::SQL\n\nSQL Part 1:\n\n<chunk>"`, `"...SQL Part 2:..."`, etc., all at
      (near-)identical timestamps. Fetch ALL of them (don't stop at the first hit),
      sort by Part number (not just timestamp — parts can tie), strip each one's
      `ExecuteAsync::SQL\n\nSQL Part N:\n\n` prefix, and concatenate in order to
      reconstruct the actual query — a single part is a fragment, not the whole SQL.
    - `resultsprocessor` (exports): `Message` starting `BuildQueryForExport::SQL`, within **2-4s before** the error.
    - **Cohort creation** (`cohortdata`/`cohortreports`): `Message` containing `COHORT_SQL` (mapping-execute, loan-selection, and name-mapping create/update/delete each log their own `COHORT_SQL ...` line, front-loaded with that literal token so it survives GELF's short-message truncation). **Pass `full_message` in the `fields-csv` arg, don't rely on `Message`** — GELF's short `message` field truncates around ~500 chars, and real cohort SQL has exceeded 18k chars; the script only returns `full_message` if you explicitly ask for it (5th arg). No established seconds-before-error offset yet — search a wider window around the error until one's established.
    - **Curve analyser** (`YourCompany.Product.Search.CurveAnalyser`, runs in `search-api`):
      `Message` containing `CurveAnalyserQuery:` — logged as
      `"CurveAnalyserQuery: \n\nSQL:\n\n<sql>"` right before execution
      (`SqlQuery/DbRepository.cs`). **Debug level (`level:7`), not Info** — absent means
      debug logging off for that env, not "no curve query ran". Failures log
      `"Error sending CurveAnalyserQuery: <ex.Message>"` at error level, so the error is
      findable even when the SQL line isn't. Ready-made UI search:
      ```
      http://your-graylog-host:9000/search/<graylog-saved-search-id>?q=message%3A+%22CurveAnalyserQuery%3A%22&rangetype=relative&from=900
      ```
      (path segment = saved-search id; per rule 13 pull ids + range out of a URL like
      this, don't re-derive.) API equivalent:
      `graylog-search.sh '"CurveAnalyserQuery:"' 900 "" 20 "timestamp,full_message"` —
      pass `full_message`, curve SQL exceeds GELF's ~500-char `message` truncation.
    - Doesn't apply if the error happened while building the SQL itself (before any SQL line was ever logged) — no SQL line will exist to find. Exception: `COHORT_SQL` logs before executing regardless, so it can still capture the query text even for a fail-safe throw at/around execution time — just not for failures further upstream than these logging sites.

12a. **Prove a request never reached SQL at all — silent-empty-result bugs, not errors.** `search-api`'s `ExecuteAsync::SQL` logs unconditionally at Debug, success or fail, before Redshift ever runs. Zero rows returned, no error -> search Graylog for an exact unbroken substring unique to the suspect request (a field/column name, no spaces — avoid short phrases, analyzer tokenizes loosely) across the repro window. Zero hits, while structurally similar requests from OTHER users/reports in the same window DO log -> request never reached SQL build/exec. Redirects debugging upstream (facade/cache/validator early-return), not into SQL builders. Also check `"Well that went wrong"` (placeholder `sql` var before build) and Error-level `ExecuteAsync::SQL` -> either means a build-time exception instead (shows as HTTP error, not silent empty 200).
    - **Two false-positive traps, both hit live (PROJ-15262):** (1) window arithmetic — Graylog timestamps are UTC, repro notes are usually local (+0200 here); a relative range computed from "now" can miss the repro entirely and zero-hits proves nothing. Prefer a fresh repro + immediate tight-window search. (2) prefix variants — toprow/rowcount requests log `ExecuteTopRowAsync::SQL` / `ExecuteRowCountAsync::SQL`, which a quoted `"ExecuteAsync::SQL"` phrase does NOT match. Before concluding "never reached SQL", confirm the control requests in your window match the SAME prefix as the suspect. A zero-rows 200 with SQL present is usually just a filter matching nothing — bisect the request body (replay, drop one criterion at a time) before blaming the pipeline.

13. **A Jira ticket's description sometimes links directly to a Graylog search or
    message** — parse that URL instead of re-deriving a query from scratch, and instead
    of treating it as just a link for a human to click:
    - A stream-search link (`.../streams/<stream-id>/search?rangetype=absolute&from=<ISO>&to=<ISO>`)
      — pull the stream id and `from`/`to` straight out of the query string, then hit
      `/api/search/universal/absolute` with those exact values (per Step 2, this instance
      needs the `absolute` endpoint directly for a fixed window, not the relative wrapper
      script).
    - A single-message link (`.../messages/<index>/<message-id>`, the same shape Step 6
      tells you to create for a new ticket) — that's one specific log row, not a query;
      widen to an absolute search around its timestamp if you need surrounding context.

14. **Need a repo's `application` field value? Check
    [APP-NAME-MAPPING.md](APP-NAME-MAPPING.md) first, don't free-text search for it.**
    Several repos don't follow the obvious `<repo>-api` pattern, so guessing from the
    repo name isn't reliable. That file also lists repos confirmed absent from Graylog
    entirely (S3-hosted frontends, dormant/empty repos), so you don't waste a search
    looking for them.

## Do NOT

- Guess the query syntax — Lucene field:value, `AND`/`NOT`/quoted phrases, same as the UI.
- Assume `/api/search/messages` works — 404s on this instance's version, always use `/api/search/universal/relative` here.
- Print `$GRAYLOG_PAT` anywhere (commands, chat, logs).
- Proceed without asking if `$GRAYLOG_PAT` is unset — same stop-and-wait convention as `$BITBUCKET_API_KEY` elsewhere in this harness.
- Trust a quoted GUID field match (`CorrelationId:"..."`) as exact — this field isn't indexed as an exact keyword here, so phrase-quoting returns unrelated hits. For precise correlation, use a narrow absolute time window instead (see above), not a GUID phrase filter.
