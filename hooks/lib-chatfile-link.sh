#!/usr/bin/env bash
# Chat-log centralization -- <harnessEpicKey> (see plan "Centralize chat files in
# `Chat files/` via reversed symlinks"). The REAL *.Chat.md file lives in
# <harness repo>/Chat files/; the session's cwd holds a symlink pointing at it. This is
# the reverse of the obvious "symlink in Chat files/, real file in cwd" design --
# verified that ripgrep and editor project-search do not follow file symlinks, so a
# forward symlink would make the central folder unsearchable and break edit-to-queue
# (atomic save replaces the link with a plain file, silently detaching it). Reversed:
# the central folder holds real files (searchable, editable), while the session's
# state file (`.session-chatfiles/<sid>`) still stores the CWD path -- unchanged.
#
# <harnessEpicKey> follow-up: the symlink itself used to sit at the ROOT of the session
# cwd, which littered every repo with *Chat.md files (77 of them, one session). Now it
# lives at "<cwd>/Local Chat Files/<name> Chat.md" instead. That breaks the assumption
# baked into on-prompt.sh's relocate check (`dirname(chat) != cwd`) and half a dozen
# other sites that used dirname(chat-path) AS the session cwd -- they now go through
# chatfile_session_cwd() below, which strips the "Local Chat Files" segment back off.
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

# The one literal for the cwd-side subfolder name. "Local" (not "Chat Files") because
# NTFS is case-insensitive: a session running IN the harness repo would otherwise make
# this the SAME directory as the central "Chat files/" store above -- confirmed via
# `fsutil` case-sensitivity check on this machine. One name everywhere, no per-repo
# special case in any caller.
CHATFILE_LOCAL_DIR="Local Chat Files"

# <cwd>/Local Chat Files/<base>. Idempotent: if cwd already IS (or ends in) the local
# dir -- e.g. a caller re-derives cwd from an already-local chat path -- don't nest a
# second "Local Chat Files" level.
chatfile_local_path() {
  local cwd="$1" base="$2"
  case "$cwd" in
    */"$CHATFILE_LOCAL_DIR") printf '%s/%s' "$cwd" "$base" ;;
    *) printf '%s/%s/%s' "$cwd" "$CHATFILE_LOCAL_DIR" "$base" ;;
  esac
}

# Replaces the `default="$cwd/${sid%%-*} Chat.md"` fallback-name expression that used to
# be duplicated verbatim at 7 call sites (log-session-start.sh, on-prompt.sh, on-stop.sh
# x4, on-session-end.sh) -- divergence between copies is a live bug risk, not just
# repetition.
chatfile_default_path() {
  local cwd="$1" sid="$2"
  chatfile_local_path "$cwd" "${sid%%-*} Chat.md"
}

# Inverse of chatfile_local_path: given a chat-file path (root-level, legacy, OR inside
# "Local Chat Files/"), returns the session's actual cwd. Every site that used to treat
# `dirname(chat)` AS the cwd must go through this instead -- see the top-of-file note.
# A legacy root-level path (no "Local Chat Files" segment) is unaffected: dirname alone,
# same as before this feature existed.
chatfile_session_cwd() {
  local chat_path="$1" dir
  dir="$(dirname "$chat_path")"
  case "$dir" in
    */"$CHATFILE_LOCAL_DIR") printf '%s' "${dir%/"$CHATFILE_LOCAL_DIR"}" ;;
    *) printf '%s' "$dir" ;;
  esac
}

# For pointer resolution (`` See prompt in `X Chat.md` ``): prefer the subfolder (new
# convention), fall back to the cwd root (a user hand-wrote it there, or a legacy file
# never migrated), else default to the subfolder path for a brand-new file.
chatfile_resolve_named() {
  local cwd="$1" base="$2"
  local sub="$(chatfile_local_path "$cwd" "$base")"
  [ -e "$sub" ] && { printf '%s' "$sub"; return 0; }
  local root="$cwd/$base"
  [ -e "$root" ] && { printf '%s' "$root"; return 0; }
  printf '%s' "$sub"
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

# Is <link path> recorded as the chat file of a session OTHER than <shortid>? Scans the
# statefiles fork-free (same loop shape as rename-topic.sh). Empty shortid -> any owner
# counts as "elsewhere" (cannot prove it is ours).
chatfile_link_owned_elsewhere() {
  local link="$1" sid="${2:-}" f stored
  for f in "$HOME/.claude/.session-chatfiles"/*; do
    case "${f##*/}" in *.*) continue ;; esac
    [ -f "$f" ] || continue
    stored=""; IFS= read -r stored < "$f" 2>/dev/null || true
    [ "${stored//\\//}" = "${link//\\//}" ] || continue
    [ -n "$sid" ] && case "${f##*/}" in "$sid"*) continue ;; esac
    return 0
  done
  return 1
}

