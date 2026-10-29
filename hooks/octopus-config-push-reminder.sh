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
. "$HOME/.claude/hooks/lib-claude-paths.sh"

CFG="$HOME/.claude/harness-config.json"
STATE="$(hstate harness .harness-config-synced-hash)"
# Last-SYNCED copy, so the nudge can carry the actual delta. Without it the hook could
# only claim "content changed" -- and for an edit made by ANOTHER session that's an
# instruction to push an org-wide change nobody in this session can even inspect
# (harness-gaps 2026-08-28). Copy refreshes only on the sync-script/first-sighting
# baselines below, so the diff is always "everything unpushed since the last sync".
COPY="$(hstate harness .harness-config-synced-copy.json)"

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
  printf '%s' "$hash" > "$STATE"; cp -f "$CFG" "$COPY" 2>/dev/null || true; exit 0;;
esac

# No baseline yet (first sighting since hook install) -- record, don't nudge blind.
if [ -z "$last" ]; then printf '%s' "$hash" > "$STATE"; cp -f "$CFG" "$COPY" 2>/dev/null || true; exit 0; fi

[ "$hash" != "$last" ] || exit 0
printf '%s' "$hash" > "$STATE"

# Own edit: this session's tool call changed the file. Leave a per-session marker so
# harness-config-unsynced-stop-gate.sh can BLOCK the turn ending until the push lands (the
# nudge below was read and ignored once, 2026-09-16). A Write/Edit is always own; a Bash
# call qualifies only when it names the file as a write target.
tool=""; [[ $payload =~ \"tool_name\"[[:space:]]*:[[:space:]]*\"([A-Za-z]+)\" ]] && tool="${BASH_REMATCH[1]}"
sid="";  [[ $payload =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]] && sid="${BASH_REMATCH[1]}"
own=0
case "$tool" in
  Edit|Write) own=1 ;;
  Bash|PowerShell) case "$payload" in *'>'*harness-config.json*|*harness-config.json*'>'*|*'jq '*harness-config.json*) own=1 ;; esac ;;
esac
[ "$own" = 1 ] && [ -n "$sid" ] && : > "$(hstate harness ".harness-config-edited-$sid")"

# Delta since last sync (40-line cap keeps the reason readable). No copy on record ->
# say so instead of pretending; jq fork only on this rare branch, for JSON escaping.
delta="(no last-synced copy on record -- cannot show the delta)"
if [ -f "$COPY" ]; then
  delta="$(diff -u "$COPY" "$CFG" 2>/dev/null | tail -n +3 | head -40)"
  [ -n "$delta" ] || delta="(diff empty -- whitespace/ordering only)"
fi
jq -cn --arg d "$delta" '{decision:"block", reason:("harness-config.json content changed. It is untracked -- git does not carry it -- so it must be pushed to the Octopus variable set or other machines never see it. Unpushed delta since last sync:\n" + $d + "\nYour own mid-task edit: run bash scripts/octopus-config-sync.sh push (from the harness repo; needs OCTOPUS_API_KEY + VPN) once the config edits for this task are complete. NOT your edit (manual/external/another session): review the delta above with the user before any push -- never push a change you cannot describe. Skip only if the user explicitly does not want this change org-wide, or the change looks unintended -- then ask.")}'
