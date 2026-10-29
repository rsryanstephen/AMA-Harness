#!/usr/bin/env bash
# Proves hooks/dispatch.sh never silently drops a gate's decision.
#
#   bash scripts/check-dispatch-equivalence.sh           # reuse the newest trace (~1-2 min was the old claim; ~500 pairs x gate+dispatch spawns = 10-40 min on Windows under load, BelowNormal priority)
#   bash scripts/check-dispatch-equivalence.sh --full    # re-harvest from check-gates (~15 min)
#   bash scripts/check-dispatch-equivalence.sh --mutate  # self-test: prove this check can FAIL
#   bash scripts/check-dispatch-equivalence.sh <trace>   # re-check a specific trace
#   bash scripts/check-dispatch-equivalence.sh --post    # the PostToolUse manifest instead
#
# The dangerous failure mode for a dispatcher is NOT "it ran a gate it needn't have" -- that
# is merely slower. It is "the needle was too narrow, the gate never ran, the call went
# UNGUARDED, and it looks exactly like a pass" -- the class GATES-AND-HOOKS.md records as
# still-unexplained for psql/mongo. So the assertion is one-directional:
#
#   for every (gate, payload) the check-gates suite exercises, where the gate DECIDES
#   (non-empty stdout, or rc != 0), dispatch.sh must still carry that gate's decision.
#
# It reuses check-gates.sh's real payloads through that script's GATE_TRACE hook rather than
# inventing a parallel corpus that would drift from the gates it protects.
#
# IT DRIVES THE REAL dispatch.sh. An earlier version re-implemented the needle match in this
# script instead, and that was worthless twice over: it could not see a bug in dispatch.sh's
# own loop (where the tab-collapse bug lived), and its own hand-rolled matcher disagreed with
# bash on `*'\n'*`, inventing 7 "silent drops" the real dispatcher does not have. A checker
# that re-implements the thing it checks only ever tests itself. Do not reintroduce one here
# for speed -- `--fast` (trace reuse) is the supported way to make this cheap.
set -u

# Below-normal CPU priority (children inherit it): this check plus a filtered suite pushed 7
# live gates in three other sessions past their timeouts in 9 min on 2026-10-15, each a
# fail-open. CHECK_GATES_NORMAL_PRIORITY=1 keeps Normal.
if [ -z "${CHECK_GATES_NORMAL_PRIORITY:-}" ] && [ -r "/proc/$$/winpid" ]; then
  IFS= read -r _wp < "/proc/$$/winpid"
  powershell -NoProfile -Command "(Get-Process -Id $_wp).PriorityClass = 'BelowNormal'" >/dev/null 2>&1 || true
  unset _wp
fi
# Mark the run in suite-runs.log so proc-start-latency.sh never counts its load as a slow spell.
_sr_log="$HOME/.claude/harness-state/logs/suite-runs.log"
printf '%(%Y-%m-%dT%H:%M:%S)T start check-dispatch-equivalence pid=%s %s\n' -1 "$$" "$*" >> "$_sr_log" 2>/dev/null
trap '_rc=$?; printf "%(%Y-%m-%dT%H:%M:%S)T end check-dispatch-equivalence pid=%s rc=%s\n" -1 "$$" "$_rc" >> "$_sr_log" 2>/dev/null' EXIT

H="$(cd "$(dirname "$0")/.." && pwd)"
HOOKS="$H/hooks"
SHORT=pre
TRACEDIR="$HOME/.claude/scratch/dispatch-equiv"

MODE=check; TRACE=""
for a in "$@"; do
  case "$a" in
    --full)   MODE=full ;;
    --fast)   MODE=check ;;
    --mutate) MODE=mutate ;;
    --post)   SHORT=post ;;
    --pre)    SHORT=pre ;;
    *)        TRACE="$a" ;;
  esac
done
MANIFEST="$HOOKS/dispatch-$SHORT-bash.manifest"
CACHE="$HOME/.claude/harness-state/hooks/needle-cache-dispatch-$SHORT-bash.manifest.tsv"