# This session's OWN central file for <base>, reused if it already exists. Returns the
# highest existing "<stem> (<sid>)" / "<stem> (<sid>-N)" file, else the first unused one.
#
# Reuse is the point. chatfile_collision_free_target always bumps past anything that EXISTS,
# so calling it repeatedly for the same session mints a fresh file every time -- observed
# live 2026-09-21 as four files for one session (`(349268b0)` through `(349268b0-4)`), three
# of them abandoned with a few hundred bytes in them. A session's log has to keep landing in
# the same file across relinks or it is not a log.
chatfile_own_central() {
  local base="$1" sid="${2:-}" central="$3"
  local sfx="${sid:-dup}"
  local stem="${base% Chat.md}"
  # $base may already carry our suffix (a relink of an already-suffixed path) -- strip it
  # back to the topic stem so we do not nest "(sid) (sid)".
  case "$stem" in
    *" ($sfx)"|*" ($sfx-"[0-9]*) stem="${stem% (*}" ;;
  esac
  local first="$central/${stem} ($sfx) Chat.md"
  local best="" n=2
  [ -e "$first" ] && best="$first"
  while [ -e "$central/${stem} ($sfx-${n}) Chat.md" ]; do
    best="$central/${stem} ($sfx-${n}) Chat.md"
    n=$((n + 1))
  done
  [ -n "$best" ] && { printf '%s' "$best"; return 0; }
  printf '%s' "$first"
}

# `ln -s` under the nativestrict env prefix (see top-of-file note) -- the ONE place a
# real Windows symlink gets created. Every call site below goes through this, never a
# bare `ln -s`, so the copy-fallback bug can't creep back in at a new call site.
chatfile_symlink() {
  local target="$1" link="$2"
  mkdir -p "$(dirname "$target")" 2>/dev/null
  # Link's parent (e.g. "<cwd>/Local Chat Files/") may not exist yet -- distinct from
  # the target's parent above, and `ln -s` fails outright if it's missing.
  mkdir -p "$(dirname "$link")" 2>/dev/null
  MSYS=winsymlinks:nativestrict ln -s "$target" "$link"
}

