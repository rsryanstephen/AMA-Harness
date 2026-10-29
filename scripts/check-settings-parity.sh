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

# Hooks that are DELIBERATELY live-only -- personal behaviour that must not ship to an
# adopter. Filtered out of the LIVE side only, so a template-only entry of the same name
# still reports (that direction means the hook shipped by mistake, which is the severe one).
# Same denylist-not-allowlist reasoning as PERSONAL_KEYS below: forgetting to add a new
# personal hook here is noisy but safe, while a genuinely shareable hook is caught with no
# edit at all.
#   plan-exit-auto-approve.sh -- auto-approves the plan-approval prompt, i.e. removes the
#   plan review gate entirely. Correct for a solo user who asked for it; never a default.
# Space-separated, split to one-per-line for `grep -f` (same shape as PERSONAL_KEYS'
# `split(" ")`). An empty denylist file matches nothing, so `-v` passes every name through --
# the safe direction if this ever ends up blank.
PERSONAL_HOOKS='plan-exit-auto-approve.sh'
live_names() { names "$1" | grep -vxF -f <(printf '%s\n' $PERSONAL_HOOKS) || true; }

drift="$(comm -3 <(names "$template") <(live_names "$live") \
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
# enabledPlugins: org-pushed plugin bundles are per-machine, never shipped in the template.
# modelSettings: per-model effort levels, as personal as effortLevel (flagged live-only 2026-09-25).
# agentPushNotifEnabled: the user's own push-notification toggle from /config (flagged live-only 2026-10-21).
PERSONAL_KEYS='model theme tui effortLevel advisorModel skipWorkflowUsageWarning enabledPlugins modelSettings agentPushNotifEnabled'
# `keys[] as $k` first, deliberately: inside `select(...)` the `.` is rebound to
# `index`'s own input (the denylist array), so the obvious `index(.)` form silently
# matches nothing and every key is treated as personal -- shared_keys returns EMPTY and
# the whole check passes vacuously. Caught in testing; bind the key to a variable.
shared_keys() { jq -r --arg p "$PERSONAL_KEYS" 'keys[] as $k | select(($p | split(" ") | index($k)) == null) | $k' "$1" | sort; }
keydrift="$(comm -3 <(shared_keys "$template") <(shared_keys "$live") \
  | awk -F'\t' '$1!=""{print "template-only key: "$1} $2!=""{print "live-only key: "$2}')"
[ -n "$keydrift" ] && drift="$(printf '%s\n%s' "$drift" "$keydrift" | sed '/^$/d')"

# Wiring parity is not value parity: this check reported CLEAN while the live
# UserPromptSubmit timeout had been raised 60 -> 180 (to stop a contended on-prompt.sh run
# having its injected context DISCARDED) and the template still said 60 -- so a fresh
# adopter inherited the exact failure the raise was for, and the drift sat unnoticed from
# 2026-08-31 to 09-01. The script name matched on both sides, which was all this compared.
# Same script, same event, different timeout is real drift; report it in both directions.
# The script name is pulled out INSIDE jq, not by a later sed. Most commands end in
# `2>/dev/null || true`, so a `|`-joined line already contains pipe characters and any
# field-splitting sed leaves `...|| true|5` behind -- the names never line up and every
# hook reports as drift. `capture` takes the name straight from the command instead.
hook_timeouts() {
  jq -r '.hooks // {} | to_entries[] | .key as $ev
         | (.value[]? | .hooks[]? | select(.timeout != null)
            # LAST hooks/ match, not the first: most commands are `hook-run.sh <real-hook>.sh`,
            # so capturing the first collapses every wrapped hook to the wrapper name --
            # unreadable, and it makes two unrelated timeouts look comparable. (No
            # apostrophes in these comments: the jq program is a single-quoted shell string.)
            | ([.command | scan("hooks/([A-Za-z0-9._-]+\\.(?:sh|ps1|pl))")] | last | .[0]) as $n
            | "\($ev) \($n) timeout=\(.timeout)")' "$1" 2>/dev/null \
    | grep -vE " ($(printf '%s' "$PERSONAL_HOOKS" | tr ' ' '|')) " \
    | sort -u
}
todrift="$(comm -3 <(hook_timeouts "$template") <(hook_timeouts "$live") \
  | awk -F'\t' '$1!=""{print "template timeout: "$1} $2!=""{print "live timeout: "$2}')"
[ -n "$todrift" ] && drift="$(printf '%s\n%s' "$drift" "$todrift" | sed '/^$/d')"

# Name sets miss DUPLICATES: same hook wired twice -> fires twice (2026-10-12, 9 live entries).
# Template repeat matcher is the cause -- install.ps1 merges by matcher into the FIRST
# same-matcher group, so a 2nd template group re-splits live on every re-install.
dupes() {
  { jq -r '.hooks // {} | to_entries[] | .key as $e | .value[] | "\($e) matcher \(.matcher // "-")"' "$1"
    jq -r '.hooks // {} | to_entries[] | .key as $e | .value[] | .hooks[]? | "\($e) hook \(.command)"' "$1"
  } 2>/dev/null | tr -d '\r' | sort | uniq -d | sed "s|^|$2 repeated: |" | cut -c1-160
}
dupdrift="$(dupes "$template" template; dupes "$live" live)"
[ -n "$dupdrift" ] && drift="$(printf '%s\n%s' "$drift" "$dupdrift" | sed '/^$/d')"

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
