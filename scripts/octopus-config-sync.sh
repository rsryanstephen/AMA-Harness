#!/usr/bin/env bash
# octopus-config-sync.sh -- sync harness-config.json with the org's "Claude Harness"
# Octopus library variable set, as ONE VARIABLE PER SCALAR VALUE.
#
# It used to store the whole config as a single JSON blob (`HarnessConfigJson`). That made
# every value invisible and un-editable in the Octopus UI and unscopeable. The set now holds
# `HarnessConfig:<colon-separated path>` variables, each a plain string or number, e.g.
#   HarnessConfig:atlassian:cloudId
#   HarnessConfig:releaseNotes:emailRecipients:3
#   HarnessConfig:releaseNotes:greetingNames:<one entry per line; this element only declares the type>
#   HarnessConfig:audiences:people:5:notes
# Colon, not dot: greetingNames is keyed BY EMAIL and those keys contain dots. Colons were
# verified empirically to survive an Octopus PUT/GET verbatim before the scheme was built.
#
# THE TRACKED EXAMPLE IS THE SCHEMA. harness-config.example.json says which leaves are numbers,
# which nodes are arrays, and what an array element looks like, so Octopus carries values only
# and no type information is smuggled into names. Consequences, both deliberate:
#   * push REFUSES when a live key has no counterpart in the example -- such a value could
#     never be placed by a fetch, so it would vanish silently on the next machine. Add the key
#     to the example (with a placeholder) first.
#   * an example array must carry ONE element, even when empty in practice, or its element type
#     is unknowable. Placeholder elements never reach a rebuilt config.
#   * fetch normalises key order to the example's, so the first fetch after this change may
#     reorder the local file without changing a single value.
#
# The config file is UNTRACKED in git; this variable set is the cross-machine source of truth.
# Fetch/push are setup-time operations only -- nothing in the harness fetches at runtime
# (hooks/skills keep reading the local file). VPN required to reach Octopus.
#
# Variables must stay NON-sensitive-typed: Sensitive is write-only via the API (returned
# masked), so a fetch would get nothing back.
#
# The `user` block (email, displayName, windowsUsername, jiraAccountId) is per-person: push
# strips it, fetch preserves the local one -- the org store never carries anyone's identity.
#
# ANY VARIABLE NOT PREFIXED `HarnessConfig:` IS PRESERVED UNTOUCHED. The same set holds
# `AmaUiTestUserPassword`, added through the UI so the plaintext never transited a tool call;
# rebuilding the Variables array from the config alone would silently delete it.
#
# Usage:
#   bash scripts/octopus-config-sync.sh fetch  [--server <url>] [--space <Spaces-N>]
#   bash scripts/octopus-config-sync.sh push   [--server <url>] [--space <Spaces-N>]
#   bash scripts/octopus-config-sync.sh verify [--server <url>] [--space <Spaces-N>]
#   bash scripts/octopus-config-sync.sh push --drop-legacy-blob
# verify = fetch into a temp file and diff against local; changes nothing. Run it after a push.
# --drop-legacy-blob additionally removes the old HarnessConfigJson variable; only do that once
# verify is clean, since it is the fallback until then.
# --server/--space are the fresh-machine bootstrap (local config still placeholder); otherwise
# both resolve from the local config's octopus.serverUrl/spaceId.
set -euo pipefail

SET_NAME="Claude Harness"
PREFIX="HarnessConfig"
LEGACY_VAR="HarnessConfigJson"
CFG="$HOME/.claude/harness-config.json"   # symlink into the repo; always write THROUGH
                                          # it (cat > "$CFG"), never mv onto it -- mv
                                          # would replace the symlink with a plain file.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLE="$HERE/../harness-config.example.json"
VARS_PY="$HERE/harness-config-vars.py"

MODE="${1:-}"; shift || true
SERVER=""; SPACE=""; DROP_BLOB=0
while [ $# -gt 0 ]; do
  case "$1" in
    --server) SERVER="$2"; shift 2;;
    --space)  SPACE="$2";  shift 2;;
    --drop-legacy-blob) DROP_BLOB=1; shift;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
