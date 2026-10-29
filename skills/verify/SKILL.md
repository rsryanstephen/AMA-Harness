---
name: verify
description: Verify that a code change actually does what it's supposed to by exercising it end-to-end and observing behavior — drive the affected flow, not just tests or typecheck. Run before committing nontrivial changes; bootstraps this repo's project verify skill if none exists yet. Don't invoke it on a diff that only touches tests, docs, or other code with no runtime surface to drive (a change to product source always has one) — there's nothing to observe.
disable-model-invocation: false
---

Shadows bundled `/verify` (model-invocation-disabled by default; this copy isn't).
Reconstructed from its known description, not byte-for-byte — bundled version's exact
prompt isn't extractable (compiled into binary, no readable source). Refine if real
usage diverges from what `/verify` itself does.

## What to do

1. Identify the actual runtime surface the change affects — flow a user/caller would exercise, not code in isolation.
2. Drive that flow for real: run the app/service/script, call the endpoint, execute the CLI command — whatever exercises the changed behavior.
3. Observe real output/behavior, compare against what the change should do. Tests/typecheck passing necessary but not sufficient — doesn't prove it works in the flow a user would hit.
4. Repo has its own verify process (script, documented QA flow, own `verify` skill)? Use that instead. None exists → bootstrap minimal one per project type (web app: start it, hit changed page/endpoint; CLI: run changed command; library: run/write small script exercising changed function). Don't skip just because nothing formal exists.
5. Report what was actually observed (real output, screenshot, response body) — not just "tests pass."

## Skip when

- Diff only touches tests/docs/other non-runtime-surface files — nothing to observe. Say so, skip, don't invent a flow to drive.
