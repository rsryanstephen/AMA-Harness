#!/usr/bin/env bash
# Shared mutual-exclusion lock for ~/.claude/sessions.txt, sourced by every hook that
# touches it (log-session-start.sh, rename-topic.sh, relocate-session.sh).
#
# Confirmed real gap: rename-topic.sh/relocate-session.sh read the whole file, then
# replace it wholesale via `mv`. If log-session-start.sh's plain `>>` append from a
# DIFFERENT concurrent session lands in between that read and that mv, the whole-file
# replace silently wipes the append -- the new session never shows up in sessions.txt,
# with no error anywhere. Multiple sessions running in parallel makes this a real,
# not theoretical, race on Windows/Git Bash (no `flock` available here).
#
# `mkdir` is atomic even over NTFS via Git Bash, so it's the portable lock primitive --
# no flock dependency needed.
SESSIONS_LOCKDIR="$HOME/.claude/.sessions.txt.lock"

sessions_lock() {
  local waited=0
  while ! mkdir "$SESSIONS_LOCKDIR" 2>/dev/null; do
    # Reclaim a stale lock (crashed holder) rather than deadlock forever.
    if [ -d "$SESSIONS_LOCKDIR" ]; then
      local held_at
      held_at="$(stat -c %Y "$SESSIONS_LOCKDIR" 2>/dev/null || echo 0)"
      local age=$(( $(date +%s) - held_at ))
      if [ "$age" -gt 10 ]; then
        rmdir "$SESSIONS_LOCKDIR" 2>/dev/null
        continue
      fi
    fi
    sleep 0.1
    waited=$((waited + 1))
    # ~5s max wait -- proceed unlocked rather than hang a hook forever if something's
    # stuck; losing one race under a genuinely wedged lock beats blocking the session.
    [ "$waited" -gt 50 ] && break
  done
}

sessions_unlock() {
  rmdir "$SESSIONS_LOCKDIR" 2>/dev/null
}

# sessions.txt/sessions.md are now symlinks at their ~/.claude path (real files live in
# the harness repo, see scripts/install.ps1) -- every rewrite here used to `mv "$tmp"
# "$dest"`, which replaces the symlink ITSELF with a plain file (rename() doesn't follow
# a symlink at the destination), silently detaching future writes from the real file.
# Same bug class already found and fixed for the per-session chat-log symlinks
# (lib-chatfile-link.sh) -- but unlike those (single-owner-per-session files),
# sessions.txt has a DOCUMENTED concurrency race (see this file's own top comment) and
# its lock proceeds unlocked after ~5s rather than deadlock -- a reader can genuinely
# race a writer here. `cat "$tmp" > "$dest"` would truncate $dest before writing,
# handing a concurrent reader a partial file; `mv "$tmp" <resolved target>` is still a
# real rename() (atomic, all-or-nothing) and never touches the symlink's own dentry,
# so it keeps the exact same atomicity the original bare `mv "$tmp" "$dest"` had before
# $dest became a symlink. Falls back to a plain mv for an adopter who hasn't run the
# updated install.ps1 yet (dest not yet a symlink).
sessions_write_through() {
  local tmp="$1" dest="$2" real
  if [ -L "$dest" ]; then
    real="$(readlink "$dest")"
    [ -n "$real" ] || return 1
    mv "$tmp" "$real"
  else
    mv "$tmp" "$dest"
  fi
}

# No sessions_sort_inplace anymore -- sessions.txt no longer carries a per-line
# timestamp (removed per user request). "Most-recently-active first" is now maintained
# structurally instead: on-prompt.sh splices the touched/new line out and re-prepends
# it to the top on every prompt, so file position IS the recency signal. rename-topic.sh
# and relocate-session.sh only edit a line's fields in place and don't touch position.

# Shared Windows-path -> copy-pasteable unix-form conversion (lowercase drive, /c/...,
# ~-substituted under $HOME) -- same logic every sessions.txt writer needs.
to_display_cwd() {
  local cwd="$1"
  local unix_cwd
  if [[ "$cwd" =~ ^([A-Za-z]):(.*)$ ]]; then
    local drive rest
    drive="$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')"
    rest="$(printf '%s' "${BASH_REMATCH[2]}" | tr '\\' '/')"
    unix_cwd="/$drive$rest"
  else
    unix_cwd="$(printf '%s' "$cwd" | tr '\\' '/')"
  fi
  if [[ "$unix_cwd" == "$HOME"* ]]; then
    printf '~%s' "${unix_cwd#$HOME}"
  else
    printf '%s' "$unix_cwd"
  fi
}
