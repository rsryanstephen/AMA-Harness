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
- **Default subagent model = Sonnet, mechanically.** `settings.json` env sets
  `CLAUDE_CODE_SUBAGENT_MODEL=sonnet` (2026-09-14) -> any spawn with `model` omitted lands on
  Sonnet, every agent type (general-purpose, Explore, Plan). No self-recognition needed --
  the old "remember to tier" nudge was honored ~1/3 of the time (3-week transcript tally:
  118 Explore + 25 general-purpose spawns inherited Fable).
  - **Easy** (mechanical, low-judgment -- summarize known files, targeted grep-and-report,
    lookups) -> `model: "haiku"`, opt down.
  - **Medium** (bounded synthesis, scoped research, code search-and-summarize) -> omit
    `model`. Sonnet by default.
  - **Hard/high-stakes** (real architectural judgment, adversarial verification, wrong call
    costly) -> `model: "<session model>"`, opt UP explicitly -- `subagent-model-tiering-gate.sh`
    names it per spawn (fable, or opus once a cap dropped the session there); never a fixed
    `"opus"` ([[regulation-tasks-on-sonnet]]). Rare: that work normally stays in the main
    session, not a delegated agent. Omitting `model` no longer inherits the parent.
  - **Workflow `agent()` -- same env default.** 396/396 workflow agents ran Sonnet on
    2026-10-21/22 with no `model` opt in any of 14 scripts, despite the authoring reference's
    "inherits the main-loop model". Mechanical stages: `model:'haiku'` / `effort:'low'`;
    judge/verify stages only: the session model.
  - **Toggle**: `SUBAGENT_MODEL_TIERING=off` in the env block silences the gate's budget
    nudge only. The Sonnet default is the env var -- remove `CLAUDE_CODE_SUBAGENT_MODEL` to
    restore inherit-parent.
  - **Not a ceiling** -- the main agent's model IS switchable per-skill, see
    "Skill-level model tiering" below.
- **Code-scan prompts name the ref**: `git grep <pattern> origin/develop -- <paths>`, not the main
  clone's working tree (stale branch → false "doesn't exist", 2026-10-20). [[grep-usage]].
- **Batch related work into fewer, larger-scoped agents** rather than many small spawns —
  each spawn re-pays setup/context cost independently.

## Skill-level model tiering — `model:` in SKILL.md frontmatter

**What the tag does (probe-proven 2026-10-22, CLI 2.1.308, 2 trials each):** `model:`
engages ONLY when the USER slash-invokes the skill -- `/skill args` runs that whole turn on
the tag (haiku on every assistant message, tool calls included). A Skill-tool invocation by
Claude IGNORES it: the turn stays on the session model. The 2026-08-31 "inert" finding
(session 1ce24e66, v2.1.251) was a Skill-tool turn, not a CLI bug. Re-probe after a CLI
upgrade: scratch skill tagged `model: haiku`, then
`MSYS_NO_PATHCONV=1 claude -p --model sonnet --verbose --output-format stream-json "/x"`
and count `.message.model` (without `MSYS_NO_PATHCONV` git-bash rewrites `/x` to a Git path).

**So a tag means "when the user runs this by hand, run it on X."** Nothing Claude does
mid-turn is affected by it. Policy ([[regulation-tasks-on-sonnet]], user 2026-10-22):
- Regulation runbooks the user slash-runs -> `model: sonnet`: deploy (`ama-deploy-release`,
  `ama-octopus-deploy`, `ama-cut-release-branch`), `ama-env-sleep`, monitors
  (`ama-aws-notices`, `<amaSupportChannelName>-notices`, `ama-embs-notices`, `ama-followups`,
  `ama-embs-reminders`), log checks (`ama-graylog-search`, `ama-cloudwatch-search`), syncs
  (`ama-library-version-sync`, `ama-search-shared-version-sync`), `ama-vpn-dns-outage`.
  Earlier, sonnet: `ama-standup-notes`, `ama-release-notes`, `ama-team-meeting-notes`,
  `harness-setup`, `company-slides`; haiku: `open-chat-file`, `relocate-session`.
- Reasoning skills -> untagged: `ama-hotfix` (the fix inside needs the session model; its
  ship leg is `ama-deploy-release`), `ama-pr-review`, `ama-ui-verify`, `ama-report-debug`,
  `ama-terraform-backbone`, `ama-harness-gaps`, DB access, `ama-api-tests`.
- First-reply, nudge-driven and mid-task reference skills -> never slash-run, tag
  irrelevant, leave untagged.
- A tagged skill Claude invokes itself (e.g. `ama-deploy-release` inside a hotfix turn) runs
  on the session model. To push a Claude-initiated leg to Sonnet: delegate it to an Agent
  (`model:"sonnet"`, explicit brief) or a `context: fork` + `model:` + `background: false`
  skill -- the fork sees no session context, needs a bounded handoff, must never ask the
  user. Worked example: [[commit-ticket]] -> [[commit-ticket-jira]]. The deploy runbooks
  confirm with the user before every major step, so as written they are NOT fork candidates.

