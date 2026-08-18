---
name: context-hygiene
description: Recommend /clear or /compact at the right moment to save tokens -- new unrelated task, or same task gone long and bloated. No tool lets Claude run either itself -- recommend only, never claim it happened.
---

# Context hygiene

Goal: catch the moment it's optimal to shrink context, say so plainly, before the
user (or the built-in auto-compact) has to do it the hard way.

**Hard limit, confirmed by tool inventory: no tool exposes `/clear` or `/compact` to
Claude.** Both are user-only slash commands. Never say "I've cleared the context" or
"I've compacted" -- that's false. Always phrase as a recommendation, let the user act.

## Two triggers

1. **Ticket switch (mechanical, near-zero cost)** -- [[commit-ticket]]'s "record the
   resolved ticket" step calls `set-session-ticket.sh` every time a ticket is resolved
   for the current task, **in any repo, not just `~/.claude`**. It diffs old vs new
   ticket and prints a `TOKEN-SAVINGS HINT` line when they differ. When that line
   appears in a tool result, surface it to the user in the reply -- don't silently
   swallow it. **This trigger is resumed-session-safe** -- it's plain tool OUTPUT the
   model reads fresh every turn, no dependency on this skill file having been loaded at
   all (unlike trigger 2, see Known limit below).
2. **Judgment call, no ticket switch needed** -- the user's new request shares
   nothing with the current thread (different repo, different system, no shared
   files/tickets/facts from earlier in the session) even though the session ticket
   hasn't changed (e.g. a quick unticketed question after a long ticketed task).
   Recognize this the same way you'd recognize any topic change -- don't wait for a
   mechanical signal that won't fire here.
3. **Context-percentage crossing (mechanical, resumed-session-safe)** -- `statusline.sh`'s
   `check_context` reads the live payload's `context_window.used_percentage` (no skill
   load needed, works even in an old/resumed session) and writes a one-shot line to this
   session's `.ctx-notices-$sid` at 60% and again at 80%, re-arming below 60%.
   `on-prompt.sh` relays + clears it. Same file also carries `chrome-verify-compact-
   nudge.sh`'s post-verify nudge (see [[ama-ui-verify]]). When it appears, surface it
   plainly per "How to say it" below -- it already names /compact vs /clear.

## Which to recommend

- **Genuinely new/unrelated task** -- earlier context has no further use → **/clear**.
  Full reset, cheapest going forward.
- **Same task, but this session has grown long** (many tool calls, lots of dead-end
  exploration, a natural checkpoint just passed -- e.g. right after a commit+push+
  ticket-wrap-up) and there's clearly more work coming on the SAME thread → **/compact**.
  Keeps the parts still relevant, drops the noise, cheaper than letting the platform's
  own automatic compaction trigger later (that happens near the context limit, not at
  the best time task-wise, and produces a worse summary because it's forced rather
  than chosen at a clean boundary).
- Unsure which fits → mention both, let the user pick. Don't guess silently and only
  offer one.

## How to say it

One line, not a paragraph, appended naturally to the end of the reply -- not its own
section, not alarmed in tone:

> This looks like a new task from what came before -- consider running `/clear` now to save tokens before continuing.

Don't repeat the recommendation every subsequent turn if the user ignores it once --
say it at the moment of the trigger, then drop it unless a NEW trigger fires.

## Known limit — trigger 2 isn't resumed-session-safe

Trigger 2 depends on this skill file having actually been loaded via CLAUDE.md's
first-reply setup, which only happens once, at a session's FIRST reply — a
long-running or `--resume`d session that started before this skill existed (or before
an edit to it) never re-reads CLAUDE.md until `/clear` or restart. If a task switch
ever goes unnoticed in an old/resumed session, that's why — trigger 1 is the one that
still works there.
