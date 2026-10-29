# AMA Backlog page — write mechanics

Page: `atlassian.backlogPageId` / `atlassian.cloudId` in `harness-config.json`.
https://yourorg.atlassian.net/wiki/spaces/HO/pages/<backlogPageId>/AMA+Backlog

## When this applies

**Placement is now automatic, both directions** — `jira-create-issue.sh` adds every new ticket
(section from issuetype, position `BACKLOG_POSITION`, else `last` + a `BACKLOG PLACEMENT OWED`
line), and `jira-transition-issue.sh` prunes it on
`indeterminate`/`done` and re-adds on `new`. So "worked immediately this session" needs no
judgement: it gets added, then removed by the transition. `BACKLOG_SKIP=1` opts out;
`BACKLOG_SECTION` overrides the section. Epics are skipped by issuetype on create. The
deliberately-off-page standing tickets (Regressions bucket, harness test fixture) are
skipped by key on the *transition* path only -- they already exist, so no create can
produce their keys. Neither path enumerates open tickets: create adds the one key it just
made, and the transition reads that one issue's status.

Read the rest for hand-placement — promoting an entry to `first`, demotions, and the section
anatomy every path depends on.

Read/pickup path ("backlog" / "pick up tasks from the backlog") lives in
[[ama-backlog-page]], not here — its one entry point is `scripts/backlog-candidates.sh`
(both pages, document order, LIVE statuses, re-run at every offer) — but the section
anatomy and non-ticket blocks below
(Placement, Insertion anchor, "Not insertion targets") apply to both paths. **New** tickets
are only ever inserted onto THIS page, never the "AMA Backlog — Deferred" child page
[[ama-backlog-page]] also reads. Deferred is written to only by the two sweeps below —
`backlog-prune-resolved.sh` (removals) and `backlog-demote-ticket.sh` (demotions).

## Rebalancing — a promotion is paid for by a demotion

Standing user rule (2026-09-04): **the main page does not grow.** Moving a ticket up from
Deferred costs an existing main-page entry, one for one. Asked to "look at the priorities"
or promote something off Deferred, do both halves or neither.