[ -f "$MANIFEST" ] || { echo "no manifest at $MANIFEST" >&2; exit 1; }
bash "$HOOKS/build-needle-cache.sh" "$MANIFEST" "$CACHE" || exit 1

# ---------------------------------------------------------------------------- trace source
if [ -z "$TRACE" ] && [ "$MODE" != full ]; then
  TRACE="$(ls -t "$TRACEDIR"/trace-*.tsv 2>/dev/null | head -1)"
  [ -n "$TRACE" ] && echo "reusing trace $TRACE (pass --full to re-harvest)" >&2
fi
if [ -z "$TRACE" ]; then
  TRACE="$TRACEDIR/trace-$$.tsv"
  mkdir -p "$TRACEDIR"; : > "$TRACE"
  echo "harvesting payloads from check-gates.sh (full pass, ~10-12 min)..." >&2
  GATE_TRACE="$TRACE" CHECK_GATES_FULL=1 bash "$H/scripts/check-gates.sh" >/dev/null 2>&1 || true
fi
[ -s "$TRACE" ] || { echo "trace is empty -- did check-gates.sh run?" >&2; exit 1; }

reason_of() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // .reason // ""' 2>/dev/null; }

# Gates whose verdict depends on a LIVE network call are excluded from the corpus: the gate
# and the dispatcher run seconds apart against a Jira issue that can change in between, so
# the same trace gave 132/132 OK and 133/134 FAIL on consecutive runs (2026-09-22). Stubbing
# the call would test the stub. Their dispatch is covered by check-gates' own "registered"
# pins; the needle match itself is deterministic and is what this check is for.
NETWORK_GATES='ready-to-test-readiness-gate.sh'

# run_check [only-gate] -> prints "<checked> <ok> <lost> <silent> <skipped>", detail on stderr
run_check() {
  local only="${1:-}"
  local checked=0 ok=0 lost=0 silent=0 skipped=0
  local -A SEEN
  local cr=$'\r'
  local gate b64 payload g_out g_rc d_out d_rc g_reason d_reason probe key
  while IFS=$'\t' read -r gate b64; do
    gate="${gate%$cr}"; b64="${b64%$cr}"
    [ -n "${gate:-}" ] && [ -n "${b64:-}" ] || continue
    [ -n "$only" ] && [ "$gate" != "$only" ] && continue
    grep -q "	$gate	" "$MANIFEST" 2>/dev/null || { skipped=$((skipped+1)); continue; }
    case " $NETWORK_GATES " in *" $gate "*) skipped=$((skipped+1)); continue ;; esac
    key="$gate|$b64"
    [ -n "${SEEN[$key]:-}" ] && continue
    SEEN["$key"]=1

    payload="$(printf '%s' "$b64" | base64 -d 2>/dev/null)"
    [ -n "$payload" ] || continue

    # Run the gate the way THIS manifest runs it (args column): octopus-lambda-delete-gate.sh
    # is a gate in the pre manifest and `--record` in the post one, and judging the post
    # dispatch against the bare gate's deny reported two phantom drops (2026-09-18).
    g_args="$(awk -F'\t' -v g="$gate" '$2==g { print ($3=="-" ? "" : $3); exit }' "$MANIFEST" | tr -d '\r')"
    # shellcheck disable=SC2086
    g_out="$(printf '%s' "$payload" | bash "$HOOKS/$gate" $g_args 2>/dev/null)"; g_rc=$?
    if [ -z "$g_out" ] && [ "$g_rc" -eq 0 ]; then silent=$((silent+1)); continue; fi
    checked=$((checked+1))

    d_out="$(printf '%s' "$payload" | bash "$HOOKS/dispatch.sh" "$MANIFEST" 2>/dev/null)"; d_rc=$?

    if [ "$g_rc" = 2 ]; then
      if [ "$d_rc" = 2 ]; then ok=$((ok+1)); else
        lost=$((lost+1)); printf 'LOST(exit2)  %-34s dispatcher rc=%s\n' "$gate" "$d_rc" >&2
      fi
      continue
    fi

    g_reason="$(reason_of "$g_out")"
    if [ -z "$g_reason" ]; then
      if [ -n "$d_out" ]; then ok=$((ok+1)); else
        lost=$((lost+1)); printf 'LOST(ctx)    %-34s dispatcher emitted nothing\n' "$gate" >&2
      fi
      continue
    fi

    probe="$(printf '%s' "$g_reason" | head -c 60)"
    d_reason="$(reason_of "$d_out")"
    case "$d_reason" in
      *"$probe"*) ok=$((ok+1)) ;;
      *) lost=$((lost+1))
         printf 'LOST         %-34s its reason is absent from the dispatched output\n' "$gate" >&2
         printf '             payload: %s\n' "$(printf '%s' "$payload" | tr -d '\n' | head -c 130)" >&2
         ;;
    esac
  done < "$TRACE"
  printf '%s %s %s %s %s' "$checked" "$ok" "$lost" "$silent" "$skipped"
}

