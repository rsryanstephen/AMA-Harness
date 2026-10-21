# AWS notice relevance model — what to keep, what to drop, and why

Required reading for `ama-aws-notices`. CLI conventions live in
[[ama-cloudwatch-search]]'s `AWS-REFERENCE.md` — not restated here.

## Why this skill exists

ElastiCache Redis OSS v4/v5 hit EOL. Notice arrived; nobody acted for months. Cost,
measured from Cost Explorer (`USAGE_TYPE` grouping), not estimated:

| Month | `USE1-ExtendedSupportYr1_Yr2-NodeUsage:cache.m4.xlarge` | `:cache.t3.small` |
|---|---|---|
| 2026-05 | $537.24 | $87.38 |
| 2026-06 | $519.91 | $84.56 |
| 2026-07 | $537.24 | $87.38 |
| 2026-08 (to 20th) | $231.79 | $35.35 |

**~$625/mo, ~$7.5k/yr.** August pro-rates to ~Aug 13-14 — the fleet redis 6.2 upgrade date
in `AWS-REFERENCE.md`. Remediation is visible in the billing data.

Notice existed first, fee arrived later. That gap is the whole job.

## Sentinel entities — strip before scoping

Entity count > 0 is NOT proof of relevance. **Four** shapes, all measured on this account
(the documented `AWS_ACCOUNT`/`UNKNOWN` pair is only half of them):

| Shape | Seen on |
|---|---|
| `AWS_ACCOUNT` | billing lifecycle event |
| `UNKNOWN` | me-central-1 operational issue |
| the bare account number, e.g. `000000000000` | BILLING, CLOUDWATCH, ECR, ECS, S3, TRUSTEDADVISOR lifecycle events |
| a bare region name, e.g. `eu-west-2` | `AWS_SDK_PLANNED_LIFECYCLE_EVENT` lists 14 |

The last two were found only by running the sweep. Left unstripped they produced ~8
phantom `unclassified` rows per run, each demanding a pointless human decision — the exact
noise that gets a monitor muted.

## Entity name → class

Prod membership separates T1 from T5. Grow this table one confirmed classification at a
time, with provenance. `unclassified` gets ASKED about, never auto-discarded.

| Class | Patterns | Confirmed examples |
|---|---|---|
| `prod` | `*production*`, `hs-prod-*`, `prod-*`, `*-prod`, `*-prod-*` | `production-v1-hs-admin-esvc`, `hs-prod-exporter-v3`, `lpc-adept-delta-prod`, `hs-production-zip-files` |
| `nonprod` | `staging-*`, `*staging*`, `qa-*`, `hs-qa-*`, `*-qa`, `development-*`, `dev-*`, `*-test`, `*-test-*` | `staging-v2-ama-elasticcache`, `hs-qa-exporter-v1`, `qa-v1-reports-api-esvc` |
| `thirdparty` | `Datadog-*`, `*-Datadog-*` | `Datadog-AWS-Integration-Dat-DatadogAPICallFunction-*` — real, and not ours to upgrade |
| `unclassified` | anything unmatched | opaque ids only, by design: Cognito pool ids (`us-east-1_EZPzT4PvW`), Lightsail UUIDs, `vpn-66352807` |

Two pattern lessons, both from running it rather than reading the naming convention:

- **`*production*`, not `production-*`.** `hs-production-zip-files` is an S3 bucket on the
  production path that the prefix-anchored form missed entirely — a production resource
  silently classified `unclassified`.
- **`tr -d '\r'` before classifying is load-bearing.** This jq build emits CRLF on `-r`
  output, so values arrive as `lpc-adept-delta-prod\r`. That fails every *anchored* pattern
  (`*-prod`) while unanchored ones (`*production*`) still match — so the bug appears on some
  resources and not others. It classified two eu-west-1 **production** lambdas as
  `unclassified` until fixed.

## Unclassified is a question, not a verdict

