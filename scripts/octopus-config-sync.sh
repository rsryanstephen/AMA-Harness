#!/usr/bin/env bash
# octopus-config-sync.sh -- sync harness-config.json with the org's "Claude Harness"
# Octopus library variable set (single JSON-blob variable: HarnessConfigJson).
#
# The config file is UNTRACKED in git; this variable set is the cross-machine source of
# truth. Fetch/push are setup-time operations only -- nothing in the harness fetches at
# runtime (hooks/skills keep reading the local file). VPN required to reach Octopus.
#
# The variable must stay NON-sensitive-typed in Octopus: Sensitive variables are
# write-only via the API (returned masked), so a fetch would get nothing.
#
# The `user` block (email, displayName, windowsUsername, jiraAccountId) is per-person:
# push strips it, fetch preserves the local one -- the org store never carries or
# overwrites anyone's identity.
#
# Usage:
#   bash scripts/octopus-config-sync.sh fetch [--server <url>] [--space <Spaces-N>]
#   bash scripts/octopus-config-sync.sh push  [--server <url>] [--space <Spaces-N>]
# --server/--space are the fresh-machine bootstrap (local config still placeholder);
# otherwise both resolve from the local config's octopus.serverUrl/spaceId.
set -euo pipefail

SET_NAME="Claude Harness"
VAR_NAME="HarnessConfigJson"
CFG="$HOME/.claude/harness-config.json"   # symlink into the repo; always write THROUGH
                                          # it (cat > "$CFG"), never mv onto it -- mv
                                          # would replace the symlink with a plain file.

MODE="${1:-}"; shift || true
SERVER=""; SPACE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --server) SERVER="$2"; shift 2;;
    --space)  SPACE="$2";  shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
case "$MODE" in fetch|push) ;; *) echo "usage: octopus-config-sync.sh fetch|push [--server <url>] [--space <Spaces-N>]" >&2; exit 2;; esac

if [ -z "${OCTOPUS_API_KEY:-}" ]; then
  echo "OCTOPUS_API_KEY not set." >&2
  exit 1
fi

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
vars_json="$(ocurl "$vars_url")"

if [ "$MODE" = "fetch" ]; then
  # Payloads travel via temp FILES only -- non-ASCII mangles to U+FFFD through jq argv
  # on Windows (--argjson "$blob"), confirmed live on the push side.
  tmpd="$(mktemp -d)"; trap 'rm -rf "$tmpd"' EXIT
  printf '%s' "$vars_json" | jq -r --arg n "$VAR_NAME" '[.Variables[] | select(.Name == $n)][0].Value // empty' > "$tmpd/blob.json"
  if [ ! -s "$tmpd/blob.json" ]; then
    echo "Variable $VAR_NAME not found (or empty) in \"$SET_NAME\". If it is Sensitive-typed, the API returns it masked -- it must be a plain text variable." >&2
    exit 1
  fi
  jq -e . "$tmpd/blob.json" > /dev/null || { echo "Fetched $VAR_NAME is not valid JSON -- refusing to write." >&2; exit 1; }
  if [ -f "$CFG" ] && [ "$(_jqr '.user.email // empty' "$CFG")" != "" ] && [ "$(_jqr '.user.email' "$CFG")" != "you@example.com" ]; then
    # keep this machine's identity: org blob wins everywhere EXCEPT .user
    jq --argfile org "$tmpd/blob.json" -n --argfile local "$CFG" '$org + {user: $local.user}' > "$tmpd/merged.json"
  else
    jq . "$tmpd/blob.json" > "$tmpd/merged.json"
  fi
  cat "$tmpd/merged.json" > "$CFG"   # write through the symlink, never mv onto it
  echo "Fetched \"$SET_NAME\" -> $CFG (local user block preserved). Run /harness-setup if the user block is still placeholder."
else
  [ -f "$CFG" ] || { echo "No local config at $CFG -- nothing to push." >&2; exit 1; }
  jq -e . "$CFG" > /dev/null || { echo "Local config is not valid JSON -- refusing to push." >&2; exit 1; }
  # Non-ASCII (em-dashes etc) gets mangled to U+FFFD when passed through jq argv on
  # Windows (--arg v "$blob") -- confirmed live. Payloads travel via temp FILES only.
  tmpd="$(mktemp -d)"; trap 'rm -rf "$tmpd"' EXIT
  jq 'del(.user)' "$CFG" > "$tmpd/blob.json"
  printf '%s' "$vars_json" > "$tmpd/vars.json"
  # summary: top-level keys that differ from what the set currently holds
  jq -r --arg n "$VAR_NAME" '[.Variables[] | select(.Name == $n)][0].Value // "{}"' "$tmpd/vars.json" > "$tmpd/old.json"
  changed="$(jq -rn --argfile a "$tmpd/old.json" --argfile b "$tmpd/blob.json" '(($a | keys) + ($b | keys)) | unique | map(select($a[.] != $b[.])) | join(", ")' 2>/dev/null || echo "?")"
  jq --arg n "$VAR_NAME" --argfile v "$tmpd/blob.json" '
    ($v | tojson) as $vs
    | if ([.Variables[] | select(.Name == $n)] | length) > 0
      then .Variables |= map(if .Name == $n then .Value = $vs else . end)
      else .Variables += [{Name: $n, Value: $vs, Type: "String", IsSensitive: false, IsEditable: true, Scope: {}}]
      end' "$tmpd/vars.json" > "$tmpd/updated.json"
  ocurl -X PUT -H "Content-Type: application/json; charset=utf-8" -d "@$tmpd/updated.json" "$vars_url" | jq -r '"Pushed. Variable set version now " + (.Version|tostring)'
  echo "Changed top-level keys: ${changed:-none} (user block never pushed)."
fi
