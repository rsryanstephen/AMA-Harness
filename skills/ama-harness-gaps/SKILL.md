---
name: ama-harness-gaps
description: Reviewing and clearing harness-gaps.md -- the weekly UNATTENDED auto-review (task AMA-Harness-Gaps-Review, plan-then-execute on the strongest model that resolves (fable, then opus), postponed when weekly usage >=90%) and the manual "address harness gaps" pass. Use when the user says "address the harness gaps", when on-prompt.sh's WEEKLY HARNESS-GAPS AUTO-REVIEW report lands, when a NEEDS USER tag needs settling, or when the auto-run skipped/failed and you need to know why.
---

# Harness gaps review

Ledger: `~/.claude/harness-gaps.md` -- a SYMLINK into the clone. Rewrite it through the repo
path (`harness-gaps.md`), never `mv`/`sed -i` over the link: that swaps the link for a
standalone file, the repo copy keeps the old text, `git status` stays clean. Hit again
2026-09-14; recovery recipe in [[bash-command-correctness]].
Header = the rules (review order: bloat, fully fixed,
improvement, ≤1 related). Reviewed line = deleted line. `on-prompt.sh` counts `^- \[session `.

## Weekly auto-review

Runner: `scripts/harness-gaps-unattended-run.sh`. Task `AMA-Harness-Gaps-Review`, **daily
15:00** local; runner decides the day. Full mechanics + registration recipe:
`PORTABILITY.md` "Weekly harness-gaps auto-review".

Decision chain, each exits 0 quietly except where noted:
1. Weekly usage live via `hooks/lib-claude-usage.sh` (OAuth usage endpoint, ACCOUNT-WIDE
   weekly figure; models at their own weekly cap dropped from the candidates). API dead → statusline state file if <24h old → else **SKIPPED**
   (digest line). Unknown never = 0%.
2. `resets_at` local date ≠ tomorrow → skip. Reset day drifts → runner follows, no re-register.
3. Already ran for this reset (`harness-state/harness/.harness-gaps-lastrun`) → skip.
4. Usage ≥90% → **POSTPONED** (digest line, no stamp → next week's fire runs).
5. Zero gap lines → stamp, exit.
6. Leg 1: `claude -p --model <M> --permission-mode plan --session-id <uuid>`, M = first alias in
   `HARNESS_GAPS_MODELS` (default `fable opus`) the CLI serves -- unrecognized/unserved OR
   spend/usage/rate-limited => next alias (weekly pre-check reads the SHARED seven_day bucket, so a
   per-model cap still bites; account-wide limit => opus fails too, one call later, reported as FAILED),
   fresh uuid (a failed attempt burns its session id). Leg 2 reuses M. Replies
   `PLANNED` + plan. `.modelUsage` must name opus/fable/mythos, else **FAILED** before any edit.
7. Leg 2: `claude -p --resume <uuid> --permission-mode acceptEdits`. Executes, commits own paths
   (`git commit -- <paths>`, never `add -A`), pushes master. Replies `DONE` + `---DIGEST---`.
8. Digest → `harness-state/notices/harness-gaps-review.txt`, relayed once by `on-prompt.sh`.
   Plan saved `scratch/harness-gaps/plan-<date>-<sid8>.md`. Log
   `harness-state/logs/harness-gaps-review.log`.

## NEEDS USER tag

Auto-run can't ask. Entry needing a user decision gets ` **NEEDS USER (auto-review <date>)**`
appended, stays. Digest lists them. Settle with the user → delete the line (or fix, then delete).

## Seams

```bash
HARNESS_GAPS_DRY_RUN=1  bash ~/.claude/skills/ama-harness-gaps/scripts/harness-gaps-unattended-run.sh   # prints DECISION, no claude
HARNESS_GAPS_FORCE_RUN=1 HARNESS_GAPS_PLAN_ONLY=1 bash ~/.claude/skills/ama-harness-gaps/scripts/harness-gaps-unattended-run.sh  # real plan on the strongest model, nothing executed
HARNESS_GAPS_FORCE_RUN=1 bash ~/.claude/skills/ama-harness-gaps/scripts/harness-gaps-unattended-run.sh   # full run now (spends real tokens)
bash ~/.claude/hooks/lib-claude-usage.sh weekly    # "<pct>\t<reset-epoch>"
```
`HARNESS_GAPS_NOW=<epoch>`, `CLAUDE_USAGE_JSON=<file>`, `HARNESS_GAPS_FILE=<file>` for tests
(`scripts/check-gates.sh` "harness-gaps" block). Run from the MAIN session, never a subagent
(a backgrounded run inside a subagent is stranded — CLAUDE.md).

## Manual pass ("address harness gaps")

Same rules as leg 1+2, interactive: plan mode first, user picks scope, fix, suite from a temp
copy, commit own paths only, review-marker HTML comment below the ledger header. Precedent:
2026-08-28 marker in the ledger.

## Gotchas

- Usage endpoint undocumented. Starts failing → run the lib by hand, check `.credentials.json`
  still has `claudeAiOauth.accessToken`; lib triggers one `claude -p` haiku call to refresh.
- Task is `InteractiveToken`: no logon at 15:00 → `StartWhenAvailable` fires at next logon,
  still gated by "reset is tomorrow" — a day late = skipped, next week.
- Leg 2 killed by its 3h timeout → digest says FAILED with `claude --resume <sid>` to finish by hand.
