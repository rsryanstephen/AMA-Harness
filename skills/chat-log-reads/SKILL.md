---
name: chat-log-reads
description: Read a session chat-log file's (`*.Chat.md`) content without loading the whole thing into context. Use whenever about to read a chat-log file for its content — finding the last block for a pointer ("see prompt" etc), picking a topic name from it, checking its history — not just confirming it exists. These files only grow, never shrink, so treat every one as potentially large regardless of how the session currently looks.
---

Never full `Read` a chat-log file just to find recent content — cost scales with
whole-file size, unbounded as the file grows.

- Need the last block (pointer convention, "see prompt" etc)? `tail -c 2000 "<file>"` (or `tail -n N`) — not a full Read.
- Need something specific? `grep -n "<pattern>" "<file>"` first for line numbers, then `Read` with `offset`/`limit` around just that region — never the whole file.
- **User says "refer to/see another session" (for its findings, a decision, what happened)** → search that session's chat log from the MOST RECENT content backward, not top-down through the whole file. Check the tail first, then work upward through `grep` matches (highest line numbers first) until the relevant content is found — the recent end is what "refer to" almost always means, and it's usually where the real answer is, not buried somewhere in the middle of a file that only grows.
- Need the WHOLE file for a reason that genuinely requires it (editing/rewriting the whole document)? That's the one case a full Read is legitimate — do it then, not preemptively "just in case."
- Rule of thumb: pick the smallest slice that answers the question.

## A compaction recap is OLD content, not fresh — regardless of where it sits

A block opening *"This session is being continued from a previous conversation that ran
out of context. The summary below covers the earlier portion of the conversation"* (Claude
Code's own resume-summary wording — grep for that opening line) restates PRE-compaction
history. It is never "what just happened," no matter how recent the file's surrounding
timestamps are or how far down the file it sits — a session resumed today can land a
paragraph like this describing a full week-old investigation, indistinguishable in tone
from a fresh accomplishment.

Confirmed live 2026-08-26 (`ama-standup-notes`, <harnessEpicKey>): a resumed session
(`362ffa37-8019-4bc2-b62e-051c8ce83bd3`) got a compaction recap on 2026-08-25 restating its
2026-08-18–20 work (a Jira ticket "sent to Reviewer One", already reassigned to someone else days
earlier). A standup-notes chat-log scan read that recap's prose as the session's Aug-25
contribution and put stale, already-superseded detail into a "Yesterday" bullet.

- **Never extract a "what happened" bullet from inside a recap block.** Its content is old
  by construction.
- **The recap does not mark the end of real content — check both sides of it.** The
  session's actual fresh work from the resume often sits immediately before or after the
  recap in the same file — in the confirmed case, the session's real same-day completion
  sat right before the recap and would have been missed by stopping at the first big prose
  block found near the tail.

## "Which session did X?" — transcripts get PRUNED, never reason from their absence

`~/.claude/projects/**/*.jsonl` is NOT a complete session record. Old transcripts vanish.
Confirmed 2026-09-11: 3 sessions ran 2026-08-09, only 1 jsonl survived -> "no session was
live, user did it by hand" reported to user twice, wrong both times.

Durable sources, use these FIRST:
- `~/.claude/history.jsonl` — one line per user prompt, `{timestamp (epoch ms, UTC), sessionId, project, display}`. Survives transcript pruning. Groups the day's real sessions.
- `*.Chat.md` logs (all `Local Chat Files/` + `ama-claude-harness/Chat files/`) — hook-written, survive too. `find ... -name '*Chat.md'` then grep; ripgrep skips the symlinked copies, so `find`+`grep` beats the Grep tool here.
- `~/.claude/.session-chatfiles/<session-id>` — maps session id -> its chat-log path.

Method: convert the event time to UTC -> group `history.jsonl` by sessionId for that day ->
a long prompt GAP spanning the event = that session's turn was running then -> confirm in
its chat log / git log (`git log --all --grep=<TICKET>`). Absence of a transcript proves
nothing; absence in history.jsonl AND every chat log is the real negative.
