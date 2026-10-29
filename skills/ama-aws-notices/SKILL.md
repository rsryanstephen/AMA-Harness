---
name: ama-aws-notices
model: sonnet
description: Weekly sweep of AWS Health Dashboard events, AWS support cases, extended-support billing and forwarded AWS notice email — triaged for downtime risk, late-cost risk, security risk and end-of-support. Acts on TLS/ACM certificate expiry rather than only triaging it. Use when hooks/aws-notices-check.sh's nudge fires, when the user says "check the AWS notifications"/"AWS notices"/"anything from AWS support", or when deciding whether AWS already announced a deprecation that just bit us. Sibling of ama-embs-notices (that one is the <one entry per line; this element only declares the type> data vendor; this one is AWS the platform).
---

# AWS notice triage

AWS announces deprecations, EOLs and security changes ahead of time. Missing one already
cost ~$7.5k/yr in extended-support fees — see `AMA-AWS-SURFACE.md`'s "Why this skill
exists".

Notices reach YourCompany only via Reviewer Two's manual forward: all three account alternate
contacts are ClientCorp addresses. So the Health API, not the mailbox, is the primary source.

CLI conventions (`MSYS_NO_PATHCONV=1`, bare `aws`, never `--profile`/`--region`):
[[ama-cloudwatch-search]]'s `AWS-REFERENCE.md`. Its standing rule applies here too — any
AWS setting change needs a matching Terraform update, and no Terraform covers ElastiCache.

## Four rules — each maps to a real failure

1. **`eventTypeCode` identifies, never scores.** No path where the code alone assigns or
   discards a tier. Tier comes after reading `latestDescription` AND classifying entities.
   A production-wide "retirement" turned out to be a no-op; a staging-only
   "SECURITY_NOTIFICATION" is not T1. Both live cases in the map.
2. **Deadline comes from the apply-by/EOS date, NEVER from `startTime` or event age.**
   An event announced 2026-07-31 carried an apply-by of 2026-08-30. Six events sit open
   since 2025 — age says nothing.
3. **Entity count > 0 is not relevance.** Strip the sentinel set
   (`AWS_ACCOUNT`, `UNKNOWN`) first. Then classify by name; prod membership is what
   separates T1 from T5.
4. **Never filter by region or service in the CLI call.** Only
   `--filter eventStatusCodes=open,upcoming`. A region filter silently dropped a real
   eu-west-1 Lambda retirement during design. Scope by judgement, not by flag.

## Steps

1. `bash ~/.claude/skills/ama-aws-notices/scripts/aws-notices-plan.sh` → JSON:
   `candidates[]` (each with `arn`, `typeCode`, `region`, `entities`, `entityClass`,
   `descHash`, `fetchError`, `priorTier`, `priorDisposition`, `scopeHint`), plus
   `watchDue[]`, `restamp[]`, `pendingArns[]`, `eventCount`, `priorRun`, `reportTarget`,
   `slackMinTier`, `since`. Config missing → fails loud. Don't improvise a report target.
   - **Check `priorRun` first.** `unclosed` means the previous run never called `finish`, so
     **nothing was suppressed** — already-triaged events reappear. Record those with
     `retriage`, not `add`, and don't re-Slack a verdict that hasn't changed.
   - **Check `surfaceError` too.** Non-null → the five non-Health legs (Trusted Advisor,
     pending maintenance, ACM, Access Analyzer, version censuses) did NOT run. Health-only
     window, NOT a clean bill for them — say so, never report an all-clear.
     `healthEventCount` + `syntheticCount` split the total.
   - Rows with a `synthetic:` arn are STANDING CONDITIONS, not dated events — true until
     someone fixes them. Triage on blast radius, not age. Mechanics + per-leg stamp rules:
     `AMA-AWS-SURFACE.md`.
2. **`restamp[]` first, mechanically.** These are events whose `lastUpdatedTime` moved but
   whose description hash did not — churn, not news.
   `scripts/aws-notices-record.sh restamp <arn> <lastUpdatedTime>` each. No re-triage, no
   Slack. This is what stops year-old open events re-flagging weekly.
