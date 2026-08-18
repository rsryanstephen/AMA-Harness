---
name: verify-before-reporting
description: Verify a potential bug/issue against real code before telling a human it exists — PR comment, Jira ticket, Slack message, any report. Use before relaying any subagent's finding, and whenever about to flag a bug to a PR author, file a ticket, or say "there may be an issue here".
metadata:
  type: reference
---

# Verify before reporting

A finding is unreported until read in the real code. A subagent's summary, a raw
Bitbucket/GitHub diff, or an earlier turn's claim is a lead, not a verified finding.

## Gate

Before any comment/ticket/message claiming a bug:

1. Read the post-change file for real — not the diff snippet, the whole relevant function/class.
2. Read the code around it that the change plausibly affects (callers, siblings, the
   schema/contract/config it writes into).
3. Only then decide whether it's real.

Fetch-only, no branch checkout (see [[ama-pr-review]] Step 3 for the exact recipe —
`git show FETCH_HEAD:<path>`, `git grep <symbol> FETCH_HEAD`).

## Check intent before calling it a bug

Read the target schema/contract/config, not just the code that writes to it. "Looks
wrong" and "violates the actual contract" are different claims.

Confirmed real: a "dropped column" flagged from the diff alone matched the schema's intended shape.

## State the confidence you actually earned

Distinguish always-wrong from conditional/latent, and name the exact condition that triggers
it. Don't round a "sometimes, under X" finding up to "broken". Overstating to a colleague
costs more credibility than staying silent or hedging.

Include: the failure case, any knock-on effects, and one line admitting you're reading code
without full domain/data context.

## After verifying: a confirmed still-open defect is a ticket

If it's real and unfixed, that's work to raise — Jira ticket per [[commit-ticket]] rule 3, not
just a note filed away. If it's real but merged/shipped, still surface it (see [[ama-pr-review]]
Step 4 for the PR-comment-plus-DM flow) — verification doesn't mean staying quiet once merged.
