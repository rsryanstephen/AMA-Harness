---
name: harness-memory
description: Governs the git-tracked, cross-machine memory/ store (replaces Claude Code's native local auto-memory). Use when saving a durable user preference, correction, project fact, or reference — anything the system prompt's memory instructions would normally save. Also use when asked where a rule/habit lives, why a rule didn't fire, or to add/edit/audit a memory/*.md file.
---

# Harness memory

Replaces Claude Code's native `~/.claude/projects/<cwd-slug>/memory/` auto-memory —
gitignored, and scoped to one directory's hash (invisible on other machines, and
invisible in other sessions even on the same machine if cwd differs).

This store is git-tracked in `ama-claude-harness/memory/`, junctioned into
`~/.claude/memory/` (same mechanism as `skills/`/`hooks/`), injected into every turn by
`hooks/on-prompt.sh` regardless of working directory.

## Use this instead of native auto-memory, always

Any time the system prompt's memory instructions would have you save a `user` /
`feedback` / `project` / `reference` memory — write here instead. Never write to
`~/.claude/projects/*/memory/` again.

## File format

One file per rule, `memory/<name>.md`:

```markdown
---
name: kebab-case-slug
scope: global                 # or a cwd substring, e.g. Repos/AMA_APP
type: feedback                # user | feedback | project | reference
description: One-line hook — this is the text injected every turn. ~100 chars max.
---

Rule statement.

**Why:** the reason/incident behind it.
**How to apply:** when this kicks in. Link related rules with [[other-name]].
```

- `scope: global` → injected in every session, every directory, every machine.
- `scope: <substring>` → injected only when the session's cwd contains that substring
  (e.g. `Repos/AMA_APP` matches any AMA_APP repo including the harness itself). Use the
  narrowest correct substring — don't default to `global` just to be safe.
- No hand-maintained index. The injected list is generated from every file's
  frontmatter each turn — don't create or maintain a `MEMORY.md` here.

## Same categories as native memory, same bar

`user` (role/preferences), `feedback` (corrections + confirmed approaches — save both),
`project` (ongoing work/decisions, convert relative dates to absolute), `reference`
(pointers to external systems). Same save/read discipline as the system prompt's own
memory instructions — only where it lives changes.

## Boundary with the other notes skills — don't duplicate

- Architecture/repo-structure facts (durable, still TRUE later, not just outdated) →
  `ama-architecture-notes`, not here. Add liberally, no need to ask.
- Reoccurring bug-CLASS patterns → `ama-debugging-notes`, not here. Always ask the user
  first, only for a genuinely generic class.
- A still-open, unfixed bug found in passing → a Jira ticket, not a note anywhere.
- Rule of thumb: memory-shaped = how Claude should behave / what the user wants going
  forward; the other two = how the CODE behaves.

## Adding or editing a note

1. Check it isn't already covered (`grep -l` across `memory/*.md`) or belongs in one of
   the boundary skills above.
2. Durability test: will this still be TRUE, not just outdated, once the current
   situation resolves? Point-in-time state fails this and doesn't belong here.
3. Pick the narrowest correct `scope`.
4. Terse, caveman style — `description` is injected on EVERY matching turn, keep it tight.
5. Commit to the harness repo with a ticket ref, same as any other harness change.

## Verifying the injector

Note not firing → confirm `Get-Item ~/.claude/memory` shows a `LinkType`, and check the
note's frontmatter parses (malformed YAML is silently skipped so one bad file never
breaks a turn — but that also means a typo silently drops a note with no error).