3. **`watchDue[]` next.** A `watch` row whose lead window has opened. Re-triage it as if
   new — the deadline is now near. It arrives as a bare arn, so re-fetch its detail.
   **`pendingArns[]` too**: each is a row whose verdict was blocked on an answer. Answer
   arrived → `scripts/aws-notices-record.sh settle <arn> <tier> <ticket|stale|->`. Not yet →
   one line in the report, row stays pending. Left unread, `pending` is a silent drop.
4. **Per candidate**: the plan script already fetched the prose and entities.
   **`fetchError` non-null means the description was never read** — re-fetch that event and
   do NOT triage or record it from this run. The script deliberately leaves such an event
   unhashed rather than hashing the empty string, which used to make an unread event look
   like a benign empty one.
5. Partition the description into paragraphs. Verdict each. Closing/footnote paragraphs
   read LAST with their own verdict line — the material clause is often there.
6. **Assign both axes** (below) and record:
   `scripts/aws-notices-record.sh add <arn> <lastUpdated> <descHash> <tier> <deadline|-> <Dband> <field|api|prose> <entityClass> <ticket|stale|pending|watch|-> <watchUntil|-> <slug>`
   - **Event already has a row** (`priorTier` non-null, or `add` says "already recorded") →
     use **`retriage`**, same arguments. `add` is idempotent on arn and will no-op, leaving
     the stored hash stale so the event re-flags and re-Slacks every week — the exact muting
     failure the restamp mechanism exists to prevent.
   - T1/T2 REFUSE `-` in the disposition column. Carry a ticket key ([[commit-ticket]]),
     `stale` (window closed, nothing actionable), `pending` (blocked on an answer — then
     seed an [[ama-followups]] row for whoever owes it), or `watch` + a date.
   - **Deadline and band travel together.** A band other than `D?` needs a real date and a
     provenance (`field`/`api`/`prose`); `D?` requires `deadline` and source both `-`. The
     script refuses the mismatch, because a row reading `D0` with no date is an assertion
     about a deadline nobody recorded — and 7 live rows were in exactly that state.
   - Prefer a service-native date over prose where one exists:
     `aws elasticache describe-update-actions --service-update-name <name>` gives
     `SLADate`/`AutoUpdateStartDate`/`UpdateActionStatus` **per cluster**, which retires
     stale `UPDATE_AVAILABLE` rows mechanically. Mark provenance `api`.
7. **Cost leg**: `bash scripts/aws-notices-cost-check.sh`. Reports extended-support-shaped
   usage types and any usage-type key new this month. A new key at ANY magnitude is a
   finding — see rule below on why there's no threshold.
8. **Support cases + contacts**: one `aws support describe-cases --include-resolved-cases`
   for anything since `since`; `aws account get-alternate-contact` ×3 compared to the map's
   baseline. Report contacts ONLY on change.
   - Also `aws notificationscontacts list-email-contacts`. Every entry must be `active`;
     anything else means AWS stopped delivering to it after a bounce or complaint, and only
     a support case resumes it. **Report a non-active contact even though it is not a
     change** — a dead subscription makes the label leg (9b) go quiet, and a quiet leg reads
     as good news. State, not a Health event, is the check: `client-product-team@client.example.com` was suppressed
     2026-09-09 and had already been removed from the contact list by the time the event
     surfaced, so the event alone could not say whether anything was still broken.
