#!/usr/bin/env bash
# git_target_dir "<command>" "<cwd>" -- which directory is this git command about?
#
# Prints the directory. Sets GIT_TARGET_UNRESOLVED=1 (else empty) when the command named a
# path this hook cannot expand and the cwd was used instead.
#
# WHY A SHARED LIB. Eleven hooks each carried their own copy of this resolution, in three
# dialects, and they had already diverged: only 8 of 11 expanded `~`/`$HOME`; only
# git-push-ticket-reminder.sh handled a path held in a shell variable (`W=...; git -C "$W"
# push`), the shape bare-cd-gate.sh steers every session into -- its absence let
# PROJ-15226 reach develop and sit at In Progress (2026-09-14), and the fix reached one
# copy of eleven; only master-push-direct-gate.sh survived a quoted path with a space. Same
# class as the two Octopus gates fixed 2026-09-15: one predicate, divergent copies, and a
# fix that lands in one of them.
#
# Resolution order:
#   1. `git -C <path>` -- anchored at a command position, quoted or bare (master-push's
#      dialect, the only one that handled `"C:/Program Files/..."`).
#   2. a leading `cd <path>` (with or without a following && / ;).
#   3. the session cwd.
# A `$NAME[/rest]` path takes NAME's literal `NAME=value` assignment from the same command
# (`_git_target_expand_var`). Then `~/` and `$HOME/` prefixes are expanded with this process's real $HOME -- grep hands
# back literal text, and `git -C` does not expand either form itself, so an unexpanded
# path silently fails and a hook goes quiet. A path that STILL carries `$`, a backtick or a
# glob after that cannot be resolved here: fall back to the cwd and flag it, never exit
# silent -- an unresolvable path is exactly when a hook most needs to say something.
# GIT_TARGET_UNRESOLVED CANNOT CROSS `$(...)`: every caller takes the dir via command
# substitution, so the flag is set in a subshell and the parent never sees it (found
# 2026-10-05 -- git-push-ticket-reminder.sh had read it as empty since the lib was written).
# Callers test git_target_unresolved "<command>" instead; the variable stays for in-process use.
# _git_target_expand_var "<dir>" "<command>" -- `$NAME[/rest]` / `${NAME}[/rest]` -> NAME's literal
# value from a `NAME=value` assignment in the same command (last one wins). Fork-free; unchanged
# when no literal assignment exists. 2026-10-15: `W=<worktree>; git -C $W push` left
# library-version-sync-reminder.sh silent on both PROJ-15801 hotfix pushes.
_git_target_expand_var() {
  local dir="$1" cmd="$2" name rest val re
  if [[ "$dir" =~ ^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?(/.*)?$ ]]; then
    name="${BASH_REMATCH[1]}"; rest="${BASH_REMATCH[2]}"
    [ "$name" = HOME ] && { printf '%s' "$dir"; return; }
    re="(^|[[:space:];&|(])${name}=(\"([^\"]*)\"|'([^']*)'|([^[:space:];&|\"'\$\`]+))"
    val=""
    while [[ "$cmd" =~ $re ]]; do
      val="${BASH_REMATCH[3]}${BASH_REMATCH[4]}${BASH_REMATCH[5]}"
      cmd="${cmd#*"${BASH_REMATCH[0]}"}"
    done
    [ -n "$val" ] && { printf '%s' "$val$rest"; return; }
  fi
  printf '%s' "$dir"
}

# _git_target_c_arg "<command>" [verb] -- the `git -C <path>` argument. With a verb, the -C
# whose own clause runs that verb wins: in `git -C $R diff ...; git -C $W commit` the commit
# is about $W, and taking the first -C made shared-input-contract-nudge.sh read the MAIN
# clone's HEAD after a worktree commit (2026-10-20). No verb, or no match -> first -C.
_git_target_c_arg() {
  local c a=""
  c="$(printf '%s' "$1" | tr -d '\r')"
  if [ -n "${2:-}" ]; then
    a="$(printf '%s' "$c" | grep -oP '(?:^|[;&|(]|&&)\s*git\s+-C\s+\K(?:"[^"]+"|\S+)(?=\s+(?:-\S+\s+)*'"$2"'\b)' | head -1)"
  fi
  [ -n "$a" ] || a="$(printf '%s' "$c" | grep -oP '(?:^|[;&|(]|&&)\s*git\s+-C\s+\K(?:"[^"]+"|\S+)' | head -1)"
  printf '%s' "$a" | sed -e 's/^"//' -e 's/"$//'
}

# git_target_unresolved "<command>" [verb] -- verb as for git_target_dir.
git_target_unresolved() {
  local dir
  dir="$(_git_target_c_arg "$1" "${2:-}")"
  [ -n "$dir" ] || dir="$(printf '%s' "$1" | tr -d '\r' | grep -oP '^\s*cd\s+"?\K[^"[:space:];&]+' | head -1)"
  case "$dir" in '$'*) dir="$(_git_target_expand_var "$dir" "$1")" ;; esac
  dir="${dir/#\~/$HOME}"; dir="${dir/#\$HOME/$HOME}"; dir="${dir/#\$\{HOME\}/$HOME}"
  case "$dir" in *'$'*|*'`'*|*'*'*|*'?'*) return 0 ;; esac
  return 1
}

# git_target_dir "<command>" "<cwd>" [verb] -- verb (e.g. commit) picks the -C of that clause.
git_target_dir() {
  local command="$1" cwd="$2" dir
  GIT_TARGET_UNRESOLVED=""

  dir="$(_git_target_c_arg "$command" "${3:-}")"
  [ -n "$dir" ] || dir="$(printf '%s' "$command" | tr -d '\r' \
    | grep -oP '^\s*cd\s+"?\K[^"[:space:];&]+' | head -1)"
  [ -n "$dir" ] || dir="$cwd"

  case "$dir" in '$'*) dir="$(_git_target_expand_var "$dir" "$command")" ;; esac
  dir="${dir/#\~/$HOME}"
  dir="${dir/#\$HOME/$HOME}"
  dir="${dir/#\$\{HOME\}/$HOME}"

  case "$dir" in
    *'$'*|*'`'*|*'*'*|*'?'*)
      dir="$cwd"; GIT_TARGET_UNRESOLVED=1 ;;
  esac

  printf '%s' "$dir"
}

# git_push_rejected "<raw payload>" -- true when the push's output says it failed and shows no
# ref that DID update (` a1b2..c3d4  x -> y`, `* [new branch]`, forced `+ a...b`). PostToolUse
# push nudges exit on it: a pre-receive rejection is not a push (2026-10-15).
git_push_rejected() {
  case "$1" in *"failed to push some refs"*|*"[remote rejected]"*|*"! [rejected]"*) ;; *) return 1 ;; esac
  printf '%s' "$1" | grep -qP '[0-9a-f]{7,}\.\.\.?[0-9a-f]{7,}\s+\S+ -> |\* \[new (branch|tag)\]' && return 1
  return 0
}
