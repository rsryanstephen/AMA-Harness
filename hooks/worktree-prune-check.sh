#!/usr/bin/env bash
# Sourced from on-prompt.sh (not standalone-wired). Weekly nudge: when linked worktrees pile
# up, point at scripts/worktree-prune.sh (dry run by default; nothing is removed unprompted).
#
# Pure bash and ONE glob pass -- on-prompt.sh is fork/timeout sensitive (see its fork-count
# throttle comment). Counting is a glob over the canonical root plus the legacy
# `/c/<repo>-worktrees/` roots; it does NOT ask git, so the count is an upper bound on what
# the prune script will actually call removable. Threshold, not exactness, is the point.
#
# Sets $worktree_prune_notice (empty = nothing to say). Throttle marker: once per 7 days.
# Toggle: WORKTREE_PRUNE_NUDGE=off.
worktree_prune_notice=""
[ "${WORKTREE_PRUNE_NUDGE:-}" = "off" ] && return 0 2>/dev/null
. "$HOME/.claude/hooks/lib-claude-paths.sh"
_wp_marker="$(hstate notices .worktree-prune-nudged)"
_wp_root="${AMA_REPOS_ROOT:-$HOME/Repos/AMA_APP}"
_wp_threshold="${WORKTREE_PRUNE_THRESHOLD:-30}"

_wp_due=1
if [ -f "$_wp_marker" ]; then
  _wp_age=$(( $(date +%s) - $(stat -c %Y "$_wp_marker" 2>/dev/null || echo 0) ))
  [ "$_wp_age" -lt 604800 ] && [ "$_wp_age" -ge 0 ] && _wp_due=0
fi

if [ "$_wp_due" = 1 ]; then
  _wp_n=0
  for _wp_d in "$_wp_root"/.worktrees/*/ /c/*-worktrees/*/; do
    [ -d "$_wp_d" ] && _wp_n=$(( _wp_n + 1 ))
  done
  if [ "$_wp_n" -ge "$_wp_threshold" ]; then
    worktree_prune_notice="WORKTREE SPRAWL: $_wp_n linked worktrees exist (threshold $_wp_threshold). Run \`bash ~/.claude/scripts/worktree-prune.sh --apply\` now -- standing rule (user 2026-10-22), no need to ask; its safety checks are the approval. Tell the user what was removed and kept. Said once a week."
    touch "$_wp_marker" 2>/dev/null
  fi
fi
unset _wp_marker _wp_root _wp_threshold _wp_due _wp_age _wp_n _wp_d