9. **Email leg** (subject/snippet only; deep-read a thread only when a recall term trips):
   `in:anywhere after:<since> (from:<each noticeForwarders entry>) (AWS OR "end of support" OR "extended support" OR deprecat OR "Action Required" OR retirement OR Redshift OR ElastiCache OR certificate OR ACM)`
   - **`in:anywhere` is required**, not optional. Gmail excludes trash and spam by default,
     and a real AWS thread was found sitting in TRASH — read and discarded before a weekly
     sweep could see it.
   - **It still does not reach spam.** 2026-09-08, two AWS SNS mails sat in spam while four
     searches including `in:anywhere` came back empty. So an empty mail leg is NOT evidence
     nothing arrived — ask the user to check spam before reporting non-delivery, and never
     write non-delivery into a ticket off an empty search. See [[ama-gmail-thread-reads]].
   - Record every triaged item: `scripts/aws-notices-record.sh mail-add <msg-id> <received> <tier> <ticket|stale|pending|-> <slug>`.
     Dedupe on **Gmail message id**. Without this the deliberate overlap window re-reads and
     re-Slacks the same forwarded notice every run.
   - A forwarder matching zero in ONE window is not evidence it's dead — don't prune config
     off one result.
   - Measured 2026-08-20 (24-month window, 42 genuinely-AWS threads visible): the sender
     clause is the only thing that has ever failed. The keyword clause never has, because
     Gmail matches quoted/forwarded body text — all 22 registrar threads pass on "Dear AWS
     customer" in the body despite subjects carrying no keyword. So when coverage is
     missing, **add a sender, not a keyword**.
   - Two clauses were removed as provably dead: `from:amazon.com` and `from:aws.amazon.com`
     matched nothing, ever. `<noticeForwarders>` is configured but currently also
     matches nothing here — AWS mails it to the account contacts (all ClientCorp), and it reaches
     this mailbox only inside a forward. It stays as a forward-looking entry, not as
     evidence direct AWS mail is covered.
9b. **Label leg** — one search per `noticeLabels` entry, on top of step 9:
    `in:anywhere after:<since> label:"<entry>"`
    - **No keyword clause on this leg.** The label IS the filter the user already curated;
      keyword-gating it re-opens the miss it exists to close.
    - **Quote the display name.** `label:<Label_id>` returns zero through the Gmail MCP
      despite its docs saying ids — see [[ama-gmail-thread-reads]].
    - **Dedupe msgids across 9 and 9b before triaging**, not only against the ledger.
      Registrar mail matches both searches and would otherwise be triaged twice in one run.
    - **Digest threads cross-check Health, they are never a triage source.** AWS User
      Notifications aggregates — subject "There were N health notifications within 5
      minutes" or "Multiple events" — arrive every ~2h in ONE thread and carry no event ARN,
      so there is nothing to key a ledger row on. Read the NEWEST message only. Every event
      type it names must show up in the Health leg's candidates or restamp, or already have
      a ledger row — `suppressedUnchanged` is a COUNT, the plan never emits those arns, so
      grep `.aws-notices-seen` for the third case. A type in none of them is the finding,
      unless it has closed, which `eventStatusCodes=open,upcoming` drops on purpose. Never
      `mail-add` a digest.
10. **Every dated finding must end up as a ledger row, or it gets no reminder.** The weekly
    deadline nudge (below) is derived from the ledger, so anything not in it is invisible to
    it — including a finding from a leg that has no Health event at all.
    - **A finding with no event ARN uses a synthetic key**: `manual:<slug>`. The ACM
      certificate expiry is the worked example — ACM emits no Health event, so
      `manual:acm-example-app-wildcard` carries PROJ-15335's 2026-10-12 deadline.
      Without that row the single most time-critical finding of the whole audit had no
      reminder at all.
    - Same rule for cost-leg and support-case findings that carry a date.
10b. **First run after the non-Health legs were added = BACKFILL, not a week's news.**
    ~270 conditions all true for months. Don't Slack them and don't let the ledger swallow
    them: `scripts/aws-notices-record.sh seed <watchUntil> <slug-prefix> < plan.json` parks
    every unseen candidate `T5`/`watch`. `watchUntil` MUST be beyond `watchLeadDays` or it
    refuses — a nearer date re-surfaces all of them next sweep. Once seeded, triage by class
    on the wake-up date. One-off; skip it on every later run.
11. Close the run: `scripts/aws-notices-record.sh finish <every candidate arn>` — or
    `finish --none`. `lastrun` updates only when every candidate has a row, so an
    interrupted run re-fires.
