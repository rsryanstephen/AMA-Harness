---
name: ama-bitbucket-api
description: Authenticating to the Bitbucket REST API (Pipelines, repos, etc.) for AMA_APP repos — use whenever calling api.bitbucket.org directly (checking a pipeline run/status, fetching build logs, triggering a pipeline) and hitting a 401, or before writing a curl call against it for the first time. NOT for git clone/fetch/push over SSH — see [[commit-ticket]] for that (a different auth layer entirely).
---

# Bitbucket REST API auth

## The mistake: Bearer auth with an Atlassian API token

```bash
curl -sS -H "Authorization: Bearer $BITBUCKET_API_KEY" \
  "https://api.bitbucket.org/2.0/repositories/<bitbucket.org from harness-config.json>/<repo>/pipelines/<id>"
```
Fails: `HTTP 401`, `{"type": "error", "error": {"message": "Token is invalid, expired, or not supported for this endpoint."}}`.

**Why it fails**: `$BITBUCKET_API_KEY` is an **Atlassian API token** (starts `ATAT`, ~192
chars) — that token type is designed for HTTP **Basic** auth (`email:token`), not Bearer.
The 401 message is misleading — it reads like the token itself is bad, but the token is
fine, only the auth scheme is wrong.

## The fix: Basic auth, username = your Atlassian account email

```bash
curl -sS -u "<user.email from harness-config.json>:$BITBUCKET_API_KEY" \
  "https://api.bitbucket.org/2.0/repositories/<bitbucket.org from harness-config.json>/<repo>/pipelines/<id>"
```
Confirmed working (`HTTP 200`) for reading pipeline status, fetching step logs, and
triggering a new pipeline run (`POST .../pipelines/`) — same auth for all three.

## Gotcha: pipeline log downloads redirect

Step log endpoints return `HTTP 307` (redirect to an S3-hosted log) — pass `-L` to `curl`
to follow it, or the response body will just be a redirect stub, not the actual log.

## Quick sanity check before assuming a token is bad

```bash
printf '%s' "$BITBUCKET_API_KEY" | head -c 4; echo "...(len=${#BITBUCKET_API_KEY})"
```
`ATAT...(len=192)` → Atlassian API token → Basic auth, not Bearer. If a 401 shows up
despite using Basic auth with the right email, then the token itself may actually be
expired/revoked — check that before re-diagnosing the auth scheme again.

## Creating a PR with reviewers

Same auth as above. **Always include `bitbucket.defaultPrReviewers` from
`harness-config.json` on every PR Claude raises, per explicit user
instruction** — add on top of any PR-specific reviewers (e.g. the ETL-fix ones below),
don't replace them.

```bash
curl -sS -u "<user.email from harness-config.json>:$BITBUCKET_API_KEY" \
  -X POST -H "Content-Type: application/json" \
  "https://api.bitbucket.org/2.0/repositories/<bitbucket.org from harness-config.json>/<repo>/pullrequests" \
  -d '{
    "title": "PROJ-XXXXX: <description>",
    "source": {"branch": {"name": "<feature-branch>"}},
    "destination": {"branch": {"name": "develop"}},
    "reviewers": [{"uuid": "<default reviewer uuid>"}, {"uuid": "<any other reviewer uuid>"}]
  }'
```

Reviewer identity is by Bitbucket **UUID** (`{xxxxxxxx-...}`, from `workspaces/<org>/members`),
not email/Jira account id — a different ID space per system, don't conflate them. See
[[ama-graylog-search]]'s `KNOWN-SIGNATURES.md` (rule 5) for the confirmed AMA_ETL fix
reviewers, cached in `harness-config.json`'s `bitbucket.etlFixReviewers` — union those
in too when raising an ETL-fix PR specifically, don't drop the default for a
special-case one.

**Never approve the user's own PR using the user's own Bitbucket auth.**

## Posting a PR comment

```bash
curl -sS -u "<user.email from harness-config.json>:$BITBUCKET_API_KEY" \
  -X POST -H "Content-Type: application/json" \
  "https://api.bitbucket.org/2.0/repositories/<bitbucket.org from harness-config.json>/<repo>/pullrequests/<id>/comments" \
  -d @body.json
```
`{"content":{"raw":"<comment>"}}`, optionally with `"inline":{"path":"<file>","to":<line>}`
to anchor it on a specific line. Approve: same auth, `POST .../pullrequests/<id>/approve`.

**Non-ASCII (em dash, emoji) in the comment body gets corrupted if passed as a literal
bash argument** (`—` → replacement char, `🤖` → `??`). Write the raw
comment text to a file with the `Write` tool (not shell), then build the JSON body with
`jq -Rs '{content:{raw:.}}' body.txt > body.json` — never a literal non-ASCII character
in a `jq -n`/curl argument.

**This isn't just human-typed text — it's any dynamic value on a command line, at any
stage of the pipeline.** Confirmed on Jira write scripts: a fetched API response
re-injected via `jq --arg`/`--argjson` mangles multi-byte UTF-8 the same way (a curly
apostrophe became a literal `?`). Separately, `curl -d "$var"` (a finished JSON body
held in a bash variable) can itself get corrupted or rejected crossing into `curl.exe`
on this Windows/Git-Bash setup — triggered by certain byte patterns even in plain ASCII
(a URL containing colons caused a 400 "error parsing JSON"). **Rule: every dynamic
value — payload in, response fetched, body out — goes through a file, never a
command-line argument or a bash variable interpolated into `-d`.** Read with
`jq ... "$FILE"`, write with `curl -d "@$FILE"`.

Delete a bad comment: `DELETE .../pullrequests/<id>/comments/<comment-id>` → `204`, same
auth. Works on a merged PR too — the diff stays browsable and commentable after merge.

## Scope

This is a general Bitbucket REST API convention (not machine-specific) — applies to any
AMA_APP repo's pipelines, not just the one it was first found on.