The five that survive classification today are all opaque identifiers — Cognito user-pool
ids, Lightsail UUIDs, a VPN id. Resolving one means a lookup (`cognito-idp
describe-user-pool`, `lightsail get-instances`), and the answer belongs in the table above
with its provenance. Never guess from the id.

## Confirmed exclusions

**Deliberately empty.** Every exclusion prior tried during design was WRONG — see the two
worked negatives below. An exclusion goes here only with provenance: what was checked, what
command proved it, when.

## Alternate-contact baseline

Read-only every run, report on CHANGE only. Never write (SKILL.md rule).

| Type | Address | Name |
|---|---|---|
| OPERATIONS | `AMA@client.example.com` | AMA, Account Owner |
| SECURITY | `cloudsecurity@client.example.com` | Darrell Grundy, Head of Cloud Security |
| BILLING | `cloudfinops@client.example.com` | Nathan Hawes, Director FinOps |

> **These addresses say NOTHING about who operates the infrastructure.** ClientCorp owns AMA but
> runs none of it — YourCompany built it and does all the hosting. A governance/notification
> field, org membership, and `clientcorp-*` resource names are evidence of routing and naming, never
> of operational ownership. Reading this table the other way produced a wrong claim to Reviewer Two
> and Reviewer One on 2026-08-20 that `*.<tenant domain>` was "probably ClientCorp IT's to renew" — it is
> YourCompany's own domain and ours to renew. See
> [[clientcorp-owns-ama-yourorg-operates]].

All three ClientCorp-owned. This is WHY email-only detection fails: `[Action Required]` mail lands
with ClientCorp, reaches YourCompany only via Reviewer Two's manual "FYA" forward. It is also why
overwriting one is worse than the gap — it removes ClientCorp's own visibility, on a setting no
Terraform covers.

## Observed extended-support usage-type strings

Cost-leg match targets. Regex `Support|Extended|ExtSupp|EOL` (case-insensitive), client-side.

```
USE1-ExtendedSupportYr1_Yr2-NodeUsage:cache.m4.xlarge
USE1-ExtendedSupportYr1_Yr2-NodeUsage:cache.t3.small
```

`cache.m4.xlarge` is previous-generation — its own deprecation candidate.

## eventTypeCode → prior-tier HINTS

> **The type code identifies, it NEVER scores.** No path where the code alone assigns or
> discards a tier. Tier comes only after reading `latestDescription` AND classifying the
> affected entities. Two live cases below prove a code-only rule gets both directions wrong.

| Code | Hint | Confirm by |
|---|---|---|
| `*_PLANNED_LIFECYCLE_EVENT` | T2/T4 — deprecation, EOL, EOS | prose date + entity class |
| `*_SECURITY_NOTIFICATION` | T3 | entity class — staging-only is not T1 |
| `AWS_ELASTICACHE_UPDATE_AVAILABLE` | T2/T3 | `elasticache describe-update-actions` — per-cluster, machine-readable. A `not-applied` row whose `ServiceUpdateStatus` is `expired` is UNAPPLIABLE, not overdue work — see [[ama-cloudwatch-search]]'s `AWS-REFERENCE.md` §ElastiCache |
| `AWS_ECS_TASK_PATCHING_RETIREMENT` | **routine, usually T5** | prose says "no action required"; check `minimumHealthyPercent` |
| `*_OPERATIONAL_ISSUE` | T1 if our region+service, else T5 | entity class |
| `AWS_*_REDUNDANCY_LOSS` | T1 | entity class |

## Recall-booster terms — boost, never filter

`end of support` · `extended support` · `deprecat` · `retirement` · `EOL` · `end of life` ·
`apply by` · `mandatory` · `will be upgraded` · `no longer supported` · `action required` ·
`security` · `CVE` · `certificate` · `breaking change`

Zero hits does NOT close an event. Read every paragraph regardless.

## Worked examples

### POSITIVE — T1/D0 candidate that turned out T5 (headline calibration case)

