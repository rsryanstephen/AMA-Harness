---
name: ama-jira-api
description: Direct Jira REST API reads AND writes (fields, transitions, JQL search, create/edit/transition/comment) via personal API token -- replaces Atlassian MCP for both. Reads trim through jq. Writes go through a fixed file (gate-protected). Confluence page-body writes/addWorklogToJiraIssue stay MCP; Confluence attachments/archiving are direct REST -- see [[ama-confluence-api]].
---

# Jira REST API (direct)

Atlassian MCP results inject into context verbatim, and Jira's API shape has fixed
nested overhead (avatarUrls, `self`, `statusCategory`) no `fields` param strips --
expensive. These scripts pipe through `jq` first -- only the trimmed value reaches
context.

## Auth: Basic, not Bearer -- same token, same gotcha as ama-bitbucket-api

`$ATLASSIAN_API_TOKEN` (env var, same convention as `GRAYLOG_PAT`/`BITBUCKET_API_KEY`)
is an Atlassian API token (starts `ATAT`, ~192 chars) -- Basic auth (`email:token`),
never Bearer. See [[ama-bitbucket-api]] for why Bearer fails misleadingly. Confirmed
empirically: `BITBUCKET_API_KEY` and `ATLASSIAN_API_TOKEN` do NOT substitute for each
other (both 401 against the other's API) -- keep both env vars.

## Read scripts

```bash
bash ~/.claude/skills/ama-jira-api/scripts/jira-get-transitions.sh <ticket-key>
bash ~/.claude/skills/ama-jira-api/scripts/jira-get-issue.sh <ticket-key> "<fields-csv>"
bash ~/.claude/skills/ama-jira-api/scripts/jira-search.sh "<jql>" "<fields-csv>" [maxResults]
```

All three print flattened, tab-separated output -- nested fields (`assignee`, `status`)
print `.displayName`/`.name`, never the full object. Verified live against real tickets.

## Write scripts — payload via a FIXED FILE, never a command-line argument

Same reason `ama-bitbucket-api/SKILL.md` says to write PR comment text to a file first,
not shell: quote/non-ASCII corruption. It's also what lets the 3 write-gated `PreToolUse`
hooks keep reading structured JSON (from the file) instead of parsing it back out of
command text -- a far more fragile surface, already the source of two quote-blind bugs
this harness has hit and fixed.

**Always**: use the `Write` tool to put the JSON payload at
`~/.claude/.jira-write-payload.json`, THEN invoke the script. Each script deletes the
file after a **successful** call only (fixed 2026-08-13 -- they used to consume it on
failure too, forcing a full payload rewrite to retry) -- never leave a stale payload
another call could reuse.

**`jira-edit-issue.sh` is v3 -- a `description` field in its payload must be ADF, not
wiki markup** (400: "Operation value must be an Atlassian Document"). For a wiki-markup
description REPLACE, skip the script and PUT the same `{"fields":{...}}` payload file to
v2 directly (confirmed 204):
```bash
curl -sS -X PUT -u "<user.email>:$ATLASSIAN_API_TOKEN" -H "Content-Type: application/json" \
  --data-binary "@$HOME/.claude/.jira-write-payload.json" \
  "https://yourorg.atlassian.net/rest/api/2/issue/<key>"
```
(For appending sections to a rich description, [[jira-append-description]]'s ADF
read-modify-write remains the right tool.)

**Same rule applies to the request body these scripts build, not just the caller's
payload** -- see [[ama-bitbucket-api]]'s expanded corruption note. Every script here
writes its built body to a temp file and PUTs/POSTs with `-d "@$file"`, never
`-d "$var"`. Follow that pattern in any new write script added here.

```bash
bash ~/.claude/skills/ama-jira-api/scripts/jira-create-issue.sh <project-key> <issuetype>
bash ~/.claude/skills/ama-jira-api/scripts/jira-edit-issue.sh <ticket-key>
bash ~/.claude/skills/ama-jira-api/scripts/jira-append-description.sh <ticket-key>
bash ~/.claude/skills/ama-jira-api/scripts/jira-transition-issue.sh <ticket-key> <transition-id>
bash ~/.claude/skills/ama-jira-api/scripts/jira-add-comment.sh <ticket-key>
```

Payload file shapes:
- `jira-create-issue.sh`: `{"summary": "...", "assignee_account_id": "...",
  "description": "wiki markup", "additional_fields": {"<epicLinkFieldId>": "PROJ-XXXXX",
  "fixVersions": [...]}}` — posts to `/rest/api/2/issue` (not v3 like the rest of this
  file) since `description` there is a plain wiki-markup string, confirmed round-tripping
  as markup (not ADF) on this instance. Template + required sections: [[commit-ticket]]'s
  `TICKET-TEMPLATE.md`, gate-enforced by `jira-ticket-description-gate.sh`.
- `jira-edit-issue.sh`: `{"fields": {"fixVersions": [{"name": "release/128.0.0"}]}}` --
  whole-field replace.
- `jira-append-description.sh`: `{"sections": [{"heading": "Acceptance criteria",
  "bullets": ["...", "..."]}]}` -- appends missing sections to an **existing**
  description via v3 ADF read-modify-write, leaving every pre-existing node untouched.
  Use this instead of `jira-edit-issue.sh` whenever the description may already hold rich
  content (media/tables/smart links) that a v2 wiki-markup round-trip would render
  lossily. Idempotent -- skips any section whose heading already appears.
- `jira-transition-issue.sh`: no file needed for a bare transition; if the target
  transition requires fields (see `commit-ticket`'s "missing required information"
  case), same `{"fields": {...}}` shape.
- `jira-add-comment.sh`: `{"body": "plain text"}` -- wrapped into ADF internally.

Get the transition ID first via `jira-get-transitions.sh` — never hardcode, per-ticket
(see `commit-ticket/SKILL.md`).

## Version descriptions — set on every hotfix/release version

Jira version `description` = Octopus Releases page's Description column. Once a
`release/*`/`hotfix/*` version is confirmed created (or found already existing) with an
empty description, write one — don't leave it blank. Hotfix = 1-3 plain sentences: the
defect + the fix (name the real file/component). Release = the work grouped by theme
(from its `fixVersion` ticket list). Plain direct language — no "a round of fixes"
meta-phrasing, no restating the ticket title.

```bash
# id from: GET /rest/api/3/project/PROJ/versions (match .name)
curl -sS -X PUT -u "<user.email>:$ATLASSIAN_API_TOKEN" -H "Content-Type: application/json" \
  "https://yourorg.atlassian.net/rest/api/3/version/<id>" -d @payload.json
# payload.json: {"description": "..."}  -- payload via file, per the rule above
```

## Scope — Confluence writes and worklogs stay on MCP

`updateConfluencePage`, `createConfluencePage`, `addWorklogToJiraIssue` are **not**
scripted here (deliberate deferral: lower call-frequency, and Confluence's REST update
needs the current page version number first — a separate gotcha) — keep using MCP for
those.

## Response-shape gotchas

- Changelog `.created` timestamps = LOCAL offset format (`+0200`, verified live) --
  compare with local-time bounds, never UTC ones. Bucket by LOCAL calendar day.
- Bulk MCP `searchJiraIssuesUsingJql` (~60 issues) blows the tool-result token cap even
  with a narrow `fields` list (each issue carries full description/parent/epic objects).
  When it dumps to a file: don't `Read`/`grep` the raw JSON -- `node -e` a one-off script
  that `JSON.parse`s the file and prints only the needed fields per issue. (Or avoid MCP
  entirely -- `jira-search.sh` above trims through jq.)
- `notifyUsers=false` on a v3 issue PUT/POST needs admin or project-admin rights --
  expect a 403 without them. Every write here notifies watchers normally.

## Token-scope gotcha

A Bitbucket-scoped token 401s against Confluence's REST API (see
[[ama-team-meeting-notes]]'s Confluence section) -- a scope issue, not a fundamental
block. A properly scoped `ATLASSIAN_API_TOKEN` returns 200 for every script above,
reads and writes.
