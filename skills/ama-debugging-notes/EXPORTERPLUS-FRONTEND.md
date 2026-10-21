# exporterplus frontend gotchas (Angular, ag-grid v26)

## SubSink prevents leaks, not races — overlapping in-flight calls

SubSink/`@autoUnsubscribe` cancel on destroy only — two overlapping in-flight calls on
the same still-alive component race unguarded. Known live bugs of this class, not yet
fixed (see the tickets for fix details):

- `catchError` placed outside `switchMap` permanently kills a search stream on first
  error (PROJ-15128).
- Non-cancelling `refreshGrid()` resubscribe races a slower in-flight `buildColDefs()`
  call (PROJ-15129, `core-grid-facade-abstract.ts:185-209`).

Convention/context: [[ama-architecture-notes]] FRONTEND-ARCHITECTURE.md's "RxJS cleanup
convention" section.

## ag-grid v26 API surface — two methods/events that don't exist

- **No `isDestroyed()` on `GridApi`** — only an internal `destroyCalled` bool. Checking
  `api.isDestroyed?.()` always returns `undefined`, so a guard using it never catches a
  dead grid. Correct check:
  `(api as unknown as {destroyCalled: boolean}).destroyCalled === true`.
- **No `gridDestroyed` event** (only `chartDestroyed`). A listener for it never fires —
  the real destroy path is `app-grid.ngOnDestroy` only (`app-grid.component.ts:217`).

Consequence if this is missed: a grid api recreated inside a live component (e.g. a
report switch via `change$`) never gets `destroy()`'d on the old api — its timers/
subscriptions keep firing on the dead api forever ("grid has been destroyed" log spam +
real leak). Confirmed in `grid-decimal-rounding.service.ts`
(`isGridDestroyed`/`purgeIfGridDestroyed`) — check there first before re-diagnosing.

## Reactive-forms CVA validity-caching trap

Angular wires a `ControlValueAccessor` sub-input with `emitEvent:false` in some places
here (e.g. an operator dropdown swapping its value sub-input via `ngSwitch`). When the
sub-input's own validity changes but its *value* doesn't, the outer control's cached
`.valid` does NOT update — anything reading the outer control's cached status (not the
inner control directly) trusts stale validity.

**Don't fix with**: `setTimeout` re-validation (can break other auto-reactivate logic
that watches `valueChanges` on disabled controls), or cross-component getters reading
live child `.form` state in a template (risks
`ExpressionChangedAfterItHasBeenCheckedError` if anything nearby force-runs
`detectChanges()` in `ngAfterViewChecked`).

**Correct fix shape**: subscribe the outer control to the inner's `statusChanges`, call
`outerControl.setErrors(...)` — bubbles validity with zero `valueChanges` emission, can't
trip unrelated value-watching logic. Confirmed working example:
`field-value-input.component.ts` (`syncOuterControlValidity`, `computeValidationErrors`),
from PROJ-15099.

This is a general Angular CVA/`emitEvent:false` interaction, not specific to one field —
watch for the same shape anywhere a sub-form's validity needs to bubble to a parent
control without a corresponding value change.

**Why loud re-validation isn't the fix, specifically**: `subscribeToActivateCriteria` in
`criteria-picker-view.component.ts` re-activates a disabled criterion on ANY
`valueChanges` of its value control. Re-validating loudly
(`updateValueAndValidity({emitEvent:true})`) trips that auto-reactivation AND churns CD
(NG0100 via `ngAfterViewChecked` force-`detectChanges`) — `setErrors` avoids both because
it emits `statusChanges` but no `valueChanges`.

**Testing caveat**: the unit harness's synchronous `detectChanges()`+`whenStable()`
self-corrects the staleness this bug depends on, so a green e2e spec doesn't prove the
live bug is closed. Verify the mechanism (inner status-only change → outer reflects via
`setErrors`) as a discriminating unit test; verify the trigger (`statusChanges` actually
firing invalid) with live browser console logs.

## async `@Input` read too early → null request, never retried (PROJ-15141)

Bug class (reoccurs): component fires fetch in `ngOnInit`/eager-init BEFORE an `@Input`
delivered via an `| async` binding has propagated. Input null at fire time → bad request
(e.g. `/field/public/null/...values`), and component never re-runs when value lands →
stale/empty forever. Seen: `field-value-input` `multiTableSetName` (fed from
`availableCriteriaFields$ | async` down the `criteria-picker` chain).

Fix shape: (1) guard the fetch — skip when the required async input is falsy; (2) re-run
in `ngOnChanges` when it arrives (`changes.x.currentValue` truthy AND changed). Do NOT
hardcode a default value to "fix" it — silent-wrong-data risk (advisor).

CD-ordering root cause (`create-cohort`): an RxJS subscriber (combineLatest → form patch
→ child rows created) runs BEFORE a sibling `| async` binding propagates the SAME emission
to the child `@Input`. So children see stale inputs at creation. Order = subscription
order; template async pipes subscribe last.

Debug method that cracked it (advisor — static tracing lied repeatedly here):
- literal `null` vs `undefined` discriminates: `AsyncPipe` pre-emit → `null?.x` =
  `undefined`; a present-but-`null` = value explicitly assigned null → look at
  construction/service, NOT bindings/timing.
- verify empirically: `npm run start:qa`, add temp `console.log`s at suspect points,
  reproduce. Trust the frontend's PARSED object, not the network tab.
- regression + "value should be X but is null" → read `git log -p` diffs of the
  construction points, not just `--oneline`.

`multiTableSetName` fact: per-report, from reports API template. `'pool'` ONLY if report is
`pool-data`/`pool-loan-view`, else `'loan'`. NOT CMO-derived. Derive from the template
(`availableCriteriaFields.multiTableSetName`) if it exists in the template.
