#!/usr/bin/env bash
# Jira project VERSION operations over REST -- create, describe, release, show.
#
# These were documented harness-wide as "cannot be automated, do it by hand in Jira".
# That was never true of the REST API; it meant "no MCP tool for it", and hardened into
# "impossible" long after ATLASSIAN_API_TOKEN gave this harness full REST write access.
# Confirmed live 2026-08-18: create / GET / release / delete all round-trip cleanly, and
# release/129.0.0 + hotfix/129.0.2 had both sat unreleased purely because of the myth.
#
# Usage:
#   jira-version.sh list    [name-prefix]                # e.g. list "hotfix/129." to pick the next free number
#   jira-version.sh show    <name>
#   jira-version.sh create  <name> [description]
#   jira-version.sh describe <name> <description>
#   jira-version.sh release <name> <YYYY-MM-DD>     # the PRODUCTION deploy date
#   jira-version.sh next    hotfix <MAJOR> [repo-dir] # max(Jira hotfix/MAJOR.*, origin branches)+1
#   jira-version.sh next    release                   # highest release/N.0.0, N+1
#   jira-version.sh unclaimed <name>                  # exit 0 = no description AND no tickets
#
# `next` and `unclaimed` replace arithmetic the agent used to do by hand over a `sort -V`
# list plus a raw curl -- the step that once read 129.0.9 as the max while 129.0.12 existed,
# and once cut an exporterplus branch against a version reserved for another repo's fix.
# Hotfix numbers are FLEET-WIDE (one Jira list), so `next hotfix` reads Jira AND the given
# repo's remote branches and takes the larger. `next release` never reads ticket
# fixVersions -- that returns the newest version of ANY kind, usually a hotfix.
#
# Every write re-reads the version afterwards and prints that, never the write's own
# response -- a PUT echoing your payload back is not evidence it persisted.
set -u

API="https://yourorg.atlassian.net/rest/api/3"
PROJECT="PROJ"
CONFIG="$HOME/.claude/harness-config.json"
if [ -f "$CONFIG" ]; then
  EMAIL="$(jq -r '.user.email // empty' "$CONFIG" 2>/dev/null | tr -d '\r')"
  PROJECT="$(jq -r '.atlassian.jiraProjectKey // "PROJ"' "$CONFIG" 2>/dev/null | tr -d '\r')"
  HOST="$(jq -r '.atlassian.cloudId // "yourorg.atlassian.net"' "$CONFIG" 2>/dev/null | tr -d '\r')"
  API="https://$HOST/rest/api/3"
fi
: "${EMAIL:?cannot resolve user.email from harness-config.json}"
: "${ATLASSIAN_API_TOKEN:?ATLASSIAN_API_TOKEN is not set}"
AUTH="$EMAIL:$ATLASSIAN_API_TOKEN"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

version_json() {
  curl -sS -u "$AUTH" "$API/project/$PROJECT/versions" \
    | jq --arg n "$1" '[.[] | select(.name == $n)] | first // empty'
}
version_id() { version_json "$1" | jq -r '.id // empty'; }

print_version() {
  local j; j="$(version_json "$1")"
  if [ -z "$j" ]; then echo "  $1: does not exist"; return 1; fi
  printf '%s' "$j" | jq -r '"  \(.name)  id=\(.id)  released=\(.released)  releaseDate=\(.releaseDate // "(none)")  description=\((.description // "")[0:80])"'
}

cmd="${1:-}"; name="${2:-}"
[ -n "$cmd" ] && [ -n "$name" ] || { sed -n '11,16p' "$0"; exit 1; }

