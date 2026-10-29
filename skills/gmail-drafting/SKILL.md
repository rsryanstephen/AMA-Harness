---
name: gmail-drafting
description: Any request to draft, compose, or send an email — ToolSearch for the Gmail MCP FIRST (`mcp__claude_ai_Gmail__*`), then use create_draft. Never just print the email text in the CLI, never drive gmail.com via claude-in-chrome browser automation, unless the user explicitly asks for the browser or Gmail MCP is confirmed unavailable.
---

# Gmail drafting

Trigger phrases: "draft an email", "write an email to X", "send an email", "email X
about Y", "compose a message to X" — any request whose deliverable is an actual email,
not just email-shaped text.

## The mistake this fixes

Session 5d622c83: asked to draft an email, printed the text in the CLI instead of
creating a real Gmail draft. Asked again, explicitly naming Gmail, it drove gmail.com
via `claude-in-chrome` browser automation instead of the Gmail MCP.

**Root cause:** `mcp__claude_ai_Gmail__*` tools are deferred — bare names only, no
description, until `ToolSearch` loads them. `claude-in-chrome` ships a loud, explicit
"when to use me" instruction block in the system prompt. Given an email task, the model
reaches for the tool it already has a description for (Chrome) over the one it doesn't
(Gmail MCP) — the Gmail MCP tools were available the whole time, nothing prompted a
search for them. Per this harness's "Mechanical Triggers Over Self-Recognition" rule,
self-recognition of an undescribed deferred tool is exactly the failure mode a skill
entry (this file) exists to close — the Skill tool's description-matching is the hook.

## What to do

1. `ToolSearch` for the Gmail tools before doing anything else:
   `ToolSearch("select:mcp__claude_ai_Gmail__create_draft,mcp__claude_ai_Gmail__list_drafts")`
2. Compose the email.
2a. **Proofread pass — any recipient outside `<tenant domain>`.** Spawn a subagent
   (`model: sonnet`) on the composed text. Corrections only, no rewrite of substance.
   Brief: idiom, compound hyphenation, subject-verb agreement, register. Real defects
   it exists to catch (one draft, all three): `following on from` (wrong idiom),
   `end to end` (missing compound hyphen), `find everywhere the affected fields
   surface` ("everywhere" as noun object). Internal-only recipients → skip.
   Gate on recipient list, NOT on how important the email feels.
   **Not haiku** — tested on seeded text, haiku got 6/6 blatant errors (`went`/`gone`,
   `their`/`there`, `effects`/`affects`, `weather`/`whether`) but missed BOTH subtle
   ones in the same text (`following on from`, `end to end`) — i.e. exactly the class
   this pass exists for. Name the three defects above in the brief regardless; don't
   rely on the model spotting register problems unprompted.
   **WAIT for it. Never call the draft ready while the pass is still running** — that's
   a check that blocks nothing, the same fault as a gate that can't fail. Confirmed:
   a pass took 9.5 min, the draft was declared ready meanwhile, and it came back with
   two real defects (a semicolon joining a statement to a direct question; hyphenation
   inconsistent with the same phrase one sentence earlier) that then needed a correction
   message chasing an already-delivered draft. If it hasn't returned, say the draft is
   pending proofread — don't hand it over.
   **Proofread scope = the new body text ONLY.** Never touches the signature block, the legal
   disclaimer, or quoted history — verbatim boilerplate. Confirmed 2026-08-20: a pass "fixed"
   the disclaimer's wording and dropped a substantive clause from the user's own text.
2a-i. **Depth is set by WHO is in `to` — read the injected AUDIENCE POLICY, don't guess.**
   Levels/roles are config data (`harness-config.json` `.audiences`), never hard-coded here —
   people swap roles. Level = MIN across `to` (business < <level>), `avoid` = UNION. Mixed
   audience → business, by consequence not special case. `cc`/`bcc` do NOT set the level (the
   step 2b-i standing cc would otherwise make every ClientCorp mail "mixed"). Put the resolved
   level + `Do NOT include` list in step 2a's proofread brief — that pass runs BEFORE the
   draft exists, so it is the checkpoint with teeth. **Brief contents are prose-only, no hook
   behind them** — nothing checks you did it. Injected by
   `audience-policy-check.sh` (prompt time, shapes the draft) and `audience-policy-gate.sh`
   (send time, backstop only — body already written). Both inject, neither blocks: no hook
   can judge tone. See [[audience-communication-levels]], [[slack-messages-terse]].
