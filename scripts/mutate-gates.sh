#!/usr/bin/env bash
# Mutation test for check-gates.sh: neuter one gate at a time (force `exit 0` right after the
# shebang, so it always allows) and assert the suite NOTICES. A case that cannot fail is worse
# than no case -- this is what proves each assert actually exercises its gate.
# Usage: mutate-gates.sh [gate.sh ...]   (default: every gate the suite names)
set -u
H="${HARNESS_ROOT:-$(git -C "$HOME/.claude/skills" rev-parse --show-toplevel 2>/dev/null)}"
[ -d "$H/hooks" ] || { printf 'mutate-gates.sh: cannot locate the harness (set HARNESS_ROOT)\n' >&2; exit 1; }
SUITE="$H/scripts/check-gates.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mutate.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

gates="$*"
if [ -z "$gates" ]; then
  gates="$(grep -oE '^G=[a-z0-9-]+\.sh' "$SUITE" | sed 's/G=//' | sort -u | tr '\n' ' ')"
fi

# A fake harness root needs more than hooks/: the readme-family cases reference
# $harness/README.md, $harness/AGENTS.md and $harness/scratch/, and readme-currency-gate greps
# AGENTS.md for the edited file's key. Seed those or the baseline fails for the wrong reason.
seed_harness() {
  local dest="$1"
  mkdir -p "$dest/scratch"
  cp -r "$H/hooks" "$dest/hooks"
  cp "$H/AGENTS.md" "$H/README.md" "$dest/" 2>/dev/null || true
  : > "$dest/scratch/throwaway.md"
}

# Baseline: unmutated copy must be green, otherwise the deltas below mean nothing.
mkdir -p "$WORK/base"
seed_harness "$WORK/base"
base_out="$(bash "$SUITE" "$WORK/base" 2>&1 | tail -1)"
printf 'baseline: %s\n\n' "$base_out"
case "$base_out" in *"0 failed"*) ;; *) printf 'ABORT: baseline is not green\n'; exit 1 ;; esac

printf '%-38s %s\n' "MUTATED GATE" "FAILURES DETECTED"
undetected=0
while IFS= read -r g; do
  [ -n "$g" ] || continue
  rm -rf "$WORK/m"; mkdir -p "$WORK/m"
  seed_harness "$WORK/m"
  target="$WORK/m/hooks/$g"
  [ -f "$target" ] || { printf '%-38s %s\n' "$g" "SKIP (absent)"; continue; }
  # Insert the neutering exit after the shebang line.
  sed -i '1a exit 0' "$target"
  n="$(bash "$SUITE" "$WORK/m" 2>&1 | grep -c '^FAIL')"
  if [ "$n" -eq 0 ]; then
    printf '%-38s %s\n' "$g" "*** NONE -- case cannot fail ***"
    undetected=$((undetected + 1))
  else
    printf '%-38s %s\n' "$g" "$n"
  fi
done < <(printf '%s\n' $gates)

printf '\ngates whose cases cannot fail: %d\n' "$undetected"
[ "$undetected" -eq 0 ]
