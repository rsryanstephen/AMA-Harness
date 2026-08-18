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

## 4. Goal-Driven Execution

Define success criteria, loop until verified.

- "Add X" → test invalid case, pass. "Fix bug" → repro test, pass. "Refactor" → tests pass before+after.
- Multi-step: state a plan, one verify per step:
  ```
  1. [Step] → verify: [check]
  ```
- Strong criteria → independent looping. Weak ("make it work") → constant clarification.
