#!/usr/bin/env bash
# Mirrors the stand-up ledger into Atlassian Forms (user instruction 2026-09-22: action
# items must be added to Atlassian Forms and tracked there).
#
# MIRROR, not replacement. `~/.claude/harness-state/standup/.standup-action-items.json`
# stays the working store -- firstSeen ageing, close-with-evidence, restated-item-updates
# and .standup-dismissed.json all keep working against it. This pushes a visible copy.
#
# Shape: ONE tracking issue (`.atlassian.standupTrackingIssueKey`), one attached form
# instance per ledger row. Multiple forms per issue is supported and verified live
# 2026-09-22; issue-per-item was rejected to keep the team board clean.
#
# Join key = the ledger `id` slug, written into the form's "Ledger id" question. NEVER
# write `sourceDoc` -- Zoom doc ids are access credentials and Jira is a shared surface.
#
# Usage: standup-forms-mirror.sh [--dry-run]
# Exit 1 on any API failure. Callers DEGRADE on that, never abort the run -- same rule
# Step 3b already applies to the Zoom fetch.
set -uo pipefail

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

. "$HOME/.claude/hooks/lib-harness-repos.sh"
. "$HOME/.claude/hooks/lib-claude-paths.sh"
HOST="$(hr_config_required '.atlassian.cloudId')" || exit 1
EMAIL="$(hr_config_required '.user.email')" || exit 1
CLOUD="$(hr_config_required '.atlassian.cloudUuid')" || exit 1
TMPL="$(hr_config_required '.atlassian.standupFormTemplateId')" || exit 1
ISSUE="$(hr_config_required '.atlassian.standupTrackingIssueKey')" || exit 1

if [ -z "${ATLASSIAN_API_TOKEN:-}" ]; then
  echo "standup-forms-mirror.sh: ATLASSIAN_API_TOKEN not set" >&2
  exit 1
fi

LEDGER="$HOME/.claude/harness-state/standup/.standup-action-items.json"
[ -f "$LEDGER" ] || { echo "standup-forms-mirror.sh: no ledger at $LEDGER" >&2; exit 1; }

BASE="https://api.atlassian.com/jira/forms/cloud/${CLOUD}"
# Every Forms call needs this header -- the API is opt-in experimental. Without it the
# route 404s, which reads like a missing form rather than a missing header.
HDR=(-H "X-ExperimentalApi: opt-in" -H "Content-Type: application/json")

api() { # api <method> <url> [body-file]
  local m="$1" u="$2" f="${3:-}" out code
  out="$(mktemp)"
  if [ -n "$f" ]; then
    code="$(curl -s --connect-timeout 10 --max-time 45 -o "$out" -w '%{http_code}' -u "${EMAIL}:${ATLASSIAN_API_TOKEN}" \
      "${HDR[@]}" -X "$m" --data-binary @"$f" "$u")"
  else
    code="$(curl -s --connect-timeout 10 --max-time 45 -o "$out" -w '%{http_code}' -u "${EMAIL}:${ATLASSIAN_API_TOKEN}" \
      "${HDR[@]}" -X "$m" "$u")"
  fi
  if [ "$code" != "200" ] && [ "$code" != "204" ]; then
    printf 'standup-forms-mirror.sh: %s %s -> HTTP %s\n%s\n' "$m" "$u" "$code" "$(cat "$out")" >&2
    rm -f "$out"; return 1
  fi
  cat "$out"; rm -f "$out"
}

# --- existing instances: ledger-id -> instance-id -------------------------------------
# One mirror at a time. A headless runner's Bash call times out at 2 min while this script
# runs on (59 forms x GET+PUT), and the model re-ran it -- two runs both saw an item as
# missing and both ADDed it (doubled forms, 2026-10-09 and 2026-10-12). mkdir is atomic on
# MSYS; a lock older than 15 min is a dead run's and is taken over.
LOCK="$(dirname "$LEDGER")/.forms-mirror.lock"
for _ in $(seq 1 60); do
  mkdir "$LOCK" 2>/dev/null && break
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +15 2>/dev/null)" ]; then rmdir "$LOCK" 2>/dev/null; continue; fi
  sleep 5