**Canonical tier check -- never self-report, never `/status`:**
`jq -r 'select(.type=="assistant") | .message.model' ~/.claude/projects/<proj>/<session>.jsonl | sort | uniq -c`
The transcript records the real model per assistant message; a model cannot reliably
introspect its own tier, and `/status` shows the session model regardless of a turn override.

**Toggle — read this precisely.** `SKILL_MODEL_TIERING=off` silences
`skill-model-tiering-gate.sh`'s warning ONLY. An env var CANNOT disable a `model:` already
in frontmatter — the CLI applies that, not Claude's judgment. The `SUBAGENT_MODEL_TIERING`
analogy does NOT carry (that one works only because Claude *chooses* the Agent `model`
param). Turning a real tier off = edit the frontmatter.

**A model excluded by an org `availableModels` allowlist is SILENTLY ignored** — session
keeps its model, no error. Check `/model` lists the tier before relying on it.

## Always-on injection cost

Anything a `UserPromptSubmit` hook injects is paid on EVERY prompt of EVERY session --
the most expensive place a token can live. `on-prompt.sh`'s memory list + chat-log rules
were ~700-900 tokens/prompt; now full on prompt 1 then every 10th, short pointer between
(492 -> 59 words). Before adding anything to injected context, ask whether it needs to be
there every prompt or just periodically.

**Trimming always-on context: reliability beats tokens** (user rule 2026-10-28). Skill
`skillOverrides` `name-only`/`user-invocable-only`, or cutting a CLAUDE.md rule, only when
EVERY trigger it carries is delivered mechanically (deny text / injected hook text naming
the same instruction). "A hook names this skill" covers the hook's trigger, not the
description's others -- 9 notice/monitor skills each had one no hook fires on. Default:
shorten prose, keep every trigger phrase.

**Subagent report budgets -- state one on EVERY Agent prompt.** The parent pays the whole
report into context, and it stays there for the rest of the session. Worse than a big tool
result: a report reads as signal, so nothing later discounts it.

- Rough caps: lookup / grep-and-report **<=200 words**, scoped investigation **<=400**,
  genuinely broad audit **<=800**.
- Ask for shape too, not just length: bullets, `file:line`, no preamble, no restating the
  question, no long code blocks. Length alone still buys prose.
- Measured 2026-09-01: unbudgeted Explore agents returned 3-5k-token reports; the same
  tasks with a cap came back at ~400 words and lost nothing that mattered.
- `subagent-model-tiering-gate.sh` nudges when a spawn has no cap (warn-only -- a genuinely
  open-ended audit legitimately has none). Budget is its ONLY check now; model default is env.

## Session context hygiene

- **`/compact` after a work phase genuinely concludes**, before pivoting to an unrelated
  task in the same session — don't let unrelated phases pile into one ever-growing
  context.
- **`/clear` (new session) when switching to something unrelated**, rather than
  continuing in an already-large session purely out of convenience.
- **A background/loop session open 8+ hours with no active back-and-forth is a smell,
  not a given** — check whether it should still be running rather than assuming
  long-lived == intentional.

## MCP tool-result bloat (Atlassian was the biggest single source — 27%, then 42% — and is now RETIRED)

- **Atlassian MCP retired 2026-08-31** (user instruction, token cost): all Jira/Confluence
  work goes through [[ama-jira-api]]/[[ama-confluence-api]] REST scripts. Never call an
  `mcp__claude_ai_Atlassian__*` tool even if the connector still appears; if one shows up
  in the tool list, that's the cue to remind the user to disconnect it in claude.ai.
  The rules below stay for every OTHER MCP server (Gmail, Slack, Calendar...).
- **Always scope MCP calls to the minimum needed** — pass minimal field selections
  rather than fetching full descriptions/comments/changelogs when
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
- **`claude-in-chrome`: SCREENSHOTS are the biggest driver** (base64 images -- see
  `hooks/chrome-verify-compact-nudge.sh` + `session-ctx-sizes.pl` headers). Measured 20% of
  one session. Text tools first: `read_page`, `get_page_text`, `find`. `computer` screenshot
  ONLY when the answer is visual (layout, rendering, wrong colour). A screenshot to read text
  costs every later turn, not one.
- **Verify loop done -> close the tab.** `chrome-verify-compact-nudge.sh` fires on
  `tabs_close_mcp`; `chrome-activity-track.sh` + `on-prompt.sh` nudge anyway after 2 prompts with no
  browser call (forgotten tab). Both relay "recommend /compact"; one guard, re-armed on /compact.
- **Long browser work -> run it in a SUBAGENT.** Its screenshots never enter the main
  context; only the report returns. The only real fix once a loop is many screenshots deep.
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
