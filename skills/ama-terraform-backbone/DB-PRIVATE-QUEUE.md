# Backbone DB roots still `publicly_accessible = true` in code

All AMA Postgres made private by hand 2026-10-20/21 (Wiz alert, PROJ-15767 session).
Root below not yet merged → its deploy makes DB public again → never approve one; reject any plan `false -> true`.
Owner: session "Backbone Terraform ... PROJ-15658" (7c2235b9). Rules: one root per PR (Reviewer One), exact
`hashicorp/aws` pin per root, mnd-* via provider default_tags, `publicly_accessible = false` EVERY env incl.
Production, sg-a3dae4d1 0.0.0.0/0:5432 stays out.

| Root | Ticket | State |
|---|---|---|
| Applications/AMA/Admin | 15532 | done (PR #26) |
| Applications/AMA/Cohorts | 15535 | PR #27 open (2026-10-21) |
| Applications/AMA/ExportProducer | 15538 | queued |
| Applications/AMA/Notifications | 15540 | queued |
| Applications/AMA/Reports | 15542 | queued |
| Applications/AMA/Export | 15537 | queued |
| Applications/AMA/ResultsProcessor (RP) | 15543 | queued |
| Applications/Mapping-Tool | 15548 | queued (HS_ENVIRONMENT; qa-v3-mapping-tool in NO backbone state per sweep → QA plan may CREATE a DB; state list/import first) |
| Base/Database/RDS (*-etl-db) | 15529 | queued (master: main.tf:32; check tfvars) |
| Load/Orchestrator (*-orchestrator-db) | 15530 | queued (Octopus project: NO approval team) |
| pricing/market-index-rates | 15550 | owned by session 60a1b019 (match live, no risky change) — others stay off |

Update row as each lands; delete file + SKILL.md pointer when done.
