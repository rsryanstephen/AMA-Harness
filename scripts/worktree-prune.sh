#!/usr/bin/env bash
# Find (and, with --apply, remove) linked worktrees nobody needs any more.
#
# Usage: worktree-prune.sh [--apply] [--idle-days N] [<repo>]
#   default: DRY RUN across every repo under $AMA_REPOS_ROOT (~/Repos/AMA_APP); prints one
#   line per linked worktree: REMOVE / KEEP + the reason. --apply removes the REMOVE ones.
#
# A worktree is REMOVE only when ALL hold -- anything doubtful is KEEP:
#   1. directory exists, status clean (tracked, untracked; ignored files like node_modules don't count)
#   2. no commit on HEAD that is absent from every remote (`git log HEAD --not --remotes`)
#   3. no LIVE session claim on it (lib-repo-claims + lib-session-liveness)
#   4. idle >= N days (default 3): newest of dir / HEAD / index mtime
#   5. no junction/symlink within 3 levels (the worktree-junction-remove-gate.sh condition:
#      `git worktree remove` follows one and empties its TARGET; we skip, never force)
# Removal is plain `git worktree remove` (never --force), then `git worktree prune`; the local
# branch is deleted with `branch -d` only (refuses unmerged), and an emptied parent dir is
# rmdir'd (never rm -r). The main clone of a repo is never touched.
#
# Why it exists: ~90 linked worktrees had piled up across five root conventions with nothing
# sweeping them; each is a full checkout, and a parked branch trips worktree-branch-conflict-gate.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../hooks/lib-repo-claims.sh" 2>/dev/null || . "$HOME/.claude/hooks/lib-repo-claims.sh"
. "$HERE/../hooks/lib-session-liveness.sh" 2>/dev/null || . "$HOME/.claude/hooks/lib-session-liveness.sh"

ROOT="${AMA_REPOS_ROOT:-$HOME/Repos/AMA_APP}"
apply=false; idle_days=3; want=""
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) apply=true ;;
    --idle-days) shift; idle_days="${1:-3}" ;;
    *) want="$1" ;;
  esac
  shift
done
case "$idle_days" in ''|*[!0-9]*) echo "worktree-prune: --idle-days needs a number" >&2; exit 2 ;; esac
now="$(date +%s)"; idle_secs=$(( idle_days * 86400 ))

n_remove=0; n_keep=0

newest_mtime() {  # newest mtime of the dir, its HEAD and its index (epoch)
  local wt="$1" gd best m f
  gd="$(git -C "$wt" rev-parse --git-dir 2>/dev/null)"
  case "$gd" in /*|[A-Za-z]:*) ;; *) gd="$wt/$gd" ;; esac
  best=0
  for f in "$wt" "$gd/HEAD" "$gd/index"; do
    m="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
    [ "$m" -gt "$best" ] && best="$m"
  done
  echo "$best"
}

judge() {  # judge <main> <wt> -> sets REASON; returns 0 when removable
  local main="$1" wt="$2" st un cl sid mt links
  REASON=""
  [ -d "$wt" ] || { REASON="directory gone (git worktree prune clears it)"; return 1; }
  st="$(git -C "$wt" status --porcelain 2>/dev/null | head -1)"
  [ -z "$st" ] || { REASON="dirty"; return 1; }
  un="$(git -C "$wt" log --oneline -1 HEAD --not --remotes 2>/dev/null)"
  [ -z "$un" ] || { REASON="unpushed commit: ${un:0:60}"; return 1; }
  cl="$(claims_get "$(claims_repo_root "$wt")" 2>/dev/null)"
  sid="$(printf '%s' "$cl" | cut -f1)"
  if [ -n "$sid" ] && session_is_live "$sid"; then REASON="live session ${sid%%-*}"; return 1; fi
  mt="$(newest_mtime "$wt")"
  [ $(( now - mt )) -ge "$idle_secs" ] || { REASON="touched $(( (now - mt) / 3600 ))h ago"; return 1; }
  links="$(find "$wt" -maxdepth 3 \( -type l -print \) -o \( -type d \( -name node_modules -o -name .git \) -prune \) 2>/dev/null | head -1)"
  [ -z "$links" ] || { REASON="junction/symlink inside: $links"; return 1; }
  REASON="clean, pushed, idle $(( (now - mt) / 86400 ))d"
  return 0
}

for d in "$ROOT"/*/; do
  d="${d%/}"; name="${d##*/}"
  [ -d "$d/.git" ] || continue                     # main clones only; linked trees are listed via their main
  [ -n "$want" ] && [ "$name" != "$want" ] && continue
  main="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)"
  first=1; wt=""; br=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "worktree "*) wt="${line#worktree }"; br="" ;;
      "branch "*)   br="${line#branch refs/heads/}" ;;
      "")
        if [ -n "$wt" ]; then
          if [ "$first" = 1 ]; then first=0
          else
            if judge "$main" "$wt"; then
              n_remove=$(( n_remove + 1 ))
              echo "REMOVE  $wt  [${br:-detached}]  -- $REASON"
              if $apply; then
                if git -C "$main" worktree remove "$wt" 2>&1 | sed 's/^/    /'; [ ! -d "$wt" ]; then
                  [ -n "$br" ] && git -C "$main" branch -d "$br" 2>&1 | sed 's/^/    /'
                  rmdir "${wt%/*}" 2>/dev/null
                else
                  echo "    left in place (git refused)"
                fi
              fi
            else
              n_keep=$(( n_keep + 1 ))
              echo "KEEP    $wt  [${br:-detached}]  -- $REASON"
            fi
          fi
        fi
        wt=""; br="" ;;
    esac
  done < <(git -C "$main" worktree list --porcelain 2>/dev/null; echo)
  $apply && git -C "$main" worktree prune 2>/dev/null
done

echo "--"
if $apply; then echo "removed (attempted): $n_remove   kept: $n_keep"
else echo "dry run: $n_remove removable, $n_keep kept.  Re-run with --apply to remove the REMOVE lines."; fi
