---
name: ama-debugging-notes
description: Known, reoccurring BUG-CLASS patterns for the AMA_APP fleet. Use when debugging/investigating an error, crash, or unexpected behavior in product-service-shared, search, fieldtablemapper, manage, or exporterplus, or a DI/connection-type crash, log redaction, ag-grid, Angular reactive-forms validity, or Bitbucket CI net9.0 test-leg failure — check BEFORE re-diagnosing from scratch.
---

# AMA debugging notes

Known bug-CLASS patterns only (already-diagnosed root causes likely to reoccur) — NOT
architecture/structure facts, those live in [[ama-architecture-notes]]. Index — read only
the file(s) relevant to the current task, not all of them.

- **[DI-EAGER-CONSTRUCTION.md](DI-EAGER-CONSTRUCTION.md)** — `shared`/`search`/`fieldtablemapper`: why an unrelated, unconfigured connection type can crash a consumer app. Read this before touching connection-type registration or DI wiring in any consumer of `YourCompany.Product.Shared`.
- **[REDACTION-AND-LOGGING.md](REDACTION-AND-LOGGING.md)** — `shared`/`manage`: input sanitization exemption model, a known OOM-causing logging class, branch/version-verification gotchas.
- **[EXPORTERPLUS-FRONTEND.md](EXPORTERPLUS-FRONTEND.md)** — `exporterplus`: ag-grid v26 API surface gotchas, an Angular reactive-forms validity-caching trap.
- **[CI-PIPELINES.md](CI-PIPELINES.md)** — any lib repo: net9.0 test leg aborting in Bitbucket CI ("You must install or update .NET") — mutated ECR pipeline image tag, one-line fix.

(Repo-naming/classification conventions live in [[ama-architecture-notes]]'s
`FLEET-CONVENTIONS.md`; git/SSH network fixes live in [[commit-ticket]] — neither is an
AMA_APP code bug, so neither belongs in this file.)

## Adding to this — see [[commit-ticket]]'s "Leave context for future agents" section

Architecture/repo-structure facts: add liberally. Bug-specific findings: only for a
genuinely generic, likely-to-reoccur class — always confirm with the user first, and
say why it's generic, not a one-off. A still-open bug found along the way is a Jira
ticket, not a note here.
