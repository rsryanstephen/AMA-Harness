#!/usr/bin/env bash
# mongo-apply.sh -- run a chunked owner-update plan (udc.py mongo-move-js output, chunks separated by
# a '//CHUNK' line) one shell call per chunk, summing the OWNER counts. A chunk that prints no count
# line is UNKNOWN (the production legacy shell went silent once at 67/144 after ~7 min): stop and
# say re-run -- every op matches on _id AND current owner, so a re-run is safe and completes it.
# Usage: mongo-apply.sh <env> <plan.js> <expected-doc-count> <out-log>
# Exit 0 only when the summed OWNER matched == expected (or, on a re-run, matched + already-done == expected
# cannot be known here -- the caller compares snapshots afterwards; this script reports what it saw).
set -uo pipefail
ENV="${1:?}"; JS="${2:?}"; WANT="${3:?}"; OUT="${4:?}"
DOCDB="$HOME/.claude/skills/ama-mongo-access/scripts/docdb-query.sh"
umask 077; TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
awk -v d="$TMP" 'BEGIN{n=1; f=d"/chunk-"n".js"} /^\/\/CHUNK$/{n++; f=d"/chunk-"n".js"; next} {print > f}' "$JS"
: > "$OUT"; total=0; of=0; shared_m=""; shared_of=""; unknown=0; i=0
for f in "$TMP"/chunk-*.js; do
  i=$((i+1))
  res="$(bash "$DOCDB" "$ENV" "$(cat "$f")" 2>&1)"; printf '=== chunk %s\n%s\n' "$i" "$res" >> "$OUT"
  line="$(grep -E '^(OWNER|SHARED) ' <<<"$res" | head -1)"
  if [ -z "$line" ]; then echo "  chunk $i: NO RESULT LINE (unknown state)" >&2; unknown=1; continue; fi
  echo "  chunk $i: $line" >&2
  case "$line" in
    OWNER*) total=$(( total + $(grep -oE 'matched [0-9]+' <<<"$line" | grep -oE '[0-9]+') )); of=$(( of + $(grep -oE 'of [0-9]+' <<<"$line" | grep -oE '[0-9]+') )) ;;
    SHARED*) shared_m="$(grep -oE 'matched [0-9]+' <<<"$line" | grep -oE '[0-9]+')"; shared_of="$(grep -oE 'of [0-9]+' <<<"$line" | grep -oE '[0-9]+')" ;;
  esac
done
echo "TOTAL matched $total of $of (expected $WANT)${shared_of:+; SHARED matched $shared_m of $shared_of}" | tee -a "$OUT" >&2
[ $unknown -eq 0 ] && [ "$total" = "$of" ] && [ "$of" = "$WANT" ] && { [ -z "$shared_of" ] || [ "$shared_m" = "$shared_of" ]; }
