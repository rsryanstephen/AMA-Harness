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

## Pipeline variables come back in PLAINTEXT — select `.key`, never `.value`

`pipelines-config/variables/` (workspace) and `pipelines_config/variables/` (repo) return
the live value of every variable NOT flagged `secured`. In this workspace that includes an
AWS key pair with ECR push rights, `OCTOPUS_CLI_API_KEY` and an `APP_PASSWORD`
(PROJ-15426).

Checking whether a variable EXISTS is the normal reason to call these — so print names only:

```bash
... | jq -r '.values[] | "\(.key) \(if .secured then "(secured)" else "(PLAINTEXT)" end)"'
```

Dumped `.value` anyway? **Redact it yourself, immediately, without asking:**
`bash ~/.claude/scripts/redact-leaked-secrets.sh` — see [[credential-leak-redact-dont-ask]].
No rotation needed for the transcript alone; it is not git-tracked. Same class as
[[ama-ui-verify]]'s `request.postData()` leak — different surface, no gate covers either.

## Push landed but no pipeline ran

`pipeline-status.sh <repo> <branch> --sha <pushed-sha>` -> `NO PIPELINE` with the API answering =
Bitbucket lost the push event. Start the branch's default pipeline:
`bash ~/.claude/skills/ama-bitbucket-api/scripts/trigger-branch-pipeline.sh <repo> <branch>`.
Server-side, not your network. Full handling: [[commit-ticket]]'s `GIT-TRANSPORT.md` (2026-10-15).

## Triggering a CUSTOM pipeline that takes variables

`run-pipeline.sh` does NOT pass them — it sends `target.selector` only, so a pipeline
declaring `- variables:` gets empty values and fails its own guards. POST it yourself,
reusing `lib-bitbucket.sh` for auth:

```json
{"target":{"type":"pipeline_ref_target","ref_type":"branch","ref_name":"master",
 "selector":{"type":"custom","pattern":"<name>"}},
 "variables":[{"key":"IMAGE_VERSION","value":"36"}]}
```

## Step failed INSIDE a CI helper script? That script is in a repo — go fix it

`package.sh`, `create-release.sh`, `build-and-publish.sh`, `check-code-coverage.sh`,
`build-lambda.sh`, `code-artifact-auth.sh` are NOT magic. They live in the `pipelines`
repo under `custom-images/base-image/`, `COPY`'d into the ECR image
(`yourproduct:yourproduct-pipelines-NN`) by `base-image-dockerfile`. Read and fix them there.

Don't conclude "baked into a private image, unfixable" — that was wrong once already
(PROJ-15418).

Rollout is fully manual, and slow: no CI builds the image, `custom-images/README.md`
holds the docker build/tag/push block, and nothing propagates a new tag into consuming
repos — each `bitbucket-pipelines.yml` pins its own `yourproduct-pipelines-NN`, so the
fleet sits on a spread of tags. A fix that must land TODAY goes in the consuming repo's
own yml step; the image fix is the durable half, not the fast one.

## Pipeline stuck "Queued" forever, no reason shown? Check `clone:` placement

- `clone: lfs: true` on a STEP -> whole pipeline sits Queued indefinitely, first step too, no
  error, 0 build seconds (export-cohort #44-#46, 2026-10-12). Same config minus it started in 30s.
- Put `clone: lfs: true` at TOP level only. Started in 15s.
- Probe: re-run previous commit (`POST /pipelines` target `pipeline_ref_target` + full 40-char
  `commit.hash`; default-pipeline repos take NO `selector`).
- Image ships an LFS pointer (134-byte text, "not a valid Package file") -> clone lacks LFS.
  Bitbucket blocks pushing a >=100 MB plain file, so LFS fetch is the only route.

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

**User as reviewer = impossible**: PR is authored by the token owner (the user) -> 400
`"<name> is the author and cannot be included as a reviewer."`. Create with no reviewers,
send the link (2026-10-28).

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

**Never approve ANY PR** -- policy 2026-10-16: AI agents may not approve, may merge.
Gate-enforced (`bitbucket-pr-approve-gate.sh`). Review requests -> `scripts/pr-review-watch.sh`
+ [[ama-pr-review]] (comment + advise; user approves).

## Merging on approval -- `scripts/pr-merge-watch.sh`

Every PR Claude opens is merged the moment a reviewer approves (user instruction 2026-10-14).
`pr-created-reviewer-dm-reminder.sh` starts the watcher detached right after creation; you do
NOT poll the PR. It merges (merge commit, source branch closed) when at least one REVIEWER
has approved and nobody has requested changes, then wakes the origin session with a durable
reminder naming the follow-ups (ticket transition, library version sync, Octopus deploy the
merge queued) -- or, with a `--post-merge` record, "work remains, don't move the ticket, reopen session X". Declined/superseded -> reminder, no merge. Refused merge (branch restriction,
red build, open task) -> logged, retried next poll. Build still INPROGRESS on the source tip
(commit statuses) -> no POST, re-check every 60s up to 2h per tip, then attempt anyway (2026-10-21:
approval mid-build spent the one-shot refusal reminder on a transient). Dead process ->
`hooks/pr-watch-check.sh` restarts it from `harness-state/prs/pending/`. Log: `harness-state/prs/<slug>-<id>.log`.

```bash
bash ~/.claude/skills/ama-bitbucket-api/scripts/pr-merge-watch.sh <repo> <pr-id> --once   # merge now if approved; exit 3 = not yet, 5 = build running
bash ~/.claude/skills/ama-bitbucket-api/scripts/pr-merge-watch.sh <repo> <pr-id> --sid <session-id>   # the loop the hook starts
bash ~/.claude/skills/ama-bitbucket-api/scripts/pr-merge-watch.sh <repo> <pr-id> --sid <session-id> --post-merge "<what is left>"   # record only
```

**Creating session decides at PR time: work left after the merge?** (user rule 2026-10-28)
- Yes -> `--post-merge` above (or `PR_POST_MERGE="<what>"` on `create-bitbucket-pr.sh`). Merge reminder then says do NOT move the ticket and names this session + its `claude -r` command for the user to reopen. User can close the session meanwhile.
- No -> nothing to record; reminder = generic list, ticket transition included, any session does it.

`HTTP 400 "1 failed merge check"`, `merge_checks: ["1 successful build on last commit"]` = a repo
setting, not a branch restriction. A repo with NO pipeline (<repository>-octopus, 2026-10-14)
can never satisfy it: the user bypasses in the UI or drops the check. Never fake a commit status.

Open PRs with their approvals, all repos: `workspaces/<org>/pullrequests/<selfUuid>?state=OPEN`
lists them but its `participants` carry NO approval flags -- read each PR individually.

## Posting a PR comment

```bash
curl -sS -u "<user.email from harness-config.json>:$BITBUCKET_API_KEY" \
  -X POST -H "Content-Type: application/json" \
  "https://api.bitbucket.org/2.0/repositories/<bitbucket.org from harness-config.json>/<repo>/pullrequests/<id>/comments" \
  -d @body.json
```
`{"content":{"raw":"<comment>"}}`, optionally with `"inline":{"path":"<file>","to":<line>}`
to anchor it on a specific line. Approve: NEVER (see above).

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
