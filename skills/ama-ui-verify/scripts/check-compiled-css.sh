#!/usr/bin/env bash
# Step-0 cheap check: confirm an SCSS/CSS change actually compiled through the dev
# server's served stylesheet, without any login/data/browser needed. Session 90abc64c's
# own pivot ("test the exact CSS selector change directly against the real compiled
# stylesheet... sidesteps unrelated login/data-access gaps") -- do this FIRST, only
# escalate to the full run-ui-verify.sh login+navigate flow if the fix needs confirming
# against a real rendered element's computed value, not just that it compiled.
#
# Usage: check-compiled-css.sh <dev-server-url e.g. http://localhost:4210> <grep-pattern>
# Prints matching lines from the served global stylesheet, exits 0 if found, 1 if not.
set -euo pipefail

BASE_URL="${1:?usage: check-compiled-css.sh <dev-server-url> <grep-pattern>}"
PATTERN="${2:?usage: check-compiled-css.sh <dev-server-url> <grep-pattern>}"

INDEX_HTML="$(curl -sf "$BASE_URL" --max-time 10)" || {
  echo "could not fetch $BASE_URL -- is the dev server up?" >&2
  exit 1
}

# Angular dev builds emit a hashed styles.<hash>.css (or plain styles.css) linked from
# index.html -- component-scoped styles get inlined into JS at runtime instead, so this
# only covers GLOBAL styles (which is what _ag-grid-overrides.scss-style fixes are).
STYLES_PATH="$(printf '%s' "$INDEX_HTML" | grep -oE '(href="|src=")[^"]*styles[^"]*\.css' | sed -E 's/^(href|src)="//' | head -1)"
[ -n "$STYLES_PATH" ] || {
  echo "no styles*.css link found in $BASE_URL -- if the change is component-scoped (not global), this check doesn't apply, use the full login+computed-CSS flow instead" >&2
  exit 1
}

CSS="$(curl -sf "${BASE_URL%/}/${STYLES_PATH#/}" --max-time 10)" || {
  echo "could not fetch stylesheet at $STYLES_PATH" >&2
  exit 1
}

if printf '%s' "$CSS" | grep -n -- "$PATTERN"; then
  exit 0
else
  echo "pattern not found in compiled stylesheet -- change may not have compiled through, or is component-scoped (inlined at runtime, not in this file)" >&2
  exit 1
fi
