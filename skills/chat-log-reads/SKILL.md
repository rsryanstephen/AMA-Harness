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