`AWS_ECS_TASK_PATCHING_RETIREMENT` ×3, us-east-1, start 2026-08-25. Entities span **15
production services** (`production-v1-AMA`), plus qa/staging/dev — 47 entities total.

Every type-code signal says P1: production, "retirement", days away. **It is not.** Prose,
verbatim:

> "There is no action required on your part unless you want to replace these tasks before
> task maintenance start time."

Routine Fargate platform-revision maintenance. A replacement task launches on the new
revision BEFORE the affected task retires — **provided `minimumHealthyPercent` is 100**
(confirmed: `production-v1-search-api-isvc` = 100/200, desired 3).

**Verdict T5.** The named condition that would flip it to T1: any affected service with
`minimumHealthyPercent` < 100. Check it, don't assume it.

**0/100 services — `production-v1-exportproducer-api-esvc`, `-resultsprocessor-api-esvc`** (desired
1). Deliberate: single queue consumers, two copies would double-process. Don't raise to 100/200.
Fix = user-approved `aws ecs update-service --force-new-deployment` (min/max untouched) outside US
hours, before the retirement date → brief processing gap at a time we choose. `wait-ecs-rollout.sh`
took >10 min (2026-10-21, PROJ-15832) → run it `run_in_background`. Graylog names:
[[ama-graylog-search]] APP-NAME-MAPPING.md (resultsprocessor has the `-api` suffix).

This is why the rule is identify-never-score. Flag this weekly as P1 and the monitor gets
muted — which is exactly how the Redis notice got missed.

### POSITIVE — T2/T3, D0, and the deadline trap

`AWS_ELASTICACHE_UPDATE_AVAILABLE`, `startTime` 2026-07-31. Prose:

> `Service Update Name: elasticache-july-patch-update-202607, Severity: important, Update
> Type: engine-update, AWS Recommended Apply By Date: 2026-08-30 05:59:59 UTC, Auto-Update
> after Due Date: no`

Entities include **`hs-prod-exporter-v3`**. Apply-by is 30 days AFTER the announcement, and
`Auto-Update: no` means it will NOT self-heal.

**The prior "a year-old open event is low urgency" is wrong.** `startTime` is the
announcement date. Six such events sit open going back to 2025-08 — age says nothing about
the deadline. Take the D-band from the apply-by date only.

### POSITIVE — cross-corroborated, and why NO region filter

`AWS_LAMBDA_PLANNED_LIFECYCLE_EVENT`, **eu-west-1**, 2026-11-10. Entities:
`lpc-adept-delta-test`, `lpc-adept-delta-prod`. Real functions.

2026-11-10 is the `dotnet8`/`dotnet9` Lambda runtime retirement date independently recorded
in `ama-architecture-notes`' `SHARED-INFRA-AND-PIPELINES.md`.

**The prior "eu-west-1 is noise, we only run us-east-1" is wrong.** A
`--filter regions=us-east-1` drops this silently. Never filter by region.

(Ownership of the `lpc-` functions is unconfirmed — likely the LPC project, not AMA. That is
an `unclassified` row to ASK about, not to assume either way.)

### POSITIVE — T4, deadline already passed, and why NO pre-seeded exclusions

`AWS_LIGHTSAIL_PLANNED_LIFECYCLE_EVENT`. `aws lightsail get-instances`:

```
poc_featureflag_yourproduct   amazon_linux_2   created 2022-05-11
```

AL2 blueprint end of support **2026-06-30 — already past**. A 2022 POC instance, still
running, still billing, now unsupported.

**The prior "we don't use Lightsail" is wrong.** This is why the confirmed-exclusions list
above ships EMPTY. Check the service, don't assume the inventory.

### INSTRUCTIVE NEGATIVE — scary name, nonprod entities

`AWS_ELASTICACHE_SECURITY_NOTIFICATION`, open since 2026-08-11. TLS certificate names now
land in public Certificate Transparency logs; cluster names cannot be removed or renamed.