12. Deliver per "Output".

## Two axes — deliberately not one score

Multiplying harm by urgency reintroduces exactly what rule 1 forbids: it lets a top-tier
item be suppressed by a distant date. Record and print both, always.

**Harm tier:**

- **T1 — client-facing downtime if we don't act.** Needs ≥1 `prod` entity, or prose stating
  a forced action on a prod path.
- **T2 — extra cost if we're late.** Extended-support surcharge, post-EOL premium,
  deprecated engine/runtime that starts billing higher. The Redis OSS EOL is the reference
  miss.
- **T3 — a version AWS deems a security risk**, on a resource we run. Vendor-declared, not
  our inference.
- **T4 — past end of support, needs upgrading.** No downtime/cost/security mechanism
  established yet.
- **T5 — in scope, no action.** One digest line. Never escalated, never Slacked.

**Deadline band**, from the apply-by/EOS date only:

- **D0** passed or ≤14 days · **D1** ≤90 days · **D2** >90 days · **D?** no date findable
  anywhere — treated as D1, because an unknown deadline is not a distant one.

## Output — per flagged item, all six

Verbatim trigger sentence · what AWS is changing · named affected resources + their class ·
mechanism of harm · deadline + its provenance · action + owner.

Quote the trigger sentence verbatim, never a re-summary. Vague "may be relevant" is ignored
by week three.

- **Slack threshold: T1/T2 at any D-band; T3/T4 only at D0/D1; T5 never.** Send via
  `mcp__claude_ai_Slack__slack_send_message`, `channel_id` = `reportTarget`. A `U…` id DMs,
  a `C…` id posts to a channel — retargeting is that ONE config value
  (`.awsNotices.reportTarget`). **Never Slack a nothing-found week.**
- T1/T2 → ticket per [[commit-ticket]], the durable due-dated store. `add` refuses an
  undispositioned T1/T2. **Seen ≠ actioned.**
- **Never write to AWS** — one scoped exception, ACM certificate renewal, see below. No
  `put-alternate-contact` (it would overwrite an ClientCorp-owned governance setting and remove
  ClientCorp's own visibility), no `elasticache batch-apply-update-action`, no service updates, no
  case replies. Everything else read-only; remediation is a ticket and a human decision,
  never a side effect of triage.
- A cost finding names the usage-type string and the monthly figure — the number is the
  argument.

## Certificate-expiry notices — act, don't just triage (user instruction 2026-09-08)

Applies to any ACM/TLS-expiry finding, whether it came from the mail leg or from the ACM
census (`aws acm list-certificates`, PROJ-15336). ACM emits no Health event — mail and
census are the only sources. Historic note: no ACM mail had ever reached this mailbox as of
2026-09-08 (verified by full-history search); Reviewer Two is setting up auto-forwarding, so treat a
first-ever cert mail as expected, not as a false positive.

**Route by who controls the certificate's public DNS zone**, not by who owns the domain.

```bash
aws route53 list-hosted-zones --query 'HostedZones[?Config.PrivateZone==`false`].Name'
```

Apex in that list → **ours**. Absent → **IT's** (live case: `<tenant domain>`, whose public
zone sits in an AWS account we have no access to).

### IT's zone → create the IT ticket automatically

Invoke [[it-ticket]] and write the file. No asking first. Include cert id, expiry, every
attached listener/ELB and whether any is prod, and the one thing IT must add (the ACM
validation CNAME). Existing draft is the template:
`IT Tickets/IT-Ticket-yourorg-net-cert-renewal.md`.

### Our zone → check the existing renewer FIRST, then renew if uncovered

**`*.example-app.com` already renews itself.** EventBridge rule
`renew-ama-certificate` (cron Mon-Fri 04:00) runs ECS task
`production-v1-certificate-renew` on `production-v1-AMA` — certbot, renewal config
`/etc/letsencrypt/archive/example-app.com-0001`, imports the new cert to ACM. So an
`*.example-app.com` cert 30-45 days from expiry is **not** a finding.