# Ensure a session's chat-file path is (a) a symlink into the central dir, AND (b)
# sitting under "<cwd>/Local Chat Files/", not the cwd root. Self-healing: an
# already-centralized link left at the OLD (root) location gets relocated down a level,
# not just left alone -- this is what migrates the 77 pre-existing root-level files
# (symlinked or not) the first time each session's owner sends another prompt, without
# needing the one-off migration script to catch every session ever created.
#
# Handles four cases:
#   - already a symlink, already in the subfolder      -> no-op
#   - already a symlink, but at the cwd root (stale)    -> relocate: rm the old link,
#                                                          recreate at the subfolder path
#                                                          pointing at the SAME central
#                                                          target (no move in Chat files/)
#   - path doesn't exist yet                             -> create a dangling symlink at
#                                                          the eventual central target
#                                                          (materializes on first append)
#   - path is a real file (root or subfolder)            -> migration: move it into the
#                                                          central dir, symlink back from
#                                                          the subfolder path
#
# Prints the resulting PATH (the symlink's location, which may differ from $1 -- callers
# that relocate MUST re-read this and persist it, not assume $1 is still current) on
# success; prints nothing and returns 1 if the harness repo can't be resolved (caller
# should leave the file where it is rather than error the whole hook).
chatfile_ensure_link() {
  local cur_path="$1" sid="${2:-}"
  [ -n "$cur_path" ] || return 1

  local cwd base
  base="$(basename "$cur_path")"
  cwd="$(chatfile_session_cwd "$cur_path")"
  local want_path
  want_path="$(chatfile_local_path "$cwd" "$base")"

  # The canonical link may already belong to a DIFFERENT session. Until 2026-09-21 nothing
  # checked: chatfile_collision_free_target suffixed the CENTRAL target per session, but the
  # link was always built from the plain base and chatfile_symlink recreated it
  # unconditionally -- so N sessions sharing a name contended for one link, last writer won,
  # and every one of them then followed that link into whichever session's central file won.
  # The per-session suffix bought nothing, because no session ever read its own file.
  #
  # Measured live: four sessions took the name "Next backlog task"; the link moved from
  # `(3544e7f0-2)` to `(349268b0-4)` within the hour, and three sessions' central files sat
  # frozen at a few KB while one collected everybody's prompts and replies. That also drove
  # real damage elsewhere -- set-session-ticket.sh resolves a session BY chat filename, so it
  # picked a different live session and overwrote its ticket.
  #
  # We take our own suffixed link instead, and critically we do NOT touch theirs: the branch
  # below would `rm -f "$cur_path"`, which on a shared link deletes the other session's only
  # path to its log while it is mid-run.
  if chatfile_link_owned_elsewhere "$want_path" "$sid"; then
    local central_own own_target own_link
    central_own="$(chatfile_central_dir)" || return 1
    own_target="$(chatfile_own_central "$base" "$sid" "$central_own")"
    own_link="$(chatfile_local_path "$cwd" "$(basename "$own_target")")"
    # Link basename mirrors the central basename on purpose -- otherwise the two names drift
    # and there is no way to tell from the cwd which central file a session is writing to.
    if [ -L "$own_link" ] && [ "$(readlink "$own_link")" = "$own_target" ]; then
      printf '%s' "$own_link"
      return 0
    fi
    chatfile_link_owned_elsewhere "$own_link" "$sid" && return 1
    rm -f "$own_link"
    chatfile_symlink "$own_target" "$own_link" || return 1
    printf '%s' "$own_link"
    return 0
  fi

  if [ -L "$cur_path" ]; then
    if [ "$cur_path" = "$want_path" ]; then
      printf '%s' "$cur_path"
      return 0
    fi
    # Stale location (still at cwd root, or some other legacy spot) -- same central
    # target, just re-point the link from the new path. Central file itself never moves.
    local target
    target="$(readlink "$cur_path")"
    rm -f "$cur_path"
    chatfile_symlink "$target" "$want_path" || return 1
    printf '%s' "$want_path"
    return 0
  fi

  local central
  central="$(chatfile_central_dir)" || return 1

  local target
  if [ -f "$cur_path" ]; then
    target="$(chatfile_collision_free_target "$base" "$sid" "$central")"
    mkdir -p "$(dirname "$want_path")" 2>/dev/null
    mv "$cur_path" "$target" || return 1
  else
    target="$central/$base"
  fi

  chatfile_symlink "$target" "$want_path" || return 1
  printf '%s' "$want_path"
}

