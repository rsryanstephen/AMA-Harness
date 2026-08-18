---
name: ama-embs-reminders
description: Reads the eMBS publishing calendar (embs.com CalendarFull.asp) for GNM ("2000 GNMA I B") and FNM/FHL ("1630 FNMA LOAN") monthly-file arrival dates, and creates next-day all-day Google Calendar reminders carrying the AMA ETL processing runbook. Use when the user says "eMBS reminders", "check the eMBS calendar", "set up the monthly file reminders", or when hooks/embs-coverage-check.sh's nudge fires (coverage running out this month). Also the harness's install-time / new-adopter step for this feature -- no config needed beyond harness-config.json's `embs` block.
---

# eMBS monthly-file calendar reminders

GNM and FNM/FHL monthly files arrive on eMBS's calendar; the AMA ETL must process
them by 9:30 AM ET the **next** day. This creates a next-day all-day reminder per
arrival so nothing gets missed.

## Steps

1. Run `bash skills/ama-embs-reminders/scripts/embs-plan-reminders.sh` (via
   `~/.claude/skills/...` from any cwd). It fetches the configured calendar
   (`harness-config.json`'s `.embs.calendarUrl`), diffs against what's already synced,
   and prints a JSON array: `[{"date":"2026-08-07","kind":"FNM_FHL"}, ...]`.
   - `[]` → verify with one `search_events` call first. State file is a local marker,
     not the calendar — it can lie synced. Stale → delete it, re-run.
   - Script failure (bad/missing config) → surface it, don't silently skip.
2. For each entry, belt-and-braces dedupe: `search_events` for the exact summary
   (below) near that date on the target calendar — the state file
   (`~/.claude/.embs-reminders-synced`) can be stale on a fresh machine; the calendar
   itself is the real source of truth. Skip if a matching event already exists.
3. Otherwise `create_event`:
   - `calendarId`: `harness-config.json`'s `.embs.googleCalendarId` (default `primary`)
   - `allDay: true`, `startTime` = the entry's date, `endTime` = date + 1 day
   - `summary`:
     - `FNM_FHL` → `FNM/FHL monthly files processed today in ETL`
     - `GNM` → `GNM monthly files processed today in ETL`
   - `description`: the matching HTML body from `BODIES.md` (verbatim except markdown
     links rendered as `<a href>` — Google Calendar's description field takes HTML,
     not markdown, so a raw `[text](url)` would show up literally)
4. Append `<date>\t<kind>` to `~/.claude/.embs-reminders-synced` for each event created.
5. Report a one-line summary: how many created, of which kind, for which dates.

## Coverage refresh

eMBS only publishes tags a few months ahead — the script tracks the latest month
that actually carried a matching tag in `~/.claude/.embs-coverage`.
`hooks/embs-coverage-check.sh` nudges (via `on-prompt.sh`, once per day) once the
current month reaches that coverage month, so re-running this skill periodically is
how new dates get picked up — no manual calendar-URL upkeep needed, the URL is an
evergreen rolling page.
