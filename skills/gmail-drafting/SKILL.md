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
2a. **Proofread pass — any recipient outside `yourorg.net`.** Spawn a subagent
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
2b. **Signature — API drafts get NO Gmail auto-sig.** Body lands unsigned unless added.
   Fetch: `search_threads` `in:sent` → newest → `get_thread`
   (`messageFormat: PLAIN_TEXT`) → trailing sig block. Reproduce verbatim EXCEPT
   company name: stored sig reads `SturctureIt`, always write `YourCompany` (standing
   user instruction, that one word only — take no other liberties with the sig).
   Add to `body` AND `htmlBody`, kept in sync.
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

`list_drafts` returns `plaintextBody` only — HTML part NOT readable back. Verify
`htmlBody` by construction; build both bodies in ONE call, don't patch one after.

See [[feedback-email-draft-gmail-mcp]] in harness memory for the incident record.
Client-notification framing (Dan's team IS client-facing):
[[ama-client-facing-notifications]].
