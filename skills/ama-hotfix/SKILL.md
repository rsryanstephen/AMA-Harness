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

Hotfix numbers are **FLEET-WIDE** (one Jira version list, every repo), and an existing
version is **someone else's reservation** — never reuse one. Both facts are in the script:
```bash
bash ~/.claude/skills/ama-jira-api/scripts/jira-version.sh next hotfix <MAJOR> <repo-dir>   # max(Jira list, origin branches)+1
bash ~/.claude/skills/ama-jira-api/scripts/jira-version.sh unclaimed hotfix/<version>       # exit 0 = no description AND no tickets
```
`unclaimed` exit 1 → it belongs to another fix, take the next number. Then **create it
yourself** (Step 2's `jira-version.sh create` + `confirm-jira-version.sh`), never a request
to the user. `.confirmed-jira-versions` proves EXISTENCE, not ownership.
`hotfix-version-claimed-gate.sh` blocks the branch mechanically but needs network — run
`unclaimed` regardless.

```bash
repo="$(bash ~/.claude/hooks/lib-harness-repos.sh path <repo>)"   # the SHARED main clone
git -C "$repo" fetch origin
wt="$(bash ~/.claude/scripts/worktree-add.sh <repo> hotfix-<version> hotfix/<version> origin/master)"   # ~/Repos/AMA_APP/.worktrees/<repo>-hotfix-<version>
git -C "$wt" push -u origin hotfix/<version>
```

**Worktree, never `git checkout` in the main clone** -- other sessions work there and a
checkout swaps their branch under them ([[commit-ticket]] `SHARED-REPO.md`; PROJ-15801,
2026-10-14). Build, commit and push from the worktree path.

**Local branch with that name already exists, or repo already ON it → check the cargo
first**: `git log origin/master..HEAD --oneline`. Anything there you didn't put there =
stowaways from a parked route — do NOT build on top. Recreate from origin/master.
Confirmed live 2026-08-05→07: parked local `hotfix/128.0.1` in `reports` carried two
cherry-picked 15278 commits; the 15286 session committed on top and shipped them to prod
unnoticed. `hotfix-stowaway-gate.sh` denies the commit mechanically (>2h-old ahead
commits, no upstream); ack via `~/.claude/.hotfix-stowaway-ack` only AFTER reviewing.

**Abandoning/parking a hotfix route = clean up SAME TURN**: `git -C "$repo" worktree remove
"$wt"`, then delete the local branch(es) in every repo touched. A parked branch is a loaded trap for the next
session that computes the same version number.

## Step 1a — Assess regression risk from the diff, BEFORE writing the fix

Not post-hoc at Step 2a. Same diff-based method as
`memory/ready-to-test-regression-comment.md` (shared libs, changed signatures, shared
queries/mappers, DI wiring) -- run it now, against the intended change, not the finished
diff. High risk (e.g. touches a published NuGet lib consumed by other repos) -> name what
will be exercised on Staging and why, before Step 2's code lands. Low risk -> one line is
enough. Step 2a's regression comment reuses this assessment, doesn't invent one from
scratch after the fix is already on Staging.

**Defect traced to an earlier change at a shared point (builder, lib, template)?** This bug is
one shape of it -- sweep the change's OTHER consumer shapes before shipping, or the next shape
ships as its own On-Prod bug (15801 → 15808, next day). [[ama-debugging-notes]]'
`SHARED-CHOKEPOINT-CHANGES.md` (SQL: `rs-explain-shapes.sh` once the hotfix runs on Staging).

**Fix carries a DB migration?** Unreleased develop migrations numbered below it get SKIPPED by
the next release (high-water mark). Check first: `PERSISTED-DATA-REWRITES.md` item 7.

## Step 2 — Ticket + fix + push

Create/resolve the ticket immediately, per [[commit-ticket]] (title prefix `On Prod: `
-- a hotfix is by definition a production bug). Commit the fix, ticket ref leading the
message as always.

**exportproducer hotfix before release 131: cherry-pick develop 9c2c3c6 (task role) into it** -- Staging's old key is gone (PROJ-14687). Temporary; removal reminder set.

**Hotfixing a published NuGet lib?** `package.sh` libs: hotfix branch publishes CLEAN
`<VersionPrefix>.<build>` (PROJ-15418). `search` publishes suffixed; every consumer needs its
OWN hotfix, same session -- see [[ama-search-shared-version-sync]] (other libs: [[ama-library-version-sync]]).
Read the real version from CodeArtifact (`aws codeartifact list-package-versions`), never assume.
Two things to expect, neither a reason to stop:
- The lib's master may be AHEAD of what production consumers pin, so its package drags
  newer transitive deps in -> `NU1605` downgrade errors in the consumer. Resolve per this
  skill's `.csproj` PackageReference rule below (latest of each, confirmed by CodeArtifact
  publish date). Do NOT re-cut the hotfix branch off an older commit: the first version is
  already published and `--skip-duplicate` means it can't be rebuilt.
