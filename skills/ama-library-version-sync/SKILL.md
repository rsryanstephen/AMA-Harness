---
name: ama-library-version-sync
description: A library code change isn't done until its version is bumped and every consumer repo is synced to it — on WHATEVER branch the change lives on (master, develop, or a release branch), not just master. Use whenever a push/commit touches a published library repo in the AMA app fleet (by user or self), or when asked to sync/propagate a library version bump — including a fix or feature landing directly on a release branch, not only the default master/develop path.
---

# AMA library version sync

Repos root: resolve via `bash ~/.claude/hooks/lib-harness-repos.sh roots app` — don't hardcode a path, folder layout varies per adopter.

**Exception:** `product-service-search`'s `Search.Shared`/`Search.Cache` packages publish from `develop`, not `master`, and are handled by the separate [[ama-search-shared-version-sync]] skill. Skip this skill for that repo.

## Steps

1. **Confirm library push**: read pushed repo's `bitbucket-pipelines.yml` (or equiv CI file). Nuget pack+push step (e.g. `dotnet pack` + `dotnet nuget push`) gated on `master`? None found → doesn't publish on master, stop, tell user, do nothing.

2. **Find published package(s)**:
   ```bash
   bash ~/.claude/skills/ama-library-version-sync/scripts/list-published-packages.sh <repo-path>
   ```
   Gives `<package-name>  <csproj-path>  <version-prefix>` per line, skips test/exe projects.