2b. **Signature — API drafts get NO Gmail auto-sig.** Body lands unsigned unless added.
   **PLAIN_TEXT sig into `htmlBody` loses all formatting — don't.** Fetch:
   `search_threads` `in:sent newer_than:30d` → genuinely newest by `date` → `get_message`
   `messageFormat: FULL_CONTENT` (need `html_body`, PLAIN_TEXT omits it). Extract the
   `<div class="gmail_signature">…</div>` block — first one BEFORE any `gmail_quote`
   (a quoted reply carries the OTHER party's sig inside `gmail_quote`; none before it →
   next-newest msg). `data-smartmail` is sent-only — Gmail strips it saving a draft, so
   never key a gate or verification on it.
   **Stale-source check: extracted sig MUST spell `YourCompany`.** Reads `SturctureIt`
   → source is an OLD message; take next-newest, don't patch the string. (Stored Gmail
   sig itself is correct — confirmed 2026-08-20; the typo survives only in older sent
   mail. Don't filter by `smaller:`, it biases toward old short messages.)
   `htmlBody` = body + that div verbatim (unstyled body is correct — Gmail applies
   account default style client-side, don't wrap it). `body` = plain text +
   `plaintextBody`'s sig rendering. Keep both in sync. No anchor at all → fall back to
   PLAIN_TEXT sig, say so in handover — never emit half-parsed HTML.
   Gate-enforced: `gmail-draft-sig-gate.sh` denies any draft carrying `SturctureIt`.
2b-i. **Any `@client.example.com` recipient → cc `<emailRecipients>`.** Standing rule,
   whole ClientCorp side, every mail. Set it in the SAME call — a forgotten cc on a reply cannot
   be patched (`update_draft` detaches, step 2c), it costs a recreate. Exempt: the user's
   own `<secondaryEmail>` as the ONLY clientcorp address (self-mail). Gate-enforced:
   `client-mail-cc-gate.sh` asks. See [[clientcorp-cc-contactone]].
2b-ii. **Mail to <one entry per line; this element only declares the type> → EVERY address in `harness-config.json` `.embs.supportRecipients`**
   (ice.com AND bkfs.com), cc EVERY address in `.embs.supportCcRecipients` (Reviewer One, Reviewer Two).
   Read the config, never hardcode one. See [[ama-embs-notices]].
2c. **Reply to a thread → target the thread's LAST message, then VERIFY it threaded.**
   `replyToMessageId` pointed at an **inbound** message (the other party's reply) put the
   draft on a **brand-new thread**, detached from the chain — confirmed live 2026-08-18,
   `threadId 1a016037939c2912` against the real chain's `1a0004ef44cd6154`. Re-creating it
   against the thread's last message (our own most recent sent one) threaded correctly.
   `create_draft` returns only `{id}`, so nothing surfaces the break: the user caught it.
   - Pick the target with `get_thread` → **last** message id, not the one you happen to be
     answering.
   - Then `list_drafts` and check the new draft's `threadId` matches the intended thread.
     (`create_draft` now returns `{id, messageId, threadId}` — the response threadId is the
     immediate check; the list_drafts confirm still stands.)
   - **`update_draft` on a reply draft DETACHES it** — worse than "cannot fix": updating
     just the body of a correctly-threaded reply re-created it as its own thread
     (`threadId` became == its `messageId`; confirmed live 2026-08-19, and AGAIN 2026-08-20
     by a session that had this very line available and updated anyway). Get the wording
     right BEFORE creating, or re-create; never update_draft a reply draft. **This line
     failing twice is why the hook now fires on `update_draft` too** — prose alone didn't
     hold.
   - Wrong thread / detached → create a replacement against the right target, then clean
     the stray with `delete_draft` on the draft `id` (`r-…`, from `list_drafts`) — fine to do
     unprompted for a Claude-created stray/superseded draft. NOT `trash_message` on the
     draft's messageId: "caller does not have permission" every time (2026-10-22, left the
     user to delete by hand). `delete_draft` is a deferred tool: ToolSearch it first.
     Anything beyond that (real messages, whole threads) → ask, don't assume.
   Gate-enforced: `gmail-reply-thread-reminder.sh` fires on any reply `create_draft`, and on
   EVERY `update_draft` (the payload can't reveal whether the target is a reply).
3. Call `mcp__claude_ai_Gmail__create_draft` with recipient/subject/body.
4. Show the drafted content in the reply too, for the user's review — that's a bonus,
   not a substitute for the real draft.
5. Do NOT fall back to `claude-in-chrome` to drive gmail.com by hand for this. Only use
   the browser if the user explicitly asks for browser automation, or Gmail MCP tools
   are confirmed unavailable in this session (`ToolSearch` returns nothing).
6. "Send" (not just draft) → same tool search, then whatever Gmail MCP exposes for
   sending; if only `create_draft` exists (no direct send tool), create the draft and
   tell the user it's staged in Drafts for them to send — don't send via the browser as
   a workaround.
7. `mcp__*__reply`/`mcp__*__forward` = direct-send path, no draft, no review step. Use
   only when user wants it sent now, not drafted. `replyAll:true`/no explicit `to` →
   recipients unknown to every gate (ContactOne cc, sig, audience backstop) — Gmail resolves
   them server-side, payload has none. Confirmed live 2026-08-26: replyAll reply to ClientCorp
   shipped with no ContactOne cc, no sig. Pass `to`/`cc` explicit when the thread might touch
   a standing rule, or use `create_draft` instead for the review step above.
8. **Screenshot/file in the mail → `create_draft` `attachments` works** (`[{filename, mimeType,
   content:<base64>}]`); "the connector can't attach" is WRONG (2026-10-23: a draft said "attached
   screenshot" with none, user caught it). Body saying "attached" = attach it, never hand the
   user the path. Shrink first or the base64 eats context: crop to the relevant region, PIL
   `quantize(24)` PNG ≈ 12 KB → 16k chars (full 1500x1000 shot = 51 KB). Read the b64 file with
   Bash, paste into the call. Verify: `get_draft` `RAW` shows the `Content-Disposition:
   attachment` part (PLAIN_TEXT/METADATA omit attachments). Image BYTES unverifiable from
   here -- tell the user to eyeball the attachment. `update_draft` detaches replies: recreate.

`list_drafts` `view: DRAFT_VIEW_FULL` DOES return a populated `htmlBody` (confirmed
2026-08-20, 27k chars; an earlier note here claiming otherwise was wrong — believing it
is what let a sig fix ship unverified). So VERIFY every draft after creating it:
`threadId` = intended thread, and the sig checks below.
**MEASURE THE SIG ONLY IN THE PRE-QUOTE REGION — byte offsets, not bare substring.**
On a REPLY, Gmail appends the whole quoted chain to the stored `htmlBody`, and that chain
carries the sigs of genuinely-sent older mail, typo and all. A bare
`htmlBody | test("SturctureIt")` therefore FALSE-FAILS every reply on an old thread, and a
bare `test("gmail_signature")` FALSE-PASSES a sig-less draft by matching a quoted one.
Both misfired live 2026-08-20 and produced a wrong diagnosis twice in one sitting. Do:
```
q=$(grep -bo 'gmail_quote' h | head -1 | cut -d: -f1)   # first quote container; none -> whole file
grep -bo 'SturctureIt' h | cut -d: -f1                  # every offset must be >= q
grep -bo 'font-family:Arial' h | cut -d: -f1            # one must be < q (style survives)
```
Offsets `< q` are OURS; `>= q` are archived history — never "fix" those.
**Verify on a STYLE marker, never on `class="gmail_signature"` — Gmail STRIPS both that
class and `data-smartmail` when it saves an API-created draft.** Measured 2026-08-20: sent
`<div dir="ltr" class="gmail_signature" data-smartmail="gmail_signature">`, stored
`<div dir="ltr">`. So the anchor can only ever match inside a QUOTE, which is precisely the
false-pass above. The inline styles (`font-family:Arial`, `#888888`, `rgb(17,85,204)`) DO
survive and are what the user actually sees. Corollary: source the sig from a SENT message,
never from a stored draft — the sent copy keeps the class, a draft has already lost it.
**Also expect Gmail to rewrite the sig's link on save** — `https://www.<tenant domain>/`
becomes `https://www.google.com/url?q=...&source=gmail&ust=...` in BOTH `htmlBody` and
`plaintextBody`. Cosmetic and Gmail-side, anchor text still reads `www.<tenant domain>`; it
is NOT evidence of a plain-text sig path (it was misread as exactly that on 2026-08-20).
Still build both bodies in ONE call — never patch one after (`update_draft` detaches
replies, step 2c).

See [[feedback-email-draft-gmail-mcp]] in harness memory for the incident record.
Client-notification framing (Dan's team IS client-facing):
[[ama-client-facing-notifications]].

Drafted mail ends with the AI disclosure line — [[ai-disclosure-footer]]. NOT on EXTERNAL mail:
any `to`/`cc` domain ≠ `<tenant domain>` (clients/ClientCorp, vendors like <one entry per line; this element only declares the type>/ICE/bkfs). Internal-only
mail keeps it. Widened 2026-09-16 from client/ClientCorp-only; that skill has the test.
