#!/usr/bin/env bash
# PostToolUse hook (Edit|Write + Bash/PowerShell). harness-config.json is untracked --
# it syncs across machines via the Octopus "Claude Harness" variable set, not git -- so
# a local edit that never gets `octopus-config-sync.sh push`ed is silently lost to every
# other machine. Mechanical trigger per CLAUDE.md's rule (self-recognition is
# unreliable); same nudge shape as library-version-sync-reminder.sh.
#
# Content-hash against a statefile, not payload parsing: a Bash call that merely READS
# the config (jq lookups happen constantly) leaves the hash unchanged and stays silent,
# and a fetch/push by octopus-config-sync.sh itself just re-baselines without nudging.
# Zero jq forks; one md5sum fork, only on payloads that name the file at all.
set -u

CFG="$HOME/.claude/harness-config.json"
STATE="$HOME/.claude/.harness-config-synced-hash"

IFS= read -r -d '' payload || true
# Cheap raw-payload pre-filter (precedent: aggregation-secret-gate.sh). Note the first
# needle does NOT match harness-config.example.json (".example." breaks the substring).
# The second needle matters on its own: a plain `octopus-config-sync.sh push` command
# never names harness-config.json, and it MUST reach the re-baseline branch below or the
# statefile goes stale the moment Claude obeys the nudge (real bug, caught in review).
case "$payload" in *harness-config.json*|*octopus-config-sync.sh*) ;; *) exit 0 ;; esac

[ -f "$CFG" ] || exit 0
hash="$(md5sum "$CFG")"; hash="${hash%% *}"

last=""
[ -f "$STATE" ] && IFS= read -r last < "$STATE" || true

# The sync script's own runs (fetch rewrites the file; push means we're now in sync)
# re-baseline silently -- nudging Claude to push what it just fetched would loop.
case "$payload" in *octopus-config-sync.sh*)
  printf '%s' "$hash" > "$STATE"; exit 0;;
esac

# No baseline yet (first sighting since hook install) -- record, don't nudge blind.
if [ -z "$last" ]; then printf '%s' "$hash" > "$STATE"; exit 0; fi

[ "$hash" != "$last" ] || exit 0
printf '%s' "$hash" > "$STATE"

printf '%s' '{"decision":"block","reason":"harness-config.json content changed. It is untracked -- git does not carry it -- so it must be pushed to the Octopus variable set or other machines never see it. Your own mid-task edit: run bash scripts/octopus-config-sync.sh push (from the harness repo; needs OCTOPUS_API_KEY + VPN) once the config edits for this task are complete. NOT your edit (you only read the file and picked up a manual/external change): push NOW, automatically, then tell the user it happened and what changed. Skip only if the user explicitly does not want this change org-wide, or the change looks unintended -- then ask."}'
