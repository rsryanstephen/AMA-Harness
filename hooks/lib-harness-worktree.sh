#!/usr/bin/env bash
# Shared: is a file inside a linked worktree of the HARNESS repo? (worktree-by-default policy,
# commit-ticket/SHARED-REPO.md). Several Edit/Write gates resolve "the harness" as
# `git -C ~/.claude/{skills,hooks} rev-parse --show-toplevel` = the MAIN clone, so an edit made
# under ~/Repos/AMA_APP/.worktrees/ama-claude-harness-<slug>/ matched none of their path cases
# and every one of them silently exited -- worktree edits bypassed doc-currency and size checks.
#
# hwt_root_of <file_path> -> sets HWT_ROOT to the worktree root, or "" when the file is not in
# one. Sets a variable rather than printing: no subshell fork on the Edit path (same reasoning
# as lib-file-claims.sh's FCLAIMS_KEY). Caller: `hwt_root_of "$fp"; [ -n "$HWT_ROOT" ] && harness="$HWT_ROOT"`.
hwt_root_of() {
  HWT_ROOT=""
  local p="${1//\\//}" base rest
  case "$p" in
    */.worktrees/ama-claude-harness-*/*)
      base="${p%%/.worktrees/ama-claude-harness-*}"
      rest="${p#"$base"/.worktrees/}"
      HWT_ROOT="$base/.worktrees/${rest%%/*}" ;;
  esac
}