done
[ -d "$LOCK" ] || { echo "standup-forms-mirror.sh: another mirror run holds $LOCK" >&2; exit 1; }
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

instances="$(api GET "$BASE/issue/$ISSUE/form")" || exit 1
map="$(mktemp)"
# `tr -d '\r'` on every jq-to-file / jq-to-loop hop: jq.exe on Windows writes CRLF, and a
# stray CR rides into the id (URL 404s) or into the last field of a row (an empty Evidence
# answer was stored as a literal "\r" before this, live 2026-09-22).
printf '%s' "$instances" | jq -r '.[].id' | tr -d '\r' | while IFS= read -r iid; do
  [ -n "$iid" ] || continue
  # One read gives "<ledger id>\x1f<text>\x1f<owners>\x1f<status choice>" (status "2" = Done)
  # -- what a person may have changed in the Jira UI, pulled back before the PUT pass.
  if ! got="$(api GET "$BASE/issue/$ISSUE/form/$iid" | jq -r '.state.answers as $a | [($a["8"].text // ""), ($a["1"].text // "" | gsub("[\n\r]"; " ")), ($a["2"].text // "" | gsub("[\n\r]"; " ")), ($a["6"].choices[0] // "")] | join("\u001f")' | tr -d '\r')"; then
    # The map drives DELETIONS, so an incomplete map is dangerous, not merely stale --
    # a read that failed looks exactly like a form with no Ledger id. Mark it and let
    # the removal pass stand down. (`exit 1` here would only kill this subshell.)
    touch "$map.incomplete"; got=""
  fi
  lid="${got%%$'\x1f'*}"
  [ -n "$lid" ] && printf '%s\n' "$got" >> "$map.answers"
  printf '%s\x1f%s\n' "$lid" "$iid" >> "$map"
done

# --- pull: a form someone set to Done closes its ledger row; text/owners that differ from
# what this script last PUT (SNAP) were edited by a person and are adopted (user instruction
# 2026-10-16). Without this the PUT below reverts both. Dry run skips it (it writes the ledger).
SNAP="$(hstate standup .forms-pushed-snapshot.json)"
if [ -s "$map.answers" ] && [ "$DRY" -eq 0 ]; then
  python "$(dirname "$0")/ledger-sync-from-surface.py" "$LEDGER" forms "$SNAP" < "$map.answers" \
    || { echo "standup-forms-mirror.sh: pull failed, not pushing over unread edits" >&2; exit 1; }
fi

