---
model: sonnet
name: ama-release-notes
description: >
  Automates the AMA release-notes pipeline: marks tickets Done, publishes a Confluence
  release-note page, generates a PDF, drafts (not sends) the announcement email. Use for
  "release notes", "AMA release", "document/publish/write up what shipped in this
  release", "send the release announcement", "generate the release PDF", or "tag the
  tickets for release X". Runs AFTER a release is already deployed.
---
# AMA Release Notes

Automates PROJ release-notes pipeline: ticket collection → email draft.

## Configuration (do not prompt the user)

Every value this pipeline uses lives in `~/.claude/harness-config.json` — read from
there, don't hardcode a second copy here (two copies drift).

| Key                       | Config path                          |
| ------------------------- | ------------------------------------- |
| Jira cloud                | `atlassian.cloudId`                    |
| Jira project              | `atlassian.jiraProjectKey`             |
| Jira board ID             | `atlassian.jiraBoardId`                |
| Confluence space ID       | `atlassian.confluenceSpaceId`          |
| Confluence space key (CQL uses the key, not the numeric ID -- same space) | `atlassian.confluenceSpaceKey` |
| Confluence parent page ID | `atlassian.confluenceParentPageId`     |
| Email recipients          | `releaseNotes.emailRecipients`         |
| Email greeting names (email → what that person actually goes by; never infer one from an address) | `releaseNotes.greetingNames` |
| Email sign-off name       | `releaseNotes.emailSignOffName`        |
| PDF approver Slack IDs    | `releaseNotes.approverSlackUserIds` (name + Slack user ID pairs) |
| PDF footer text           | `releaseNotes.pdfFooter`               |

## No manual Jira steps — both former ones are automated

This section used to say two steps "**cannot** be automated". Neither claim was true.
Confirmed live 2026-08-18 by a full create → GET → release → delete round trip:

```bash
V=~/.claude/skills/ama-jira-api/scripts/jira-version.sh
bash $V create  "release/X.Y.Z" "<the work, grouped by theme>"   # was "do it by hand"
bash $V release "release/X.Y.Z" "<YYYY-MM-DD production deploy date>"   # was "click Release"
```

- `releaseDate` is the **Production deploy** date, not today's, when they differ.
- The script re-reads and prints the version after every write — a PUT echoing your
  payload back is not evidence it persisted.
- `create` refuses a name that already exists. That's correct: an existing version is
  someone else's reservation ([[ama-hotfix]] Step 1). Resolve the number first.
- Mark it Released only once Production is verified.

**The generalisable lesson, worth more than the two steps:** "cannot be automated" meant
"no *MCP* tool for it", and that hardened into "impossible" long after
`ATLASSIAN_API_TOKEN` gave this harness full REST write access. `release/129.0.0` and
`hotfix/129.0.2` both sat unreleased purely because of the myth, and every release asked
the user to do handwork that a one-line script does. **Re-test any remaining "manual
step" against REST before repeating the claim.**

---

## Step-by-Step Execution

### Step 1 — Infer the Next Release Number

Query Confluence for most recently created release-note page:

```
CQL: title ~ "Release Note: Release" AND type = page AND space.key = "<atlassian.confluenceSpaceKey>"
ORDER BY created DESC, limit = 1
```

Extract version from page title, regex `Release (\d+\.\d+\.\d+)`. Increment **major** by 1 (e.g. `124.0.0` → `125.0.0`).
Announce: *"Detected latest release: 124.0.0 — proceeding with 125.0.0."*

No page found → ask user for version number.

---

### Step 2 — Collect this release's tickets

**Release N.0.0 must ALSO include every hotfix shipped on release N-1.** Those tickets
carry `fixVersion = hotfix/(N-1).0.x`, never `release/N.0.0`, so a Fix-Version query scoped
to the release alone silently drops them — and they appear in NO other release note, because
[[ama-hotfix]] deliberately skips release notes for a hotfix. Confirmed live on 129.0.0: three
production fixes (PROJ-15286, -15294, -15305) were missing until caught by the user.

```jql
project = PROJ AND fixVersion in ("hotfix/<N-1>.0.1", ... , "hotfix/<N-1>.0.<max>")
```
Resolve the actual hotfix versions live (`GET /rest/api/3/project/PROJ/versions`, keep
names matching `hotfix/<N-1>.0.*`) — don't assume how many there were. **Union with the release
list and de-duplicate by key**: a ticket fixed in a hotfix and then carried into the release
(as PROJ-15297 was) holds both Fix Versions and would otherwise be listed twice.

Invoked from [[ama-deploy-release]] Step 8: use the exact ticket-key list handed off
from that skill's Step 7a — don't re-query it — then add the hotfix set above on top. Fetch via [[ama-jira-api]]'s
`jira-search.sh`, batched JQL `key in (...)`, fields `key,summary,issuetype` — one
call, not per-ticket `getJiraIssue`.

