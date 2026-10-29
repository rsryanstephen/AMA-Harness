#!/usr/bin/env bash
# Create a linked worktree under the ONE canonical root, ~/Repos/AMA_APP/.worktrees/.
#
# Usage: worktree-add.sh <repo> <slug> <branch> [base]
#   <repo>   directory name under $AMA_REPOS_ROOT (default ~/Repos/AMA_APP)
#   <slug>   suffix for the dir: .worktrees/<repo>-<slug>
#   <branch> new branch to create there
#   [base]   start point; default = origin's default branch (the harness repo: local master)
# Prints the worktree path on stdout (last line) so callers can `git -C "$(...)"`.
#
# Why one root: five conventions had piled up (~90 worktrees). `.worktrees/` is hidden, so
# fleet-repo-state.sh's `"$ROOT"/*/` walk does not list a worktree as if it were a repo.
# node_modules: `npm ci` in the new tree. NEVER junction it to the main clone --
# worktree-junction-remove-gate.sh exists because `git worktree remove` followed one.
set -u

ROOT="${AMA_REPOS_ROOT:-$HOME/Repos/AMA_APP}"
repo="${1:-}"; slug="${2:-}"; branch="${3:-}"; base="${4:-}"
[ -n "$repo" ] && [ -n "$slug" ] && [ -n "$branch" ] || { echo "usage: worktree-add.sh <repo> <slug> <branch> [base]" >&2; exit 2; }

src="$ROOT/$repo"
[ -e "$src/.git" ] || { echo "worktree-add: $src is not a git repo" >&2; exit 1; }

if [ -z "$base" ]; then
  if [ "$repo" = "ama-claude-harness" ]; then
    base="master"
  else
    base="$(git -C "$src" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)"
    [ -n "$base" ] || base="origin/develop"
  fi
fi

# Fetch only a remote-tracking base; fail soft (offline / VPN down) and use what is local.
case "$base" in
  origin/*) git -C "$src" fetch --quiet origin "${base#origin/}" 2>/dev/null || echo "worktree-add: fetch failed, using local $base" >&2 ;;
esac

wt="$ROOT/.worktrees/$repo-$slug"
[ -e "$wt" ] && { echo "worktree-add: $wt already exists" >&2; exit 1; }

git -C "$src" worktree add "$wt" -b "$branch" "$base" >&2 || exit 1
echo "worktree-add: product repos need 'npm ci' inside the tree (no node_modules junction)." >&2
echo "$wt"
