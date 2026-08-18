#!/usr/bin/env bash
# Resolves a repo name/slug to its actual local checkout path -- PROJ-15143.
# Local folder names are NOT trustworthy: Your Name's are shortened ("admin", not
# "product-service-admin"), and the stripping isn't even one rule (also
# "<repository>-api-testing" -> "api-testing", "yourproduct-cacheupdate-infrastructure"
# -> "cacheupdate-infrastructure"). A fresh adopter is equally likely to clone with the
# real Bitbucket slugs, full stop. The repo's own `git remote get-url origin` is the
# only identity that's always correct -- same idiom already proven in
# check-build-counter-reset.sh:40-41, absorbed here rather than reinvented.
#
# State lives in ~/.claude/.harness-local.json -- per-machine, gitignored, never
# committed (see .gitignore in both this repo and the standalone harness repo). Holds
# the configured search root(s) AND the discovered slug->path index as PERSISTED state,
# not a TTL cache: discovery runs once, and is re-run only on a lookup miss (rescan,
# retry once) or an explicit hr_refresh -- per explicit user instruction ("discover once,
# never repeat").
#
# HR_ROOTS_OVERRIDE (test seam) is ephemeral by design -- it NEVER touches
# .harness-local.json. Every call re-discovers in memory instead of caching, so a test
# run can never corrupt the real machine's persisted index.
#
# Sourceable (`. lib-harness-repos.sh`) and directly executable
# (`bash lib-harness-repos.sh <fn> [args]`) so PowerShell/node callers can shell out.

set -u

HR_LOCAL_FILE="$HOME/.claude/.harness-local.json"
HR_CONFIG_FILE="$HOME/.claude/harness-config.json"

hr_expand() {
  local v="$1"
  v="${v/#\~/$HOME}"
  printf '%s' "$v"
}

# Confirmed real: this environment's jq build (jq-1.5rc1, Windows/git-bash) emits
# CRLF on `-r` output -- same bug class fixed earlier in
# jira-fixversion-confirm-gate.sh. Every jq -r read in this file goes through here so
# it's fixed once, not per call site.
#
# File reads redirect via stdin (`_jqr '...' < file`), never a path argument --
# under `export MSYS_NO_PATHCONV=1` (which
# ama-cloudwatch-search legitimately needs), git-bash stops converting the
# `/c/...`-form path for native jq.exe, which then can't open it, and hr_config*
# silently reported keys as unconfigured. Stdin is opened by the shell itself, immune.
_jqr() {
  jq -r "$@" 2>/dev/null | sed 's/\r$//'
}

