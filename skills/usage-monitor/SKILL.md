---
name: usage-monitor
description: What to do when a UserPromptSubmit hook injects a USAGE THRESHOLD CROSSED notice (5-hour or weekly plan usage hit 75% or 90%) -- how to surface it, and how the underlying mechanism works.
---

# Usage monitor

Two real limits, confirmed via Claude Code docs research (no guessing): a rolling
**5-hour** window and a **weekly** window. Claude Code's statusLine JSON payload
(`rate_limits.five_hour.used_percentage`, `rate_limits.seven_day.used_percentage`)
is the ONLY place this percentage exists -- no CLI command, no local file Claude Code
itself writes, no API a script could hit. `/usage` shows historical Day/Week totals,
not live percentage-against-cap, and its output is UI-only anyway -- never reaches
the model's context even if the user runs it.

## The two-part mechanism this harness builds instead

1. **`hooks/statusline.sh`** (wired as the `statusLine` command in settings) runs on
   every render. It draws a live colored bar -- green under 75%, bold yellow 75-89%,
   bold red 90%+, for both windows -- using raw ANSI escapes. **This only works in the
   statusLine bar.** Chat replies render through a markdown pipe with no color support
   at all -- don't ever try to put ANSI in a chat reply, it'll just show as garbage
   escape-code text.
2. Same script tracks, per window, the highest threshold already notified (state in
   `~/.claude/.usage-state/`, reset whenever `resets_at` moves to a new window). The
   FIRST time a window crosses 75% or 90% since its last reset, it appends one line to
   `~/.claude/.usage-notices`.
3. `hooks/on-prompt.sh` (UserPromptSubmit) checks that file every turn; if non-empty,
   folds its contents into `additionalContext` telling Claude to surface it, then
   truncates the file -- one-shot, not repeated every subsequent turn.

## Sibling mechanism: per-session context-window notice

Same `statusline.sh`, a second `check_context` function, same shape -- but keyed by
**session id**, not account-wide, because context usage is per-session while the 5h/
weekly windows aren't. Reads `context_window.used_percentage` from the same payload,
fires once at 60%/80% into `~/.claude/.ctx-notices-$sid` (re-arms below 60%), relayed
by the same `on-prompt.sh`, reading only its own session's file. Also fed by
`chrome-verify-compact-nudge.sh` (post-verify /compact nudge). See
[[context-hygiene]] trigger 3 for what to do when it fires -- it's a `/compact`-or-
`/clear` recommendation, not a rate-limit warning, so it doesn't use the "USAGE
THRESHOLD CROSSED" wording above.

## What to do when `additionalContext` says USAGE THRESHOLD CROSSED

Surface it prominently in the SAME reply, distinct from normal prose -- a bolded line
or a blockquote near the top of the reply, not folded into the middle of unrelated
work. E.g.:

> **⚠ Weekly usage at 91% -- resets in ~14h.**

Then continue with whatever the user's actual prompt asked for -- don't let this
replace answering them, it's a heads-up, not the whole reply. Don't repeat it again
next turn; the hook already won't re-inject it (one-shot), so don't manually re-raise
it either.

## Known limits, be upfront about them, don't overclaim

- No mechanism here reads or influences the ACTUAL account limits -- purely reactive
  to whatever Claude Code itself already computes and exposes via statusLine.
- If Claude Code changes the statusLine JSON schema (field renamed/removed), this
  silently stops firing -- the script uses `// empty` fallbacks so it won't crash, it
  just goes quiet. Worth a periodic sanity check (glance at the bar) rather than
  blind trust it's still wired correctly.
- This can't warn REALTIME mid-turn -- it only checks at the start of each new user
  prompt (UserPromptSubmit is the only hook that can inject context the model reads).
  A single very expensive turn that crosses a threshold mid-flight surfaces the notice
  on the NEXT prompt, not immediately.
