---
name: ama-library-pr-propagate
description: Two-phase workflow for updating an AMA library via PR and propagating the new version to referencing repos via their own PRs. Use when the user asks Claude to make/open a PR to update or bump an AMA library (Search.Shared, Search.Cache, or any other library repo in the AMA app fleet), or asks to "update the references" for a library after such a PR.
disable-model-invocation: true
---

# Library update → PR propagation

**PAUSED for now** — solo dev right now, direct push to develop/master (via [[ama-library-version-sync]] / [[ama-search-shared-version-sync]]) is the standing default. `disable-model-invocation: true` above stops Claude auto-picking this skill. Content kept as-is for when a team workflow needs it later — flip that flag back to re-enable, don't rewrite from scratch.

Two-phase workflow, split across separate user turns:

- **Phase A** — user asks for a PR to update library X. Claude opens that PR, finds consumers, reports them, then **stops and waits** ("let me know when I can update the references").
- **Phase B** — user later says to go ahead / update the references for library X. Claude propagates the new version to every consumer via its own PR, fixing build/test failures where it can, reporting what it couldn't fix.

Repos root: resolve via `bash ~/.claude/hooks/lib-harness-repos.sh roots app`.

Target branch for the **library's own PR**:
- `product-service-search`'s `Search.Shared`/`Search.Cache` → PR into `develop` (see [[ama-search-shared-version-sync]] for why: that repo's pipeline only publishes from develop).
- Every other library → PR into `master` (see [[ama-library-version-sync]] for why: standard libraries publish from master).

## Phase A — open the library PR, then stop