# -------------------------------------------------------------------------- mutation mode
# "A case that cannot fail is worse than no case" -- check-gates.sh's own rule, and the
# reason mutate-gates.sh exists. This check's whole value is catching a too-narrow needle,
# so prove it still detects one: narrow a real gate's needle to something no payload can
# match, and assert the check goes RED for that gate.
if [ "$MODE" = mutate ]; then
  victim="$(awk -F'\t' -v skip=" $NETWORK_GATES " '$4 != "@ALWAYS" && index(skip, " " $2 " ") == 0 { print $2; exit }' "$CACHE")"
  [ -n "$victim" ] || { echo "no needled gate to mutate" >&2; exit 1; }
  echo "mutating $victim's needle to something unmatchable..."
  read -r c0 o0 l0 _ _ <<EOF
$(run_check "$victim" 2>/dev/null)
EOF
  if [ "${c0:-0}" -eq 0 ]; then
    echo "SKIP -- the trace has no deciding payload for $victim, so nothing to detect." >&2
    exit 0
  fi
  cp -f "$CACHE" "$CACHE.premutate"
  awk -F'\t' -v v="$victim" 'BEGIN{OFS="\t"} $2==v { $4="*__IMPOSSIBLE_NEEDLE_ZZZ__*" } { print }' \
    "$CACHE.premutate" > "$CACHE"
  touch "$CACHE"
  read -r c1 o1 l1 _ _ <<EOF
$(run_check "$victim" 2>/dev/null)
EOF
  mv -f "$CACHE.premutate" "$CACHE"; touch "$CACHE"
  echo "  before mutation: checked=$c0 preserved=$o0 lost=$l0"
  echo "  after  mutation: checked=$c1 preserved=$o1 lost=$l1"
  if [ "${l1:-0}" -gt 0 ]; then
    echo "OK -- the check detects a narrowed needle (it can fail, so a green run means something)."
    exit 0
  fi
  echo "FAIL -- needle narrowed to an impossible pattern and the check STILL passed."
  echo "        This check cannot fail, so its green runs prove nothing. Fix it before trusting it."
  exit 1
fi

# ------------------------------------------------------------------------------ normal run
read -r checked ok lost silent skipped <<EOF
$(run_check)
EOF

echo
echo "trace:                             $TRACE"
echo "deciding pairs checked:            $checked"
echo "  decision preserved:              $ok"
echo "  DECISION LOST:                   $lost"
echo "pairs where the gate stayed silent (nothing to preserve): $silent"
echo "pairs skipped (not dispatched by this manifest, or network-dependent: $NETWORK_GATES): $skipped"
[ "${lost:-1}" -eq 0 ] || { echo; echo "FAIL -- dispatch.sh drops decisions its gates make."; exit 1; }
echo
echo "OK -- every decision the gates make survives the dispatcher."
