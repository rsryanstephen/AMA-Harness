# Relevance model — vendor concept → AMA surface

## Why this skill exists

2026-05-05 notice, subject "Ginnie Mae Single-Family Enhancements - June/July 2026". Subject
and ~90% of body: Reperforming Loans + Opportunity Zone stratifications, both irrelevant to
AMA. One closing **Note** said Ginnie would switch WARM/WALA from actual UPB to scheduled
UPB at Go Live Aug 2026, parallel test files on request. Missed.

August: GNM remterm −1 / loan age +1, a 2-month Jun→Jul step across report columns and the
Aging Curve, plus phantom curtailment CPR that reached a client. Three months' warning, one
sentence, wrong subject line. Hence rules 1–4 in `SKILL.md`.

## Opt-in format upgrades — the recurring, expensive trap

Vendor adds fields to a loan-level table, and clients are **not** upgraded automatically:
"Submit a Request", typically a 3-month window. Miss it and the feed silently stays on the
old layout — no error, no missing-file alert, just absent columns.

Confirmed instances, both windows now CLOSED. Both sit on tables riding files AMA is
confirmed to ingest (product scope below), so neither is hypothetical:
- **`GnmLoan` 43 → 44 cols** (`SchedRPB`), announced 2026-07-09, dual-version period ended
  2026-08-01 daily / 2026-08-10 monthly. Rides `GNM_GLLM.ZIP`.
- **`FnmLoan` 60 → 62, `FnmLoanMod` 43 → 44, `FhlLoan` 64 → 66, `FhlLoanMod` 42 → 43**
  (VANCS/UVANCS credit-score fields), announced 2025-11-10, window expired ~2026-02-10.
  On the FNM/FHL monthly loan-level files; which product carries the `*LoanMod` tables is
  not confirmed. Both column counts are with eMBS on case
  **0903508206** (asked 2026-08-17, awaiting reply) — the question is entitlement and
  layout, NOT credit-score interest: AMA never reports those fields, yet a missing column
  still breaks the load. If a request was never submitted, nothing announces it; the first
  symptom is a load failure or silently absent columns.

Treat any "Submit a Request"/"will not be upgraded automatically" sentence as T2 on sight,
and check whether the request was actually submitted — nobody gets a reminder.

## Corrections without correction files — stored history stays wrong