**Never list harness tickets -- REQUIRED, before anything is written:** pipe the gathered list (handed-off + hotfix set + fallback, `key<TAB>summary`) through
`bash ~/.claude/skills/ama-release-notes/scripts/harness-ticket-filter.sh <file>` (add `--since` if release older than 120d). Drops epic-linked (`.atlassian.harnessEpicKey`), harness-repo-only commits, no-commit `Harness:`/skill/hook summaries; mixed app+harness commits KEPT. Use its KEPT lines only; print its REMOVED lines (key, reason) in the handoff to user. Removed still swept to Done, never documented. Why: epic link alone missed 6 of 26 on 130 (2026-10-14). Manual JQL/summary filtering is not a substitute.

Standalone (not chained from a deploy this session): no handed-off list exists. Fall
back to:
```jql
project = PROJ AND status = Done ORDER BY statusCategoryChangedDate DESC
```
`maxResults = 25`, fields `key,summary,issuetype`, via `jira-search.sh`. Tell the user
this is unscoped to the release and may include unrelated concurrent work — ask them
to double-check before proceeding.

---

### Step 3 — Create the Jira Release (automated; no longer a prompt)

**Find the new release's start date first**:
```bash
bash ~/.claude/skills/ama-octopus-deploy/scripts/last-prod-deploy-date.sh release/<N-1>
```
Reads Octopus's Production history (never a Jira `releaseDate`, not reliably populated),
picks the most recent fleet-sized deploy day in ET, prints it and the **next working day**.
Public holidays are not accounted for — say so if the date lands right after one.

Then create it yourself and record the confirmation:

```bash
V=~/.claude/skills/ama-jira-api/scripts/jira-version.sh
bash $V create "release/X.Y.Z" "<the release's work, grouped by theme, from its ticket list>"
bash "$HOME/.claude/hooks/confirm-jira-version.sh" "release/X.Y.Z"
```

Don't stop and ask — this step was manual only because the REST call was never tried.
`create` refuses an existing name, so a collision surfaces as a loud failure rather than
silently reusing another release's version.

Jira's own **start date** isn't settable through this script's payload; if the user wants
it set, that one field still needs the release-management view (the plain `/versions` path
404s):
https://<atlassian.cloudId>/projects/<atlassian.jiraProjectKey>?selectedItem=com.atlassian.jira.jira-projects-plugin%3Arelease-page
Tell them the computed date rather than making them work it out: `<computed next working
day>`, the next working day after `release/<X.Y.Z-1>` reached Production on `<that date>`.

---

### Step 4 — Set Resolution on All 25 Tickets

Fix Version is already tagged at cut time (see [[ama-cut-release-branch]]'s Step 3a) —
this step only sets resolution, so a ticket doesn't stay `Unresolved` after Done. For
each of the 25 tickets, call [[ama-jira-api]]'s `jira-edit-issue.sh` (payload
`{"fields": {"resolution": {"name": "Done"}}}`). MCP retired 2026-08-31.

Needed because PROJ Done transition (`id: 261`) has `hasScreen: false`, no
post-function to auto-set resolution. Update sequentially. Report progress as `✅ N/25`.

---

### Step 5 — Categorise Tickets by Issue Type

Map issue types to release-note sections using this table:

| Issue Type(s)                    | Section                                                                          |
| -------------------------------- | -------------------------------------------------------------------------------- |
| `New Feature`                  | New Features                                                                     |
| `Bug`                          | Bug Fixes                                                                        |
| `Support`                      | Support Requests*(or Support Alerts if production-critical — see note below)* |
| `Task`, `Sub-task`, `Epic` | Tasks*(unless clearly an improvement — see note below)*                       |

**Production-critical heuristic:** Support ticket summary has words like *"production"*, *"prod"*, *"failing"*, *"crash"*, *"stopped working"*, *"error"*, *"alert"* → **Support Alerts** instead of Support Requests.

**Improvement heuristic:** Task ticket summary has words like *"upgrade"*, *"optimize"*, *"refactor"*, *"improve"*, *"update"*, *"migrate"* (not purely operational) → **Improvements** instead of Tasks.

Derive 2–3 **Highlights** bullets summarising notable themes across New Features, Improvements, significant Tasks. **Never name Your Name or Reviewer One as who did the work** — describe what shipped, not who did it (per explicit user instruction).

---

### Step 6 — Create the Confluence Page