```bash
bash ~/.claude/skills/commit-ticket-jira/scripts/backlog-demote-ticket.sh KEY [deferred-section] [--dry-run]
```
Default target section is `Low Priority` (Deferred's lowest tier). It moves the entry's
paragraph node **verbatim**, so a hand-written annotation ("This never re-occurred", "Is
this still needed?") travels with the ticket — those notes are the justification for the
demotion, so losing them would destroy the evidence. Same guards as the add script, on both
pages, plus a refusal if the key is listed more than once (see "Not insertion targets" —
`14729` and `14731` each appear twice, and removing one copy leaves the key still on the
page while the delta guard reads −1). Deferred is written first: if the second write fails
the key is briefly on both pages, which the pickup path dedupes harmlessly, whereas
main-first would drop it off both. `--dry-run` first, always.

**Which entries are demotable.** Not a judgement call — the main page self-identifies its
weakest tier through the user's own annotations in the two `Low Priority` sections. Verify
the promotion candidate is still live (read the ticket, check the code/infra actually still
exists) before spending a slot on it; the Deferred page's ordering came from an unverified
2026-08 LLM pass, and a stale `Critical` stamp is not evidence. Jira's `priority` field is
useless as a cross-page comparator — it's unused default on the main page (where document
order is the ranking) and a real 2023–24 grooming stamp on Deferred.

## Section mapping

- Bug → `Bugs`
- Task / tech-debt → `Tech Debt`
- Story / feature → `Features`
- Never `Previous requests for new features` (historical, not active backlog).
- Never the `Low Priority …` variants unless the user says so.

## Placement

**Automatic — do NOT propose a slot and wait for approval.** Explicit user instruction
(2026-08-18): placement no longer needs manual sign-off. Place it, then say where it went
in one line afterwards.

**Slot = priority fit, judged by the caller** (user rule 2026-10-22, replaces "always last").
Position on this page IS priority. Before creating: `backlog-section.sh <section>` prints the
section in page order (rank, key, status, type, Jira priority, summary, hand-written note);
compare the new ticket's impact with its neighbours (production > QA, security / data loss /
wrong numbers > slow > cosmetic; the notes carry the user's own ranking) and pass
`BACKLOG_POSITION=before:<KEY>` (or `first`, or `last` only when it ranks lowest) to
`jira-create-issue.sh`. Jira `priority` is shown but is mostly an unused default here — never
the deciding signal for slot order (it IS the keep signal for epic-child duplicates, below). Forgot? The create appends last and prints `BACKLOG PLACEMENT OWED`;
re-slot with `backlog-move-first.sh <KEY> --before <KEY2>`. Still no approval needed.

**Epic children stay off the page** (user rule 2026-10-22). An `epicLink`/`parent` ticket is not
listed; `backlog-epics-sync.sh --ensure <EPIC>` puts the epic in the **Epics** index instead (top
of the page, above Features; pickup offers its Open children first, in index order). Exit 3 =
epic not indexable (started/resolved, or the harness epic) → the child is listed like any ticket.
Full sync `backlog-epics-sync.sh [--dry-run]` (run it with the weekly prune): index = Open/To Do
epics with an Open/To Do child and child activity in the last year; a DORMANT epic (no such
activity, not on the page) is not indexed and its unstarted children are listed one by one on the
Deferred page instead. Re-slot an epic in the index with `backlog-move-first.sh <EPIC> --before <KEY>`.

**The index is ranked by priority, not by age** (user rule 2026-10-22) -- it is pickup order.
`--ensure` appends a new epic last and prints `EPIC PLACEMENT OWED`; re-slot it by judgement.

**Duplicates -- standing rule (user 2026-10-22):** a child of an indexed epic is listed by itself
as well ONLY when its Jira priority is Show-stopper or Critical (otherwise its priority is lost
among the epic's children). Every other indexed-epic child is removed from both pages by the full
sync. **User says an epic child is high priority / "list it at the top" / "standalone entry" → in the
SAME step raise its Jira priority to Critical** (`jira-edit-issue.sh`, `{"fields":{"priority":{"name":"Critical"}}}`)
and verify with `backlog-epics-sync.sh --dry-run` (key must NOT be in the removal list); placing it on
the page alone is undone by the next sync (PROJ-15861, 2026-10-27). Raising alone does not
list it either -- only create-time adds; the full sync prints `HIGH-PRIORITY EPIC CHILDREN NOT LISTED`
for any it finds off the page: slot each near its section top, or lower its priority. Jira priority is meaningful because the creator must judge it: `jira-create-issue.sh`
refuses a payload without `additional_fields.priority` (scale in commit-ticket SKILL.md). For an
older ticket, judge it on its merits before the sync removes it -- a stored `Normal` is often
just Jira's default (15817/15818/15820/15850 were live security holes stored as Normal/Minor).

Run the script, don't hand-splice:
```bash
bash ~/.claude/skills/commit-ticket-jira/scripts/backlog-add-ticket.sh <TICKET-KEY> [section] [last|first]
# ANNOTATION="one-line note" env -> appended as plain text after the card (2026-10-08)
# BACKLOG_PAGE_ID=<id> env -> another page with the same anatomy (the Deferred page)
```
Idempotent (exits 0 without writing if the key is anywhere on the page), aborts *before*
writing if the `mediaSingle` count or the ticket-key delta is wrong, and re-reads to verify
afterwards. It encodes everything in the sections below — read those only when debugging it
or if the page structure changed.

**Re-prioritising an entry that is already on the page** (add-ticket exits 0 on it,
demote-ticket moves between pages) — top of its own section, or of another section on the
same page with `--section` (prefix match, e.g. `"Low Priority Tech Debt"`), same guards, `--dry-run` first:
```bash
bash ~/.claude/skills/commit-ticket-jira/scripts/backlog-move-first.sh <TICKET-KEY> [--section "<name>"] [--dry-run]
```

## Removing resolved tickets — both pages, opposite rule to insertion

Standing user rule (2026-09-04): **no Done ticket on the backlog anywhere.** Unlike
insertion, this covers the Deferred child page too (`atlassian.deferredBacklogPageId`) —
a stale entry there costs every pickup pass the same fetch and status round-trip.

```bash
bash ~/.claude/skills/commit-ticket-jira/scripts/backlog-prune-resolved.sh              # sweep both pages
bash ~/.claude/skills/commit-ticket-jira/scripts/backlog-prune-resolved.sh KEY [KEY...] # targeted
bash ~/.claude/skills/commit-ticket-jira/scripts/backlog-prune-resolved.sh --dry-run …  # report only
```

Sweep mode resolves every key on both pages against `statusCategory = Done` (covers Done /
Closed / Canceled without hardcoding status names). Same guards as the add script — ADF
only, mediaSingle count asserted, re-read to verify — plus a set-difference check that
exactly the intended keys went, since a count-only assert passes when one key is silently
swapped for another.

`hooks/backlog-stale-check.sh` schedules it (`backlogStale.checkDays`, default 7). A
transition trigger deliberately isn't used: measured 2026-09-04, 4 of 5 stale entries were
closed in another session or in the Jira UI, where no PostToolUse hook can see them.

The ADD direction for QA-raised tickets is `backlog-qa-sweep.sh` (biweekly task, see
PORTABILITY.md); it shares prune's status list via `backlog-statuses.sh` so the two never fight.

Never a bulk re-sort of the existing ~50 entries (hand-curated with inline commentary — a
wholesale re-sort is a large, unreviewable edit nobody asked for; offer separately if
wanted).

## Insertion anchor — the part most likely to go wrong

Sections are top-level `<li>` items in bulleted lists, **not headings** — `Features`,
`Bugs`, `Tech Debt:` etc. are each an `<li>` whose own `<p>` text is the section name
(some carry a trailing colon, some don't — confirmed live, match by prefix not exact
string), holding a nested `<ul>` of ticket `<li>`s. Empty `<p>` paragraphs sit between
several sections (a zero-width non-joiner in the markdown render) → the page is several
sibling top-level `<ul>`s, not one continuous list.

Rule: find the `<li>` whose own `<p>` text starts with the section name, insert a new
`<li>` into **that** `<li>`'s child `<ul>`. Never "the Nth `<ul>` on the page" — confirmed
live (2026-08-06) the page has several sibling top-level `<ul>`s.

**`Bugs` nests one level deeper than every other section.** Its child `<ul>` holds a
*single* empty-text `<li>` whose only child is another `<ul>`, and the bug tickets live in
that inner list. Appending to the outer list makes the entry a sibling of the wrapper —
wrong depth, and the `+1` key-delta guard passes either way, so it fails silently.
`backlog-splice.js` descends the wrapper (max 2 levels, then it errors) and asserts it did
not land on a wrapper. Confirmed live 2026-09-04 (v131). `Tech Debt:` has direct items and
is unaffected.

Prefix matching is safe for `Bugs` and `Tech Debt` despite `Low Priority Bugs` /
`Low Priority Tech Debt:` also existing — `"low priority tech debt"` does not
`startsWith("tech debt")`, and the matcher walks in document order. Checked 2026-09-04;
don't re-derive it.

Not insertion targets — write path only, still read on pickup ([[ama-backlog-page]]
harvests keys from these too):
- Trailing free-form blocks (Terraform/`PROJ-14731`, the "Automated API Tests"
  writeup) — prose, not a ticket list.
- `Tech Debt`'s nested ".Net 6 / two repositories" sub-block — not a ticket slot, skip
  it when counting position.

Confirm the live markup with `getConfluencePage(contentFormat="html")` before writing —
don't rely on inference from a markdown render, it hides the real `<li>`/`<ul>` nesting.

## Write

Reuse [[ama-team-meeting-notes]]'s confirmed Confluence mechanics — don't invent a
second pattern.

**This page holds an embedded image** in the Terraform/`PROJ-14731` block — a
full-body `contentFormat="html"` write drops it (converter bug, drops media nested in a
`<li>`). See [[ama-confluence-api]] before writing; re-verify the image after.

**Write ADF, not HTML.** `contentFormat="html"` destroys this page's Terraform
screenshot — every time, not occasionally: the converter silently drops a `<figure
data-type="media-single">` nested inside a `<li>`, and that image lives inside the
Terraform `<li>`. Confirmed live 2026-08-17 (v88): body written back faithfully, version
bumped, image gone, no error. **Gate-enforced** (`confluence-media-gate.sh`) — an html
write to this page is now denied outright, so this is not a rule to remember.

Never markdown either: it degrades `<custom data-type="smartlink">` nodes and turns the
image into an unwritable `blob:` URL.

1. `getConfluencePage`, `contentFormat="adf"` → save the body to a file. Don't read it
   into a reply and retype it; a hand-transcribed body is how ~60 smartlinks get lost.
2. Splice **one `listItem`** into the Bugs/Tech Debt/Features list with **jq**, not by
   hand. Locate the section by its own text, then insert:
   ```bash
   jq --argjson li "$NEW" '.content[N].content[0].content[1].content |= ([$li] + .)' body.json
   ```
   New ticket link node — omit `localId`, Confluence assigns its own (reusing an existing
   one is the real corruption risk):
   `{"type":"paragraph","content":[{"type":"inlineCard","attrs":{"url":"https://<cloudId>/browse/<KEY>"}}]}`
3. Re-read fresh immediately before writing for the current version number (avoids
   clobbering a concurrent human edit), then write the whole body back — Confluence has
   no partial-patch API. `updateConfluencePage` with `contentFormat="adf"`, or
   `PUT /wiki/api/v2/pages/<id>` with `body.representation=atlas_doc_format` and
   `--data-binary @file` (never `-d`, multi-byte corrupts — see [[ama-confluence-api]]).
4. Re-fetch and verify, and don't trust a silent success: new entry present, **`mediaSingle`
   count still 1** (`grep -c mediaSingle`), ticket-key count = previous + 1, every other
   section unchanged.

If an html write already happened and the image is gone, the attachment is NOT deleted —
only the body reference. Restore recipe and media-node shape: [[ama-confluence-api]]. For
this page: `id 5adc836b-1f2a-4c5f-8bef-335d98eb0ef0`, collection `contentId-<backlogPageId>`,
1037x102, in the Terraform `listItem` between its two paragraphs.

Spike this exact cycle against a private scratch Confluence page before touching the
live one.

## Auth

Confluence page writes stay on MCP (`updateConfluencePage`/`getConfluencePage`). Direct
REST (attachments, archiving) uses `$ATLASSIAN_API_TOKEN` too — see
[[ama-confluence-api]] for the mechanics and the images/archiving gotchas.