case "$cmd" in
  list)
    # name is optional here -- treated as a prefix filter. Sorted -V so 129.0.9 < 129.0.13.
    curl -sS -u "$AUTH" "$API/project/$PROJECT/versions" \
      | jq -r --arg p "${name:-}" '.[] | select(.name|startswith($p))
          | "\(.name)\treleased=\(.released)\tid=\(.id)\tdesc=\((.description // "(none)")[0:70])"' \
      | sort -V
    ;;

  show)
    print_version "$name"
    ;;

  create)
    if [ -n "$(version_id "$name")" ]; then
      echo "REFUSING: $name already exists -- an existing version is someone else's reservation." >&2
      print_version "$name" >&2
      exit 1
    fi
    pid="$(curl -sS -u "$AUTH" "$API/project/$PROJECT" | jq -r '.id')"
    [ -n "$pid" ] && [ "$pid" != "null" ] || { echo "could not resolve project id for $PROJECT" >&2; exit 1; }
    jq -n --arg n "$name" --arg d "${3:-}" --argjson p "$pid" \
      '{name:$n, projectId:$p, released:false} + (if $d == "" then {} else {description:$d} end)' > "$TMP/p.json"
    resp="$(curl -sS -X POST -u "$AUTH" -H "Content-Type: application/json" --data-binary "@$TMP/p.json" "$API/version")"
    printf '%s' "$resp" | jq -e '.id' >/dev/null 2>&1 || {
      echo "CREATE FAILED:" >&2; printf '%s' "$resp" | jq -r '.errorMessages // .errors // .' >&2; exit 1; }
    echo "created:"; print_version "$name"
    ;;

  describe)
    id="$(version_id "$name")"; [ -n "$id" ] || { echo "$name does not exist" >&2; exit 1; }
    jq -n --arg d "${3:?description required}" '{description:$d}' > "$TMP/p.json"
    curl -sS -X PUT -u "$AUTH" -H "Content-Type: application/json" --data-binary "@$TMP/p.json" "$API/version/$id" >/dev/null
    echo "described:"; print_version "$name"
    ;;

  release)
    id="$(version_id "$name")"; [ -n "$id" ] || { echo "$name does not exist" >&2; exit 1; }
    date="${3:?release date required (YYYY-MM-DD, the PRODUCTION deploy date)}"
    printf '%s' "$date" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' || { echo "date must be YYYY-MM-DD" >&2; exit 1; }
    jq -n --arg d "$date" '{released:true, releaseDate:$d}' > "$TMP/p.json"
    curl -sS -X PUT -u "$AUTH" -H "Content-Type: application/json" --data-binary "@$TMP/p.json" "$API/version/$id" >/dev/null
    echo "released:"; print_version "$name"
    ;;

  next)
    case "$name" in
      hotfix)
        major="${3:?usage: jira-version.sh next hotfix <MAJOR> [repo-dir]}"; repo="${4:-}"
        jmax="$(curl -sS -u "$AUTH" "$API/project/$PROJECT/versions" \
          | jq -r --arg p "hotfix/$major.0." '.[] | select(.name|startswith($p)) | .name' \
          | sed 's#.*\.##' | grep -E '^[0-9]+$' | sort -n | tail -1)"
        bmax=""
        if [ -n "$repo" ]; then
          bmax="$(git -C "$repo" ls-remote --heads origin "hotfix/$major.0.*" 2>/dev/null \
            | sed 's#.*/hotfix/[0-9]*\.0\.##' | grep -E '^[0-9]+$' | sort -n | tail -1)"
        fi
        m="${jmax:-0}"; [ "${bmax:-0}" -gt "$m" ] && m="$bmax"
        echo "hotfix/$major.0.$((m+1))"
        [ -n "$jmax" ] && echo "  (jira max: hotfix/$major.0.$jmax${bmax:+, branch max: hotfix/$major.0.$bmax})" >&2
        ;;
      release)
        rmax="$(curl -sS -u "$AUTH" "$API/project/$PROJECT/versions" \
          | jq -r '.[] | select(.name|test("^release/[0-9]+\\.0\\.0$")) | .name' \
          | sed 's#release/##; s#\.0\.0$##' | sort -n | tail -1)"
        [ -n "$rmax" ] || { echo "no release/N.0.0 versions found" >&2; exit 1; }
        echo "release/$((rmax+1)).0.0"
        echo "  (previous: release/$rmax.0.0)" >&2
        ;;
      *) echo "usage: jira-version.sh next hotfix <MAJOR> [repo-dir] | next release" >&2; exit 1 ;;
    esac
    ;;

  unclaimed)
    # A version that exists is someone's reservation UNLESS it has no description and no
    # tickets. Exit 0 = safe to take (or does not exist yet), exit 1 = belongs to another fix.
    j="$(version_json "$name")"
    if [ -z "$j" ]; then echo "UNCLAIMED: $name does not exist yet -- create it"; exit 0; fi
    desc="$(printf '%s' "$j" | jq -r '.description // ""')"
    tickets="$(bash "$(dirname "$0")/jira-search.sh" "fixVersion = \"$name\"" "key,summary" 10 2>/dev/null \
      | awk -F'\t' '$1 ~ /^[A-Z]+-[0-9]+$/ {print "    " $1 "  " substr($NF,1,60)}')"
    if [ -z "$desc" ] && [ -z "$tickets" ]; then
      echo "UNCLAIMED: $name exists with no description and no tickets"; exit 0
    fi
    echo "CLAIMED: $name belongs to another fix -- take the next number"
    [ -n "$desc" ] && echo "  description: ${desc:0:100}"
    [ -n "$tickets" ] && printf '  tickets:\n%s\n' "$tickets"
    exit 1
    ;;

  *)
    echo "unknown command: $cmd" >&2; sed -n '11,16p' "$0"; exit 1
    ;;
esac
