---
name: karpathy-guidelines
description: Activate on "karpathy" or "/karpathy".
license: MIT
---
# Karpathy Guidelines

Reduce common LLM coding mistakes. From [Karpathy's observations](https://x.com/karpathy/status/2015883857489522876).

**Tradeoff:** caution over speed. Trivial tasks: use judgment.

## 1. Think Before Coding

Don't assume, hide confusion, or pick silently among interpretations.

- State assumptions; ask if uncertain.
- Multiple interpretations → present all.
- Simpler approach exists → say so, push back.
- Unclear → stop, name confusion, ask.

## 2. Simplicity First

Minimum code, nothing speculative.

- No unasked features/abstractions/flexibility/error-handling.
- 200 lines could be 50 → rewrite.
- Senior eng would call it overcomplicated → simplify.

## 3. Surgical Changes

Touch only what's needed, clean only your own mess.

- Don't improve/refactor adjacent or working code; match existing style. Unrelated dead code → mention, don't delete.
- Remove only imports/vars/fns YOUR change orphaned; leave pre-existing dead code.
- Every changed line traces to the request.

### Extra "belt-and-braces" check = code change, not free safety

Brownfield. Missing check may be DELIBERATE, reason undisclosed. Assuming oversight breaks
things. Adding a term to a live condition is as dangerous as deleting one — both change
behaviour, only deleting FEELS risky.

Before adding any guard/condition/validation the request didn't ask for:

1. **Read what you're testing.** Find where the flag/property is ASSIGNED, not declared.
   Never infer semantics from name. `git -C <lib-repo> log -S".Foo =" --oneline` + grep the
   source. No assignment anywhere → flag dead, your term is a constant → STOP.
2. **Check local convention.** Sibling call sites handling the same type — do they test it?
   All ignore it → that IS the answer. Copy them, don't improve on them.
3. **Test the REAL type.** Mock hand-setting a field production never sets → test validates
   the assumption against itself, green forever. Build the mock like the real producer does.
4. Can't verify → don't add it. Say what you couldn't confirm, ship the minimum guard.

### Code that parses/rewrites/name-matches input another component produces

N producers, one assumed shape = the bug. List EVERY producer, run each for real, test with
their real output (all-producers test), never a hand-typed fixture. Split structured text at
top level only. Detail: [[ama-debugging-notes]]' `SHARED-CHOKEPOINT-CHANGES.md` (15416 → 15808).

### Change at a shared point = change to every consumer shape

Builder/base class/shared lib output others wrap → "it inherits the change" is a test case,
not a conclusion. Verify the EMITTED artifact in every consumer shape against the real engine,
never a hand-written proxy: [[ama-debugging-notes]]' `SHARED-CHOKEPOINT-CHANGES.md`.

Confirmed live, 7 weeks broken prod: [[ama-debugging-notes]]'
`UNVERIFIED-GUARD-ASSUMPTIONS.md`.

### Code that REWRITES PERSISTED DATA (migration, backfill, datafix, bulk update)

Same chokepoint rule on data: every reader of the field = consumer, every sibling step in
the run = producer a later step can undo. Test the ORDERED SEQUENCE on real document shapes,
diff every write in a dry run, list the readers fleet-wide. "Each step idempotent" proves
nothing about the sequence (15274 → 15835): [[ama-debugging-notes]]' `PERSISTED-DATA-REWRITES.md`.

## 4. Goal-Driven Execution

Define success criteria, loop until verified.

- "Add X" → test invalid case, pass. "Fix bug" → repro test, pass. "Refactor" → tests pass before+after.
- Multi-step: state a plan, one verify per step:
  ```
  1. [Step] → verify: [check]
  ```
- Strong criteria → independent looping. Weak ("make it work") → constant clarification.
