#!/usr/bin/env bash
# Diffs the set of hook scripts wired in settings.template.json (this repo) vs the live
# ~/.claude/settings.json. The two are separate files and have drifted BOTH directions
# for real (template-only: hook dead for this user; live-only: fresh adopter silently
# missing a gate). Prints one line per drifted script name; exit 1 on drift, 0 on parity.
# Informational -- the caller decides what to do (on-stop.sh appends a deduped
# harness-gaps.md line).
# Usage: check-settings-parity.sh [harness-repo-root]
set -u

harness="${1:-$(git -C "$HOME/.claude/skills" rev-parse --show-toplevel 2>/dev/null)}"
template="$harness/settings.template.json"
live="$HOME/.claude/settings.json"
[ -f "$template" ] && [ -f "$live" ] || exit 0

names() { grep -oP 'hooks/\K[A-Za-z0-9._-]+\.sh' "$1" | sort -u; }

drift="$(comm -3 <(names "$template") <(names "$live") \
  | awk -F'\t' '$1!=""{print "template-only: "$1} $2!=""{print "live-only: "$2}')"

# Hook names alone are not enough: this returned parity while the template was missing
# `autoMode` entirely and install.ps1 never merged `statusLine`, so a fresh adopter got
# neither. Also compare the SHAREABLE top-level keys.
#
# Defined as a DENYLIST of personal keys, not an allowlist of shareable ones. An
# allowlist was tried first and is the same trap this check exists to catch: it named the
# template's own keys, so adding a shareable key and forgetting to list it here failed
# silently -- and a key present only in LIVE could never be flagged at all, which is
# exactly how `autoMode` went unmirrored. Inverted, the two failure modes swap severity:
# forgetting to add a NEW personal key here is noisy but safe (it reports as drift and
# you add it), while a genuinely shared key is caught with no edit at all, in either
# direction. `permissions.defaultMode` is nested, never a top-level key, so it needs no
# entry -- it stays personal by living inside `permissions`, which is merged key-by-key.
PERSONAL_KEYS='model theme tui effortLevel advisorModel skipWorkflowUsageWarning'
# `keys[] as $k` first, deliberately: inside `select(...)` the `.` is rebound to
# `index`'s own input (the denylist array), so the obvious `index(.)` form silently
# matches nothing and every key is treated as personal -- shared_keys returns EMPTY and
# the whole check passes vacuously. Caught in testing; bind the key to a variable.
shared_keys() { jq -r --arg p "$PERSONAL_KEYS" 'keys[] as $k | select(($p | split(" ") | index($k)) == null) | $k' "$1" | sort; }
keydrift="$(comm -3 <(shared_keys "$template") <(shared_keys "$live") \
  | awk -F'\t' '$1!=""{print "template-only key: "$1} $2!=""{print "live-only key: "$2}')"
[ -n "$keydrift" ] && drift="$(printf '%s\n%s' "$drift" "$keydrift" | sed '/^$/d')"

# autoMode.environment is a union at merge time, so template entries missing from live
# means the adopter never re-ran install.ps1 after the template gained them.
if jq -e '.autoMode.environment' "$template" >/dev/null 2>&1; then
  envdrift="$(comm -23 <(jq -r '.autoMode.environment[]' "$template" | sort) \
                       <(jq -r '.autoMode.environment[]? // empty' "$live" | sort) \
    | sed 's/^/template-only autoMode.environment: /' | cut -c1-120)"
  [ -n "$envdrift" ] && drift="$(printf '%s\n%s' "$drift" "$envdrift" | sed '/^$/d')"
fi

[ -n "$drift" ] || exit 0
printf '%s\n' "$drift"
exit 1