case "$MODE" in fetch|push|verify) ;; *) echo "usage: octopus-config-sync.sh fetch|push|verify [--server <url>] [--space <Spaces-N>] [--drop-legacy-blob]" >&2; exit 2;; esac

if [ -z "${OCTOPUS_API_KEY:-}" ]; then
  echo "OCTOPUS_API_KEY not set." >&2
  exit 1
fi
[ -f "$EXAMPLE" ] || { echo "Schema missing: $EXAMPLE (the example config IS the schema)." >&2; exit 1; }
[ -f "$VARS_PY" ] || { echo "Helper missing: $VARS_PY" >&2; exit 1; }

_jqr() { jq -r "$1" "$2" 2>/dev/null | sed 's/\r$//'; }

if [ -f "$CFG" ]; then
  [ -n "$SERVER" ] || SERVER="$(_jqr '.octopus.serverUrl // empty' "$CFG")"
  [ -n "$SPACE"  ] || SPACE="$(_jqr '.octopus.spaceId // empty'   "$CFG")"
fi
case "$SERVER" in ''|*yourorg*) echo "Octopus server unknown -- pass --server <url> (local config missing/placeholder)." >&2; exit 1;; esac
[ -n "$SPACE" ] || { echo "Octopus space unknown -- pass --space <Spaces-N>." >&2; exit 1; }

ocurl() { curl -sS -H "X-Octopus-ApiKey: $OCTOPUS_API_KEY" "$@"; }

# Resolve the variable set by NAME (never a hardcoded LibraryVariableSets-NNN id).
sets_json="$(ocurl "$SERVER/api/$SPACE/libraryvariablesets?contentType=Variables&partialName=$(printf '%s' "$SET_NAME" | sed 's/ /%20/g')")"
varset_id="$(printf '%s' "$sets_json" | jq -r --arg n "$SET_NAME" '.Items[] | select(.Name == $n) | .VariableSetId' | head -1)"
if [ -z "$varset_id" ] || [ "$varset_id" = "null" ]; then
  echo "Library variable set \"$SET_NAME\" not found in $SPACE on $SERVER (VPN? name? permissions?)." >&2
  exit 1
fi
vars_url="$SERVER/api/$SPACE/variables/$varset_id"

# Payloads travel via temp FILES only -- non-ASCII mangles through argv and through a
# non-UTF-8 stdout on Windows (both confirmed live: an em-dash in a `notes` value became a
# byte the next parse rejected).
tmpd="$(mktemp -d)"; trap 'rm -rf "$tmpd"' EXIT
ocurl "$vars_url" > "$tmpd/vars.json"

# rebuild_config <vars-doc> <out> -- Octopus variables -> a config file (no user block)
rebuild_config() {
  local n
  n="$(jq -r --arg p "$PREFIX:" '[.Variables[] | select(.Name | startswith($p))] | length' "$1")"
  if [ "${n:-0}" -eq 0 ]; then
    echo "No $PREFIX:* variables in \"$SET_NAME\"." >&2
    if [ "$(jq -r --arg n "$LEGACY_VAR" '[.Variables[] | select(.Name == $n)] | length' "$1")" != "0" ]; then
      echo "The set still holds the legacy $LEGACY_VAR blob -- it has not been migrated to" >&2
      echo "per-value variables yet. Run 'push' from a machine with a good local config." >&2
    fi
    return 1
  fi
  python "$VARS_PY" unflatten "$1" "$EXAMPLE" > "$2"
  echo "  ($n variables read)" >&2
}

