---
name: ama-hotfix
description: Cut, test, and ship an emergency production hotfix outside the normal release cycle -- hotfix/X.Y.Z+1 branched from master, autodeploys to Staging, merges to master+develop and deploys to Production once verified. Use when the user says "hotfix", "HF" (synonym), "we need a hotfix", "patch production now", or asks to fix something urgently in production outside a normal release. Companion to ama-cut-release-branch (normal scheduled release cut) and ama-deploy-release (reused here for the merge/production-deploy leg).
---

# AMA_APP hotfix

**"HF" is a synonym for "hotfix"** -- same workflow, no need to ask which is meant.

**Different from a normal release cut**: branches off `master` (current production
state), not `develop` -- a hotfix must not pull in unrelated in-progress develop
changes. Scoped to whichever repo(s) actually need the fix, not the whole fleet.

## Step 1 — Resolve the hotfix version and create the branch

Next hotfix version = last release's version, PATCH+1 (`128.0.0` -> `hotfix/128.0.1`;
one exists -> `128.0.2`).

**Hotfix numbers are FLEET-WIDE (one Jira version list, all repos) -- repo-branches-only
check picks collisions.** Resolve N from Jira:
```bash
curl -sS -u "<user.email>:$ATLASSIAN_API_TOKEN" \
  "https://yourorg.atlassian.net/rest/api/3/project/PROJ/versions" \
  | jq -r '.[].name | select(startswith("hotfix/<MAJOR>."))'
```
Next N = max across that list AND the repo's branches, +1.

```bash
cd "$(bash ~/.claude/hooks/lib-harness-repos.sh path <repo>)"
git fetch origin
git checkout -b hotfix/<version> origin/master
git push -u origin hotfix/<version>
```

## Step 2 — Ticket + fix + push

Create/resolve the ticket immediately, per [[commit-ticket]] (title prefix `On Prod: `
-- a hotfix is by definition a production bug). Commit the fix, ticket ref leading the
message as always.

**Set the ticket's Jira Fix Version to `hotfix/<version>`** (same version resolved in
Step 1, e.g. `hotfix/128.0.1`) via [[ama-jira-api]]'s `jira-edit-issue.sh` (payload
`{"fields": {"fixVersions": [{"name": "hotfix/<version>"}]}}`) or MCP `editJiraIssue` --
`fixVersions: [{"name": "hotfix/<version>"}]`. If that version doesn't exist in Jira yet, same gap as
[[ama-cut-release-branch]]'s Step 3a: no tool here creates one, tell the user to add it
in Jira project settings first, don't guess a workaround.

**Once the version exists (user confirms creation, or found already created): set its
description** — [[ama-jira-api]]'s "Version descriptions" section (Octopus shows it as
the release's Description). `confirm-jira-version.sh` prints this nudge too.

**`admin`/`exporterplus` fix -- run [[ama-ui-verify]]'s self-verify → fix loop → user
local sign-off before pushing to hotfix branch, don't just spot-check once.**

**Confirm the push auto-deploys to Staging**, same as `release/*`
([[ama-cut-release-branch]]). `hotfix/*` is already treated identically to
`release/*` in at least one repo's build tooling (`exporterplus`), but this isn't
confirmed end-to-end for every repo/Octopus channel yet. If it doesn't land on
Staging as expected, check that repo's Octopus channel/lifecycle rule
([[ama-octopus-deploy]]) rather than assuming the branch pattern itself is wrong.

