---
name: rename-topic
description: Rename the current session's chat-log topic/file. Use when the user says "rename this topic to X", "rename topic to X" (explicit name given), or just "rename topic" / "rename this topic" / "rename the topic" with no name given (Claude picks one itself from the chat file's current content).
---

One name per session: chat file = Claude Code's own session name. LIVE session: `/rename`
only — client-side, no tool/hook reaches it. IDLE session (another sid, >30 min unwritten):
`perl ~/.claude/hooks/../scripts/session-name-dedupe.pl --rename <sid> "<name>"`. This skill does NOT rename anything
itself; it tells the user what to type. `hooks/rename-topic.sh` is internal now, called
only by `lib-fallback-rename.sh`.

**Check the name is free first, always:**

```bash
perl ~/.claude/hooks/../scripts/session-name-taken.pl "<the name>" "<this session's sid>"
```

(`hooks/..` is not a typo — `~/.claude/hooks` is the symlink into the harness repo, and
`~/.claude/scripts` does not exist.)

Exit 0 = taken, prints `<shortid>  <name>` per clash. Exit 1 = free. Two sessions with one
name means `claude -r "<name>"` opens the picker instead of resuming, and both rows in
sessions.md fall back to a raw id. Claude Code warns about none of this. Catches only names
the harness suggests — a `/rename` typed straight in is client-side, invisible to hooks.

**User gave the name** ("rename this topic to X"): tell them to run `/rename X` themselves.
Say something like: "Run `/rename X` — the chat file follows automatically once the name
lands, next turn end." Taken? Say so, name the other session, let them choose — never
silently substitute their name.

**No name given** ("rename topic", etc.): pick a good name from the chat file's *current*
content — what the session is about *now*, not just its first prompt. Read the current
chat file (name in injected context) per the chat-log-reads skill — tail recent content,
don't full-Read just for this. Then tell the user to run `/rename <your pick>`. Don't ask
them to confirm your pick first — just say it.

**Name the OUTCOME, long and plain. Length is free; cryptic is not.** User instruction
2026-09-04, after a short two-clause pick got rejected. Rules:
- State what was established/fixed, not the topic area. `GNM LoanDist redistribution feeds
  no AMA column - PROJ-15310`, not `LoanDist clearance`.
- Ticket key on the end when one ticket owns the session — it's the fastest handle for
  `claude -r` and for sessions.md.
- **Harness session → end it `- Harness`, never `- <harnessEpicKey>`** (user instruction
  2026-09-22). Every harness change carries that one epic, so the key sorts nothing and
  distinguishes nothing; the word says the same thing and reads. Same reasoning as
  [[ama-harness-no-epic-comments]]. A real per-change ticket still goes on the end as
  its own key.
- Session did two unrelated things → name the one that MATTERS, drop the other. Don't
  and-join them; a two-clause name is worse than a one-clause name about the real work.
- No abbreviating for brevity. Real domain terms, spelled out. A long unambiguous name
  beats a short one every time.
- Session was about work on a repo/service → name the surface too, so the name still
  reads a month later.

Don't wait for the user to ask — if the session has no `customTitle` set yet, the harness
already nudges you every so often ("no user-set name yet") with a suggested name baked in.
That suggestion is Claude Code's own auto-title, and those run SHORT — treat it as a
starting point, not the recommendation. Expand it to outcome form per the rules above
before handing it over; relay it verbatim only if it already reads that way.
