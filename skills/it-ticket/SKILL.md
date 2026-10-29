---
name: it-ticket
description: Draft a support ticket for the YourCompany IT department (DNS, certificates, VPN, network, accounts, endpoints IT owns) as a Markdown file the user submits themselves. Use when the user says "draft an IT ticket", "write up a ticket for IT", "raise this with IT", "log an IT ticket", "IT support ticket", or asks for something only IT can action (a record in a zone we don't control, a corporate DNS change, a firewall rule, a domain/registrar change).
---

# IT ticket drafts

Output = Markdown FILE, always. Never CLI-only.

Path: `<harness>/IT Tickets/IT-Ticket-<topic-kebab>.md` — e.g.
`IT Tickets/IT-Ticket-yourorg-net-cert-renewal.md`. Hand user the path.
(Pre-existing `~/.claude/IT-Ticket-VPN-DNS/` stays put — [[ama-vpn-dns-outage]] points there.)

**User submits it. Claude never submits, and never asks whether to** — see
[[draft-never-sends]]. Same for a REPLY on an existing IT ticket: draft it, hand it over,
stop. Sending needs a fresh instruction in send/post wording; "looks good" approves the
wording only.

**Never reproduce the body in the CLI** — wasted tokens, user copies from the file only.
Reply = the path, one line on what it asks IT for, plus anything deliberately left out.

## Body: shortest form that still carries the facts

Audience = IT/security, short on time — `memory/audience-communication-levels.md` (TECHNICAL,
minimum verbiage). Applies to REPLIES as much as new tickets.

- Facts, IDs, dates, commands. No theories, no narrative.
- One sentence per point. One line per fact.
- Never restate their question back at them, or re-explain what they just told you.
- Don't offer options they didn't ask for; one alternative maximum, offered once, never pressed.
- Cut every sentence that doesn't change what IT does. Then cut again.
- Reply target ≤150 words, new ticket ≤400. Over → delete, don't reword.
- Full sentences (human reader — never caveman), just very few of them.
- Last line = the AI disclosure, [[ai-disclosure-footer]].

**Must paste into IT's portal Description box as-is.** That box makes EVERY newline a
paragraph and renders no Markdown (2026-10-13: hard-wrapped ticket pasted one line per
paragraph, `##` literal). File shape:

- One line per paragraph, never hard-wrapped. Blank line between paragraphs.
- Section titles = plain UPPERCASE line (`1. WHAT WE NEED FROM IT`). No `#`.
- Lists + facts = `- ` lines. No indentation (stripped on paste), no pipe tables, no
  fenced blocks, no `---` rules. Tabular facts → label line + `- Label: value` lines:

  ```
  Certificate 3c9dea62-c92d-4710-bd79-58e8d9a7b83f
  - Expired: 2026-07-09
  - Attached to: production-v1-aggregation-api (ALB, 443 listener)
  - Status: only certificate on the listener, IsDefault=True, no SNI fallback
  ```

- Commands = plain line of their own.
- Enforced: `hooks/it-ticket-paste-format-check.sh` flags violations with line numbers after
  every write to an `IT Tickets/` file. Fix before handing the path over.

## Sections

1. **What we need from IT** — the ask, numbered, concrete enough to action without a reply.
   Name the exact record/rule/permission. Offer the permanent fix over the recurring one.
2. **Why it matters** — impact, with dates. What is already broken vs what breaks when.
3. **Evidence** — ARNs, cert ids, resolver addresses, hostnames, expiry dates, the command
   that reproduces it.
4. **How to verify** — one command IT (or we) can run after the change.
5. **Reference** — our own `PROJ-####` key.

Nothing IT can't act on: drop internal-only context, our roadmap, our repo names.

## Before writing — prove we CANNOT do it ourselves

Last step, not first. Assume it's ours until a live check says otherwise. Check in order,
record what each returned:

1. **Artifact already reachable?** Octopus library (certificates, variable sets, feeds),
   Secrets Manager/SSM, S3, ECR, a repo.
2. **Automation already exists?** `aws events list-rules`, scheduled ECS tasks, Octopus
   runbooks.
3. **We hold the permission?** Try the call — a 403 is proof, an assumption isn't.
4. **Whose zone/account/tenant?** `aws route53 list-hosted-zones`,
   `aws route53domains list-domains`, `aws account get-alternate-contact`.

Any of 1-3 yes → not an IT ticket. Do the work, or say plainly it's ours. Only the residue
surviving all four is IT's, and the ticket asks for that alone.

- Verify every infra claim LIVE (`aws`, `nslookup`, `openssl s_client`) — never assert
  state from memory or from an old ticket body.
- Matching PROJ ticket exists → cite it in Reference; none → [[commit-ticket]]'s
  ticket-it-or-ask rule applies.
- Split unrelated faults into separate tickets, even with the same owner. Mention the
  second one to the user; don't fold it in.
