---
name: resource-efficiency
description: General usage/cost-reduction discipline — model tiering for subagents, session context hygiene, and minimizing MCP tool-result bloat. NOT AMA-specific, applies to every session/project. Invoked unconditionally at session start via CLAUDE.md's First-Reply Setup (see there) — once loaded it applies session-wide like caveman/karpathy-guidelines, no re-invoke needed. Re-consult before spawning a subagent, before a broad/expensive MCP call (Jira/Confluence search, full-repo sweep), or when a session's context is visibly ballooning.
---

# Resource efficiency

The main cost drivers: subagent-heavy sessions, very high context (>150k), very long
sessions (8h+), and the `atlassian` MCP server. Optimize these, not marginal stuff.

## Subagents — the single biggest lever

- **Don't spawn one at all if the task is answerable directly, quickly.** Reserve
  Agent/Task for genuinely parallel or context-isolating work (matches the Agent tool's
  own guidance) — not a reflex for anything multi-step.
- **Tier the `model` param by task complexity every time you spawn one — concrete
  mapping, not a vague "consider a cheaper model":**
  - **Easy** (mechanical, well-defined, low-judgment — reading/summarizing known files,
    a targeted grep-and-report, simple formatting/lookups) → `model: "haiku"`.
  - **Medium** (bounded synthesis, multi-step but not deeply ambiguous — a scoped
    research question, a moderate code search-and-summarize) → `model: "sonnet"`.
  - **Hard/high-stakes** (real architectural judgment, ambiguous scope, adversarial
    verification, anything where a wrong call is costly) → omit `model` (inherits the
    parent/session model). Don't downgrade these — that's false economy.
  - This uses the Agent tool's own `model` parameter directly — no hook or extra
    infrastructure needed, this mechanism is already confirmed working every time a
    subagent is spawned.
  - **Toggle**: if the shell env has `SUBAGENT_MODEL_TIERING=off` (set in `settings.json`'s
    `env` block, same pattern as `CLAUDE_CODE_USE_POWERSHELL_TOOL`), skip all of the
    above and just inherit the parent model for every subagent, no tiering. Check for
    this before applying the mapping.
  - **Known hard ceiling, don't try to work around it**: this tiering only applies to
    subagents. There is no supported mechanism (hook, setting, or otherwise) for the
    *main* agent's own model to be switched automatically mid-session based on task
    complexity — that's a real platform limit, not a gap in this skill. If the main
    agent should run cheaper for a batch of easy work, that requires the user to run
    `/model` themselves at session start; don't suggest or attempt an automatic
    workaround for this.
- **Batch related work into fewer, larger-scoped agents** rather than many small spawns —
  each spawn re-pays setup/context cost independently.

## Session context hygiene

- **`/compact` after a work phase genuinely concludes**, before pivoting to an unrelated
  task in the same session — don't let unrelated phases pile into one ever-growing
  context.
- **`/clear` (new session) when switching to something unrelated**, rather than
  continuing in an already-large session purely out of convenience.
- **A background/loop session open 8+ hours with no active back-and-forth is a smell,
  not a given** — check whether it should still be running rather than assuming
  long-lived == intentional.

## MCP tool-result bloat (Atlassian confirmed the biggest single source — 27%, then 42%)

- **Always scope MCP calls to the minimum needed** — pass minimal `fields` arrays on
  `getJiraIssue` and Jira searches alike (e.g. `["summary","status"]`, not the default
  full set or `"*all"`) rather than fetching full descriptions/comments/changelogs when
  only status or a summary is needed.
- **Field-scoping has a floor — some fields don't get smaller.** `assignee`/`status`
  come back as large fixed-shape nested objects (avatarUrls at 4 resolutions, `self`
  links, `statusCategory`) no matter what `fields` you pass. Skip requesting a field
  entirely when you don't actually need it (don't fetch `assignee` just to read
  `status`), and prefer ONE JQL search with `fields` over N individual `getJiraIssue`
  calls — call count matters as much as scoping.
- **A full Confluence page fetch (`contentFormat="html"`) can be tens of thousands of
  characters** — `/compact` right after that fetch+edit round-trip, don't carry it into
  unrelated later work in the same session.
- **Tool results stay in context for the rest of the session** — a broad call made once
  early keeps costing on every later turn. Prefer several narrow, targeted calls over one
  broad one "just in case," and `/compact` after a heavy batch of MCP calls (e.g. bulk
  ticket operations) once done.
- **Check for redundant parallel MCP connections** (e.g. two separate Atlassian
  integrations active at once) — if one's redundant, that's double schema/result
  overhead for no benefit.

## Local-machine resource use (memory/CPU) — token efficiency still wins ties

**Token efficiency always comes first.** The rules below are for when a choice is free
on tokens but wasteful locally — never trade tokens away to save local resources.

- **Searching file content** (raw bash `grep`, or scoping a recursive search) — see
  [[grep-usage]] (`grep.exe` hit 6GB RAM, twice).

## General principle for any broad/expensive action

Before a wide sweep (log search across a long time range, full-repo agent fan-out,
exhaustive querying), try a narrower/cheaper pass first — widen only if that comes back
empty or insufficient, not by default.