Create via [[ama-confluence-api]]'s `confluence-create-page.sh <space-id> "<title>"
<body-file> <parent-page-id>` (MCP retired 2026-08-31; body via file, `storage` format
for the HTML below → pass format through `confluence-update-page.sh ... storage` if a
follow-up edit is needed). **It prints `id<TAB>webui-url` — that URL is what Step 9
reports to the user.** Per explicit user instruction: always give the user the actual
link to the page just created, not a placeholder.

Parent = `atlassian.confluenceParentPageId`, space = `atlassian.confluenceSpaceId`
(both from `harness-config.json`; the script wants the NUMERIC space id). Title:

```
Release Note: Release X.Y.Z
```

HTML body format below exactly mirrors 124.0.0 release note structure.
Only include sections with ≥1 ticket. Omit empty sections entirely.

```html
<p>Deployed <time datetime="YYYY-MM-DD">Month D, YYYY</time> </p>
<h1>Highlights</h1>
<ul>
  <li><p>Highlight bullet 1</p></li>
  <li><p>Highlight bullet 2</p></li>
</ul>
<h1>Support Requests</h1>
<ul>
  <li><p>PROJ-XXXXX	Ticket summary</p></li>
</ul>
<h1>New Features</h1>
<ul>
  <li><p>PROJ-XXXXX	Ticket summary</p></li>
</ul>
<h1>Improvements</h1>
<ul>
  <li><p>PROJ-XXXXX	Ticket summary</p></li>
</ul>
<h1>Support Alerts</h1>
<ul>
  <li><p>PROJ-XXXXX	Ticket summary</p></li>
</ul>
<h1>Tasks</h1>
<ul>
  <li><p>PROJ-XXXXX	Ticket summary</p></li>
</ul>
<h1>Bug Fixes</h1>
<ul>
  <li><p>PROJ-XXXXX	Ticket summary</p></li>
</ul>
```

Note: separate ticket key/summary with a **tab character** (`\t`), not spaces — matches existing page format.

---

### Step 7 — Generate the PDF

Run bundled script, pass release data as JSON. Use `python`, not `python3` (Microsoft
Store stub — see [[bash-command-correctness]]):

```bash
python /path/to/ama-release-notes/scripts/generate_pdf.py \
  --version "X.Y.Z" \
  --date "Month D, YYYY" \
  --tickets '<JSON>' \
  --footer "<releaseNotes.pdfFooter from harness-config.json>" \
  --output "C:/Users/<you>/AppData/Local/Temp/HO-Release Note_ Release X.Y.Z.pdf"
```

The `--tickets` JSON shape:

```json
{
  "highlights": ["Highlight 1", "Highlight 2"],
  "support_requests":  [["PROJ-XXXXX", "Summary"], ...],
  "new_features":      [["PROJ-XXXXX", "Summary"], ...],
  "improvements":      [["PROJ-XXXXX", "Summary"], ...],
  "support_alerts":    [["PROJ-XXXXX", "Summary"], ...],
  "tasks":             [["PROJ-XXXXX", "Summary"], ...],
  "bug_fixes":         [["PROJ-XXXXX", "Summary"], ...]
}
```

Omit any key with empty list.

Heading + first item are kept together (no heading stranded at a page bottom). Script then re-reads the PDF and exits non-zero if any page ends on a section heading ("Orphan-heading check: OK" = pass; needs pypdf or PyPDF2, else warns + skips). Non-zero → don't attach that PDF.

---

### Step 7a — Send the PDF to David and Reviewer Two for approval, before the client email

Per explicit user instruction: before drafting the client-facing email (Step 8), send
the release PDF to the two people named in `releaseNotes.approverSlackUserIds`
(`harness-config.json`) as a **joint DM — one shared conversation with both of them, not
two separate DMs**. Try
`slack_send_message` with both user IDs as the `channel_id` (comma-separated) to open/
reuse the shared conversation; if that doesn't resolve a joint DM, fall back to sending
identical individual DMs to each and say so — don't silently substitute one for the
other without telling the user.

Message: PDF attached, brief note asking for approval before it goes out to clients.
Wait for their go-ahead before treating Step 8 as ready to send (Step 8 already only
drafts the email, never sends it — this is about not telling the user the email is
ready to go out until approval is in).

---

### Step 8 — Compose the Gmail Draft

Base64-encode PDF, call `Gmail:create_draft` with:

- **to**: `releaseNotes.emailRecipients` (see Configuration) — the whole list at once, i.e.
  the canonical mixed audience, so [[audience-communication-levels]] resolves it to
  **business level**. The fixed body template below already is that; don't add <level>
  detail to it.
- **subject**: `Release Note: Release X.Y.Z`
- **body** — greeting names come from **`releaseNotes.greetingNames`** (email → the name
  that person actually goes by). **Never derive a name from the email address.** That is
  how <emailRecipients> became "Sebastien" in the 129.0.0 draft when he goes by
  **Seb** — the local part is a legal name, not a form of address, and a client-facing
  email is the worst place to get it wrong. Recipient missing from the map → ask the user
  what that person goes by and add them to the map; don't guess from the address:

  ```
  Hi <greetingNames values, comma-separated, in emailRecipients order>,

  Please find attached the release note for release X.Y.Z deployed to production on the Dth Month.

  Regards,
  <releaseNotes.emailSignOffName>
  ```

  Use ordinal suffix for day (1st, 2nd, 3rd, 4th … 25th, etc.).
- **attachments**: `[{ "content": "<base64>", "filename": "HO-Release Note_ Release X.Y.Z.pdf", "mimeType": "application/pdf" }]`

---

### Step 9 — Final Report

Print concise summary:

```
✅ Release X.Y.Z pipeline complete