- Baseline first. Build the consumer on its ORIGINAL pin and see what's already red, so a
  pre-existing failure isn't misread as caused by the hotfix.

**Set the ticket's Jira Fix Version to `hotfix/<version>`** (same version resolved in
Step 1, e.g. `hotfix/128.0.1`) via [[ama-jira-api]]'s `jira-edit-issue.sh` (payload
`{"fields": {"fixVersions": [{"name": "hotfix/<version>"}]}}`) or MCP `editJiraIssue` --
`fixVersions: [{"name": "hotfix/<version>"}]`.

**If the version doesn't exist yet, CREATE IT — don't ask the user to.** This was long
documented as impossible; it isn't, and both create and release round-trip cleanly
(confirmed 2026-08-18):
```bash
bash ~/.claude/skills/ama-jira-api/scripts/jira-version.sh create "hotfix/<version>" "<defect + fix, 1-3 sentences>"
bash ~/.claude/hooks/confirm-jira-version.sh "hotfix/<version>"
```
The script refuses to create a name that already exists, which is the right failure: an
existing version is someone else's reservation (see Step 1). Resolve the number by the
max+1 rule FIRST — being able to create one makes taking the wrong number easier, not
harder.

The description is not optional — Octopus shows it as the release's Description. `create`
takes it inline; `jira-version.sh describe <name> <text>` sets it later.

**`admin`/`exporterplus` fix -- run [[ama-ui-verify]]'s self-verify → fix loop → user
local sign-off before pushing to hotfix branch, don't just spot-check once.**

**The push auto-deploys to Staging** — `hotfix/*` → the project's dedicated **Hotfix**
channel → lifecycle auto-deploys Staging, no manual promotion. Take this as given; the
channel/lifecycle ids and the confirmed-repo list live in [[ama-octopus-deploy]]'s
`OCTOPUS-REFERENCE.md` ("Hotfix channel auto-deploys to Staging"). **Don't go walking
`/channels` + `/lifecycles/{id}` to re-derive it** — only dig if a push demonstrably does
NOT land on Staging.

Confirmed end-to-end: `reports` (`hotfix/128.0.2` → build #233 → release 2.0.0.233 →
YourProduct-Staging), `exporterplus`, `export`.

**Confirm via the ECS image tag, not the Octopus task state** — check the task-def tag
actually flipped to the new version ([[ama-octopus-deploy]]'s deployed-vs-running rule).
**Exception: `exporterplus` is an S3 bundle, not ECS** — its ECS service is a static host
whose tag never tracks releases; confirm via Octopus `Projects-65` progression `Success`
PLUS a behavioral probe (see the S3-bundle section in [[ama-octopus-deploy]]).
A repo may create several Octopus releases from one push (`export` → 3); check the project
whose code actually changed.

## Cache update gate — run BEFORE Step 2a if this hotfix touched report fields, SqlTemplates or SQL builders

**Own step, not a footnote — this was buried as Step 2's last paragraph and got skipped
entirely on hotfix/129.0.9-.11 as a result (confirmed live 2026-08-25: zero Staging
cache-update executions ran between the hotfix pushes and Production deploy).** Same
trigger condition [[ama-deploy-release]] Step 4a uses for Production: touched report
fields, SqlTemplates, Search.Shared's SQL builders, search's result post-processing
(Search.Shared Services/Query/Executor/Formatters, Search.Domain result builders — the cache
stores the processed result) or fieldtablemapper's mappings (anything that changes the SQL a
report emits or the values it returns) → run a `main` cache update against Staging once the push lands — before Step 3's
verification, or that verification just measures the stale cached result. Didn't touch
any → skip this step. **The invalidation belongs to the deploy** (user rule 2026-09-27):
never verify by sorting a column or editing criteria to dodge a cached result, and never
leave it to a tester or client to. QA/Staging get NO automatic cache update — their data
month moves only when someone runs `main` (`memory/ama-cache-update-after-deploy.md`).