if [ "$MODE" = "fetch" ] || [ "$MODE" = "verify" ]; then
  rebuild_config "$tmpd/vars.json" "$tmpd/org.json"
  jq -e . "$tmpd/org.json" > /dev/null || { echo "Rebuilt config is not valid JSON -- refusing to write." >&2; exit 1; }

  if [ -f "$CFG" ] && [ "$(_jqr '.user.email // empty' "$CFG")" != "" ] && [ "$(_jqr '.user.email' "$CFG")" != "you@example.com" ]; then
    # keep this machine's identity: the org store wins everywhere EXCEPT .user
    jq -n --argfile org "$tmpd/org.json" --argfile local "$CFG" '{user: $local.user} + $org' > "$tmpd/merged.json"
  else
    jq . "$tmpd/org.json" > "$tmpd/merged.json"
  fi

  if [ "$MODE" = "verify" ]; then
    if [ ! -f "$CFG" ]; then echo "No local config to compare against." >&2; exit 1; fi
    jq -S . "$CFG" > "$tmpd/a.json"; jq -S . "$tmpd/merged.json" > "$tmpd/b.json"
    if diff -u "$tmpd/a.json" "$tmpd/b.json" > "$tmpd/d.txt"; then
      echo "verify: the variable set round-trips to the local config exactly."
    else
      echo "verify: DIFFERS -- what the org store would give this machine vs the local file:"
      cat "$tmpd/d.txt"
      exit 1
    fi
  else
    cat "$tmpd/merged.json" > "$CFG"   # write through the symlink, never mv onto it
    echo "Fetched \"$SET_NAME\" -> $CFG (local user block preserved). Run /harness-setup if the user block is still placeholder."
  fi
else
  [ -f "$CFG" ] || { echo "No local config at $CFG -- nothing to push." >&2; exit 1; }
  jq -e . "$CFG" > /dev/null || { echo "Local config is not valid JSON -- refusing to push." >&2; exit 1; }

  # Refuses (exit 3) when a live key has no counterpart in the example -- see the header.
  python "$VARS_PY" flatten "$CFG" "$EXAMPLE" > "$tmpd/new.json"

  # Summary: which leaves actually change. Computed against the set as it is NOW, so a no-op
  # push says so instead of claiming a change.
  jq -n --argfile old "$tmpd/vars.json" --argfile new "$tmpd/new.json" --arg p "$PREFIX:" '
      ([$old.Variables[] | select(.Name | startswith($p)) | {key: .Name, value: (.Value // "")}] | from_entries) as $o
    | ([$new[] | {key: .Name, value: .Value}] | from_entries) as $n
    | { added:   [$n | keys[] | select($o[.] == null)],
        removed: [$o | keys[] | select($n[.] == null)],
        changed: [$n | keys[] | select($o[.] != null and $o[.] != $n[.])] }' > "$tmpd/delta.json"

  # PRESERVE every variable this scheme does not own -- AmaUiTestUserPassword lives here.
  jq --argfile new "$tmpd/new.json" --arg p "$PREFIX:" '
      .Variables = ([.Variables[] | select((.Name | startswith($p)) | not)]
                    + [$new[] | {Name: .Name, Value: .Value, Type: "String",
                                 IsSensitive: false, IsEditable: true, Scope: {}}])' \
    "$tmpd/vars.json" > "$tmpd/updated.json"

  if [ "$DROP_BLOB" = "1" ]; then
    jq --arg n "$LEGACY_VAR" '.Variables |= map(select(.Name != $n))' "$tmpd/updated.json" > "$tmpd/u2.json"
    mv "$tmpd/u2.json" "$tmpd/updated.json"
  fi

  ocurl -X PUT -H "Content-Type: application/json; charset=utf-8" -d "@$tmpd/updated.json" "$vars_url" \
    | jq -r '"Pushed. Variable set version now " + (.Version|tostring)'
  jq -r '"  added: \(.added|length), changed: \(.changed|length), removed: \(.removed|length)"
         + (if (.changed|length) > 0 then "\n  changed: " + (.changed | join(", ")) else "" end)
         + (if (.added|length)   > 0 then "\n  added:   " + (.added   | join(", ")) else "" end)
         + (if (.removed|length) > 0 then "\n  removed: " + (.removed | join(", ")) else "" end)' "$tmpd/delta.json"
  echo "  (user block never pushed; variables outside $PREFIX:* left untouched)"

  if [ "$DROP_BLOB" = "1" ]; then
    echo "  legacy $LEGACY_VAR removed."
  elif [ "$(jq -r --arg n "$LEGACY_VAR" '[.Variables[] | select(.Name == $n)] | length' "$tmpd/vars.json")" != "0" ]; then
    echo "  NOTE: the legacy $LEGACY_VAR blob is still in the set and is now STALE."
    echo "  Run 'octopus-config-sync.sh verify' first, then 'push --drop-legacy-blob' to remove it."
  fi
fi
