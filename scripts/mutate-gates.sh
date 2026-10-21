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
# Mark the run in suite-runs.log so proc-start-latency.sh never counts its load as a slow spell.
_sr_log="$HOME/.claude/harness-state/logs/suite-runs.log"
printf '%(%Y-%m-%dT%H:%M:%S)T start mutate-gates pid=%s %s\n' -1 "$$" "$*" >> "$_sr_log" 2>/dev/null
trap '_rc=$?; rm -rf "$WORK"; printf "%(%Y-%m-%dT%H:%M:%S)T end mutate-gates pid=%s rc=%s\n" -1 "$$" "$_rc" >> "$_sr_log" 2>/dev/null' EXIT

# Accept check-gates.sh's `--gate X` spelling as an alias for this script's positional form. The
# two are siblings agents run back to back, and the wrong one FAILED SILENTLY in the worst way:
# "--gate" became a gate NAME (one "SKIP (absent)" line nobody reads), and because $# was then 2
# the single-gate filter below never armed -- so both suite passes ran UNFILTERED, turning a
# ~30-60s targeted run into ~2x10 min. Measured 2026-09-14; the user had to notice it was still
# going 20 min later. An alias, not an error: the intent is unambiguous.
while [ "$#" -gt 0 ] && [ "$1" = "--gate" ]; do shift; done

gates="$*"
if [ -z "$gates" ]; then
  gates="$(grep -oE '^G=[a-z0-9-]+\.sh' "$SUITE" | sed 's/G=//' | sort -u | tr '\n' ' ')"
elif [ "$#" -eq 1 ] && [ -z "${CHECK_GATES_ONLY:-}" ]; then
  # AGENTS.md tells agents to run this TARGETED after touching a gate, but naming one gate
  # only narrowed what gets MUTATED -- both suite runs below stayed full passes, so a
  # "targeted" run still cost ~2x10 min and got killed by the low-memory supervisor at 580s
  # (measured 2026-09-09). check-gates.sh reads CHECK_GATES_ONLY from the environment and
  # these runs are its children, so forwarding it makes the whole thing ~30-60s per pass.
  # Only for a single named gate: the filter matches one exact name, so a multi-gate
  # invocation must stay unfiltered or every gate but one would report "cannot fail".
  export CHECK_GATES_ONLY="$1"
fi

# A fake harness root needs more than hooks/: the readme-family cases reference
# $harness/README.md, $harness/AGENTS.md and $harness/scratch/, and readme-currency-gate greps
# AGENTS.md for the edited file's key. Seed those or the baseline fails for the wrong reason.
seed_harness() {
  local dest="$1"
  mkdir -p "$dest/scratch"
  cp -r "$H/hooks" "$dest/hooks"
  cp "$H/AGENTS.md" "$H/README.md" "$dest/" 2>/dev/null || true
  # Without these the baseline runs 3 environment SKIPs the real tree doesn't (scfg-parity
  # needs $harness/harness-config.example.json; the unattended-wrapper-allowlist block needs
  # the two runner scripts under skills/) -- and a SKIP here is a case no mutation can fail.
  # Deliberately NOT `cp -r skills/` -- that tree carries junctions/symlinks on Windows.
  cp "$H/harness-config.example.json" "$dest/" 2>/dev/null || true
  # settings.template.json: the suite's "hook is registered" assertion greps it. Missing here, it
  # fails for EVERY gate and the baseline is never green -- i.e. mutate-gates.sh aborts always,
  # silently useless. Confirmed 2026-09-14: baseline 619/1-failed against a real tree that was
  # 637/0. Whenever the suite starts asserting about a new $harness/<file>, seed it here too.
  cp "$H/settings.template.json" "$dest/" 2>/dev/null || true
  local s
  for s in ama-standup-notes ama-team-meeting-notes; do
    mkdir -p "$dest/skills/$s/scripts"
    cp "$H/skills/$s/scripts/"*unattended-run.sh "$dest/skills/$s/scripts/" 2>/dev/null || true
  done
  : > "$dest/scratch/throwaway.md"
}

# Baseline: unmutated copy must be green, otherwise the deltas below mean nothing.
mkdir -p "$WORK/base"
seed_harness "$WORK/base"
# Streamed to a file, not captured into a variable. A captured run shows NOTHING while it
# executes, so its log sat at 0 bytes for 20 minutes on 2026-09-14 and a hang looked exactly
# like progress -- the user had to ask what was still running. check-gates.sh already prints
# `gate N: <name>` per gate to stderr; this is what makes that visible. $WORK lives until the
# EXIT trap fires, so the log is tailable for the whole run.
printf 'mutate-gates: streaming suite output under %s\n' "$WORK"
bash "$SUITE" "$WORK/base" > "$WORK/base.log" 2>&1
base_all="$(cat "$WORK/base.log")"
# Pick the SUMMARY line by shape, not by position. `tail -1` broke as soon as a filtered run
# started appending its "some assertions are suite-level" advisory after the summary: the
# green baseline then never matched "0 failed" and every targeted run aborted claiming the
# fixtures were broken.
base_out="$(printf '%s' "$base_all" | grep -E 'check-gates: [0-9]+ passed' | tail -1)"
printf 'baseline: %s\n\n' "$base_out"
case "$base_out" in
  *"0 failed"*) ;;
  *)
    # Print WHICH cases failed. Aborting on the count alone sent one investigation off to
    # hand-build a baseline reproducer just to see the FAIL lines -- and a baseline that fails
    # here while the real tree is green is almost always the documented $real_harness trap
    # (a gate that resolves the harness itself, given a payload naming the relocated copy) or
    # two passes colliding on shared probe state.
    printf 'ABORT: baseline is not green -- the failures below are in the SUITE or its fixtures,\n'
    printf 'not in any gate. A green run against the real tree does not clear them.\n\n'
    printf '%s\n' "$base_all" | grep -E '^(FAIL|SKIP)' | sed 's/^/  /'
    exit 1 ;;
esac

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
  # Same reason as the baseline above: to a file, then counted, so the run is observable
  # while it happens instead of only after it ends.
  bash "$SUITE" "$WORK/m" > "$WORK/m.log" 2>&1
  n="$(grep -c '^FAIL' "$WORK/m.log" || true)"
  if [ "$n" -eq 0 ]; then
    printf '%-38s %s\n' "$g" "*** NONE -- case cannot fail ***"
    undetected=$((undetected + 1))
  else
    printf '%-38s %s\n' "$g" "$n"
  fi
done < <(printf '%s\n' $gates)

printf '\ngates whose cases cannot fail: %d\n' "$undetected"
[ "$undetected" -eq 0 ]