```bash
export MSYS_NO_PATHCONV=1
aws logs describe-log-streams --log-group-name /ecs/production-v1-certificate-renew \
  --order-by LastEventTime --descending --max-items 1
```

Healthy tail reads `Cert not yet due for renewal` (certbot renews inside 30 days) or an
import. Ran today and healthy → report that, renew nothing. Stale streams, or a certbot
error → THAT is the finding; fix the renewer, don't hand-issue around it.

Only a domain the renewer does not cover reaches the steps below. It covers
`example-app.com` only — `<tenant domain>` is not in its config, which is why both
of those certs expired.

### Uncovered domain in our zone → renew it

The scoped write exception. Nothing else in this skill writes to AWS.

1. `aws acm request-certificate --domain-name '*.<apex>' --subject-alternative-names '<apex>'
   --validation-method DNS` — ACM-issued, so it auto-renews from here on. Never re-import a
   Let's Encrypt cert; that recreates the manual treadmill this exists to end.
2. `aws acm describe-certificate` → `DomainValidationOptions[].ResourceRecord`;
   `aws route53 change-resource-record-sets` UPSERT that CNAME. Leave it in place forever —
   deleting it breaks auto-renewal silently.
3. Poll `describe-certificate` until `Status=ISSUED`.
4. Attach, additively: `aws elbv2 add-listener-certificates` on every listener carrying the
   old cert, then `modify-listener --certificates CertificateArn=<new>` to make it default.
   Classic ELBs: `aws elb set-load-balancer-listener-ssl-certificate`.
5. Verify each public host with `openssl s_client … | openssl x509 -noout -issuer -dates`
   before reporting done.
6. **Never detach or delete the old certificate**, even expired. Rollback = re-point the
   listener default at it.

Hard stops — do these instead of proceeding: verification fails on any host (report, leave
the old default in place), the apex is in a private zone only, or the cert fronts something
outside `aws elbv2`/`aws elb` (CloudFront, API Gateway, a Terraform-managed listener —
[[ama-cloudwatch-search]]'s `AWS-REFERENCE.md` standing rule: an AWS setting change needs a
matching Terraform update).

### Always tell the user in the CLI, same run

Not Slack-only, not ticket-only. One line per action taken: what expired, which branch ran,
what changed, and the verification result. A silent auto-renewal of a production listener is
the failure mode here.

Ledger row either way (`manual:acm-<slug>`), disposition = the ticket key.

## No threshold on the cost leg

A ~$625/mo extended-support line sits inside a much larger ElastiCache bill and clears no
threshold that isn't already crying wolf on normal growth. So the signal is a **new
`USAGE_TYPE` key appearing**, not a magnitude. Match client-side on
`Support|Extended|ExtSupp|EOL` and set-difference this month's keys against the prior two.

This leg detects *we started paying*. Priority-2 risk is mostly *we will start paying*,
which only comes from `*_PLANNED_LIFECYCLE_EVENT` prose. Both legs, different jobs.

## First run / new machine — three calibration gates

1. **Health reachability** — the run MUST surface the 3× `AWS_ECS_TASK_PATCHING_RETIREMENT`
   and the eu-west-1 `AWS_LAMBDA_PLANNED_LIFECYCLE_EVENT` dated 2026-11-10. Can't find
   them → the CLI profile can't read Health; STOP and report it. Otherwise the skill
   reports a clean `0 candidates` forever and looks healthy.
   **This tests API REACHABILITY, not triage accuracy** — both events are named in
   `AMA-AWS-SURFACE.md` with their expected verdicts, so any run following this skill has
   already seen the answer. Don't report it as a blind check.
   **This gate does NOT cover the mail leg — see gate 3.** Confirmed by running it:
   Health carries no event at all for the RDS/Lambda-Python/ElastiCache dates gate 3 checks
   (only RDS has a matching `startTime`, 2026-05-31). A Health-only calibration would
   declare those three unfindable.
