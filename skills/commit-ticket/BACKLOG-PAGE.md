# AMA Backlog page — write mechanics

Page: `atlassian.backlogPageId` / `atlassian.cloudId` in `harness-config.json`.
https://yourorg.atlassian.net/wiki/spaces/HO/pages/<backlogPageId>/AMA+Backlog

## When this applies

Write path (sections below, through "Auth"): only a new ticket left at **Open** — see
`SKILL.md`'s "New ticket left at Open" section. Skip if worked immediately this session,
or if it's the harness epic / Regressions ticket.

Read/pickup path ("backlog" / "pick up tasks from the backlog") lives in
[[ama-backlog-page]], not here — but the section anatomy and non-ticket blocks below
(Placement, Insertion anchor, "Not insertion targets") apply to both paths. New tickets
are only ever inserted onto THIS page, never the "AMA Backlog — Deferred" child page
[[ama-backlog-page]] also reads — that page is a one-time 2026-08-10 triage dump, not a
second write target.

## Section mapping

- Bug → `Bugs`
- Task / tech-debt → `Tech Debt`
- Story / feature → `Features`
- Never `Previous requests for new features` (historical, not active backlog).
- Never the `Low Priority …` variants unless the user says so.

## Placement

State the proposed section + slot in one line naming neighbours ("Bugs, 3rd — above
PROJ-14827"), wait for yes/adjust, then write. Insert-in-order going forward, not a
bulk re-sort of the existing ~50 entries (hand-curated with inline commentary — a
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