1. Make the requested change in the library repo (e.g. bump `VersionPrefix`) on a new branch off the target branch above (don't commit directly to develop/master).
2. Commit, push the branch.
3. Open the PR:
   ```bash
   bash ~/.claude/skills/ama-library-version-sync/scripts/create-bitbucket-pr.sh <repo-slug> <source-branch> <develop-or-master> "<title>" "<description>"
   ```
4. **Find published package(s)**:
   ```bash
   bash ~/.claude/skills/ama-library-version-sync/scripts/list-published-packages.sh <library-repo-path>
   ```
5. **Find every consumer** of each published package name:
   ```bash
   bash ~/.claude/skills/ama-library-version-sync/scripts/find-consumers.sh <package-name> <resolved-repos-root>
   ```
6. **Report to user**: PR link + full list of repos referencing this library (per package if multiple). End with: **"Let me know when I can update the references."**
7. **Stop here.** Don't touch any consumer repo yet — only Phase B, on explicit request.

## Phase B — update the references (triggered by "update the references for X" / "go ahead")

1. **Confirm library version is actually published** — Phase-A PR must be merged (or, for search's develop case, pushed) so a real build number exists. Unmerged → tell user, stop, don't guess a version.

2. **Get the build number** (same rules as [[ama-library-version-sync]] / [[ama-search-shared-version-sync]]):
   - Check `$BITBUCKET_API_KEY`. Unset → **stop, alert user prominently**, give exact cmd, wait for confirm:
     ```bash
     export BITBUCKET_API_KEY=your_api_key_here
     ```
   - Basic auth `<email>:$BITBUCKET_API_KEY` (not `x-token-auth`) against pipelines API for library repo, correct branch, matching merge/push commit. Poll if still in progress.
   - Can't/won't set key → fall back to `~/.ssh/bitbucket-ssh-key` (commit inspection only) or git log/tags (inferred) — flag clearly which used.

3. **Compute new version**: `<VersionPrefix>.<build-number>` per package.

4. **Re-scan consumers** (don't reuse Phase A's list — re-run `find-consumers.sh`, things may have changed).

4.5. **Assess the size of this change — small changes don't need to hit every consumer immediately.**
   - Diff the library's merge/push commit range (`git diff --stat <old-sha>..<new-sha>` in the library repo, scoped to the published package's own source directory).
   - Judge it, don't just count lines: a one-line log tweak, a comment, a tiny scoped bugfix with no caller-visible behavior change → **small**. A new feature, a signature/behavior change, anything touching the public API surface → **not small**. Genuinely unsure → treat as not-small (full propagation).
   - **If small**: present every consumer repo from step 4 as a plain numbered/bulleted list in your message text — **do not** use the question-picker tool for this; it caps at 4 options and silently truncates a longer consumer list. Ask the user to reply with which ones (by name or number), or "all", as free text. Process only what's chosen, same full step-5 rigor either way. Report anything left out as "left on the old version, per your choice" — never drop it from the report silently.
   - **If not small**: proceed with the full propagation across every consumer, as below.

5. **Per consumer repo**:
   - Target branch: `develop` if exists (local/remote), else `master`.
   - Tree clean? Dirty w/ unrelated changes → skip, warn user.
   - New branch off target branch (don't commit directly to develop/master — this phase also goes through a PR).
   - Edit `Version` attribute(s) of matching `PackageReference`(s).
   - **Build + test, must be green before opening a PR:**
     - Tell user building/testing.
     - Both pass → proceed.
     - Either fails → try fix (e.g. adapt calling code to changed API), ask user's preference at real decision points (multiple plausible fixes, adapt vs pin back, keep trying vs give up), cap ~3 fix attempts.
     - **Still red after reasonable effort → do NOT open a PR for this repo.** Report as failed — state user is responsible for making this repo work with the updated library, with exact build/test errors as a starting point.
   - Green → commit branch, push, open PR via `create-bitbucket-pr.sh` into target branch, note PR link.
   - **After pushing the branch, check its real Bitbucket pipeline** — local build+test passing does NOT mean CI passes (e.g. a YAML syntax error in `bitbucket-pipelines.yml` fails CI but is invisible to a local `dotnet build`). Poll until it completes; if it fails, say so in the PR report — don't silently rely on the reviewer to notice, and don't fix the CI config yourself unless asked.
   - **Check if this consumer is itself a library** (`list-published-packages.sh` on it). If yes, this repo is a new "Phase A" waiting to happen once **its** PR merges — see Cascading below. If no (an app/service, publishes nothing): leaf node, done.

## Cascading (chained, not autonomous — merges need a human)

Unlike the direct-push skills ([[ama-library-version-sync]], [[ama-search-shared-version-sync]]), this workflow can't recurse on its own within one turn: each hop's PR needs an actual merge (and, per this org's branch rules, approval from someone other than the author) before a real build number exists for the next hop. So cascading here means **chaining Phase A → Phase B pairs across however many user turns it takes**, not a single autonomous pass:

- For every consumer repo from step 5 that turned out to itself be a library: treat opening its PR as that repo's own **Phase A** — find *its* consumers (`find-consumers.sh` on its package name(s)) and report them too, in the same final report, clearly nested under which repo/PR they depend on.
- End the report with the same stop-and-wait pattern per pending PR: **"Let me know when [repo]'s PR is merged too."** Track (in the conversation, and by re-deriving from scratch if a new session picks this up later — don't rely on hidden state) which PRs are still open vs. merged.
- When the user later says a given PR is merged, run that repo's own Phase B: get its build number, compute its new version, re-scan **its** consumers, and repeat the whole cycle — which may itself surface further libraries needing yet another hop.
- No fixed depth limit is needed here the way the autonomous skills need one (each hop requires a human to explicitly say "go ahead" via a merge), but if a chain gets long, periodically summarize the whole tree so the user isn't tracking it from memory alone.
- A repo that failed build/test (no PR opened) or whose PR the user later declines to update refs for: **does not cascade** — nothing consumes a version that was never actually published.

6. **Final report** — for the current hop:
   - Repos updated: PR link + branch + new version, per repo.
   - Repos NOT updated: what failed (build/test errors), user must handle that repo themselves.
   - Repos that are themselves libraries with their own consumers: listed per Cascading above, each ending in its own "let me know when this one's merged."

## Do NOT

- Skip Phase A's stop-and-wait — never touch consumer repos before user explicitly says to update references, at any hop.
- Commit directly to develop/master in either phase — always via branch + PR.
- Open a PR for a consumer repo whose build/tests still fail after reasonable fix attempts — report as a failure instead.
- Guess build number silently — always state method used, at every hop.
- Silently pick a fix approach on a real judgment call — ask the user.
- Assume a downstream repo's version without confirming its PR actually merged — each hop's merge is a hard gate, not something to skip past.
- Silently drop a cascade thread — if a repo is itself a library, always say so and name its own consumers, even many hops deep.
