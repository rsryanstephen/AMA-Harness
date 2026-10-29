#!/usr/bin/env bash
# Shared: the repo-claim registry.
#
# ~/.claude/.repo-claims, TSV:  <repo-abs-path>\t<sid>\t<branch>\t<epoch>
# One row per repo -- the most recent session to act in it. Not a lock, not a lease: a
# record of who was last seen where, used only to WARN.
#
# ONE FILE, deliberately. The obvious alternative is a per-session state file next to the
# others in .session-chatfiles/, and that would be a mistake: nothing in this harness
# deletes per-session state at SessionEnd (~380 files live there now, including orphans
# from removed features), and on-prompt.sh:77-83 records that scanning that directory once
# blew the 30s hook budget. A single self-pruning file cannot grow that way.
#
# NO LOCK, also deliberately. lib-sessions-lock.sh exists but is hardcoded to sessions.txt
# and its 10s-stale / 5s-give-up semantics are tuned for a fast rewrite, not this. A lost
# update here costs exactly one missed warning; paying lock complexity -- and lock-stranding
# risk -- for that is the wrong trade. Writes are atomic (temp + mv) so a concurrent reader
# never sees a half-written file, which is the only corruption that would actually matter.
#
# Sourced, not executed. Every function fails soft: a guard built on this stays silent
# rather than misfiring.

. "$HOME/.claude/hooks/lib-claude-paths.sh"
CLAIMS_FILE="${CLAIMS_FILE:-$(hstate sessions .repo-claims)}"
CLAIMS_MAX_AGE_DAYS="${CLAIMS_MAX_AGE_DAYS:-7}"

# claims_repo_root <dir> -> absolute repo root, normalised, or empty.
# Normalising matters: the same repo arrives as C:/... from one payload and /c/... from
# another, and two spellings would read as two different repos.
claims_repo_root() {
  local d="${1:-}" root
  [ -n "$d" ] || return 0
  root="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)" || return 0
  [ -n "$root" ] || return 0
  printf '%s' "$root" | tr '\134' '/' | tr '[:upper:]' '[:lower:]'
}

# claims_get <repo-root> -> "sid<TAB>branch<TAB>epoch" for that repo, or empty
claims_get() {
  local root="${1:-}"
  [ -n "$root" ] && [ -f "$CLAIMS_FILE" ] || return 0
  awk -F'\t' -v r="$root" '$1 == r { print $2 "\t" $3 "\t" $4; exit }' "$CLAIMS_FILE" 2>/dev/null
}

# claims_put <repo-root> <sid> <branch> -- upsert, prune, atomic replace
claims_put() {
  local root="${1:-}" sid="${2:-}" branch="${3:-}" now cutoff tmp
  [ -n "$root" ] && [ -n "$sid" ] || return 0
  now="$(date +%s)"
  cutoff=$(( now - CLAIMS_MAX_AGE_DAYS * 86400 ))
  tmp="$(mktemp "${CLAIMS_FILE}.XXXXXX" 2>/dev/null)" || return 0

  # Keep other repos' rows that are still recent, drop this repo's old row and anything
  # past the cutoff -- pruning on write is what keeps this file from becoming another
  # pile nothing ever cleans.
  if [ -f "$CLAIMS_FILE" ]; then
    awk -F'\t' -v r="$root" -v c="$cutoff" \
      '$1 != r && $4 ~ /^[0-9]+$/ && $4 >= c' "$CLAIMS_FILE" >> "$tmp" 2>/dev/null
  fi
  printf '%s\t%s\t%s\t%s\n' "$root" "$sid" "$branch" "$now" >> "$tmp"
  mv -f "$tmp" "$CLAIMS_FILE" 2>/dev/null || rm -f "$tmp" 2>/dev/null
}

# claims_describe_age <epoch> -> "3m" / "2h" / "4d", for a human-readable warning
claims_describe_age() {
  local then="${1:-0}" now age
  case "$then" in ''|*[!0-9]*) echo "unknown"; return ;; esac
  now="$(date +%s)"; age=$(( now - then ))
  if   [ "$age" -lt 60 ];    then echo "${age}s"
  elif [ "$age" -lt 3600 ];  then echo "$(( age / 60 ))m"
  elif [ "$age" -lt 86400 ]; then echo "$(( age / 3600 ))h"
  else echo "$(( age / 86400 ))d"
  fi
}
