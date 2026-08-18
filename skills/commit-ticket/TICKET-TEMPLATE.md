# Ticket description template

Wiki markup (`h2.`, `*bold*`, `#`/`*` lists) — confirmed live that this Jira instance
round-trips it as markup, not ADF, via `/rest/api/2/issue`. `jira-create-issue.sh` posts
there for exactly this reason; **create through it, not MCP `createJiraIssue`** — MCP
posts v3, where `h2.` renders as literal text.

The three sections below are a **floor, not a ceiling** — context, affected
repo/environment, links are welcome above them. But keep AC and requirements to one-line
bullets, no prose paragraphs — that's the part that stays brief.

`hooks/jira-ticket-description-gate.sh` enforces the headings are present (any
case/prefix) — it does not check content quality or exact wording.

## Bug

```
h2. How to reproduce
# <step>
# <step>

h2. Acceptance criteria
* <observable outcome>

h2. How to test
* <env + exact action a human repeats to confirm>
```

## Feature / support / task / story

Same shape, `h2. Requirements` in place of `h2. How to reproduce`:

```
h2. Requirements
* <requirement>
* <requirement>

h2. Acceptance criteria
* <observable outcome>

h2. How to test
* <env + exact action a human repeats to confirm>
```

## Filled-in example (Bug)

```
h2. How to reproduce
# Open the {{custom-loan-pool-view}} report in exporterplus.
# Filter "Last Loan Age" with operator "Between", leave both From/To blank.
# Click Apply.

h2. Acceptance criteria
* Blank Between filter is rejected client-side with a validation message, not sent to the server.

h2. How to test
* On QA, repeat the repro steps above — confirm no request fires and the field shows a validation error.
```
