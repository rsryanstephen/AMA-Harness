#!/usr/bin/env bash
# Flattens a saved my_notes_get_note_content(include=transcript) result to "Speaker: text"
# lines. The raw JSON is ~4x the text (65k vs 15k chars on 2026-10-07) and overflows the
# tool-result cap into a file; reading the flattened text keeps an unattended run's tokens
# flat. Speakers are Zoom's own labels (Speaker 1/2, Unknown) -- they do NOT identify people.
# Usage: zoom-transcript-flatten.sh <saved-result.json>
set -uo pipefail
f="${1:?usage: zoom-transcript-flatten.sh <saved-result.json>}"
jq -r '.transcript as $t
  | ($t.items // [])[]
  | (.speaker_id as $id | ([($t.speakers // [])[] | select(.speaker_id == $id) | .display_name][0] // "Unknown"))
    + ": " + (.text // "")' "$f" | tr -d '\r'