📋 Jira:         25 tickets tagged with release/X.Y.Z
                 ✅ Version marked Released via REST (PUT /version/<id>)
                 ⚠️  Only the version's CREATION may still need doing by hand
📄 Confluence:   Release Note: Release X.Y.Z — <real page URL, not a placeholder>
📎 PDF:          HO-Release Note_ Release X.Y.Z.pdf
💬 Slack:        PDF sent to David + Reviewer Two for approval
📧 Gmail draft:  Subject "Release Note: Release X.Y.Z" (not sent)
```

---

## Error Handling

| Situation                                          | Action                                                                                                    |
| -------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| Confluence search returns no prior release pages   | Ask user for the version number                                                                           |
| `jira-edit-issue.sh` fails for a ticket          | Log `⚠️ Failed: PROJ-XXXXX`, continue with remaining tickets, report failures at the end         |
| `resolution` update fails for a ticket           | Log a warning but do not stop — continue with remaining tickets, patch manually if needed |
| PDF script fails                                   | Fall back to creating the PDF inline using the reportlab code embedded at the end of this skill           |
| `Gmail:create_draft` fails                       | Report the error; remind user the Confluence page and PDF were still created successfully                 |

---

## Inline PDF Fallback

Script unavailable → generate PDF directly using this Python template (substitute `VERSION`, `DATE_STR`, ticket sections):

```python
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib.units import mm
from reportlab.lib import colors
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, HRFlowable

OUTPUT = "C:/Users/<you>/AppData/Local/Temp/HO-Release Note_ Release {VERSION}.pdf"
BRAND_BLUE = colors.HexColor("#0052CC")
RULE_COLOR = colors.HexColor("#DFE1E6")
BODY_GRAY  = colors.HexColor("#172B4D")
META_GRAY  = colors.HexColor("#6B778C")

doc = SimpleDocTemplate(OUTPUT, pagesize=A4,
      leftMargin=20*mm, rightMargin=20*mm, topMargin=20*mm, bottomMargin=20*mm)

title_style = ParagraphStyle("T", fontName="Helvetica-Bold", fontSize=22,
              textColor=BRAND_BLUE, spaceAfter=2*mm, leading=28)
meta_style  = ParagraphStyle("M", fontName="Helvetica", fontSize=10,
              textColor=META_GRAY, spaceAfter=6*mm, leading=14)
head_style  = ParagraphStyle("H", fontName="Helvetica-Bold", fontSize=13,
              textColor=BRAND_BLUE, spaceBefore=6*mm, spaceAfter=2*mm, leading=18)
item_style  = ParagraphStyle("I", fontName="Helvetica", fontSize=9,
              textColor=BODY_GRAY, leftIndent=8*mm, spaceAfter=1.5*mm, leading=13)
bull_style  = ParagraphStyle("B", fontName="Helvetica", fontSize=10,
              textColor=BODY_GRAY, leftIndent=8*mm, spaceAfter=1.5*mm, leading=14)

def section(title):
    return [HRFlowable(width="100%", thickness=1, color=RULE_COLOR,
                       spaceAfter=2*mm, spaceBefore=3*mm),
            Paragraph(title, head_style)]

def ticket(key, summary):
    return Paragraph(
        f'<font name="Helvetica-Bold" color="#0052CC">{key}</font>'
        f'<font name="Helvetica" color="#172B4D">  {summary}</font>', item_style)

def bullet(text):
    return Paragraph(f"<bullet>•</bullet> {text}", bull_style)

story = []
story.append(Paragraph("Release Note: Release {VERSION}", title_style))
story.append(Paragraph("Deployed: {DATE_STR}", meta_style))
story.append(HRFlowable(width="100%", thickness=2, color=BRAND_BLUE, spaceAfter=4*mm))

# Add sections dynamically from categorised tickets
# ... (same pattern as scripts/generate_pdf.py)

doc.build(story)
```