# --- desired rows ---------------------------------------------------------------------
# Field separator is US (\x1f), NOT tab. Tab is an IFS *whitespace* character, so `read`
# collapses runs of them and an empty field (a decision has no owners) silently shifts
# every later column -- hit live 2026-09-22, `status` came back holding the evidence text.
rows="$(mktemp)"
jq -r '.[] | [
    .id,
    (.text // "" | gsub("[\n\r]"; " ")),
    ((.owners // []) | join(", ")),
    (if .kind == "decision" then "2" else "1" end),
    (if .source == "slack" then "2" else "1" end),
    (.firstSeen // ""),
    (if .status == "done" then "2" else "1" end),
    (.evidence // "" | gsub("[\n\r]"; " "))
  ] | join("\u001f")' "$LEDGER" | tr -d '\r' > "$rows"

added=0; updated=0; removed=0
while IFS=$'\x1f' read -r id text owners kind source firstseen status evidence; do
  [ -n "$id" ] || continue
  # Every text answer is sent even when empty: PUT MERGES into the stored answer set
  # rather than replacing it, so an omitted key keeps whatever was there last run.
  body="$(mktemp)"
  jq -n --arg t "$text" --arg o "$owners" --arg k "$kind" --arg s "$source" \
        --arg d "$firstseen" --arg st "$status" --arg e "$evidence" --arg i "$id" '
    {answers: ({
      "1": {text: $t},
      "2": {text: $o},
      "3": {choices: [$k]},
      "4": {choices: [$s]},
      "6": {choices: [$st]},
      "7": {text: $e},
      "8": {text: $i}
    }
    + (if $d == "" then {} else {"5": {date: $d}} end))}' > "$body"

  iid="$(awk -F'\037' -v k="$id" '$1 == k { print $2; exit }' "$map")"
  # A row that closed BEFORE it was ever mirrored is history, not tracking -- don't
  # backfill it. A row already mirrored gets its Status flipped to Done and keeps its
  # form, so the closure is visible rather than the item silently vanishing.
  if [ -z "$iid" ] && [ "$status" = "2" ]; then rm -f "$body"; continue; fi
  if [ -z "$iid" ]; then
    if [ "$DRY" -eq 1 ]; then echo "would ADD    $id"; added=$((added+1)); rm -f "$body"; continue; fi
    attach="$(mktemp)"; printf '{"formTemplate":{"id":"%s"}}' "$TMPL" > "$attach"
    iid="$(api POST "$BASE/issue/$ISSUE/form" "$attach" | jq -r '.id' | tr -d '\r')" || exit 1
    rm -f "$attach"
    added=$((added+1)); echo "ADD    $id -> $iid"
  else
    if [ "$DRY" -eq 1 ]; then echo "would UPDATE $id"; updated=$((updated+1)); rm -f "$body"; continue; fi
    updated=$((updated+1)); echo "UPDATE $id -> $iid"
  fi
  api PUT "$BASE/issue/$ISSUE/form/$iid" "$body" > /dev/null || exit 1
  rm -f "$body"
done < "$rows"

# Every row PUT cleanly (an api failure exits above) -> record what the forms now hold, the
# baseline the next pull diffs against. Written only after the whole pass, never mid-way.
if [ "$DRY" -eq 0 ]; then
  jq '[.[] | {key: .id, value: {text: (.text // "" | gsub("[\n\r]"; " ")), owners: ((.owners // []) | join(", "))}}] | from_entries' \
    "$LEDGER" > "$SNAP.tmp" && mv "$SNAP.tmp" "$SNAP"
fi

# --- instances with no ledger row: the user asked for the item to stop being raised, so
# it is DELETED from the ledger (never faked as done). The mirror follows.
awk -F'\037' '{print $1}' "$rows" | sort -u > "$map.want"
if [ -f "$map.incomplete" ]; then
  echo "standup-forms-mirror.sh: a form read failed, skipping the removal pass" >&2
fi
while IFS=$'\x1f' read -r lid iid; do
  [ -n "$iid" ] || continue
  [ -f "$map.incomplete" ] && continue
  # No Ledger id = not ours (hand-attached in the Jira UI, or a read that came back
  # blank). Leaving an orphan is recoverable; deleting someone's real form is not.
  if [ -z "$lid" ]; then
    echo "SKIP   form $iid has no Ledger id -- not deleting"
    continue
  fi
  # A second form for a ledger id the map already holds is a doubled ADD (see the lock
  # above) -- the update pass only ever writes the FIRST one, so the extra goes stale.
  if grep -qxF "$lid" "$map.seen" 2>/dev/null; then
    if [ "$DRY" -eq 1 ]; then echo "would REMOVE duplicate $lid ($iid)"; else
      api DELETE "$BASE/issue/$ISSUE/form/$iid" > /dev/null || exit 1
      echo "REMOVE duplicate $lid ($iid)"
    fi
    removed=$((removed+1)); continue
  fi
  printf '%s\n' "$lid" >> "$map.seen"
  if ! grep -qxF "$lid" "$map.want"; then
    if [ "$DRY" -eq 1 ]; then echo "would REMOVE $lid ($iid)"; else
      api DELETE "$BASE/issue/$ISSUE/form/$iid" > /dev/null || exit 1
      echo "REMOVE $lid ($iid)"
    fi
    removed=$((removed+1))
  fi
done < "$map"

printf 'standup-forms-mirror.sh: %s added, %s updated, %s removed -> %s\n' \
  "$added" "$updated" "$removed" "https://${HOST}/browse/${ISSUE}"
rm -f "$map" "$map.want" "$map.seen" "$map.incomplete" "$map.answers" "$rows"
