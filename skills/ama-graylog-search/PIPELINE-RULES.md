# Suppressing an alert — pipeline rule mechanics

Confirmed live against this instance (Graylog 4.2.6), <harnessEpicKey>. Read this before
hand-rolling any pipeline-rule call — the write path has sharp edges the UI hides.

## The one pipeline that matters for support-alert suppression

- **Pipeline**: `"alert suppress"`, id in `.graylog.suppressPipelineId`
  (`harness-config.json`) — currently `<suppressPipelineId>`. Processes the `All
  messages` stream.
- **Stage 0 is the only stage** (`match either` — any one rule firing is enough), and it
  is where every new suppression rule goes. There is no stage 1+ to choose between.
- A rule's effect is `set_field("known_issue", "<reason>")` — this is what keeps a
  message off the L1 support alert (see `GRAYLOG-REFERENCE.md`'s `known_issue` note).

## Writing a rule: use the scripts, not raw curl

`hooks/graylog-write-gate.sh` denies a hand-rolled `curl -X PUT/POST/DELETE` against
`/api/system/pipelines/...` for exactly this reason. Use:
- `scripts/graylog-rule-get.sh <id|title>` — read one rule.
- `scripts/graylog-rule-write.sh update <id>` / `create` — backs up the current rule,
  **parse-validates the new source first** (`/rule/parse`, persists nothing — a syntax
  error can never reach the live pipeline through this script), writes, reads back and
  diffs. Payload from `~/.claude/harness-state/tickets/.graylog-rule-payload.json` (Write tool, never shell —
  same reasoning as `jira-edit-issue.sh`'s fixed-payload-file convention).
- `scripts/graylog-pipeline-attach-rule.sh "<rule title>"` — **creating a rule does NOT
  attach it.** A pipeline's `source` field lists rule titles explicitly
  (`rule "PROJ-MBdev"` … `end`); a new rule with nothing referencing its title never
  fires, silently. This script inserts the `rule "<title>"` line and is idempotent.

## Sharp edges

- **API route ≠ UI route.** The Graylog web UI shows `/system/pipelines/rules/{id}`
  (plural) — that's HTML. The API is `/api/system/pipelines/rule/{id}` (singular).
- **Writes need `X-Requested-By`** or every PUT/POST 400s:
  `"CSRF protection header is missing"`. All three scripts above set it; a raw curl
  usually forgets it on the first try.
- **Stage references are BY TITLE, not id.** Renaming a rule silently detaches it from
  every pipeline that names it — no error, the rule just stops firing. `graylog-rule-write.sh`
  refuses an `update` whose parsed title doesn't match the payload's declared title for
  exactly this reason. Never rename a rule that's already attached to a pipeline without
  also fixing the pipeline's `source`.
- **Never pin a rotating identifier (a GUID, a request id, a timestamp) into a
  suppression rule.** Confirmed live 2026-08-22: a rule suppressing
  `<repository>-api-testing`'s negative-delete-report test pinned one fixture GUID; the
  tests mint a fresh GUID per run (11 distinct GUIDs seen across 14 days, 10 from one
  run), so the rule went stale the same day it was written. Match the **shape** instead —
  `regex("...[0-9a-fA-F-]{36}...", to_string($message.message)).matches` — never the
  literal value.
- **`regex(...).matches` needs an explicit boolean comparison in an `OR` chain** on this
  version — `regex(...).matches OR contains(...)` 400s with `incompatible_types`
  ("Object" vs "Boolean"); write `(regex(...).matches == true) OR contains(...)` instead.
  Confirmed live 2026-08-22.
- **`/rule/parse` before every write, always** — it's the only thing standing between a
  typo and a broken production suppression rule, and it costs nothing (persists
  nothing).

## Every new suppression rule → tell #<amaSupportChannelName>

A suppression rule silently changes what reaches the support mailbox/alert stream — the
absence of an alert looks identical to "nothing happened" unless someone announces it.
After writing OR attaching a new/changed rule (not a read-only investigation), post one
Slack message to `#<amaSupportChannelName>` (real send, no draft — this is public info for the whole
support-facing team, not a personal DM): what signature is now suppressed, why it's
benign, and a link/reference to the evidence (a pipeline run, a ticket, a Graylog
message link per `SKILL.md`'s ticket-linking convention). Keep it as terse as every other
Slack convention in this harness — one signature, one reason, one link.