# For rename-topic.sh: old_path is the session's current cwd chat-file path (symlink,
# or a plain file if this session predates centralization), new_path is the same dir
# with the new topic-derived basename. Renames the CENTRAL file (not just the link) so
# `Chat files/` reflects the new topic, then re-creates the symlink under the new name.
# Prints the path actually linked -- may be "<topic> (<sid8>) Chat.md" when another
# session holds the plain name.
chatfile_relink_renamed() {
  local old_path="$1" new_path="$2" sid="${3:-}"
  [ -n "$old_path" ] && [ -n "$new_path" ] || return 1
  [ "$old_path" != "$new_path" ] || { printf '%s' "$new_path"; return 0; }

  # The new name already exists as THIS session's own link (the session was renamed to it
  # before, then its old fallback file reappeared -- the user kept writing prompts into
  # "<shortid> Chat.md" and pointing at it). Renaming onto it used to `mv` the plain file
  # over the link and then migrate with a numeric suffix: 23 "(158ea91a-N) Chat.md" copies
  # in two days, one per pointer prompt, and the statefile left on the stale name (harness-
  # gaps 2026-09-18). Merge instead: append the reappeared content into the link's central
  # target, drop the stray, keep the link. A link owned by a DIFFERENT session falls through
  # to the collision-suffix path below -- merging would mix two sessions' logs.
  if [ -L "$new_path" ] && ! chatfile_link_owned_elsewhere "$new_path" "$sid"; then
    local keep_target src
    keep_target="$(readlink "$new_path")"
    case "$keep_target" in /*) ;; *) keep_target="$(chatfile_central_dir)/$(basename "$new_path")" ;; esac
    if [ -L "$old_path" ]; then src="$(readlink "$old_path")"; else src="$old_path"; fi
    if [ -f "$src" ] && [ "$src" != "$keep_target" ]; then
      { [ -s "$keep_target" ] && printf '\n---\n\n'; cat "$src"; } >> "$keep_target" || return 1
      rm -f "$src"
    fi
    [ "$old_path" != "$new_path" ] && rm -f "$old_path"
    printf '%s' "$new_path"
    return 0
  fi

  # New name already taken by ANOTHER session (link or plain file): take our own suffixed
  # name instead. Before 2026-10-12 this fell through: the -L branch mv'd our history to a
  # fresh "(sid8-N)", rm'd our link, then `ln -s` onto theirs failed -> rename-topic exited
  # before repointing the statefile (dead path, lost reply); the plain-file branch mv'd OVER
  # their link. Callers MUST persist the printed path, not $new_path.
  if [ -e "$new_path" ] || [ -L "$new_path" ]; then
    local own_c
    own_c="$(chatfile_central_dir)" || return 1
    own_c="$(chatfile_own_central "$(basename "$new_path")" "$sid" "$own_c")"
    new_path="$(dirname "$new_path")/$(basename "$own_c")"
    [ "$old_path" = "$new_path" ] && { printf '%s' "$new_path"; return 0; }
  fi

  if [ -L "$old_path" ]; then
    local central old_target new_base new_target
    old_target="$(readlink "$old_path")"
    # A RELATIVE target here is poison: dirname gives ".", so new_target becomes "./<base>"
    # and the replacement link points at ITSELF, in its own directory. Appends to it then
    # fail silently and the session's whole chat log stops being written -- observed
    # 2026-09-14 on session edcd4fbd, which lost every line logged after its rename and only
    # surfaced when dequeue-prompt.sh said "no such file". The `-f "$old_target"` test below
    # also reads relative-to-cwd, so the central file is never moved and the old name is
    # orphaned. Fall back to the canonical central dir rather than trusting the readlink.
    case "$old_target" in
      /*) central="$(dirname "$old_target")" ;;
      *)  central="$(chatfile_central_dir)" || return 1 ;;
    esac
    new_base="$(basename "$new_path")"
    # Already our own file under that name -> keep it, never bump past ourselves.
    if [ "$central/$new_base" = "$old_target" ]; then
      new_target="$old_target"
    else
      new_target="$(chatfile_collision_free_target "$new_base" "$sid" "$central")"
    fi
    if [ -f "$old_target" ] && [ "$old_target" != "$new_target" ]; then
      mv "$old_target" "$new_target" || return 1
    fi
    rm -f "$old_path"
    chatfile_symlink "$new_target" "$new_path" || return 1
    printf '%s' "$new_path"
    return 0
  fi

  # Pre-centralization session (plain file, no link yet): do the plain rename, then
  # migrate it into the central dir under its new name in the same step.
  if [ -f "$old_path" ]; then
    mv "$old_path" "$new_path" || return 1
  fi
  local ensured
  ensured="$(chatfile_ensure_link "$new_path" "$sid")"
  printf '%s' "${ensured:-$new_path}"
  return 0
}

# For relocate-session.sh: old_path is the session's chat-file symlink (or plain file)
# in its OLD cwd, new_cwd is the directory it just moved to. The basename is unchanged
# by a relocate (only the directory changes), so the central file itself never moves --
# only the symlink is removed from the old cwd and re-created in the new one.
chatfile_relink_moved() {
  local old_path="$1" new_cwd="$2"
  [ -n "$old_path" ] && [ -n "$new_cwd" ] || return 1
  local new_path
  new_path="$(chatfile_local_path "$new_cwd" "$(basename "$old_path")")"
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