3. **Get Bitbucket build number** for the push (same rules as [[ama-search-shared-version-sync]]):
   - Check `$BITBUCKET_API_KEY`. Unset → **stop, alert user prominently**, give exact cmd, wait for confirm:
     ```bash
     export BITBUCKET_API_KEY=your_api_key_here
     ```
   - Once set: query via Basic auth `<your-atlassian-email>:$BITBUCKET_API_KEY` (NOT `x-token-auth` — that's git https clone only) against pipelines API, master branch, matching commit.
   - User can't/won't set key → fall back, flag as inferred: `~/.ssh/bitbucket-ssh-key` (commit inspection only, no build number) or git log/tags (best-effort guess).

4. **Compute new version** per package: `<VersionPrefix>.<build-number>`.
   - **Check `~/.claude/fleet-health/latest-build-counter.txt` first** (nightly scan). Library's package shows `RISK` there → its live build counter is BELOW a build some consumer already references (an accidental counter reset once caused a real downgrade). Don't use `live-build+1` blind in that case — bump past the highest referenced build instead, and tell the user why. File missing/stale (check its timestamp) → don't block on it, just note you couldn't cross-check.

5. **Find consumers** per published package name (repos root resolved above):
   ```bash
   bash ~/.claude/skills/ama-library-version-sync/scripts/find-consumers.sh <package-name> <resolved-repos-root>
   ```
   Gives `<repo-name>  <csproj-path>  <current-version>` per consumer. Automatically skips repos listed in `scripts/excluded-repos.txt` (e.g. deprecated duplicate publishers) — check that file if a repo you expect is missing.

5.5. **Present every consumer for the user to choose from — no size/relevance judgment call.**
   - `resultsprocessor` is always compulsory for a Search.Shared change — bump it automatically, no ask. (Single source of truth for this exception — [[ama-search-shared-version-sync]] step 4.5 cross-references it, doesn't restate it.)
   - For every other consumer of every other library push: present the full consumer list from step 5 as a plain numbered/bulleted list in your message text — **do not** use the question-picker tool for this; it caps at 4 options and silently truncates a longer consumer list. Ask the user to reply with which ones (by name or number), or "all", as free text. Process only what's chosen, same full step-6 rigor either way. Report anything left out as "left on the old version, per your choice" — never silently drop it from the report.

6. **Per consumer repo** (this step recurses — see Cascading below):
   - **Target branch = the same branch the library change lives on** — `develop`/`master`
     normally, but a release branch if that's where the fix was applied (easy to sync
     `develop` and forget the release branch, leaving its consumers pinned to the old
     version there). If the library change is on
     more than one branch (e.g. both `develop` and a release branch), sync consumers on
     each branch it's on, not just the default one.
   - Branch checked out, tree clean? Dirty w/ unrelated changes → skip, warn user, don't clobber.
   - Edit `Version` attr of matching `PackageReference`.
   - **Build + test, must be green before proceeding:**
     - Tell user building/testing now.
     - `dotnet build` (solution/repo root) then `dotnet test`.
     - Both pass → commit (own commit, don't bundle unrelated changes) and push to that branch. No confirmation needed — green build/test is the gate.
     - **After pushing, check the real Bitbucket pipeline for that commit** (same API method as the build-number lookup) — local build+test passing does NOT mean CI passes (e.g. a YAML syntax error in `bitbucket-pipelines.yml` fails CI but is invisible to a local `dotnet build`). Poll until the pipeline completes; if it fails, report it explicitly — don't treat the hop as done, and don't fix the CI config yourself unless asked (that's a separate, deliberate task, not something to do silently mid-cascade). A failed pipeline also means nothing actually got published, so **this repo does not cascade further** either, same as a build/test failure.
     - Either fails → tell user what failed (errors/failing tests), try fix it (e.g. adjust calling code to changed API signature). Keep user posted per attempt.
       - **Ask user's preference at any decision point** — multiple plausible fixes, adapt code vs pin older version, keep trying vs abandon repo. Don't unilaterally choose.
       - Re-run build+test per fix attempt. Cap ~3 retries, then stop and ask user how to proceed.
       - Still red after reasonable effort → stop, report exact errors, do NOT commit/push, ask how to proceed. **This repo does not cascade further** (nothing downstream of it gets a real new version to pick up).

7. **Report**: see Cascading below — this is now a cascade-tree report, not a flat one-level list.

## Cascading (library-depends-on-library chains)

A just-pushed consumer might itself be a library others depend on (e.g. `product-service-shared` updates → `product-service-search` is a consumer, but `Search.Shared`/`Search.Cache` are themselves published packages too). Don't stop at one hop — keep going till the chain runs dry:

- Maintain a **worklist** of (repo, package(s), new version(s)), seeded with the triggering repo. Maintain a **visited set** so no repo processes twice even via two paths (cycle/diamond safety).
- After a consumer repo pushes (step 6), check if **it** publishes a NuGet package:
  ```bash
  bash ~/.claude/skills/ama-library-version-sync/scripts/list-published-packages.sh <consumer-repo-path>
  ```
  - Publishes nothing → leaf node, done, don't enqueue.
  - Publishes package(s) — incl. `product-service-search`, which hands off to [[ama-search-shared-version-sync]]'s develop-branch rules instead of this skill's master rule — get **its** build number (step 3's method), compute **its** version(s). Enqueue unless already visited.
- Breadth-first: finish all direct consumers of one library before the next library's consumers. Every hop gets full step-6 treatment (build/test gate) — no depth skips this.
- **No "say go"/"shall I proceed" stop mid-cascade, ever — including at the hand-off into [[ama-search-shared-version-sync]].** The user's fix request already covers every downstream repo the fix touches. Green build/test is the only gate (per step 6), not a check-in. Only real stop conditions still apply: missing `$BITBUCKET_API_KEY`, dirty tree, red build/test past retry cap, a genuine judgment call on HOW to fix broken code.
- **Hygiene-only bump — stop the cascade yourself, don't ask.** Before enqueuing a consumer, check: does it already carry the real fix another way (a direct reference to the fixed package at a version NuGet's highest-wins rule already prefers over what this bump would deliver transitively)? If yes, this hop is pure version hygiene, no functional change reaches anyone. Don't ask "should I propagate anyway" — just stop the cascade there and say why (which consumers, why hygiene-only, what direct reference already covers it). Recognizing "hygiene-only" already IS the judgment call — don't re-ask after making it.
- **Safety cap**: stop at a generous finite depth/count (e.g. 20 repos or 5 levels) if unterminated — report explicitly ("cascade safety limit hit, N repos remain: [...]"), never silently truncate.
- **Final report is a cascade tree**, not flat: each level shows which library triggered it and which repos updated/skipped/failed there.

## Do NOT

- Act on `product-service-search` (see exception above) — hand off to [[ama-search-shared-version-sync]] if the cascade reaches it.
- Guess build number silently — always state method used, at every cascade level.
- Touch a consumer repo with a dirty working tree.
- Commit/push a consumer repo whose build/tests still fail.
- Silently pick a fix approach on a real judgment call — ask the user.
- Treat a hop as done just because local build+test passed — confirm the pushed commit's real Bitbucket pipeline also passes; report failures instead of burying them, and don't fix a broken CI pipeline yourself unless asked.
- Cascade past a failed/dirty-skipped/CI-failed repo as if it succeeded — a repo that didn't actually publish has no new version for anything downstream to pick up, so nothing enqueues from it.
- Silently stop cascading without reporting — either the chain naturally ran dry (say so) or the safety cap was hit (say so and list what's left).
