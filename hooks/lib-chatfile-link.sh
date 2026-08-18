#!/usr/bin/env bash
# Chat-log centralization -- <harnessEpicKey> (see plan "Centralize chat files in
# `Chat files/` via reversed symlinks"). The REAL *.Chat.md file lives in
# <harness repo>/Chat files/; the session's cwd holds a symlink pointing at it. This is
# the reverse of the obvious "symlink in Chat files/, real file in cwd" design --
# verified that ripgrep and editor project-search do not follow file symlinks, so a
# forward symlink would make the central folder unsearchable and break edit-to-queue
# (atomic save replaces the link with a plain file, silently detaching it). Reversed:
# the central folder holds real files (searchable, editable), while the session's
# state file (`.session-chatfiles/<sid>`) still stores the CWD path -- unchanged --
# so on-prompt.sh's `dirname(chat) != cwd` relocate-on-mismatch check never fires.
#
# Confirmed real (this session, scratchpad tests): `>>` through a Windows file symlink
# follows it to the real target, including a dangling one -- the append materializes
# the target file at that point, so a symlink can be created before any chat content
# exists.
#
# BUT: Git Bash's `ln -s` (coreutils/MSYS) defaults to a lenient mode that SILENTLY
# FALLS BACK TO COPYING the file instead of erroring when native Windows symlink
# creation doesn't go through for whatever reason -- confirmed real on this machine: a
# space ANYWHERE in either path (target or link -- every real chat-file basename has
# one, "<name> Chat.md") was enough to trigger the fallback. The result LOOKS fine
# (`ln -s` exits 0, the file reads correctly) but `-L` is false -- it's a static copy,
# not a link, and edits to one side never reach the other. `MSYS=winsymlinks:nativestrict`
# (env-prefixed per call, not exported -- scoped to just that command, never leaked to
# a child process) forces a REAL symlink or a loud failure instead; confirmed it also
# handles a dangling target fine, spaces included. Every `ln -s` below uses this prefix
# -- drop it and chat-file linking silently degrades to copies that never sync.
#
# Sourceable (`. lib-chatfile-link.sh`) and directly executable
# (`bash lib-chatfile-link.sh <fn> [args]`), same convention as lib-harness-repos.sh.
#
# Deliberately NO `set -u` at file scope -- on-prompt.sh sources this ~30 lines in and
# runs ~420 more afterward; `set -u` here would leak into all of it for the rest of
# that hook's execution (confirmed: sourcing turns on shell options for the caller,
# not just this file). Every function below guards its own optional args (`${2:-}`)
# instead, so it doesn't need the option to be correct.

# Harness repo root, resolved via git through the skills/ junction -- same trick
# on-stop.sh:325-328 already uses to find the harness regardless of clone location.
chatfile_harness_dir() {
  git -C "$HOME/.claude/skills" rev-parse --show-toplevel 2>/dev/null
}

# Central dir, created on demand. Empty output (harness repo not resolvable) means
# callers must fall back to leaving the file in cwd -- never silently write elsewhere.
chatfile_central_dir() {
  local harness
  harness="$(chatfile_harness_dir)"
  [ -n "$harness" ] || return 1
  local dir="$harness/Chat files"
  mkdir -p "$dir" 2>/dev/null
  printf '%s' "$dir"
}

# Collision-free absolute path for <central>/<base>, suffixing with the session's own
# shortid (or "dup" if none given) when a DIFFERENT session already owns that name --
# e.g. two sessions renamed to the same topic. Bumps a numeric tail on the rare case
# the suffixed name is also taken.
chatfile_collision_free_target() {
  local base="$1" sid="${2:-}" central="$3"
  local target="$central/$base"
  [ -e "$target" ] || { printf '%s' "$target"; return 0; }

  local stem="${base% Chat.md}"
  local suffix="${sid:-dup}"
  local candidate="$central/${stem} (${suffix}) Chat.md"
  local n=2
  while [ -e "$candidate" ]; do
    candidate="$central/${stem} (${suffix}-${n}) Chat.md"
    n=$((n + 1))
  done
  printf '%s' "$candidate"
}

# `ln -s` under the nativestrict env prefix (see top-of-file note) -- the ONE place a
# real Windows symlink gets created. Every call site below goes through this, never a
# bare `ln -s`, so the copy-fallback bug can't creep back in at a new call site.
chatfile_symlink() {
  local target="$1" link="$2"
  mkdir -p "$(dirname "$target")" 2>/dev/null
  MSYS=winsymlinks:nativestrict ln -s "$target" "$link"
}

