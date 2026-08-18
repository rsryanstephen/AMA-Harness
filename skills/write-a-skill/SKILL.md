---
name: write-a-skill
description: Create new agent skills with proper structure, progressive disclosure, and bundled resources. Use when user wants to create, write, or build a new skill.
---

# Writing Skills

## Process

1. **Gather requirements**: task/domain? specific use cases? executable scripts or just instructions? reference materials to include?
2. **Draft**: SKILL.md (concise) + extra reference files if content exceeds 500 lines + utility scripts if deterministic ops needed. Write body prose in caveman style (see skill) — drop filler/articles/pleasantries, keep fragments, technical accuracy exact. Never compress commands, code, config values, data, or trigger phrases in the description — those stay verbatim.
3. **Review with user**: covers use cases? missing/unclear? more/less detail needed?

## Skill Structure

```
skill-name/
├── SKILL.md           # Main instructions (required)
├── REFERENCE.md       # Detailed docs (if needed)
├── EXAMPLES.md        # Usage examples (if needed)
└── scripts/           # Utility scripts (if needed)
    └── helper.js
```

## SKILL.md Template

```md
---
name: skill-name
description: Brief description of capability. Use when [specific triggers].
---

# Skill Name

## Quick start

[Minimal working example]

## Workflows

[Step-by-step processes with checklists for complex tasks]

## Advanced features

[Link to separate files: See [REFERENCE.md](REFERENCE.md)]
```

## Description Requirements

Description is **the only thing your agent sees** when choosing which skill to load — surfaced in the system prompt alongside every other installed skill.

**Goal**: agent knows (1) what capability this provides, (2) when/why to trigger it (keywords, contexts, file types).

**Format**:

- Max 1024 chars
- Write in third person
- First sentence: what it does
- Second sentence: "Use when [specific triggers]"
- Triggers = wording of the FUTURE request that needs this skill (the problem a reader will have), not the current task's wording — that's what makes documented lessons findable (see CLAUDE.md "Gotcha/Lesson Placement")

**Good example**:

```
Extract text and tables from PDF files, fill forms, merge documents. Use when working with PDF files or when user mentions PDFs, forms, or document extraction.
```

**Bad example**:

```
Helps with documents.
```

Bad example gives no way to distinguish this from other document skills.

## When to Add Scripts

Add utility scripts when: operation is deterministic (validation, formatting), same code would be generated repeatedly, or errors need explicit handling. Saves tokens, more reliable than generated code.

## When to Split Files

Split into separate files when: SKILL.md exceeds 100 lines, content has distinct domains (finance vs sales schemas), or advanced features are rarely needed.

## Review Checklist

After drafting, verify:

- [ ] Description includes triggers ("Use when...")
- [ ] SKILL.md under 100 lines
- [ ] Body prose in caveman style, no filler — commands/code/config/data/triggers untouched
- [ ] No time-sensitive info
- [ ] Consistent terminology
- [ ] Concrete examples included
- [ ] References one level deep

## Editing Existing Skills

Same rule applies: when updating any skill's SKILL.md, compress prose you touch to
caveman style. Never alter commands, code, config values, data, or trigger phrases —
only narration gets trimmed.

**A skill file is instructions, not a changelog.** Confirmed recurring problem: edits
kept including the STORY of the bug/incident that prompted a change ("release X's
notes wrongly included ticket Y because the old flow did Z...") instead of just the
current instruction. State what to do now. A one-line "confirmed real gap:"/"confirmed
real bug:" tag naming the consequence is fine; a multi-sentence retelling of what broke
and why is not — the commit message/Jira ticket already own that history. Test: would
this sentence still make sense to someone who never knew the old behavior existed? If
it only makes sense as "here's what changed," cut it.

**Mechanical backstop**: `hooks/skill-bloat-gate.sh` denies an Edit/Write to any
`skills/*/SKILL.md` when a paragraph both contains "confirmed real" and runs long.

## Skills directory is a junction — no throwaway files

`~/.claude/skills/...` paths: Write refuses (junction into `ama-claude-harness`), and
writing the resolved repo path trips the README-currency hook for a file that shouldn't
be tracked at all. Throwaway/one-off scripts → session scratchpad; only real skill
content goes here, via the resolved repo path.

**If an edit can be reduced to one line, it must be.** Per explicit user instruction —
don't stop at "acceptable length," compress to the minimum that still states the
instruction.