Entities: `staging-v2-ama-elasticcache`, `staging-v3-ama-elasticcache-001` — **staging
only**. Not T1 despite `SECURITY_NOTIFICATION` in the code. T3 at most, and the actual
question is whether either name carries sensitive information (they don't — environment plus
product).

### NEGATIVE — sentinel-only

`AWS_BILLING_PLANNED_LIFECYCLE_EVENT`, 2026-08-19. Sole entity: `AWS_ACCOUNT`. Sounds T2,
carries no resource. Stage-3 judgement, digest line.

## Honest limits

- Health shows events AWS raised against **this account**. It cannot see what ClientCorp's
  governance addresses receive — hence the email leg.
- `describe-events` retention is bounded; a long-idle monitor cannot backfill. The ledger is
  the memory, and `finish` is what proves a window was covered.
- The cost leg detects *we started paying*. *We will start paying* only comes from
  `*_PLANNED_LIFECYCLE_EVENT` prose. Different jobs.

## Structural ceilings — measured 2026-08-20, do not code around

**Member account in ClientCorp's org.** `organizations describe-organization`:

```
org o-bgh9yaai9l   payer 725799391269   AWS-BSL-MASTER-ADMIN@client.example.com   FeatureSet ALL
us  000000000000   (IAM user ryan_stephen)
```