# Ensure a session's cwd chat-file path is a symlink into the central dir. No-op if
# it already is one (callers that are actively renaming/relocating use the more
# specific functions below instead). Handles three cases:
#   - already a symlink            -> no-op
#   - cwd path doesn't exist yet   -> create a dangling symlink at the eventual
#                                     central target (materializes on first append)
#   - cwd path is a real file      -> migration: move it into the central dir, then
#                                     symlink the cwd path to it
# Prints the resolved central target path on success (mainly for callers/logging);
# prints nothing and returns 1 if the harness repo can't be resolved (caller should
# leave the file where it is rather than error the whole hook).
chatfile_ensure_link() {
  local cwd_path="$1" sid="${2:-}"
  [ -n "$cwd_path" ] || return 1
  [ -L "$cwd_path" ] && return 0

  local central
  central="$(chatfile_central_dir)" || return 1

  local base target
  base="$(basename "$cwd_path")"

  if [ -f "$cwd_path" ]; then
    target="$(chatfile_collision_free_target "$base" "$sid" "$central")"
    mv "$cwd_path" "$target" || return 1
  else
    target="$central/$base"
  fi

  chatfile_symlink "$target" "$cwd_path" || return 1
  printf '%s' "$target"
}

# For rename-topic.sh: old_path is the session's current cwd chat-file path (symlink,
# or a plain file if this session predates centralization), new_path is the same dir
# with the new topic-derived basename. Renames the CENTRAL file (not just the link) so
# `Chat files/` reflects the new topic, then re-creates the symlink under the new name.
chatfile_relink_renamed() {
  local old_path="$1" new_path="$2" sid="${3:-}"
  [ -n "$old_path" ] && [ -n "$new_path" ] || return 1
  [ "$old_path" != "$new_path" ] || return 0

  if [ -L "$old_path" ]; then
    local central old_target new_base new_target
    old_target="$(readlink "$old_path")"
    central="$(dirname "$old_target")"
    new_base="$(basename "$new_path")"
    new_target="$(chatfile_collision_free_target "$new_base" "$sid" "$central")"
    if [ -f "$old_target" ] && [ "$old_target" != "$new_target" ]; then
      mv "$old_target" "$new_target" || return 1
    fi
    rm -f "$old_path"
    chatfile_symlink "$new_target" "$new_path" || return 1
    return 0
  fi

  # Pre-centralization session (plain file, no link yet): do the plain rename, then
  # migrate it into the central dir under its new name in the same step.
  if [ -f "$old_path" ]; then
    mv "$old_path" "$new_path" || return 1
  fi
  chatfile_ensure_link "$new_path" "$sid" >/dev/null
  return 0
}

# For relocate-session.sh: old_path is the session's chat-file symlink (or plain file)
# in its OLD cwd, new_cwd is the directory it just moved to. The basename is unchanged
# by a relocate (only the directory changes), so the central file itself never moves --
# only the symlink is removed from the old cwd and re-created in the new one.
chatfile_relink_moved() {
  local old_path="$1" new_cwd="$2"
  [ -n "$old_path" ] && [ -n "$new_cwd" ] || return 1
  local new_path="$new_cwd/$(basename "$old_path")"
  [ "$old_path" != "$new_path" ] || { printf '%s' "$new_path"; return 0; }

  if [ -L "$old_path" ]; then
    local target
    target="$(readlink "$old_path")"
    rm -f "$old_path"
    chatfile_symlink "$target" "$new_path" || return 1
    printf '%s' "$new_path"
    return 0
  fi

  if [ -f "$old_path" ]; then
    mv "$old_path" "$new_path" || return 1
  fi
  chatfile_ensure_link "$new_path" >/dev/null
  printf '%s' "$new_path"
}

# Direct-execution dispatch: `bash lib-chatfile-link.sh <fn> [args...]`.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fn="${1:-}"; shift || true
  case "$fn" in
    central-dir) chatfile_central_dir "$@" ;;
    ensure-link) chatfile_ensure_link "$@" ;;
    relink-renamed) chatfile_relink_renamed "$@" ;;
    relink-moved) chatfile_relink_moved "$@" ;;
    *) echo "usage: lib-chatfile-link.sh {central-dir|ensure-link|relink-renamed|relink-moved} [args]" >&2; exit 1 ;;
  esac
fi
