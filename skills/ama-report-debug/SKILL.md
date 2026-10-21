---
name: ama-report-debug
description: Debug a "this report doesn't load" ticket for exporterplus/admin. Use when a ticket describes a report failing to load, hanging, or erroring. Sequence: offer the user a chance to self-serve (load it, hand over a Graylog link) first, else Claude loads it and checks Graylog; for a custom band (dynamic column), check Postgres.
---

# Debugging a report that doesn't load

## 1. Offer self-serve first

Ask the user: load the report yourself and paste the Graylog link (or report URL +
rough time), or should Claude do it. Don't default to doing it unprompted.

## 2. Declined / "you do it" -> load the report via ama-ui-verify

Use its `--chrome`-vs-headless table and its "Bootstrapping test data" flow if the test
user has no matching report. Capture the actual failure: screenshot, console, network.
This is that skill's debug-first use, not just verification.

## 3. Check Graylog around the load window

Reuse ama-graylog-search's link-parsing step for a user-supplied link. Real signal
comes from `product-service-export-api`, `-reports-api`, `-querybuilder-api` --
never exporterplus itself (S3 static, emits nothing). Cross-check
KNOWN-SIGNATURES.md's two dynamic-column entries.

## 4. Custom band (dynamic column) involved -> check Postgres

Confirmed anomaly: querybuilder serves/manages dynamic columns and is where related
errors surface, but the data itself lives in the **export API's** Postgres DB, not
querybuilder's own (see ama-architecture-notes' CORE-LIBRARIES.md). Use
ama-postgres-access's AWS-ECS-\>psql pattern, targeted at the `export` service (not
`exportproducer`, a different row already there) -- resolve for real the first time
this comes up, then add the confirmed row per that skill's own instruction.

## Adding/changing a report field, not a load failure

Report definitions themselves (fields, filters, dimensions) live in the `reports`
repo's template JSONs, not here -- see ama-architecture-notes' REPORT-TEMPLATES.md.
