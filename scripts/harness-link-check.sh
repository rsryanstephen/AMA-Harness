#!/usr/bin/env bash
# Reports any ~/.claude entry that install.ps1 links into the harness repo but that is
# currently a REAL file/dir instead of a link.
#
# Why this exists: on 2026-09-01 `~/.claude/harness-gaps.md` was replaced by a real file
# TWICE (09:47, then again at 11:06 after the first repair). While it is a real file every
# append through the `~/.claude` path lands somewhere nothing reads -- gap entries from every
# session silently stop reaching the repo, and nothing anywhere says so. It was found by
# accident, because an unrelated check-gates.sh case (`write through a ~/.claude symlink`)
# went from deny to pass. That accident is the only reason it was ever noticed; this makes
# it a check instead. The unlink route itself is now gated (shell-write-bypass-gate.sh maps
# a `sed -i`/`perl -i` on a linked ~/.claude path to symlink-write-gate.sh), but a gate only
# covers tool calls -- an unattended runner or an external process still gets through, so
# detection has to stand on its own.
#
# Usage: harness-link-check.sh [--repair] [harness-repo-root]
#   (no flag)  report only, exit 1 if anything is broken, 0 if all linked
#   --repair   additionally repair the APPEND-ONLY files, see the merge note below
# Output: one line per broken target.
set -u

repair=0
args=()
for a in "$@"; do
  case "$a" in
    --repair) repair=1 ;;
    *) args+=("$a") ;;
  esac
done

harness="${args[0]:-$(git -C "$HOME/.claude/skills" rev-parse --show-toplevel 2>/dev/null)}"
[ -n "$harness" ] && [ -d "$harness" ] || exit 0
CDIR="${CLAUDE_LINK_ROOT:-$HOME/.claude}"   # seam: the suite points this at its own snapshot

# install.ps1's $targets list. Keep in step with it -- a target added there and not here is
# simply unchecked, which is how this class goes unnoticed in the first place.
TARGETS='skills hooks scripts memory CLAUDE.md README.md AGENTS.md
harness-config.example.json .harness-local.json.example harness-gaps.md
sessions.txt sessions.md session-names.txt'

# Repaired by merge, never by copy. Both copies routinely hold work the other lacks: at the
# 11:06 recurrence the live file had a newer `cb8b1004` annotation while the repo had a whole
# `6f6fb2f3` entry live had never seen, so `cp` in EITHER direction would have destroyed
# somebody's entry. These three are strictly append-only line sets, so a line union is
# well-defined and lossless; nothing else is, which is why nothing else is repaired.
APPEND_ONLY='harness-gaps.md sessions.txt session-names.txt'

# Deliberately NOT checked for repair, and not reported as broken when it is a real file:
# install.ps1 REFUSES to replace a real harness-config.json that differs from the repo copy,
# because that config is Octopus-synced and the repo copy is routinely the stale one.
# A real file there is the designed state, not damage.
SKIP='harness-config.json'

broken=0
for name in $TARGETS; do
  live="$CDIR/$name"
  repo="$harness/$name"
  [ -e "$repo" ] || continue          # not in this checkout (sessions.md is generated)
  case " $SKIP " in *" $name "*) continue ;; esac
  [ -e "$live" ] || continue          # absent is install.ps1's business, not a silent-loss bug
  [ -L "$live" ] && continue
  # A Windows junction is not a symlink to `test -L`, but readlink -f still resolves it
  # out of ~/.claude. Compare resolved paths before calling a directory broken.
  if [ -d "$live" ]; then
    [ "$(readlink -f "$live" 2>/dev/null)" = "$(readlink -f "$repo" 2>/dev/null)" ] && continue
  fi

  broken=$((broken + 1))
  printf 'BROKEN LINK: %s is a real %s, not a link into %s\n' \
    "$live" "$([ -d "$live" ] && echo dir || echo file)" "$repo"

  case " $APPEND_ONLY " in *" $name "*) : ;; *)
    printf '  -> not auto-repaired (only %s are append-only, so only they merge losslessly). Reconcile by hand, then re-run scripts/install.ps1.\n' "$APPEND_ONLY"
    continue ;;
  esac
  [ "$repair" = 1 ] || { printf '  -> re-run with --repair to merge and relink.\n'; continue; }

  # Union of both line sets, ORIGINAL ORDER preserved from the repo copy first, then any
  # live-only lines appended. `grep -vxF -f` keeps a line the repo already has from being
  # duplicated. Never `sort -u` -- these files are read top-to-bottom by humans and by
  # on-prompt.sh, and sorting them would scramble the header and the review blocks.
  merged="$(mktemp)"
  # Counted BEFORE the merge: computing it afterwards compares the live file against a repo
  # copy that already contains those lines, which always reports 0.
  live_only="$(grep -cvxF -f "$repo" "$live" 2>/dev/null || echo 0)"
  cat "$repo" > "$merged"
  grep -vxF -f "$repo" "$live" 2>/dev/null >> "$merged" || true
  if ! cmp -s "$merged" "$repo"; then
    cat "$merged" > "$repo"
    printf '  -> merged %s live-only line(s) into the repo copy.\n' "$live_only"
  fi
  rm -f "$merged"

  # The live file is kept until a link actually exists in its place. Deleting first and
  # relinking after means a failed relink leaves NO file at all -- and this check skips a
  # missing target, so the next run would go SILENT on the very thing it exists to report.
  backup="$(mktemp)"; cat "$live" > "$backup"
  rm -f "$live"
  # MSYS `ln -s` copies unless winsymlinks is set, so shell out as install.ps1 does. pwsh
  # FIRST and not just "powershell": Windows PowerShell 5.1 refuses with "Administrator
  # privilege required" even with Developer Mode on, while pwsh 7 honours it (verified on
  # this box) -- so the 5.1 fallback is a last resort, not the default.
  linked=0
  for sh in pwsh.exe powershell.exe; do
    command -v "$sh" >/dev/null 2>&1 || continue
    if "$sh" -NoProfile -Command \
         "New-Item -ItemType SymbolicLink -Path '$(cygpath -w "$live")' -Value '$(cygpath -w "$repo")' -ErrorAction Stop | Out-Null" >/dev/null 2>&1; then
      linked=1; break
    fi
  done
  if [ "$linked" = 1 ]; then
    printf '  -> relinked %s -> %s\n' "$live" "$repo"
    rm -f "$backup"
  else
    cat "$backup" > "$live"; rm -f "$backup"
    printf '  -> RELINK FAILED (needs Developer Mode or an elevated shell). Content is merged and safe in %s, and the real file is left in place so this keeps reporting instead of going quiet.\n' "$repo"
  fi
done

[ "$broken" -eq 0 ] || exit 1
exit 0