Vendor sometimes announces corrections it will NOT redistribute: "Ginnie Mae is not
providing correction files. Clients that store history may want to update their data"
(2026-06-18, 115 ARM pools' May 2026 coupons; pool list only via a linked xlsx). AMA
stores history (`loanhistorybyperiods`, `f<YYYYMM>_*`, `poolembsfieldhistoryview`) →
affected stored months keep wrong values until patched by hand. Treat as T2 on sight:
the action is ours, has no deadline, and fails silently.

## Coverage limit worth knowing

The programme's ORIGINAL notice (2025-06-02, "Ginnie Mae Single-Family Pool and Loan
Disclosure Enhancements") is **not retrievable in this mailbox** — later notices cite it,
searches for it return nothing. So the mailbox is not a complete archive; when a notice
cites an earlier one, the citation may be all there is. Original Go-Live was Feb 2026,
slipped to Aug 2026.

## Product scope — what AMA actually ingests

GNM and FNM/FHL monthly single-family, pool + loan level.

**Monthly loan level = exactly `GNM_GLLM.ZIP`, `FNM_NLLM.ZIP`, `FHL_LLM.ZIP`.**
Entitlement/subscription name **`REFINITIV-1`** — quote that string when asking eMBS what
a subscription covers.

Provenance: ETL owner → eMBS support, 2026-08-12, enumerating "the current monthly
loan-level products" during ICE-endpoint testing. **Scope of that evidence — read it
narrowly:**
- Three file names and the entitlement string, nothing more. It does NOT say which vendor
  TABLES ride which file. `GnmLoan` on `GNM_GLLM` is safe (the Ginnie notices tie them);
  which product carries `FnmLoanMod`/`FhlLoanMod` is **not established anywhere** — don't
  assert a file for a table without checking, that is the LDST error one family over.
- Loan level only. It does NOT enumerate pool-level products; those stay as before.
  **Open gap worth closing:** "pool + loan level" above has no provenance at all, so a
  pool-level notice (e.g. a `SecCurr` layout change) has nothing to check against. Asking
  eMBS for the pool-level product list is the obvious next step — case 0903508206 already
  carries an entitlement question.
- It does NOT touch the stratification family (`GNM_LDST` / `FHL_LDST` / `LoanDist`) —
  a different product family, silent rather than negative. Neither cleared nor excluded:
  PROJ-15310.

Arrival *tags* (`2000 GNMA I B` → GNM, `1630 FNMA LOAN` → FNM/FHL) are a separate axis,
per `ama-embs-reminders/scripts/embs-plan-reminders.sh`. That script tracks calendar
arrival only — it has no pool/loan axis and no file names, so don't cite it for product
scope. Notices are written in file names, the calendar in tags; you need both lists.

**Out-of-scope products** — discard the PARAGRAPH, never the notice: multifamily (any
agency), SBA, STACR/CAS, CMO/REMIC, LLDC pseudopool, new offerings not subscribed.

CONFIRMED exclusions, with provenance (grow this list; a confirmed "we don't ingest X" is
the cheapest possible triage):
- `GNM_GNLM.ZIP` (Ginnie multifamily) — ETL owner, 2026-02-25, answering that exact
  "does this notice affect AMA?" question by email. Precedent worth noting: this triage
  used to happen ad-hoc over email, which is what this skill systematises.
- `FNM_NCLR.ZIP` / Fannie CAS — ETL owner, 2026-02-11 (PROJ-14939), "Not ingested".
- `FHL_SOAM` / `FHL_MSDT` / `FHL_DELH` — same reply: ingested but NOT used in Model Builder.
  Careful: that clears ONE consumer, not all of AMA. Not a full exclusion.
- `SecCurr.WAOCS` and credit-score fields generally (FICO, VantageScore/VANCS) — not
  reported anywhere in AMA, user-confirmed 2026-08-18, so almost certainly not ingested.
  **Value/calculation** changes on them are permanently out of scope — e.g. the 2025-11-17
  WAOCS recompute (prefer refreshed FICO over original, "No Schema Change") → T4, close it.
  Read the next section before extending that to a layout change.

### "We don't report field X" kills VALUE impact only — never LAYOUT impact

Same trap shape as `FHL_SOAM` above: a narrow clearance read too widely. A column-count or
position change on a table riding an ingested product breaks the load whether or not
anyone reports the field. So `WAOCS` being unreported retires recompute notices, but a
notice adding columns to `FnmLoan` still lands T2 — the field's use and the file's layout
are independent questions. Ask which one a notice is actually about.

**AMA reads eMBS DATABASE format, not Agency Aligned format** — evidenced, not assumed.
Freddie's April 2026 consolidation changed Agency-format "not available" from blanks to
sentinels (`9`, `77.777`, `7777`) in WA LTV/CLTV/DTI/FICO. Checked `poolloanview`
`securityperiodic_waoltv = 9` across the March and August snapshots: **49 both times**, with
nulls still dominant (~166k FHL) and growing only in step with pool count. The sentinels
never arrived. So a notice scoped to "Agency format"/position-keyed layouts is very likely
moot for us — still triage it, but this is why it usually lands T4 rather than T1.
**In-scope but ETL/ops-tagged, not app**: SFTP / data-centre migration, maintenance
windows, file delays, redistributions — they hit the ingest path, so still flag, owner =
`.ama.etlAssigneeName`.

## Vendor → AMA mapping

| Vendor table/field | AMA surface | Why it matters |
|---|---|---|
| `GnmLoan.RemTerm` | `loanperiodic_remainingterm(_unique)`, `pricing_remainingterm`, `loanhistorybyperiods.remterm` | AVG/WA Loan Rem Term, Remaining Term, MCF WAM, WAMQ, `WAM_HIST` |
| `GnmLoan.LoanAge` | `loanperiodic_loanage(_unique)`, `historical_loan_age`, `f<YYYYMM>_historical_loan_age` | AVG/WA Current Loan Age, WALA, MCF Age, WALAQ, Loan Age Band, **Aging Curve x-axis** |
| `GnmLoan.SchedRPB` | `sched_rpb` (NB: ours is ETL-derived and predates the vendor field — not the same provenance) | scheduled-basis recomputation |
| `SecCurr.PublWam/PublWala`, `Wam/Wala` | `securityperiodic_wam/wala`, `publishedwam/publishedwala`, `embswam/embswala` | pool-level WAM/WALA columns, Current WALA |
| `SecCurr.WtdAvgEffDt` | `securityperiodic_wtdavgeffectivedate` | **basis/reporting-period marker** — advanced 2 months for 81.5% of GNM pools at the Aug 2026 switch vs 0% FNM/FHL. Use to detect a boundary from data instead of hardcoding a date |
| `SecCurr.WamSrc/WalaSrc` | `securityperiodic_wamsrc/walasrc` | `P` vs `PP` provenance flags. GNM sat at `PP` both sides of the change, so NOT a reliable basis marker on its own |
| `Hist` (`GNM_FH`) monthly WAM | `poolembsfieldhistoryview.f<YYYYMM>_wam` | pool `WAM_<Mon>_<Year>`, Current WAM |
| `LoanDist` | band/stratification columns | Loan Age Band and sibling bands. **Unresolved** — no confirmed source file, and whether the ETL ingests `GNM_LDST` at all is the open question in PROJ-15310. Don't read this row as a confirmed ingest path |
| `RemovalReasonCode` | liquidation/payoff fields | payoff-age columns, CPR inputs |

Downstream column detail: `ama-architecture-notes/AGGREGATION-DB.md`, `REPORT-TEMPLATES.md`.

## Recall-booster terms — boost, never filter

**Vendor side:** WARM, WALA, WAM, scheduled UPB, actual UPB, RPB, `SchedRPB`, remaining
term, loan age, factor, curtailment, Go Live, parallel, test file, "Submit a Request",
alter statement, schema, layout change, new column/attribute, enumeration, relabel,
deprecat*, effective date, restated, redistributed, correction, "one-month gap".

**AMA side:** `f<YYYYMM>_*` period-column family, `current_rpb`, `sched_rpb`,
`aggregation_metadata.gnm_available`, `latest_cpr_field`, `CPR1_MM_YY`.

Neutral prose is the trap: "calculated using scheduled UPB rather than actual UPB" contains
no alarming word. Judgement links it to AMA columns — a keyword list alone won't.

## Worked examples

**POSITIVE, hard case — 2026-05-05.** Subject in scope (GNM single-family) so subject can't
discard. Reperforming/Opportunity-Zone paragraphs → T4. Closing note hits WARM, WALA, UPB,
Go Live, test file → mandatory finding → **T1** (basis change reaching remterm and loan-age
columns, Aug 2026, 2-month discontinuity, Aging Curve re-bucketing) **plus T2** (parallel
test files on request, dated window). Caught.

**POSITIVE, field detail — 2026-05-04**, subject "…Pool and Loan Disclosure Enhancements -
Aug 2026". Field-level table: `LoanAge`/`RemTerm` calc change, `SchedRPB` NEW,
`PublWam`/`PublWala` basis, and `WtdAvgEffDt` "Switch date to current month… **a one-month
gap will appear in the files/database**". → T1 + **T2** (44-column `GnmLoan` upgrade needs
an explicit request; not automatic; 3-month window). The T2 is the expensive one to miss —
a skipped opt-in silently deprives us of a field.

Both are the first-run calibration targets in `SKILL.md`.

**NEGATIVE — SBA factor-file notice, multifamily coupon corrections, Freddie STACR
enhancements.** Every paragraph out-of-scope product → notice closed irrelevant, one digest
line, no Slack. Note it's still *read* paragraph by paragraph before closing.