Confirmed end-to-end for `reports` (`hotfix/128.0.2` → build #233 → release 2.0.0.233 on
its **Hotfix** channel `Channels-342` → auto-deployed YourProduct-Staging, no manual step).
Projects carry a dedicated Hotfix channel — list them with
`GET /api/Spaces-1/projects/<id>/channels` before assuming a hotfix needs manual promotion.
**Confirm via the ECS image tag, not the Octopus task state** — check the task-def tag
actually flipped to the new version ([[ama-octopus-deploy]]'s deployed-vs-running rule).

**If the hotfix touched report fields or SqlTemplates, run a `main` cache update against
Staging once it lands — before verifying anything.** Deploying does not refresh the
Redis-cached templates/SqlTemplate set, so Step 3's verification would otherwise just measure
the stale state, and a removed SqlTemplate column 500s the report instead of merely serving
stale data. A narrower `sqltemplates` update is NOT sufficient (confirmed — it never clears
search's copy). Trigger/monitor calls (HTTP 200 only means "queued"):
[[ama-graylog-search]]'s `CACHE-UPDATE-DEBUGGING.md`. Production is covered separately by
[[ama-deploy-release]]'s Step 4a — each environment needs its own run.

## Step 2a — Once on Staging and stable: testable → Ready to Test, else → Test Complete

**Column meaning**: `Review` = open PR. `QA` = pushed/merged to `develop` (QA env).
Final target stays `Ready to Test`/`Test Complete` — but board blocks In Progress →
target directly. Hop `Review` → `QA` → target ([[commit-ticket]]'s intermediates rule).

`Ready to Test` is a real, separate Jira status — confirmed via JQL
(`status = "Ready to Test"`, id `10171`, category "In Progress"), NOT the same status
object as `QA` (id `10121`, "PR Merged - Deployed and ready to test") despite the
similar-sounding description. Don't reuse `QA`'s transition here even if it looks like
the closest match by description — confirm the real transition via [[ama-jira-api]]'s
`jira-get-transitions.sh` on the specific ticket, id may differ per ticket/workflow.

**Do this automatically once Staging is confirmed stable — watch for it, follow up, and
transition without waiting to be asked.** This is ticket bookkeeping, not a deploy
action — it doesn't need the same explicit go-ahead Step 3/Step 4 (Production) require.
Transition via [[ama-jira-api]]'s `jira-transition-issue.sh` or MCP `transitionJiraIssue`;
add the testing-instructions comment via `jira-add-comment.sh` or MCP
`addCommentToJiraIssue`.

Decide per ticket:

**If a human can manually verify the fix** (a UI change, an observable behavior):
1. Hop `Review` → `QA` → **Ready to Test** (re-check `jira-get-transitions.sh` each hop).
2. **Add a comment with exact testing steps** -- not just "please test," concrete
   instructions: what to click/call, what the expected vs. broken behavior looked
   like, and the Staging URL for the affected page/endpoint. Include direct URLs
   whenever a log check is part of verifying it, same link conventions as
   [[ama-graylog-search]]:
   - A specific message: `<graylog.host from harness-config.json>/messages/<index>/<message._id>`
   - A search window: `.../streams/<stream-id>/search?rangetype=absolute&from=<ISO>&to=<ISO>`
   Don't invent a Staging URL if it isn't already known from this session's own
   investigation -- confirm it rather than guessing a domain.

**If there's no manual test path** (an internal-only fix, e.g. a null-guard or log
change with no user-observable behavior) → hop `Review` → `QA` → **Test Complete**,
no testing-instructions comment needed. Same conditional applies to
[[ama-cut-release-branch]]'s Step 3a, per-ticket (a release bundles many tickets, not
all the same kind of fix).

## Step 3 — Verify on Staging, wait for explicit go-ahead

Same offer-only verification as any other Staging push -- see
[[ama-cloudwatch-search]]'s `DEPLOY-VERIFICATION.md`. **Never merge/deploy further
without the user explicitly saying it's ready** -- verified-on-Staging is a hard gate,
not a suggestion.

## Step 4 — Once approved: merge to master + develop, deploy to Production

Same flow as a normal release from here, just sourced from `hotfix/<version>` instead
of `release/<version>` — follow [[ama-deploy-release]] starting at its Step 0 (Staging
log check, window = since this hotfix branch was cut) **through Step 7a only** (ticket-
to-Done sweep), substituting the hotfix branch name everywhere `release/<version>` is
referenced. Don't re-derive or duplicate those steps here.

### The develop back-merge is NOT optional, and NOT deferrable

`master` **and** `develop`, same session, every hotfix. Delegating this to
[[ama-deploy-release]] Step 1 was not enough on its own — hotfixes 128.0.1-128.0.7 each
shipped to master and production with the develop half skipped, and the drift only
surfaced at the release/129.0.0 wrap-up: six repos with conflicting `.csproj` library
versions, and `reports` with a real semantic conflict (develop had dropped
`report.Report = toUpdate;`, the hotfixes restored it on master) that took a live
investigation to settle weeks after anyone remembered why.

**Resolve conflicts on the spot** — that's the point of doing it now rather than later.
Two rules with precedent:
- `.csproj` PackageReference conflict → latest version of each package. Confirm "latest"
  against **CodeArtifact publish dates**, not the version string: the Bitbucket repo
  migration reset some build counters, so a higher number isn't automatically newer.
  ```bash
  aws codeartifact describe-package-version --domain yourorg --domain-owner 000000000000 \
    --repository <repository> --format nuget --region us-east-1 \
    --package <pkg> --package-version <ver> --query 'packageVersion.publishedTime'
  ```
- Hotfix code conflicting with develop → **master wins**; that's what production runs.

Then build + test before pushing develop. Never `git merge --abort` and leave it.

`develop-backmerge-reminder.sh` (`PostToolUse`) fires on any master push whose commit
isn't on develop yet — mechanical backstop, per CLAUDE.md's "Mechanical Triggers Over
Self-Recognition".

**Stop before Step 8 — a hotfix does not get release notes.** Per explicit user
instruction: a hotfix is an emergency out-of-cycle patch, not a scheduled release, so
the release-notes/PDF/email pipeline doesn't apply here.

**The hotfix ticket must end at Done once deployed to production** — this is already
covered by the reused flow, not a separate step: the master merge moves it to Test
Complete (per [[commit-ticket]]'s push-to-master rule), then Step 7a sweeps every
Test-Complete ticket to Done. Confirm it actually landed there once Step 7a runs —
don't assume the chain worked silently. **Run Step 7a unprompted, immediately after
verifying the deploy (ECS image tag, not health alone)** — per [[commit-ticket]]'s
"Deployed to production" line this no longer needs the user to ask first, and the
`octopus-prod-deploy-ticket-sweep-reminder.sh` hook fires on the production deployment
API call itself as a mechanical backstop if it's still overlooked.