`health describe-events-for-organization` → **AccessDenied** ("did not come from the
management account"). Anything AWS routes to the payer is invisible from here. So is any
Savings Plan or RI: `savingsplans describe-savings-plans`, `ec2 describe-reserved-instances`
and `rds describe-reserved-db-instances` all return empty. A commitment expiring at the
payer cannot be seen — only its **effect**, via `ce get-savings-plans-coverage`, which does
work at member level.

Do not alarm on a month-over-month coverage drop: measured across Feb–Aug 2026 it swings
82–92% normally. The Jun→Jul dip (91.8% → 81.6%, +$322 uncovered) read as an expiry until
the full series showed it was variance. Needs a sustained-decline test or a hard floor.

**Region blindness.** The harness convention bars `--region`, so every regional API is read
in `us-east-1` only. "GuardDuty not enabled" is a us-east-1 fact, not an account fact — and
eu-west-1 demonstrably holds real Lambdas. Any leg touching a regional service must iterate
a configured region list, or state that it only covers one region.

## The email leg — measured coverage, 2026-08-20

**Scope is anything AWS-related VISIBLE in the mailbox**, whoever it was addressed to: mail
to the shared `<noticeSenders>`, forwards from colleagues, and cc-only threads all
count. (An earlier pass measured "does mail arrive from an AWS sender domain", answered no,
and mistook that for the finding. The routing is a fact; the coverage is the question.)

**42 genuinely-AWS threads over 24 months. The query caught 36 — 86%.** Real volume is
concentrated in the last 15 months; the first AWS notice in the window is 2025-05-28.

All six misses failed on the **sender** clause. The keyword clause has never failed, because
Gmail matches quoted and forwarded body text: all 22 registrar threads pass on
"Dear AWS customer" in the body even though subjects like "Automatic renewal of … succeeded"
carry no keyword. **So when coverage is missing, add a sender, not a keyword.**

| Miss | Sender | Why |
|---|---|---|
| `Fwd: [CASE 175982774800789] Redshift Elastic Resize Rollback` | `<colleague-a>@` | AWS **Support case**, original from `<noticeForwarders>` |
| `AWS Access Keys` | `chintan.bhatt@` | not a configured forwarder |
| `AMA Redshift migration from DC2 to RA3` | `<colleague-b>@` | cc-only, not a forwarder |
| `AMA Redshift your-redshift-cluster database size` | `<colleague-a>@` | sender **and** sitting in TRASH |
| `Verify your AWS Builder ID email address` | `<noticeForwarders>` | AWS-family domain not in the list |
| `You have successfully enrolled in AWS Technical Essentials` | `no-reply@aws.training` | training mail; deliberately still excluded |

Mail to `yourproduct@` is **covered**, but only incidentally — all 22 registrar threads match
because that one sender is configured. A sweep of `to:yourproduct@` for AWS terms from other
senders found no AWS notices, only Graylog alerts. So the shared mailbox is not a gap today;
it would become one the moment anything else AWS-shaped arrived there.

Two clauses were removed as **provably dead**: `from:amazon.com` and `from:aws.amazon.com`
matched nothing, ever, all-time, `in:anywhere` included. `<noticeForwarders>` is
configured and also matches nothing here — AWS mails it to the account contacts (all ClientCorp),
so it only reaches this mailbox inside a forward. It stays as a forward-looking entry, and
is **not** evidence that direct AWS mail is covered.

**Do not trust Gmail's `resultCountEstimate`.** It reported 201 threads for a sender whose
true volume is ~22, which made the query look hopelessly noisy. Measured over a real 7-week
window the query returned 7 threads, all relevant, zero false positives. Widening the sender
list does cost precision — roughly 3 false positives became ~9 in the first 50 — which is
acceptable because step 9 reads subjects only and deep-reads a thread only when a term trips.

**What no sender/keyword approach can catch:** a bare "FYA" forward with the notice as a PDF
attachment, or a notice paraphrased in a colleague's own words; a new forwarder nobody has
configured yet; and mail deleted before the weekly sweep runs (`in:anywhere` reaches trash,
but not a permanent delete). The email leg is corroboration. Health is the primary source.

## ACM: Health is structurally silent on imported certificates

`describe-event-types --filter services=ACM` offers only `AWS_ACM_RENEWAL_FAILURE` /
`AWS_ACM_RENEWAL_STATE_CHANGE` — both about certificates **ACM issued**. There is no
approaching-expiry event for an `IMPORTED` cert, and this account has **zero** ACM Health
events. An imported certificate expires in complete silence, and AWS's expiry email goes to
the ClientCorp alternate contacts.

Measured 2026-08-20: every `IMPORTED` cert in the account was expired or expiring and all
were `RenewalEligibility: INELIGIBLE` — including `*.example-app.com` (52 days out,
27 load balancers, 6 production) and two `*.<tenant domain>` certs that were the **sole**
listener certificate on `production-v1-aggregation-api` and on the classic ELB
`hs-prod-elasticsearch-external`. Raised as PROJ-15335.

`acm list-certificates` + `describe-certificate` is the only surface that sees this.

---

# Non-Health surfaces (PROJ-15336, 2026-09-21)

`aws-notices-surfaces.sh` reads the five surfaces `describe-events` can't see. Emits rows in
`aws-notices-plan.sh`'s own shape -> they join `events.tsv` before the ledger diff.

## Why synthetic rows, not a second pipeline

These are STANDING CONDITIONS, not events. Health event opens + closes; a TA recommendation
or deprecated runtime stays true until someone fixes it. Plan's diff keys on
`(arn, lastUpdatedTime)` for suppression + `sha1(description)` for restamp-vs-candidate --
right shape for a standing condition IF the stamp is content-derived, never a clock. Wrong
stamp rebuilds the documented failure: six year-old `ELASTICACHE_UPDATE_AVAILABLE` events
re-flagging weekly until the monitor got muted -> Redis OSS EOL missed.

| Leg | Synthetic arn | Stamp moves only when |
|---|---|---|
| Trusted Advisor | `synthetic:ta:<id>` | `lifecycleStage/status` -- resolved, dismissed, severity change |
| Pending maintenance | `synthetic:pending:rds:<res>#<action>` | `CurrentApplyDate` \| `AutoAppliedAfterDate` \| `unscheduled` |
| ACM | `synthetic:acm:<certArn>` | `NotAfter` |
| Access Analyzer | `synthetic:accessanalyzer:<id>` | `status` alone |
| Lambda runtime | `synthetic:runtime:lambda:<arn>` | runtime string |
| DB version census | `synthetic:version:rds:<region>:<id>` | `<engine> <version>` |

Access Analyzer stamps on `status` ALONE on purpose. `updatedAt`/`analyzedAt` churn on
re-analysis without the finding changing -> either re-flags all 62 every sweep.

## ACM rule is the REVERSE of the obvious one

**Alarm when `NotAfter` has NOT moved.** Moved = something renewed it = no alert needed;
alarming there re-fires ~4x/year/cert. Static-and-in-window is the dangerous state. Only leg
that reads the ledger -- "has it moved" compares against the previous run, not the current
response.

Verified 2026-09-21: `*.example-app.com` rotated by the certbot ECS task,
`*.<tenant domain>` by the `hs-production-certificate-sync` Lambda -> both move, both silent.
`fcb684e8` (static 11 months) + `3c9dea62` (static 6 weeks), both serving live production,
are what this catches. First sighting can't judge renewal -> emits once, says so.

## Traps -- measured, not reasoned

- **TA: filter `lifecycleStage`, never `status` alone.** Two checks report `status=error` +
  `lifecycleStage=resolved` dated 2024 (RDS CA Certificate Expiration + DocumentDB twin); all
  live CA certs expire 2027. Status-only alarms forever.
- **TA: use the `trustedadvisor` service, not `support`.**
  `describe-trusted-advisor-check-summaries` rejects its own ids, `UNKNOWN_CHECK_ID_ERROR`.
- **Pending maintenance: key is `PendingMaintenanceActions`**, not
  `PendingMaintenanceActionsDetails`. Wrong key returns null, doesn't error.
- **Never also poll `docdb describe-pending-maintenance-actions`.** DocDB is RDS-backed, the
  `rds` call already returns them. Both = 166 rows, all 83 pairs duplicated under two arns,
  double-alerting the production DocDB `os-upgrade`.
- **Synthetic arns must never reach `describe-event-details`.** No Health event behind one; a
  failure marks the whole chunk of 10 unfetched -> nine real events lost to one synthetic row.
  Pass 1 routes them out.

## Regions -- iterated, not single

`.awsNotices.regions`, default `us-east-1,eu-west-1`. The no-`--region` convention covers
`describe-events` (global); these are regional APIs, no global view. us-east-1 only would
under-report the 22 deprecated runtimes -- eu-west-1 holds real Lambdas.

## First run is a BACKFILL -- `record.sh seed`

Turning these on = ~270 standing conditions all true for months, not a week's news. Left
alone: one unreadable Slack message, then permanent suppression. Nobody reads it, nobody sees
them again.

`aws-notices-record.sh seed <watchUntil> <slug-prefix> < plan.json` PARKS them: `T5`,
disposition `watch`, required wake-up date. Parks rather than marking stale because the
invariant is seen = TRIAGED -- a blind `stale` fabricates judgement on 270 unread rows. Never
overwrites an existing row -> re-running after a partial triage can't undo it.

**`watchUntil` must be beyond `watchLeadDays`**; refuses otherwise. Nearer date puts every
seeded row back into `watchDue` next sweep -- measured before the guard: `candidates 0,
suppressed 308, watchDue 308`. Reads clean, hands back the whole backfill under another key.

## Accepted limits, these legs

- Censuses report WHAT VERSION RUNS, not whether it's out of support. Judging that needs the
  current AWS end-of-standard-support date, absent from every API response here. Census makes
  the question visible before the bill starts.
- TA count (60 error/warning, 2026-09-21) != the audit's ~51 from 2026-08-20. Sets drift; not
  a fixture.
- Leg failure is NOT fatal -- Health is the older load-bearing leg, mustn't die with a new
  surface. `surfaceError`/`syntheticCount` say whether legs ran; `surfaceNote` tells the
  caller not to report an all-clear for a window it never read.
