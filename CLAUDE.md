# Global Default Claude Behavior

Apply these defaults in every repository session:

## Harness Docs — Agent vs Human
- `ama-claude-harness/AGENTS.md` (symlinked `~/.claude/AGENTS.md`) = agent source of truth for this harness — hooks, gates, skills, failure modes. Read that, not `README.md`, for how the harness works.
- `README.md` = human-only install/usage guide. Never auto-update it — only edit when a change is human-visible, and only when the user asks for it.

## First-Reply Setup (Caveman + Karpathy + Resource Efficiency + Context Hygiene)
- First reply of a session: invoke caveman, karpathy-guidelines, resource-efficiency, AND context-hygiene skills (this file's summaries are trimmed; skills have full detail). Loading skills is a side-step, not the whole reply — still fully address the user's message, same turn.
- After first reply, style/guidelines apply session-wide, no re-invoke needed.

## Skill File Edits
- Writing/editing any `skills/*/SKILL.md` — regardless of task framing: compress prose touched to caveman style. Commands, code, config, data, trigger phrases untouched, exact.
- Gate-enforced (`skill-bloat-gate.sh`): denies an overlong Edit/Write paragraph shaped like a bug-incident writeup instead of a terse tag.

## Gotcha/Lesson Placement — Discoverability First
- Documenting a learned lesson/gotcha → ask: will a future agent hitting this problem find this file? Route by the problem a reader will have, not the file you happen to have open.
- Generic lesson in a task-specific skill = write-only. Put it in the skill whose description matches the future request (create one if none fits — precedent: `ama-confluence-api`); leave one-line cross-ref at the original site if that site still needs the warning.
- Lesson stays in-place ONLY if it applies nowhere else.

## Durable Memory Goes in the Harness, Not Native Auto-Memory
- `user`/`feedback`/`project`/`reference` memory → `~/.claude/memory/<name>.md` (see `harness-memory` skill for format/scope), not native `~/.claude/projects/*/memory/` — gate-enforced (`native-memory-gate.sh`), and that store is gitignored/machine-local anyway.

## Harness Hiccups — Flag Prominently
- Hit a hiccup in an `ama-*` harness skill/script → flag it prominently in the reply, own section, AND append one line to `~/.claude/harness-gaps.md` (`- [session <shortid>, <date>] <one-line gap>` — file's own header has the full convention).
- Have context to fix it yourself → do it now, then tag the entry `**SELF-FIXED, commit <hash> — harness agent should review before clearing.**` (never delete the line yourself).
- Keep every harness fix as small as the problem needs — reuse existing patterns, cross-reference instead of restating, no new abstractions beyond what's asked.

## Issues Found Along the Way
- Found a real defect while working on something else → don't just flag it in prose and move on. See `commit-ticket/SKILL.md`'s ticket-it-or-ask rule.

## Mechanical Triggers Over Self-Recognition
- A skill meant to fire "after X happens" needs a hook behind it, not just a Skill-tool description match — self-recognition is unreliable. See `library-version-sync-reminder.sh` for the pattern.

## Subagents Must Never Return With Live Background Work
- A subagent that backgrounds work then returns leaves it stranded — no task-notification fires, and the parent can't query the child's ID. Wait synchronously, or background from the main session instead.

## Skill Invocation Errors
- `Skill(x)` errors "disable-model-invocation" → x is user-only, Skill tool can never run it. Tell user to run `/x` themselves.

## Bash Command Style
- See `bash-command-style` skill (path-as-argument over `cd`, no parallel prompt-triggering fan-out, denial handling, hook-testing gotcha). Two parts gate-enforced: `bare-cd-gate.sh` (leading bare `cd`), `parallel-fanout-gate.sh` (2nd+ call in a batch).

## CLI Output Commentary
- Hooks auto-log prompts+replies. Never append yourself → dupes + wasted tokens.
- Filename: "See … prompt in `<name> Chat.md`" pointer names it, else `<shortid> Chat.md` in cwd.
- Pointer w/ no content → real task = LAST NON-QUEUED block in the chat file — skip trailing queue-marker block(s) ("-- Q"/"--Q"/"-Q"/"- Q"/"-q"), those stay queued.
- Chat filename still fallback `<shortid> Chat.md` → pick topic, rename now (rename-topic skill), unprompted, once, before session end.
- Finished a task cleanly → run `bash "$HOME/.claude/hooks/dequeue-prompt.sh" "<current chat file>"` yourself, same turn, before ending it. Prints a queued prompt → work it, then check again, loop until empty. See `process-prompt-queue` skill for the backstop if you don't.