2. **Cost leg — not fakeable.** `aws-notices-cost-check.sh` must return
   `USE1-ExtendedSupportYr1_Yr2-NodeUsage` for 2026-05/06/07 at ~$625/mo total, with
   August pro-rated to the mid-August upgrade. **Zero rows means the query shape broke, not
   that we stopped paying.** The number comes back from the API, so unlike gate 1 this
   tests something real.
3. **Mail leg — the leg with no other check.** Gmail search must surface the RDS
   PostgreSQL notice (2026-06-01, msg `19e821e49e1e4243`), the Lambda Python 3.10 EOS
   notice (2026-07-02, msg `19f21cea38b33bcc`), and the ElastiCache Redis OSS v4/v5 EOL
   notice (2026-08-07, msg `19fdc3f1eabab682`) — all three forwarded by Reviewer Two, all inside
   `noticeForwarders`. Zero hits means the query shape or the forwarder list broke, not
   that Reviewer Two stopped forwarding. Recorded passing 2026-08-26, see PROJ-15332.
   **Second assertion, same stop-and-report shape — the label leg.** EACH `noticeLabels`
   entry, searched over the 120-day window, must return ≥1 thread. Zero means the Gmail
   filter or the label name changed, NOT that AWS stopped sending — and there is no
   sender-based fallback, since these mails resolve to the subscribed mailbox's own address,
   which also matches unrelated mail. Here that is `label:"<one entry per line; this element only declares the type>"`, anchor msg
   `1a08a7b007c6d54e` (the 2026-09-10 digest), recorded passing 2026-09-10 — an instance
   fact like the msg ids above, not the rule.

## The weekly deadline reminder — derived, not seeded

`hooks/aws-notices-check.sh` recomputes it from the ledger on every prompt, throttled to
weekly, and appends it to whatever else the hook has to say. Nothing to create, nothing to
dedupe, nothing to keep in sync.

- Fires for a row that is **actionable** (disposition is a ticket key — not `stale`,
  `pending`, `watch` or `-`) **and dated inside `.awsNotices.deadlineHorizonDays`** (90).
  `D?` rows fire regardless, since an unknown deadline is not a distant one.
- **Selection is on the date, not the stored band.** A band is fixed at triage time and goes
  stale — a D2 item silently becomes D1 as the calendar moves — so a band-based filter would
  go quiet on exactly the item that just became urgent.
- **Collapsed by ticket key**, soonest first, with `(+N more event(s))` for the rest. One
  ticket routinely covers many events: the ElastiCache backlog alone is 7 events under one
  key, and listing them individually turned 2 real items into 9 lines. A list that long gets
  muted, which is the failure this whole skill exists to prevent.
- **Muting is per item, with a reason:** `aws-notices-record.sh settle <arn> <tier> stale`.
  Note this overloads `stale` to mean "window closed **or** the work is done" — a settled row
  is not necessarily one we decided didn't matter.
- If the weekly list routinely runs past ~6 items, raise it rather than widening the filter.

## Touched a script? Run the selftest

`bash scripts/aws-notices-selftest.sh` — 61 assertions over `aws-notices-record.sh`'s
refusal gates and their side effects. Not in `scripts/check-gates.sh`; that suite is for
PreToolUse hooks and none of this is one.

Takes over two minutes — give it a long timeout, or the default 2m kill lands mid-restore.
That restore is not atomic, so a kill used to strand the real ledger in `*.selftest.bak`
and wipe live state silently (2026-08-28: un-stamped a sweep's coverage gate). Leftover
`.bak` files are now recovered at startup. Same in `<amaSupportChannelName>-notices`' selftest.

Worth running rather than skipping: writing it found two bugs review had passed — an
unquoted `D?` case pattern (the `?` is a glob, so any `D<char>` validated) and jq's CRLF
output silently breaking anchored entity-classification patterns.

Relevance model, entity classes, exclusions with provenance, worked examples:
`AMA-AWS-SURFACE.md`.