Deploying does not refresh the Redis-cached templates/SqlTemplate set, and a removed
SqlTemplate column 500s the report instead of merely serving stale data. A narrower
`sqltemplates` update is NOT sufficient (confirmed — it never clears search's copy).

**First:** `bash ~/.claude/skills/ama-cloudwatch-search/scripts/wait-ecs-rollout.sh staging <services>`
— a still-rolling deploy drains the API task holding the Step Functions token and the
execution burns to `States.Timeout` (Production, 2026-08-25; Staging is not immune).

Trigger/monitor calls (HTTP 200 only means "queued"), the state machine to watch
(`<env>=staging`), and the Graylog completion line: [[ama-graylog-search]]'s
`CACHE-UPDATE-DEBUGGING.md`. Production is covered separately by [[ama-deploy-release]]'s
Step 4a — each environment needs its own run, it does not carry over.

## Step 2a — Once on Staging and stable: testable → Ready to Test, else → Test Complete

**Column meaning**: `Review` = open PR. `QA` = pushed/merged to `develop` (QA env).
Final target stays `Ready to Test`/`Test Complete` — but board blocks In Progress →
target directly. Hop `Review` → `QA` → target ([[commit-ticket-jira]]'s intermediates rule).

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

Decide per ticket. **Route on BLAST RADIUS, not on UI-testability** (user instruction
2026-08-21, replaces the old "can a human manually verify it" test): anything downstream of
the change could break → **Ready to Test**, even with no click path. Not-easily-UI-testable
is NOT a reason for Test Complete -- the testing steps become a log/DB/API check instead.

**Material blast radius, however small:**
1. Hop `Review` → `QA` → **Ready to Test** (re-check `jira-get-transitions.sh` each hop).
2. **Comment 1 -- exact testing steps** -- first line says WHERE: `Test on Staging` (hotfix/
   release branch) or `Test on QA` (develop only) -- gate-enforced. Then concrete
   instructions, not just "please test": what to click/call, what the expected vs. broken behavior looked
   like, and the Staging URL for the affected page/endpoint. Include direct URLs
   whenever a log check is part of verifying it, same link conventions as
   [[ama-graylog-search]]:
   - A specific message: `<graylog.host from harness-config.json>/messages/<index>/<message._id>`
   - A search window: `.../streams/<stream-id>/search?rangetype=absolute&from=<ISO>&to=<ISO>`
   Don't invent a Staging URL if it isn't already known from this session's own
   investigation -- confirm it rather than guessing a domain.
3. **Regression -- Claude's check first, comment only for the tester.** Rule
   (`memory/ready-to-test-regression-comment.md`, refined 2026-08-26), same for hotfix,
   release ([[ama-cut-release-branch]] Step 3a) and develop work ([[commit-ticket-jira]]):
   - Judge risk from the DIFF, not the summary: `git log -p` the ticket's commits; other
     callers of a changed signature; consumers of a changed shared lib
     ([[ama-library-version-sync]]); reports sharing a changed query/mapper/field table;
     DI wiring ([[ama-architecture-notes]]); known bug classes ([[ama-debugging-notes]]).
   - **Risk low → no check, but STILL a one-liner on the ticket**: `Regression: risk low --
     <why>` in comment 1. Risk sets the size of the notes, never whether they exist
     (2026-09-11). Ready to Test owes four things, always: description w/ template headings,
     testing-steps comment, regression notes, where to test (QA/Staging). `ready-to-test-readiness-gate.sh`
     DENIES the transition without all four, and fails CLOSED (no token / Jira down → denied too).
   - **Risk high → EXERCISE it now, in session** -- [[ama-ui-verify]] on Staging,
     [[ama-graylog-search]] / [[ama-postgres-access]] / [[ama-mongo-access]] for non-UI. Then:
     - UI tester (`ama.uiTesterName`) can run it from the UI (UI ticket, or API ticket with
       visible UI effect) → SEPARATE comment, brief: ≤5 one-line steps, "open X, confirm Y
       still works". No narrative. `regression-comment-brevity-gate.sh` asks past ~800 chars, denies past 1200.
     - Not UI-testable → no regression comment; one line in comment 1: "Regression:
       checked a, b; nothing found."

**Nothing downstream of the change at all** (a log-only or comment-only edit nothing
consumes) → hop `Review` → `QA` → **Test Complete**, no comments. Judge per ticket: a
release bundles many tickets, not all the same kind of fix.

**If the verifier is Dan (business/client-facing sign-off against Yield Book or client
data)**: the Ready-to-Test handoff happens AFTER the production deploy, not at Staging —
testing envs lack the data his check needs (per-user instruction 2026-08-19, recorded as
an honest gap on PROJ-15278). Ticket sits at Ready to Test until his confirmation,
then → Done. Same comment rule, just later -- at that post-prod handoff, not at Staging. Don't sweep it to Done in [[ama-deploy-release]] Step 7a on deploy success
alone.

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

**Order, every repo, ECS included: merge hotfix → master FIRST, then deploy the
MASTER-channel release to Production -- never the hotfix-channel release.** Prove it:
`bash ~/.claude/skills/ama-octopus-deploy/scripts/oct-release-progression.sh <Releases-N> <production>`
(exit 3 = no Production phase; true of search-api Projects-95 and every Lambda project).

**Do NOT skip Step 4's business-hours precondition. 9am-5pm ET Mon-Fri is the BLOCKED
window, not the permitted one** — deploy OUTSIDE it. Gate-enforced
(`prod-deploy-business-hours-gate.sh`), override `AMA_ALLOW_PROD_DEPLOY=1`, user's call
only. A hotfix's emergency timeline is not an exemption — an urgent fix landing
mid-business-hours is the case the window exists to PREVENT. Before 9am ET is as valid an
opening as after 5pm ET, so the wait is usually to the next morning, not a full day.

**Why: CLIENT impact, not staff availability.** Clients run US business hours; the people
who maintain AMA do not (SAST). So "it is the middle of the night in ET" is an argument
FOR deploying, never against — nobody who maintains this is asleep at 00:47 ET, and no
client is using it either. Stated by the user 2026-09-18 after this file's old wording
("business-hours precondition") was read as 9-5 ET being REQUIRED, and a verified hotfix
was parked ~8h waiting for the window that would have blocked it.

**Skip [[ama-deploy-release]] Step 3a and Step 5a for a hotfix** — the automated API
test suite (QA-before-cut, Staging-before-deploy, and the Production run) is a full-
release requirement, not a hotfix one. A hotfix ships one small, already-verified
change on an emergency timeline; the full suite adds a run cycle the situation doesn't
call for. Per explicit user instruction (2026-08-25).
**Exception (user rule 2026-10-20, PROJ-15825):** hotfix changes report SQL ->
`release-preflight.sh --hotfix` runs the api-testing `staging_shapes` subset itself (~5 min),
so every query shape reaches Staging before the EXPLAIN sweep. Why: the 15801 hotfix shipped
15808 in a shape nothing ran. Nothing to do by hand -- EXCEPT Mon-Fri 9-5 ET: subset runs real
report queries on the shared Redshift, so preflight skips it and reports `SHAPES-NOT-RUN` as a
finding. ASK the user: run now (re-run preflight with `--shapes-in-business-hours`, their yes
covers that run only) or after 5pm ET (set a `reminder.sh` for it).
**Export-content tests: ASK every hotfix** (user rule 2026-10-21, PROJ-15829): "run the
export-content tests too (`staging_export_content`, ~2 min)?" -> `--export-tests` /
`--no-export-tests`. Preflight exits 64 without one -- never pick for the user. Same 9-5 ET rule.

**Error sweep still required** — `prod-deploy-preflight-gate.sh` denies the Production deploy
without one <12h old. Sweep only, no suite:
`bash ~/.claude/skills/ama-deploy-release/scripts/release-preflight.sh <hotfix-version> --hotfix --export-tests|--no-export-tests --hours <since cut>`.
Findings → warn user; deploy only on explicit yes (`AMA_PREFLIGHT_ACK=1`).
Stamp per-run, 12h expiry: next-day deploy re-runs `--hotfix` sweep, or `AMA_PREFLIGHT_ACK=1` after user's yes.

**Lambda projects: deploy via `ama-octopus-deploy/scripts/deploy-lambda.sh`** (dry-checks lifecycle BEFORE delete-function, retries worker death, verifies Active) -- never hand-rolled delete+POST.

**Lifecycle trap**: Hotfix channel has no Production phase -- pre-POST check `oct-release-progression.sh <Releases-N> <production>` (exit 3 = merge to master, deploy the master-channel release); `deploy-lambda.sh` runs it itself. Detail: `ama-octopus-deploy/OCTOPUS-REFERENCE.md`.

### A LIVE `release/*` branch needs the hotfix too — it will otherwise undo it

**Three targets, not two: `master`, `develop`, AND any `release/*` cut but not yet shipped.**
A release branch was cut off develop BEFORE the hotfix existed, so the master and develop
merges do not reach it. Ship that release and it replaces the hotfixed code with code that
still has the bug — same symptom back, no new commit to blame.

Check, in the hotfixed repo, every release branch not yet on master:
```bash
git -C <repo> branch -r --list 'origin/release/*'
git -C <repo> merge-base --is-ancestor origin/release/<v> origin/master   # 0 = already shipped, skip
git -C <repo> merge-base --is-ancestor <hotfix-sha> origin/release/<v>    # 1 = needs the merge
```
Then merge **master into the release branch** (not the hotfix branch — master is what the
release will eventually merge into anyway, and it keeps one ancestry story). Precedent is
already in these repos' history: `b96787a Merge master into release/129.0.0` in `cohortdata`.
Same conflict rules as the develop back-merge below.

Do it in the SAME session as the master merge. Deferring means the regression returns at the
next release, weeks later, with nobody connecting it to the hotfix. Also say out loud that QA
runs develop, so QA stays broken until the develop half lands — otherwise a retest there
reads as the fix not working.

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
- `.csproj` PackageReference conflict → **resolve each candidate version back to the commit
  and branch that built it, then pick by branch, not by number and not by date.** Version
  tail = `BITBUCKET_BUILD_NUMBER`, so the build number IS the lookup key:
  ```bash
  bash ~/.claude/skills/ama-bitbucket-api/scripts/pipeline-build.sh <repo> <build-number>
  # -> branch, sha, state/result for that build
  ```
  Then: merging into `develop` → want the newest SUCCESSFUL **develop** build that carries
  the fix. Onto `release/*` → want that release branch's own build. **Never a build from the
  other line.**

  Neither publish date nor version string survives contact with this repo:
  - **Publish date picks the backport.** Search.Shared `19.1.2.177` (hotfix line, built off
    `release-shared-15411`) published AFTER `19.2.0.173` — date order says take `.177`, which
    would drag develop back onto a `19.1.2` prefix missing every `19.2.0` commit. Live trap,
    2026-09-18.
  - **Version string lies too** — the Bitbucket repo migration reset some build counters, so
    a higher number isn't automatically newer.
  - **A published package does not mean a green pipeline.** `dotnet nuget push` runs mid-way;
    Search.Shared `19.2.0.181` is published from a build marked FAILED (it died later, at
    "Create lambda releases in Octopus"). Check `result` before pinning to it.
  - Suffixed versions (`19.2.0.176-hotfix-129.0.18`) are branch builds and are never the
    answer for `develop` or `release/*` — `package_develop_branch.sh` leaves the suffix off
    only for `develop` and `release*`.
  **A hotfix backmerge to `develop` must leave every consumer on a DEVELOP build of the lib**
  (user rule, 2026-09-18). Resolving `resultsprocessor`'s merge to `19.2.0.173` — a
  `release/130.0.0` build — compiled, but was wrong: develop's build carrying the fix was
  #181 (red, runner fault) → reran as #182 → pinned `.182`. "Carries the fix" means the fix
  commit is an ANCESTOR of that build's sha (`git merge-base --is-ancestor`), not that the
  build is newer than the fix.
- Hotfix code conflicting with develop → **master wins on the FIX'S BEHAVIOUR** (that's what
  production runs) — but NOT on code whose master shape is an artifact of the branch rather
  than of the fix. Two ways that happens, both common:
  - **master is behind on a library major version.** Back-ported call sites compile on
    master's package set and NOT on develop's. Taking master's side breaks develop's build.
  - **master predates unrelated develop work.** Taking master's side deletes it.

  Resolving in master's favour would fail to compile on develop, or revert work unrelated to
  the fix? Then don't encode the decision in the merge at all — split it:
  1. Merge for **ancestry only**: resolve EVERY conflict in develop's favour, then assert
     `git diff origin/develop` is **empty**. That empty diff is the proof the merge changed
     no content — check it, don't assume it.
  2. Apply the fix's intended semantic change as a **separate commit written against
     develop's own dependencies**, so it's reviewable on its own terms instead of arriving
     disguised as a conflict resolution.
  3. Build + test develop before pushing. A deliberate test-count change → say so and why.

  A file existing only on develop is usually **not** a conflict: hotfix branched from master
  before that file was added → no tracked deletion exists, merge keeps it. Don't hunt for
  deletions git never staged.

Then build + test before pushing develop. Never `git merge --abort` and leave it.

`develop-backmerge-reminder.sh` (`PostToolUse`) fires on any master push whose commit
isn't on develop yet — mechanical backstop, per CLAUDE.md's "Mechanical Triggers Over
Self-Recognition".

**Mark the hotfix version Released once Production is verified.** Same
`PUT /rest/api/3/version/<id>` used for the description — `{"released": true,
"releaseDate": "<the production deploy date>"}`, recipe in [[ama-jira-api]]. This was
long documented as a click-only step, so hotfix versions simply accumulated unreleased;
confirmed automatable 2026-08-18 on `hotfix/129.0.2`. Verify with a fresh GET, not the
PUT's response.

**Slack/email: say "a hotfix", never the number.** Gate-enforced
(`hooks/hotfix-number-comms-gate.sh`); rule in `memory/hotfix-number-not-in-comms.md`.

**Stop before Step 8 — a hotfix does not get release notes.** Per explicit user
instruction: a hotfix is an emergency out-of-cycle patch, not a scheduled release, so
the release-notes/PDF/email pipeline doesn't apply here.

**The hotfix ticket must end at Done once deployed to production — Done, not Closed.**
Closed only comes later, when the NEXT release deploys to prod ([[ama-deploy-release]]
Step 7a's same-pass sweep). This is already
covered by the reused flow, not a separate step: the master merge moves it to Test
Complete (per [[commit-ticket-jira]]'s push-to-master rule), then Step 7a sweeps every
Test-Complete ticket to Done. Confirm it actually landed there once Step 7a runs —
don't assume the chain worked silently. **Run Step 7a unprompted, immediately after
verifying the deploy (ECS image tag, not health alone)** — per [[commit-ticket-jira]]'s
"Deployed to production" line this no longer needs the user to ask first, and the
`octopus-prod-deploy-ticket-sweep-reminder.sh` hook fires on the production deployment
API call itself as a mechanical backstop if it's still overlooked.
