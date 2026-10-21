#!/usr/bin/env bash
# Shared: the FILE-claim ledger. Sibling of lib-repo-claims.sh, one level finer.
#
# ~/.claude/harness-state/sessions/.file-claims, TSV:  <norm-path>\t<sid>\t<epoch>
# One row per (path, sid) -- when each session last edited each file. Not a lock, not a
# lease: a record used only to WARN, exactly like the repo claims.
#
# Why it exists (PROJ-15368). cross-session-repo-claim.sh sees BRANCHES; two sessions
# editing the same file on the same branch triggered nothing. A 7-day transcript scan found
# 153 same-file/different-session pairs inside 6h windows, 58 distinct files, all but one of
# them in this harness repo. Most were harmless -- but twice on 2026-09-01 one session's
# uncommitted work was swept into another session's commit under an unrelated message, and
# the recovery from the second left the shared index holding a staged DELETION of freshly
# committed content that the next commit would have shipped.
#
# So the WARNING IS AT COMMIT TIME, not edit time. Recording an edit is silent; the only
# thing anyone gets told is "you are about to commit a file another live session is in".
# That is where the harm actually happened, and it keeps the noisy 153 from becoming 153
# interruptions.
#
# ONE FILE, self-pruning, no lock -- all three for the reasons lib-repo-claims.sh's header
# spells out (nothing in this harness deletes per-session state; a lost update costs exactly
# one missed warning; atomic temp+mv is the only corruption that would matter). Ages out
# faster and carries a ROW CAP as well, because files churn far faster than repos do.
#
# ZERO SUBPROCESSES in fclaims_put, deliberately. This runs on the Edit|Write path, where a
# baseline measurement (2026-09-01, solo) put the whole 9-gate stack at 2.53s and its
# cheapest prefilter-and-exit gate at ~130ms -- i.e. bash startup dominates and every extra
# fork is visible. So: `printf '%(%s)T'` not `date`, a `$$`-suffixed temp not `mktemp`, and
# the prune/cap done in bash rather than piped through awk|sort|head. Keep it that way.
#
# Sourced, not executed. Every function fails soft: a guard built on this stays silent
# rather than misfiring.

# Path built inline rather than through `hstate sessions .file-claims`, which is the usual
# convention -- hstate forks `dirname` and the command substitution around it forks again,
# and this file is read on the Edit path where that is a measurable share of the cost. The
# two things hstate adds are not needed here: the parent is created below with a builtin
# test first, and there is no legacy top-level ~/.claude/.file-claims to absorb (this ledger
# is new as of PROJ-15368 and never lived anywhere else). CLAUDE_STATE_DIR is still
# honoured, so the check-gates seam works unchanged.
CLAUDE_STATE_DIR="${CLAUDE_STATE_DIR:-$HOME/.claude/harness-state}"
FCLAIMS_FILE="${FCLAIMS_FILE:-$CLAUDE_STATE_DIR/sessions/.file-claims}"
FCLAIMS_MAX_AGE_SECS="${FCLAIMS_MAX_AGE_SECS:-86400}"
FCLAIMS_MAX_ROWS="${FCLAIMS_MAX_ROWS:-500}"

# fclaims_norm <path> -> comparable spelling, or empty.
# The same file arrives as C:\..., C:/..., /c/... and with mixed case from different tools
# and payloads; four spellings would read as four different files. A JSON payload also
# carries Windows separators DOUBLED (`C:\\Users`), so collapse repeats after converting.
# No `git rev-parse` here (unlike claims_repo_root) -- that would be a fork per edit.
# Sets FCLAIMS_KEY rather than printing: `key="$(fclaims_norm ...)"` would fork a subshell
# on every edit, which is exactly what this file's header says not to do.
fclaims_norm() {
  FCLAIMS_KEY=""
  local p="${1:-}"
  [ -n "$p" ] || return 0
  p="${p//\\//}"
  p="${p/#\~/$HOME}"
  p="${p/#\$HOME/$HOME}"
  while [ "$p" != "${p//\/\//\/}" ]; do p="${p//\/\//\/}"; done
  # /c/foo -> c:/foo, so both spellings of a Windows path land on one key.
  case "$p" in
    /[a-zA-Z]/*) p="${p:1:1}:${p:2}" ;;
  esac
  FCLAIMS_KEY="${p,,}"
}

# fclaims_put <path> <sid> -- upsert this (path,sid), prune, atomic replace. No forks.
fclaims_put() {
  local p="${1:-}" sid="${2:-}" key now cutoff tmp line f_key f_sid f_ts
  [ -n "$p" ] && [ -n "$sid" ] || return 0
  case "$sid" in *[!a-zA-Z0-9-]*) return 0 ;; esac   # sid is the key of a warning; keep it clean
  fclaims_norm "$p"; key="$FCLAIMS_KEY"
  [ -n "$key" ] || return 0
  printf -v now '%(%s)T' -1 2>/dev/null
  case "$now" in ''|*[!0-9]*) now="$(date +%s 2>/dev/null)" ;; esac
  case "$now" in ''|*[!0-9]*) return 0 ;; esac
  cutoff=$(( now - FCLAIMS_MAX_AGE_SECS ))

  local -a keep=()
  if [ -r "$FCLAIMS_FILE" ]; then
    while IFS=$'\t' read -r f_key f_sid f_ts; do
      [ -n "$f_key" ] || continue
      case "$f_ts" in ''|*[!0-9]*) continue ;; esac
      [ "$f_ts" -ge "$cutoff" ] || continue
      [ "$f_key" = "$key" ] && [ "$f_sid" = "$sid" ] && continue
      keep+=("$f_key	$f_sid	$f_ts")
    done < "$FCLAIMS_FILE"
  fi
  # Rows are appended newest-last, so the tail IS the newest -- no sort needed for the cap.
  if [ "${#keep[@]}" -ge "$FCLAIMS_MAX_ROWS" ]; then
    keep=("${keep[@]: -$(( FCLAIMS_MAX_ROWS - 1 ))}")
  fi
  keep+=("$key	$sid	$now")

  local dir="${FCLAIMS_FILE%/*}"
  [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || return 0
  tmp="$FCLAIMS_FILE.$$"
  printf '%s\n' "${keep[@]}" > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 0; }
  mv -f "$tmp" "$FCLAIMS_FILE" 2>/dev/null || rm -f "$tmp" 2>/dev/null
}

# fclaims_others <path> <my-sid> -> lines "<sid>\t<epoch>" for OTHER sessions that edited it.
# Liveness is NOT tested here -- the caller decides, because only the caller knows which
# window is fair for what it is about to do.
fclaims_others() {
  local p="${1:-}" mine="${2:-}" key f_key f_sid f_ts
  [ -n "$p" ] && [ -r "$FCLAIMS_FILE" ] || return 0
  fclaims_norm "$p"; key="$FCLAIMS_KEY"
  [ -n "$key" ] || return 0
  while IFS=$'\t' read -r f_key f_sid f_ts; do
    [ "$f_key" = "$key" ] || continue
    [ -n "$f_sid" ] && [ "$f_sid" != "$mine" ] || continue
    printf '%s\t%s\n' "$f_sid" "$f_ts"
  done < "$FCLAIMS_FILE"
}