# jq-path read with a default, from harness-config.json. Not the 8+ pre-existing
# call sites' idiom -- new, used only by files this PROJ-15143 pass touches.
hr_config() {
  local path="$1" default="${2:-}"
  [ -f "$HR_CONFIG_FILE" ] || { printf '%s' "$default"; return; }
  local v
  v="$(_jqr "$path // empty" < "$HR_CONFIG_FILE")"
  [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$default"
}

# Sibling to hr_config, NOT a replacement -- hr_config's "return $default, never error"
# contract is relied on by existing call sites, don't change it. For reads that decide
# WHICH COMPANY'S infrastructure gets hit (Bitbucket org, AWS region, Graylog host) a
# silent default is the actual bug (Wave 2 audit: several scripts fell back to
# YourCompany's own instance on a missing/typo'd key, no error, wrong org silently).
# No default param -- empty value OR missing file OR missing key all fail the same way.
hr_config_required() {
  local path="$1" v
  if [ ! -f "$HR_CONFIG_FILE" ]; then
    printf '%s not configured -- run /harness-setup\n' "$path" >&2
    return 1
  fi
  v="$(_jqr "$path // empty" < "$HR_CONFIG_FILE")"
  if [ -z "$v" ]; then
    printf '%s not configured -- run /harness-setup\n' "$path" >&2
    return 1
  fi
  printf '%s' "$v"
}

# One repo's Bitbucket slug from its origin remote. Falls back to the folder's own
# name if no org match / no remote at all, so non-Bitbucket or remote-less repos still
# index under something.
hr_slug_from_remote() {
  local dir="$1" bb_org="$2"
  local url slug
  url="$(git -C "$dir" remote get-url origin 2>/dev/null)"
  [ -n "$url" ] || { basename "$dir"; return; }
  slug="$(printf '%s' "$url" | grep -oP "(?<=${bb_org}/)[^/.]+(?=(\.git)?\$)" 2>/dev/null)"
  [ -n "$slug" ] && printf '%s' "$slug" || basename "$dir"
}

# Internal: every configured root as path<TAB>fleet, UNFILTERED (fleet filtering is
# hr_roots'/hr_index's job, not this). Same precedence everywhere in this file:
# HR_ROOTS_OVERRIDE (test seam, fleet always empty) -> .harness-local.json reposRoots
# -> legacy harness-config.json paths.reposRoot -> derived from the harness's own
# clone location -> nothing.
_hr_root_pairs() {
  if [ -n "${HR_ROOTS_OVERRIDE:-}" ]; then
    while IFS= read -r r; do
      [ -n "$r" ] && printf '%s\t\n' "$r"
    done <<< "$HR_ROOTS_OVERRIDE"
    return 0
  fi

  if [ -f "$HR_LOCAL_FILE" ]; then
    local rows
    rows="$(_jqr '
      .reposRoots // [] | .[] |
      if type == "string" then {path: ., fleet: null} else . end |
      [.path, (.fleet // "")] | @tsv
    ' < "$HR_LOCAL_FILE")"
    if [ -n "$rows" ]; then
      printf '%s\n' "$rows"
      return 0
    fi
  fi

  # Legacy fallback -- paths.reposRoot in harness-config.json predates this schema and
  # was never actually read by anything until now.
  local legacy
  legacy="$(hr_config '.paths.reposRoot' '')"
  if [ -n "$legacy" ]; then
    printf '%s\t\n' "$legacy"
    return 0
  fi

  # Derived: the harness's own clone location implies where sibling repos live, same
  # trick on-stop.sh:254 already uses to find the harness itself. Guard: only trust it
  # if the parent actually holds other git repos (>=2 siblings with a .git) -- a
  # standalone harness clone (e.g. ~/.claude-harness) must not yield $HOME as a "root".
  local harness parent count
  harness="$(git -C "$HOME/.claude/skills" rev-parse --show-toplevel 2>/dev/null)"
  if [ -n "$harness" ]; then
    parent="$(dirname "$harness")"
    count=0
    for d in "$parent"/*/; do
      [ -e "${d}.git" ] && count=$((count + 1))
      [ "$count" -ge 2 ] && break
    done
    if [ "$count" -ge 2 ]; then
      printf '%s\t\n' "$parent"
      return 0
    fi
  fi

  echo "hr_roots: no repos roots resolved -- set reposRoots in ~/.claude/.harness-local.json (see /harness-setup)" >&2
  return 0
}

# Root list, one absolute existence-checked path per line, optionally filtered by
# fleet label. Wraps _hr_root_pairs with fleet-filtering, ~-expansion, and dedup.
hr_roots() {
  local fleet="${1:-}"
  local seen=""
  local pairs
  pairs="$(_hr_root_pairs)"
  [ -n "$pairs" ] || return 0

  while IFS=$'\t' read -r p f; do
    [ -n "${p:-}" ] || continue
    [ -z "$fleet" ] || [ -z "${f:-}" ] || [ "$f" = "$fleet" ] || continue
    p="$(hr_expand "$p")"
    [ -d "$p" ] || continue
    case "$seen" in *"|$p|"*) continue ;; esac
    seen="${seen}|$p|"
    printf '%s\n' "$p"
  done <<< "$pairs"
}

# Internal: discover repos across a given path<TAB>fleet pair list (as produced by
# _hr_root_pairs), depth 1. Prints slug<TAB>folder<TAB>abspath<TAB>fleet rows.
_hr_discover() {
  local pairs="$1"
  local bb_org
  bb_org="$(hr_config '.bitbucket.org' 'yourorg')"

  while IFS=$'\t' read -r root_raw fleet; do
    [ -n "${root_raw:-}" ] || continue
    local root
    root="$(hr_expand "$root_raw")"
    [ -d "$root" ] || continue
    for dir in "$root"/*/; do
      [ -e "${dir}.git" ] || continue
      local top
      top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)"
      [ -n "$top" ] || continue
      local folder slug
      folder="$(basename "$dir")"
      slug="$(hr_slug_from_remote "$dir" "$bb_org")"
      printf '%s\t%s\t%s\t%s\n' "$slug" "$folder" "$top" "${fleet:-}"
    done
  done <<< "$pairs"
}

# slug<TAB>folder<TAB>abspath per repo, optionally filtered by fleet.
#
# Under HR_ROOTS_OVERRIDE, this NEVER touches .harness-local.json -- it re-discovers
# fresh every call. That's deliberate: a test run must not read or write the real
# machine's persisted index. Otherwise: persisted state, rebuilt only on first use or
# an explicit hr_refresh.
hr_index() {
  local fleet="${1:-}"

  if [ -n "${HR_ROOTS_OVERRIDE:-}" ]; then
    _hr_discover "$(_hr_root_pairs)" | awk -F'\t' -v f="$fleet" \
      'f == "" || $4 == "" || $4 == f { print }'
    return 0
  fi

  [ -f "$HR_LOCAL_FILE" ] || hr_refresh
  local have
  have="$(_jqr '.repoIndex // [] | length' < "$HR_LOCAL_FILE")"
  [ "${have:-0}" -gt 0 ] || hr_refresh
  _jqr --arg f "$fleet" '
    .repoIndex // [] | .[] |
    select(($f == "") or (.fleet == null) or (.fleet == $f)) |
    [.slug, .folder, .path, .fleet] | @tsv
  ' < "$HR_LOCAL_FILE"
}

# Force rediscovery and rewrite repoIndex in .harness-local.json.
#
# No-op under HR_ROOTS_OVERRIDE -- hr_index already discovers fresh every call in that
# mode, and persisting fixture data into the real machine's state file would corrupt
# it for every subsequent real (non-override) invocation.
hr_refresh() {
  if [ -n "${HR_ROOTS_OVERRIDE:-}" ]; then
    echo "hr_refresh: HR_ROOTS_OVERRIDE active, nothing to persist (ephemeral by design)" >&2
    return 0
  fi

  [ -f "$HR_LOCAL_FILE" ] || printf '{"reposRoots":[],"repoIndex":[]}\n' > "$HR_LOCAL_FILE"

  local rows
  rows="$(_hr_discover "$(_hr_root_pairs)")"

  local idx_json
  idx_json="$(printf '%s' "$rows" | jq -R -s -c '
    split("\n") | map(select(length > 0)) | map(split("\t")) |
    map({slug: .[0], folder: .[1], path: .[2], fleet: (if .[3] == "" then null else .[3] end)})
  ' 2>/dev/null)"

  # --slurpfile isn't supported by this environment's jq (1.5rc1) -- pass the built
  # index as a JSON value via --argjson instead.
  jq --argjson idx "${idx_json:-[]}" '.repoIndex = $idx' < "$HR_LOCAL_FILE" > "${HR_LOCAL_FILE}.tmp" \
    && mv "${HR_LOCAL_FILE}.tmp" "$HR_LOCAL_FILE"
}

# Absolute path for a repo by slug or folder name, optionally fleet-scoped.
# Exit 1: not found. Exit 2: ambiguous (candidates printed to stderr).
hr_repo_path() {
  local name="$1" fleet="${2:-}"
  local needle
  needle="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"

  local idx
  idx="$(hr_index "$fleet")"

  _match_tier() {
    local awk_prog="$1"
    printf '%s\n' "$idx" | awk -F'\t' -v n="$needle" "$awk_prog"
  }

  local hits
  # Tier 1: exact slug. Tier 2: exact folder.
  hits="$(_match_tier '{ s=tolower($1); f=tolower($2); if (s==n || f==n) print $3 }' | sort -u)"
  if [ -z "$hits" ]; then
    # Tier 3: slug == needle or ends with "-needle". Tier 4: folder suffix, same rule.
    hits="$(_match_tier '{
      s=tolower($1); f=tolower($2);
      if (s==n || s ~ ("-" n "$") || f==n || f ~ ("-" n "$")) print $3
    }' | sort -u)"
  fi

  local n_hits
  n_hits="$(printf '%s\n' "$hits" | grep -c . || true)"
  if [ "$n_hits" -eq 0 ]; then
    # One rescan-then-retry on a miss, per persisted-state (not TTL) design. Under
    # override this is a harmless extra discovery pass (never persists anyway).
    hr_refresh
    idx="$(hr_index "$fleet")"
    hits="$(_match_tier '{ s=tolower($1); f=tolower($2); if (s==n || f==n) print $3 }' | sort -u)"
    [ -z "$hits" ] && hits="$(_match_tier '{
      s=tolower($1); f=tolower($2);
      if (s==n || s ~ ("-" n "$") || f==n || f ~ ("-" n "$")) print $3
    }' | sort -u)"
    n_hits="$(printf '%s\n' "$hits" | grep -c . || true)"
  fi

  if [ "$n_hits" -eq 0 ]; then
    echo "hr_repo_path: '$name' not found under configured roots" >&2
    return 1
  elif [ "$n_hits" -gt 1 ]; then
    echo "hr_repo_path: '$name' is ambiguous, candidates:" >&2
    printf '%s\n' "$hits" >&2
    return 2
  fi
  printf '%s\n' "$hits"
}

# Canonical slug for a local directory (reverse lookup).
hr_repo_slug() {
  local dir="$1"
  local top
  top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)"
  [ -n "$top" ] || { echo "hr_repo_slug: '$dir' is not a git repo" >&2; return 1; }
  local bb_org
  bb_org="$(hr_config '.bitbucket.org' 'yourorg')"
  hr_slug_from_remote "$top" "$bb_org"
}

# Direct-execution dispatch: `bash lib-harness-repos.sh <fn> [args...]`.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fn="${1:-}"; shift || true
  case "$fn" in
    roots) hr_roots "$@" ;;
    index) hr_index "$@" ;;
    path) hr_repo_path "$@" ;;
    slug) hr_repo_slug "$@" ;;
    refresh) hr_refresh "$@" ;;
    *) echo "usage: lib-harness-repos.sh {roots|index|path|slug|refresh} [args]" >&2; exit 1 ;;
  esac
fi
