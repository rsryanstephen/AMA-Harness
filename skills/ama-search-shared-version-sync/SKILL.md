---
name: ama-search-shared-version-sync
description: Sync YourCompany.Product.Search.Shared/Search.Cache NuGet versions in every referencing repo after push to develop on product-service-search. Use when push to develop on search happens (by user or self).
---

# Search.Shared → consumers version sync

Repos root: resolve via `bash ~/.claude/hooks/lib-harness-repos.sh roots app`.

Push to `product-service-search`'s `develop` -> Bitbucket pipeline (`package_develop_branch.sh`) -> new `YourCompany.Product.Search.Shared` + `YourCompany.Product.Search.Cache` nupkgs to AWS CodeArtifact (`<repository>`).

Version = `<VersionPrefix>.<BITBUCKET_BUILD_NUMBER>` per package. VersionPrefix from each package's own csproj.

**master push = no publish** (script skips nuget push if `BITBUCKET_BRANCH == master`, temporary/intentional). Ignore master.

This is `product-service-search`'s own develop-branch special case (unlike other libraries, which publish from master) — see [[ama-library-version-sync]] for the general master-branch version, which explicitly defers to this skill for this repo.

## Steps

0. **Determine what actually changed — do nothing if neither package's code changed.**
   - Commit range for this push: `<old-sha>..<new-sha>` (develop tip before push, new tip after). Pushed it yourself → you know both. Reacting to someone else's push → `git fetch`, use `origin/develop@{1}` (prior reflog value) as old-sha, `origin/develop` as new-sha — ask user for prior commit if reflog unavailable (e.g. fresh clone).
   - Run:
     ```bash
     git diff --name-only <old-sha>..<new-sha> -- YourCompany.Product.Search.Shared/ YourCompany.Product.Search.Cache/
     ```
     (exclude `bin/`/`obj/` noise if present — shouldn't be tracked anyway).
   - **No files** changed under either directory → **stop, tell user nothing relevant changed, don't query build numbers or touch any consumer repo.**
   - Only `YourCompany.Product.Search.Shared/` changed → scope run to Shared only, skip Cache and its consumers entirely.
   - Only `YourCompany.Product.Search.Cache/` changed → scope run to Cache only, skip Shared and its consumers entirely.
   - Both changed → proceed with both.
   - Directory-scoped diff is authoritative, final — no exceptions, no question to user. (Cache has a project reference to Shared, so a Shared-only change is technically part of Cache's compiled output too — but pipeline republishes Cache every push regardless, own version bump when it actually changes, so no special-casing needed. Don't raise as a question.)

1. **Find published packages in scope** (per step 0):
   ```bash
   bash ~/.claude/skills/ama-library-version-sync/scripts/list-published-packages.sh <path-to-product-service-search>
   ```
   Gives `<package-name>  <csproj-path>  <version-prefix>` per line — filter to package(s) in scope from step 0.

2. Check `$BITBUCKET_API_KEY`. Unset → **stop, alert user prominently**, give exact cmd, wait for confirm:
   ```bash
   export BITBUCKET_API_KEY=your_api_key_here
   ```
   Confirmed set: Basic auth `<your-atlassian-email>:$BITBUCKET_API_KEY` (NOT `x-token-auth` — that's git https clone only, pipelines API needs email:token) to query pipelines for `yourorg/product-service-search`, develop branch, commit in question, for build number. Matching build still in progress → poll until done.
   Can't/won't set it → fall back (state which used):
   - `~/.ssh/bitbucket-ssh-key`: git ops only, no pipelines API — inspect pushed commit only, not build number.
   - git log/tags in search repo: infer, flag unconfirmed.

3. **Compute new version** per package: `<VersionPrefix>.<build-number>`.

4. **Find every consumer**, per published package name (repos root from intro):
   ```bash
   bash ~/.claude/skills/ama-library-version-sync/scripts/find-consumers.sh <package-name> <resolved-repos-root>
   ```
   (Known as of last check: `product-service-resultsprocessor`, `product-service-cohortdata`, `product-service-export-cohort`, `product-service-manage`, `product-service-fieldtablemapper` — re-run scan each time, don't trust this list, new consumers may appear.)

4.5. **Present every consumer for the user to choose from — no size judgment call.**
   - `resultsprocessor` is always compulsory for a Search.Shared change — see [[ama-library-version-sync]]'s step 5.5 standing exception, same rule, no ask.
   - **Everything else** (Cache consumers, or Shared consumers other than resultsprocessor): present the rest as a plain numbered/bulleted list in your message text — **do not** use the question-picker tool for this; it caps at 4 options and silently truncates a longer consumer list. Ask the user to reply with which ones (by name or number), or "all", as free text. Process only what's chosen, same full step-5 rigor either way. Report anything left out as "left on the old version, per your choice" — never drop it from the report silently.

5. **Per consumer repo found** (same rigor as [[ama-library-version-sync]] step 6 — this step recurses, see Cascading below):
   - Target branch: `develop` if exists (local/remote), else `master`.
   - Branch checked out, tree clean? Dirty w/ unrelated changes → skip, warn user.
   - Edit `Version` attr(s) of matching `PackageReference`(s) — a repo may reference both Search.Shared and Search.Cache.
   - **Build + test, must be green before proceeding.** Tell user building/testing. Fails → try fix (adapt calling code etc.), ask user's preference at real decision points, cap ~3 fix attempts then stop and ask. Never commit/push while red. **Failed/dirty-skipped repo does not cascade further.**
   - Green → commit (own commit) + push to that branch. No confirmation needed — green build/test is the gate.
   - **After pushing, check the real Bitbucket pipeline for that commit** — local build+test passing does NOT mean CI passes (a `bitbucket-pipelines.yml` syntax error is invisible to a local `dotnet build`). Poll until the pipeline completes; if it fails, report it explicitly — don't treat the hop as done, and don't fix the CI config yourself unless asked. A failed pipeline means nothing actually published, so **this repo does not cascade further** either.

## Cascading (this repo's consumers may themselves be libraries)

`product-service-search` is the *only* repo with the develop-publish special case (`package_develop_branch.sh` quirk). Search.Shared/Cache's own consumers don't get that treatment — if one (e.g. `product-service-resultsprocessor`, `product-service-manage`) is itself a library others depend on, it follows the **standard master-branch publish convention**, not this skill's rules.

So: after a consumer repo pushes (step 5), check if it publishes a package (`list-published-packages.sh` on it). If yes, **hand off to [[ama-library-version-sync]]'s cascading algorithm** for that repo and everything downstream — worklist/visited-set, build-number lookup via its master branch, per-hop build/test gate, safety cap, cascade-tree reporting. Don't duplicate that logic here; this skill only owns the initial develop-branch hop for `product-service-search` itself.

6. **Report**: package(s) + new version(s), build-number method used, per-consumer-repo outcome (updated & pushed / fixed-then-pushed / build-test-failed-skipped / skipped-dirty) — and if the cascade continued into [[ama-library-version-sync]] territory, fold its cascade-tree report in underneath so the user sees the whole chain in one place.

## Do NOT

- Do anything (build-number lookup, consumer scan, edits) if step 0 finds no changes under either package's directory.
- Sync Search.Cache consumers when only Search.Shared changed, or vice versa. Don't ask user — directory-scoped diff decides automatically.
- Guess build number silently — always state method used.
- Touch master for this repo's own publish (search.shared/cache only publish from develop) — but downstream cascaded repos DO use master, that's correct and expected.
- Commit/push a consumer repo whose build/tests still fail.
- Treat a hop as done just because local build+test passed — confirm the pushed commit's real Bitbucket pipeline also passes; report failures instead of burying them, and don't fix a broken CI pipeline yourself unless asked.
- Cascade past a failed/dirty-skipped/CI-failed repo as if it succeeded.
- Stop mid-cascade for a "say go"/"shall I proceed" check, including at the hand-off into [[ama-library-version-sync]] — see that skill's Cascading section, same rule applies here.
- Ask before skipping a hygiene-only bump (consumer already has the fix via a direct reference NuGet's highest-wins already prefers) — same rule as [[ama-library-version-sync]]'s Cascading section, recognizing it IS the judgment call, don't re-ask after making it.
