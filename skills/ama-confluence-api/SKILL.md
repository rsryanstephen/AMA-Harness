---
name: ama-confluence-api
description: ALL direct Confluence REST -- page read/create/update (scripts), attachments/images, archiving/deleting, CQL search. Replaces the Atlassian MCP for Confluence entirely (MCP retired 2026-08-31 to save tokens). Use for any Confluence page read or write, adding an image, a disappearing image after a write, or delete/archive/trash a page.
---

# Confluence REST (direct) — pages, images, archiving

Atlassian MCP retired 2026-08-31 (token cost; user instruction). Every Confluence
operation = direct REST. Page bodies via scripts below; attachments/archiving via the
recipes further down.

## Page read / create / update — scripts

```bash
bash ~/.claude/skills/ama-confluence-api/scripts/confluence-get-page.sh <page-id> <out-body-file> [atlas_doc_format|storage]
bash ~/.claude/skills/ama-confluence-api/scripts/confluence-create-page.sh <space-id> <title> <body-file> [parent-page-id]
bash ~/.claude/skills/ama-confluence-api/scripts/confluence-update-page.sh <page-id> <body-file> [message] [atlas_doc_format|storage]
```

- Body via FILE always, never argv — same corruption rule as [[ama-jira-api]].
- `atlas_doc_format` (default) = ADF JSON; `storage` = XHTML, the format
  [[ama-team-meeting-notes]] splices. Update = whole-body replace, no partial patch —
  get, splice, update, verify content yourself (script verifies version bump only).
- create prints `id<TAB>webui-url` — hand the user the real link.
- Space id = numeric (`GET /wiki/api/v2/spaces?keys=HO`), not the key.
- Find a page by title: CQL, `GET /wiki/rest/api/content/search?cql=title~"..."`.
- All verified live 2026-08-31 (get/update on real pages; create+update+archive
  round-trip on a scratch page).
- No `"\(...)"` jq interpolation in these scripts — MSYS argv conversion mangled it to
  `/(...)` live; build strings with `+` and `@tsv`.

## Auth

`$ATLASSIAN_API_TOKEN` Basic-auths fine against Confluence REST directly, both
`/wiki/rest/api/...` and `/wiki/api/v2/...` — confirmed live. Only `BITBUCKET_API_KEY`
401s here (Bearer-vs-Basic mixup, see [[ama-bitbucket-api]]) — don't conflate the two.

## Upload an attachment (no MCP tool covers this)

```bash
curl -X POST -H "X-Atlassian-Token: nocheck" \
  -u "<user.email>:$ATLASSIAN_API_TOKEN" \
  -F "file=@<path>" \
  "https://yourorg.atlassian.net/wiki/rest/api/content/<pageId>/child/attachment"
```
400 "same file name as an existing attachment" → re-upload under a different filename.
Response's `extensions.fileId` / `extensions.collectionName` feed the media node below.

## Embed the image: write via `contentFormat="adf"`, not `"html"`

`updateConfluencePage(contentFormat="html")`'s HTML→ADF converter silently drops any
`<figure data-type="media-single">` node nested inside a `<li>` — survives fine as a
top-level sibling, dropped every time nested in a list item. Confirmed root cause, not a
platform limit. Fix: bypass the converter, write raw ADF instead.

```json
{"type":"mediaSingle","attrs":{"layout":"center"},
 "content":[{"type":"media","attrs":{"id":"<fileId>","type":"file","collection":"<collectionName>"}}]}
```
Place inside the listItem's `content` array wherever it needs to go. Fetch the page with
`contentFormat="adf"` first to see real structure — don't hand-guess it. Confluence
auto-fills `width`/`height` on read-back if it resolved — that's the tell it took, not
just a version-bump.

Recipe end-to-end: upload (above) → reference via the ADF node → re-fetch and confirm
the media node itself persisted, not just the version number.

## Recover a dropped image reference

Attachments live independently of body content — dropping the body reference does NOT
delete the file.
1. `searchConfluenceUsingCql`, `type = attachment AND container = <pageId>` — still
   there, `current` status.
2. `GET /wiki/rest/api/content/<pageId>/child/attachment/<attId>/download`, Basic auth —
   302 to signed storage, `curl -L` follows to the bytes.

Always warn the user before writing to a page holding an embedded image, and re-verify
the image specifically after — a clean version-bump doesn't mean nothing was lost.

## Archive a page — v1 bulk-archive endpoint, no MCP tool, no delete at all

No page/attachment delete or trash tool exists anywhere in this MCP server. Archiving is
the closest thing. Two plausible endpoints fail differently:
- `PUT .../rest/api/content/{id}` with `"status":"archived"` — silently ignored (200,
  status stays `current`).
- `PUT .../api/v2/pages/{id}` with `"status":"archived"` — rejected outright
  (`PageUpdateAllowedStatus` only allows `CURRENT`/`DRAFT`).

Real mechanism, confirmed live:
```
POST /wiki/rest/api/content/archive   body: {"pages":[{"id":"<pageId>"}]}
```
202 + a `longtask` URL. Poll `GET /wiki/rest/api/longtask/<taskId>` for
`"status":"FINISH_SUCCESS"`, then `GET .../content/<pageId>?status=archived` to verify.

## Reading a large page body

A big page's HTML comes back as one giant single line -- too long for the Read tool's
per-call token cap. Save to a file, split (`split -b 20000 <file> <prefix>`), `Read`
each chunk verbatim -- never paraphrase/summarize chunks you intend to write back, and
never retype from memory.

## Multi-byte payloads

Em dash / curly quotes inline via `curl -d '...'` in this Windows Git-Bash environment
corrupt (`Invalid UTF-8 start byte` 400). Write JSON to a file, `curl --data-binary
@file` — same risk [[ama-jira-api]]/[[ama-bitbucket-api]] already warn about.

## Security / cost records — dated row per change (user rule 2026-10-13)

AMA security improvement, or infra cost saving/improvement, live (or landed) → one dated row, same session.
Nudged by `hooks/security-cost-confluence-reminder.sh` after a matching Jira transition/comment.

- Security → "AMA Security Improvements", `atlassian.securityImprovementsPageId`, table "Improvements":
  Date | Improvement | Why it matters | Status | Ticket. Keep its "Open follow-ups" list current.
- Cost/infra → Reviewer One's "Cost Optimizations", `atlassian.costSavingsPageId`, ONLY the bottom table
  "Cost savings and infrastructure improvements log": Date implemented | Change | Removed or reduced |
  ~$ saving/mo | Ticket. Never edit Reviewer One's top table or the "Platform improvements 2026" table.
- Both kinds (e.g. retiring an unused service) → row on each.
- How: get `storage` → splice one `<tr>` after the header row (newest first) → update `storage` →
  re-get, grep your row. Splice fetched body, never retype.
- Wording business level (<name> reads it): what changed, why it matters, status per env, ticket key.
  Date = day live; partial rollout → date landed, update Status cell as it spreads.
