#!/usr/bin/env bash
# reminder-watch.sh <sid> -- `reminder.sh watch <sid>`, run from a private temp copy.
# Every open session keeps a watcher alive for hours, and running-script-edit-gate.sh denies an
# edit of a script a live process runs (bash reads lazily -- an edit corrupts the running loop).
# Watching reminder.sh in place made it uneditable for good (2026-10-21). The copy is what runs;
# reminder.sh stays free. Start watchers with THIS script, not `reminder.sh watch`.
src="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/reminder.sh"
copy="$(mktemp "${TMPDIR:-/tmp}/reminder-watch.XXXXXX")" && cp "$src" "$copy" \
  || exec bash "$src" watch "$@"
trap 'rm -f "$copy"' EXIT
bash "$copy" watch "$@"
