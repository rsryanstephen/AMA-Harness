#!/usr/bin/env bash
# Regression suite for the PreToolUse deny-gates. Feeds each gate a real payload and
# asserts its decision -- behavioural, never a source-grep for "does the file mention -i".
# A gate that can't fail is worse than no gate, and both gates here shipped with a fault
# that only an executed test surfaced (see the self-deny case below).
#
# Usage: check-gates.sh [harness-repo-root]
# Exit 0 = all asserted, 1 = at least one gate misbehaved (prints the failures).
#
# ADD A CASE whenever a gate gains or loses a match rule -- especially a FALSE-POSITIVE
# case. Both faults found so far were false positives, not missed denials.
#
# Payloads are built with `jq -n --arg`, never hand-escaped JSON: hand-escaped backslashes
# collapse in the tool-call transport and the test silently passes for the wrong reason
# (see the bash-command-style skill). Fixtures live in THIS FILE rather than inline in a
# Bash command for the same reason a quote-blind gate can't be tested inline -- a
# real-looking fixture in the command text self-triggers the gate under test.
set -u
# Run from a private COPY (2026-08-21, twice): bash reads a script lazily, so an edit to this
# file mid-run -- own or a concurrent session's -- corrupted the remaining source and the run
# died early with FAIL lines printed but exit 0. The copy is immune to later edits, and the
# EXIT trap below turns any early death into a nonzero exit.
if [ -z "${CHECK_GATES_COPY:-}" ]; then
  _cp="$(mktemp "${TMPDIR:-/tmp}/check-gates-run.XXXXXX")" && cp "${BASH_SOURCE[0]}" "$_cp" \
    && CHECK_GATES_COPY="$_cp" CHECK_GATES_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")" exec bash "$_cp" "$@"
fi
pass=0; fail=0; skip=0
trap '_rc=$?; declare -F cg_cleanup >/dev/null && cg_cleanup; printf "%(%Y-%m-%dT%H:%M:%S)T end check-gates pid=%s rc=%s\n" -1 "$$" "$_rc" >> "${_sr_log:-/dev/null}" 2>/dev/null; if [ "$_rc" -ne 0 ] || [ "${fail:-0}" -gt 0 ]; then exit 1; fi; exit 0' EXIT
. "$HOME/.claude/hooks/lib-claude-paths.sh"
# Below-normal CPU priority (children inherit it): a filtered run plus the equivalence check
# pushed 7 live gates in three other sessions past their timeouts in 9 min on 2026-10-15,
# each a fail-open. CHECK_GATES_NORMAL_PRIORITY=1 keeps Normal (timing a gate as-live).
if [ -z "${CHECK_GATES_NORMAL_PRIORITY:-}" ] && [ -r "/proc/$$/winpid" ]; then
  IFS= read -r _wp < "/proc/$$/winpid"
  powershell -NoProfile -Command "(Get-Process -Id $_wp).PriorityClass = 'BelowNormal'" >/dev/null 2>&1 || true
  unset _wp
fi
# Mark the run in suite-runs.log (end line in the EXIT trap) so scripts/proc-start-latency.sh
# never counts the load a suite causes as a slow spell. Real state dir on purpose: sections
# below repoint CLAUDE_STATE_DIR at temp trees.
_sr_log="$HOME/.claude/harness-state/logs/suite-runs.log"
# One suite at a time, machine-wide -- three overlapping runs stalled every other session's hooks
# (2026-10-22). Waits for a live holder; released from cg_cleanup. Header: lib-suite-lock.sh.
. "$HOME/.claude/scripts/lib-suite-lock.sh"; suite_lock check-gates || exit 3
printf '%(%Y-%m-%dT%H:%M:%S)T start check-gates pid=%s %s\n' -1 "$$" "$*" >> "$_sr_log" 2>/dev/null

# ---------------------------------------------------------------- gate filter (2026-09-09)
# A full run is ~451 assertions over 67 gates and takes ~10 minutes, because every assertion
# spawns a gate process and process creation costs ~60ms here (Intune Sysmon per-exec
# certificate check -- see GATES-AND-HOOKS.md's fork budget). That is 5-10k processes, so a
# run is long enough for a low-memory supervisor to kill it, and the workflow it serves
# ("touched a gate? run the suite") only ever needs one gate's cases.
#
# --gate/CHECK_GATES_ONLY is checked in the per-block guard, not just in assert(), so a
# filtered-out gate skips its whole setup too -- the mktemp trees, the 8 git clones and the
# 3 powershell.exe + Get-CimInstance launches, which are the expensive parts.
#
# Parsed BEFORE the harness="${1:-...}" line below, which would otherwise read the flag as
# the harness root. The copy-exec above forwards "$@", so the flag survives it.
ONLY="${CHECK_GATES_ONLY:-}"
if [ "${1:-}" = "--gate" ]; then ONLY="${2:-}"; shift 2
# `<tree> --gate X` (the worktree recipe reads that way) used to run the FULL suite silently --
# 36 min, rc=1, and check-gates-unfiltered-gate.sh passed it because `--gate` was present.
elif [ "${2:-}" = "--gate" ]; then ONLY="${3:-}"; set -- "$1"; fi
gates_matched=0; gates_filtered=0

# ONLY holds a SET of gate names, colon-separated. A value with no colon is one name and
# behaves exactly as the old exact-string compare did, so `--gate x` and CHECK_GATES_ONLY=x
# are untouched; run-check-gates-full.sh passes several at once to sweep only the sections
# its reminder ledger says are owed, instead of a ~10min full pass.
gate_wanted() { case ":$ONLY:" in *":$1:"*) return 0 ;; *) return 1 ;; esac; }

want_gate() {
  if [ -n "$ONLY" ] && ! gate_wanted "$1"; then
    gates_filtered=$((gates_filtered+1))
    return 1
  fi
  gates_matched=$((gates_matched+1))
  # Progress to STDERR, unbuffered and per gate. A passing run used to print nothing at all
  # until the final summary, so ten minutes of silence proved neither a hang nor an absence
  # of failures, and a killed run said nothing about how far it got.
  printf 'gate %2d: %s\n' "$gates_matched" "$1" >&2
  return 0
}

# Reached when want_gate passed but the gate file is absent; silent when merely filtered out.
skip_gate() {
  [ -z "$ONLY" ] || gate_wanted "$1" || return 0
  skip=$((skip+1)); printf 'SKIP  %s not present\n' "$1"
}

# Temp dirs are created with fixed prefixes under /tmp, so the EXIT trap cannot glob them --
# that would delete a CONCURRENT run's state, the exact hazard GATES-AND-HOOKS.md warns
# about. Record this run's own instead, and remove only those. Before this, a killed run
# leaked every one of them (~16 dirs, several of them bare git repos).
CG_TMPLIST="$(mktemp "${TMPDIR:-/tmp}/check-gates-tmplist.XXXXXX" 2>/dev/null || true)"
cgmktemp() {
  local d
  d="$(mktemp "$@")" || return 1
  [ -n "${CG_TMPLIST:-}" ] && printf '%s\n' "$d" >> "$CG_TMPLIST"
  printf '%s' "$d"
}
cg_cleanup() {
  suite_unlock 2>/dev/null
  rm -f "${CHECK_GATES_COPY:-}" 2>/dev/null
  if [ -n "${CG_TMPLIST:-}" ] && [ -f "$CG_TMPLIST" ]; then
    while IFS= read -r _d; do
      [ -n "$_d" ] && rm -rf -- "$_d" 2>/dev/null
    done < "$CG_TMPLIST"
    rm -f "$CG_TMPLIST" 2>/dev/null
  fi
}
# EXIT alone does not cover a signal in a non-interactive shell.
trap 'cg_cleanup; exit 130' INT
trap 'cg_cleanup; exit 143' TERM

# Reap orphans from runs that died WITHOUT running the trap. This is the case that matters:
# a supervisor low-memory kill is SIGKILL, which is uncatchable, so the trap above cannot
# help -- verified 2026-09-09 by killing a run and finding its temp files still present.
# Confirmed leftovers at the time: 11 stale check-gates-run/selfcheck entries.
#
# Age-bounded rather than glob-everything: a full run takes ~10 minutes, so anything older
# than an hour belongs to a dead run, while a CONCURRENT run's files are minutes old and are
# left alone. Globbing by prefix without the age test would delete a live run's state, the
# exact hazard GATES-AND-HOOKS.md warns about.
cg_reap_orphans() {
  local tdir="${TMPDIR:-/tmp}" list
  # Follow each dead run's list first, so the dirs it recorded go too.
  for list in $(find "$tdir" -maxdepth 1 -name 'check-gates-tmplist.*' -mmin +60 2>/dev/null); do
    [ -f "$list" ] || continue
    while IFS= read -r _d; do
      [ -n "$_d" ] && rm -rf -- "$_d" 2>/dev/null
    done < "$list"
    rm -f "$list" 2>/dev/null
  done
  find "$tdir" -maxdepth 1 \( -name 'check-gates-run.*' -o -name 'gatefix-*' -o -name 'selfcheck.*' \) \
    -mmin +60 -exec rm -rf -- {} + 2>/dev/null || true
}
cg_reap_orphans

harness="${1:-$(git -C "$HOME/.claude/skills" rev-parse --show-toplevel 2>/dev/null)}"
hooks="$harness/hooks"
[ -d "$hooks" ] || { printf 'check-gates.sh: cannot locate harness hooks dir (tried %s)\n' "$hooks" >&2; exit 1; }

pass=0; fail=0; skip=0

# GATE_TRACE=<file> records every (gate, payload) this suite exercises, one base64 line
# each, so scripts/check-dispatch-equivalence.sh can replay the whole corpus against
# dispatch.sh's needle prefilter instead of inventing a second set of payloads. Off unless
# the variable is set; costs nothing on a normal run.
trace_pair() {
  [ -n "${GATE_TRACE:-}" ] || return 0
  printf '%s\t%s\n' "$1" "$(printf '%s' "$2" | base64 -w0 2>/dev/null || printf '%s' "$2" | base64)" >> "$GATE_TRACE"
}

# ===================================================== per-gate timing (2026-09-21)
# A gate that reaches its dispatch timeout FAILS OPEN live (dispatch.sh rc 124) while the
# identical payload passes here, because the suite runs gates with no timeout at all --
# psql-write-gate did exactly that at 12-22s vs 15s (GATES-AND-HOOKS.md "Time a gate as part
# of testing it"). So every invocation is timed with $EPOCHREALTIME (builtin, no fork) and
# compared to the gate's OWN timeout from the dispatch manifests; a gate in neither manifest
# is not timed. Threshold = the real timeout, not a fraction: contention noise stays green,
# the psql shape goes red. One FAIL per gate per run. GATE_TIMEOUT_OVERRIDE_MS=<n> replaces
# every manifest timeout (test seam for the assertion itself; see its own case below).
declare -A _gt_to=()
_gt_file="$(mktemp)"
for _m in "$hooks"/dispatch-*.manifest; do
  [ -f "$_m" ] || continue
  while IFS=$'\t' read -r _to _g _rest; do
    _to="${_to%$'\r'}"; _g="${_g%$'\r'}"
    case "$_to" in ''|*[!0-9]*) continue ;; esac
    [ -n "$_g" ] && [ -z "${_gt_to[$_g]:-}" ] && _gt_to[$_g]="$_to"
  done < "$_m"
done
unset _m _to _g _rest
gate_timeout_of() { printf '%s' "${_gt_to[$1]:-}"; }
# Called by decide/reason_of/decide_block right after the gate returns, with the two
# $EPOCHREALTIME stamps. Those callers run inside a `$(...)` capture, so a `fail++` here never
# reached the parent: the FAIL line printed and the run still ended "0 failed", rc 0 (seen
# 2026-10-15 on a 53-minute invocation). Verdicts go to a file the summary counts; the same
# file is the one-FAIL-per-gate dedupe. Self-tests pass their own _gt_file.
gate_timing_check() {
  local gate="$1" t0="$2" t1="$3" to ms lim g
  to="${_gt_to[$gate]:-}"
  [ -n "$to" ] || return 0
  while IFS= read -r g; do [ "$g" = "$gate" ] && return 0; done < "$_gt_file"
  ms=$(( (${t1%.*} - ${t0%.*}) * 1000 + (10#${t1#*.} - 10#${t0#*.}) / 1000 ))
  lim=$(( to * 1000 )); [ -n "${GATE_TIMEOUT_OVERRIDE_MS:-}" ] && lim="$GATE_TIMEOUT_OVERRIDE_MS"
  if [ "$ms" -ge "$lim" ]; then
    printf '%s\n' "$gate" >> "$_gt_file"
    printf 'FAIL  %-46s took %dms >= its %dms dispatch timeout -- would fail OPEN live\n' "$gate" "$ms" "$lim"
  fi
}
# Self-test, suite-level (runs under any --gate filter). Subshells so the assertion's own
# output never reaches the real count; the OUTPUT line and the verdict file are what is asserted.
_gt_g=inplace-edit-gate.sh
if [ -n "${_gt_to[$_gt_g]:-}" ]; then
  _gt_out="$(_gt_file=/dev/null GATE_TIMEOUT_OVERRIDE_MS=1 gate_timing_check "$_gt_g" 1.000000 1.005000)"
  case "$_gt_out" in *"would fail OPEN live"*) pass=$((pass+1)) ;; *) fail=$((fail+1)); printf 'FAIL  %-46s want=red got=%s\n' "timing: 5ms vs 1ms override" "$_gt_out" ;; esac
  _gt_out="$(_gt_file=/dev/null gate_timing_check "$_gt_g" 1.000000 1.005000)"
  [ -z "$_gt_out" ] && pass=$((pass+1)) || { fail=$((fail+1)); printf 'FAIL  %-46s got=%s\n' "timing: 5ms vs manifest, green" "$_gt_out"; }
  _gt_out="$(_gt_file=/dev/null GATE_TIMEOUT_OVERRIDE_MS=1 gate_timing_check no-such-gate-in-manifest.sh 1.000000 9.000000)"
  [ -z "$_gt_out" ] && pass=$((pass+1)) || { fail=$((fail+1)); printf 'FAIL  %-46s got=%s\n' "timing: unmanifested gate not timed" "$_gt_out"; }
  # The verdict must survive the capture (recorded once), and a second miss on the same gate is silent.
  _gt_tmp="$(mktemp)"
  _gt_out="$(_gt_file="$_gt_tmp" GATE_TIMEOUT_OVERRIDE_MS=1 gate_timing_check "$_gt_g" 1.000000 1.005000)"
  [ "$(cat "$_gt_tmp")" = "$_gt_g" ] && pass=$((pass+1)) || { fail=$((fail+1)); printf 'FAIL  %-46s got=%s\n' "timing: verdict recorded across the capture" "$(cat "$_gt_tmp")"; }
  _gt_out="$(_gt_file="$_gt_tmp" GATE_TIMEOUT_OVERRIDE_MS=1 gate_timing_check "$_gt_g" 1.000000 1.005000)"
  [ -z "$_gt_out" ] && [ "$(wc -l < "$_gt_tmp")" -eq 1 ] && pass=$((pass+1)) || { fail=$((fail+1)); printf 'FAIL  %-46s got=%s\n' "timing: one FAIL per gate per run" "$_gt_out"; }
  rm -f "$_gt_tmp"; unset _gt_tmp
else
  fail=$((fail+1)); printf 'FAIL  %-46s\n' "timing: $_gt_g missing from dispatch manifests"
fi
unset _gt_g _gt_out

# decide <gate-file> <payload-json> -> prints "deny" | "allow" | "pass"
decide() {
  local raw _t0 _t1
  trace_pair "$1" "$2"
  _t0=$EPOCHREALTIME
  raw="$(printf '%s' "$2" | bash "$hooks/$1" 2>/dev/null)"
  _t1=$EPOCHREALTIME; gate_timing_check "$1" "$_t0" "$_t1" >&2
  if [ -z "$raw" ]; then printf 'pass'; return; fi
  printf '%s' "$raw" | jq -r '.hookSpecificOutput.permissionDecision // "pass"' 2>/dev/null || printf 'pass'
}

assert() {
  local desc="$1" gate="$2" expect="$3" payload="$4" got
  got="$(decide "$gate" "$payload")"
  if [ "$got" = "$expect" ]; then
    pass=$((pass+1))
  else
    fail=$((fail+1))
    printf 'FAIL  %-46s want=%-5s got=%s\n' "$desc" "$expect" "$got"
  fi
}

bash_payload() { jq -n --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'; }

# ===================================================== reason assertions
# The suite asserted DECISIONS only, and that was a real hole: bare-cd-gate.sh shipped a
# correct deny with the WRONG REASON (it told the reader a compound cd to the session's own
# home "leaks cwd forward", which is false -- the target IS cwd; it's denied because Claude
# Code can't statically resolve a cd-compound and so won't delegate to the classifier). A
# decision-only case cannot see that. Use this wherever a gate has branch-specific reasons.
#
# DEFINED HERE, above every gate section, because it was defined ~480 lines BELOW its first
# caller: check-gates-unfiltered-gate.sh's two assert_reason cases died with
# "assert_reason: command not found" on stderr and simply never asserted, while the suite
# still reported green. Exactly the "a case that cannot fail is worse than no case" failure
# the mutation tester exists to catch -- found 2026-09-14 only because a scoped sweep put
# that section's output where someone read it. Keep every shared helper above line ~150.
reason_of() {
  local raw _t0 _t1
  trace_pair "$1" "$2"
  _t0=$EPOCHREALTIME
  raw="$(printf '%s' "$2" | bash "$hooks/$1" 2>/dev/null)"
  _t1=$EPOCHREALTIME; gate_timing_check "$1" "$_t0" "$_t1" >&2
  [ -n "$raw" ] || { printf ''; return; }
  # PreToolUse gates put the reason in hookSpecificOutput; PostToolUse gates
  # (readme-currency-gate) emit {decision:"block", reason} -- read both shapes.
  printf '%s' "$raw" | jq -r '.hookSpecificOutput.permissionDecisionReason // .reason // ""' 2>/dev/null
}
assert_reason() {
  local desc="$1" gate="$2" want="$3" payload="$4" got
  got="$(reason_of "$gate" "$payload")"
  if printf '%s' "$got" | grep -qiE "$want"; then pass=$((pass+1)); else
    fail=$((fail+1)); printf 'FAIL  %-46s want-reason=/%s/ got=%s\n' "$desc" "$want" "$(printf '%s' "$got" | head -c 60)"
  fi
}

# ---------------------------------------------------------------- inplace-edit-gate.sh
G=inplace-edit-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  CL='$HOME/.claude'
  assert "sed -i on a harness symlink"      "$G" deny "$(bash_payload "sed -i 's/a/b/' $CL/harness-gaps.md")"
  # sed/perl were never the only unlinkers. harness-gaps.md was found detached TWICE on
  # 2026-09-01 (09:47, 11:06) with the sed/perl route already gated -- so something else
  # did it, and a sweep of every unlinking shape found `mv` over the link and `rm` of it
  # ungated by all four ~/.claude gates. Only paths that ARE links deny, so the routine
  # hstate/hscratch shapes below stay allowed.
  assert "mv over a harness symlink"        "$G" deny "$(bash_payload "mv /tmp/new.md $CL/harness-gaps.md")"
  assert "rm a harness symlink"             "$G" deny "$(bash_payload "rm $CL/harness-gaps.md && printf x > $CL/harness-gaps.md")"
  assert "rm a harness-state file"          "$G" pass "$(bash_payload "rm $CL/harness-state/notices/.foo")"
  assert "mv into scratch"                  "$G" pass "$(bash_payload "mv /tmp/x.md $CL/scratch/diag/x.md")"
  # The safe half: these open THROUGH a link and leave it intact. CLAUDE.md tells every
  # session to append its gap line with `>> ~/.claude/harness-gaps.md`, so a deny here
  # would break the harness's own documented instruction.
  assert "append >> through a symlink"      "$G" pass "$(bash_payload "printf x >> $CL/harness-gaps.md")"
  assert "sed --in-place"                   "$G" deny "$(bash_payload "sed --in-place 's/a/b/' $CL/AGENTS.md")"
  assert "sed -i.bak (suffix form)"         "$G" deny "$(bash_payload "sed -i.bak 's/a/b/' $CL/CLAUDE.md")"
  assert "perl -i"                          "$G" deny "$(bash_payload "perl -i -pe 's/a/b/' $CL/settings.json")"
  assert "chained after &&"                 "$G" deny "$(bash_payload "echo hi && sed -i 's/a/b/' $CL/x.md")"
  assert "chained after ;"                  "$G" deny "$(bash_payload "date ; sed -i 's/a/b/' $CL/x.md")"
  # Bundled -i: the classic in-place perl idioms. Both PASSED the gate until 2026-08-18 --
  # the old pattern wanted a bare `-i`, so `-pi` slipped through the one thing it guards.
  assert "perl -pi (bundled)"               "$G" deny "$(bash_payload "perl -pi -e 's/a/b/' $CL/AGENTS.md")"
  assert "perl -npi.bak (bundled + suffix)" "$G" deny "$(bash_payload "perl -npi.bak -e 's/a/b/' $CL/AGENTS.md")"
  # `|` sed delimiter split the segment, path landed outside it -> passed (2026-10-12 detach).
  assert "sed -i with | delimiter"          "$G" deny "$(bash_payload "sed -i 's|a b|c d|' $CL/harness-gaps.md")"
  assert "sed -n with | delimiter"          "$G" pass "$(bash_payload "sed -n 's|a|b|p' $CL/AGENTS.md")"

  assert "sed -n is read-only"              "$G" pass "$(bash_payload "sed -n '1,5p' $CL/AGENTS.md")"
  # False positive: `-i` inside a FILENAME word (`edit-issue`), not a flag. Denied a
  # read-only `sed -n` on a real harness script path.
  assert "sed -n, path contains -i in word" "$G" pass "$(bash_payload "sed -n '1,25p' $CL/skills/ama-jira-api/scripts/jira-edit-issue.sh")"
  assert "grep -i is not an edit"           "$G" pass "$(bash_payload "grep -i foo $CL/AGENTS.md")"
  assert "sed -i outside the harness"       "$G" pass "$(bash_payload "sed -i 's/a/b/' /tmp/x.txt")"
  assert "cat"                              "$G" pass "$(bash_payload "cat $CL/harness-gaps.md")"
  assert "piped sed with no -i"             "$G" pass "$(bash_payload "cat $CL/AGENTS.md | sed 's/a/b/'")"
  assert "recursive grep"                   "$G" pass "$(bash_payload "grep -rn foo $CL/skills/")"
  # The in-place edit and the .claude path must sit in the SAME simple command. A `perl -0pi`
  # on a REPO path was denied because `~/.claude` appeared in a sibling command, and so was
  # the `>>` appending the ledger line that described it (2026-09-18).
  assert "sed -i on a repo path, .claude elsewhere" "$G" pass "$(bash_payload "perl -0pi -e 's/a/b/' /c/Users/x/Repos/AMA_APP/ama-claude-harness/scripts/foo.sh && echo $CL/harness-gaps.md")"
  assert "append mentioning sed -i in its text"    "$G" pass "$(bash_payload "printf -- '- gate refused perl -0pi on %s' x >> $CL/harness-gaps.md")"

  # THE regression: the gate's own first version denied its own commit, because the message
  # DESCRIBES the hazard and a quote-blind matcher can't tell prose from an invocation.
  # Heredoc bodies are data; only the region before the first `<<` is measured.
  assert "heredoc body merely describing sed -i" "$G" pass "$(bash_payload "git commit -F - <<EOF
denies sed -i / perl -i against a $CL path, because sed -i renames over the symlink
EOF")"
else
  skip_gate "$G"
fi

# ----------------------------------------------------------- shell-write-bypass-gate.sh
# Sibling of inplace-edit-gate.sh above, different trigger and different hazard: that one
# guards ~/.claude paths against SYMLINK DESTRUCTION, this one guards any path a deny-class
# content gate covers against the gate never running at all. A shell write fires no
# Edit|Write hook, and auto mode actively prefers shell writes -- so skill-bloat-gate.sh
# et al were bypassable by default (<harnessEpicKey>, confirmed live 2026-08-31).
G=shell-write-bypass-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  # CL is also set in inplace-edit-gate's section, INSIDE its want_gate block -- so under a
  # `--gate shell-write-bypass-gate.sh` filter it was empty and the two ~/.claude cases below
  # degraded to `/skills/x/SKILL.md`, a correct pass, reported as FAIL (2026-09-15, twice).
  CL='$HOME/.claude'
  assert "perl -i on a repo skill"          "$G" deny "$(bash_payload "perl -i -pe 's/a/b/' skills/<amaSupportChannelName>-notices/SKILL.md")"
  assert "sed -i on a repo skill"           "$G" deny "$(bash_payload "sed -i 's/a/b/' skills/x/SKILL.md")"
  assert "sed -i on CLAUDE.md"              "$G" deny "$(bash_payload "sed -i 's/a/b/' CLAUDE.md")"
  # Redirects are the OTHER half of the bypass, and the half that already bit us:
  # standup-empty-section-gate.sh's own header records the run writing its file by
  # redirect, so the gate never fired on the one path that executes every morning.
  assert "heredoc redirect onto a skill"    "$G" deny "$(bash_payload "cat > skills/x/SKILL.md <<EOF")"
  assert "append redirect onto a skill"     "$G" deny "$(bash_payload "printf '%s' \"\$x\" >> skills/x/SKILL.md")"
  assert "tee onto a skill"                 "$G" deny "$(bash_payload "printf '%s' \"\$x\" | tee skills/x/SKILL.md")"
  assert "redirect onto standup notes"      "$G" deny "$(bash_payload "printf hi >> \$HOME/standup-notes-2026-09-01.md")"
  assert "redirect into native memory"      "$G" deny "$(bash_payload "echo x > \$HOME/.claude/projects/foo/memory/bar.md")"
  assert "absolute path to a skill"         "$G" deny "$(bash_payload "sed -i 's/a/b/' $CL/skills/x/SKILL.md")"
  # A ~/.claude path that IS a link maps to symlink-write-gate.sh. Belt-and-braces with
  # inplace-edit-gate.sh above (which owns this hazard); kept because the two disagree
  # about command position, and a second gate naming the right owner costs nothing.
  # The `.claude/` prefilter needle is what makes this reachable at all -- none of the
  # original needles (skills/, SKILL.md, CLAUDE.md, standup-notes-, /memory/) match a
  # lowercase `.claude/harness-gaps.md`, so the whole class was invisible to this gate.
  assert "sed -i on a linked ~/.claude file" "$G" deny "$(bash_payload "sed -i 's/a/b/' $CL/harness-gaps.md")"
  assert "append into a linked ~/.claude file" "$G" pass "$(bash_payload "printf x >> $CL/harness-gaps.md")"
  assert "redirect into harness-state"      "$G" pass "$(bash_payload "printf x > $CL/harness-state/notices/.foo")"

  assert "unrelated redirect"               "$G" pass "$(bash_payload "echo hi > /tmp/scratch.txt")"
  assert "sed -n on a skill is read-only"   "$G" pass "$(bash_payload "sed -n '1,25p' skills/x/SKILL.md")"
  # Same `-i`-inside-a-word trap inplace-edit-gate.sh documents above; a flag must be a
  # real token, and a plain read must never match however the path is spelled.
  assert "grep -i on a skill"               "$G" pass "$(bash_payload "grep -i pattern skills/x/SKILL.md")"
  assert "cat a skill"                      "$G" pass "$(bash_payload "cat skills/x/SKILL.md")"
  assert "AGENTS.md is NOT covered"         "$G" pass "$(bash_payload "sed -i 's/a/b/' AGENTS.md")"
  # Segment isolation: a write in one simple command must not condemn a protected path
  # merely READ in another.
  assert "write and read in diff segments"  "$G" pass "$(bash_payload "sed -i 's/a/b/' notes.txt && cat skills/x/SKILL.md")"
  assert "escape hatch"                     "$G" pass "$(bash_payload "HARNESS_BULK_EDIT=1 perl -i -pe 's/a/b/' skills/x/SKILL.md")"
  # Write shape 3 (2026-10-05): an interpreter writing the skill from code, the body in a
  # heredoc where no redirect/-i shape can see it. The 2026-09-22 bypass.
  assert "python heredoc writing a skill"   "$G" deny "$(bash_payload "python - <<'PY'
p='skills/x/SKILL.md'
open(p,'w').write(open(p).read().replace('a','b'))
PY")"
  assert "node -e writeFileSync onto a skill" "$G" deny "$(bash_payload "node -e \"require('fs').writeFileSync('skills/x/SKILL.md', 'x')\"")"
  assert "python read of a skill, no write verb" "$G" pass "$(bash_payload "python -c \"print(len(open('skills/x/SKILL.md').read()))\"")"
  assert "python writing an unprotected file" "$G" pass "$(bash_payload "python -c \"open('/tmp/out.txt','w').write('x')\"")"
  # Same self-deny trap as inplace-edit-gate.sh's own first commit: prose describing the
  # hazard is data, not an invocation.
  assert "heredoc body describing the rule" "$G" pass "$(bash_payload "git commit -F - <<EOF
denies a shell write like sed -i on skills/x/SKILL.md because skill-bloat-gate.sh cannot see it
EOF")"
else
  skip_gate "$G"
fi

# ---------------------------------------------------------- running-script-edit-gate.sh
# Bash|PowerShell leg. This branch was written from the start but the gate was registered
# under Edit|Write ONLY, so it had never once executed (found 2026-09-01 while mapping the
# bypass above). A gate moved from "never runs" to "runs, untested" is no better, so the
# deny case spawns a REAL live interpreter to assert against rather than only pinning the
# negatives -- proving the branch denies, not merely that it loads.
G=running-script-edit-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  _live="$(mktemp "${TMPDIR:-/tmp}/check-gates-live.XXXXXX.sh")"
  printf '#!/usr/bin/env bash\nsleep 60\n' > "$_live"
  bash "$_live" & _live_pid=$!
  sleep 2
  assert "in-place on a RUNNING script"     "$G" deny "$(bash_payload "sed -i 's/a/b/' $_live")"
  kill "$_live_pid" 2>/dev/null; wait "$_live_pid" 2>/dev/null
  rm -f "$_live"

  assert "in-place on a non-running script" "$G" pass "$(bash_payload "sed -i 's/a/b/' /tmp/definitely-not-running-$$.sh")"
  assert "in-place on a non-script file"    "$G" pass "$(bash_payload "sed -i 's/a/b/' /tmp/notes-$$.txt")"
  # 2026-10-21: the edited .mjs, not the running script named later in the same call.
  _live="$(mktemp "${TMPDIR:-/tmp}/check-gates-live.XXXXXX.sh")"
  printf '#!/usr/bin/env bash\nsleep 60\n' > "$_live"
  bash "$_live" & _live_pid=$!
  sleep 2
  assert "sed -i x.mjs then run a live script"  "$G" pass "$(bash_payload "sed -i 's/a/b/' /tmp/v-$$.mjs && bash $_live --script /tmp/v-$$.mjs")"
  assert "sed -i a live script then run other"  "$G" deny "$(bash_payload "sed -i 's/a/b/' $_live && bash /tmp/other-$$.sh")"
  kill "$_live_pid" 2>/dev/null; wait "$_live_pid" 2>/dev/null
  rm -f "$_live"
else
  skip_gate "$G"
fi

# ------------------------------------------------------------- confluence-media-gate.sh
G=confluence-media-gate.sh
CONFIG="$HOME/.claude/harness-config.json"
protected=""
[ -f "$CONFIG" ] && protected="$(jq -r '.atlassian.pagesWithNestedMedia[0]? // empty' < "$CONFIG" 2>/dev/null | tr -d '\r')"
if ! want_gate "$G"; then
  : # filtered out
elif [ ! -f "$hooks/$G" ]; then
  skip_gate "$G"
elif [ -z "$protected" ]; then
  # Correct for an adopter with no such page -- the gate is inert by design, so asserting
  # a deny here would fail for the wrong reason. Say so rather than silently passing.
  skip=$((skip+1)); printf 'SKIP  %s: .atlassian.pagesWithNestedMedia is empty (gate inert)\n' "$G"
else
  cpage() { jq -n --arg p "$1" --arg f "$2" \
    '{tool_name:"mcp__claude_ai_Atlassian__updateConfluencePage",tool_input:{pageId:$p,contentFormat:$f}}'; }
  assert "html write to a nested-media page"  "$G" deny "$(cpage "$protected" html)"
  assert "adf write to the same page"         "$G" pass "$(cpage "$protected" adf)"
  assert "html write to an unlisted page"     "$G" pass "$(cpage "0000000000" html)"
  # Wrong tool on the same matcher family must not be touched.
  assert "getConfluencePage is not a write"   "$G" pass "$(jq -n --arg p "$protected" \
    '{tool_name:"mcp__claude_ai_Atlassian__getConfluencePage",tool_input:{pageId:$p,contentFormat:"html"}}')"
fi

# ---------------------------------------------------------------- slack-brevity-gate.sh
G=slack-brevity-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  slack() { jq -n --arg t "$1" --arg m "$2" '{tool_name:$t,tool_input:{message:$m}}'; }
  # Name predates the 120->150 default raise (2026-10-22); now 160 words, still over it.
  LONG130="$(awk 'BEGIN{for(i=1;i<=160;i++) printf "word%d ", i}')"
  assert "130 prose words"                  "$G" deny "$(slack mcp__claude_ai_Slack__slack_send_message "$LONG130")"
  assert "130 words via the draft tool"     "$G" deny "$(slack mcp__claude_ai_Slack__slack_send_message_draft "$LONG130")"

  assert "a short message"                  "$G" pass "$(slack mcp__claude_ai_Slack__slack_send_message \
    "Reviewer Two - six Azure ranges on 80/443 arent LogicMonitor. Any idea what runs there? PROJ-15314.")"
  # Pasting data is not wordiness: a fenced block of 130 tokens must not trip the gate.
  assert "130 words inside a code fence"    "$G" pass "$(slack mcp__claude_ai_Slack__slack_send_message \
    "$(printf '```\n%s\n```\n' "$LONG130")")"
  assert "long message, non-Slack tool"     "$G" pass "$(jq -n --arg m "$LONG130" \
    '{tool_name:"Write",tool_input:{message:$m}}')"
  # rule 3: self-DM must @-mention the user (2026-10-16). Config seamed via HR_CONFIG_FILE.
  SDCFG="$(cgmktemp "${TMPDIR:-/tmp}/gatefix-selfdm.XXXXXX")"
  printf '%s' '{"user":{"slackUserId":"U0SELF0001","slackSelfDmChannelId":"D0SELF0001"}}' > "$SDCFG"
  sdm() { jq -n --arg t "$1" --arg c "$2" --arg m "$3" '{tool_name:$t,tool_input:{channel_id:$c,message:$m}}'; }
  _sd_hc="${HR_CONFIG_FILE-}"; export HR_CONFIG_FILE="$SDCFG"
  assert        "self-DM (U-id), no mention"         "$G" deny "$(sdm mcp__claude_ai_Slack__slack_send_message U0SELF0001 'PR review: clean')"
  assert_reason "  ...reason names the mention"      "$G" '<@U0SELF0001>' "$(sdm mcp__claude_ai_Slack__slack_send_message U0SELF0001 'PR review: clean')"
  assert        "self-DM (D-id), no mention"         "$G" deny "$(sdm mcp__claude_ai_Slack__slack_schedule_message D0SELF0001 'PR review: clean')"
  assert        "self-DM with mention"               "$G" pass "$(sdm mcp__claude_ai_Slack__slack_send_message U0SELF0001 "$(printf '<@U0SELF0001>\n\nPR review: clean')")"
  assert        "self-DM draft, no mention"          "$G" pass "$(sdm mcp__claude_ai_Slack__slack_send_message_draft U0SELF0001 'PR review: clean')"
  assert        "DM to someone else, no mention"     "$G" pass "$(sdm mcp__claude_ai_Slack__slack_send_message U0OTHER001 'PR review: clean')"
  # A leading mention line must not knock the support triage header off its raised ceiling.
  assert        "mention + support header, 130 words" "$G" pass "$(sdm mcp__claude_ai_Slack__slack_send_message U0SELF0001 "$(printf '<@U0SELF0001>\n\nSupport notification triage:\n%s' "$LONG130")")"
  # DM to the user themselves: no word limit (2026-10-22); a DM to anyone else keeps it.
  W600="$(awk 'BEGIN{for(i=1;i<=600;i++) printf "word%d ", i}')"
  assert        "self-DM with mention, 600 words"     "$G" pass "$(sdm mcp__claude_ai_Slack__slack_send_message U0SELF0001 "$(printf '<@U0SELF0001>\n\n%s' "$W600")")"
  assert        "self-DM draft (D-id), 600 words"     "$G" pass "$(sdm mcp__claude_ai_Slack__slack_send_message_draft D0SELF0001 "$W600")"
  assert        "self-DM 600 words, no mention"       "$G" deny "$(sdm mcp__claude_ai_Slack__slack_send_message U0SELF0001 "$W600")"
  assert        "other DM with mention, 160 words"    "$G" deny "$(sdm mcp__claude_ai_Slack__slack_send_message U0OTHER001 "$(printf '<@U0SELF0001>\n\n%s' "$LONG130")")"
  W150="$(awk 'BEGIN{for(i=1;i<=150;i++) printf "word%d ", i}')"
  assert        "other DM, exactly 150 words"         "$G" pass "$(sdm mcp__claude_ai_Slack__slack_send_message U0OTHER001 "$W150")"
  if [ -n "$_sd_hc" ]; then export HR_CONFIG_FILE="$_sd_hc"; else unset HR_CONFIG_FILE; fi
  rm -f "$SDCFG"

  # A stand-up note earns a raised 320-word ceiling (recipients lack the context the
  # normal rule says to drop; raised 250->320 2026-08-25 for the new Client
  # mail/Decisions blocks). Keyed off its mandated opening line, so both the boundary
  # AND the first-line anchor need pinning -- an unanchored match would hand every long
  # message the higher limit.
  SU_HDR='Updates from me:'
  # The header itself counts 3 words (Updates/from/me:), so body counts are 317/318 to
  # land exactly on 320 and 321. Measured, not assumed -- an earlier header form was
  # assumed to cost 1 and actually cost 2, and this suite caught it.
  SU317="$(awk 'BEGIN{for(i=1;i<=317;i++) printf "word%d ", i}')"
  SU318="$(awk 'BEGIN{for(i=1;i<=318;i++) printf "word%d ", i}')"
  assert "standup header, 320 words"        "$G" pass "$(slack mcp__claude_ai_Slack__slack_send_message \
    "$(printf '%s\n%s\n' "$SU_HDR" "$SU317")")"
  assert "standup header, 321 words"        "$G" deny "$(slack mcp__claude_ai_Slack__slack_send_message \
    "$(printf '%s\n%s\n' "$SU_HDR" "$SU318")")"
  # Bold-wrapped and colon-less forms of the same line still count as the header.
  assert "standup header, bold wrapped"     "$G" pass "$(slack mcp__claude_ai_Slack__slack_send_message \
    "$(printf '*Updates from me:*\n%s\n' "$SU317")")"
  # A configurable per-audience greeting sits ABOVE the header -- with and without a
  # blank line between. Both must still earn the raised ceiling. The greeting itself costs
  # 3 words (Hi/Reviewer Two,/Reviewer One) so the body drops to 314 to total exactly 320: sized on purpose,
  # because at 323 the case would deny under BOTH ceilings and prove nothing about whether
  # the header was matched at all.
  SU314="$(awk 'BEGIN{for(i=1;i<=314;i++) printf "word%d ", i}')"
  assert "greeting then header"             "$G" pass "$(slack mcp__claude_ai_Slack__slack_send_message \
    "$(printf '<team>\n%s\n%s\n' "$SU_HDR" "$SU314")")"
  assert "greeting, blank, then header"     "$G" pass "$(slack mcp__claude_ai_Slack__slack_send_message \
    "$(printf '<team>\n\n%s\n%s\n' "$SU_HDR" "$SU314")")"
  # The 3-line scan is the whole allowance (greeting + blank + header), so line 3 legitimately
  # passes -- "Morning all" is indistinguishable from a configured greeting. Line 4 must NOT,
  # or any long message could bury the token and claim the ceiling.
  assert "standup header buried line 4"     "$G" deny "$(slack mcp__claude_ai_Slack__slack_send_message \
    "$(printf 'Morning all\n\nsome preamble\n%s\n%s\n' "$SU_HDR" "$LONG130")")"
  # Matched whole: the phrase leading into other prose is not the header.
  assert "header phrase mid-sentence"       "$G" deny "$(slack mcp__claude_ai_Slack__slack_send_message \
    "$(printf 'Updates from me: here is the long one\n%s\n' "$LONG130")")"

  # ama-team-meeting-notes' unattended send earns its own raised ceiling (LIMIT_TEAM_MEETING),
  # same content-shape pattern as standup's. Header is `*Team meeting notes*`, which the
  # gate's own word-splitter counts as 3 tokens ("*Team"/"meeting"/"notes*") -- same as
  # standup's bold-wrapped header case above. Body sizes are MEASURED against that 3, not
  # assumed, per this suite's own standing lesson (SU317/SU318's comment).
  TM_HDR='*Team meeting notes*'
  TM477="$(awk 'BEGIN{for(i=1;i<=477;i++) printf "word%d ", i}')"
  TM478="$(awk 'BEGIN{for(i=1;i<=478;i++) printf "word%d ", i}')"
  assert "team-meeting header, 480 words"   "$G" pass "$(slack mcp__claude_ai_Slack__slack_send_message \
    "$(printf '%s\n%s\n' "$TM_HDR" "$TM477")")"
  assert "team-meeting header, 481 words"   "$G" deny "$(slack mcp__claude_ai_Slack__slack_send_message \
    "$(printf '%s\n%s\n' "$TM_HDR" "$TM478")")"
  # Same anchor rule as standup's buried-header case: past the first-3-line allowance, the
  # header does not count and the message falls back to the plain 120 default.
  assert "team-meeting header buried line 4" "$G" deny "$(slack mcp__claude_ai_Slack__slack_send_message \
    "$(printf 'Morning\n\nsome preamble\n%s\n%s\n' "$TM_HDR" "$LONG130")")"
  # Support-triage DM ceiling, 400 (raised from 250 2026-10-15). Header = 3 tokens, so
  # 397/398 body words land on 400/401. Line-1 anchor only: a leading blank line drops it.
  ST_HDR='Support notification triage:'
  ST397="$(awk 'BEGIN{for(i=1;i<=397;i++) printf "word%d ", i}')"
  ST398="$(awk 'BEGIN{for(i=1;i<=398;i++) printf "word%d ", i}')"
  assert "support header, 400 words"        "$G" pass "$(slack mcp__claude_ai_Slack__slack_send_message \
    "$(printf '%s\n%s\n' "$ST_HDR" "$ST397")")"
  assert "support header, 401 words"        "$G" deny "$(slack mcp__claude_ai_Slack__slack_send_message \
    "$(printf '%s\n%s\n' "$ST_HDR" "$ST398")")"
  assert "support header not on line 1"     "$G" deny "$(slack mcp__claude_ai_Slack__slack_send_message \
    "$(printf '\n%s\n%s\n' "$ST_HDR" "$LONG130")")"
  # Plain 130-word default-ceiling denial is already covered verbatim by "130 prose words"
  # above -- not duplicated here, a copy of the same fixture proves nothing new.

  # Rule 2: an address LIST needs per-item backticks -- Slack chips them separately.
  assert "bare list of 6 addresses"         "$G" deny "$(slack mcp__claude_ai_Slack__slack_send_message \
    "Reviewer Two - it held six Azure ranges: 20.42.35.32/28 .64/28 .80/28 .96/28 .112/28 .128/28. Any idea?")"
  # ONE span around the whole list is the same defect wearing backticks: one wide chip.
  assert "one span wraps the whole list"    "$G" deny "$(slack mcp__claude_ai_Slack__slack_send_message \
    'Ranges: `20.42.35.32/28 .64/28 .80/28 .96/28 .112/28`')"
  assert "each address backticked"          "$G" pass "$(slack mcp__claude_ai_Slack__slack_send_message \
    'Ranges: `20.42.35.32/28`  `.64/28`  `.80/28`  `.96/28`  `.112/28`  `.128/28`. Any idea?')"
  # Scoped to lists: prose mentions and a lone resource id must not be caught.
  assert "two bare addresses in prose"      "$G" pass "$(slack mcp__claude_ai_Slack__slack_send_message \
    "The ELB resolved to 3.211.43.34 and 3.232.204.239, both healthy.")"
  assert "lone sg- id, un-backticked"       "$G" pass "$(slack mcp__claude_ai_Slack__slack_send_message \
    "The Logic Monitor group (sg-def080a9) also held six ranges - any idea?")"
  assert "bare list inside a code fence"    "$G" pass "$(slack mcp__claude_ai_Slack__slack_send_message \
    "$(printf 'Ranges:\n```\n20.42.35.32/28 .64/28 .80/28 .96/28\n```\n')")"
else
  skip_gate "$G"
fi

# slack-signature-gate.sh RETIRED 2026-08-25 (<harnessEpicKey>): its premise (headless
# never gets Slack's auto-footer, interactive does) was empirically false -- controlled
# tests showed Slack/the connector auto-adds the footer in BOTH modes, unreliably
# (headless 2/3, interactive 2/2). Typing it manually now mostly guarantees a visible
# duplicate instead of occasionally preventing a missing one. See harness-gaps.md.

# ============================================================ shared payload builders
# bash_payload() above sets only tool_name+command. Several gates resolve the session's home
# directory or repo from `cwd`/`session_id` and FAIL OPEN without them -- a case built with the
# bare builder would pass for the wrong reason. Hence explicit builders.
bash_payload_cwd() { jq -n --arg c "$1" --arg d "$2" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}'; }
bash_payload_sid() { jq -n --arg c "$1" --arg d "$2" --arg s "$3" '{tool_name:"Bash",cwd:$d,session_id:$s,tool_input:{command:$c}}'; }
# PostToolUse shape: the command plus what it printed.
resp_payload()     { jq -n --arg c "$1" --arg r "$2" '{tool_name:"Bash",hook_event_name:"PostToolUse",tool_input:{command:$c},tool_response:{stdout:$r,stderr:""}}'; }
write_payload()    { jq -n --arg p "$1" --arg t "$2" '{tool_name:"Write",tool_input:{file_path:$p,content:$t}}'; }
edit_payload()     { jq -n --arg p "$1" --arg t "$2" '{tool_name:"Edit",tool_input:{file_path:$p,new_string:$t}}'; }
agent_payload()    { jq -n --arg p "$1" --argjson m "$2" '{tool_name:"Agent",tool_input:({prompt:$p}+$m)}'; }
mcp_payload()      { jq -n --arg t "$1" --argjson f "$2" '{tool_name:$t,tool_input:$f}'; }
skill_payload()    { jq -n --arg s "$1" '{tool_name:"Skill",tool_input:{skill:$s}}'; }

HARNESS_CWD="$harness"

# ------------------------------------------------------------ unanalyzable-script-gate.sh
# All four rules, each with the false-positive case that constrains it. Rules 2-4 were each
# added after a shape slipped past the previous ones and cost a real permission prompt.
G=unanalyzable-script-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  assert "one-line for loop"                 "$G" deny "$(bash_payload 'for k in a b; do echo "$k"; done')"
  assert "multi-line while loop"             "$G" deny "$(bash_payload 'x=1
while read -r l; do echo "$l"; done < f')"
  assert "multi-line -m commit message"      "$G" deny "$(bash_payload 'git commit -q -m "subject

body line" -- a.md')"
  assert "unresolvable ALL-CAPS env ref"     "$G" deny "$(bash_payload 'curl -sS -u "me:$ATLASSIAN_API_TOKEN" https://example.internal/x')"
  assert "braced env ref"                    "$G" deny "$(bash_payload 'echo "${OCTOPUS_API_KEY:+set}"')"

  # Prescribed forms and idioms that MUST stay allowed -- these are the constraints.
  assert "heredoc commit body (prose 'if')"   "$G" pass "$(bash_payload "git commit -F - -- a.md <<'EOF'
PROJ-1: subject
if this breaks, for real, revert it
EOF")"
  assert "single-line if/then/fi"             "$G" pass "$(bash_payload 'if [ -f /etc/hosts ]; then echo yes; fi')"
  assert "jq program with \$p is not a shell var" "$G" pass "$(bash_payload "jq -r 'paths(scalars) as \$p | (\$p|join(\".\"))' f.json")"
  assert "\$HOME is resolvable"               "$G" pass "$(bash_payload 'ls -la "$HOME/.claude/hooks" | head -3')"
  assert "prose containing done and for"      "$G" pass "$(bash_payload 'echo "done deal, for the record"')"
  assert "multi-line, no ctrl flow or span"   "$G" pass "$(bash_payload 'echo one; echo two
printf "%s\n" three')"
else
  skip_gate "$G"
fi

# -------------------------------------------------------------------- short-path-gate.sh
G=short-path-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  assert "8.3 user-profile segment"          "$G" deny "$(bash_payload 'ls "C:/Users/RYAN~1.STE/AppData/Local/Temp"')"
  assert "8.3 PROGRA~1 segment"              "$G" deny "$(bash_payload 'ls "C:/PROGRA~1/Git/bin"')"
  # Git revisions and ~ home expansion share the tilde but are not 8.3 segments. The pattern
  # requires a trailing path separator precisely so these stay allowed.
  assert "git HEAD~1"                        "$G" pass "$(bash_payload 'git diff HEAD~1 --stat')"
  assert "git HEAD~1..HEAD range"            "$G" pass "$(bash_payload 'git log HEAD~1..HEAD --oneline')"
  assert "~/ home expansion"                 "$G" pass "$(bash_payload 'ls ~/.claude/hooks | head -3')"
  assert "long-form path"                    "$G" pass "$(bash_payload 'ls "C:/Users/your.windows.username/AppData/Local/Temp"')"
else
  skip_gate "$G"
fi

# ------------------------------------------------------------------ background-pipe-gate.sh
# Needs the run_in_background FLAG in tool_input, which no other gate reads -- the plain builders
# don't set it, so a case built with bash_payload passes vacuously. The whole rule is the
# COMBINATION: a foreground `| tail` is correct and constant, so the pass cases below are the
# point, not padding.
G=background-pipe-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  bgp() { jq -nc --arg c "$1" --argjson b "$2" '{tool_name:"Bash",cwd:"/tmp",tool_input:{command:$c,run_in_background:$b}}'; }
  assert "background piped to tail"          "$G" deny "$(bgp 'bash long.sh | tail -20' true)"
  assert "background piped to head"          "$G" deny "$(bgp 'bash long.sh | head -5' true)"
  assert "background piped to tr"            "$G" deny "$(bgp 'wsl.exe -d Ubuntu -- bash x.sh | tr -d "\0"' true)"
  assert "background, pipe mid-chain"        "$G" deny "$(bgp 'bash a.sh 2>&1 | tail -3 > out.txt' true)"
  # The fix the deny recommends must itself pass.
  assert "background redirected to a log"    "$G" pass "$(bgp 'bash long.sh > scratch/x.log 2>&1' true)"
  # grep --line-buffered flushes per line and is the documented way to stream a background feed.
  assert "background piped to grep"          "$G" pass "$(bgp 'tail -f app.log | grep --line-buffered ERROR' true)"
  # Foreground is the common, correct case -- this is what a pipe-only rule would wrongly deny.
  assert "FOREGROUND piped to tail"          "$G" pass "$(bgp 'cat big.txt | tail -20' false)"
  assert "flag absent entirely"              "$G" pass "$(jq -nc '{tool_name:"Bash",cwd:"/tmp",tool_input:{command:"cat x | tail -3"}}')"
  assert "background, no pipe"               "$G" pass "$(bgp 'bash long.sh' true)"
  # "tail" as a word, not a pipe stage.
  assert "tail in a filename/flag"           "$G" pass "$(bgp 'bash tail-report.sh --tail 5' true)"
else
  skip_gate "$G"
fi


# ------------------------------------------------- substitution-stdin-hang-gate.sh
# A filter whose file operands ALL come from an unquoted substitution: an empty expansion leaves it
# reading STDIN, and it blocks forever with no output to notice. The PASS cases are the point, not
# padding -- `find | grep` and `grep P file $(...)` are both common and correct, and a rule keyed on
# "substitution near a filter" would deny them.
G=substitution-stdin-hang-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  assert "the 2026-09-14 incident shape"     "$G" deny "$(bash_payload 'grep -l -i relaunch $(find "$HOME/.claude/debug" -maxdepth 1 -newermt "2026-09-14 15:05")')"
  assert "grep, one substitution operand"    "$G" deny "$(bash_payload 'grep PATTERN $(find . -name "*.log")')"
  assert "filter with no pattern operand"    "$G" deny "$(bash_payload 'wc -l $(find . -name "*.md")')"
  assert "backtick substitution"             "$G" deny "$(bash_payload 'grep foo `find . -name x`')"
  assert "later in a ; chain"                "$G" deny "$(bash_payload 'ls; grep foo $(find . -name y)')"
  assert "options trailing the operand"      "$G" deny "$(bash_payload 'grep -n foo $(find . -type f) --color')"
  # Correct forms the deny recommends -- each must itself pass.
  assert "piped in instead"                  "$G" pass "$(bash_payload 'find . -name "*.log" | grep PATTERN')"
  assert "find -exec instead"                "$G" pass "$(bash_payload 'find . -name "*.log" -exec grep -l PATTERN {} +')"
  assert "explicit </dev/null"               "$G" pass "$(bash_payload 'grep PATTERN $(find . -name y) </dev/null')"
  # A literal operand means it never falls through to stdin.
  assert "a literal file operand too"        "$G" pass "$(bash_payload 'grep PATTERN real.txt $(find . -name "*.log")')"
  # Quoted: one empty arg, which ERRORS ("No such file"); it does not hang.
  assert "quoted substitution"               "$G" pass "$(bash_payload 'grep PATTERN "$(ls x)"')"
  assert "substitution is the PATTERN"       "$G" pass "$(bash_payload 'grep "$(cat pat.txt)" file.txt')"
  assert "tr takes no file operand"          "$G" pass "$(bash_payload 'tr -d "\0" $(echo x)')"
  assert "not a stdin-reading filter"        "$G" pass "$(bash_payload 'bash $(find . -name run.sh)')"
  assert "a ; inside the substitution"       "$G" pass "$(bash_payload 'echo "$(ls; pwd)"')"
  assert "no substitution at all"            "$G" pass "$(bash_payload 'grep -rn foo ./src')"
  # A backtick in ORDINARY PROSE, not a substitution -- the scanner only toggles its backtick
  # state outside quotes, and the raw-payload prefilter deliberately lets prose through so the
  # command-level filter can reject it. Both halves are asserted here.
  assert "backtick inside single quotes"     "$G" pass "$(bash_payload "echo 'see the \`grep\` output'")"
  assert "backtick only in the description"  "$G" pass "$(jq -nc '{tool_name:"Bash",cwd:"/tmp",tool_input:{command:"grep -rn foo ./src",description:"check the `grep` output"}}')"
else
  skip_gate "$G"
fi
# -------------------------------------------------------------------- grep-memory-gate.sh
G=grep-memory-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  assert "recursive grep without -I"         "$G" deny "$(bash_payload 'grep -rn foo /some/tree')"
  assert "recursive long flag without -I"    "$G" deny "$(bash_payload 'grep --recursive foo /some/tree')"
  assert "recursive grep with -I"            "$G" pass "$(bash_payload 'grep -rIn foo /some/tree')"
  assert "-I after --include (not first flag)" "$G" pass "$(bash_payload 'grep -rl --include=*.cs -I "X" /some/tree')"
  assert "-r not first flag, no -I"          "$G" deny "$(bash_payload 'grep -n -r foo /some/tree')"
  assert "non-recursive grep"                "$G" pass "$(bash_payload 'grep -n foo one-file.txt')"
  assert "ripgrep is not grep"               "$G" pass "$(bash_payload 'rg -n foo /some/tree')"
  # The grep lives in a scratch script the command runs (2026-09-16: two unguarded recursive
  # greps ran that way with this gate live). lib-scan-script-refs.sh reads scratch paths.
  GS="$(cgmktemp -d "/tmp/gatefix-grepref.XXXXXX")"; mkdir -p "$GS/scratch"
  printf 'grep -rn foo /some/tree\n' > "$GS/scratch/x.sh"
  assert "recursive grep inside a scratch script" "$G" deny "$(bash_payload "bash $GS/scratch/x.sh")"
  printf 'grep -rIn foo /some/tree\n' > "$GS/scratch/x.sh"
  assert "scratch script grep with -I passes"    "$G" pass "$(bash_payload "bash $GS/scratch/x.sh")"
else
  skip_gate "$G"
fi

# ------------------------------------------------------------ dispatch.sh (scratch needles)
# A gate that scans a referenced scratch script is spawned only when its keyword appears in
# the command OR the script (2026-10-14): build-needle-cache.sh drops the `*scratch*`
# alternatives and dispatch.sh reads the script into what the needles match. Observed via the
# breadcrumb log, keyed on a session id no real session can have. `--gate dispatch.sh`.
G=dispatch.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  DS="$(cgmktemp -d "/tmp/gatefix-dispatch.XXXXXX")"; mkdir -p "$DS/scratch"
  DLOG="$HOME/.claude/harness-state/logs/gate-invocations.log"
  dispatch_gates() {   # <script text> -> comma list of gates the Pre dispatcher ran for `bash <that script>`
    printf '%s\n' "$1" > "$DS/scratch/x.sh"
    local before after
    before=$(grep -c 'd15ba7c4' "$DLOG" 2>/dev/null); before=${before:-0}
    jq -cn --arg c "bash $DS/scratch/x.sh" '{session_id:"d15ba7c4-0000-4000-8000-000000000000",hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c},cwd:"C:/x"}' \
      | bash "$hooks/dispatch.sh" "$hooks/dispatch-pre-bash.manifest" >/dev/null 2>&1
    after=$(grep -c 'd15ba7c4' "$DLOG" 2>/dev/null); after=${after:-0}
    [ "$after" -gt "$before" ] || { echo none; return; }
    grep 'd15ba7c4' "$DLOG" | tail -n $((after - before)) | cut -f3 | sort | paste -sd, -
  }
  dispatch_case() {    # <desc> <script text> <gate that must have run|-> <gate that must not|->
    local got; got="$(dispatch_gates "$2")"
    if { [ "$3" = - ] || [[ ",$got," == *",$3,"* ]]; } && { [ "$4" = - ] || [[ ",$got," != *",$4,"* ]]; }; then
      pass=$((pass+1))
    else
      fail=$((fail+1)); printf 'FAIL  %-46s want=+%s -%s got=%s\n' "$1" "$3" "$4" "$got"
    fi
  }
  dispatch_case "scratch script with no keyword: no psql gate"   'echo hi' - psql-write-gate.sh
  dispatch_case "scratch script with no keyword: no grep gate"   'echo hi' - grep-memory-gate.sh
  dispatch_case "psql inside the script spawns psql-write-gate"  'psql -h qa-host -c "select 1"' psql-write-gate.sh grep-memory-gate.sh
  dispatch_case "grep inside the script spawns grep-memory-gate" 'grep -rIn foo /some/tree' grep-memory-gate.sh psql-write-gate.sh
  # A gate its timeout kills is DENIED when its header carries `dispatch: fail-closed-on-timeout`
  # (the production gates) and skipped otherwise (2026-10-15). The manifest's directory is the
  # hooks dir, so two 1s-timeout fixtures live in a temp dir with their own needle cache.
  TH="$(cgmktemp -d "/tmp/gatefix-dispatch-to.XXXXXX")"
  cp "$hooks/build-needle-cache.sh" "$TH/"
  printf '#!/usr/bin/env bash\n# dispatch: fail-closed-on-timeout -- fixture\nsleep 4\n' > "$TH/slow-closed-gate.sh"
  printf '#!/usr/bin/env bash\nsleep 4\n' > "$TH/slow-open-gate.sh"
  printf '1\tslow-closed-gate.sh\t-\n1\tslow-open-gate.sh\t-\n' > "$TH/dispatch-gatefix-to.manifest"
  _dto="$(printf '%s' '{"session_id":"d15ba7c4-0000-4000-8000-000000000000","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo hi"},"cwd":"C:/x"}' \
    | bash "$hooks/dispatch.sh" "$TH/dispatch-gatefix-to.manifest" 2> "$TH/err")"
  case "$_dto" in
    *'"permissionDecision":"deny"'*'slow-closed-gate.sh timed out after 1s and FAILS CLOSED'*) pass=$((pass+1)) ;;
    *) fail=$((fail+1)); printf 'FAIL  %-46s got=%s\n' "dispatch: marked gate timeout is denied" "$(printf '%s' "$_dto" | head -c 100)" ;;
  esac
  case "$_dto" in *slow-open-gate*) fail=$((fail+1)); printf 'FAIL  %-46s\n' "dispatch: unmarked gate timeout still fails open" ;; *) pass=$((pass+1)) ;; esac
  if grep -q 'slow-open-gate.sh exceeded 1s and was skipped (failed open)' "$TH/err"; then pass=$((pass+1)); else
    fail=$((fail+1)); printf 'FAIL  %-46s got=%s\n' "dispatch: fail-open timeout named on stderr" "$(head -c 100 "$TH/err")"; fi
  # `-unless-nonprod` (DB write gates): no env named -> deny; only staging/qa named -> fail open.
  printf '#!/usr/bin/env bash\n# dispatch: fail-closed-on-timeout-unless-nonprod -- fixture\nsleep 4\n' > "$TH/slow-env-gate.sh"
  printf '1\tslow-env-gate.sh\t-\n' > "$TH/dispatch-gatefix-env.manifest"
  _denv() { printf '{"session_id":"d15ba7c4-0000-4000-8000-000000000000","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"%s"},"cwd":"C:/x"}' "$1" \
    | bash "$hooks/dispatch.sh" "$TH/dispatch-gatefix-env.manifest" 2>/dev/null; }
  case "$(_denv 'pg-connect.sh staging reports x')" in *deny*) fail=$((fail+1)); echo "FAIL  dispatch: nonprod-marked timeout on staging fails open" ;; *) pass=$((pass+1)) ;; esac
  case "$(_denv 'pg-connect.sh production reports x')" in *deny*) pass=$((pass+1)) ;; *) fail=$((fail+1)); echo "FAIL  dispatch: nonprod-marked timeout on production denies" ;; esac
  case "$(_denv 'bash x.sh')" in *deny*) pass=$((pass+1)) ;; *) fail=$((fail+1)); echo "FAIL  dispatch: nonprod-marked timeout, no env named, denies" ;; esac
  rm -rf "$TH" "$HOME/.claude/harness-state/hooks/needle-cache-dispatch-gatefix-to.manifest.tsv" "$HOME/.claude/harness-state/hooks/needle-cache-dispatch-gatefix-env.manifest.tsv" 2>/dev/null || true
  rm -rf "$DS" 2>/dev/null || true
else
  skip_gate "$G"
fi

# --------------------------------------------------------------- defender-hot-trigger.sh
# The slow-spell recorder's trigger + relay (scripts/defender-hot-record.ps1 runs elevated
# and is not driven here). Seams: CLAUDE_STATE_DIR, DEFENDER_HOT_SCHTASKS (a fake schtasks).
G=defender-hot-trigger.sh
if want_gate "$G" && [ -f "$hooks/$G" ] && [ -f "$hooks/defender-hot-check.sh" ]; then
  DH="$(cgmktemp -d "/tmp/gatefix-defhot.XXXXXX")"; mkdir -p "$DH/state/logs"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/calls"\n' "$DH" > "$DH/fake-schtasks"; chmod +x "$DH/fake-schtasks"
  _dh_prev_state="${CLAUDE_STATE_DIR:-}"; export CLAUDE_STATE_DIR="$DH/state"
  # The copy-drift check must never see the machine's real installed copy: absent fixture = no
  # drift line, until the drift cases below create one.
  export DEFENDER_HOT_BIN="$DH/bin.ps1" DEFENDER_HOT_OUT="$DH/out"   # never the real recorder output
  # The slow-box reaper kick goes to its own fake, so the recording-start call counts below hold.
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/reap-calls"\n' "$DH" > "$DH/fake-reap"; chmod +x "$DH/fake-reap"
  export REAP_SCHTASKS="$DH/fake-reap"
  DEFENDER_HOT_SCHTASKS="$DH/fake-schtasks" bash "$hooks/$G" "bash-start=600ms,900ms" >/dev/null 2>&1
  grep -q '^//run //tn AMA-Harness-Orphan-Conhost-Reap$' "$DH/reap-calls" 2>/dev/null && pass=$((pass+1)) || { fail=$((fail+1)); printf 'FAIL  %-46s\n' "defender-hot: slow spell kicks the orphan reaper"; }
  if grep -q '^//run //tn AMA-Harness-Defender-Hot-Record$' "$DH/calls" 2>/dev/null \
     && grep -q 'hot-record started reason=bash-start=600ms,900ms' "$DH/state/logs/defender-hot.log" 2>/dev/null; then
    pass=$((pass+1))
  else
    fail=$((fail+1)); printf 'FAIL  %-46s\n' "defender-hot: first trigger starts the task + logs"
  fi
  DEFENDER_HOT_SCHTASKS="$DH/fake-schtasks" bash "$hooks/$G" "again" >/dev/null 2>&1
  [ "$(wc -l < "$DH/calls")" -eq 1 ] && pass=$((pass+1)) || { fail=$((fail+1)); printf 'FAIL  %-46s\n' "defender-hot: 30-min cooldown holds"; }
  [ "$(wc -l < "$DH/reap-calls")" -eq 1 ] && pass=$((pass+1)) || { fail=$((fail+1)); printf 'FAIL  %-46s\n' "defender-hot: reaper kick 10-min throttle"; }
  # Not registered yet: a FAILED line, which the relay turns into the registration command.
  printf '%s x\n' "$(( $(date +%s) - 7200 ))" > "$DH/state/logs/.defender-hot-last"
  DEFENDER_HOT_SCHTASKS="/nonexistent/schtasks" bash "$hooks/$G" "msmpeng=130%" >/dev/null 2>&1
  grep -q 'hot-record FAILED to start' "$DH/state/logs/defender-hot.log" 2>/dev/null && pass=$((pass+1)) || { fail=$((fail+1)); printf 'FAIL  %-46s\n' "defender-hot: unregistered task logged as FAILED"; }
  # Two starts today already (one ok, one FAILED): the daily cap holds even past the cooldown.
  printf '%s x\n' "$(( $(date +%s) - 7200 ))" > "$DH/state/logs/.defender-hot-last"
  DEFENDER_HOT_SCHTASKS="$DH/fake-schtasks" bash "$hooks/$G" "third" >/dev/null 2>&1
  if [ "$(wc -l < "$DH/calls")" -eq 1 ] && ! grep -q 'reason=third' "$DH/state/logs/defender-hot.log" 2>/dev/null; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL  %-46s\n' "defender-hot: daily cap of 2 holds"; fi
  DEFENDER_HOT_PER_DAY=5 DEFENDER_HOT_SCHTASKS="$DH/fake-schtasks" bash "$hooks/$G" "fourth" >/dev/null 2>&1
  [ "$(wc -l < "$DH/calls")" -eq 2 ] && pass=$((pass+1)) || { fail=$((fail+1)); printf 'FAIL  %-46s\n' "defender-hot: raised daily cap allows the start"; }
  # Recorder's own cooldown (fresh output): skip + say so, no start, no slot spent.
  mkdir -p "$DH/out"; : > "$DH/out/x.report.txt"
  printf '%s x\n' "$(( $(date +%s) - 7200 ))" > "$DH/state/logs/.defender-hot-last"
  DEFENDER_HOT_PER_DAY=9 DEFENDER_HOT_SCHTASKS="$DH/fake-schtasks" bash "$hooks/$G" "fresh-out" >/dev/null 2>&1
  if [ "$(wc -l < "$DH/calls")" -eq 2 ] && grep -q 'skipped: recorder cooldown.*reason=fresh-out' "$DH/state/logs/defender-hot.log"; then pass=$((pass+1)); else
    fail=$((fail+1)); printf 'FAIL  %-46s\n' "defender-hot: recorder cooldown skips the start"; fi
  rm -rf "$DH/out"
  # The watcher writes the day counter with Set-Content (CRLF): the cap must still hold.
  printf '%s 2\r\n' "$(date +%F)" > "$DH/state/logs/.defender-hot-day"
  printf '%s x\r\n' "$(( $(date +%s) - 7200 ))" > "$DH/state/logs/.defender-hot-last"
  DEFENDER_HOT_SCHTASKS="$DH/fake-schtasks" bash "$hooks/$G" "crlf" >/dev/null 2>&1
  [ "$(wc -l < "$DH/calls")" -eq 2 ] && pass=$((pass+1)) || { fail=$((fail+1)); printf 'FAIL  %-46s\n' "defender-hot: CRLF day counter still caps"; }
  # The on-prompt relay reads the user-side log AND the admin-owned recording log: every new
  # line once, then silent; a line landing later in either log is relayed on its own.
  printf '2026-10-15T13:40:00 recorded 120s: scans 9870 ms = 8.2%% of a core; at start MsMpEng 131%% MsSense 52%% total 61%% SenseIR=1; top: MsMpEng 5000ms/40\n' > "$DH/admin.log"
  export DEFENDER_HOT_ADMIN_LOG="$DH/admin.log"
  defender_hot_notice=""; . "$hooks/defender-hot-check.sh"
  case "$defender_hot_notice" in
    *"DEFENDER HOT RECORDING"*"hot-record started"*"FAILED to start"*"recorded 120s"*register-defender-hot-record*) pass=$((pass+1)) ;;
    *) fail=$((fail+1)); printf 'FAIL  %-46s got=%s\n' "defender-hot-check: both logs relayed" "$(printf '%s' "$defender_hot_notice" | head -c 90)" ;;
  esac
  defender_hot_notice=""; . "$hooks/defender-hot-check.sh"
  [ -z "$defender_hot_notice" ] && pass=$((pass+1)) || { fail=$((fail+1)); printf 'FAIL  %-46s\n' "defender-hot-check: relayed once only"; }
  printf '2026-10-15T13:42:40 task AMA-Harness-Defender-Hot-Record retired after 3 recording(s)\n' >> "$DH/admin.log"
  defender_hot_notice=""; . "$hooks/defender-hot-check.sh"
  case "$defender_hot_notice" in
    *"retired after 3"*) case "$defender_hot_notice" in *"recorded 120s"*) fail=$((fail+1)); printf 'FAIL  %-46s\n' "defender-hot-check: old line repeated" ;; *) pass=$((pass+1)) ;; esac ;;
    *) fail=$((fail+1)); printf 'FAIL  %-46s\n' "defender-hot-check: later admin line relayed" ;;
  esac
  # A bare "FAILED: <error>" from the elevated side is a script error AFTER a successful
  # recording, and the guidance must say so -- a peer read the first one as a missing registration.
  printf '\xEF\xBB\xBF2026-10-15T14:42:06 FAILED: Cannot bind argument to parameter Path because it is an empty string.\n' >> "$DH/admin.log"
  defender_hot_notice=""; . "$hooks/defender-hot-check.sh"
  case "$defender_hot_notice" in
    *"FAILED: Cannot bind"*"recording RAN"*) case "$defender_hot_notice" in *"FAILED to start' ="*) fail=$((fail+1)); printf 'FAIL  %-46s\n' "defender-hot-check: script error mis-explained as registration" ;; *) pass=$((pass+1)) ;; esac ;;
    *) fail=$((fail+1)); printf 'FAIL  %-46s got=%s\n' "defender-hot-check: script error explained" "$(printf '%s' "$defender_hot_notice" | head -c 100)" ;;
  esac
  # Shared Defender notes (2026-10-16): every relayed line lands in notices/defender-notes.md
  # with the relaying session; the OWNER session gets other sessions' lines once.
  _dh_sid_prev="${sid-}"; DN="$DH/state/notices/defender-notes.md"
  [ "$(grep -c '^- \[session ' "$DN" 2>/dev/null)" -ge 1 ] && pass=$((pass+1)) || { fail=$((fail+1)); printf 'FAIL  %-46s\n' "defender-notes: relayed lines written"; }
  case "$defender_hot_notice" in *"defender-notes.md"*) pass=$((pass+1)) ;; *) fail=$((fail+1)); printf 'FAIL  %-46s\n' "defender-notes: session told to add a summary" ;; esac
  printf 'aaaa1111-0000-4000-8000-000000000000\n' > "$DH/state/notices/spell-milestones.owner"
  printf -- '- [session bbbb2222, 2026-10-16 07:40] summary: 07:33 recording quiet, probe undecided\n' >> "$DN"
  sid=aaaa1111-0000-4000-8000-000000000000; defender_hot_notice=""; . "$hooks/defender-hot-check.sh"
  case "$defender_hot_notice" in *"DEFENDER NOTES from other sessions"*"07:33 recording quiet"*) pass=$((pass+1)) ;;
    *) fail=$((fail+1)); printf 'FAIL  %-46s got=%s\n' "defender-notes: owner gets others' notes" "$(printf '%s' "$defender_hot_notice" | head -c 100)" ;; esac
  defender_hot_notice=""; . "$hooks/defender-hot-check.sh"
  [ -z "$defender_hot_notice" ] && pass=$((pass+1)) || { fail=$((fail+1)); printf 'FAIL  %-46s\n' "defender-notes: owner relay once only"; }
  printf -- '- [session bbbb2222, 2026-10-16 07:50] another\n' >> "$DN"
  sid=cccc3333-0000-4000-8000-000000000000; defender_hot_notice=""; . "$hooks/defender-hot-check.sh"
  [ -z "$defender_hot_notice" ] && pass=$((pass+1)) || { fail=$((fail+1)); printf 'FAIL  %-46s\n' "defender-notes: non-owner not relayed"; }
  sid="$_dh_sid_prev"; unset _dh_sid_prev DN
  export -n DEFENDER_HOT_ADMIN_LOG; unset DEFENDER_HOT_ADMIN_LOG
  # The installed admin-only copy vs the repo script: a differing copy is said out loud on a
  # trigger; an identical one is not. (Marker aged so the cooldown allows the start; cap raised.)
  printf 'old copy\n' > "$DH/bin.ps1"
  printf '%s x\n' "$(( $(date +%s) - 7200 ))" > "$DH/state/logs/.defender-hot-last"
  DEFENDER_HOT_PER_DAY=9 DEFENDER_HOT_BIN="$DH/bin.ps1" DEFENDER_HOT_SCHTASKS="$DH/fake-schtasks" bash "$hooks/$G" "drift" >/dev/null 2>&1
  grep -q 'installed copy differs from the repo script' "$DH/state/logs/defender-hot.log" 2>/dev/null && pass=$((pass+1)) || { fail=$((fail+1)); printf 'FAIL  %-46s\n' "defender-hot: differing copy reported"; }
  cp "$HOME/.claude/scripts/defender-hot-record.ps1" "$DH/bin.ps1"
  printf '%s x\n' "$(( $(date +%s) - 7200 ))" > "$DH/state/logs/.defender-hot-last"
  DEFENDER_HOT_PER_DAY=9 DEFENDER_HOT_BIN="$DH/bin.ps1" DEFENDER_HOT_SCHTASKS="$DH/fake-schtasks" bash "$hooks/$G" "nodrift" >/dev/null 2>&1
  [ "$(grep -c 'installed copy differs' "$DH/state/logs/defender-hot.log" 2>/dev/null)" = "1" ] && pass=$((pass+1)) || { fail=$((fail+1)); printf 'FAIL  %-46s\n' "defender-hot: identical copy stays silent"; }
  export -n DEFENDER_HOT_BIN DEFENDER_HOT_OUT REAP_SCHTASKS 2>/dev/null || true; unset DEFENDER_HOT_BIN DEFENDER_HOT_OUT REAP_SCHTASKS
  CLAUDE_STATE_DIR="$_dh_prev_state"; export -n CLAUDE_STATE_DIR 2>/dev/null || true
  [ -n "$_dh_prev_state" ] || unset CLAUDE_STATE_DIR
  unset defender_hot_notice _dh_prev_state; rm -rf "$DH" 2>/dev/null || true
else
  skip_gate "$G"
fi

# ------------------------------------------------------------------- spell-milestones.sh
# The slow-spell measurement milestones (scripts/spell-milestones.sh) and their launcher at the
# end of dispatch.sh's once-a-minute sample. Every path is a temp dir -- CLAUDE_STATE_DIR covers
# logs, notices AND the reminder store (reminder.sh resolves through hstate), so no real
# reminder is ever filed. Fixture windows: A validated, B refuted, C not seen + no write,
# D not seen + a write, E scan too short to tell, F a second validation (no second notice).
G=spell-milestones.sh
if want_gate "$G" && [ -f "$harness/scripts/$G" ] && [ -f "$hooks/dispatch.sh" ]; then
  SM="$(cgmktemp -d "/tmp/gatefix-spellms.XXXXXX")"; mkdir -p "$SM/state/logs"
  _sm_prev_state="${CLAUDE_STATE_DIR:-}"; export CLAUDE_STATE_DIR="$SM/state"
  export DEFENDER_HOT_ADMIN_LOG="$SM/admin.log"
  sm() { SPELL_ANALYSIS_OUT="$SM/analysis.txt" bash "$harness/scripts/$G" "$@" >/dev/null 2>&1; }
  smok() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL  %-46s got=%s want=%s\n' "spell-milestones: $1" "$2" "$3"; fi; }
  nrem() { local n; n="$(ls "$SM/state/reminders/pending/" 2>/dev/null | grep -c '\.rem$')"; printf '%s' "${n:-0}"; }
  nml() { local n; n="$(grep -c " $1 " "$SM/state/logs/spell-milestones.log" 2>/dev/null)"; printf '%s' "${n:-0}"; }
  rec() {   # <window start YYYY-MM-DDTHH-MM-SS> <probe text>
    printf '%s recorded 120s: scans 720 ms over 99 = 7,3 ms each, 0,6%% of a core; at start MsMpEng 30%% MsSense 20%% total 10%% SenseIR=0; window avg: MsMpEng 33%%; top: svchost.exe 483ms/796; %s; mplog 12 line(s); report C:\\ProgramData\\AMA-Harness\\defender-hot\\%s.report.txt\n' "$1" "$2" "$1" >> "$SM/admin.log"
  }
  printf '2026-10-15T14:42:06 FAILED: Cannot bind argument\n' > "$SM/admin.log"
  { for h in 08 09; do printf '2026-10-16T%s:00:00 bash-start=50ms file-write=500us file-read=400us\n' "$h"; done
    printf '2026-10-16T10:00:30 bash-start=450ms file-write=6000us file-read=400us\n'
    printf '2026-10-16T11:00:40 bash-start=450ms file-write=500us file-read=400us\n'
    printf '2026-10-16T13:01:00 bash-start=50ms file-write=500us file-read=400us\n'
    printf '2026-10-16T14:00:20 bash-start=50ms file-write=500us file-read=400us\n'
    printf '2026-10-16T15:00:20 bash-start=450ms file-write=500us file-read=7000us\n'; } > "$SM/state/logs/proc-start-latency.log"
  printf 'verdict: insufficient (0 instrumented spell(s) over 0 day(s); need >= 3 over >= 2 days)\n' > "$SM/analysis.txt"
  sm owner 00000000-feed-4000-8000-000000000000
  smok "owner marks the old lines seen"  "$(cat "$SM/state/notices/.spell-milestones-admin-seen" 2>/dev/null)" 1
  rec 2026-10-16T10-00-00 'probe scanned 1x, 7,0 ms'; sm check
  smok "A: validated logged"             "$(nml probe-validated)" 1
  smok "A: one reminder filed"           "$(nrem)" 1
  _smr="$(cat "$SM/state/reminders/pending/"*.rem 2>/dev/null)"
  case "$_smr" in *$'\n'00000000-feed-4000-8000-000000000000$'\n'*"VALIDATED by hot recording 2026-10-16T10:00:00"*) pass=$((pass+1)) ;;
    *) fail=$((fail+1)); printf 'FAIL  %-46s got=%s\n' "spell-milestones: reminder names owner + task" "$(printf '%s' "$_smr" | head -c 120)" ;; esac
  sm check
  smok "A: nothing new, nothing filed"   "$(nrem)" 1
  rec 2026-10-16T11-00-00 'probe scanned 1x, 7,0 ms'; sm check
  smok "B: refuted (wait not timed)"     "$(nml probe-refuted)" 1
  rec 2026-10-16T12-00-00 'probe not seen'; sm check
  smok "C: not seen, no write: silent"   "$(nml probe-not-seen)" 0
  rec 2026-10-16T13-00-00 'probe not seen'; sm check
  smok "D: not seen though written"      "$(nml probe-not-seen)" 1
  rec 2026-10-16T14-00-00 'probe scanned 1x, 0,2 ms'; sm check
  smok "E: too short: logged"            "$(nml probe-undecided)" 1
  smok "E: too short: no reminder"       "$(nrem)" 3
  rec 2026-10-16T15-00-00 'probe scanned 1x, 7,0 ms'; sm check
  smok "F: second validation not resent" "$(nml probe-validated)" 1
  sm check
  smok "insufficient verdict: silent"    "$(nml verdict-reached)" 0
  printf 'instrumented spells: 3 of 5 over 2 day(s) -> scan-wait=2\nverdict: scan-wait in 2 of 3 instrumented spells -- supports asking for path exclusions\n' > "$SM/analysis.txt"; sm check
  smok "verdict reached"                 "$(nml verdict-reached)" 1
  smok "verdict reminder filed"          "$(nrem)" 4
  smok "verdict analysis kept"           "$(grep -c '^verdict: scan-wait' "$SM/state/logs/spell-verdict-latest.txt" 2>/dev/null)" 1
  sm check
  smok "same verdict class: silent"      "$(nrem)" 4
  printf 'verdict: insufficient (2 instrumented spell(s) over 2 day(s); need >= 3 over >= 2 days)\n' > "$SM/analysis.txt"; sm check
  smok "insufficient after (rotation)"   "$(nrem)" 4
  printf 'verdict: mixed in 2 of 4 instrumented spells -- inconclusive\n' > "$SM/analysis.txt"
  printf '%s' "$(date +%s)" > "$SM/state/logs/.spell-pending"; sm check
  smok "spell still running: waits"      "$(nml verdict-changed)" 0
  mkdir "$SM/state/logs/.spell-milestones.lock"; printf 'ran 1' > "$SM/state/logs/.spell-pending"; sm check
  smok "lock held: second run exits"     "$(nml verdict-changed)" 0
  rmdir "$SM/state/logs/.spell-milestones.lock"; sm check
  smok "class change notified"           "$(grep -c 'verdict-changed class=mixed (was scan-wait)' "$SM/state/logs/spell-milestones.log" 2>/dev/null)" 1
  # The launcher in dispatch.sh, through an empty manifest (no gates; the temp dir also has no
  # defender-hot-trigger.sh, so a slow sample cannot start the real task). A slow real sample
  # rewrites the pending marker, so the pending cases are skipped, not failed, on a slow machine.
  SMD="$(cgmktemp -d "/tmp/gatefix-spellms-d.XXXXXX")"; cp "$hooks/build-needle-cache.sh" "$SMD/"; : > "$SMD/dispatch-gatefix-sm.manifest"
  printf '#!/usr/bin/env bash\nprintf "x\\n" >> "%s/launched"\n' "$SM" > "$SM/fake-ms.sh"
  smd() {   # run one dispatch with a forced sample; echoes the sample's bash-start ms
    printf '0 0 0' > "$SM/state/logs/.proc-start-latency-last"
    printf '%s' '{"session_id":"d15ba7c4-0000-4000-8000-000000000000","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo hi"},"cwd":"C:/x"}' \
      | SPELL_MILESTONES_SCRIPT="$SM/fake-ms.sh" bash "$hooks/dispatch.sh" "$SMD/dispatch-gatefix-sm.manifest" >/dev/null 2>&1
    local l; l="$(tail -n 1 "$SM/state/logs/proc-start-latency.log")"; l="${l#* bash-start=}"; printf '%s' "${l%%ms*}"
  }
  smlaunched() {   # <expected count>: waits up to 5 s for it (the launch is detached)
    local i n
    for i in 1 2 3 4 5 6 7 8 9 10; do n="$(grep -c x "$SM/launched" 2>/dev/null)"; [ "${n:-0}" -ge "$1" ] && break; sleep 0.5; done
    sleep 0.5; n="$(grep -c x "$SM/launched" 2>/dev/null)"; printf '%s' "${n:-0}"
  }
  rm -f "$SM/state/logs/.spell-pending"; smd >/dev/null
  smok "launch: recording log changed"   "$(smlaunched 1)" 1
  smd >/dev/null
  smok "launch: log unchanged, no run"   "$(smlaunched 2)" 1
  printf '%s' "$(( $(date +%s) - 1000 ))" > "$SM/state/logs/.spell-pending"; _sms="$(smd)"
  if [ "${_sms:-0}" -lt 400 ]; then
    smok "launch: spell over (15 min)"   "$(smlaunched 2)" 2
    smok "launch: marker flipped to ran" "$(cut -c1-4 "$SM/state/logs/.spell-pending")" "ran "
    smd >/dev/null
    smok "launch: no second launch"      "$(smlaunched 3)" 2
  else skip=$((skip+1)); printf 'SKIP  spell-milestones: launch cases (sample took %sms)\n' "$_sms"; fi
  printf '%s' "$(( $(date +%s) - 100 ))" > "$SM/state/logs/.spell-pending"; smd >/dev/null
  _smn="$(grep -c x "$SM/launched" 2>/dev/null)"
  smok "launch: spell still running"     "$(smlaunched $((_smn + 1)))" "$_smn"
  touch -d '+1 minute' "$SM/admin.log"; smd >/dev/null
  smok "launch: new recording line"      "$(smlaunched $((_smn + 1)))" "$((_smn + 1))"
  rm -rf "$SMD" "$HOME/.claude/harness-state/hooks/needle-cache-dispatch-gatefix-sm.manifest.tsv" 2>/dev/null || true
  export -n DEFENDER_HOT_ADMIN_LOG; unset DEFENDER_HOT_ADMIN_LOG
  CLAUDE_STATE_DIR="$_sm_prev_state"; export -n CLAUDE_STATE_DIR 2>/dev/null || true
  [ -n "$_sm_prev_state" ] || unset CLAUDE_STATE_DIR
  unset -f sm smok nrem nml rec smd smlaunched; unset _sm_prev_state _smr _sms _smn; rm -rf "$SM" 2>/dev/null || true
else
  skip_gate "$G"
fi

# --------------------------------------------------------------- aggregation-secret-gate.sh
G=aggregation-secret-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  S='bash "$HOME/.claude/skills/ama-postgres-access/scripts/get-aggregation-connection.sh" staging'
  assert "connection script, output unconsumed" "$G" deny "$(bash_payload "$S")"
  # The documented consuming forms: the whole point is that the password never lands in the
  # transcript, so anything that captures the output is fine.
  assert "consumed via eval \$( )"           "$G" pass "$(bash_payload "eval \"\$($S)\"")"
  assert "consumed via pipe"                 "$G" pass "$(bash_payload "$S | grep -c PGPASSWORD")"
  assert "consumed via redirect"             "$G" pass "$(bash_payload "$S > /tmp/conn.env")"
  assert "unrelated postgres command"        "$G" pass "$(bash_payload 'psql -c "select 1"')"
else
  skip_gate "$G"
fi

# ===================================================== PostToolUse block-shape assertions
# Three output styles exist in this harness: PreToolUse `permissionDecision`, PostToolUse
# `{"decision":"block","reason":…}`, and plain non-zero exit. decide() only understands the
# first and returns "pass" for anything else -- routing a block-shaped gate through it would
# report a broken gate as healthy, so these get their own helper.
decide_block() {
  local raw rc _t0 _t1
  trace_pair "$1" "$2"
  _t0=$EPOCHREALTIME
  raw="$(printf '%s' "$2" | bash "$hooks/$1" 2>&1)"; rc=$?
  _t1=$EPOCHREALTIME; gate_timing_check "$1" "$_t0" "$_t1" >&2
  # Empty output MUST be handled before the jq probe: this box's jq (1.5rc1) exits 0 on empty
  # input, so `jq -e '.decision == "block"'` succeeds for a hook that said nothing at all.
  # Without this guard every silent (correctly-passing) gate reported as blocking -- three
  # false FAILs, and the same trap decide() above already sidesteps by testing -z first.
  if [ -z "$raw" ]; then
    if [ "$rc" -ne 0 ]; then printf 'block'; else printf 'pass'; fi
    return
  fi
  if printf '%s' "$raw" | jq -e '.decision == "block"' >/dev/null 2>&1; then printf 'block'; return; fi
  if [ "$rc" -ne 0 ]; then printf 'block'; return; fi
  printf 'pass'
}
assert_block() {
  local desc="$1" gate="$2" expect="$3" payload="$4" got
  got="$(decide_block "$gate" "$payload")"
  if [ "$got" = "$expect" ]; then pass=$((pass+1)); else
    fail=$((fail+1)); printf 'FAIL  %-46s want=%-5s got=%s\n' "$desc" "$expect" "$got"
  fi
}

# Probe session ids carry a PER-RUN tag. They used to be fixed literals, which made two passes
# collide: the fixtures live at shared paths (`~/.claude/.session-chatfiles/<sid>`,
# `~/.claude/.deploy-verify-approved`), so a second pass writes and then DELETES the first's state
# mid-flight. That is reachable three ways -- `mutate-gates.sh` spawns a full pass per gate,
# another session in this shared clone can run the suite at any time, and an interrupted run
# leaves state behind. It presented as `bare-cd` denying a cd to its own session home (the
# chatfile vanished between write and read) and as both `deploy-verify` cases inverting, and it is
# almost certainly the true content of the "spurious FAIL on a cold first run" report, whose
# stated direction was backwards. Tagging makes concurrent passes independent instead of
# forbidden. Cleanup globs are tag-scoped for the same reason -- a bare `check-gates-probe*` wipe
# would delete a CONCURRENT run's state and cause the very failure it was meant to prevent.
PROBE_TAG="$$"
PROBE_SID="check-gates-probe-$PROBE_TAG"
probe_state_clean() { rm -f "$HOME/.claude/.session-chatfiles/check-gates-probe-$PROBE_TAG"* 2>/dev/null || true; }

# The readme-family gates resolve the harness THEMSELVES from ~/.claude/skills and compare the
# edited path against it -- they ignore this script's $harness argument. So their payloads must
# name the real harness even when $hooks is a relocated copy (which is how mutation testing
# works: gate file from the copy, payload paths from reality). Pointing those payloads at a
# copied tree makes both gates fall through to "pass" and reads as two gate bugs.
real_harness="$(git -C "$HOME/.claude/skills" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$harness")"

# ------------------------------------------------------------------- native-memory-gate.sh
G=native-memory-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  assert "write into native per-project memory" "$G" deny \
    "$(write_payload "$HOME/.claude/projects/C--Users-x-Repos-y/memory/note.md" "a fact")"
  assert "write into the harness memory store"  "$G" pass \
    "$(write_payload "$HOME/.claude/memory/a-fact.md" "a fact")"
  assert "ordinary repo write"                  "$G" pass \
    "$(write_payload "$harness/scratch/note.md" "a fact")"
else
  skip_gate "$G"
fi

# ------------------------------------------------------------- claude-dir-clutter-gate.sh
# PROJ-15342: denies a NEW top-level ~/.claude entry (Edit/Write, or a Bash/
# PowerShell redirect/touch/mkdir/mv/cp/tee) not on the small allowlist of what
# legitimately lives there. A path already nested under any subdirectory is always
# allowed regardless of which one -- state/scratch both live one level down now.
G=claude-dir-clutter-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  assert "new top-level Write"                  "$G" deny \
    "$(write_payload "$HOME/.claude/.new-thing" "x")"
  assert "new top-level redirect"               "$G" deny \
    "$(bash_payload 'echo x > "$HOME/.claude/.new-thing"')"
  assert "mkdir a new top-level dir"             "$G" deny \
    "$(bash_payload 'mkdir "$HOME/.claude/newstuff"')"
  assert "touch a new top-level file"            "$G" deny \
    "$(bash_payload 'touch "$HOME/.claude/.oops-state"')"
  assert "write into harness-state subfolder"    "$G" pass \
    "$(write_payload "$HOME/.claude/harness-state/notices/.foo" "x")"
  assert "write into scratch subfolder"          "$G" pass \
    "$(write_payload "$HOME/.claude/scratch/notes/x.md" "x")"
  assert "write to the allowlisted settings.json" "$G" pass \
    "$(write_payload "$HOME/.claude/settings.json" "x")"
  assert "session-chatfiles subpath redirect"    "$G" pass \
    "$(bash_payload 'printf x > "$HOME/.claude/.session-chatfiles/abc123"')"
  assert "plain read of an existing top-level file" "$G" pass \
    "$(bash_payload 'cat "$HOME/.claude/harness-gaps.md"')"
  # The DESTINATION of a cp/mv was never examined. The old non-greedy verb pattern stopped
  # at the first .claude path -- the SOURCE -- which top_level_new_name cleared as
  # allowlisted, so this exact command silently created the clutter file the gate exists to
  # prevent (found by doing it accidentally, session 1ce24e66, 2026-09-01).
  assert "cp allowlisted src -> NEW top-level"  "$G" deny \
    "$(bash_payload 'cp "$HOME/.claude/settings.json" "$HOME/.claude/settings.json.bak"')"
  assert "mv allowlisted src -> NEW top-level"  "$G" deny \
    "$(bash_payload 'mv "$HOME/.claude/AGENTS.md" "$HOME/.claude/AGENTS.old.md"')"
  # ...but testing every path in the segment must not turn routine copies into denials.
  assert "cp allowlisted src -> nested dst"     "$G" pass \
    "$(bash_payload 'cp "$HOME/.claude/settings.json" "$HOME/.claude/harness-state/settings-backups/s.json"')"
  assert "cp allowlisted src -> outside .claude" "$G" pass \
    "$(bash_payload 'cp "$HOME/.claude/settings.json" /tmp/s.json')"
  # Only the DESTINATION of cp/mv is judged: an `mv` that REMOVES a stray top-level file has
  # clutter as its source by definition, and the gate blocked its own remediation (2026-09-18).
  assert "mv stray top-level file INTO scratch"  "$G" pass \
    "$(bash_payload 'mv "$HOME/.claude/stray-note.md" "$HOME/.claude/scratch/cleanup/stray-note.md"')"
  # scripts/ is junctioned in alongside hooks/ (install.ps1, 2026-09-01); the allowlist and
  # that target must stay in step or the gate denies its own installer.
  assert "write into the scripts junction"      "$G" pass \
    "$(bash_payload 'touch "$HOME/.claude/scripts/x.sh"')"
  assert "unrelated command"                     "$G" pass "$(bash_payload 'git status')"
  assert "edit an allowlisted top-level file"    "$G" pass "$(edit_payload "$HOME/.claude/AGENTS.md" "x")"
else
  skip_gate "$G"
fi

# ------------------------------------------------------------------ symlink-write-gate.sh
G=symlink-write-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  # Rewrites, never decides: no permissionDecision (decide() reads "pass"), and updatedInput
  # carries the real path plus every other input field unchanged.
  rewritten_path() { printf '%s' "$2" | bash "$hooks/$1" 2>/dev/null | jq -r '.hookSpecificOutput.updatedInput.file_path // ""' | tr '\\' '/'; }
  assert_rewrite() {
    local desc="$1" payload="$2" want="$3" got
    got="$(rewritten_path "$G" "$payload")"
    if [ "${got,,}" = "${want,,}" ]; then pass=$((pass+1)); else
      fail=$((fail+1)); printf 'FAIL  %-46s want-rewrite=%s got=%s\n' "$desc" "$want" "$got"; fi
  }
  real_harness_w="$(readlink -f "$HOME/.claude/AGENTS.md" | sed -E 's#^/([a-zA-Z])/#\1:/#; s#/AGENTS.md$##')"
  assert "edit through a link: no decision"     "$G" pass "$(edit_payload "$HOME/.claude/AGENTS.md" "x")"
  assert_rewrite "edit through a link: real path"     "$(edit_payload "$HOME/.claude/AGENTS.md" "x")" "$real_harness_w/AGENTS.md"
  assert_rewrite "write through a link: real path"    "$(write_payload "$HOME/.claude/harness-gaps.md" "x")" "$real_harness_w/harness-gaps.md"
  assert_rewrite "skill dir link: real path"          "$(edit_payload "$HOME/.claude/skills/ama-api-tests/SKILL.md" "x")" "$real_harness_w/skills/ama-api-tests/SKILL.md"
  [ "$(printf '%s' "$(edit_payload "$HOME/.claude/AGENTS.md" "x")" | bash "$hooks/$G" | jq -r '.hookSpecificOutput.updatedInput.new_string == "x"')" = true ] \
    && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL  rewrite keeps the other Edit fields"; }
  assert_rewrite "edit the resolved repo path: none"  "$(edit_payload "$harness/AGENTS.md" "x")" ""
  assert_rewrite "edit outside the harness: none"     "$(edit_payload "/tmp/whatever.md" "x")" ""
else
  skip_gate "$G"
fi

# -------------------------------------------------------------- standup-empty-section-gate.sh
# The heading is spelled "Couldn't summarize" -- with the apostrophe. A case written against
# "Could not summarize" passes vacuously, which is how this assert was nearly shipped wrong.
G=standup-empty-section-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  assert "empty Couldn't-summarize section"     "$G" deny "$(write_payload "$HOME/standup-notes-2026-08-18.md" \
    "## Yesterday
- shipped a thing

## Couldn't summarize
- None.
")"
  assert "same section with a real bullet"      "$G" pass "$(write_payload "$HOME/standup-notes-2026-08-18.md" \
    "## Yesterday
- shipped a thing

## Couldn't summarize
- session 1a2b3c: transcript truncated mid-tool-call, no reply text recorded
")"
  assert "standup with no such section"         "$G" pass "$(write_payload "$HOME/standup-notes-2026-08-18.md" \
    "## Yesterday
- shipped a thing
")"
  # Bare movement bullet (2026-08-21): a **KEY** line with nothing indented under it denies;
  # the same bullet with one indented explanation line passes.
  assert "bare **KEY** movement bullet denied"  "$G" deny "$(write_payload "$HOME/standup-notes-2026-08-18.md" \
    "## Yesterday
- **PROJ-15330** - Open -> In Progress
- shipped a thing
")"
  assert "**KEY** bullet with indented prose ok" "$G" pass "$(write_payload "$HOME/standup-notes-2026-08-18.md" \
    "## Yesterday
- **PROJ-15330** - Open -> In Progress
  Replace the dead UserNotification index; labelling sweep still outstanding.
- shipped a thing
")"
  assert "empty Action items section"           "$G" deny "$(write_payload "$HOME/standup-notes-2026-08-18.md" \
    "## Yesterday
- shipped a thing

## Action items
- None.
")"
  assert "Action items with a real bullet"      "$G" pass "$(write_payload "$HOME/standup-notes-2026-08-18.md" \
    "## Yesterday
- shipped a thing

## Action items
- Demo the harness work to Reviewer Two - open 3d
")"
  # Both guarded headings present, only the SECOND empty. The gate's awk stops at the next
  # heading, so a single pass sees "Couldn't summarize", finds a real bullet and passes --
  # this pins the per-heading loop that stops a populated section masking an empty one.
  assert "populated section masking empty one" "$G" deny "$(write_payload "$HOME/standup-notes-2026-08-18.md" \
    "## Couldn't summarize
- session 1a2b3c: transcript truncated mid-tool-call

## Action items
- None.
")"
  # Bare heading with nothing at all after it. Used to pass (empty body short-circuited
  # before the bullet count); Step 5 forbids a bare heading just as firmly as "- None.".
  assert "bare Action items heading at EOF"    "$G" deny "$(write_payload "$HOME/standup-notes-2026-08-18.md" \
    "## Yesterday
- shipped a thing

## Action items
")"
  # "Client mail" and "Decisions" (2026-08-25) -- same widened heading loop, same risk:
  # both carry forward rather than reset daily, so an empty one reads as "nothing
  # outstanding" when the truth could be a failed sweep.
  assert "empty Client mail section"            "$G" deny "$(write_payload "$HOME/standup-notes-2026-08-18.md" \
    "## Yesterday
- shipped a thing

## Client mail
- None.
")"
  assert "Client mail with a real bullet"       "$G" pass "$(write_payload "$HOME/standup-notes-2026-08-18.md" \
    "## Yesterday
- shipped a thing

## Client mail
- Dan - asked re GNM basis change; replied 20 Aug
")"
  assert "empty Decisions section"              "$G" deny "$(write_payload "$HOME/standup-notes-2026-08-18.md" \
    "## Yesterday
- shipped a thing

## Decisions
- None.
")"
  assert "Decisions with a real bullet"         "$G" pass "$(write_payload "$HOME/standup-notes-2026-08-18.md" \
    "## Yesterday
- shipped a thing

## Decisions
- Aggregation API stays on 8080 for now - 21 Aug
")"
else
  skip_gate "$G"
fi

# ------------------------------------------------------------ subagent-model-tiering-gate.sh
# Warn-only: it returns permissionDecision "allow" WITH a reason rather than denying, so the
# assertion is allow-vs-pass. Asserting deny here would fail for the wrong reason.
G=subagent-model-tiering-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  # Output budget is the ONLY check as of 2026-09-14 -- settings.json env
  # CLAUDE_CODE_SUBAGENT_MODEL=sonnet defaults the model mechanically, so the gate stopped
  # reading `model` at all. The old "no model set" case asserted allow and would still pass
  # here for the WRONG reason (its payload also carries no budget), so it is replaced rather
  # than kept.
  assert "Agent call with no output budget"     "$G" allow "$(agent_payload "grep the fleet for a string" '{"subagent_type":"general-purpose"}')"
  assert "Agent call with output budget"        "$G" pass  "$(agent_payload "grep the fleet for a string; report in under 400 words" '{"subagent_type":"general-purpose"}')"
  # 2026-10-22: `model` omitted -> additionalContext names the SESSION model (transcript
  # tail, settings.json `.model` fallback) so an opt-up passes it exactly; `model` given ->
  # no context line. Decision is unchanged by this (pass/allow above still hold).
  _smt_tr="$(cgmktemp 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/smt-$$.jsonl")"
  printf '%s\n' '{"type":"assistant","message":{"model":"claude-opus-5-5","content":[]}}' > "$_smt_tr"
  _smt_ctx() { printf '%s' "$1" | bash "$hooks/$G" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null; }
  _smt_p="$(agent_payload "grep the fleet; report in under 400 words" '{"subagent_type":"general-purpose"}' | jq -c --arg t "$_smt_tr" '. + {transcript_path:$t}')"
  if _smt_ctx "$_smt_p" | grep -q 'model:"opus"'; then pass=$((pass+1)); else
    fail=$((fail+1)); printf 'FAIL  %-46s\n' "Agent model omitted: names session model"; fi
  _smt_p="$(agent_payload "grep the fleet; report in under 400 words" '{"subagent_type":"general-purpose","model":"sonnet"}' | jq -c --arg t "$_smt_tr" '. + {transcript_path:$t}')"
  if [ -z "$(_smt_ctx "$_smt_p")" ]; then pass=$((pass+1)); else
    fail=$((fail+1)); printf 'FAIL  %-46s\n' "Agent model given: no session-model line"; fi
  rm -f "$_smt_tr" 2>/dev/null
  # A tiered `model` must not sway the budget verdict.
  assert "budget present, model also set"       "$G" pass  "$(agent_payload "grep the fleet for a string; report in under 400 words" '{"subagent_type":"general-purpose","model":"haiku"}')"
  assert "no budget, model set"                 "$G" allow "$(agent_payload "grep the fleet for a string" '{"subagent_type":"general-purpose","model":"haiku"}')"
else
  skip_gate "$G"
fi

# ------------------------------------------------------------ skill-model-tiering-gate.sh
# Warn-only sibling (allow + reason, never denies). Had NO case until 2026-10-22, when its
# reason text changed (tag engages on user /slash only). Asserts the decision shape only.
G=skill-model-tiering-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  _skt() { jq -n --arg c "$1" '{tool_name:"Write",tool_input:{file_path:"C:/x/skills/foo/SKILL.md",content:$c}}'; }
  assert "SKILL.md write without model:"       "$G" allow "$(_skt $'---\nname: foo\ndescription: d\n---\nbody')"
  assert "SKILL.md write with model: sonnet"   "$G" pass  "$(_skt $'---\nname: foo\nmodel: sonnet\ndescription: d\n---\nbody')"
  assert "non-skill write is ignored"          "$G" pass  "$(jq -n '{tool_name:"Write",tool_input:{file_path:"C:/x/hooks/foo.sh",content:"x"}}')"
else
  skip_gate "$G"
fi

# ------------------------------------------------------------------- chrome-verify-nudge.sh
G=chrome-verify-nudge.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  assert "UI-driving skill invoked"            "$G" allow "$(skill_payload "ama-ui-verify")"
  assert "unrelated skill invoked"             "$G" pass  "$(skill_payload "ama-graylog-search")"
else
  skip_gate "$G"
fi

# ------------------------------------------------------------------- harness-ticket-gate.sh
# Epic arrives at .tool_input.additional_fields[<epicLinkFieldId>], not as a top-level field.
G=harness-ticket-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  EPICF="$(jq -r '.atlassian.epicLinkFieldId // "<epicLinkFieldId>"' "$HOME/.claude/harness-config.json" 2>/dev/null | tr -d '\r')"
  EPICK="$(jq -r '.atlassian.harnessEpicKey // "<harnessEpicKey>"' "$HOME/.claude/harness-config.json" 2>/dev/null | tr -d '\r')"
  assert "new ticket under the harness epic"    "$G" deny "$(mcp_payload mcp__claude_ai_Atlassian__createJiraIssue \
    "$(jq -nc --arg f "$EPICF" --arg k "$EPICK" '{projectKey:"PROJ",summary:"x",additional_fields:{($f):$k}}')")"
  assert "new ticket under another epic"        "$G" pass "$(mcp_payload mcp__claude_ai_Atlassian__createJiraIssue \
    "$(jq -nc --arg f "$EPICF" '{projectKey:"PROJ",summary:"x",additional_fields:{($f):"PROJ-99999"}}')")"
  assert "new ticket with no epic at all"       "$G" pass "$(mcp_payload mcp__claude_ai_Atlassian__createJiraIssue \
    '{"projectKey":"PROJ","summary":"x"}')"
  # Security findings must sit under atlassian.securityEpicKey (2026-10-15).
  SECK="$(jq -r '.atlassian.securityEpicKey // empty' "$HOME/.claude/harness-config.json" 2>/dev/null | tr -d '\r')"
  if [ -n "$SECK" ]; then
    assert "security summary with no epic"      "$G" deny "$(mcp_payload mcp__claude_ai_Atlassian__createJiraIssue \
      '{"projectKey":"PROJ","summary":"On Prod: band names written unescaped into SQL (SQL injection)"}')"
    assert_reason "security deny names the epic" "$G" "$SECK" "$(mcp_payload mcp__claude_ai_Atlassian__createJiraIssue \
      '{"projectKey":"PROJ","summary":"On Prod: XSS in report name"}')"
    # Summary carries no keyword; the description says so (PROJ-15818's shape).
    assert "security only in description"       "$G" deny "$(mcp_payload mcp__claude_ai_Atlassian__createJiraIssue \
      '{"projectKey":"PROJ","summary":"A sharee can delete the owner band","description":"Security issue (authorization)."}')"
    assert "security finding under another epic" "$G" deny "$(mcp_payload mcp__claude_ai_Atlassian__createJiraIssue \
      "$(jq -nc --arg f "$EPICF" '{projectKey:"PROJ",summary:"Unauthorized delete of shared bands",additional_fields:{($f):"PROJ-99999"}}')")"
    assert "security finding under security epic" "$G" pass "$(mcp_payload mcp__claude_ai_Atlassian__createJiraIssue \
      "$(jq -nc --arg f "$EPICF" --arg k "$SECK" '{projectKey:"PROJ",summary:"SQL injection in band names",additional_fields:{($f):$k}}')")"
    assert "AWS security group ticket, no epic" "$G" pass "$(mcp_payload mcp__claude_ai_Atlassian__createJiraIssue \
      '{"projectKey":"PROJ","summary":"Open security group port 443 for the new client","description":"Add the client IP to the security groups."}')"
    assert "dependency injection bug, no epic"  "$G" pass "$(mcp_payload mcp__claude_ai_Atlassian__createJiraIssue \
      '{"projectKey":"PROJ","summary":"FieldTableMapper dependency injection crash"}')"
    assert "security word with exemption"       "$G" pass "$(mcp_payload mcp__claude_ai_Atlassian__createJiraIssue \
      '{"projectKey":"PROJ","summary":"Update the security improvements page layout","security_epic_exempt":"docs page, not a finding"}')"
  else
    skip=$((skip+1)); printf 'SKIP  %s security cases: .atlassian.securityEpicKey not configured\n' "$G"
  fi
else
  skip_gate "$G"
fi

# --------------------------------------------------------------- jira-ticket-fields-gate.sh
G=jira-ticket-fields-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  assert "new ticket with no assignee"          "$G" deny "$(mcp_payload mcp__claude_ai_Atlassian__createJiraIssue \
    '{"projectKey":"PROJ","summary":"x","description":"- acceptance criteria: y"}')"
  # Two things a wrongly-written case gets wrong here: the field is assignee_account_id (not
  # assignee), AND the gate requires the USER'S OWN accountId -- someone else's is itself a
  # denial ("default assignee is always the user's own unless they explicitly asked").
  SELFACC="$(jq -r '.user.jiraAccountId // empty' "$HOME/.claude/harness-config.json" 2>/dev/null | tr -d '\r')"
  if [ -n "$SELFACC" ]; then
    assert "new ticket assigned to the user"    "$G" pass "$(mcp_payload mcp__claude_ai_Atlassian__createJiraIssue \
      "$(jq -nc --arg a "$SELFACC" '{projectKey:"PROJ",summary:"x",assignee_account_id:$a,description:"- acceptance criteria: y"}')")"
    assert "new ticket assigned to someone else" "$G" deny "$(mcp_payload mcp__claude_ai_Atlassian__createJiraIssue \
      '{"projectKey":"PROJ","summary":"x","assignee_account_id":"ffffffffffffffffffffffff","description":"- acceptance criteria: y"}')"
  else
    skip=$((skip+1)); printf 'SKIP  %s: .user.jiraAccountId not configured\n' "$G"
  fi
else
  skip_gate "$G"
fi

# ---------------------------------------------------------- jira-ticket-description-gate.sh
G=jira-ticket-description-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  assert "description is prose only"            "$G" deny "$(mcp_payload mcp__claude_ai_Atlassian__createJiraIssue \
    '{"projectKey":"PROJ","summary":"x","assignee":"abc","description":"just some prose about the problem"}')"
  assert "description has required sections"    "$G" pass "$(mcp_payload mcp__claude_ai_Atlassian__createJiraIssue \
    '{"projectKey":"PROJ","summary":"x","assignee":"abc","issuetype":"Task","description":"h3. Requirements\n* thing\n\nh3. Acceptance criteria\n* works\n\nh3. How to test\n* run it"}')"
else
  skip_gate "$G"
fi

# -------------------------------------------------------- jira-fixversion-confirm-gate.sh
# Versions arrive at .tool_input.fields.fixVersions[].name (MCP) -- there is also an
# additional_fields form and a Bash/PAYLOAD_FILE form for the jira-create-issue.sh path.
G=jira-fixversion-confirm-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  # Deliberately absurd versions: confirmations persist in ~/.claude/harness-state/tickets/.confirmed-jira-versions,
  # so a real release number may already be confirmed on this machine and the gate would
  # correctly pass -- which reads as a gate bug. Keep test versions out of that file's range.
  assert "release/* Fix Version, unconfirmed"   "$G" deny "$(mcp_payload mcp__claude_ai_Atlassian__editJiraIssue \
    '{"issueKey":"PROJ-1","fields":{"fixVersions":[{"name":"release/999.0.0"}]}}')"
  assert "hotfix/* Fix Version, unconfirmed"    "$G" deny "$(mcp_payload mcp__claude_ai_Atlassian__editJiraIssue \
    '{"issueKey":"PROJ-1","fields":{"fixVersions":[{"name":"hotfix/999.0.9"}]}}')"
  # Deny gave no path; a forked session hunted ~/.claude for the script (harness-gaps 2026-10-12).
  assert_reason "deny names confirm script path" "$G" 'hooks/confirm-jira-version\.sh' "$(mcp_payload mcp__claude_ai_Atlassian__editJiraIssue \
    '{"issueKey":"PROJ-1","fields":{"fixVersions":[{"name":"release/999.0.0"}]}}')"
  assert "edit with no Fix Version"             "$G" pass "$(mcp_payload mcp__claude_ai_Atlassian__editJiraIssue \
    '{"issueKey":"PROJ-1","fields":{"summary":"new title"}}')"
  # Released-version check: JFVG_ISSUE_FILE fixture replaces the Jira read (never hits Jira).
  # New version is absurd so only the released-check can be what denies; every allow case below
  # would ALSO pass the confirm check only if confirmed, so allow cases use already-present names.
  _jf="$(mktemp)"; export JFVG_ISSUE_FILE="$_jf"; _cfg="$(mktemp)"
  printf '{"atlassian":{"regressionsTicketKey":"PROJ-77777","harnessEpicKey":"PROJ-88888"}}' > "$_cfg"
  edit_fv() { mcp_payload mcp__claude_ai_Atlassian__editJiraIssue "{\"issueKey\":\"$1\",\"fields\":{\"fixVersions\":$2}}"; }
  printf 'release/123.0.0	true
' > "$_jf"
  assert "add release/* onto released release/*" "$G" deny "$(edit_fv PROJ-2 '[{"name":"release/999.0.0"}]')"
  assert_reason "deny says new linked Bug"       "$G" 'new .*bug ticket' "$(edit_fv PROJ-2 '[{"name":"release/999.0.0"}]')"
  _pf="$(mktemp)"; printf '{"fields":{"fixVersions":[{"name":"release/999.0.0"}]}}' > "$_pf"
  assert "script path: add release onto released" "$G" deny "$(bash_payload "JIRA_PAYLOAD_FILE=$_pf bash skills/ama-jira-api/scripts/jira-edit-issue.sh PROJ-2")"
  rm -f "$_pf"; unset _pf
  printf 'release/123.0.0	true
hotfix/9.0.1	false
' > "$_jf"
  assert "append to keep released + add release" "$G" deny "$(edit_fv PROJ-2 '[{"name":"release/123.0.0"},{"name":"release/999.0.0"}]')"
  printf 'release/123.0.0	true
' > "$_jf"
  assert "payload only removes a version"        "$G" pass "$(edit_fv PROJ-2 '[]')"
  assert "payload keeps only present versions"   "$G" pass "$(edit_fv PROJ-2 '[{"name":"release/123.0.0"}]')"
  printf 'release/124.0.0	false
' > "$_jf"
  assert_reason "unreleased -> confirm path only" "$G" 'not yet confirmed' "$(edit_fv PROJ-2 '[{"name":"release/999.0.0"}]')"
  printf 'release/123.0.0	true
' > "$_jf"
  assert_reason "hotfix add is not the released deny" "$G" 'not yet confirmed' "$(edit_fv PROJ-2 '[{"name":"hotfix/999.0.9"}]')"
  HR_CONFIG_FILE="$_cfg" assert_reason "regressions key skips released check" "$G" 'not yet confirmed' "$(edit_fv PROJ-77777 '[{"name":"release/999.0.0"}]')"
  unset JFVG_ISSUE_FILE; rm -f "$_jf" "$_cfg"; unset _jf _cfg
else
  skip_gate "$G"
fi

# ----------------------------------------------------------------- human-readme-edit-gate.sh
# PostToolUse, block shape, and it needs a session_id: without one it fails open, so a case
# built with the plain builders passes vacuously.
G=human-readme-edit-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  # Both readme-family gates are ONE-SHOT per session: they record state under
  # ~/.claude/.session-chatfiles/<sid>* and stay quiet afterwards. Reusing one probe sid makes
  # the first case pass and every later one silently "pass" for the wrong reason -- and a
  # leftover file from an earlier run makes even the first case pass. Fresh sid per case,
  # cleaned both sides.
  probe_state_clean
  rp() { jq -n --arg p "$1" --arg s "$2" '{tool_name:"Edit",session_id:$s,tool_input:{file_path:$p,new_string:"x"}}'; }
  assert_block "edit to README.md"             "$G" block "$(rp "$real_harness/README.md" "$PROBE_SID-hr1")"
  assert_block "edit to AGENTS.md"             "$G" pass  "$(rp "$real_harness/AGENTS.md" "$PROBE_SID-hr2")"
  assert_block "edit to a hook"                "$G" pass  "$(rp "$real_harness/hooks/statusline.sh" "$PROBE_SID-hr3")"
  probe_state_clean
else
  skip_gate "$G"
fi

# ------------------------------------------------------------------ readme-currency-gate.sh
G=readme-currency-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  probe_state_clean
  # This gate also has a SIZE threshold: it accumulates changed lines per file per session and
  # stays quiet at <= 5, so a one-line payload passes even for a file AGENTS.md names. Both
  # halves are asserted -- the quiet-for-small-edits behaviour is a feature, not an absence.
  cp2() { jq -n --arg p "$1" --arg s "$2" --arg t "$3" '{tool_name:"Edit",session_id:$s,tool_input:{file_path:$p,new_string:$t}}'; }
  BIG="$(printf 'line %s\n' 1 2 3 4 5 6 7 8)"
  assert_block "big edit to a hook AGENTS.md names" "$G" block "$(cp2 "$real_harness/hooks/statusline.sh" "$PROBE_SID-rc1" "$BIG")"
  assert_block "one-line edit stays under threshold" "$G" pass "$(cp2 "$real_harness/hooks/statusline.sh" "$PROBE_SID-rc2" "x")"
  assert_block "big edit to a scratch file"          "$G" pass "$(cp2 "$real_harness/scratch/throwaway.md" "$PROBE_SID-rc3" "$BIG")"
  probe_state_clean
else
  skip_gate "$G"
fi

# ------------------------------------------------------- check-gates-unfiltered-gate.sh
# The NEGATIVE cases carry the weight here. A naive "the payload mentions check-gates.sh"
# gate denies every READ of the suite file -- including the gate recount GATES-AND-HOOKS.md
# tells agents to run -- and this gate denied two real read-only commands on its first two
# live calls: a bare variable assignment holding the path, and a heredoc body containing a
# fixture command. Both are pinned below; do not "simplify" the segment parsing away.
G=check-gates-unfiltered-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  assert "unfiltered suite run"              "$G" deny "$(bash_payload 'bash scripts/check-gates.sh')"
  assert "unfiltered, quoted abs path"       "$G" deny "$(bash_payload 'bash "/c/x/scripts/check-gates.sh" 2>&1 | tail -5')"
  assert "direct exec, unfiltered"           "$G" deny "$(bash_payload './scripts/check-gates.sh')"
  assert "--gate filtered"                   "$G" pass "$(bash_payload 'bash scripts/check-gates.sh --gate foo.sh')"
  assert "CHECK_GATES_ONLY filtered"         "$G" pass "$(bash_payload 'CHECK_GATES_ONLY=foo.sh bash scripts/check-gates.sh')"
  assert "CHECK_GATES_FULL escape hatch"     "$G" pass "$(bash_payload 'CHECK_GATES_FULL=1 bash scripts/check-gates.sh')"
  assert "sanctioned full-pass wrapper"      "$G" pass "$(bash_payload 'bash scripts/run-check-gates-full.sh')"
  assert "cat the suite file"                "$G" pass "$(bash_payload 'cat scripts/check-gates.sh')"
  assert "git diff the suite file"           "$G" pass "$(bash_payload 'git diff scripts/check-gates.sh')"
  assert "documented gate recount"           "$G" pass "$(bash_payload "grep -oE '^G=' scripts/check-gates.sh | sort -u | wc -l")"
  assert "var assignment holding the path"   "$G" pass "$(bash_payload 'C=/x/scripts/check-gates.sh')"
  assert "grep alternation \\| is no pipe"   "$G" pass "$(bash_payload 'grep -n "G=dispatch\|HOME=x" $R/scripts/check-gates.sh | head')"
  assert "invocation after an escaped pipe"  "$G" deny "$(bash_payload 'echo a\|b; bash scripts/check-gates.sh')"
  assert "heredoc body is data"              "$G" pass "$(bash_payload "$(printf 'cat > f.sh <<%sEOF%s
bash scripts/check-gates.sh
EOF
' "'" "'")")"
  assert "command after heredoc counts"      "$G" deny "$(bash_payload "$(printf 'cat > f.sh <<%sEOF%s
hello
EOF
bash scripts/check-gates.sh
' "'" "'")")"
  assert "bare mutate-gates (~35min)"        "$G" deny "$(bash_payload 'bash scripts/mutate-gates.sh')"
  assert "targeted mutate-gates"             "$G" pass "$(bash_payload 'bash scripts/mutate-gates.sh my-gate.sh')"
  # Reasons, not just decisions: bare-cd once shipped a correct deny with a FALSE reason.
  assert_reason "unfiltered names the filtered form" "$G" '\-\-gate <gate\.sh>' "$(bash_payload 'bash scripts/check-gates.sh')"
  assert_reason "bare mutate names targeted form"    "$G" 'mutate-gates\.sh <gate\.sh>' "$(bash_payload 'bash scripts/mutate-gates.sh')"
else
  skip_gate "$G"
fi

# -------------------------------------------------------- check-gates-currency-gate.sh
# Nudges when an edited file is one THIS SUITE asserts about. Two things are pinned: that a
# statically-pinned non-gate file is caught (the 4e54f3b miss this gate exists for), and that
# an UNPINNED skill is not -- a bare-basename key would fire on every skill in the fleet,
# since SKILL.md appears 24x here as unrelated fixture text.
#
# CLAUDE_STATE_DIR is redirected for these cases: the gate ARMS the real full-run-owed marker
# as a side effect, and this suite must not write live state it does not own.
G=check-gates-currency-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  probe_state_clean
  CGT="$(cgmktemp -d "/tmp/gatefix-cg.XXXXXX")"
  # lib-claude-paths.sh:23 SETS CLAUDE_STATE_DIR without exporting it, and this suite sources
  # that lib at line 29 -- so the var is set-but-unexported for the whole run, and the hstate
  # meta-test below depends on it NOT reaching a subprocess environment. Exporting it here and
  # restoring it with `export` still leaves the export ATTRIBUTE set, which leaked into that
  # meta-test and failed it ("default CLAUDE_STATE_DIR still absorbs"). Restore with
  # `export -n` to put the variable back exactly as it was: same value, not exported.
  _cg_prev_state="${CLAUDE_STATE_DIR:-}"
  export CLAUDE_STATE_DIR="$CGT/state"
  cg() { jq -n --arg p "$1" --arg s "$2" '{tool_name:"Edit",session_id:$s,tool_input:{file_path:$p,new_string:"x"}}'; }
  # SELF-REFERENTIAL FIXTURE TRAP (GATES-AND-HOOKS.md's fixture-traps section): this gate
  # matches on the edited file's last TWO path components appearing in THIS file, so writing
  # the negative case's path as one literal makes the suite pin it and the case inverts --
  # observed, "edit to an unpinned SKILL.md" came back block. The components are kept in
  # separate variables so the adjacent literal never exists in this source.
  UNPIN_DIR="caveman"; UNPIN_FILE="SKILL.md"
  assert_block "edit to a gate the suite pins"     "$G" block "$(cg "$real_harness/hooks/subagent-model-tiering-gate.sh" "$PROBE_SID-cc1")"
  assert_block "edit to a statically pinned file"  "$G" block "$(cg "$real_harness/skills/ama-harness-gaps/scripts/harness-gaps-unattended-run.sh" "$PROBE_SID-cc2")"
  assert_block "edit to a non-gate hook it pins"   "$G" block "$(cg "$real_harness/hooks/on-prompt.sh" "$PROBE_SID-cc3")"
  assert_block "edit to an unpinned skill file"    "$G" pass  "$(cg "$real_harness/skills/$UNPIN_DIR/$UNPIN_FILE" "$PROBE_SID-cc4")"
  assert_block "edit to the suite itself"          "$G" pass  "$(cg "$real_harness/scripts/check-gates.sh" "$PROBE_SID-cc5")"
  assert_block "same file twice, second is quiet"  "$G" pass  "$(cg "$real_harness/hooks/on-prompt.sh" "$PROBE_SID-cc3")"
  # The reminder must NOT be a one-shot. on-prompt.sh DRAINS the digest as it relays and the
  # daily task that refilled it deleted itself, so tying the digest line to marker CREATION
  # left the marker armed and silent forever after one mention. Assert a second session still
  # gets a line while the marker stands.
  _cg_dg="$CLAUDE_STATE_DIR/notices/check-gates-reminder.txt"
  _cg_n1="$(wc -l < "$_cg_dg" 2>/dev/null || printf 0)"
  cg_out="$(cg "$real_harness/hooks/on-prompt.sh" "$PROBE_SID-cc6")"
  printf '%s' "$cg_out" | bash "$hooks/$G" >/dev/null 2>&1
  _cg_n2="$(wc -l < "$_cg_dg" 2>/dev/null || printf 0)"
  if [ "${_cg_n2:-0}" -gt "${_cg_n1:-0}" ]; then pass=$((pass+1)); else
    fail=$((fail+1)); printf 'FAIL  %-46s
' "check-gates-currency: reminder went one-shot"; fi
  [ -e "$CLAUDE_STATE_DIR/notices/.check-gates-full-run-owed" ] && pass=$((pass+1)) || {
    fail=$((fail+1)); printf 'FAIL  %-46s
' "check-gates-currency: marker not armed"; }
  # The marker is a LEDGER, not a bare flag: run-check-gates-full.sh sweeps only the sections
  # it names, so what lands here decides what actually gets re-run. Three shapes must be
  # right, and the middle one is the whole reason this is not just a boolean:
  #   - a gate edit records its own section;
  #   - a NON-gate file records the gate section that really asserts about it. Recording it
  #     as "suite-level only" would clear the reminder while leaving that gate unrun, which
  #     is silently worse than the blunt full pass this replaces;
  #   - a file the suite never mentions records N:, because only the always-on suite-level
  #     assertions can cover it and every filtered run already includes those.
  _cg_mk="$CLAUDE_STATE_DIR/notices/.check-gates-full-run-owed"
  printf '%s' "$(cg "$real_harness/scripts/mutate-gates.sh" "$PROBE_SID-cc7")" | bash "$hooks/$G" >/dev/null 2>&1
  grep -qxF 'G:subagent-model-tiering-gate.sh' "$_cg_mk" 2>/dev/null && pass=$((pass+1)) || {
    fail=$((fail+1)); printf 'FAIL  %-46s\n' "check-gates-currency: gate edit absent from ledger"; }
  grep -qxF 'G:check-gates-unfiltered-gate.sh' "$_cg_mk" 2>/dev/null && pass=$((pass+1)) || {
    fail=$((fail+1)); printf 'FAIL  %-46s\n' "check-gates-currency: non-gate file mismapped"; }
  grep -qxF 'N:' "$_cg_mk" 2>/dev/null && pass=$((pass+1)) || {
    fail=$((fail+1)); printf 'FAIL  %-46s\n' "check-gates-currency: unmentioned file not N:"; }
  CLAUDE_STATE_DIR="$_cg_prev_state"
  export -n CLAUDE_STATE_DIR 2>/dev/null || true
  [ -n "$_cg_prev_state" ] || unset CLAUDE_STATE_DIR
  rm -rf "$CGT"
  probe_state_clean
else
  skip_gate "$G"
fi

# ===================================================== side-effect assertions
# Some hooks decide nothing and instead WRITE state (a queued notice statusline.sh later
# relays). Asserting their exit code proves nothing -- assert the artifact.
assert_writes() {
  local desc="$1" gate="$2" payload="$3" file="$4" want="$5" got="absent"
  printf '%s' "$payload" | bash "$hooks/$gate" >/dev/null 2>&1 || true
  [ -f "$file" ] && grep -qE "$want" "$file" 2>/dev/null && got="written"
  if [ "$got" = "written" ]; then pass=$((pass+1)); else
    fail=$((fail+1)); printf 'FAIL  %-46s want=%-5s got=%s\n' "$desc" "written" "$got"
  fi
}
assert_no_write() {
  local desc="$1" gate="$2" payload="$3" file="$4" before after
  # `wc -l < missing` fails at the redirect, before wc runs, so the `|| printf 0` never
  # applies and the run prints shell noise. Test for the file first.
  before=0; [ -f "$file" ] && before="$(wc -l < "$file" 2>/dev/null)"
  printf '%s' "$payload" | bash "$hooks/$gate" >/dev/null 2>&1 || true
  after=0; [ -f "$file" ] && after="$(wc -l < "$file" 2>/dev/null)"
  if [ "$before" = "$after" ]; then pass=$((pass+1)); else
    fail=$((fail+1)); printf 'FAIL  %-46s want=%-5s got=%s\n' "$desc" "no-write" "grew $before->$after"
  fi
}

# ------------------------------------------------------------------- skill-bloat-gate.sh
G=skill-bloat-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  BLOAT="Confirmed real gap: on 2026-08-14 the exporter run failed because the vendor changed the column order without notice, which meant the mapper silently wrote the wrong field, and it took two hours of Graylog digging to find it, after which we rewrote the loader and added a schema assertion so the next occurrence fails loudly instead of silently."
  TERSE="Vendor column order drifts -- assert schema, fail loud."
  assert "incident narrative into a SKILL.md"  "$G" deny "$(edit_payload "$real_harness/skills/ama-debugging-notes/SKILL.md" "$BLOAT")"
  assert "terse tag into the same SKILL.md"    "$G" pass "$(edit_payload "$real_harness/skills/ama-debugging-notes/SKILL.md" "$TERSE")"
  # Scope: the anti-bloat rule is about skills. The same prose in AGENTS.md is out of scope --
  # that file is allowed to explain at length.
  assert "same narrative into AGENTS.md"       "$G" pass "$(edit_payload "$real_harness/AGENTS.md" "$BLOAT")"
else
  skip_gate "$G"
fi

# ------------------------------------------------------------ octopus-lambda-delete-gate.sh
# Blocks creating an Octopus deployment for a lambda project unless `aws lambda delete-function`
# was recorded for THIS session within 2h (marker: ~/.claude/.lambda-deleted-<sid>). Blocks via
# stderr + non-zero exit, not JSON -- hence assert_block.
G=octopus-lambda-delete-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  OSID="$PROBE_SID-oct"
  MARKER="$(hstate tickets ".lambda-deleted-$OSID")"
  rm -f "$MARKER" 2>/dev/null || true
  DEPLOY='curl -sS -X POST "https://example.octopus.app/api/Spaces-1/deployments" -d @body.json'
  op() { jq -nc --arg c "$1" --arg s "$OSID" '{tool_name:"Bash",session_id:$s,tool_input:{command:$c}}'; }
  assert_block "deployment POST, no delete recorded" "$G" block "$(op "$DEPLOY")"
  # Documented escape hatch for non-lambda projects, and a read of the same endpoint.
  assert_block "same POST with the NOT_LAMBDA opt-out" "$G" pass "$(op "OCTOPUS_TARGET_NOT_LAMBDA=1 $DEPLOY")"
  # The sanctioned wrapper deletes the function itself before its POST (2026-10-15).
  assert_block "deploy-lambda.sh wrapper passes"      "$G" pass "$(op 'bash ~/.claude/skills/ama-octopus-deploy/scripts/deploy-lambda.sh <production> production Releases-20810 cacheupdate-lambda')"
  assert_block "GET of the deployments endpoint"       "$G" pass "$(op 'curl -sS "https://example.octopus.app/api/Spaces-1/deployments?take=1"')"
  # With a fresh delete marker the deploy is licensed. Timestamp must be current: the window
  # is 2h, so a stale marker correctly does NOT license it.
  date +%s > "$MARKER"
  assert_block "deployment POST after a recorded delete" "$G" pass "$(op "$DEPLOY")"
  printf '%s\n' 1 > "$MARKER"
  assert_block "deployment POST with a stale marker"     "$G" block "$(op "$DEPLOY")"
  rm -f "$MARKER" 2>/dev/null || true
  # The 2026-09-15 bypass, pinned. The gate's matcher joined the POST verb and the endpoint
  # with `.*`; grep -P is line-scoped, so an ordinary multi-line curl -- written into a
  # script by a heredoc and run in the same command, which is the shape parallel-fanout-gate
  # and unanalyzable-script-gate push deploys into -- matched nothing and a real Staging
  # Lambda deploy went through with no delete-function. Match the tokens independently.
  ML_DEPLOY='cat > /tmp/octo.sh <<'"'"'EOF'"'"'
RESP="$(curl -sS -H "$H" -X POST \
  -d "{\"EnvironmentId\":\"<staging>\"}" \
  "$S/api/Spaces-1/deployments")"
EOF
bash /tmp/octo.sh'
  assert_block "multi-line POST written by heredoc, then run" "$G" block "$(op "$ML_DEPLOY")"
  # The other half of that fix: a heredoc body that only DESCRIBES the endpoint is data.
  # Scanning heredoc bodies unconditionally reopens the self-denial trap inplace-edit-gate.sh
  # and deploy-verify-confirm-gate.sh both fell into, so the body counts only when the same
  # command also executes the file it wrote.
  DESCRIBES='git commit -q -F - <<'"'"'EOF'"'"'
Document the gate

It matches a POST to api/Spaces-1/deployments made with -X POST.
EOF'
  assert_block "commit message describing the endpoint"       "$G" pass  "$(op "$DESCRIBES")"
  # The POST inside a scratch script, run by name: the command text never says "deployments".
  # Bypassed live on the UpdateCacheState Staging redeploy (2026-09-15).
  LS="$(cgmktemp -d "/tmp/gatefix-lambdaref.XXXXXX")"; mkdir -p "$LS/scratch"
  printf '%s\n' "$DEPLOY" > "$LS/scratch/deploy.sh"
  assert_block "deployment POST inside a scratch script"       "$G" block "$(op "bash $LS/scratch/deploy.sh")"
else
  skip_gate "$G"
fi

# ------------------------------------------------------------ bitbucket-pr-approve-gate.sh
# Policy 2026-10-16: AI agents may not approve PRs, may merge them.
G=bitbucket-pr-approve-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  BBA='https://api.bitbucket.org/2.0/repositories/yourorg/yourproduct-backbone/pullrequests'
  assert        "approve, numeric PR id"           "$G" deny "$(bash_payload "curl -sS -u \"\$A\" -X POST $BBA/24/approve")"
  assert_reason "  ...reason names the policy"     "$G" 'may not approve' "$(bash_payload "curl -sS -u \"\$A\" -X POST $BBA/24/approve")"
  assert        "approve, \$ID variable"            "$G" deny "$(bash_payload "curl -sS -X POST \"\$BB_API/\$SLUG/pullrequests/\$ID/approve\"")"
  assert        "approve, PowerShell"              "$G" deny "$(jq -nc --arg c "Invoke-RestMethod -Method Post -Uri $BBA/24/approve" '{tool_name:"PowerShell",tool_input:{command:$c}}')"
  assert        "unapprove (DELETE)"               "$G" pass "$(bash_payload "curl -sS -X DELETE $BBA/24/approve")"
  assert        "merge"                            "$G" pass "$(bash_payload "curl -sS -X POST $BBA/24/merge")"
  assert        "request-changes"                  "$G" pass "$(bash_payload "curl -sS -X POST $BBA/24/request-changes")"
  assert        "grep for the word approve"        "$G" pass "$(bash_payload "grep -n approve skills/ama-pr-review/SKILL.md")"
  assert        "endpoint in a commit message"     "$G" pass "$(bash_payload "git commit -m 'gate denies .../pullrequests/<id>/approve POST' -- hooks/x.sh")"
fi

# ------------------------------------------------------------ octopus-task-cancel-gate.sh
# Denies cancelling an Octopus task this session did not start (2026-10-13: a session
# cancelled another session's PROJ-15654 Staging deploy). --record ledgers the task ids
# a deploy POST returned. State + projects dirs seamed to throwaway trees.
G=octopus-task-cancel-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  TCB="$(cgmktemp -d "${TMPDIR:-/tmp}/gatefix-tcancel.XXXXXX")"; mkdir -p "$TCB/state" "$TCB/proj/p" "$TCB/scratch"
  _tc_sd="${CLAUDE_STATE_DIR-}"; _tc_pd="${CLAUDE_PROJECTS_DIR-}"
  export CLAUDE_STATE_DIR="$TCB/state" CLAUDE_PROJECTS_DIR="$TCB/proj"
  TSID=tcancel-me
  tcp() { jq -nc --arg c "$1" --arg s "$TSID" '{tool_name:"Bash",session_id:$s,tool_input:{command:$c}}'; }
  tcr() { jq -nc --arg c "$1" --arg r "$2" --arg s "$TSID" '{tool_name:"Bash",session_id:$s,hook_event_name:"PostToolUse",tool_input:{command:$c},tool_response:{stdout:$r,stderr:""}}'; }
  CANCEL='curl -sS -X POST -H "$H" "$O/tasks/ServerTasks-900001/cancel"'
  assert        "cancel of a task this session never started" "$G" deny "$(tcp "$CANCEL")"
  assert_reason "  ...reason names the task"                  "$G" 'ServerTasks-900001' "$(tcp "$CANCEL")"
  assert_reason "  ...reason names the hatch"                 "$G" 'AMA_CANCEL_FOREIGN_TASK=1' "$(tcp "$CANCEL")"
  assert        "same cancel with the user-approved hatch"     "$G" pass "$(tcp "AMA_CANCEL_FOREIGN_TASK=1 $CANCEL")"
  assert        "GET of the task (status read)"                "$G" pass "$(tcp 'curl -sS -H "$H" "$O/tasks/ServerTasks-900001"')"
  assert        "cancel with no literal task id"               "$G" deny "$(tcp 'curl -sS -X POST "$O/tasks/$t/cancel"')"
  # The incident's shape: a scratch script does the POST, the id rides in as an argument.
  printf '%s\n' 'for t in "$@"; do curl -sS -X POST -H "$H" "$O/tasks/$t/cancel"; done' > "$TCB/scratch/oct-cancel.sh"
  assert        "scratch cancel script, foreign id as arg"     "$G" deny "$(tcp "bash $TCB/scratch/oct-cancel.sh ServerTasks-900001")"
  # A live OTHER session mentioning the task is named in the reason.
  printf '%s\n' '{"type":"user","text":"deploying ServerTasks-900001"}' > "$TCB/proj/p/other-live-session.jsonl"
  assert_reason "  ...names the live session mentioning it"    "$G" 'live session.*other-li' "$(tcp "$CANCEL")"
  # Own deploy recorded -> own cancel allowed; the record needs a deploy POST, not any output.
  LEDGER="$TCB/state/sessions/octopus-task-owners"
  DEP='curl -sS -X POST -H "$H" -d @b.json "$O/deployments"'
  printf '%s' "$(tcr 'curl -sS "$O/tasks/ServerTasks-900002"' 'ServerTasks-900002 Executing')" | bash "$hooks/$G" --record >/dev/null 2>&1
  if grep -q 'ServerTasks-900002' "$LEDGER" 2>/dev/null; then fail=$((fail+1)); printf 'FAIL  %-46s\n' "status read output is not ledgered"; else pass=$((pass+1)); fi
  printf '%s' "$(tcr "$DEP" 'Deployments-1	ServerTasks-900002')" | bash "$hooks/$G" --record >/dev/null 2>&1
  if grep -q "^ServerTasks-900002	$TSID	" "$LEDGER" 2>/dev/null; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL  %-46s\n' "deploy POST response ledgered"; fi
  assert        "cancel of this session's own deploy"          "$G" pass "$(tcp 'curl -sS -X POST "$O/tasks/ServerTasks-900002/cancel"')"
  assert        "own + foreign in one cancel"                  "$G" deny "$(tcp 'bash x.sh ServerTasks-900002 ServerTasks-900001; curl -X POST "$O/tasks/$t/cancel"')"
  # export -n, not export: see check-gates-currency-gate.sh's section (the absorb meta-test).
  CLAUDE_STATE_DIR="$_tc_sd"; export -n CLAUDE_STATE_DIR
  if [ -n "$_tc_pd" ]; then export CLAUDE_PROJECTS_DIR="$_tc_pd"; else unset CLAUDE_PROJECTS_DIR; fi
  rm -rf "$TCB" 2>/dev/null || true
else
  skip_gate "$G"
fi

# ------------------------------------------------------- octopus-approve-preflight-gate.sh
# Denies Claude approving an Octopus intervention (POST interruptions/<id>/submit, or a helper
# `approve ServerTasks-N`) without a fresh SAFE/REVIEW stamp from octopus-approval-preflight.sh
# (2026-10-15: an approved RabbitMq plan swapped a load balancer's security group).
G=octopus-approve-preflight-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  APB="$(cgmktemp -d "${TMPDIR:-/tmp}/gatefix-apf.XXXXXX")"; mkdir -p "$APB/state/octopus/approval-preflight"
  _ap_sd="${CLAUDE_STATE_DIR-}"; export CLAUDE_STATE_DIR="$APB/state"
  apst() { printf '%s %s P\n' "$2" "${3:-$(date +%s)}" > "$APB/state/octopus/approval-preflight/$1"; }
  app() { jq -nc --arg c "$1" '{tool_name:"Bash",session_id:"apf",tool_input:{command:$c}}'; }
  SUB='curl -sS -X POST -H "$H" -d @b.json "$O/interruptions/Interruptions-5/submit"'
  apst ServerTasks-910001 SAFE; apst ServerTasks-910002 STALE; apst ServerTasks-910003 NETWORK
  apst ServerTasks-910004 SAFE 1000; apst ServerTasks-910005 REVIEW
  assert        "approve helper, SAFE stamp"                 "$G" pass "$(app 'bash oct-deploy.sh approve ServerTasks-910001')"
  assert        "approve helper, REVIEW stamp"               "$G" pass "$(app 'bash oct-deploy.sh approve ServerTasks-910005')"
  assert        "approve helper, never preflighted"          "$G" deny "$(app 'bash oct-deploy.sh approve ServerTasks-910009')"
  assert_reason "  ...reason names the preflight script"     "$G" 'octopus-approval-preflight.sh' "$(app 'bash oct-deploy.sh approve ServerTasks-910009')"
  assert        "approve helper, STALE stamp"                "$G" deny "$(app 'bash oct-deploy.sh approve ServerTasks-910002')"
  assert        "approve helper, stamp >3h old"              "$G" deny "$(app 'bash oct-deploy.sh approve ServerTasks-910004')"
  assert        "NETWORK stamp, no user ack"                 "$G" deny "$(app 'bash oct-deploy.sh approve ServerTasks-910003')"
  assert_reason "  ...reason names the network hatch"        "$G" 'AMA_APPROVE_NETWORK_ACK=1' "$(app 'bash oct-deploy.sh approve ServerTasks-910003')"
  assert        "NETWORK stamp, user-acked hatch"            "$G" pass "$(app 'AMA_APPROVE_NETWORK_ACK=1 bash oct-deploy.sh approve ServerTasks-910003')"
  assert        "raw interruption submit, no task id"        "$G" deny "$(app "$SUB")"
  assert        "raw submit naming a SAFE task"              "$G" pass "$(app "T=ServerTasks-910001; $SUB")"
  assert        "GET interruptions list (read-only)"         "$G" pass "$(app 'curl -sS -H "$H" "$O/interruptions?regarding=ServerTasks-910002"')"
  assert        "the word approve in an echo"                "$G" pass "$(app 'echo "waiting for you to approve"')"
  CLAUDE_STATE_DIR="$_ap_sd"; export -n CLAUDE_STATE_DIR
  rm -rf "$APB" 2>/dev/null || true
else
  skip_gate "$G"
fi

# -------------------------------------------------------------- graylog-write-gate.sh
# (a) raw curl PUT/POST/DELETE against /api/system/pipelines -> denied, except the
#     validate-only .../rule/parse endpoint (persists nothing). (b) ANY write attempt --
#     raw curl or the sanctioned scripts -- denied outright when the transcript's
#     entrypoint is sdk-cli (headless), same detection as slack-signature-gate.sh.
G=graylog-write-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  GLBASE="$(cgmktemp -d "${TMPDIR:-/tmp}/gatefix-glw.XXXXXX")"
  TR_HEADLESS="$GLBASE/headless.jsonl"; TR_INTERACTIVE="$GLBASE/interactive.jsonl"
  jq -nc '{entrypoint:"sdk-cli"}' > "$TR_HEADLESS"
  jq -nc '{entrypoint:"cli"}'     > "$TR_INTERACTIVE"
  glop() { jq -nc --arg c "$1" --arg tr "$2" '{tool_name:"Bash",transcript_path:$tr,tool_input:{command:$c}}'; }
  RAW_PUT='curl -sS -u "$GRAYLOG_PAT:token" -X PUT -d @body.json "http://gl:9000/api/system/pipelines/rule/abc123"'
  RAW_PARSE='curl -sS -u "$GRAYLOG_PAT:token" -X POST -d @body.json "http://gl:9000/api/system/pipelines/rule/parse"'
  RAW_GET='curl -sS -u "$GRAYLOG_PAT:token" "http://gl:9000/api/system/pipelines/rule/abc123"'
  SCRIPT_WRITE='bash ~/.claude/skills/ama-graylog-search/scripts/graylog-rule-write.sh update abc123'
  assert "raw curl PUT on pipelines denied (interactive)"    "$G" deny "$(glop "$RAW_PUT" "$TR_INTERACTIVE")"
  assert "raw curl POST rule/parse allowed (validate-only)"  "$G" pass "$(glop "$RAW_PARSE" "$TR_INTERACTIVE")"
  assert "raw curl GET on pipelines untouched"               "$G" pass "$(glop "$RAW_GET" "$TR_INTERACTIVE")"
  assert "sanctioned write script allowed (interactive)"     "$G" pass "$(glop "$SCRIPT_WRITE" "$TR_INTERACTIVE")"
  assert "sanctioned write script denied (headless)"         "$G" deny "$(glop "$SCRIPT_WRITE" "$TR_HEADLESS")"
  assert "raw curl PUT denied (headless, both rules fire)"   "$G" deny "$(glop "$RAW_PUT" "$TR_HEADLESS")"
  assert "unrelated curl untouched"                          "$G" pass "$(glop 'curl -sS "https://example.com"' "$TR_INTERACTIVE")"
  # 2026-09-15 replay: the write inside a heredoc-written script run in the same command.
  assert "heredoc-written script, run in same command"       "$G" deny "$(glop "cat > \"\$HOME/.claude/scratch/x/g.sh\" <<'EOF'
$RAW_PUT
EOF
bash \"\$HOME/.claude/scratch/x/g.sh\"" "$TR_INTERACTIVE")"
  assert "commit message describing the PUT"                 "$G" pass "$(glop "git commit -F - <<EOF
graylog-rule-write.sh does the curl -X PUT against /api/system/pipelines for us
EOF" "$TR_INTERACTIVE")"
  rm -rf "$GLBASE" 2>/dev/null || true
else
  skip_gate "$G"
fi

# --------------------------------------------------------- chrome-verify-compact-nudge.sh
# Decides nothing: queues a /compact recommendation into .ctx-notices-<sid> for on-prompt.sh
# to relay, and is one-shot per session. (This comment used to say statusline.sh -- it is a
# WRITER of that file, never its reader. The relay is asserted in the on-prompt.sh section
# below; until 2026-09-03 it did not exist and this section's write-only assertions passed
# anyway, for three weeks, while 8 real Chrome nudges went undelivered.)
G=chrome-verify-compact-nudge.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  CSID="$PROBE_SID-chrome"
  NOTICE="$(hstate sessions ".ctx-notices-$CSID")"
  # The one-shot guard lives SEPARATELY from the notice, in
  # ~/.claude/harness-state/sessions/.usage-state/chrome-compact-nudged-<sid>. Cleaning only
  # the notice made this case pass exactly once and fail on every later run -- the same
  # state-leak class as the readme family. Both files, both sides.
  NGUARD="$(hstate sessions ".usage-state/chrome-compact-nudged-$CSID")"
  rm -f "$NOTICE" "$NGUARD" 2>/dev/null || true
  cn() { jq -nc --arg s "$CSID" '{tool_name:"mcp__claude-in-chrome__tabs_close_mcp",session_id:$s,tool_input:{}}'; }
  assert_writes   "closing a verify tab queues a /compact notice" "$G" "$(cn)" "$NOTICE" "compact"
  assert_no_write "second close does not re-queue it"             "$G" "$(cn)" "$NOTICE"
  rm -f "$NOTICE" "$NGUARD" 2>/dev/null || true
else
  skip_gate "$G"
fi

# ---------------------------------------------------------- chrome-activity-track.sh
# Stamps .chrome-active-<sid> with the current prompt number on every claude-in-chrome call;
# on-prompt.sh's idle check reads it (asserted in the on-prompt.sh section below).
G=chrome-activity-track.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  TSID="$PROBE_SID-track"
  TACT="$(hstate sessions ".chrome-active-$TSID")"
  rm -f "$TACT" 2>/dev/null || true
  printf 7 > "$HOME/.claude/.session-chatfiles/$TSID.promptn"
  ct() { jq -nc --arg s "$TSID" '{tool_name:"mcp__claude-in-chrome__computer",session_id:$s,tool_input:{action:"screenshot"}}'; }
  assert_writes "chrome call stamps the current prompt number" "$G" "$(ct)" "$TACT" "^7$"
  rm -f "$TACT" "$HOME/.claude/.session-chatfiles/$TSID.promptn" 2>/dev/null || true
else
  skip_gate "$G"
fi

# ----------------------------------------------------------- chrome-compact-rearm.sh
# SessionStart(compact): deletes the one-shot guard + activity marker so the next verify loop
# in the same session nudges again. Assert absence, not exit code.
G=chrome-compact-rearm.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  RSID="$PROBE_SID-rearm"
  RG="$(hstate sessions ".usage-state/chrome-compact-nudged-$RSID")"; RA="$(hstate sessions ".chrome-active-$RSID")"
  touch "$RG"; printf 1 > "$RA"
  jq -nc --arg s "$RSID" '{session_id:$s,source:"compact"}' | bash "$hooks/$G" >/dev/null 2>&1 || true
  if [ ! -f "$RG" ] && [ ! -f "$RA" ]; then pass=$((pass+1)); else
    fail=$((fail+1)); printf 'FAIL  %-46s want=%-5s got=%s\n' "compact clears nudge guard + activity marker" "gone" "guard=$([ -f "$RG" ] && echo present || echo gone) marker=$([ -f "$RA" ] && echo present || echo gone)"
  fi
  rm -f "$RG" "$RA" 2>/dev/null || true
else
  skip_gate "$G"
fi

# ------------------------------------------------------------------------- on-prompt.sh
# READ side of the notice pipeline. Everything else in this suite asserts that a hook
# WRITES its notice file; nothing asserted that anyone ever reads one. That gap let two
# relays sit dark for weeks with the suite green: .usage-notices was read from a literal
# pre-migration path that no longer existed (that relay is gone now -- the status bar
# already shows the numbers), and .ctx-notices-<sid> (statusline.sh's context crossings +
# chrome-verify-compact-nudge.sh) had no reader at all -- 18 stale files and 8 undelivered
# Chrome nudges on disk. So: assert the text reaches injected context AND that the file is
# drained, for every surviving channel.
#
# CLAUDE_STATE_DIR is sandboxed, so no live notice is consumed by a test run. The nudge
# throttle marker is pre-created deliberately: it makes _nudge_due=0 so the six sourced
# cadence checks (network, dozens of forks) are skipped wholesale, keeping this hermetic
# and fast and focused on the two relays.
G=on-prompt.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  OPBASE="$(hscratch check-gates "onprompt-$PROBE_TAG")"
  rm -rf "$OPBASE" 2>/dev/null || true
  mkdir -p "$OPBASE/notices" "$OPBASE/sessions" 2>/dev/null
  touch "$OPBASE/notices/.nudge-checks-lastrun" 2>/dev/null
  OPSID="$PROBE_SID-onprompt"

  # cwd is MANDATORY in the payload: without it on-prompt.sh exits early, silently, with
  # zero output -- so a cwd-less probe looks exactly like a broken relay.
  # op_relay <desc> <seed-file> <seed-text> <want-regex-in-context>
  # Asserts BOTH halves: the text is relayed, and the one-shot file ends up empty.
  op_relay() {
    local desc="$1" file="$2" seed="$3" want="$4" out="" left=1
    printf '%s\n' "$seed" > "$file"
    out="$(jq -nc --arg s "$OPSID" --arg c "$HARNESS_CWD" '{session_id:$s,prompt:"x",cwd:$c,hook_event_name:"UserPromptSubmit"}' \
      | CLAUDE_STATE_DIR="$OPBASE" bash "$hooks/$G" 2>/dev/null)"
    [ -s "$file" ] || left=0
    if printf '%s' "$out" | grep -qE "$want" && [ "$left" = 0 ]; then pass=$((pass+1)); else
      fail=$((fail+1))
      printf 'FAIL  %-46s relayed=%s drained=%s\n' "$desc" \
        "$(printf '%s' "$out" | grep -qE "$want" && echo yes || echo NO)" \
        "$([ "$left" = 0 ] && echo yes || echo NO)"
    fi
  }

  op_relay "ctx/compact notice is relayed + drained" \
    "$OPBASE/sessions/.ctx-notices-$OPSID" "GATEPROBE-CTX closed a verify tab, recommend /compact" "GATEPROBE-CTX"
  # The weekly harness-gaps digest was only string-checked (`grep -c` on the hook source),
  # i.e. the same write-only blindness this section exists to end (2026-09-07).
  op_relay "harness-gaps review digest relayed + drained" \
    "$OPBASE/notices/harness-gaps-review.txt" "GATEPROBE-HG DONE 3 entries cleared" "GATEPROBE-HG"
  # check-gates "pass owed" digest is HELD while process start is slow (acting on it mid-spell
  # adds a suite to the load, 2026-10-22), relayed once it recovers. Marker = dispatch.sh's.
  mkdir -p "$OPBASE/logs" 2>/dev/null
  printf '%s 120 90' "$EPOCHSECONDS" > "$OPBASE/logs/.proc-start-latency-last"
  op_relay "check-gates digest relayed when start is fast" \
    "$OPBASE/notices/check-gates-reminder.txt" "GATEPROBE-CG pass is owed" "GATEPROBE-CG"
  printf '%s 950 500' "$EPOCHSECONDS" > "$OPBASE/logs/.proc-start-latency-last"
  printf 'GATEPROBE-CG2 pass is owed\n' > "$OPBASE/notices/check-gates-reminder.txt"
  op_out="$(jq -nc --arg s "$OPSID" --arg c "$HARNESS_CWD" '{session_id:$s,prompt:"x",cwd:$c,hook_event_name:"UserPromptSubmit"}' \
    | CLAUDE_STATE_DIR="$OPBASE" bash "$hooks/$G" 2>/dev/null)"
  if ! printf '%s' "$op_out" | grep -q 'GATEPROBE-CG2' && [ -s "$OPBASE/notices/check-gates-reminder.txt" ]; then
    pass=$((pass+1)); else
    fail=$((fail+1)); printf 'FAIL  %-46s want=%-5s got=%s\n' "check-gates digest held while start is slow" "held" "relayed or drained"
  fi
  rm -f "$OPBASE/logs/.proc-start-latency-last" "$OPBASE/notices/check-gates-reminder.txt" 2>/dev/null

  # A ctx notice belonging to ANOTHER session must not leak into this one's context --
  # the whole reason that file is keyed by sid (statusline.sh:238-240).
  printf 'GATEPROBE-LEAK other session notice\n' > "$OPBASE/sessions/.ctx-notices-someone-else"
  op_out="$(jq -nc --arg s "$OPSID" --arg c "$HARNESS_CWD" '{session_id:$s,prompt:"x",cwd:$c,hook_event_name:"UserPromptSubmit"}' \
    | CLAUDE_STATE_DIR="$OPBASE" bash "$hooks/$G" 2>/dev/null)"
  if printf '%s' "$op_out" | grep -q 'GATEPROBE-LEAK'; then
    fail=$((fail+1)); printf 'FAIL  %-46s want=%-5s got=%s\n' "another session's ctx notice does not leak" "absent" "leaked"
  else pass=$((pass+1)); fi

  # Absent notice files: silent, and no crash. hstate under `set -u` with the lib sourced
  # too late used to expand to an empty path -- the exact shape of the bug fixed here.
  rm -f "$OPBASE/sessions/.ctx-notices-$OPSID" 2>/dev/null
  op_out="$(jq -nc --arg s "$OPSID" --arg c "$HARNESS_CWD" '{session_id:$s,prompt:"x",cwd:$c,hook_event_name:"UserPromptSubmit"}' \
    | CLAUDE_STATE_DIR="$OPBASE" bash "$hooks/$G" 2>/dev/null)"
  if printf '%s' "$op_out" | grep -q 'CONTEXT HYGIENE'; then
    fail=$((fail+1)); printf 'FAIL  %-46s want=%-5s got=%s\n' "no notice files means no relay text" "silent" "relayed"
  else pass=$((pass+1)); fi


  # Idle-browser nudge: chrome-activity-track.sh's marker at prompt N, no browser call for
  # two prompts -> nudge relayed, marker deleted, one-shot guard set (all sandboxed under
  # OPBASE via hstate). The prompt counter lives in the REAL .session-chatfiles dir, so
  # seed the marker from whatever it reads now.
  _opn=0; [ -f "$HOME/.claude/.session-chatfiles/$OPSID.promptn" ] && read -r _opn < "$HOME/.claude/.session-chatfiles/$OPSID.promptn"
  printf '%s' "$_opn" > "$OPBASE/sessions/.chrome-active-$OPSID"
  rm -f "$OPBASE/sessions/.usage-state/chrome-compact-nudged-$OPSID" 2>/dev/null
  op_out="$(jq -nc --arg s "$OPSID" --arg c "$HARNESS_CWD" '{session_id:$s,prompt:"x",cwd:$c,hook_event_name:"UserPromptSubmit"}' \
    | CLAUDE_STATE_DIR="$OPBASE" bash "$hooks/$G" 2>/dev/null)"
  if printf '%s' "$op_out" | grep -q 'verify loop looks finished'; then
    fail=$((fail+1)); printf 'FAIL  %-46s want=%-5s got=%s\n' "idle-browser nudge waits for 2 idle prompts" "quiet" "nudged at +1"
  else pass=$((pass+1)); fi
  op_out="$(jq -nc --arg s "$OPSID" --arg c "$HARNESS_CWD" '{session_id:$s,prompt:"x",cwd:$c,hook_event_name:"UserPromptSubmit"}' \
    | CLAUDE_STATE_DIR="$OPBASE" bash "$hooks/$G" 2>/dev/null)"
  if printf '%s' "$op_out" | grep -q 'verify loop looks finished' && [ ! -f "$OPBASE/sessions/.chrome-active-$OPSID" ] \
     && [ -f "$OPBASE/sessions/.usage-state/chrome-compact-nudged-$OPSID" ]; then pass=$((pass+1)); else
    fail=$((fail+1)); printf 'FAIL  %-46s want=%-5s got=%s\n' "idle-browser nudge fires at +2, sets guard" "nudge" "relayed=$(printf '%s' "$op_out" | grep -q 'verify loop looks finished' && echo yes || echo NO) marker=$([ -f "$OPBASE/sessions/.chrome-active-$OPSID" ] && echo present || echo gone) guard=$([ -f "$OPBASE/sessions/.usage-state/chrome-compact-nudged-$OPSID" ] && echo set || echo MISSING)"
  fi
  rm -f "$HOME/.claude/.session-chatfiles/$OPSID.promptn" 2>/dev/null
  rm -rf "$OPBASE" 2>/dev/null || true
else
  skip_gate "$G"
fi

# --------------------------------------------------------------- git-commit-scope-gate.sh
# Pure command-text: no repo needed. `git add <paths> && git commit` commits the WHOLE index,
# so another session's staged files ride along -- the gate wants the paths repeated after `--`.
G=git-commit-scope-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  RP="$real_harness"
  assert "add then bare commit (no pathspec)"   "$G" deny "$(bash_payload_cwd "git -C $RP add AGENTS.md && git -C $RP commit -m 'PROJ-1: x'" "$RP")"
  assert "add then commit WITH pathspec"        "$G" pass "$(bash_payload_cwd "git -C $RP add AGENTS.md && git -C $RP commit -m 'PROJ-1: x' -- AGENTS.md" "$RP")"
  assert "status is not a commit"               "$G" pass "$(bash_payload_cwd "git -C $RP status --porcelain" "$RP")"
  # HARNESS REPO ONLY (2026-09-15): any pathspec-less commit is denied here, `-a`/`-am`
  # included -- every session edits this clone's settings.json, so "commit every tracked
  # change" means "including somebody else's". `-am` used to PASS on this very assertion;
  # that is the behaviour change, not a broken case.
  assert "commit -am in the harness repo"       "$G" deny "$(bash_payload_cwd "git -C $RP commit -am 'PROJ-1: x'" "$RP")"
  assert "bare commit, no add, harness repo"    "$G" deny "$(bash_payload_cwd "git -C $RP commit -m 'PROJ-1: x'" "$RP")"
  assert "commit --pathspec-from-file, harness" "$G" pass "$(bash_payload_cwd "git -C $RP commit -m 'PROJ-1: x' --pathspec-from-file=/tmp/paths.txt" "$RP")"
  assert "add then commit --pathspec-from-file" "$G" pass "$(bash_payload_cwd "git -C $RP add AGENTS.md && git -C $RP commit -F m.txt --pathspec-from-file /tmp/p.txt" "$RP")"
  # Elsewhere the gate is unchanged: -a/-am stays the self-aware choice its header describes.
  assert "commit -am outside the harness repo"  "$G" pass "$(bash_payload_cwd "git -C /tmp/elsewhere commit -am 'PROJ-1: x'" "/tmp/elsewhere")"
  # Fixture text naming a commit is not a commit (lib-command-text.sh).
  assert "quoted fixture commit in harness"     "$G" pass "$(bash_payload_cwd "T='git -C $RP commit -m x'; echo \"\$T\"" "$RP")"
else
  skip_gate "$G"
fi

# -------------------------------------------------------------- git-commit-ticket-gate.sh
G=git-commit-ticket-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  RP="$real_harness"
  # The -F <file> cases below need files the hook can actually read: it resolves the path as
  # given, then relative to the command's target dir, then the session cwd. Absolute paths under
  # the real harness scratch/ satisfy the first, removed at the end of the block.
  printf '<harnessEpicKey>: a proper subject\n\nbody\n' > "$RP/scratch/gate-probe-msg-ok.txt"
  printf 'no ticket in this one\n\nbody\n'             > "$RP/scratch/gate-probe-msg-bad.txt"
  assert "commit with no ticket ref"            "$G" deny "$(bash_payload_cwd "git -C $RP commit -m 'no ticket here'" "$RP")"
  assert "commit with a PROJ ref"          "$G" pass "$(bash_payload_cwd "git -C $RP commit -m '<harnessEpicKey>: x'" "$RP")"
  # ~/.claude has its own separate gate, so this one deliberately stands down there.
  assert "commit in ~/.claude"                  "$G" pass "$(bash_payload_cwd "git -C $HOME/.claude commit -m 'no ticket'" "$HOME/.claude")"
  # Documented scope is "under ~/Repos", but it actually denies a ticket-less commit ANYWHERE
  # outside ~/.claude. Asserting the real behaviour, not the header's wording -- the broader
  # deny is the safe direction, and a case is the right place to notice if it ever narrows.
  assert "ticket-less commit outside ~/Repos"   "$G" deny "$(bash_payload_cwd "git -C /tmp/elsewhere commit -m 'no ticket'" "/tmp/elsewhere")"

  # --- message sources other than -m. `git commit -F -` used to bypass the gate ENTIRELY: the
  # message lives on stdin, extraction found nothing, and the hook fails open by design. A
  # ticket-less harness commit landed that way (the only one in this repo's history) while the
  # next commit, same kind but with -m, was denied -- enforcement depended on flag choice.
  # A heredoc attached to the commit IS visible, and `--amend -F -` in that shape is the
  # documented workaround for PowerShell here-strings mangling a subject, so it must still pass.
  assert "-F - heredoc carrying a ticket ref"   "$G" pass "$(bash_payload_cwd "git -C $RP commit --amend -F - <<'EOF'
<harnessEpicKey>: real subject

body
EOF" "$RP")"
  assert "-F - heredoc with no ticket ref"      "$G" deny "$(bash_payload_cwd "git -C $RP commit -F - <<'EOF'
just some subject

body
EOF" "$RP")"
  # Piped: the message exists nowhere in the command text. The single deliberate exception to
  # fail-open -- concealed, not ambiguous, and unverifiable after the fact too.
  # (its reason is asserted in the reason-assertions section below -- assert_reason is defined
  # further down the file than this block.)
  assert "message piped into git commit -F -"   "$G" deny "$(bash_payload_cwd "printf 'no ticket\n' | git -C $RP commit -F -" "$RP")"
  # A real file is readable, so it gets checked like any other message.
  assert "-F <file> whose first line has a ref" "$G" pass "$(bash_payload_cwd "git -C $RP commit -F $RP/scratch/gate-probe-msg-ok.txt" "$RP")"
  assert "-F <file> with no ticket ref"         "$G" deny "$(bash_payload_cwd "git -C $RP commit -F $RP/scratch/gate-probe-msg-bad.txt" "$RP")"
  # A LITERAL "$HOME" in the path: the hook sees the command unexpanded, and this repo's own
  # commands write paths that way, so without prefix expansion all three [ -f ] probes missed and
  # the more natural -F <file> shape fell straight back through to fail-open -- the very bypass
  # this block closes. Written single-quoted here so the payload really carries the literal.
  assert '-F "$HOME/..." unexpanded, no ref'   "$G" deny "$(bash_payload_cwd 'git -C $HOME/Repos/AMA_APP/ama-claude-harness commit -F $HOME/Repos/AMA_APP/ama-claude-harness/scratch/gate-probe-msg-bad.txt' "$RP")"
  # Short options glue, so -F- is the same bypass spelled differently; --file takes both forms.
  assert "-F- glued, message piped in"          "$G" deny "$(bash_payload_cwd "printf 'no ticket\n' | git -C $RP commit -F-" "$RP")"
  assert "--file - spaced, message piped in"    "$G" deny "$(bash_payload_cwd "printf 'no ticket\n' | git -C $RP commit --file -" "$RP")"
  # Unlocatable file is ambiguity, not concealment -- fail open, per the header's contract.
  assert "-F <file> the hook cannot locate"     "$G" pass "$(bash_payload_cwd "git -C $RP commit -F nowhere-at-all.txt" "$RP")"
  # Fail-open shapes that must NOT have moved: each reuses an already-gated message or puts a
  # human in the loop. These are the regression guard on narrowing fail-open at all.
  assert "--amend --no-edit reuses its message" "$G" pass "$(bash_payload_cwd "git -C $RP commit --amend --no-edit" "$RP")"
  assert "--fixup names no new message"         "$G" pass "$(bash_payload_cwd "git -C $RP commit --fixup HEAD" "$RP")"
  assert "bare commit opens an editor"          "$G" pass "$(bash_payload_cwd "git -C $RP commit" "$RP")"

  # --- both notations for the same harness file must agree. The ~/.claude carve-out used to
  # recognise harness subtrees by a literal list (skills, hooks, claude.md, harness-config.json),
  # but memory/, "Chat files"/, sessions.md, AGENTS.md and README.md are links into the harness
  # too -- so `git -C ~/.claude/memory commit` was real harness code going through ungated.
  assert "git -C ~/.claude/memory (was ungated)" "$G" deny "$(bash_payload_cwd "git -C $HOME/.claude/memory commit -m 'no ticket'" "$HOME/.claude")"
  assert "win-form ~/.claude/hooks"              "$G" deny "$(bash_payload_cwd "git -C $(printf '%s' "$HOME" | sed -E 's|^/([a-z])/|\1:/|')/.claude/hooks commit -m 'no ticket'" "$HOME/.claude")"

  # --- script TEXT is not a command. Adding -F handling turned this old, survivable weakness
  # into a false DENY: the anchor matched a `git commit` sitting inside a heredoc body being
  # written to a file, and the -F branch then denied a call that commits nothing. Fixed by
  # anchoring against heredoc-stripped text; these three are the guard on that.
  assert "script body containing a -F - commit"  "$G" pass "$(bash_payload_cwd "cat > $RP/scratch/gate-probe-t.sh <<'SH'
git commit -F - <<'EOF'
set -u is not a commit message
EOF
SH
bash $RP/scratch/gate-probe-t.sh" "$RP")"
  # ...but a real ticket-less commit alongside such a heredoc must still be caught.
  assert "writes a script AND really commits"    "$G" deny "$(bash_payload_cwd "cat > $RP/scratch/gate-probe-t.sh <<'SH'
echo hi
SH
git -C $RP commit -m 'no ticket'" "$RP")"
  # Two heredocs: the message must come from the COMMIT's own, not the first one in the command.
  assert "message file heredoc, then -F - with a ref" "$G" pass "$(bash_payload_cwd "cat > $RP/scratch/gate-probe-t.txt <<'MSG'
not the message
MSG
git -C $RP commit -F - <<'EOF'
<harnessEpicKey>: the real subject
EOF" "$RP")"
  rm -f "$RP/scratch/gate-probe-msg-ok.txt" "$RP/scratch/gate-probe-msg-bad.txt" 2>/dev/null || true
else
  skip_gate "$G"
fi

# ------------------------------------------------------------- master-push-direct-gate.sh
# Needs real refs: it compares origin/master..master and demands every outgoing NON-MERGE
# commit be reachable from a hotfix/* or release/* ref. It also excludes any repo path
# containing `ama-claude-harness` or `.claude` (both live on master by design), so the fixture
# must sit elsewhere -- pointing this at the harness repo asserts nothing.
G=master-push-direct-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  MPBASE="$(cgmktemp -d "${TMPDIR:-/tmp}/gatefix-mp.XXXXXX")"
  ORIGIN="$MPBASE/origin.git"; WORK="$MPBASE/work"
  git init -q --bare "$ORIGIN" 2>/dev/null
  git clone -q "$ORIGIN" "$WORK" 2>/dev/null
  git -C "$WORK" config user.email gates@example.com
  git -C "$WORK" config user.name "Gate Fixture"
  git -C "$WORK" checkout -q -B master 2>/dev/null
  printf 'base\n' > "$WORK/a.txt"
  git -C "$WORK" add a.txt && git -C "$WORK" commit -q -m "base"
  git -C "$WORK" push -q origin master 2>/dev/null
  if git -C "$WORK" rev-parse --verify -q refs/remotes/origin/master >/dev/null; then
    # (a) a DIRECT commit on master, reachable from no hotfix/release ref
    printf 'direct\n' >> "$WORK/a.txt"
    git -C "$WORK" commit -q -am "direct change on master"
    assert "push master carrying a direct commit"  "$G" deny "$(bash_payload_cwd "git -C $WORK push origin master" "$WORK")"
    assert "push of a non-master branch"           "$G" pass "$(bash_payload_cwd "git -C $WORK push origin hotfix/1.0.1" "$WORK")"
    # (b) same outgoing content, but arriving via a --no-ff hotfix merge: the merge commit is
    #     skipped by --no-merges and the hotfix's own commits are excluded by ref.
    git -C "$WORK" reset -q --hard refs/remotes/origin/master
    git -C "$WORK" checkout -q -b hotfix/1.0.1
    printf 'fix\n' >> "$WORK/a.txt"
    git -C "$WORK" commit -q -am "the fix"
    git -C "$WORK" checkout -q master
    git -C "$WORK" merge -q --no-ff -m "Merge hotfix/1.0.1" hotfix/1.0.1
    assert "push master after a --no-ff hotfix merge" "$G" pass "$(bash_payload_cwd "git -C $WORK push origin master" "$WORK")"
  else
    skip=$((skip+1)); printf 'SKIP  %s: fixture repo did not initialise\n' "$G"
  fi
  # Test-automation-repo exclusion (api-testing/ui-testing): same direct-commit shape
  # as case (a) above, but the toplevel dirname itself is the exemption -- matched
  # literally, so the fixture must actually be named api-testing/ui-testing, not just
  # live under a path containing that word.
  for TNAME in api-testing ui-testing; do
    TORIGIN="$MPBASE/$TNAME-origin.git"; TWORK="$MPBASE/$TNAME"
    git init -q --bare "$TORIGIN" 2>/dev/null
    git clone -q "$TORIGIN" "$TWORK" 2>/dev/null
    git -C "$TWORK" config user.email gates@example.com
    git -C "$TWORK" config user.name "Gate Fixture"
    git -C "$TWORK" checkout -q -B master 2>/dev/null
    printf 'base\n' > "$TWORK/a.txt"
    git -C "$TWORK" add a.txt && git -C "$TWORK" commit -q -m "base"
    git -C "$TWORK" push -q origin master 2>/dev/null
    if git -C "$TWORK" rev-parse --verify -q refs/remotes/origin/master >/dev/null; then
      printf 'direct\n' >> "$TWORK/a.txt"
      git -C "$TWORK" commit -q -am "direct change on master"
      assert "push direct commit on $TNAME (exempt)" "$G" pass "$(bash_payload_cwd "git -C $TWORK push origin master" "$TWORK")"
    else
      skip=$((skip+1)); printf 'SKIP  %s: %s fixture repo did not initialise\n' "$G" "$TNAME"
    fi
  done
  rm -rf "$MPBASE" 2>/dev/null || true
else
  skip_gate "$G"
fi

# ------------------------------------------------------------- fleet-owner-push-gate.sh
# User rule 2026-10-28: a protected-branch push in a fleet the user does not own is denied;
# a feature-branch push (the PR route) passes. Fleet comes from the FLEET_OWNER_FLEETS seam,
# owners from a fixture HR_CONFIG_FILE -- live config and the live repo index stay untouched.
G=fleet-owner-push-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  FOB="$(cgmktemp -d "${TMPDIR:-/tmp}/gatefix-fo.XXXXXX")"
  git init -q "$FOB/work" 2>/dev/null
  git -C "$FOB/work" checkout -q -B master 2>/dev/null
  printf '{"bitbucket":{"org":"yourorg","selfUuid":"{self}"},"fleetOwners":{"etl":{"name":"Reviewer One","bitbucketUuid":"{ali}"},"app":{"name":"Me","bitbucketUuid":"{self}"}}}' > "$FOB/cfg.json"
  printf '{"bitbucket":{"org":"yourorg","selfUuid":"{self}"}}' > "$FOB/cfg-none.json"
  export HR_CONFIG_FILE="$FOB/cfg.json" FLEET_OWNER_FLEETS=etl
  FW="$FOB/work"
  assert "fleet: push feature branch passes"      "$G" pass "$(bash_payload_cwd "git -C $FW push -u origin feature/PROJ-1-x" "$FW")"
  assert "fleet: push master denied"              "$G" deny "$(bash_payload_cwd "git -C $FW push origin master" "$FW")"
  assert "fleet: push HEAD:develop denied"        "$G" deny "$(bash_payload_cwd "git -C $FW push origin HEAD:develop" "$FW")"
  assert "fleet: delete release branch denied"    "$G" deny "$(bash_payload_cwd "git -C $FW push origin :release/1.0" "$FW")"
  assert "fleet: bare push on master denied"      "$G" deny "$(bash_payload_cwd "git push" "$FW")"
  assert "fleet: --tags on master passes"         "$G" pass "$(bash_payload_cwd "git -C $FW push --tags" "$FW")"
  assert_reason "fleet: reason names the owner"   "$G" "owned by Reviewer One" "$(bash_payload_cwd "git -C $FW push origin master" "$FW")"
  assert "fleet: owner-approved hatch passes"     "$G" pass "$(bash_payload_cwd "AMA_FLEET_OWNER_APPROVED=1 git -C $FW push origin master" "$FW")"
  export FLEET_OWNER_FLEETS=app
  assert "fleet: own fleet push master passes"    "$G" pass "$(bash_payload_cwd "git -C $FW push origin master" "$FW")"
  export FLEET_OWNER_FLEETS=etl HR_CONFIG_FILE="$FOB/cfg-none.json"
  assert "fleet: no fleetOwners configured passes" "$G" pass "$(bash_payload_cwd "git -C $FW push origin master" "$FW")"
  assert "fleet: not a push passes"               "$G" pass "$(bash_payload_cwd "git -C $FW status" "$FW")"
  unset HR_CONFIG_FILE FLEET_OWNER_FLEETS
  rm -rf "$FOB" 2>/dev/null || true
else
  skip_gate "$G"
fi

# ===================================================== reason assertions
# reason_of/assert_reason MOVED UP to sit with the other helpers, before the first gate
# section -- see there for why. The cases that use them start below.
assert_exit() {
  local desc="$1" want="$2"; shift 2
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  if { [ "$want" = "zero" ] && [ "$rc" -eq 0 ]; } || { [ "$want" = "nonzero" ] && [ "$rc" -ne 0 ]; }; then
    pass=$((pass+1))
  else
    fail=$((fail+1)); printf 'FAIL  %-46s want=%-5s got=rc%s\n' "$desc" "$want" "$rc"
  fi
}

# ---------------------------------------- readme-currency-gate.sh (size counter-pressure)
# Second half of the readme-currency block above (this one needs assert_reason, defined
# later than that block runs). Over AGENTS_SIZE_LIMIT bytes the nudge must flip to
# "relocate, don't append" -- the anti-regrowth half of the 2026-08-31 AGENTS.md diet.
# The real AGENTS.md is what the gate reads (it self-resolves the harness), so the limit
# is forced low via the env seam rather than fabricating a giant file.
G=readme-currency-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  probe_state_clean
  rcsz() { jq -n --arg p "$1" --arg s "$2" --arg t "$3" '{tool_name:"Edit",session_id:$s,tool_input:{file_path:$p,new_string:$t}}'; }
  RCBIG="$(printf 'line %s\n' 1 2 3 4 5 6 7 8)"
  export AGENTS_SIZE_LIMIT=1
  assert_reason "over-limit nudge says relocate" "$G" 'do NOT grow it further' "$(rcsz "$real_harness/hooks/statusline.sh" "$PROBE_SID-rcsz1" "$RCBIG")"
  unset AGENTS_SIZE_LIMIT
  probe_state_clean
  # Positive match on the wording ADJACENT to where the size note splices in: with the
  # note absent, "routing note)." is immediately followed by "Checked..." (grep -E has no
  # lookahead, so asserting the absence directly isn't possible here).
  # Mirror-image of the seam above: the real AGENTS.md crossed 100000 bytes in Aug 2026 and
  # has stayed over, which made this case unsatisfiable and left the suite permanently at
  # "1 failed" on a clean tree (harness-gaps.md, session dc852cc8). Force the limit HIGH
  # rather than shrinking the file, exactly as the over-limit case forces it to 1.
  export AGENTS_SIZE_LIMIT=99999999
  assert_reason "under-limit nudge has no size note" "$G" 'routing note\)\. Checked and NO change needed' "$(rcsz "$real_harness/hooks/statusline.sh" "$PROBE_SID-rcsz2" "$RCBIG")"
  unset AGENTS_SIZE_LIMIT
  probe_state_clean
else
  skip_gate "$G"
fi

# ---------------------------------------------------------------- mongo-write-gate.sh
# Write eval against docdb-query.sh production -> deny (AMA_ALLOW_PROD_MONGO_WRITE=1, a
# USER-set hatch, passes); any other Mongo write -- qa/staging eval, raw mongosh,
# mongoimport/mongorestore, aggregate $out/$merge -> deny with its OWN hatch
# (AMA_ALLOW_MONGO_WRITE=1, which must NOT unlock production); reads pass silently.
# Deny-plus-hatch over "ask": mode-independent, and the approval lands in the transcript.
# Method match requires "(" right after the name so a collection NAMED updates doesn't
# trip it; heredoc bodies are exempt like every command gate here.
G=mongo-write-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  DQ='bash ~/.claude/skills/ama-mongo-access/scripts/docdb-query.sh'
  MW_QA="$DQ qa "'db.getSiblingDB("cohort").cohortreport.updateMany({_id:"x"},{$set:{y:1}})'
  MW_PROD="$DQ production "'db.getSiblingDB("cohort").cohortreport.deleteMany({})'
  assert "qa updateMany denied"                  "$G" deny "$(bash_payload "$MW_QA")"
  assert "production deleteMany denied"          "$G" deny "$(bash_payload "$MW_PROD")"
  assert_reason "prod deny names the prod hatch" "$G" 'PRODUCTION DocumentDB.*AMA_ALLOW_PROD_MONGO_WRITE' "$(bash_payload "$MW_PROD")"
  assert_reason "qa deny explains the rw creds"  "$G" 'read-write credentials.*AMA_ALLOW_MONGO_WRITE' "$(bash_payload "$MW_QA")"
  # 2026-10-05: the old text said "re-run with VAR=1 in the environment", which read as an
  # inline prefix -- that never reaches a hook's own env. The deny must say so.
  assert_reason "qa deny says inline prefix never reaches it"   "$G" 'inline.*never reaches this gate' "$(bash_payload "$MW_QA")"
  assert_reason "prod deny says inline prefix never reaches it" "$G" 'inline.*never reaches this gate' "$(bash_payload "$MW_PROD")"
  AMA_ALLOW_PROD_MONGO_WRITE=1 assert "prod write + prod hatch passes" "$G" pass "$(bash_payload "$MW_PROD")"
  AMA_ALLOW_MONGO_WRITE=1 assert "qa write + qa hatch passes"          "$G" pass "$(bash_payload "$MW_QA")"
  AMA_ALLOW_MONGO_WRITE=1 assert "qa hatch does NOT unlock production" "$G" deny "$(bash_payload "$MW_PROD")"
  assert "qa countDocuments is a read"           "$G" pass "$(bash_payload "$DQ qa 'db.getSiblingDB(\"cohort\").cohortreport.countDocuments({})'")"
  assert "collection NAMED updates, find()"      "$G" pass "$(bash_payload "$DQ qa 'db.getSiblingDB(\"cohort\").updates.find({}).limit(1)'")"
  assert "aggregate with \$merge denied"         "$G" deny "$(bash_payload "$DQ qa "'db.getSiblingDB("cohort").c.aggregate([{$merge:{into:"x"}}])')"
  assert "raw mongosh insertOne denied"          "$G" deny "$(bash_payload 'docker run --rm mongo:7 mongosh --host h -u u -p p --eval "db.x.insertOne({a:1})"')"
  assert "mongorestore denied"                   "$G" deny "$(bash_payload 'docker run --rm mongo:7 mongorestore --host h --dir /dump')"
  assert "prose mention, no write op"            "$G" pass "$(bash_payload 'echo docdb-query.sh is documented in SKILL.md')"
  assert "heredoc body describing updateMany"    "$G" pass "$(bash_payload "git commit -F - <<EOF
gate denies docdb-query.sh updateMany( evals unless approved
EOF")"
  # The 2026-09-15 replay: a write written INTO a script by heredoc and run in the same
  # command. `${command%%<<*}` dropped the body AND the trailing `bash x.sh`, so the gate saw
  # `cat > x.sh` and nothing else -- silent allow on a production write. The scan lib cannot
  # help either: at PreToolUse the file does not exist yet. command_scan_region counts the
  # body as code when the same command runs a file.
  assert "heredoc-written script, run in same command" "$G" deny "$(bash_payload "cat > \"\$HOME/.claude/scratch/x/m.sh\" <<'EOF'
$MW_QA
EOF
bash \"\$HOME/.claude/scratch/x/m.sh\"")"

  # A script REFERENCED BY "$HOME/..." must be read, not skipped. short-path-gate.sh tells
  # every session to spell scratchpad paths that way instead of the 8.3 form, so this was
  # the harness recommending the one shape lib-scan-script-refs.sh could not resolve -
  # confirmed live 2026-09-15, a write ran unchallenged through it.
  # Must live under the REAL $HOME: the gate sources its scan lib from $HOME/.claude/hooks,
  # so faking HOME to plant the fixture would disable the very scan being asserted and the
  # case would "pass" for the wrong reason.
  SCANREL=".claude/scratch/check-gates/scan-$PROBE_TAG"
  mkdir -p "$HOME/$SCANREL"
  printf 'docdb-query.sh qa %s\n' \
    'db.getSiblingDB("cohort").cohortreport.updateMany({},{$set:{y:1}})' > "$HOME/$SCANREL/w.sh"
  assert "write inside a \$HOME-referenced script" "$G" deny "$(bash_payload "bash \"\$HOME/$SCANREL/w.sh\"")"
  assert "same script via ~"                       "$G" deny "$(bash_payload "bash ~/$SCANREL/w.sh")"
  rm -rf "$HOME/$SCANREL" 2>/dev/null || true
else
  skip_gate "$G"
fi

# ----------------------------------------------------------------------- psql-write-gate.sh
# Had NO section until 2026-09-15 -- the same heredoc+run replay that caught mongo-write-gate
# caught this one, and there was nothing here to have noticed. Hatches: AMA_ALLOW_PG_WRITE=1
# (non-prod), AMA_ALLOW_PROD_PG_WRITE=1 (prod, separate on purpose).
G=psql-write-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  PW_UPD='psql "$PG" -c "UPDATE report_templates SET enabled=false WHERE id=1"'
  assert "inline UPDATE denied"                     "$G" deny "$(bash_payload "$PW_UPD")"
  assert "inline SELECT is a read"                  "$G" pass "$(bash_payload 'psql "$PG" -c "SELECT count(*) FROM report_templates"')"
  assert "commit message describing an UPDATE"      "$G" pass "$(bash_payload "git commit -F - <<EOF
datafix: UPDATE report_templates SET enabled=false for the retired org
EOF")"
  assert "heredoc-written script, run in same command" "$G" deny "$(bash_payload "cat > \"\$HOME/.claude/scratch/x/p.sh\" <<'EOF'
$PW_UPD
EOF
bash \"\$HOME/.claude/scratch/x/p.sh\"")"
  AMA_ALLOW_PG_WRITE=1 assert "non-prod hatch passes"  "$G" pass "$(bash_payload "$PW_UPD")"
  # Same 2026-10-05 wording pin as mongo-write-gate: the hatch is launch-env, not an inline prefix.
  assert_reason "deny says inline prefix never reaches it" "$G" 'inline.*never reaches this gate' "$(bash_payload "$PW_UPD")"
  # pg-connect.sh names no psql on the command line -- the gate was blind to the harness's
  # OWN documented Postgres path until 2026-09-18 (a production DELETE replayed silent).
  PGC='bash ~/.claude/skills/ama-postgres-access/scripts/pg-connect.sh'
  assert "pg-connect prod DELETE denied"            "$G" deny "$(bash_payload "$PGC production reports \"DELETE FROM \\\"UserReport\\\" WHERE id=1\"")"
  assert "pg-connect qa UPDATE denied"              "$G" deny "$(bash_payload "$PGC qa reports \"UPDATE \\\"UserReport\\\" SET \\\"IsDeleted\\\"=true\"")"
  assert "pg-connect SELECT is a read"              "$G" pass "$(bash_payload "$PGC qa reports \"SELECT count(*) FROM \\\"UserReport\\\"\"")"
  AMA_ALLOW_PROD_PG_WRITE=1 assert "pg-connect prod hatch passes" "$G" pass "$(bash_payload "$PGC production reports \"DELETE FROM \\\"UserReport\\\" WHERE id=1\"")"
  # -f puts the SQL in a file and nothing in argv. The file legitimately lives outside the
  # scratch roots lib-scan-script-refs.sh reads, so the gate opens this one named file.
  PGF="$(cgmktemp "/tmp/gatefix-pg.XXXXXX")"
  printf 'UPDATE "UserReport" SET "IsDeleted"=true;\n' > "$PGF"
  assert "pg-connect -f file holding a write"       "$G" deny "$(bash_payload "$PGC qa reports -f $PGF")"
  printf 'SELECT count(*) FROM "UserReport";\n' > "$PGF"
  assert "pg-connect -f file holding a read"        "$G" pass "$(bash_payload "$PGC qa reports -f $PGF")"
  # Windows spelling of that same path. Pinned because `jq @tsv` doubles backslashes, which
  # silently broke the `[ -f ]` test and made -f a bypass again -- forward-slash fixtures
  # cannot see it. Keep both spellings.
  printf 'DELETE FROM "UserReport" WHERE id=1;\n' > "$PGF"
  PGFW="$(cygpath -w "$PGF" 2>/dev/null || printf '%s' "$PGF")"
  assert "pg-connect -f WINDOWS path, write"        "$G" deny "$(bash_payload "$PGC qa reports -f \"$PGFW\"")"
  rm -f "$PGF" 2>/dev/null || true
  # A filename holding "psql"/"pg-connect.sh" plus another holding "update" is not a psql
  # invocation (2026-10-20: `git add` of the gate's own file + confluence-update-page.sh denied).
  assert "git add of psql-named + update-named files"  "$G" pass "$(bash_payload 'git add -- hooks/psql-write-gate.sh skills/ama-confluence-api/scripts/confluence-update-page.sh && git commit -m "set x"')"
  assert "git add of pg-connect.sh + update/set words" "$G" pass "$(bash_payload 'git add -- skills/ama-postgres-access/scripts/pg-connect.sh notes/update-the-set.md')"
  assert "docker-run psql UPDATE still denied"         "$G" deny "$(bash_payload 'docker run --rm postgres:15 psql "$URL" -c "UPDATE t SET a=1"')"
  assert "PGPASSWORD-prefixed psql UPDATE denied"      "$G" deny "$(bash_payload 'PGPASSWORD=x psql -h h -c "UPDATE t SET a=1"')"
  # Script path held in a variable -- the style bare-cd-gate steers sessions into. The
  # invocation check must still see these (2026-10-21 review of the filename fix).
  PGP='~/.claude/skills/ama-postgres-access/scripts'
  assert "pg-connect via var, start of command"        "$G" deny "$(bash_payload "P=$PGP/pg-connect.sh; bash \$P production reports \"DELETE FROM x WHERE id=1\"")"
  assert "pg-connect via quoted var, mid-command"      "$G" deny "$(bash_payload "R=1; P=\"$PGP/pg-connect.sh\"; bash \"\$P\" qa reports \"DELETE FROM x WHERE id=1\"")"
  assert "pg-connect via export var"                   "$G" deny "$(bash_payload "export P=$PGP/pg-connect.sh; bash \$P qa reports \"DELETE FROM x WHERE id=1\"")"
  assert "pg-connect via dir var + /pg-connect.sh"     "$G" deny "$(bash_payload "S=$PGP; bash \$S/pg-connect.sh qa reports \"DELETE FROM x WHERE id=1\"")"
  assert "pg-connect via var after && "                "$G" deny "$(bash_payload "cd /x && P=$PGP/pg-connect.sh && bash \$P qa reports \"UPDATE x SET a=1\"")"
  assert "psql held in a variable"                     "$G" deny "$(bash_payload 'Q=psql; $Q -h h -c "DELETE FROM x"')"
else
  skip_gate "$G"
fi

# ----------------------------------------------------------- cherry-pick-release-gate.sh
# Denies `git cherry-pick` onto develop of a commit reachable from a release/*|hotfix/* ref.
# Real repo fixture: develop <- base; release/1.0.0 <- base + RSHA; develop <- base + DSHA.
G=cherry-pick-release-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  CP="$(cgmktemp -d "/tmp/gatefix-cp.XXXXXX")"
  git -C "$CP" init -q -b develop 2>/dev/null
  git -C "$CP" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "PROJ-1: base" 2>/dev/null
  git -C "$CP" checkout -q -b release/1.0.0 2>/dev/null
  git -C "$CP" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "PROJ-2: release fix" 2>/dev/null
  RSHA="$(git -C "$CP" rev-parse HEAD)"
  git -C "$CP" checkout -q develop 2>/dev/null
  git -C "$CP" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "PROJ-3: develop work" 2>/dev/null
  DSHA="$(git -C "$CP" rev-parse HEAD)"
  cpp() { bash_payload_sid "$1" "$CP" "$PROBE_SID-cp"; }
  assert "release commit picked onto develop"       "$G" deny "$(cpp "git -C $CP cherry-pick $RSHA")"
  assert "develop-only commit picked"               "$G" pass "$(cpp "git -C $CP cherry-pick $DSHA")"
  assert "hatch AMA_ALLOW_CHERRY_PICK=1"            "$G" pass "$(cpp "AMA_ALLOW_CHERRY_PICK=1 git -C $CP cherry-pick $RSHA")"
  assert "commit message mentioning cherry-pick"    "$G" pass "$(cpp "git -C $CP commit -q -F - <<EOF
PROJ-4: never cherry-pick $RSHA onto develop
EOF")"
  git -C "$CP" checkout -q release/1.0.0 2>/dev/null
  assert "cherry-pick while ON the release branch"  "$G" pass "$(cpp "git -C $CP cherry-pick $DSHA")"
  rm -rf "$CP" 2>/dev/null || true
else
  skip_gate "$G"
fi

# ------------------------------------------------------- jira-search-assignee-reminder.sh
# Warn-only: a status/sprint-shaped JQL with no assignee clause (the silent-failure shape --
# more rows, looks fine). fixVersion-/key-scoped queries are about a release, not a column.
G=jira-search-assignee-reminder.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  JS='bash ~/.claude/skills/ama-jira-api/scripts/jira-search.sh'
  assert_block "status JQL, no assignee, nudges"     "$G" block "$(bash_payload "$JS 'project = PROJ AND status = \"QA\"' key,summary 50")"
  assert_block "status JQL with assignee stays quiet" "$G" pass  "$(bash_payload "$JS 'project = PROJ AND status = \"QA\" AND assignee = currentUser()' key 50")"
  assert_block "fixVersion-scoped query stays quiet"  "$G" pass  "$(bash_payload "$JS 'fixVersion = \"release/130.0.0\" AND status = Done' key 120")"
  assert_block "key-scoped query stays quiet"         "$G" pass  "$(bash_payload "$JS 'key in (PROJ-1, PROJ-2) AND status = QA' key 5")"
  assert_block "unrelated command"                    "$G" pass  "$(bash_payload 'git status')"
else
  skip_gate "$G"
fi

# ------------------------------------------------------------ redshift-window-context.sh
# Context-only, never a decision: inside Mon-Fri 9am-5pm ET an rs-query.sh call gets the
# Redshift-heavy-work rule injected; outside it, and for EXPLAIN, silence. Forced clock via
# the same python shim the two window gates use.
G=redshift-window-context.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  RSHIM="$(cgmktemp -d "/tmp/gatefix-rs.XXXXXX")"
  rclock() { printf '#!/usr/bin/env bash\nprintf "%%s %%s %%s:00 Day -0400 EDT\\n" "%s" "%s" "%s"\n' "$1" "$2" "$1" > "$RSHIM/python"; chmod +x "$RSHIM/python"; }
  ROLDPATH="$PATH"; PATH="$RSHIM:$PATH"
  rctx() { printf '%s' "$(bash_payload "$1")" | bash "$hooks/$G" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null; }
  RSQ='bash ~/.claude/skills/ama-postgres-access/scripts/rs-query.sh "select count(*) from loanperiodic"'
  rclock 10 3
  if rctx "$RSQ" | grep -q "inside US business hours"; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL  %-46s\n' "rs-query inside window gets context"; fi
  if [ -z "$(rctx 'bash ~/.claude/skills/ama-postgres-access/scripts/rs-query.sh "explain select 1"')" ]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL  %-46s\n' "EXPLAIN stays silent"; fi
  if [ "$(decide "$G" "$(bash_payload "$RSQ")")" = "pass" ]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL  %-46s\n' "context hook never decides"; fi
  rclock 20 3
  if [ -z "$(rctx "$RSQ")" ]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL  %-46s\n' "rs-query outside window stays silent"; fi
  PATH="$ROLDPATH"; rm -rf "$RSHIM" 2>/dev/null || true
else
  skip_gate "$G"
fi

# ----------------------------------------------------- octopus-prod-cache-update-reminder.sh
# Production twin of the staging cache-update reminder: decision-nudge after a prod POST,
# silent for staging, and it must see the multi-line heredoc+bash shape (shared lib).
G=octopus-prod-cache-update-reminder.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  CPROD='curl -sS -X POST -H "Content-Type: application/json" -d "{\"ReleaseId\":\"Releases-1\",\"EnvironmentId\":\"<production>\"}" "https://yourorg.octopus.app/api/Spaces-1/deployments"'
  assert_block "prod POST nudges the cache-update decision" "$G" block "$(bash_payload "$CPROD")"
  assert_block "staging POST stays quiet"                    "$G" pass  "$(bash_payload "${CPROD//<production>/<staging>}")"
  assert_block "multi-line prod POST via heredoc+bash"       "$G" block "$(bash_payload "cat > /tmp/octo.sh <<'EOF'
curl -sS -X POST \\
  -d \"{\\\"EnvironmentId\\\":\\\"<production>\\\"}\" \\
  \"https://yourorg.octopus.app/api/Spaces-1/deployments\"
EOF
bash /tmp/octo.sh")"
  assert_block "commit message describing a prod deploy"     "$G" pass  "$(bash_payload "git commit -F- <<EOF
PROJ-1: posts <production> to api/Spaces-1/deployments
EOF")"
  # The SHAPE is not a deployment: with a tool_response present, Octopus's own ids must be in
  # it. A gate-blocked deploy command nudged both prod reminders on 2026-09-18.
  assert_block "prod POST whose response shows no deployment" "$G" pass  "$(resp_payload "$CPROD" 'Octopus deployment blocked: no delete-function recorded')"
  assert_block "prod POST answered with a ServerTasks id"     "$G" block "$(resp_payload "$CPROD" '{"Id":"Deployments-8811","TaskId":"ServerTasks-99120"}')"
else
  skip_gate "$G"
fi

# --------------------------------------------------------- deploy-verify-slack-reminder.sh
# Fires only when a verify script ran against PRODUCTION AND its own RESULT line said steady.
G=deploy-verify-slack-reminder.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  dvp() { jq -nc --arg c "$1" --arg o "$2" '{tool_name:"Bash",tool_input:{command:$c},tool_response:{stdout:$o}}'; }
  VCMD='bash ~/.claude/skills/ama-cloudwatch-search/scripts/verify-qa-deploy.sh search ecs 15'
  PCMD="AMA_ENV=production $VCMD"
  PCL='Cluster: production-v1-AMA  Service: production-v1-search-api-esvc'
  assert_block "clean prod verify nudges the Slack post" "$G" block "$(dvp "$PCMD" "$PCL
Steady state reached.
RESULT: deployment steady, no non-routine restarts. Review the log scan above.")"
  assert_block "prod via command prefix, no Cluster line" "$G" block "$(dvp "$PCMD" "RESULT: deployment steady, no non-routine restarts.")"
  assert_block "clean QA verify stays quiet"         "$G" pass  "$(dvp "$VCMD" "Cluster: qa-v1-AMA  Service: qa-v1-search-api-esvc
RESULT: deployment steady, no non-routine restarts.")"
  assert_block "clean staging verify stays quiet"    "$G" pass  "$(dvp "AMA_ENV=staging $VCMD" "Cluster: staging-v1-AMA  Service: staging-v1-search-api-esvc
RESULT: deployment steady, no non-routine restarts.")"
  assert_block "no env anywhere = qa default, quiet" "$G" pass  "$(dvp "$VCMD" "RESULT: deployment steady, no non-routine restarts.")"
  assert_block "failed prod verify stays quiet"      "$G" pass  "$(dvp "$PCMD" "$PCL
RESULT: deployment steady
FAILED: 3 non-routine task stops")"
  assert_block "prod verify still running stays quiet" "$G" pass "$(dvp "$PCMD" "$PCL
Polling for steady state (every 30s, up to 15m)...")"
  assert_block "unrelated command"                   "$G" pass  "$(dvp 'git status' 'RESULT: deployment steady')"
else
  skip_gate "$G"
fi

# ------------------------------------------------------------------ trace-secret-gate.sh
# `bash -x <harness script>` prints curl -H headers, API keys included, into the transcript.
G=trace-secret-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  assert "bash -x on a skill script denied"        "$G" deny "$(bash_payload 'bash -x "$HOME/.claude/skills/ama-octopus-deploy/scripts/last-prod-deploy-date.sh" release/129.0.0')"
  assert "set -x before a hooks script denied"      "$G" deny "$(bash_payload 'set -x; bash ~/.claude/hooks/lib-et-now.sh')"
  assert "bash -x on a scratchpad script allowed"   "$G" pass "$(bash_payload 'bash -x "$HOME/AppData/Local/Temp/claude/x/scratchpad/probe.sh"')"
  assert "plain run of a skill script allowed"      "$G" pass "$(bash_payload 'bash "$HOME/.claude/skills/ama-octopus-deploy/scripts/last-prod-deploy-date.sh" release/129.0.0')"
  assert "hatch AMA_ALLOW_TRACE=1"                  "$G" pass "$(bash_payload 'AMA_ALLOW_TRACE=1 bash -x ~/.claude/hooks/lib-et-now.sh')"
  assert "commit message mentioning bash -x"        "$G" pass "$(bash_payload 'git commit -F - <<EOF
PROJ-1: never bash -x a ~/.claude/skills script
EOF')"
else
  skip_gate "$G"
fi

# --------------------------------------------------------- dotfile-secret-print-gate.sh
# Printing ~/.secrets (or a profile that still holds a key export) leaks keys into the
# transcript. Fixture HOME: ~/.secrets always protected; .bashrc protected only while dirty.
G=dotfile-secret-print-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  DSH="$(cgmktemp -d "${TMPDIR:-/tmp}/gatefix-dsp.XXXXXX")"
  printf 'export FAKE_API_KEY="x"\n' > "$DSH/.secrets"
  printf 'alias ll="ls -l"\n' > "$DSH/.bashrc"
  printf 'export OTHER_TOKEN=y\n' > "$DSH/.bash_profile"
  rp() { jq -n --arg p "$1" '{tool_name:"Read",tool_input:{file_path:$p}}'; }
  HOME="$DSH" assert "cat ~/.secrets denied"                  "$G" deny "$(bash_payload 'cat ~/.secrets')"
  HOME="$DSH" assert "tail of ~/.secrets denied"              "$G" deny "$(bash_payload 'tail -n 3 "$HOME/.secrets"')"
  HOME="$DSH" assert "grep -o capturing values denied"        "$G" deny "$(bash_payload "grep -o 'export X=.*' ~/.secrets")"
  HOME="$DSH" assert "second segment cat denied"              "$G" deny "$(bash_payload 'ls ~ && cat ~/.secrets')"
  HOME="$DSH" assert "Get-Content denied"                     "$G" deny "$(bash_payload 'Get-Content C:\Users\me\.secrets')"
  HOME="$DSH" assert "tail of dirty .bash_profile denied"     "$G" deny "$(bash_payload 'tail -n 3 ~/.bash_profile')"
  HOME="$DSH" assert "Read of ~/.secrets denied"              "$G" deny "$(rp 'C:\Users\me\.secrets')"
  HOME="$DSH" assert "Grep content on ~/.secrets denied"      "$G" deny "$(jq -n '{tool_name:"Grep",tool_input:{pattern:"x",path:"C:/Users/me/.secrets",output_mode:"content"}}')"
  HOME="$DSH" assert "names-only grep -o allowed"             "$G" pass "$(bash_payload "grep -n -o '^export [A-Za-z_]*=' ~/.secrets")"
  HOME="$DSH" assert "grep -c allowed"                        "$G" pass "$(bash_payload 'grep -c KEY ~/.secrets')"
  HOME="$DSH" assert "sourcing allowed"                       "$G" pass "$(bash_payload '[ -f ~/.secrets ] && . ~/.secrets')"
  HOME="$DSH" assert "append redirect allowed"                "$G" pass "$(bash_payload "echo 'export B_KEY=z' >> ~/.secrets")"
  HOME="$DSH" assert "sed -i delete allowed"                  "$G" pass "$(bash_payload "sed -i '/^export B_KEY=/d' ~/.secrets")"
  HOME="$DSH" assert "tail of clean .bashrc allowed"          "$G" pass "$(bash_payload 'tail -n 3 ~/.bashrc')"
  HOME="$DSH" assert "Read of clean .bashrc allowed"          "$G" pass "$(rp 'C:/Users/me/.bashrc')"
  HOME="$DSH" assert "Grep count on ~/.secrets allowed"       "$G" pass "$(jq -n '{tool_name:"Grep",tool_input:{pattern:"x",path:"C:/Users/me/.secrets",output_mode:"count"}}')"
  HOME="$DSH" assert "unrelated command allowed"              "$G" pass "$(bash_payload 'git status')"
  printf 'export DTRACK_API_KEY="odt_x"\n' >> "$DSH/.bashrc"
  HOME="$DSH" assert "tail of .bashrc with a key denied"      "$G" deny "$(bash_payload 'tail -n 3 ~/.bashrc')"
  rm -rf "$DSH"; unset -f rp
else
  skip_gate "$G"
fi

# ------------------------------------------------------------------------- bare-cd-gate.sh
# Resolves the session's OWN home from .session-chatfiles/<sid> (the dirname of the recorded
# chat-log path) and falls back to cwd. Without that file seeded it fails open, so a case built
# with the plain builder passes for the wrong reason.
G=bare-cd-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  BSID="$PROBE_SID-barecd"
  BHOME="$(cgmktemp -d "${TMPDIR:-/tmp}/gatefix-cd.XXXXXX")"
  CHATREG="$HOME/.claude/.session-chatfiles"
  mkdir -p "$CHATREG"
  printf '%s\n' "$BHOME/Probe Chat.md" > "$CHATREG/$BSID"
  bp() { bash_payload_sid "$1" "$BHOME" "$BSID"; }
  assert "bare cd back to the session home"   "$G" pass "$(bp "cd $BHOME")"
  assert "compound cd to the session home"    "$G" deny "$(bp "cd $BHOME; ls -la")"
  assert "leading cd to a foreign path"       "$G" deny "$(bp "cd /tmp/elsewhere && ls -la")"
  assert "real subshell (cd X && cmd)"        "$G" pass "$(bp "(cd /tmp/elsewhere && ls -la)")"
  assert "path passed as an argument"         "$G" pass "$(bp "ls -la $BHOME/")"
  # The two denials must give DIFFERENT reasons -- this is the pair the decision-only suite
  # could not distinguish.
  assert_reason "home compound cites classifier delegation" "$G" "classifier|statically" "$(bp "cd $BHOME; ls -la")"
  assert_reason "foreign target cites cwd leaking forward"  "$G" "leaks cwd|persists across"  "$(bp "cd /tmp/elsewhere && ls -la")"
  rm -f "$CHATREG/$BSID" 2>/dev/null || true
  rm -rf "$BHOME" 2>/dev/null || true
else
  skip_gate "$G"
fi

# ------------------------------------------------------- unanalyzable-script-gate.sh reasons
# Four rules, four distinct remedies -- assert each names its own, not just that it denied.
G=unanalyzable-script-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  assert_reason "loop rule names the loop"        "$G" "loop"                  "$(bash_payload 'for k in a b; do echo "$k"; done')"
  assert_reason "quote rule names the open quote" "$G" "quoted string|open"     "$(bash_payload 'git commit -q -m "subject

body" -- a.md')"
  assert_reason "env rule names the variable"     "$G" "ATLASSIAN_API_TOKEN"    "$(bash_payload 'curl -u "me:$ATLASSIAN_API_TOKEN" https://example.internal/x')"
  assert_reason "ctrl rule points at a file"      "$G" "file|bash <file>"       "$(bash_payload 'x=1
if [ -f a ]; then echo y; fi')"
else
  skip_gate "$G"
fi

# ------------------------------------------------------ git-commit-ticket-gate.sh reasons
# The stdin deny is the hook's ONE non-fail-open branch, and its reason has to explain the
# SHAPE rather than quote a message -- there is no message to quote. A decision-only case
# would pass just as happily on the generic "message doesn't start with a ref" text, which
# would send the reader looking for a message that does not exist.
G=git-commit-ticket-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  assert_reason "stdin deny names the shape, not a message" "$G" "stdin|-F -" \
    "$(bash_payload_cwd "printf 'no ticket\n' | git -C $real_harness commit -F -" "$real_harness")"
else
  skip_gate "$G"
fi

# ------------------------------------------------------- lib-chatfile-link.sh (+ rename path)
# Not a gate: lib-chatfile-link.sh, lib-fallback-rename.sh's sync_session_name and
# rename-topic.sh share one sandboxed-HOME selftest. Per-turn self-rename onto a name another
# session held minted "(sid8-N)" files and dead statefile paths (harness-gaps 2026-10-12).
G=lib-chatfile-link.sh
if want_gate "$G" && [ -f "$hooks/$G" ] && [ -f "$real_harness/scripts/chatfile-link-selftest.sh" ]; then
  _cf_out="$(bash "$real_harness/scripts/chatfile-link-selftest.sh" 2>&1)"
  if [ $? -eq 0 ]; then pass=$((pass+1)); else
    fail=$((fail+1)); printf 'FAIL  %-46s\n%s\n' "chatfile-link-selftest" "$(printf '%s' "$_cf_out" | grep FAIL)"
  fi
  unset _cf_out
else
  skip_gate "$G"
fi

# ------------------------------------------------------- deploy-verify-confirm-gate.sh
# Approval is one line per session id in ~/.claude/.deploy-verify-approved and is CONSUMED on
# use, so a second launch in the same session must ask again. Only the probe sid line is
# touched -- real approvals in that file are left alone.
G=deploy-verify-confirm-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  DSID="$PROBE_SID-deploy"
  DFILE="$(hstate tickets .deploy-verify-approved)"
  VCMD='bash "$HOME/.claude/skills/ama-cloudwatch-search/scripts/verify-qa-deploy.sh" manage'
  dp() { jq -nc --arg c "$1" --arg s "$DSID" --arg d "$real_harness" '{tool_name:"Bash",cwd:$d,session_id:$s,tool_input:{command:$c}}'; }
  # `grep -v` exits 1 when it selects NOTHING, so `grep -v … && mv` silently skipped the mv in the
  # one case that matters most: a file whose ONLY line is a stale probe approval, left behind by
  # an interrupted run. The stale line then survived and the "no approval" case passed for the
  # wrong reason. Detach the mv from grep's exit status.
  strip_probe_sid() {
    [ -f "$DFILE" ] || return 0
    grep -v "^$DSID\(	\|$\)" "$DFILE" > "$DFILE.probe" 2>/dev/null || :
    [ -f "$DFILE.probe" ] && mv -f "$DFILE.probe" "$DFILE"
    return 0
  }
  strip_probe_sid
  assert "verify launch with no approval"        "$G" deny "$(dp "$VCMD")"
  # Inert mention: the command merely CONTAINS the script name, it doesn't invoke it.
  assert "script name inside an echo"           "$G" pass "$(dp "echo \"run $VCMD when ready\"")"
  printf '%s\n' "$DSID" >> "$DFILE"
  assert "verify launch after approval"         "$G" pass "$(dp "$VCMD")"
  # PreToolUse no longer consumes: a sibling gate denying the call must not burn the
  # approval (harness-gaps 2026-10-06). The PostToolUse side (call actually ran) consumes.
  assert "pre-allow does not consume approval"  "$G" pass "$(dp "$VCMD")"
  dpost() { dp "$1" | jq -c '. + {hook_event_name:"PostToolUse"}'; }
  assert "post side never denies"               "$G" pass "$(dpost "$VCMD")"
  assert "second launch, approval consumed"     "$G" deny "$(dp "$VCMD")"
  assert "post with no approval stays silent"   "$G" pass "$(dpost "$VCMD")"
  # Scoped approvals (PROJ-15435): an approval names <repo>:<version>, so a run that
  # verifies a DIFFERENT artifact is denied rather than riding on the earlier yes. The
  # bare-sid rows above are the pre-scope shape and must keep working -- and must keep
  # being CONSUMED, which is what breaks first if the row is reconstructed rather than
  # matched literally.
  VCMD143="$VCMD ecs 15 \"\" 2.0.0.143"
  VCMD144="$VCMD ecs 15 \"\" 2.0.0.144"
  printf '%s	manage:2.0.0.143
' "$DSID" >> "$DFILE"
  assert "scoped approval, same artifact"       "$G" pass "$(dp "$VCMD143")"
  printf '%s	manage:2.0.0.143
' "$DSID" >> "$DFILE"
  assert "scoped approval, changed version"     "$G" deny "$(dp "$VCMD144")"
  printf '%s	manage:2.0.0.143
' "$DSID" >> "$DFILE"
  assert_reason "changed artifact names both scopes" "$G"     'approved for manage:2\.0\.0\.143.*verifies manage:2\.0\.0\.144' "$(dp "$VCMD144")"
  # 2026-10-12 user decision: an e2e run that stops at Stage 1/2 verified nothing, so the
  # yes carries to the rerun. The gate's post side leaves e2e alone; the script consumes on
  # entering Stage 3 via confirm-deploy-verify.sh --consume.
  strip_probe_sid
  ECMD='bash "$HOME/.claude/skills/ama-cloudwatch-search/scripts/verify-deployment-e2e.sh" manage'
  printf '%s\n' "$DSID" >> "$DFILE"
  assert "e2e launch after approval"            "$G" pass "$(dp "$ECMD")"
  assert "e2e post side stays silent"           "$G" pass "$(dpost "$ECMD")"
  assert "e2e rerun keeps the approval"         "$G" pass "$(dp "$ECMD")"
  # An unscoped row unlocks any run, so any repo's Stage 3 may spend it; a SCOPED one only its own.
  strip_probe_sid
  printf '%s\tmanage:\n' "$DSID" >> "$DFILE"
  bash "$hooks/confirm-deploy-verify.sh" --consume "$DSID" search 2.0.0.150
  assert "consume for another repo leaves it"   "$G" pass "$(dp "$ECMD")"
  bash "$hooks/confirm-deploy-verify.sh" --consume "$DSID" manage 2.0.0.150
  assert "Stage 3 consume spends it"            "$G" deny "$(dp "$ECMD")"
  strip_probe_sid
else
  skip_gate "$G"
fi

# ------------------------------------------------------- ecs-running-image-gate.sh
# PROJ-15355: a correct fix was reverted because the deploy check read
# describe-services -> services[0].taskDefinition, which the service points at from the
# MOMENT a rollout starts, not when the new task begins serving. Warn-only (additionalContext,
# no permissionDecision) and once per session, so it must stay silent on the legitimate shapes:
# describe-task-definition for env vars/credentials, and the CORRECT describe-tasks call.
G=ecs-running-image-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  ESID="$PROBE_SID-ecsimage"
  EMARK="$HOME/.claude/.session-chatfiles/$ESID.ecsimage"
  ep() { jq -nc --arg c "$1" --arg s "${2:-$ESID}" '{tool_name:"Bash",session_id:$s,tool_input:{command:$c}}'; }
  ectx() {
    local raw
    raw="$(printf '%s' "$1" | bash "$hooks/$G" 2>/dev/null)"
    [ -n "$raw" ] || return 0
    printf '%s' "$raw" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null
  }
  eassert() { # eassert <desc> <SPEAKS|SILENT> <payload>
    local desc="$1" want="$2" got; got="$(ectx "$3")"
    if [ "$want" = SILENT ]; then
      [ -z "$got" ] && { pass=$((pass+1)); return; }
      fail=$((fail+1)); printf 'FAIL  %-46s want=SILENT  got=spoke\n' "$desc"; return
    fi
    case "$got" in
      *"describe-tasks"*) pass=$((pass+1)) ;;
      *) fail=$((fail+1)); printf 'FAIL  %-46s want=SPEAKS  got=%s\n' "$desc" "${got:-<silent>}" ;;
    esac
  }

  rm -f "$EMARK"
  # The exact command that caused the incident.
  eassert "describe-services mined for taskDefinition" SPEAKS \
    "$(ep "aws ecs describe-services --cluster qa-v1-AMA --services qa-v1-search-api-isvc --query 'services[0].taskDefinition' --output text")"
  # Once per session: the same shape again must stay quiet.
  eassert "second call in the same session"          SILENT \
    "$(ep "aws ecs describe-services --cluster qa-v1-AMA --services other --query 'services[0].taskDefinition'")"
  rm -f "$EMARK"
  # Legitimate: reading a task definition's env vars is how connection strings/HMAC keys are
  # resolved (ama-postgres-access). Must never be nagged.
  eassert "describe-task-definition for env vars"    SILENT \
    "$(ep "aws ecs describe-task-definition --task-definition qa-v1-search-api --query 'taskDefinition.containerDefinitions[0].environment'" "$ESID-b")"
  # The CORRECT call the gate is steering towards.
  eassert "describe-tasks on a running task"         SILENT \
    "$(ep "aws ecs describe-tasks --cluster qa-v1-AMA --tasks \$t --query 'tasks[0].containers[0].image'" "$ESID-c")"
  # describe-services for rollout health, not for the image.
  eassert "describe-services for runningCount"       SILENT \
    "$(ep "aws ecs describe-services --cluster qa-v1-AMA --services x --query 'services[0].runningCount'" "$ESID-d")"
  eassert "unrelated command"                        SILENT "$(ep "git status" "$ESID-e")"

  # The incident's ACTUAL shape: the describe-services call lived inside a scratchpad script
  # and the command was just `bash <path>`. A command-text-only match misses it -- i.e. misses
  # the one case this gate exists for -- so it scans the referenced script via
  # lib-scan-script-refs.sh, the same helper the DB write gates use for the same bypass.
  ESCRATCH="$HOME/AppData/Local/Temp/claude/check-gates-probe"
  mkdir -p "$ESCRATCH" 2>/dev/null
  printf '%s\n' '#!/usr/bin/env bash' \
    'td=$(aws ecs describe-services --cluster qa-v1-AMA --services x --query "services[0].taskDefinition" --output text)' \
    > "$ESCRATCH/check-qa-image.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'echo nothing to see here' > "$ESCRATCH/harmless.sh"

  eassert "describe-services inside a scratch script"  SPEAKS \
    "$(ep "bash \"$ESCRATCH/check-qa-image.sh\"" "$ESID-f")"
  # short-path-gate.sh tells every session to write scratch paths as "$HOME/..." -- the lib
  # resolves that, and must keep doing so or the harness's own path rule reopens the hole.
  eassert "same, via the mandated \$HOME form"         SPEAKS \
    "$(ep 'bash "$HOME/AppData/Local/Temp/claude/check-gates-probe/check-qa-image.sh"' "$ESID-g")"
  eassert "scratch script with no ECS call in it"      SILENT \
    "$(ep "bash \"$ESCRATCH/harmless.sh\"" "$ESID-h")"

  rm -rf "$ESCRATCH"
  rm -f "$HOME/.claude/.session-chatfiles/$ESID"*.ecsimage
else
  skip_gate "$G"
fi

# ------------------------------------------------------------------ parallel-fanout-gate.sh
# Reads `transcript_path` straight from the payload, so a synthesised transcript is enough --
# no fake HOME. It also only acts in `default` permission mode (auto has no per-call prompt to
# stack, plan blocks outright), which is itself worth asserting.
G=parallel-fanout-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  FBASE="$(cgmktemp -d "${TMPDIR:-/tmp}/gatefix-fan.XXXXXX")"
  BATCH="$FBASE/batch.jsonl"; SEQ="$FBASE/seq.jsonl"
  jq -nc '{type:"assistant",message:{content:[{type:"tool_use",name:"Bash",id:"tu_a"},{type:"tool_use",name:"Bash",id:"tu_b"}]}}' > "$BATCH"
  jq -nc '{type:"assistant",message:{content:[{type:"tool_use",name:"Bash",id:"tu_a"}]}}'  > "$SEQ"
  jq -nc '{type:"user",message:{content:[{type:"tool_result"}]}}'                         >> "$SEQ"
  jq -nc '{type:"assistant",message:{content:[{type:"tool_use",name:"Bash",id:"tu_b"}]}}' >> "$SEQ"
  fp() { jq -nc --arg t "$1" --arg id "$2" --arg m "$3" \
    --arg fsid "$PROBE_SID-fan" \
    '{tool_name:"Bash",session_id:$fsid,transcript_path:$t,tool_use_id:$id,permission_mode:$m,tool_input:{command:"ls -la"}}'; }
  assert "2nd call in an uninterrupted batch"   "$G" deny "$(fp "$BATCH" tu_b default)"
  assert "1st call of the same batch"           "$G" pass "$(fp "$BATCH" tu_a default)"
  # A tool_result between the two calls means sequential work, not a batch.
  assert "second of two sequential calls"       "$G" pass "$(fp "$SEQ" tu_b default)"
  assert "same batch under auto mode"           "$G" pass "$(fp "$BATCH" tu_b auto)"
  assert "same batch under plan mode"           "$G" pass "$(fp "$BATCH" tu_b plan)"
  rm -rf "$FBASE" 2>/dev/null || true
else
  skip_gate "$G"
fi

# ------------------------------------------------------------------- publish-scrub-gate.sh
# Only the cheap branches are asserted through the hook: faking a staged harness index would
# fight another session's staged files. The substantive behaviour -- does the scrub+gate
# actually catch a forbidden token -- is asserted directly against publish-public.sh
# --check-paths, which is what the hook calls.
G=publish-scrub-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  PBASE="$(cgmktemp -d "${TMPDIR:-/tmp}/gatefix-pub.XXXXXX")"
  git init -q "$PBASE/repo" 2>/dev/null
  pp() { jq -nc --arg c "$1" --arg d "$2" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}'; }
  assert "commit in a non-harness repo"        "$G" pass "$(pp "git -C $PBASE/repo commit -m 'PROJ-1: x'" "$PBASE/repo")"
  assert "non-commit command in the harness"   "$G" pass "$(pp "git -C $real_harness status --porcelain" "$real_harness")"
  # FAIL CLOSED on an unresolvable harness root (2026-09-15): the guarded action -- a secret
  # reaching the public mirror -- is irreversible, a denied commit is not. Four `|| exit 0`
  # in a row used to let a commit through whenever the skills junction was broken, which is
  # also precisely when the environment is least trustworthy. Pointed at a non-repo dir.
  mkdir -p "$PBASE/notarepo"
  PUBLISH_SCRUB_SKILLS_DIR="$PBASE/notarepo" assert "unresolvable harness root fails closed" "$G" deny "$(pp "git -C $real_harness commit -m 'PROJ-1: x'" "$real_harness")"
  # THE deny case. Without it this gate's cases were all PASSES, so neutering the gate changed
  # nothing and mutate-gates.sh correctly reported "case cannot fail" -- shipped that way once.
  # A real deny needs real staged content. That used to mean staging into the SHARED index and
  # skipping whenever a concurrent session had anything staged -- which silently retired the
  # only case here that can fail, exactly the "case cannot fail" state above warns about (it
  # skipped on a real run, 2026-08-28). Stage into a PRIVATE index instead: GIT_INDEX_FILE is
  # honoured by the gate's own `git -C "$repo" diff --cached --name-only`, so the case always
  # runs and the shared index is never touched. Seeded from HEAD via read-tree, otherwise an
  # empty index reports every tracked file as deleted alongside the probe.
  # Absolute path required -- the gate uses `git -C`, which would resolve a relative one
  # against the wrong directory.
  PROBE_REL="scratch/gate-probe-staged.md"
  PROBE_IDX="$PBASE/probe-index"
  {
    # Split across a concatenation so THIS FILE's own source never contains the
    # contiguous forbidden substring -- check-gates.sh itself is exported to the public
    # mirror (not in publish-public.sh's excluded_from_export list), so a fixture
    # written as one literal here would abort a commit of this very file, at the
    # source-text level, regardless of what the runtime test below actually does.
    # Confirmed live 2026-08-21 (<harnessEpicKey>) -- mapping the literal away in
    # public-scrub-map.txt was tried first and was WRONG: it also scrubbed the runtime
    # fixture below, so the "must be flagged" assertion started passing for the wrong
    # reason (false negative on the detector itself).
    _frag1="compute-1"; _frag2="amazonaws.com"
    printf 'bastion ec2-9-9-9-9.%s.%s is the box\n' "$_frag1" "$_frag2" > "$real_harness/$PROBE_REL"
    # -f: scratch/ is gitignored, so a plain add silently stages nothing and the deny case
    # degrades into asserting against a clean index (seen live 2026-08-19: want=deny got=pass).
    # Exported explicitly rather than as a `VAR=x assert ...` prefix: `assert` is a shell
    # function, and an env prefix on a function is not reliably visible to the grandchild
    # process that actually runs the gate.
    export GIT_INDEX_FILE="$PROBE_IDX"
    git -C "$real_harness" read-tree HEAD 2>/dev/null
    git -C "$real_harness" add -f -- "$PROBE_REL" 2>/dev/null
    assert "harness commit with a forbidden token staged" "$G" deny "$(pp "git -C $real_harness commit -m 'PROJ-1: x'" "$real_harness")"
    unset GIT_INDEX_FILE
    # No `git reset` -- the shared index was never written, so there is nothing to unstage.
    rm -f "$PROBE_IDX" 2>/dev/null || true
    rm -f "$real_harness/$PROBE_REL" 2>/dev/null || true
  }
  # Pathspec / -a commits (2026-10-28): they carry an UNSTAGED change the gate never looked at,
  # and SHARED-REPO.md makes pathspec commits the norm. A throwaway harness stands in, via
  # PUBLISH_SCRUB_SKILLS_DIR -- the real one's index and tracked files are never touched.
  PH="$PBASE/harness"; mkdir -p "$PH/scripts" "$PH/skills"
  git init -q "$PH" 2>/dev/null
  for _f in scripts/publish-public.sh scripts/public-scrub-map.txt scripts/public-scrub-gate.txt \
            scripts/public-email-allow.txt harness-config.json harness-config.example.json; do
    cp "$real_harness/$_f" "$PH/$_f"
  done
  printf 'clean\n' > "$PH/notes.md"
  git -C "$PH" add -A 2>/dev/null; git -C "$PH" -c user.name=t -c user.email=t@t commit -q -m init 2>/dev/null
  _frag1="compute-1"; _frag2="amazonaws.com"   # split: see PROBE_REL above
  printf 'bastion ec2-9-9-9-9.%s.%s is the box\n' "$_frag1" "$_frag2" > "$PH/notes.md"
  export PUBLISH_SCRUB_SKILLS_DIR="$PH/skills"
  assert "pathspec commit, unstaged forbidden change" "$G" deny "$(pp "git -C $PH commit -m 'PROJ-1: x' -- notes.md" "$PH")"
  assert "commit -am, unstaged forbidden change"      "$G" deny "$(pp "git -C $PH commit -am 'PROJ-1: x'" "$PH")"
  assert "a change the commit does not name passes"   "$G" pass "$(pp "git -C $PH commit -m 'PROJ-1: x' -- other.md" "$PH")"
  unset PUBLISH_SCRUB_SKILLS_DIR
  if [ -x "$real_harness/scripts/publish-public.sh" ] || [ -f "$real_harness/scripts/publish-public.sh" ]; then
    # Same split-literal reasoning as PROBE_REL above.
    _frag1="compute-1"; _frag2="amazonaws.com"
    printf 'bastion host ec2-1-2-3-4.%s.%s is the box\n' "$_frag1" "$_frag2" > "$real_harness/scratch/gate-probe-forbidden.md"
    assert_exit "check-paths flags a forbidden token" nonzero \
      bash "$real_harness/scripts/publish-public.sh" --check-paths scratch/gate-probe-forbidden.md
    printf 'nothing sensitive here at all\n' > "$real_harness/scratch/gate-probe-clean.md"
    assert_exit "check-paths passes a clean file"     zero \
      bash "$real_harness/scripts/publish-public.sh" --check-paths scratch/gate-probe-clean.md
    # A scrub placeholder is `<...>`: unquoted in a case pattern it breaks shell syntax and the
    # real publish's bash -n step aborts (2026-10-14). Quoted, it stays a plain literal.
    printf '%s\n' 'case "$1" in *<repository>-api-testing*) : ;; esac' > "$real_harness/scratch/gate-probe-syntax.sh"
    assert_exit "check-paths flags a scrub that breaks shell syntax" nonzero \
      bash "$real_harness/scripts/publish-public.sh" --check-paths scratch/gate-probe-syntax.sh
    printf '%s\n' "case \"\$1\" in *'<repository>-api-testing'*) : ;; esac" > "$real_harness/scratch/gate-probe-syntax.sh"
    assert_exit "check-paths passes the same literal quoted" zero \
      bash "$real_harness/scripts/publish-public.sh" --check-paths scratch/gate-probe-syntax.sh
    # Step 4c (2026-10-28): an unknown address, and a config person's name in a spelling the
    # literal scrub misses (lowercase, space for the dot). The address is split like the
    # fixtures above -- step 4c reads this file too. The name comes from the live config.
    _at="@"; printf 'mail jane.doe%sacme-widgets.io about it\n' "$_at" > "$real_harness/scratch/gate-probe-email.md"
    assert_exit "check-paths flags an unlisted email address" nonzero \
      bash "$real_harness/scripts/publish-public.sh" --check-paths scratch/gate-probe-email.md
    printf 'mail someone@example.com about it\n' > "$real_harness/scratch/gate-probe-email.md"
    assert_exit "check-paths passes a placeholder address" zero \
      bash "$real_harness/scripts/publish-public.sh" --check-paths scratch/gate-probe-email.md
    # A new colleague at the company's own domain: the scrub swaps the domain for a placeholder,
    # so only the as-written check (step 2b) can see the name. Domain from the live config.
    _dom="$(jq -r '.user.email // empty' "$real_harness/harness-config.json" 2>/dev/null | tr -d '\r' | sed 's/^[^@]*@//')"
    if [ -n "$_dom" ]; then
      printf 'mail new.starter%s%s about it\n' "$_at" "$_dom" > "$real_harness/scratch/gate-probe-email.md"
      assert_exit "check-paths flags a colleague at the company domain" nonzero \
        bash "$real_harness/scripts/publish-public.sh" --check-paths scratch/gate-probe-email.md
    fi
    _who="$(jq -r '[.audiences.people[]?.emails[]?] | .[0] // empty' "$real_harness/harness-config.json" 2>/dev/null \
      | tr -d '\r' | sed 's/@.*//; s/[0-9]*$//; s/[._-]/ /g' | tr 'A-Z' 'a-z')"
    if [ -n "$_who" ]; then
      printf 'ask %s about it\n' "$_who" > "$real_harness/scratch/gate-probe-email.md"
      assert_exit "check-paths flags a config person, any spelling" nonzero \
        bash "$real_harness/scripts/publish-public.sh" --check-paths scratch/gate-probe-email.md
    fi
    rm -f "$real_harness/scratch/gate-probe-forbidden.md" "$real_harness/scratch/gate-probe-clean.md" \
          "$real_harness/scratch/gate-probe-syntax.sh" "$real_harness/scratch/gate-probe-email.md" 2>/dev/null || true
  else
    skip=$((skip+1)); printf 'SKIP  %s: publish-public.sh absent\n' "$G"
  fi
  rm -rf "$PBASE" 2>/dev/null || true
else
  skip_gate "$G"
fi

# ------------------------------------------------------- cross-session-repo-claim.sh
# Shared-clone coordination. Needs three things a normal section doesn't: a real git repo,
# a seeded .repo-claims file, and controllable session liveness -- hence CLAIMS_FILE and
# CLAUDE_PROJECTS_DIR overrides in the libs. Never writes to real session state.
G=cross-session-repo-claim.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  XBASE="$(mktemp -d)"
  XREPO="$XBASE/repo"; mkdir -p "$XREPO"
  git init -q "$XREPO" 2>/dev/null
  git -C "$XREPO" config user.email t@t.t; git -C "$XREPO" config user.name t
  echo one > "$XREPO/f"; git -C "$XREPO" add -A
  git -C "$XREPO" commit -q -m "PROJ-1: base" --no-verify 2>/dev/null
  git -C "$XREPO" checkout -q -B master 2>/dev/null
  XROOT="$(printf '%s' "$(git -C "$XREPO" rev-parse --show-toplevel)" | tr '\134' '/' | tr '[:upper:]' '[:lower:]')"

  MINE=aaaaaaaa-1111-2222-3333-444444444444
  THEIRS=bbbbbbbb-5555-6666-7777-888888888888

  # Fake transcripts: THEIRS fresh = live; back-date it to 20 min for the stale case.
  XPROJ="$XBASE/projects/p"; mkdir -p "$XPROJ"
  : > "$XPROJ/$THEIRS.jsonl"
  : > "$XPROJ/$MINE.jsonl"

  xp() { jq -n --arg c "$1" --arg s "$2" --arg d "$XREPO" \
    '{tool_name:"Bash",session_id:$s,cwd:$d,tool_input:{command:$c}}'; }
  xdecide() { CLAIMS_FILE="$XBASE/claims" CLAUDE_PROJECTS_DIR="$XBASE/projects" \
    FCLAIMS_FILE="$XBASE/fclaims" \
    bash -c 'printf "%s" "$1" | bash "$2" 2>/dev/null' _ "$2" "$hooks/$1" \
    | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null; }
  xassert() { # desc want-regex(empty=silent) payload
    local desc="$1" want="$2" pl="$3" got
    got="$(xdecide "$G" "$pl")"
    if [ -z "$want" ]; then
      if [ -z "$got" ]; then pass=$((pass+1)); else
        fail=$((fail+1)); printf 'FAIL  %-46s want=silent got=%s\n' "$desc" "$(printf '%s' "$got" | head -c 50)"; fi
    else
      if printf '%s' "$got" | grep -qiE "$want"; then pass=$((pass+1)); else
        fail=$((fail+1)); printf 'FAIL  %-46s want-reason=/%s/ got=%s\n' "$desc" "$want" "$(printf '%s' "$got" | head -c 50)"; fi
    fi
  }

  # No claims recorded yet -> nothing to say.
  xassert "no claim recorded is silent" "" "$(xp "git -C $XREPO checkout -b feature/x" "$MINE")"

  # Seed: THEIRS holds the repo on their own branch, live.
  printf '%s\t%s\t%s\t%s\n' "$XROOT" "$THEIRS" "feature/theirs" "$(date +%s)" > "$XBASE/claims"

  xassert "cross-session checkout warns"      "claimed by another live session" \
    "$(xp "git -C $XREPO checkout -b feature/mine" "$MINE")"
  xassert "warn names the holding branch"     "feature/theirs" \
    "$(xp "git -C $XREPO switch -c feature/mine" "$MINE")"
  # FALSE-POSITIVE guard: a non-branch-changing command must not warn.
  xassert "plain status does not warn"        "" \
    "$(xp "git -C $XREPO status" "$MINE")"

  # Stale holder (transcript 20 min old) -> liveness fails -> silence, so a dead session
  # can never nag forever. This is the case that makes claims safe without a lock.
  touch -d '20 minutes ago' "$XPROJ/$THEIRS.jsonl" 2>/dev/null || touch -t "$(date -d '20 minutes ago' +%Y%m%d%H%M 2>/dev/null)" "$XPROJ/$THEIRS.jsonl" 2>/dev/null
  xassert "stale holder goes silent"          "" \
    "$(xp "git -C $XREPO checkout -b feature/mine" "$MINE")"
  touch "$XPROJ/$THEIRS.jsonl"

  # Hotfix contention: same repo, both hotfix -> warn. Different repo would not reach here.
  printf '%s\t%s\t%s\t%s\n' "$XROOT" "$THEIRS" "hotfix/9.9.9" "$(date +%s)" > "$XBASE/claims"
  xassert "same-repo hotfix contention warns" "hotfix contention" \
    "$(xp "git -C $XREPO checkout -b hotfix/9.9.10" "$MINE")"

  # Branch moved under ME: my own claim says master, HEAD is master -> silent; then move HEAD.
  printf '%s\t%s\t%s\t%s\n' "$XROOT" "$MINE" "master" "$(date +%s)" > "$XBASE/claims"
  xassert "own claim matching HEAD is silent" "" \
    "$(xp "git -C $XREPO commit -m 'PROJ-1: x'" "$MINE")"
  git -C "$XREPO" checkout -q -B other 2>/dev/null
  xassert "branch moved under me warns"       "moved under you" \
    "$(xp "git -C $XREPO commit -m 'PROJ-1: x'" "$MINE")"
  xassert "moved-under-me names both branches" "master.*other|other.*master" \
    "$(xp "git -C $XREPO push origin other" "$MINE")"

  # --record writes a claim
  CLAIMS_FILE="$XBASE/claims2" CLAUDE_PROJECTS_DIR="$XBASE/projects" \
    FCLAIMS_FILE="$XBASE/fclaims" \
    bash -c 'printf "%s" "$1" | bash "$2" --record >/dev/null 2>&1' _ \
    "$(xp "git -C $XREPO checkout other" "$MINE")" "$hooks/$G"
  if grep -q "$MINE" "$XBASE/claims2" 2>/dev/null; then pass=$((pass+1)); else
    fail=$((fail+1)); printf 'FAIL  %-46s --record wrote no claim\n' "record mode"; fi

  # ---- check 2: FILE collisions at commit time (PROJ-15368) --------------------
  # Warns when a file in the tree carries a ledger row from another LIVE session. Fires on
  # commit and `add -A` only: the raw collision rate is ~150/week and almost all of them are
  # harmless, so an edit-time warning would be noise for the two cases that actually hurt.
  printf '' > "$XBASE/claims"          # isolate from the branch checks above
  git -C "$XREPO" checkout -q -B master 2>/dev/null
  echo mine > "$XREPO/g"; git -C "$XREPO" add -A >/dev/null 2>&1
  git -C "$XREPO" commit -q -m "PROJ-1: add g" --no-verify 2>/dev/null
  echo three > "$XREPO/f"; echo mine2 > "$XREPO/g"   # both MODIFIED, so both are sweepable
  : > "$XPROJ/$THEIRS.jsonl"           # live again
  printf '%s/f\tTHEIRSID\t%s\n' "$XROOT" "$(date +%s)" | sed "s/THEIRSID/$THEIRS/" > "$XBASE/fclaims"

  xassert "foreign live file claim warns on commit" "belong to another live session" \
    "$(xp "git -C $XREPO commit -m 'PROJ-1: x'" "$MINE")"
  xassert "file warn names the shared file"         " - f " \
    "$(xp "git -C $XREPO commit -m 'PROJ-1: x'" "$MINE")"
  xassert "file warn on git add -A"                 "belong to another live session" \
    "$(xp "git -C $XREPO add -A" "$MINE")"
  # FALSE-POSITIVE guards: reads must never warn, and an unclaimed file must not be named.
  xassert "file check silent on plain status"       "" \
    "$(xp "git -C $XREPO status --porcelain" "$MINE")"
  xassert "file check silent on git log"            "" \
    "$(xp "git -C $XREPO log --oneline -3" "$MINE")"
  xassert "file warn omits unclaimed g"             "^(( - g )*[^-]*)*$" \
    "$(xp "git -C $XREPO commit -m 'PROJ-1: x'" "$MINE")"

  # A dead claimant must never nag -- the property that makes claims safe without a lock.
  touch -d '20 minutes ago' "$XPROJ/$THEIRS.jsonl" 2>/dev/null || touch -t "$(date -d '20 minutes ago' +%Y%m%d%H%M 2>/dev/null)" "$XPROJ/$THEIRS.jsonl" 2>/dev/null
  xassert "stale file claimant goes silent"         "" \
    "$(xp "git -C $XREPO commit -m 'PROJ-1: x'" "$MINE")"
  : > "$XPROJ/$THEIRS.jsonl"

  # My own earlier claim on the same file is not a collision.
  printf '%s/f\tMINESID\t%s\n' "$XROOT" "$(date +%s)" | sed "s/MINESID/$MINE/" > "$XBASE/fclaims"
  xassert "own file claim goes silent"              "" \
    "$(xp "git -C $XREPO commit -m 'PROJ-1: x'" "$MINE")"

  # Absent ledger: silence, not an error.
  rm -f "$XBASE/fclaims"
  xassert "absent file ledger goes silent"          "" \
    "$(xp "git -C $XREPO commit -m 'PROJ-1: x'" "$MINE")"

  # Warn-only, always. A stale claim must never be able to wedge an urgent commit.
  printf '%s/f\tTHEIRSID\t%s\n' "$XROOT" "$(date +%s)" | sed "s/THEIRSID/$THEIRS/" > "$XBASE/fclaims"
  xd="$(CLAIMS_FILE="$XBASE/claims" CLAUDE_PROJECTS_DIR="$XBASE/projects" FCLAIMS_FILE="$XBASE/fclaims" \
    bash -c 'printf "%s" "$1" | bash "$2" 2>/dev/null' _ "$(xp "git -C $XREPO commit -m 'PROJ-1: x'" "$MINE")" "$hooks/$G" \
    | jq -r '.hookSpecificOutput.permissionDecision // ""' 2>/dev/null)"
  if [ "$xd" = allow ]; then pass=$((pass+1)); else
    fail=$((fail+1)); printf 'FAIL  %-46s want=allow got=%s\n' "file warn never denies" "$xd"; fi

  rm -rf "$XBASE" 2>/dev/null || true
else
  skip_gate "$G"
fi

# ------------------------------------------------------------- file-claim-record.sh
# The RECORDER half of the file-claim pair. Silent by contract: it must write a row, print
# nothing, and never be the reason an edit fails. Kept cheap on purpose -- it is the tenth
# hook on the Edit|Write path (baseline for the other nine: 2.53s total, 2026-09-01 solo).
G=file-claim-record.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  RBASE="$(mktemp -d)"
  RLED="$RBASE/fclaims"
  rp() { jq -n --arg f "$1" --arg s "$2" '{tool_name:"Edit",session_id:$s,tool_input:{file_path:$f}}'; }
  rrun()  { printf '%s' "$1" | FCLAIMS_FILE="$RLED" bash "$hooks/$G" 2>&1; }
  rroff() { printf '%s' "$1" | FCLAIMS_FILE="$RLED" FILE_CLAIMS=off bash "$hooks/$G" 2>&1; }
  rok() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else
    fail=$((fail+1)); printf 'FAIL  %-46s want=%s got=%s\n' "$1" "$3" "$2"; fi; }
  rrows() { wc -l < "$RLED" 2>/dev/null | tr -d ' '; }
  rhere() { [ -f "$RLED" ] && echo yes || echo no; }

  R1=eeeeeeee-1111-2222-3333-444444444444
  R2=ffffffff-5555-6666-7777-888888888888
  # Single quotes keep the backslashes literal; jq --arg does the JSON escaping.
  RWIN='C:\Users\x\A.md'

  out="$(rrun "$(rp "$RWIN" "$R1")")"
  rok "recorder prints nothing"        "${out:-empty}" "empty"
  rok "recorder wrote one row"         "$(rrows)" "1"

  # Windows and POSIX spellings of ONE file must land on ONE key, or every warning misses.
  rrun "$(rp '/c/Users/x/A.md' "$R2")" >/dev/null 2>&1
  rok "two spellings share one key"    "$(cut -f1 "$RLED" | sort -u | wc -l | tr -d ' ')" "1"
  rok "two sessions, two rows"         "$(rrows)" "2"

  # Re-editing must UPSERT, not append -- otherwise the ledger grows without bound.
  rrun "$(rp "$RWIN" "$R1")" >/dev/null 2>&1
  rok "same session upserts"           "$(rrows)" "2"

  # Toggle, and the two malformed shapes. All three must leave no file at all.
  rm -f "$RLED"
  rroff "$(rp 'C:/x/B.md' "$R1")" >/dev/null 2>&1
  rok "FILE_CLAIMS=off writes nothing" "$(rhere)" "no"
  rrun 'not json' >/dev/null 2>&1
  rok "garbage payload writes nothing" "$(rhere)" "no"
  rrun '{"tool_name":"Edit","tool_input":{"file_path":"/c/x/y.md"}}' >/dev/null 2>&1
  rok "no session_id writes nothing"   "$(rhere)" "no"

  # Age cap prunes on write; the fresh row survives.
  printf 'c:/old.md\tOLDSID\t%s\n' "$(( $(date +%s) - 200000 ))" | sed "s/OLDSID/$R2/" > "$RLED"
  rrun "$(rp 'C:/x/C.md' "$R1")" >/dev/null 2>&1
  rok "expired row pruned on write"    "$(rrows)" "1"

  rm -rf "$RBASE" 2>/dev/null || true
else
  skip_gate "$G"
fi

# ------------------------------------------------------------- worktree-by-default
# Four pieces of the worktree-default policy (commit-ticket/SHARED-REPO.md): the recorder's
# one-shot worktree NUDGE (lib-file-claims.sh fclaims_nudge), lib-harness-worktree.sh's path
# resolver, scripts/worktree-prune.sh (against REAL repos -- the constraints are git's own),
# and scripts/worktree-add.sh. Run against a worktree's code: `check-gates.sh --gate
# worktree-default <worktree-root>`.
G=worktree-default
if want_gate "$G" && [ -f "$hooks/lib-harness-worktree.sh" ] && [ -f "$harness/scripts/worktree-prune.sh" ]; then
  NBASE="$(mktemp -d)"; NLED="$NBASE/fclaims"
  nrec() { printf '%s' "$(jq -n --arg f "$1" --arg s "$2" '{tool_name:"Edit",session_id:$s,tool_input:{file_path:$f}}')" \
             | FCLAIMS_FILE="$NLED" bash "$hooks/file-claim-record.sh" 2>&1; }
  nok() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else
    fail=$((fail+1)); printf 'FAIL  %-46s want=%s got=%s\n' "$1" "$3" "$2"; fi; }
  yn() { case "$1" in *WORKTREE*) echo nudge ;; '') echo silent ;; *) echo other ;; esac; }
  NR='C:\Users\x\Repos\AMA_APP'
  nok "solo edit in a product repo is silent"        "$(yn "$(nrec "$NR\\search\\a.cs" aaaaaaaa-1)")" silent
  nok "other session's fresh edit nudges"            "$(yn "$(nrec "$NR\\search\\b.cs" bbbbbbbb-2)")" nudge
  nok "nudge is once per session+repo"               "$(yn "$(nrec "$NR\\search\\c.cs" bbbbbbbb-2)")" silent
  nok "nudge output is valid hook JSON"              "$(nrec "$NR\\export\\a.cs" cccccccc-3 >/dev/null; nrec "$NR\\export\\b.cs" dddddddd-4 | jq -r '.hookSpecificOutput.hookEventName' 2>/dev/null)" PreToolUse
  nok "edit already inside .worktrees/ is silent"    "$(yn "$(nrec "$NR\\.worktrees\\search-x\\a.cs" eeeeeeee-5)")" silent
  nok "legacy *-worktrees root is silent"            "$(yn "$(nrec 'C:\ep-worktrees\ep-1\a.ts' ffffffff-6)")" silent
  nok "harness: first hooks file is silent"          "$(yn "$(nrec "$HOME/.claude/hooks/a.sh" 99999999-7)")" silent
  nok "harness: second hooks file nudges"            "$(yn "$(nrec "$HOME/.claude/hooks/b.sh" 99999999-7)")" nudge
  nok "harness: memory path never nudges"            "$(yn "$(nrec "$HOME/.claude/memory/m.md" 88888888-8)")" silent
  rm -f "$NLED"
  nok "FILE_CLAIMS=off: no nudge"                    "$( { nrec "$NR\\admin\\a.cs" 77777777-1 >/dev/null; printf '%s' "$(jq -n --arg f "$NR\\admin\\b.cs" '{session_id:"77777777-2",tool_input:{file_path:$f}}')" | FCLAIMS_FILE="$NLED" FILE_CLAIMS=off bash "$hooks/file-claim-record.sh" 2>&1; } | yn "$(cat)")" silent

  # lib-harness-worktree.sh: the resolver three Edit/Write gates use so worktree edits are not
  # silently skipped (they resolved "the harness" as the main clone only).
  hwt="$( . "$hooks/lib-harness-worktree.sh"; hwt_root_of 'C:/R/.worktrees/ama-claude-harness-x/hooks/a.sh'; printf '%s' "$HWT_ROOT")"
  nok "resolver: worktree file -> tree root"         "$hwt" 'C:/R/.worktrees/ama-claude-harness-x'
  hwt="$( . "$hooks/lib-harness-worktree.sh"; hwt_root_of 'C:\R\.worktrees\ama-claude-harness-x\skills\s\SKILL.md'; printf '%s' "$HWT_ROOT")"
  nok "resolver: backslash path too"                 "$hwt" 'C:/R/.worktrees/ama-claude-harness-x'
  hwt="$( . "$hooks/lib-harness-worktree.sh"; hwt_root_of 'C:/R/ama-claude-harness/hooks/a.sh'; printf '%s' "$HWT_ROOT")"
  nok "resolver: main clone -> empty"                "${hwt:-empty}" empty
  hwt="$( . "$hooks/lib-harness-worktree.sh"; hwt_root_of 'C:/R/.worktrees/search-develop/a.cs'; printf '%s' "$HWT_ROOT")"
  nok "resolver: other repo's worktree -> empty"     "${hwt:-empty}" empty

  # worktree-prune.sh against REAL repos: clean+pushed removable; dirty and unpushed kept; a
  # dry run removes nothing; --apply removes only the REMOVE one and its merged branch.
  NP="$NBASE/prune"; mkdir -p "$NP/repos"
  git init -q --bare "$NP/origin.git" 2>/dev/null
  git clone -q "$NP/origin.git" "$NP/repos/proj" 2>/dev/null
  git -C "$NP/repos/proj" config user.email t@t.t; git -C "$NP/repos/proj" config user.name t
  git -C "$NP/repos/proj" commit -q --allow-empty -m base --no-verify 2>/dev/null
  git -C "$NP/repos/proj" branch -M main 2>/dev/null
  git -C "$NP/repos/proj" push -q -u origin main 2>/dev/null
  for n in clean dirty ahead; do git -C "$NP/repos/proj" worktree add -q "$NP/repos/.worktrees/proj-$n" -b "$n" main >/dev/null 2>&1; done
  : > "$NP/repos/.worktrees/proj-dirty/untracked.txt"
  git -C "$NP/repos/.worktrees/proj-ahead" config user.email t@t.t; git -C "$NP/repos/.worktrees/proj-ahead" config user.name t
  git -C "$NP/repos/.worktrees/proj-ahead" commit -q --allow-empty -m local --no-verify 2>/dev/null
  pr() { AMA_REPOS_ROOT="$NP/repos" CLAIMS_FILE="$NP/claims" bash "$harness/scripts/worktree-prune.sh" --idle-days 0 "$@" 2>&1; }
  out="$(pr)"
  nok "prune: clean+pushed tree is REMOVE"           "$(printf '%s\n' "$out" | grep -c '^REMOVE .*proj-clean')" 1
  nok "prune: dirty tree is KEEP"                    "$(printf '%s\n' "$out" | grep -c '^KEEP .*proj-dirty.*dirty')" 1
  nok "prune: unpushed commit is KEEP"               "$(printf '%s\n' "$out" | grep -c '^KEEP .*proj-ahead.*unpushed')" 1
  nok "prune: dry run removes nothing"               "$([ -d "$NP/repos/.worktrees/proj-clean" ] && echo yes || echo no)" yes
  pr --apply >/dev/null
  nok "prune --apply removes the REMOVE tree"        "$([ -d "$NP/repos/.worktrees/proj-clean" ] && echo yes || echo no)" no
  nok "prune --apply deletes its merged branch"      "$(git -C "$NP/repos/proj" branch --list clean | wc -l | tr -d ' ')" 0
  nok "prune --apply leaves the dirty tree"          "$([ -d "$NP/repos/.worktrees/proj-dirty" ] && echo yes || echo no)" yes
  nok "prune --apply leaves the unpushed tree"       "$([ -d "$NP/repos/.worktrees/proj-ahead" ] && echo yes || echo no)" yes

  # worktree-add.sh: canonical root, prints the path, refuses to clobber.
  wa() { AMA_REPOS_ROOT="$NP/repos" bash "$harness/scripts/worktree-add.sh" "$@" 2>/dev/null; }
  nok "add: prints the canonical path"               "$(wa proj newone feat/x main | tail -1)" "$NP/repos/.worktrees/proj-newone"
  nok "add: tree exists on the new branch"           "$(git -C "$NP/repos/.worktrees/proj-newone" branch --show-current 2>/dev/null)" feat/x
  nok "add: second call to the same slug refuses"    "$(wa proj newone feat/y main >/dev/null; echo $?)" 1
  rm -rf "$NBASE" 2>/dev/null || true
else
  skip_gate "$G"
fi

# --------------------------------------------------- foreign-worktree-changes-gate.sh
G=foreign-worktree-changes-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  FBASE="$(mktemp -d)"
  FREPO="$FBASE/repo"; mkdir -p "$FREPO"
  git init -q "$FREPO" 2>/dev/null
  git -C "$FREPO" config user.email t@t.t; git -C "$FREPO" config user.name t
  echo one > "$FREPO/tracked"; git -C "$FREPO" add -A
  git -C "$FREPO" commit -q -m "PROJ-1: base" --no-verify 2>/dev/null
  FROOT="$(printf '%s' "$(git -C "$FREPO" rev-parse --show-toplevel)" | tr '\134' '/' | tr '[:upper:]' '[:lower:]')"
  FMINE=cccccccc-1111-2222-3333-444444444444
  FTHEIRS=dddddddd-5555-6666-7777-888888888888
  FPROJ="$FBASE/projects/p"; mkdir -p "$FPROJ"; : > "$FPROJ/$FTHEIRS.jsonl"
  printf '%s\t%s\t%s\t%s\n' "$FROOT" "$FTHEIRS" "master" "$(date +%s)" > "$FBASE/claims"

  fp() { jq -n --arg c "$1" --arg s "$FMINE" --arg d "$FREPO" \
    '{tool_name:"Bash",session_id:$s,cwd:$d,tool_input:{command:$c}}'; }
  fdecide() { CLAIMS_FILE="$FBASE/claims" CLAUDE_PROJECTS_DIR="$FBASE/projects" \
    bash -c 'printf "%s" "$1" | bash "$2" 2>/dev/null' _ "$1" "$hooks/$G" \
    | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null; }
  fassert() {
    local desc="$1" want="$2" pl="$3" got; got="$(fdecide "$pl")"
    if [ -z "$want" ]; then
      if [ -z "$got" ]; then pass=$((pass+1)); else
        fail=$((fail+1)); printf 'FAIL  %-46s want=silent got=%s\n' "$desc" "$(printf '%s' "$got" | head -c 50)"; fi
    else
      if printf '%s' "$got" | grep -qiE "$want"; then pass=$((pass+1)); else
        fail=$((fail+1)); printf 'FAIL  %-46s want-reason=/%s/ got=%s\n' "$desc" "$want" "$(printf '%s' "$got" | head -c 50)"; fi
    fi
  }

  # Clean tree -> nothing could be swept, so silent even with a live foreign claim.
  fassert "clean tree is silent"              "" "$(fp "git -C $FREPO add -A")"

  echo two > "$FREPO/tracked"            # modified TRACKED file
  echo x   > "$FREPO/untracked-noise"    # must NOT alone trigger

  fassert "add -A with foreign claim warns"   "sweeps all"      "$(fp "git -C $FREPO add -A")"
  fassert "warn lists the tracked file"       "tracked"         "$(fp "git -C $FREPO add .")"
  fassert "commit -a warns too"               "sweeps all"      "$(fp "git -C $FREPO commit -am 'PROJ-1: x'")"
  # BARE commit -- the shape the header always claimed and the code did not match until
  # 2026-09-15. It takes the whole INDEX, so an earlier call's `git add` by another session
  # rides along; that is how a settings.json edit got swept (harness-gaps.md, 2026-09-14).
  fassert "bare commit warns"                 "sweeps all"      "$(fp "git -C $FREPO commit -m 'PROJ-1: x'")"
  # ...but a bare commit only MENTIONED in fixture text is not one.
  fassert "quoted fixture commit silent"      ""  "$(fp "T='git -C $FREPO commit -m x'; echo \"\$T\"")"
  # FALSE-POSITIVE guards -- these are the shapes that must stay quiet.
  fassert "scoped commit -- <paths> silent"   ""  "$(fp "git -C $FREPO commit -m 'PROJ-1: x' -- tracked")"
  fassert "git add <named path> silent"       ""  "$(fp "git -C $FREPO add tracked")"

  # Untracked-only changes must not warn: build output is not somebody's stolen work.
  git -C "$FREPO" checkout -- tracked 2>/dev/null
  fassert "untracked-only changes silent"     ""  "$(fp "git -C $FREPO add -A")"

  rm -rf "$FBASE" 2>/dev/null || true
else
  skip_gate "$G"
fi

# ------------------------------------------------------- hotfix-version-claimed-gate.sh
# Network-dependent (queries Jira), so only the pre-network branches are asserted here --
# the deny path needs a live claimed version and belongs in a manual check, not in a suite
# that must pass offline. These are exactly the false-positive shapes.
G=hotfix-version-claimed-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  assert "plain checkout of existing branch passes" "$G" pass "$(bash_payload 'git checkout hotfix/1.0.1')"
  assert "unrelated branch creation passes"         "$G" pass "$(bash_payload 'git checkout -b feature/x origin/master')"
  assert "non-git text mentioning hotfix passes"    "$G" pass "$(bash_payload "echo 'hotfix/1.0.1 is claimed'")"
else
  skip_gate "$G"
fi

# ------------------------------------------------------------- hotfix-stowaway-gate.sh
# Builds a REAL repo: the predicate is git state (branch, upstream, ahead-of-origin/master
# commit ages), not command text, so a mocked payload alone proves nothing. origin/master
# is a plain local remote-tracking ref -- no network anywhere.
G=hotfix-stowaway-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  SBASE="$(mktemp -d)"
  git init -q "$SBASE" 2>/dev/null
  git -C "$SBASE" config user.email t@t.t; git -C "$SBASE" config user.name t
  echo base > "$SBASE/f"; git -C "$SBASE" add -A
  git -C "$SBASE" commit -q -m "PROJ-1: base" --no-verify 2>/dev/null
  git -C "$SBASE" checkout -q -B master 2>/dev/null
  # a real remote (self-URL) so @{u} can resolve -- without remote.origin.fetch,
  # rev-parse @{u} fatals "not stored as a remote-tracking branch" even with the ref present
  git -C "$SBASE" remote add origin "$SBASE" 2>/dev/null
  git -C "$SBASE" update-ref refs/remotes/origin/master master
  # a parked hotfix branch: one commit backdated 3 days = stowaway
  git -C "$SBASE" checkout -q -b hotfix/9.9.9 2>/dev/null
  echo stow > "$SBASE/f"
  git -C "$SBASE" add -A
  GIT_COMMITTER_DATE="$(date -d '3 days ago' '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -v-3d '+%Y-%m-%dT%H:%M:%S')" \
    git -C "$SBASE" commit -q -m "PROJ-2: parked stowaway" --no-verify 2>/dev/null
  stow_payload() { jq -n --arg c "$1" --arg d "$SBASE" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}'; }
  assert "commit onto stale parked hotfix branch denies" "$G" deny "$(stow_payload 'git commit -m "PROJ-3: new work"')"
  assert "git -C form denies too"                        "$G" deny "$(jq -n --arg c "git -C \"$SBASE\" commit -m x" '{tool_name:"Bash",cwd:"/tmp",tool_input:{command:$c}}')"
  assert "non-commit command passes"                     "$G" pass "$(stow_payload 'git status')"
  # ack hatch: exact HEAD reviewed -> allowed
  SROOT="$(git -C "$SBASE" rev-parse --show-toplevel)"
  SHEAD="$(git -C "$SBASE" rev-parse HEAD)"
  ACKF="$(hstate tickets .hotfix-stowaway-ack)"
  printf '%s|%s|%s\n' "$SROOT" "hotfix/9.9.9" "$SHEAD" >> "$ACKF"
  assert "acked HEAD passes"                             "$G" pass "$(stow_payload 'git commit -m "PROJ-3: new work"')"
  grep -vxF "$SROOT|hotfix/9.9.9|$SHEAD" "$ACKF" > "$ACKF.tmp" 2>/dev/null; mv "$ACKF.tmp" "$ACKF"
  # fresh own commit on top (committer date = now) -> still stale one below, denies;
  # but a branch whose ONLY ahead commit is fresh passes:
  git -C "$SBASE" checkout -q -b hotfix/9.9.8 refs/remotes/origin/master 2>/dev/null
  echo fresh > "$SBASE/f"; git -C "$SBASE" add -A
  git -C "$SBASE" commit -q -m "PROJ-4: fresh own work" --no-verify 2>/dev/null
  assert "fresh-only ahead commits pass"                 "$G" pass "$(stow_payload 'git commit -m "PROJ-5: more"')"
  # upstream set -> passes even with the stale commit
  git -C "$SBASE" checkout -q hotfix/9.9.9 2>/dev/null
  git -C "$SBASE" update-ref refs/remotes/origin/hotfix/9.9.9 hotfix/9.9.9
  # --set-upstream-to refuses a hand-made tracking ref ("not a branch"); config directly
  git -C "$SBASE" config branch.hotfix/9.9.9.remote origin
  git -C "$SBASE" config branch.hotfix/9.9.9.merge refs/heads/hotfix/9.9.9
  assert "upstreamed branch passes"                      "$G" pass "$(stow_payload 'git commit -m "PROJ-6: post-push"')"
  # non-hotfix branch passes regardless
  git -C "$SBASE" checkout -q master 2>/dev/null
  assert "non-hotfix branch passes"                      "$G" pass "$(stow_payload 'git commit -m "PROJ-7: x"')"
  rm -rf "$SBASE"
else
  skip_gate "$G"
fi

# ------------------------------------------------------- ticket-worked-while-open-gate.sh
# Also network-dependent. The exemptions below are resolved BEFORE any curl, so they are
# assertable offline -- and they are the two that would break the harness if they regressed:
# the Regressions ticket is deliberately parked at Open, so losing its exemption would make
# every regression fix trip the gate by design.
G=ticket-worked-while-open-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  tp() { jq -n --arg c "$1" '{tool_name:"Bash",session_id:"eeeeeeee-1111-2222-3333-444444444444",cwd:"/tmp",tool_input:{command:$c}}'; }
  assert_block_silent() {
    local desc="$1" pl="$2" raw
    raw="$(printf '%s' "$pl" | bash "$hooks/$G" 2>/dev/null)"
    if [ -z "$raw" ]; then pass=$((pass+1)); else
      fail=$((fail+1)); printf 'FAIL  %-46s want=silent got=%s\n' "$desc" "$(printf '%s' "$raw" | head -c 50)"; fi
  }
  assert_block_silent "non-commit command is silent"  "$(tp 'git status')"
  assert_block_silent "commit outside a repo silent"  "$(tp 'git -C /tmp/definitely-not-a-repo commit -m x')"
  # 2026-09-26: `git -C "$W" commit` fell back to the cwd (the MAIN clone) and reported another
  # worktree's HEAD ticket as "just committed". An unexpandable path must remind generically,
  # before any Jira call, and never name a ticket.
  twog_raw="$(tp 'W=C:/x/.worktrees/search-develop; git -C "$W" commit -m "PROJ-1: x"' | bash "$hooks/$G" 2>/dev/null)"
  if printf '%s' "$twog_raw" | grep -q 'shell variable' && ! printf '%s' "$twog_raw" | grep -q 'PROJ-[0-9]'; then pass=$((pass+1)); else
    fail=$((fail+1)); printf 'FAIL  %-46s got=%s\n' "unresolved path reminds without a ticket" "$(printf '%s' "$twog_raw" | head -c 80)"; fi
else
  skip_gate "$G"
fi

# ------------------------------------------------------- shared-input-contract-nudge.sh
# Offline: a throwaway repo, state in a throwaway CLAUDE_STATE_DIR. The real-incident replay
# (a9a7890b / c26fcee3 / 0dd5527f fire, a Lambda-only commit is silent) was run by hand against
# the search repo when this hook was added -- see the hook header.
G=shared-input-contract-nudge.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  SIR="$(cgmktemp -d "/tmp/gatefix-sicn.XXXXXX")"; SIS="$(cgmktemp -d "/tmp/gatefix-sicn-st.XXXXXX")"
  git -C "$SIR" init -q && git -C "$SIR" config user.email t@t && git -C "$SIR" config user.name t
  sicn_commit() { # <relpath> <added line> <subject> [body]
    mkdir -p "$SIR/$(dirname "$1")"; printf '%s\n' "$2" >> "$SIR/$1"
    git -C "$SIR" add -A >/dev/null && git -C "$SIR" commit -q -m "$3" ${4:+-m "$4"}
  }
  sicn_assert() { # <desc> <silent|regex> [command]
    local raw; raw="$(jq -n --arg c "${3:-git -C $SIR commit -m x}" --arg d "$SIR" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' \
      | CLAUDE_STATE_DIR="$SIS" bash "$hooks/$G" 2>/dev/null)"
    if [ "$2" = silent ]; then
      if [ -z "$raw" ]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL  %-46s want=silent got=%s\n' "$1" "$(printf '%s' "$raw" | head -c 60)"; fi
    elif printf '%s' "$raw" | jq -r '.reason // empty' 2>/dev/null | grep -qE "$2"; then pass=$((pass+1)); else
      fail=$((fail+1)); printf 'FAIL  %-46s want=/%s/ got=%s\n' "$1" "$2" "$(printf '%s' "$raw" | head -c 60)"; fi
  }
  sicn_assert "non-commit command is silent"                     silent "git -C $SIR status"
  sicn_commit YourCompany.Product.Search.Shared/Builders/Select/Mask.cs 'var parts = sql.Split(",");' 'PROJ-1: mask'
  sicn_assert "shared builder gains a Split -> producer checklist" "INPUTS YOU DON'T OWN"
  sicn_commit YourCompany.Product.Search.Shared/Builders/Select/Mask2.cs 'var p = sql.Split(",");' 'PROJ-1: more'
  sicn_assert "second commit, same ticket -> once per ticket"    silent
  sicn_commit YourCompany.Product.Search.Lambda/Handler.cs 'var p = x.Split(",");' 'PROJ-2: lambda'
  sicn_assert "non-shared project -> silent"                     silent
  sicn_commit YourCompany.Product.Search.Shared/Builders/Select/Other.cs '_log.Information("a".Replace("b","c"));' 'PROJ-3: log'
  sicn_assert "logging-only text op -> silent"                   silent
  sicn_commit YourCompany.Product.Search.Lambda/Doc.cs '// note' 'PROJ-4: fix' 'Neither was caught earlier because the unit fixtures used the wrong alias.'
  sicn_assert "postmortem commit body -> record-the-lesson nudge" "postmortem"
  sicn_commit YourCompany.Product.Search.Lambda/Doc.cs '// more' 'PROJ-5: fix' 'The root cause was a stale cache.'
  sicn_assert "plain root-cause body is not a postmortem"        silent
  rm -rf "$SIR" "$SIS"
else
  skip_gate "$G"
fi

# -------------------------------------------------------- persisted-data-rewrite-nudge.sh
# DATA twin of the block above (PROJ-15274 -> 15835): a commit that rewrites persisted
# data -- a migration path, or a bulk-write op in added lines -- gets the six-check protocol,
# once per ticket; tests, comments and plain code stay silent.
G=persisted-data-rewrite-nudge.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  PDR="$(cgmktemp -d "/tmp/gatefix-pdrn.XXXXXX")"; PDS="$(cgmktemp -d "/tmp/gatefix-pdrn-st.XXXXXX")"
  git -C "$PDR" init -q && git -C "$PDR" config user.email t@t && git -C "$PDR" config user.name t
  pdrn_commit() { # <relpath> <added line> <subject>
    mkdir -p "$PDR/$(dirname "$1")"; printf '%s\n' "$2" >> "$PDR/$1"
    git -C "$PDR" add -A >/dev/null && git -C "$PDR" commit -q -m "$3"
  }
  pdrn_assert() { # <desc> <silent|regex> [command]
    local raw; raw="$(jq -n --arg c "${3:-git -C $PDR commit -m x}" --arg d "$PDR" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' \
      | CLAUDE_STATE_DIR="$PDS" bash "$hooks/$G" 2>/dev/null)"
    if [ "$2" = silent ]; then
      if [ -z "$raw" ]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL  %-46s want=silent got=%s\n' "$1" "$(printf '%s' "$raw" | head -c 60)"; fi
    elif printf '%s' "$raw" | jq -r '.reason // empty' 2>/dev/null | grep -qE "$2"; then pass=$((pass+1)); else
      fail=$((fail+1)); printf 'FAIL  %-46s want=/%s/ got=%s\n' "$1" "$2" "$(printf '%s' "$raw" | head -c 60)"; fi
  }
  pdrn_assert "non-commit command is silent"                      silent "git -C $PDR status"
  pdrn_commit YourCompany.Product.CohortReports.Migrations/_1_0_15_Foo.cs 'public class _1_0_15_Foo : IMigration' 'PROJ-1: migration'
  pdrn_assert "new migration file -> sequence checklist"          "SEQUENCE, not units"
  pdrn_commit YourCompany.Product.CohortReports.Migrations/_1_0_16_Bar.cs 'public class _1_0_16_Bar : IMigration' 'PROJ-1: another'
  pdrn_assert "second commit, same ticket -> once per ticket"     silent
  pdrn_commit YourCompany.Product.CohortReports.Migrations.Tests/FooTests.cs 'new _1_0_15_Foo().Up(db);' 'PROJ-2: tests'
  pdrn_assert "migration TEST file -> silent"                     silent
  pdrn_commit YourCompany.Product.Reports.Domain/Services/Fixer.cs 'collection.UpdateMany(filter, update);' 'PROJ-3: bulk fix'
  pdrn_assert "bulk UpdateMany in ordinary code -> fires"         "bulk write: .*UpdateMany"
  pdrn_commit YourCompany.Product.Reports.Domain/Services/Plain.cs 'var total = items.Count;' 'PROJ-4: plain'
  pdrn_assert "plain code -> silent"                              silent
  pdrn_commit YourCompany.Product.Reports.Domain/Services/Note.cs '// previously called collection.UpdateMany(...) here' 'PROJ-5: comment'
  pdrn_assert "bulk op named in a comment only -> silent"         silent
  pdrn_commit db/scripts/fix-orders.sql 'UPDATE orders SET status = 1 WHERE status IS NULL;' 'PROJ-6: sql'
  pdrn_assert "SQL UPDATE ... SET -> fires"                       "bulk write"
  rm -rf "$PDR" "$PDS"
else
  skip_gate "$G"
fi

# ---------------------------------------------------------------- repo-followup-nudge.sh
# Deferred per-repo follow-up: fires after a commit in a repo with an open ledger row, once per
# repo+branch; silent elsewhere; the row drops itself once HEAD's file carries the marker.
G=repo-followup-nudge.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  RFR="$(cgmktemp -d "/tmp/gatefix-rfn.XXXXXX")"; RFS="$(cgmktemp -d "/tmp/gatefix-rfn-st.XXXXXX")"
  git -C "$RFR" init -q -b master && git -C "$RFR" config user.email t@t && git -C "$RFR" config user.name t
  git -C "$RFR" remote add origin git@bitbucket.org:org/yourproduct-lib-x.git
  rfn_commit() { printf '%s\n' "$2" >> "$RFR/$1"; git -C "$RFR" add -A >/dev/null && git -C "$RFR" commit -q -m "$3"; }
  rfn_assert() { # <desc> <silent|regex> [command]
    local raw; raw="$(jq -n --arg c "${3:-git -C $RFR commit -m x}" --arg d "$RFR" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' \
      | CLAUDE_STATE_DIR="$RFS" bash "$hooks/$G" 2>/dev/null)"
    if [ "$2" = silent ]; then
      if [ -z "$raw" ]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL  %-46s want=silent got=%s\n' "$1" "$(printf '%s' "$raw" | head -c 60)"; fi
    elif printf '%s' "$raw" | jq -r '.reason // empty' 2>/dev/null | grep -qE "$2"; then pass=$((pass+1)); else
      fail=$((fail+1)); printf 'FAIL  %-46s want=/%s/ got=%s\n' "$1" "$2" "$(printf '%s' "$raw" | head -c 60)"; fi
  }
  rfn_commit bitbucket-pipelines.yml 'image: x' 'PROJ-1: start'
  rfn_assert "no ledger -> silent"                                silent
  mkdir -p "$RFS/tickets"
  # Ticket key as a %s arg: glued to a `\t` escape, the public scrub can't match it (`t` is a letter).
  printf 'yourproduct-other\t%s\tbitbucket-pipelines.yml:sbom-publish.sh\tAdd the SBOM step.\n' PROJ-9 > "$RFS/tickets/repo-followups"
  rfn_assert "row for another repo -> silent"                     silent
  printf 'yourproduct-lib-x\t%s\tbitbucket-pipelines.yml:sbom-publish.sh\tAdd the SBOM step.\n' PROJ-9 >> "$RFS/tickets/repo-followups"
  rfn_assert "non-commit command -> silent"                       silent "git -C $RFR status"
  rfn_commit src.cs 'class A {}' 'PROJ-2: real change'
  rfn_assert "commit in the repo -> names the follow-up"          "Owed follow-up for yourproduct-lib-x \(PROJ-9\): Add the SBOM step"
  rfn_commit src.cs 'class B {}' 'PROJ-2: more'
  rfn_assert "second commit, same branch -> silent"               silent
  git -C "$RFR" checkout -q -b feature/y
  rfn_commit src.cs 'class C {}' 'PROJ-3: other change'
  rfn_assert "new branch -> fires again"                          "branch feature/y"
  rfn_commit bitbucket-pipelines.yml '  - sbom-publish.sh' 'PROJ-9: sbom step'
  rfn_assert "marker on the branch -> silent"                     silent
  if grep -q '^yourproduct-lib-x	' "$RFS/tickets/repo-followups"; then pass=$((pass+1)); else
    fail=$((fail+1)); echo "FAIL  row dropped while only an unmerged branch has the marker"; fi
  git -C "$RFR" update-ref refs/remotes/origin/master HEAD   # the branch reached the default branch
  rfn_commit src.cs 'class D {}' 'PROJ-3: after merge'
  rfn_assert "marker on default branch -> silent"                 silent
  if grep -q '^yourproduct-lib-x	' "$RFS/tickets/repo-followups" || ! grep -q '^yourproduct-other	' "$RFS/tickets/repo-followups"; then
    fail=$((fail+1)); echo "FAIL  done row not dropped, or another repo's row lost"; else pass=$((pass+1)); fi
  rm -rf "$RFR" "$RFS"
else
  skip_gate "$G"
fi

# --------------------------------------------------- prod-infra-change-ticket-reminder.sh
# Infra-only twin of the hook above -- same network dependency, same offline-assertable
# exemptions. The positive (block) path needs a live Jira token and a real session ticket
# file, so this block only pins what regresses without one: the read-only/non-aws/harness-
# epic silences. A live positive-path check was run by hand against PROJ-15313 (a
# real Open ticket) during the session that added this hook -- see AGENTS.md.
G=prod-infra-change-ticket-reminder.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  ip() { jq -n --arg c "$1" --arg sid "$2" '{tool_name:"Bash",session_id:$sid,tool_input:{command:$c}}'; }
  assert_silent() {
    local desc="$1" pl="$2" raw
    raw="$(printf '%s' "$pl" | bash "$hooks/$G" 2>/dev/null)"
    if [ -z "$raw" ]; then pass=$((pass+1)); else
      fail=$((fail+1)); printf 'FAIL  %-46s want=silent got=%s\n' "$desc" "$(printf '%s' "$raw" | head -c 50)"; fi
  }
  assert_silent "read-only describe-security-groups is silent" \
    "$(ip 'aws ec2 describe-security-groups --group-ids sg-x' 'cgcgcgcg-1111-2222-3333-444444444444')"
  assert_silent "non-aws command is silent (zero forks)" \
    "$(ip 'git status' 'cgcgcgcg-1111-2222-3333-444444444444')"
  assert_silent "no session ticket file -> silent" \
    "$(ip 'aws ec2 authorize-security-group-ingress --group-id sg-x --ip-permissions file://x.json' 'cgcgcgcg-nosuchsession-0000-000000000000')"
  # Harness-epic exemption, resolved before any curl -- assertable offline the same way
  # ticket-worked-while-open-gate.sh's exemptions are, above.
  SIDX="cgcgcgcg-epictest-0000-000000000000"
  TF="$HOME/.claude/.session-chatfiles/$SIDX.ticket"
  printf '<harnessEpicKey>' > "$TF" 2>/dev/null
  assert_silent "harness epic ticket is exempt" \
    "$(ip 'aws ec2 authorize-security-group-ingress --group-id sg-x --ip-permissions file://x.json' "$SIDX")"
  rm -f "$TF" 2>/dev/null
  # Staging/qa target is not a production mutation; stub curl answers "Open" so a miss blocks.
  SIDS="cgcgcgcg-stagetest-0000-000000000000"; TF="$HOME/.claude/.session-chatfiles/$SIDS.ticket"
  printf 'PROJ-1' > "$TF" 2>/dev/null
  CB="$(cgmktemp -d "/tmp/gatefix-curl.XXXXXX")"
  printf '#!/bin/sh\necho %s\n' "'{\"fields\":{\"status\":{\"name\":\"Open\"}}}'" > "$CB/curl"; chmod +x "$CB/curl"
  sraw() { printf '%s' "$(ip "$1" "$SIDS")" | PATH="$CB:$PATH" ATLASSIAN_API_TOKEN=x bash "$hooks/$G" 2>/dev/null; }
  if [ -z "$(sraw 'aws elbv2 set-security-groups --load-balancer-arn arn:x:loadbalancer/net/staging-v1-ama-rabbitmq/1 --security-groups sg-1')" ]; then pass=$((pass+1)); else
    fail=$((fail+1)); printf 'FAIL  %-46s want=silent\n' "staging-v1 target is not production"; fi
  if sraw 'aws elbv2 set-security-groups --load-balancer-arn arn:x:loadbalancer/net/production-v1-ama/1 --security-groups sg-1' | grep -q block; then pass=$((pass+1)); else
    fail=$((fail+1)); printf 'FAIL  %-46s want=block\n' "production-v1 target still reminds"; fi
  rm -f "$TF" 2>/dev/null
  # Terraform-first nudge (PROJ-15657): no ticket needed, context not block.
  tfn() { printf '%s' "$(ip "$1" 'cgcgcgcg-nosuchsession-0000-000000000000')" | bash "$hooks/$G" 2>/dev/null \
            | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null; }
  for c in 'aws cloudfront update-distribution --id E1 --if-match X --distribution-config file://c.json' \
           'aws wafv2 update-web-acl --scope CLOUDFRONT --name x' \
           'aws s3api put-bucket-lifecycle-configuration --bucket b --lifecycle-configuration file://l.json' \
           'aws logs put-delivery-source --name n --log-type ACCESS_LOGS --resource-arn a'; do
    if tfn "$c" | grep -q yourproduct-backbone; then pass=$((pass+1)); else
      fail=$((fail+1)); printf 'FAIL  %-46s want=tf-nudge cmd=%s\n' "terraform-first nudge fires" "$c"; fi
  done
  assert_silent "cloudfront create-invalidation is silent" \
    "$(ip 'aws cloudfront create-invalidation --distribution-id E1 --paths "/*"' 'cgcgcgcg-nosuchsession-0000-000000000000')"
  assert_silent "s3api put-object is silent" \
    "$(ip 'aws s3api put-object --bucket b --key k --body f' 'cgcgcgcg-nosuchsession-0000-000000000000')"
  assert_silent "cloudfront get-distribution-config is silent" \
    "$(ip 'aws cloudfront get-distribution-config --id E1' 'cgcgcgcg-nosuchsession-0000-000000000000')"
else
  skip_gate "$G"
fi


# --------------------------------------------------- worktree-branch-conflict-gate.sh
# Builds a REAL repo with a REAL linked worktree -- the constraint under test is git's own
# ("already used by worktree at ..."), so a mocked layout would prove nothing.
G=worktree-branch-conflict-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  WBASE="$(mktemp -d)"
  WMAIN="$WBASE/main"; mkdir -p "$WMAIN"
  git init -q "$WMAIN" 2>/dev/null
  git -C "$WMAIN" config user.email t@t.t; git -C "$WMAIN" config user.name t
  echo one > "$WMAIN/f"; git -C "$WMAIN" add -A
  git -C "$WMAIN" commit -q -m "PROJ-1: base" --no-verify 2>/dev/null
  git -C "$WMAIN" checkout -q -B master 2>/dev/null
  git -C "$WMAIN" branch -q held 2>/dev/null
  git -C "$WMAIN" branch -q free 2>/dev/null
  git -C "$WMAIN" worktree add -q "$WBASE/wt" held >/dev/null 2>&1

  wp() { jq -n --arg c "$1" --arg d "$2" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}'; }
  wreason() { printf '%s' "$1" | bash "$hooks/$G" 2>/dev/null \
                | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null; }
  wassert() { # desc want(WARN|SILENT) payload
    local desc="$1" want="$2" got; got="$(wreason "$3")"
    local g=SILENT; [ -n "$got" ] && g=WARN
    if [ "$g" = "$want" ]; then pass=$((pass+1)); else
      fail=$((fail+1)); printf 'FAIL  %-46s want=%-6s got=%s\n' "$desc" "$want" "$g"; fi
  }

  if [ -d "$WBASE/wt" ]; then
    wassert "checkout a worktree-held branch warns"  WARN   "$(wp "git -C $WMAIN checkout held" "$WMAIN")"
    wassert "switch to a worktree-held branch warns" WARN   "$(wp "git -C $WMAIN switch held" "$WMAIN")"
    wassert "branch -D a worktree-held branch warns" WARN   "$(wp "git -C $WMAIN branch -D held" "$WMAIN")"
    # The reason has to name the holder, or it is not actionable.
    if wreason "$(wp "git -C $WMAIN checkout held" "$WMAIN")" | grep -q "$(basename "$WBASE")"; then
      pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL  %-46s reason omits the holding path\n' "worktree warn names the holder"; fi

    # FALSE POSITIVES -- each of these would train an agent to ignore the warning.
    wassert "branch no worktree holds is silent"     SILENT "$(wp "git -C $WMAIN checkout free" "$WMAIN")"
    wassert "from the holding worktree is silent"    SILENT "$(wp "git -C $WBASE/wt checkout held" "$WBASE/wt")"
    wassert "creating a branch (-b) is silent"       SILENT "$(wp "git -C $WMAIN checkout -b brand/new" "$WMAIN")"
    wassert "switch -c is silent"                    SILENT "$(wp "git -C $WMAIN switch -c brand/new" "$WMAIN")"
    # `git -C <path>` contains a literal -C: an unanchored create-flag test collides with it
    # and silently skipped every real case until the test above caught it.
    wassert "checkout -- <path> is silent"           SILENT "$(wp "git -C $WMAIN checkout -- f" "$WMAIN")"
    wassert "checkout . is silent"                   SILENT "$(wp "git -C $WMAIN checkout ." "$WMAIN")"
    wassert "status is silent"                       SILENT "$(wp "git -C $WMAIN status" "$WMAIN")"
    wassert "non-git command naming it is silent"    SILENT "$(wp "echo held" "$WMAIN")"

    # The cross-session claim guard must stay quiet BETWEEN worktrees: they do not share a
    # working tree, so warning there would be a false positive. Currently true only as an
    # emergent property of keying claims on --show-toplevel; pin it.
    if [ -f "$hooks/cross-session-repo-claim.sh" ]; then
      WPROJ="$WBASE/projects/p"; mkdir -p "$WPROJ"
      WOTHER=ffffffff-1111-2222-3333-444444444444
      : > "$WPROJ/$WOTHER.jsonl"
      WTROOT="$(printf '%s' "$(git -C "$WBASE/wt" rev-parse --show-toplevel)" | tr '\134' '/' | tr '[:upper:]' '[:lower:]')"
      printf '%s\t%s\t%s\t%s\n' "$WTROOT" "$WOTHER" "held" "$(date +%s)" > "$WBASE/claims"
      xout="$(CLAIMS_FILE="$WBASE/claims" CLAUDE_PROJECTS_DIR="$WBASE/projects" \
        bash -c 'printf "%s" "$1" | bash "$2" 2>/dev/null' _ \
        "$(jq -n --arg c "git -C $WMAIN checkout free" --arg s aaaaaaaa-9999-9999-9999-999999999999 --arg d "$WMAIN" \
             '{tool_name:"Bash",session_id:$s,cwd:$d,tool_input:{command:$c}}')" \
        "$hooks/cross-session-repo-claim.sh" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""')"
      if [ -z "$xout" ]; then pass=$((pass+1)); else
        fail=$((fail+1)); printf 'FAIL  %-46s a claim on a WORKTREE must not warn in the main clone\n' "worktrees are separate claims"; fi
    fi
  else
    skip=$((skip+1)); printf 'SKIP  %s: worktree add unavailable\n' "$G"
  fi
  git -C "$WMAIN" worktree remove --force "$WBASE/wt" >/dev/null 2>&1 || true
  rm -rf "$WBASE" 2>/dev/null || true
else
  skip_gate "$G"
fi

# ---------------------------------------------------------------- gmail-reply-thread-reminder
# Fires only on a REPLY draft. The silent cases matter as much as the blocking one: nagging
# every new-thread draft would train the nudge away, and an empty-string replyToMessageId
# must not read as a reply.
G=gmail-reply-thread-reminder.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  gd() { jq -n --arg t "${2:-mcp__claude_ai_Gmail__create_draft}" --arg r "$1" \
    'if $r == "" then {tool_name:$t,tool_input:{to:["x@y.com"],body:"hi"}}
     else {tool_name:$t,tool_input:{to:["x@y.com"],body:"hi",replyToMessageId:$r}} end'; }
  assert_block "reply draft nudges a thread check" "$G" block "$(gd 1a00ec570b4a4a33)"
  assert_block "new-thread draft stays silent"     "$G" pass  "$(gd '')"
  assert_block "an unrelated Gmail tool"           "$G" pass  "$(gd 1a00ec570b4a4a33 mcp__claude_ai_Gmail__list_drafts)"
  # update_draft DETACHES a reply draft (2026-08-19, again 2026-08-20). The payload can't
  # say whether the target is a reply, so this one nudges unconditionally -- asserted with
  # NO replyToMessageId precisely to pin that "always" and stop a future reader from
  # "fixing" it into a reply-only nudge the way create_draft's is.
  ud() { jq -n --arg d "$1" '{tool_name:"mcp__claude_ai_Gmail__update_draft",tool_input:{draftId:$d,body:"hi"}}'; }
  assert_block "update_draft always nudges"        "$G" block "$(ud r-7686723745624014601)"
else
  skip_gate "$G"
fi

# ------------------------------------------------------------ self-checkable-ask-reminder
# A Stop hook, so it takes a transcript path rather than a tool payload, and it "fires" by
# APPENDING to harness-gaps.md -- assert_block can't see that, so this block diffs the file
# and restores it. Precision is the whole point: the ask-phrase alone must stay silent, or
# the nudge gets trained away. Cases pin both halves of the co-occurrence rule.
G=self-checkable-ask-reminder.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  SCD="$(cgmktemp -d "/tmp/selfcheck.$PROBE_TAG.XXXXXX")"
  # HOME override, NOT an edit of the real file. The first version of this block appended to
  # the live ~/.claude/harness-gaps.md and undid it with `sed -i '$d'` -- which REPLACED the
  # symlink with a regular file (sed writes a new inode and renames over the link), detaching
  # ~/.claude from the repo so a concurrent session's appends stopped arriving and a probe line
  # got auto-committed. Exactly what CLAUDE.md's "never sed -i a ~/.claude path" and
  # inplace-edit-gate.sh exist to prevent, tripped from inside the test suite where no gate
  # watches. Pointing HOME at a throwaway dir means the hook writes to a disposable file and
  # the real one is never opened, let alone rewritten.
  mkdir -p "$SCD/home/.claude"
  : > "$SCD/home/.claude/harness-gaps.md"
  sc() { # <label> <flag|silent> <reply text>
    jq -cn --arg t "$3" '{type:"assistant",message:{content:[{type:"text",text:$t}]}}' > "$SCD/t.jsonl"
    : > "$SCD/home/.claude/harness-gaps.md"
    jq -cn --arg p "$SCD/t.jsonl" '{session_id:"probe-0000",transcript_path:$p}' |
      HOME="$SCD/home" bash "$hooks/$G" >/dev/null 2>&1
    if [ -s "$SCD/home/.claude/harness-gaps.md" ]; then g=flag; else g=silent; fi
    if [ "$g" = "$2" ]; then pass=$((pass+1))
    else fail=$((fail+1)); printf 'FAIL  %-46s want=%-6s got=%s\n' "$1" "$2" "$g"; fi
  }
  sc "ask + octopus, same paragraph" flag \
    "Worth checking the Octopus yourproduct-blog-domain value, since it decides whether this is open."
  sc "ask phrase with no system named" silent \
    "Worth checking with Dan whether he still wants the notice sent this week."
  sc "backticked quote of the rule" silent \
    'The hook fires on `worth checking` when an Octopus or Graylog keyword shares the paragraph.'
  rm -rf "$SCD"
else
  skip_gate "$G"
fi

# ------------------------------------------------------------ on-stop.sh auto_commit_push
# Claude-Config auto-commit. A Stop job, not a gate: runs the function itself against a
# throwaway ~/.claude clone + bare remote under an overridden HOME, in a subshell -- the real
# ~/.claude is never opened. Pins what left Claude-Config six weeks unpushed (2026-10-28):
# scoped to a cwd under ~/.claude, CLI-made settings.json changes dropped. Plus the shared
# index: another session's staged file must not ride along.
G=on-stop.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  ACD="$(cgmktemp -d "/tmp/autocommit.$PROBE_TAG.XXXXXX")"
  acp_res="$( (
    export HOME="$ACD/home"; R="$HOME/.claude"; mkdir -p "$HOME"
    git init -q --bare -b main "$ACD/remote.git"
    git clone -q "$ACD/remote.git" "$R" 2>/dev/null
    git -C "$R" config user.name t; git -C "$R" config user.email t@t
    printf 'hooks/\n' > "$R/.gitignore"; printf '{"a":1}\n' > "$R/settings.json"; printf 'n\n' > "$R/notes.md"
    git -C "$R" add -A 2>/dev/null; git -C "$R" commit -q -m init; git -C "$R" push -q -u origin main 2>/dev/null
    mkdir -p "$R/hooks"
    eval "$(sed -n '/^_safe_push_pull_retry() {/,/^}/p; /^auto_commit_push() {/,/^}/p' "$hooks/$G")"
    sid="probe123-0000"; tr_path="$ACD/t.jsonl"; root="$(git -C "$R" rev-parse --show-toplevel)"
    w() { jq -cn --arg p "$(cygpath -w "$1")" '{type:"assistant",message:{content:[{type:"tool_use",name:"Write",input:{file_path:$p}}]}}'; }
    head_files() { git -C "$R" diff-tree --no-commit-id --name-only -r HEAD | sort | tr '\n' ' '; }
    pushed() { local i; for i in $(seq 1 30); do [ "$(git -C "$ACD/remote.git" rev-parse main)" = "$(git -C "$R" rev-parse HEAD)" ] && return 0; sleep 0.5; done; return 1; }
    r() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fi; }
    # CLI-made settings.json edit (no Write for it), own new note, foreign untracked + foreign
    # STAGED new file, own write into an ignored dir, a path outside ~/.claude.
    printf '{"a":2}\n' > "$R/settings.json"; printf 'm\n' > "$R/mine.md"; printf 't\n' > "$R/foreign.md"
    printf 's\n' > "$R/staged.md"; git -C "$R" add staged.md 2>/dev/null; printf 'x\n' > "$R/hooks/x.sh"
    { w "$root/mine.md"; w "$root/hooks/x.sh"; w "C:/elsewhere/y.md"; } > "$tr_path"
    auto_commit_push
    r "commits CLI settings.json + own new file only" '[ "$(head_files)" = "mine.md settings.json " ]'
    r "another session's staged file stays staged"   'git -C "$R" status --porcelain | grep -q "^A  staged.md"'
    r "commit is pushed (detached)"                   pushed
    printf '{"a":' > "$R/settings.json"; printf 'more\n' >> "$R/notes.md"; : > "$tr_path"
    auto_commit_push
    r "half-written JSON skipped, tracked note goes"  '[ "$(head_files)" = "notes.md " ] && pushed'
    printf '{"a":3}\n' > "$R/settings.json"; auto_commit_push; pushed
    h="$(git -C "$R" rev-parse HEAD)"; auto_commit_push
    r "quiet stop makes no commit"                    '[ "$(git -C "$R" rev-parse HEAD)" = "$h" ]'
    printf 'z\n' >> "$R/notes.md"; git -C "$R" commit -q -am stranded; auto_commit_push
    r "stranded local commit gets pushed"             pushed
  ) 2>/dev/null )"
  while IFS= read -r l; do
    case "$l" in
      PASS*) pass=$((pass+1)) ;;
      FAIL*) fail=$((fail+1)); printf 'FAIL  %-46s\n' "auto_commit_push: ${l#FAIL }" ;;
    esac
  done <<< "$acp_res"
  printf '%s\n' "$acp_res" | grep -q '^PASS' || { fail=$((fail+1)); printf 'FAIL  %-46s\n' "auto_commit_push: harness produced no result"; }
  rm -rf "$ACD"
else
  skip_gate "$G"
fi

# ------------------------------------------------------------ learned-lesson-check
# Stop hook: a reply paragraph that reports a learned lesson (correction/root-cause/fix phrase)
# about a harness-known system, with no Edit/Write under ~/.claude or the harness repo and no
# harness-gaps.md mention in the transcript tail -> decision:block. Pins: all three halves,
# the durable-write exemption, the backtick-quote exemption, and stop_hook_active silence.
G=learned-lesson-check.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  LLD="$(cgmktemp -d "/tmp/lesson.$PROBE_TAG.XXXXXX")"
  ll() { # <label> <block|silent> <reply text> [extra transcript line json]
    { [ -n "${4:-}" ] && printf '%s\n' "$4"; jq -cn --arg t "$3" '{type:"assistant",message:{content:[{type:"text",text:$t}]}}'; } > "$LLD/t.jsonl"
    out="$(jq -cn --arg p "$LLD/t.jsonl" '{session_id:"probe-0000",transcript_path:$p,stop_hook_active:false}' | bash "$hooks/$G" 2>/dev/null)"
    case "$out" in *'"decision":"block"'*) g=block ;; *) g=silent ;; esac
    if [ "$g" = "$2" ]; then pass=$((pass+1))
    else fail=$((fail+1)); printf 'FAIL  %-46s want=%-6s got=%s\n' "$1" "$2" "$g"; fi
  }
  ll "lesson + terraform, nothing written" block \
    "I was wrong about the lifecycle: in Octopus a minimum of 0 means every environment, so Terraform plans need QA first."
  ll "lesson phrase, no system named" silent \
    "Turned out that Dan had already approved the notice last week."
  ll "system named, no lesson phrase" silent \
    "The Octopus plan for CloudMap shows 2 to destroy, as expected."
  ll "backticked quote of the rule" silent \
    'The hook fires on `i was wrong` next to an Octopus or Terraform keyword.'
  ll "lesson but a skill was written this turn" silent \
    "The real cause was the Terraform 0.12 provider address in the state; I recorded it in the skill." \
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"C:/Users/x/Repos/AMA_APP/ama-claude-harness/skills/ama-terraform-backbone/SKILL.md"}}]}}'
  ll "lesson but harness-gaps.md appended this turn" silent \
    "The real cause was the Terraform 0.12 provider address in the state; logged a gap." \
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"echo x >> ~/.claude/harness-gaps.md"}}]}}'
  # stop_hook_active: the resumed turn must be silent or the hook loops.
  jq -cn --arg t "I was wrong about the Terraform provider address." '{type:"assistant",message:{content:[{type:"text",text:$t}]}}' > "$LLD/t.jsonl"
  out="$(jq -cn --arg p "$LLD/t.jsonl" '{session_id:"probe-0000",transcript_path:$p,stop_hook_active:true}' | bash "$hooks/$G" 2>/dev/null)"
  case "$out" in *'"decision":"block"'*) fail=$((fail+1)); echo "FAIL  stop_hook_active resumed turn        want=silent got=block" ;; *) pass=$((pass+1)) ;; esac
  rm -rf "$LLD"
else
  skip_gate "$G"
fi

# ------------------------------------------------------------ deferred-window-reminder-check
# Stop hook: a reply deferring work past the 9-5 ET window with no CronCreate in the recent
# transcript gets decision:block. Pins: deferral phrase + window word -> block; a CronCreate
# tool_use anywhere in the transcript tail -> silent; deferral phrase with no window named ->
# silent; stop_hook_active (the resumed turn) -> silent, or the hook would loop.
G=deferred-window-reminder-check.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  DWD="$(cgmktemp -d "/tmp/deferwin.$PROBE_TAG.XXXXXX")"
  dw() { # <label> <block|silent> <reply text> [with-cron] [stop-active]
    jq -cn --arg t "$3" '{type:"assistant",message:{content:[{type:"text",text:$t}]}}' > "$DWD/t.jsonl"
    if [ "${4:-}" = "with-cron" ]; then
      jq -cn '{type:"assistant",message:{content:[{type:"tool_use",name:"CronCreate",input:{cron:"4 23 7 10 *"}}]}}' >> "$DWD/t.jsonl"
    fi
    if [ "${5:-}" = "stop-active" ]; then active=true; else active=false; fi
    got="$(jq -cn --arg p "$DWD/t.jsonl" --argjson a "$active" '{session_id:"probe-0000",transcript_path:$p,stop_hook_active:$a}' |
      bash "$hooks/$G" 2>/dev/null | jq -r '.decision // "silent"' 2>/dev/null)"
    [ -n "$got" ] || got=silent
    if [ "$got" = "$2" ]; then pass=$((pass+1))
    else fail=$((fail+1)); printf 'FAIL  %-46s want=%-6s got=%s\n' "$1" "$2" "$got"; fi
  }
  dw "deferred past 17:00 ET, no reminder" block \
    "The replay and the anchor-loan query are owed after 17:00 ET today, once the Redshift window closes."
  dw "same deferral, CronCreate in transcript" silent \
    "The replay and the anchor-loan query are owed after 17:00 ET today, once the Redshift window closes." with-cron
  dw "deferral phrase, no window named" silent \
    "The follow-up is deferred until the client confirms the numbers."
  dw "resumed turn (stop_hook_active)" silent \
    "The replay is owed after 17:00 ET today." "" stop-active
  dw "reminder acknowledged in the paragraph" silent \
    "Reminder set for 23:04 SAST: the replay runs after 17:00 ET when the Redshift window reopens."
  jq -cn '{type:"assistant",message:{content:[{type:"tool_use",name:"Bash",input:{command:"bash ~/.claude/scripts/reminder.sh add s \"2026-10-07 23:04\" replay"}}]}}' > "$DWD/r.jsonl"
  jq -cn --arg t "The replay is owed after 17:00 ET today." '{type:"assistant",message:{content:[{type:"text",text:$t}]}}' >> "$DWD/r.jsonl"
  got="$(jq -cn --arg p "$DWD/r.jsonl" '{session_id:"probe-0000",transcript_path:$p,stop_hook_active:false}' | bash "$hooks/$G" 2>/dev/null | jq -r '.decision // "silent"' 2>/dev/null)"
  if [ "${got:-silent}" = silent ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL  durable reminder.sh add counts as set  got=$got"; fi
  # Slot wording (user rule 2026-10-14): next weekday 08:00 LOCAL, via the DEFER_NOW_LOCAL seam.
  jq -cn --arg t "The replay is owed after 17:00 ET today, once the Redshift window closes." '{type:"assistant",message:{content:[{type:"text",text:$t}]}}' > "$DWD/s.jsonl"
  slot() { # <label> <fixed local now> <expected slot>
    got="$(DEFER_NOW_LOCAL="$2" bash -c 'jq -cn --arg p "$1" "{session_id:\"probe-0000\",transcript_path:\$p,stop_hook_active:false}" | bash "$2"' _ "$DWD/s.jsonl" "$hooks/$G" 2>/dev/null | jq -r '.reason // ""' 2>/dev/null)"
    case "$got" in *"reminder at $3 local"*) pass=$((pass+1)) ;; *) fail=$((fail+1)); printf 'FAIL  %-46s want slot=%s\n' "$1" "$3" ;; esac
  }
  slot "Wed evening -> Thu 08:00"       "2026-10-14 22:00" "2026-10-15 08:00"
  slot "Wed 06:00 -> today 08:00"       "2026-10-14 06:00" "2026-10-14 08:00"
  slot "Fri evening -> Monday 08:00"    "2026-10-16 18:00" "2026-10-19 08:00"
  slot "Sat -> Monday 08:00"            "2026-10-17 10:00" "2026-10-19 08:00"
  rm -rf "$DWD"
else
  skip_gate "$G"
fi

# ------------------------------------------------------------ cron-oneshot-durable-gate
# One-shot CronCreate is session-only -> denied, redirected to scripts/reminder.sh. Recurring
# (/loop) and the "[session-only]" hatch pass.
G=cron-oneshot-durable-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  cc() { jq -cn --arg p "$1" --argjson r "$2" '{session_id:"probe-0000",tool_name:"CronCreate",tool_input:{cron:"4 8 14 10 *",prompt:$p,recurring:$r}}'; }
  assert "one-shot CronCreate denied"        "$G" deny "$(cc "check deploy" false)"
  assert "recurring CronCreate passes"       "$G" pass "$(cc "poll" true)"
  assert "[session-only] hatch passes"       "$G" pass "$(cc "[session-only] check" false)"
else
  skip_gate "$G"
fi

# ------------------------------------------------------------ backlog-pick-no-ask-gate
# A which-ticket AskUserQuestion during a backlog pick -> deny. Non-pick prompt, a judgment
# question with no competing keys, or a claim landed after the last listing -> pass. Reads
# `transcript_path` from the payload, so a synthesised transcript is enough.
G=backlog-pick-no-ask-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  BPD="$(cgmktemp -d "${TMPDIR:-/tmp}/gatefix-bpick.XXXXXX")"
  bpt() { # <file> <prompt-json> [cmd ...]  -- user prompt, then one Bash tool_use per cmd
    local f="$1"; jq -cn --argjson c "$2" '{type:"user",message:{content:$c}}' > "$f"; shift 2
    while [ $# -gt 0 ]; do
      jq -cn --arg c "$1" '{type:"assistant",message:{content:[{type:"tool_use",name:"Bash",input:{command:$c}}]}}' >> "$f"; shift
    done
  }
  bpq() { # <transcript> <question> <opt1> <opt2>
    jq -cn --arg t "$1" --arg q "$2" --arg a "$3" --arg b "$4" \
      '{session_id:"probe-0000",tool_name:"AskUserQuestion",transcript_path:$t,tool_input:{questions:[{question:$q,header:"Next",options:[{"label":$a,description:"x"},{"label":$b,description:"y"}]}]}}'; }  # "label" is a jq keyword
  WHICH='Which backlog task next?'; LIST='bash ~/.claude/skills/commit-ticket-jira/scripts/backlog-candidates.sh'
  CLAIM='bash "$HOME/.claude/hooks/set-session-ticket.sh" "C:/x" "349268b0 Chat.md" PROJ-15263'
  BPF="$BPD/pick.jsonl";  bpt "$BPF" '"Pick up the next backlog task"' "$LIST"
  assert "which-ticket question mid pick"             "$G" deny "$(bpq "$BPF" "$WHICH" "PROJ-15263 (Recommended)" "PROJ-14775 first")"
  assert "wording alone, keys only in question"       "$G" deny "$(bpq "$BPF" "$WHICH" "Top row" "Further down the page")"
  assert "two keys, neutral wording"                  "$G" deny "$(bpq "$BPF" "Start where?" "PROJ-15263" "PROJ-14775")"
  assert "judgment question, no competing keys"       "$G" pass "$(bpq "$BPF" "Derived twin: what do you want done with it?" "Separate ticket" "Fix now in this commit")"
  BPF="$BPD/array.jsonl"; bpt "$BPF" '[{"type":"text","text":"next backlog item"}]' "$LIST"
  assert "array-content prompt still a pick"          "$G" deny "$(bpq "$BPF" "$WHICH" "PROJ-1" "PROJ-2")"
  BPF="$BPD/other.jsonl"; bpt "$BPF" '"Fix the login bug on QA"' "$LIST"
  assert "non-pick prompt passes"                     "$G" pass "$(bpq "$BPF" "$WHICH" "PROJ-1" "PROJ-2")"
  BPF="$BPD/claimed.jsonl"; bpt "$BPF" '"Pick up the next backlog task"' "$LIST" "$CLAIM"
  assert "claim after listing = pick made, passes"    "$G" pass "$(bpq "$BPF" "$WHICH" "PROJ-1" "PROJ-2")"
  BPF="$BPD/relisted.jsonl"; bpt "$BPF" '"Pick up the next backlog task"' "$CLAIM" "$LIST"
  assert "re-listed after a claim = next pick, denied" "$G" deny "$(bpq "$BPF" "$WHICH" "PROJ-1" "PROJ-2")"
  assert "no transcript fails open"                   "$G" pass "$(bpq "$BPD/missing.jsonl" "$WHICH" "PROJ-1" "PROJ-2")"
  rm -rf "$BPD" 2>/dev/null || true
else
  skip_gate "$G"
fi

# ------------------------------------------------------------ octopus-deploy-watch-reminder
# Post-deploy nudge to start scripts/octopus-task-watch.sh. Context-only: a deploy POST whose
# response carries a ServerTasks id -> additionalContext naming that id; a GET, or a POST with
# no deploy evidence in the response -> silent.
G=octopus-deploy-watch-reminder.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  dwp() { jq -cn --arg c "$1" --arg r "$2" '{session_id:"probe-0000",tool_name:"Bash",tool_input:{command:$c},tool_response:$r}'; }
  got="$(dwp 'curl -sS -H "$H" -X POST -d "{}" "$O/api/Spaces-1/deployments"' 'Deployments-9 task=ServerTasks-4242' | bash "$hooks/$G" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // ""')"
  case "$got" in *"octopus-task-watch.sh ServerTasks-4242 probe-0000"*) pass=$((pass+1)) ;; *) fail=$((fail+1)); echo "FAIL  deploy POST with task id nudges watcher  got=${got:0:80}" ;; esac
  got="$(dwp 'curl -sS -H "$H" "$O/api/Spaces-1/deployments?take=5"' 'ServerTasks-1 ServerTasks-2' | bash "$hooks/$G" 2>/dev/null)"
  [ -z "$got" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL  deployments GET stays silent"; }
  got="$(dwp 'curl -sS -H "$H" -X POST -d "{}" "$O/api/Spaces-1/deployments"' 'denied by gate' | bash "$hooks/$G" 2>/dev/null)"
  [ -z "$got" ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL  POST with no deploy evidence stays silent"; }
else
  skip_gate "$G"
fi

# ------------------------------------------------------------ octopus-approval-watch-check
# Stop hook: a reply handing the user an Octopus approve/deploy link with no
# octopus-task-watch.sh call in the transcript -> block; watcher present, no ask verb,
# or stop_hook_active -> silent.
G=octopus-approval-watch-check.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  AWD="$(cgmktemp -d "/tmp/apprwatch.$PROBE_TAG.XXXXXX")"
  aw() { # <label> <block|silent> <reply text> [with-watch] [stop-active]
    # Watcher call FIRST, reply text last -- the real order. (Text-then-tool_use made the hook read
    # an empty final message, so "watcher present" passed for the wrong reason until 2026-10-15.)
    : > "$AWD/t.jsonl"
    [ "${4:-}" = "with-watch" ] && jq -cn '{type:"assistant",message:{content:[{type:"tool_use",name:"Bash",input:{command:"bash ~/.claude/scripts/octopus-task-watch.sh ServerTasks-77 s"}}]}}' >> "$AWD/t.jsonl"
    jq -cn --arg t "$3" '{type:"assistant",message:{content:[{type:"text",text:$t}]}}' >> "$AWD/t.jsonl"
    if [ "${5:-}" = "stop-active" ]; then active=true; else active=false; fi
    got="$(jq -cn --arg p "$AWD/t.jsonl" --argjson a "$active" '{session_id:"probe-0000",transcript_path:$p,stop_hook_active:$a}' | bash "$hooks/$G" 2>/dev/null | jq -r '.decision // "silent"' 2>/dev/null)"
    [ -n "$got" ] || got=silent
    if [ "$got" = "$2" ]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL  %-46s want=%-6s got=%s\n' "$1" "$2" "$got"; fi
  }
  # Approval-preflight stamps (scripts/octopus-approval-preflight.sh) live in a throwaway state dir.
  _aw_sd="${CLAUDE_STATE_DIR-}"; export CLAUDE_STATE_DIR="$AWD/state"; mkdir -p "$AWD/state/octopus/approval-preflight"
  awstamp() { printf '%s %s P\n' "$2" "${3:-$(date +%s)}" > "$AWD/state/octopus/approval-preflight/$1"; }
  awstamp ServerTasks-77 SAFE
  aw "approve link, no watcher" block "Please approve the plan: https://yourorg.octopus.app/app#/Spaces-1/tasks/ServerTasks-77"
  aw "release link + deploy ask, no watcher" block "Now deploy release 2.0.0.82-qa to Production: https://yourorg.octopus.app/app#/Spaces-1/projects/other-project-rp/deployments/releases/2.0.0.82-qa"
  aw "approve link, watcher in transcript" silent "Please approve the plan: https://yourorg.octopus.app/app#/Spaces-1/tasks/ServerTasks-77" with-watch
  aw "task link, no ask verb (a report)" silent "The task finished with a failure: https://yourorg.octopus.app/app#/Spaces-1/tasks/ServerTasks-77 -- the worker timed out."
  aw "resumed turn (stop_hook_active)" silent "Please approve: https://yourorg.octopus.app/app#/Spaces-1/tasks/ServerTasks-77" "" stop-active
  aw "approve link, never preflighted" block "Please approve: https://yourorg.octopus.app/app#/Spaces-1/tasks/ServerTasks-78" with-watch
  awstamp ServerTasks-79 SAFE 1000
  aw "approve link, preflight >3h old" block "Please approve: https://yourorg.octopus.app/app#/Spaces-1/tasks/ServerTasks-79" with-watch
  awstamp ServerTasks-80 STALE
  aw "approve link, STALE preflight" block "Please approve: https://yourorg.octopus.app/app#/Spaces-1/tasks/ServerTasks-80" with-watch
  awstamp ServerTasks-81 NETWORK
  aw "NETWORK verdict, change not explained" block "Please approve: https://yourorg.octopus.app/app#/Spaces-1/tasks/ServerTasks-81" with-watch
  aw "NETWORK verdict, security group explained" silent "Please approve: https://yourorg.octopus.app/app#/Spaces-1/tasks/ServerTasks-81 -- it swaps the NLB security group; export-api's SG is still admitted on 5672." with-watch
  awstamp ServerTasks-82 REVIEW
  aw "REVIEW verdict, fresh" silent "Please approve: https://yourorg.octopus.app/app#/Spaces-1/tasks/ServerTasks-82 (adds bucket logging)" with-watch
  CLAUDE_STATE_DIR="$_aw_sd"; export -n CLAUDE_STATE_DIR
  rm -rf "$AWD"
else
  skip_gate "$G"
fi

# ------------------------------------------------------------ terraform-plan-approval-review-check
# Stop hook: recommending a plan approval needs plan-review.sh run on that task first. Pins:
# affirmative ask + task id, no review -> block; review on the SAME id -> silent; review on a
# DIFFERENT id -> block; a warning ("never approve a plan that deletes") -> silent; local plan
# ask with a --file review -> silent; stop_hook_active -> silent.
G=terraform-plan-approval-review-check.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  PRD="$(cgmktemp -d "/tmp/planrev.$PROBE_TAG.XXXXXX")"
  pr() { # <label> <block|silent> <reply> [review-cmd] [stop-active]
    : > "$PRD/t.jsonl"
    [ -n "${4:-}" ] && jq -cn --arg c "$4" '{type:"assistant",message:{content:[{type:"tool_use",name:"Bash",input:{command:$c}}]}}' >> "$PRD/t.jsonl"
    jq -cn --arg t "$3" '{type:"assistant",message:{content:[{type:"text",text:$t}]}}' >> "$PRD/t.jsonl"
    if [ "${5:-}" = "stop-active" ]; then active=true; else active=false; fi
    got="$(jq -cn --arg p "$PRD/t.jsonl" --argjson a "$active" '{session_id:"probe-0000",transcript_path:$p,stop_hook_active:$a}' | bash "$hooks/$G" 2>/dev/null | jq -r '.decision // "silent"' 2>/dev/null)"
    [ -n "$got" ] || got=silent
    if [ "$got" = "$2" ]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL  %-46s want=%-6s got=%s\n' "$1" "$2" "$got"; fi
  }
  R=~/.claude/skills/ama-terraform-backbone/scripts/plan-review.sh
  pr "approve ask, no review" block "It is safe to approve the plan: ServerTasks-500"
  pr "approve ask, reviewed same id" silent "It is safe to approve the plan: ServerTasks-500" "bash $R ServerTasks-500 ServerTasks-499"
  pr "approve ask, reviewed other id" block "Please approve the plan for ServerTasks-500" "bash $R ServerTasks-501"
  pr "warning only, not an ask" silent "At the approval step, never approve a plan that deletes an aws_db_instance."
  pr "local plan ask, --file review" silent "Approve the Terraform plan by running apply yes." "bash $R --file /tmp/plan.txt"
  pr "resumed turn (stop_hook_active)" silent "Please approve the plan: ServerTasks-500" "" stop-active
  rm -rf "$PRD"
else
  skip_gate "$G"
fi

# ------------------------------------------------------------------- gmail-draft-sig-gate
# The typo deny is the load-bearing half: it must fire on the plain-text `body` too, not
# just htmlBody, since both ship in the same message. The sig-missing half is asserted
# create_draft/reply only, on purpose -- an update_draft patching a subject carries no sig
# by design, and forward's own text is commentary, not a new message; pinning both
# silences here stops a future reader from "helpfully" widening them. Also pinned:
# `data-smartmail` alone must NOT satisfy the anchor (Gmail strips it when saving a draft,
# so keying on it would false-negative every time).
G=gmail-draft-sig-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  SIG='<div dir="ltr" class="gmail_signature"><div>Your Name</div></div>'
  sg() { jq -n --arg t "${3:-mcp__claude_ai_Gmail__create_draft}" --arg b "$1" --arg h "$2" \
    '{tool_name:$t,tool_input:{to:["x@y.com"],body:$b,htmlBody:$h}}'; }
  # assert/decide (not assert_block/decide_block) -- this is a PreToolUse gate emitting
  # hookSpecificOutput.permissionDecision; decide_block only reads the legacy `.decision`
  # field and would score every deny here as a pass.
  assert "typo in htmlBody denied"             "$G" deny "$(sg "hi" "<div>hi</div>SturctureIt, 2nd floor")"
  assert "typo in plain body denied"           "$G" deny "$(sg "SturctureIt, 2nd floor" "$SIG")"
  assert "clean signed draft passes"           "$G" pass "$(sg "hi" "<div>hi</div>$SIG")"
  assert "unsigned create_draft asks"          "$G" ask  "$(sg "hi" "<div>hi</div>")"
  assert "data-smartmail alone not enough"     "$G" ask  "$(sg "hi" '<div data-smartmail="gmail_signature">x</div>')"
  assert "unsigned update_draft stays silent"  "$G" pass "$(sg "hi" "<div>hi</div>" mcp__claude_ai_Gmail__update_draft)"
  assert "typo still denied on update_draft"   "$G" deny "$(sg "hi" "SturctureIt" mcp__claude_ai_Gmail__update_draft)"
  assert "an unrelated Gmail tool"             "$G" pass "$(sg "SturctureIt" "SturctureIt" mcp__claude_ai_Gmail__list_drafts)"
  # Widened 2026-08-26 to reply/forward -- both are direct-send with no compose-UI auto-sig,
  # same as create_draft. forward has no `body`; its own text is `forwardText`.
  assert "unsigned reply asks (widened 2026-08-26)" "$G" ask  "$(sg "hi" "<div>hi</div>" mcp__claude_ai_Gmail__reply)"
  assert "signed reply passes"                 "$G" pass "$(sg "hi" "<div>hi</div>$SIG" mcp__claude_ai_Gmail__reply)"
  assert "typo in reply body denied"           "$G" deny "$(sg "SturctureIt, 2nd floor" "$SIG" mcp__claude_ai_Gmail__reply)"
  fg() { jq -n --arg ft "$1" --arg h "$2" \
    '{tool_name:"mcp__claude_ai_Gmail__forward",tool_input:{messageId:"m1",forwardText:$ft,htmlBody:$h}}'; }
  assert "unsigned forward stays silent (commentary, no sig owed)" "$G" pass "$(fg "FYI" "<div>FYI</div>")"
  assert "typo in forwardText still denied"    "$G" deny "$(fg "SturctureIt, 2nd floor" "<div>hi</div>")"
else
  skip_gate "$G"
fi

# --------------------------------------------------------------------- client-mail-cc-gate
# The self-address exemption is the half most likely to be "simplified" away by a later
# reader who sees a plain domain test and tidies it -- <secondaryEmail> IS an <one entry per line; this element only declares the type>
# address, and without the carve-out every note-to-self prompts. Both directions are pinned:
# own-address-alone passes, own-address-plus-a-colleague still asks. bcc is pinned too (a
# bcc'd colleague is still a recipient; ContactOne via bcc still satisfies the rule).
G=client-mail-cc-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  lz() { jq -n --arg t "${4:-mcp__claude_ai_Gmail__create_draft}" --argjson to "$1" --argjson cc "$2" --argjson bcc "$3" \
    '{tool_name:$t,tool_input:{to:$to,cc:$cc,bcc:$bcc,body:"hi"}}'; }
  assert "ClientCorp recipient without ContactOne asks"   "$G" ask  "$(lz '["<one entry per line; this element only declares the type>"]' '[]' '[]')"
  assert "ContactOne in cc satisfies the rule"      "$G" pass "$(lz '["<one entry per line; this element only declares the type>"]' '["<emailRecipients>"]' '[]')"
  # Own address from config, as the gate reads it -- a mixed-case literal here only half-scrubbed
  # in the public mirror and left the surname public (2026-10-28).
  own2="$(jq -r '.user.secondaryEmail // empty' "$HOME/.claude/harness-config.json" 2>/dev/null | tr -d '\r')"
  assert "own clientcorp2 address alone is exempt"   "$G" pass "$(lz "[\"$own2\"]" '[]' '[]')"
  assert "own clientcorp2 plus a colleague still asks" "$G" ask "$(lz "[\"$own2\",\"<one entry per line; this element only declares the type>\"]" '[]' '[]')"
  assert "no ClientCorp recipient stays silent"      "$G" pass "$(lz '["<one entry per line; this element only declares the type>"]' '[]' '[]')"
  assert "ClientCorp in bcc still asks"              "$G" ask  "$(lz '[]' '[]' '["<one entry per line; this element only declares the type>"]')"
  assert "ContactOne via bcc satisfies"             "$G" pass "$(lz '["<one entry per line; this element only declares the type>"]' '[]' '["<emailRecipients>"]')"
  assert "mixed-case address still matches"    "$G" ask  "$(lz '["some.colleague@ClientCorp.com"]' '[]' '[]')"
  assert "an unrelated Gmail tool"             "$G" pass "$(lz '["<one entry per line; this element only declares the type>"]' '[]' '[]' mcp__claude_ai_Gmail__list_drafts)"
  # Unresolvable-recipients branch (2026-08-26): reply/forward with NO to/cc/bcc at all --
  # e.g. replyAll:true -- carries no addresses in the payload; Gmail resolves them
  # server-side. Confirmed live: this used to pass silently, no ContactOne cc, on a real ClientCorp
  # reply-all. Must ask, unconditionally, before the <one entry per line; this element only declares the type> literal prefilter even runs.
  ru() { jq -n --arg t "$1" --argjson extra "${2:-{\}}" '{tool_name:$t,tool_input:({messageId:"m1"} + $extra)}'; }
  assert "reply, replyAll, no to/cc/bcc asks"   "$G" ask  "$(ru mcp__claude_ai_Gmail__reply '{"replyAll":true,"body":"hi"}')"
  assert "forward, no to at all asks"           "$G" ask  "$(ru mcp__claude_ai_Gmail__forward)"
  assert "reply with explicit to still checked" "$G" ask  "$(ru mcp__claude_ai_Gmail__reply '{"to":["<one entry per line; this element only declares the type>"],"body":"hi"}')"
  assert "reply, explicit internal-only to, silent" "$G" pass "$(ru mcp__claude_ai_Gmail__reply '{"to":["<one entry per line; this element only declares the type>"],"body":"hi"}')"
  assert "send_message, no to/cc/bcc, NOT in unresolvable branch, silent" \
    "$G" pass "$(ru mcp__claude_ai_Gmail__send_message '{"body":"hi"}')"
else
  skip_gate "$G"
fi

# ------------------------------------------------------------- prod-api-test-window-gate.sh
# The window bound itself is asserted with a FORCED clock, not with the real one -- a suite
# whose result flips with the wall clock is the flake this file already carries two entries
# about. A tiny `python` shim on PATH reports a chosen ET, which is also the only way to
# assert the outside-the-window PASS at all when the suite happens to run mid-afternoon.
G=prod-api-test-window-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  TRIG='curl -sS -u "me@x:$BITBUCKET_API_KEY" -X POST -H "Content-Type: application/json" "https://api.bitbucket.org/2.0/repositories/yourorg/<repository>-api-testing/pipelines/" -d '\''{"target":{"ref_type":"branch","ref_name":"master","type":"pipeline_ref_target","selector":{"type":"custom","pattern":"production"}}}'\'''
  # decide() runs the gate in this shell's env, so a shimmed PATH/env applies to it too.
  WSHIM="$(cgmktemp -d "/tmp/gatefix-win.XXXXXX")"
  clock() { # <HH> <iso-dow> -- rewrite the shim to report that ET reading
    printf '#!/usr/bin/env bash\nprintf "%%s %%s %%s:00 Day -0400 EDT\\n" "%s" "%s" "%s"\n' "$1" "$2" "$1" > "$WSHIM/python"
    chmod +x "$WSHIM/python"
  }
  OLDPATH="$PATH"; PATH="$WSHIM:$PATH"

  clock 10 3   # Wednesday 10:00 ET -- inside
  assert "production selector inside window"  "$G" deny "$(bash_payload "$TRIG")"
  assert "production_exports inside window"   "$G" deny "$(bash_payload "${TRIG//\"production\"/\"production_exports\"}")"
  assert "staging selector inside window"     "$G" pass "$(bash_payload "${TRIG//\"production\"/\"staging\"}")"
  assert "another repo's pipelines POST"       "$G" pass "$(bash_payload "${TRIG//<repository>-api-testing/product-service-search}")"
  assert "repo named but no pipelines POST"    "$G" pass "$(bash_payload 'cd api-testing && git status')"
  # Boundaries: 09:00 is blocked, 17:00 is open. Both ends were stated as 9am-5pm.
  clock 09 3; assert "09:00 ET is inside"      "$G" deny "$(bash_payload "$TRIG")"
  clock 17 3; assert "17:00 ET is open again"  "$G" pass "$(bash_payload "$TRIG")"
  clock 08 3; assert "08:00 ET is open"        "$G" pass "$(bash_payload "$TRIG")"
  clock 14 6; assert "Saturday is open"        "$G" pass "$(bash_payload "$TRIG")"
  clock 14 7; assert "Sunday is open"          "$G" pass "$(bash_payload "$TRIG")"
  # Heredoc-written trigger run in the same command must still deny inside the window
  # (2026-09-15 -- the `${command%%<<*}` idiom dropped everything after the first `<<`).
  clock 10 3; assert "heredoc-written trigger, run in same command" "$G" deny "$(bash_payload "cat > /tmp/t.sh <<'EOF'
$TRIG
EOF
bash /tmp/t.sh")"
  # The override is the user's, and must win even mid-window.
  clock 14 3
  # Exported, then unset -- an assignment PREFIX on a function call leaks into the shell in
  # POSIX mode, which would silently make every later case pass for the wrong reason.
  export AMA_ALLOW_PROD_API_TESTS=1
  assert "override env var wins"               "$G" pass "$(bash_payload "$TRIG")"
  unset AMA_ALLOW_PROD_API_TESTS
  # Fails CLOSED, unlike the network-dependent gates: no resolvable ET must not read as "go".
  printf '#!/usr/bin/env bash\nexit 1\n' > "$WSHIM/python"; chmod +x "$WSHIM/python"
  assert "unresolvable ET denies (fail closed)" "$G" deny "$(bash_payload "$TRIG")"
  # A zoneinfo lookup that quietly returned UTC is the original defect's signature. The shim
  # must report the real current UTC HH:MM, not a rounded hour: ET is a whole-hour offset from
  # UTC, so the MINUTES always match and only an exact HH:MM equality means "this is UTC".
  # A ":00" fixture never trips it unless the suite happens to run on the minute.
  UTCHM="$(date -u '+%H:%M')"
  printf '#!/usr/bin/env bash\nprintf "%%s 3 %%s Day -0400 EDT\\n" "%s" "%s"\n' "${UTCHM%%:*}" "$UTCHM" > "$WSHIM/python"
  chmod +x "$WSHIM/python"
  assert "ET equal to UTC denies"              "$G" deny "$(bash_payload "$TRIG")"

  PATH="$OLDPATH"
  rm -rf "$WSHIM" 2>/dev/null || true
  # A commit message DESCRIBING the hazard must not self-deny -- the trap
  # inplace-edit-gate.sh hit on its own first commit.
  assert "heredoc body describing the hazard"  "$G" pass "$(bash_payload "git commit -F - <<EOF
denies a <repository>-api-testing pipelines POST with \"pattern\":\"production\" inside 9am-5pm ET
EOF")"
else
  skip_gate "$G"
fi

# --------------------------------------------- octopus-prod-deploy-ticket-sweep-reminder.sh
# Had NO test block until 2026-09-09, and was silently broken the whole time: it matched only
# a curl POST carrying the "EnvironmentId":"<production>" JSON key, so every deploy issued
# through octo-deploy-release.sh (positional env arg, body written to a file, POST from inside
# the script) produced no nudge -- the mandatory Fix-Version sweep and mark-version-Released
# reminder simply never fired. Both forms pinned here so that cannot regress unnoticed.
G=octopus-prod-deploy-ticket-sweep-reminder.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  # Post-prod-deploy action ledger (2026-09-26): seam at a temp file so the live ledger is never read.
  PPA="$(cgmktemp -d "/tmp/gatefix-ppa.XXXXXX")"; export POST_PROD_ACTIONS_FILE="$PPA/actions"
  SPROD='curl -sS -X POST -H "Content-Type: application/json" -d "{\"ReleaseId\":\"Releases-1\",\"EnvironmentId\":\"<production>\"}" "https://yourorg.octopus.app/api/Spaces-1/deployments"'
  printf 'after release/999.0.0 reaches Production: redeploy the fixture hotfix to Staging\n' > "$POST_PROD_ACTIONS_FILE"
  assert_reason "owed follow-up surfaced on prod deploy" "$G" 'owed follow-ups.*release/999\.0\.0.*redeploy the fixture hotfix' "$(bash_payload "$SPROD")"
  : > "$POST_PROD_ACTIONS_FILE"
  assert_block "prod curl POST nudges"          "$G" block "$(bash_payload "$SPROD")"
  assert_block "prod wrapper script nudges"     "$G" block "$(bash_payload 'bash scratch/octo-deploy-release.sh Releases-20810 <production>')"
  assert_block "staging wrapper stays quiet"    "$G" pass  "$(bash_payload 'bash scratch/octo-deploy-release.sh Releases-20810 <staging>')"
  assert_block "prod deploy-lambda.sh nudges"   "$G" block "$(bash_payload 'bash ~/.claude/skills/ama-octopus-deploy/scripts/deploy-lambda.sh <production> production Releases-20810 cacheupdate-lambda')"
  assert_block "staging curl POST stays quiet"  "$G" pass  "$(bash_payload "${SPROD//<production>/<staging>}")"
  assert_block "word deployments in prose"      "$G" pass  "$(bash_payload 'echo "we will discuss deployments later"')"
  # Naming the wrapper is not invoking it (a read of the script denied a harness-gaps review, 2026-09-18).
  assert_block "reading the wrapper stays quiet" "$G" pass  "$(bash_payload 'sed -n 1,20p scratch/octo-deploy-release.sh')"
  assert_block "response shows no deployment"    "$G" pass  "$(resp_payload "$SPROD" 'permission denied')"
  assert_block "response carries the task id"    "$G" block "$(resp_payload "$SPROD" 'ServerTasks-99120')"
  # A commit message DESCRIBING a prod deploy must not read as one. Observed live: the commit
  # that broadened the detection above tripped this reminder on its own message body.
  assert_block "heredoc commit msg stays quiet" "$G" pass  "$(bash_payload "git commit -F- <<EOF
octo-deploy-release.sh posts <production> to api/Spaces-1/deployments
EOF")"
  # This reminder kept a THIRD private copy of the `.*`-joined deploy regex and was missed
  # when the two deploy gates' copies were fixed (2026-09-15). Now on the shared lib.
  assert_block "multi-line prod POST via heredoc+bash" "$G" block "$(bash_payload "cat > /tmp/octo.sh <<'EOF'
curl -sS -X POST \\
  -d \"{\\\"EnvironmentId\\\":\\\"<production>\\\"}\" \\
  \"https://yourorg.octopus.app/api/Spaces-1/deployments\"
EOF
bash /tmp/octo.sh")"
  unset POST_PROD_ACTIONS_FILE
else
  skip_gate "$G"
fi

# -------------------------------------------------------- prod-deploy-preflight-gate.sh
# User instruction 2026-10-12: a Production deploy needs a release-preflight.sh run (Staging
# API tests + error sweep) in the last 12h; a run with findings needs AMA_PREFLIGHT_ACK=1.
G=prod-deploy-preflight-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  PFT="$(cgmktemp -d "/tmp/gatefix-pf.XXXXXX")"; PFS="$PFT/stamp"; PFNOW=1800000000
  PPROD='bash scratch/octo-deploy-release.sh Releases-20810 <production>'
  pfa() { # <desc> <pass|deny> <payload>
    local got; got="$(printf '%s' "$3" | env PREFLIGHT_STAMP_FILE="$PFS" PREFLIGHT_NOW="$PFNOW" AMA_PREFLIGHT_ACK="${PFACK:-}" bash "$hooks/$G" 2>/dev/null)"
    case "$2:$got" in pass:|deny:*'"deny"'*) pass=$((pass+1)) ;; *) fail=$((fail+1)); printf 'FAIL  %-46s want=%s got=%s\n' "$1" "$2" "$(printf '%s' "$got" | head -c 160)" ;; esac; }
  : > "$PFS"
  pfa "prod deploy, no preflight"            deny "$(bash_payload "$PPROD")"
  pfa "staging deploy never needs one"       pass "$(bash_payload "${PPROD//<production>/<staging>}")"
  pfa "not a deploy"                         pass "$(bash_payload 'echo "deployments later"')"
  LPROD='bash ~/.claude/skills/ama-octopus-deploy/scripts/deploy-lambda.sh <production> production Releases-20810 cacheupdate-lambda'
  pfa "deploy-lambda.sh to prod, no preflight" deny "$(bash_payload "$LPROD")"
  pfa "deploy-lambda.sh to staging"            pass "$(bash_payload "${LPROD//<production> production/<staging> staging}")"
  printf '%s\t130.0.0\tPASS\tCLEAN\tnone\t/r\n' "$((PFNOW - 3600))" > "$PFS"
  pfa "fresh clean preflight passes"         pass "$(bash_payload "$PPROD")"
  printf '%s\t130.0.0\tPASS\tCLEAN\tnone\t/r\n' "$((PFNOW - 50000))" > "$PFS"
  pfa "stale (>12h) preflight denied"        deny "$(bash_payload "$PPROD")"
  printf '%s\t130.0.0\tFAIL\tISSUES\tAPI tests: failed\t/r\n' "$((PFNOW - 600))" > "$PFS"
  pfa "fresh preflight with findings denied" deny "$(bash_payload "$PPROD")"
  PFACK=1 pfa "user-acked findings pass"     pass "$(bash_payload "$PPROD")"
  rm -rf "$PFT"; unset -f pfa
else
  skip_gate "$G"
fi

# -------------------------------------------------------- prod-deploy-business-hours-gate.sh
# Same forced-clock shim as the api-test window gate above, and for the same reason: a suite
# whose result flips with the wall clock is the flake this file carries two entries about.
# The gate resolves ET through hooks/lib-et-now.sh, which shells out to `python`, so a PATH
# shim reaches it exactly as it does the inline copy.
#
# The WRAPPER-SCRIPT form is asserted alongside the curl form deliberately. The first version
# of this gate prefiltered on `*deployments*` only, and `octo-deploy-release.sh Releases-X
# <production>` contains neither that word nor a curl POST -- so it allowed a production
# deploy straight through, and only this shape caught it.
G=prod-deploy-business-hours-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  PROD='curl -sS -X POST -H "X-Octopus-ApiKey: $OCTOPUS_API_KEY" -H "Content-Type: application/json" -d "{\"ReleaseId\":\"Releases-1\",\"EnvironmentId\":\"<production>\"}" "https://yourorg.octopus.app/api/Spaces-1/deployments"'
  WRAP='bash scratch/octo-deploy-release.sh Releases-20810 <production>'
  DSHIM="$(cgmktemp -d "/tmp/gatefix-dwin.XXXXXX")"
  dclock() { # <HH> <iso-dow>
    printf '#!/usr/bin/env bash\nprintf "%%s %%s %%s:00 Day -0400 EDT\\n" "%s" "%s" "%s"\n' "$1" "$2" "$1" > "$DSHIM/python"
    chmod +x "$DSHIM/python"
  }
  DOLDPATH="$PATH"; PATH="$DSHIM:$PATH"

  dclock 10 3   # Wednesday 10:00 ET -- inside
  assert "prod curl POST inside window"        "$G" deny "$(bash_payload "$PROD")"
  assert "prod wrapper script inside window"   "$G" deny "$(bash_payload "$WRAP")"
  assert "staging wrapper inside window"       "$G" pass "$(bash_payload "${WRAP//<production>/<staging>}")"
  # deploy-lambda.sh, the live wrapper since 2026-10-14, is neither a curl POST nor named
  # octo-deploy*: it passed this gate in silence for a day. Pinned in both forms.
  LWRAP='bash ~/.claude/skills/ama-octopus-deploy/scripts/deploy-lambda.sh <production> production Releases-20810 cacheupdate-lambda'
  assert "prod deploy-lambda.sh inside window"    "$G" deny "$(bash_payload "$LWRAP")"
  assert "staging deploy-lambda.sh inside window" "$G" pass "$(bash_payload "${LWRAP//<production> production/<staging> staging}")"
  assert "qa curl POST inside window"          "$G" pass "$(bash_payload "${PROD//<production>/<qa>}")"
  assert "GET progression, not a deploy"       "$G" pass "$(bash_payload 'curl -sS "https://yourorg.octopus.app/api/Spaces-1/projects/Projects-54/progression"')"
  assert "word deployments in prose"           "$G" pass "$(bash_payload 'echo "we will discuss deployments later"')"
  # The 2026-09-15 bypass, pinned here as well as in the delete gate's section -- both gates
  # carried the same `.*`-joined matcher, and grep -P cannot span a newline, so an ordinary
  # multi-line curl written by a heredoc and run in the same command matched neither. That
  # shape is what the harness's own style gates push deploys into, so it is the common case.
  MLPROD='cat > /tmp/octo.sh <<'"'"'EOF'"'"'
RESP="$(curl -sS -H "$H" -X POST \
  -d "{\"ReleaseId\":\"Releases-1\",\"EnvironmentId\":\"<production>\"}" \
  "https://yourorg.octopus.app/api/Spaces-1/deployments")"
EOF
bash /tmp/octo.sh'
  assert "multi-line prod POST via heredoc+bash" "$G" deny "$(bash_payload "$MLPROD")"
  assert "same shape targeting staging"          "$G" pass "$(bash_payload "${MLPROD//<production>/<staging>}")"
  # And the counterweight: a heredoc body that only DESCRIBES the endpoint stays data.
  assert "commit message describing the endpoint" "$G" pass "$(bash_payload 'git commit -q -F - <<'"'"'EOF'"'"'
Document the gate

It matches a POST to api/Spaces-1/deployments with -X POST, <production>.
EOF')"
  # Opaque target fails CLOSED: an environment built from a variable or read from a file
  # cannot be cleared as non-production, and that is the one that must not slip.
  assert "opaque env fails closed"             "$G" deny "$(bash_payload 'curl -sS -X POST --data-binary "@body.json" "https://yourorg.octopus.app/api/Spaces-1/deployments"')"
  # Boundaries: 09:00 blocked, 17:00 open. Stated as 9am-5pm.
  dclock 09 3; assert "09:00 ET is inside"     "$G" deny "$(bash_payload "$PROD")"
  dclock 17 3; assert "17:00 ET is open again" "$G" pass "$(bash_payload "$PROD")"
  dclock 08 3; assert "08:00 ET is open"       "$G" pass "$(bash_payload "$PROD")"
  dclock 14 6; assert "Saturday is open"       "$G" pass "$(bash_payload "$PROD")"
  dclock 14 7; assert "Sunday is open"         "$G" pass "$(bash_payload "$PROD")"
  # The override is the user's, and must win mid-window. Exported then unset -- an assignment
  # PREFIX on a function call leaks into the shell in POSIX mode, which would silently make
  # every later case pass for the wrong reason.
  dclock 14 3
  export AMA_ALLOW_PROD_DEPLOY=1
  assert "override env var wins"               "$G" pass "$(bash_payload "$PROD")"
  assert "override wins for wrapper too"       "$G" pass "$(bash_payload "$WRAP")"
  unset AMA_ALLOW_PROD_DEPLOY
  # Must NOT share the api-test gate's hatch -- clearing one cannot clear the other.
  export AMA_ALLOW_PROD_API_TESTS=1
  assert "api-test hatch does NOT clear this"  "$G" deny "$(bash_payload "$PROD")"
  unset AMA_ALLOW_PROD_API_TESTS
  # Fails closed on an unreadable clock: "could not read the time" must not read as "go".
  printf '#!/usr/bin/env bash\nexit 1\n' > "$DSHIM/python"; chmod +x "$DSHIM/python"
  assert "unresolvable ET denies"              "$G" deny "$(bash_payload "$PROD")"
  # A zoneinfo lookup that quietly returned UTC is the original defect's signature. The shim
  # reports the real current UTC HH:MM: ET is a whole-hour offset from UTC, so the MINUTES
  # always match and only exact HH:MM equality means "this is UTC".
  DUTCHM="$(date -u '+%H:%M')"
  printf '#!/usr/bin/env bash\nprintf "%%s 3 %%s Day -0400 EDT\\n" "%s" "%s"\n' "${DUTCHM%%:*}" "$DUTCHM" > "$DSHIM/python"
  chmod +x "$DSHIM/python"
  assert "ET equal to UTC denies"              "$G" deny "$(bash_payload "$PROD")"

  PATH="$DOLDPATH"
  rm -rf "$DSHIM" 2>/dev/null || true
  # A commit message DESCRIBING the hazard must not self-deny -- the trap
  # inplace-edit-gate.sh hit on its own first commit.
  assert "heredoc body describing the hazard"  "$G" pass "$(bash_payload "git commit -F - <<EOF
denies a POST to api/Spaces-1/deployments naming <production> inside 9am-5pm ET
EOF")"
else
  skip_gate "$G"
fi

# ------------------------------------------------------------ config-key-parity-reminder.sh
# Both directions, via the hook's CFGPARITY_* test seam. The real tree is clean, so asserting
# only against it would prove nothing but "it stays quiet" -- a detector whose firing path is
# never exercised is this file's opening complaint.
G=config-key-parity-reminder.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  CBASE="$(cgmktemp -d "/tmp/gatefix-cfg.XXXXXX")"
  # FREEZE the live config into a fixture (2026-08-28). These cases used to hand the gate
  # $HOME/.claude/harness-config.json itself while `setup.md` below was a snapshot taken
  # once here -- so a concurrent session editing the live config mid-run made the two
  # disagree, missing_setup fired, and the two silence cases failed. Not theoretical:
  # observed live, config mtime 10:33:36 and the gate's own 10:36:36 both inside a run
  # spanning 10:25:35-11:06:31, and both cases pass in isolation against the same gate.
  # Same lesson as running-script-edit-gate.sh and this suite's own private-copy trick,
  # one level out: the suite must not read live, mutable state it does not own.
  # The basename MUST stay `harness-config.json`: the gate's first precondition is
  # `case "$file_path" in */harness-config.json)`, so a snapshot named anything else makes it
  # exit 0 on every case -- the two want=block cases fail and the two want=pass cases go green
  # for the wrong reason (silent because the gate never ran). Cost one red run to learn.
  REALLIVECFG="$HOME/.claude/harness-config.json"
  LIVECFG="$CBASE/harness-config.json"
  [ -f "$REALLIVECFG" ] && cp "$REALLIVECFG" "$LIVECFG" 2>/dev/null
  if [ -f "$LIVECFG" ] && [ -f "$harness/harness-config.example.json" ]; then
    cp "$harness/harness-config.example.json" "$CBASE/example.json"
    # setup shim names EVERY live top-level key, so missing_setup is silent and these cases
    # isolate the example<->live direction. The real harness-setup/SKILL.md legitimately lags
    # (`azure` block present live, not yet enumerated there) -- that's a real nudge, not a
    # test failure, so it must not leak into a case testing something else.
    jq -r 'keys[]' "$LIVECFG" 2>/dev/null > "$CBASE/setup.md"
    jq '. + {brandNewBlock:{someKey:"x"}}' "$LIVECFG" > "$CBASE/drift.json"
    jq '.releaseNotes.greetingNames += {"Someone.New@example.com":"New"}' "$LIVECFG" > "$CBASE/mapentry.json" 2>/dev/null \
      || cp "$LIVECFG" "$CBASE/mapentry.json"
    cfg() { jq -n --arg s "$1" --arg f "$2" \
      '{session_id:$s,tool_name:"Edit",tool_input:{file_path:$f,old_string:"a",new_string:"b"}}'; }
    export CFGPARITY_EXAMPLE="$CBASE/example.json" CFGPARITY_SETUP="$CBASE/setup.md"

    export CFGPARITY_LIVE="$CBASE/drift.json"
    assert_block "a new config key nudges"        "$G" block "$(cfg "$PROBE_SID-cfg1" "$LIVECFG")"
    assert_block "same session, same set deduped" "$G" pass  "$(cfg "$PROBE_SID-cfg1" "$LIVECFG")"
    # Entries inside a data-keyed map (emails) are DATA. Reporting each one listed a real
    # person's name per entry and buried the single line that mattered.
    # Example shimmed to the LIVE file for the two silence cases: since the reverse direction
    # exists, the real example legitimately differs from a live config that hasn't been
    # fetched lately, and that real drift is a nudge, not a test failure.
    export CFGPARITY_LIVE="$CBASE/mapentry.json" CFGPARITY_EXAMPLE="$LIVECFG"
    assert_block "extra map ENTRIES are not drift" "$G" pass "$(cfg "$PROBE_SID-cfg2" "$LIVECFG")"
    # Reverse direction (2026-08-28): a key only the EXAMPLE has must nudge too -- the check
    # was one-way and `aws.redshiftClusterId` sat missing from the live config unflagged.
    jq '. + {exampleOnlyBlock:{someKey:"x"}}' "$CBASE/example.json" > "$CBASE/exonly.json"
    export CFGPARITY_LIVE="$LIVECFG" CFGPARITY_EXAMPLE="$CBASE/exonly.json"
    assert_block "an example-only key nudges"     "$G" block "$(cfg "$PROBE_SID-cfg5" "$LIVECFG")"
    export CFGPARITY_EXAMPLE="$CBASE/example.json"
    # Identical files must be silent, i.e. no standing false nudge from the detector itself.
    export CFGPARITY_LIVE="$LIVECFG" CFGPARITY_EXAMPLE="$LIVECFG"
    assert_block "identical live/example raise nothing" "$G" pass "$(cfg "$PROBE_SID-cfg3" "$LIVECFG")"
    unset CFGPARITY_LIVE CFGPARITY_EXAMPLE CFGPARITY_SETUP
    assert_block "a non-config file is silent"     "$G" pass "$(cfg "$PROBE_SID-cfg4" "$HOME/.claude/settings.json")"
    rm -f "$HOME/.claude/.session-chatfiles/$PROBE_SID-cfg"*.cfgkeynudge 2>/dev/null || true
  else
    skip=$((skip+1)); printf 'SKIP  %s: no live/example harness-config.json\n' "$G"
  fi
  rm -rf "$CBASE" 2>/dev/null || true
fi

# ------------------------------------------------------------ vpn-dns-outage-logger.sh
# Reminds Claude to append another dated occurrence to the standing draft VPN-DNS IT ticket
# when a NETWORK command fails with a resolver error. Predicate is two-sided (DNS wording AND
# a network command) and deduped to one entry per calendar day, read off the ticket's own
# `### Example` headings. VPN_DNS_TICKET_FILE shims the ticket path -- mandatory, not
# cosmetic: the real ticket gains an entry dated today the first time this hook works, which
# would silently turn every case below into a "pass" and make the section prove nothing.
G=vpn-dns-outage-logger.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  VBASE="$(mktemp -d)"
  export VPN_DNS_TICKET_FILE="$VBASE/ticket.md"
  : > "$VPN_DNS_TICKET_FILE"
  DNSERR='ssh: Could not resolve hostname altssh.bitbucket.org: No address associated with hostname'
  vp() { jq -nc --arg c "$1" --arg r "$2" --arg s "$PROBE_SID-vpn" '{tool_name:"Bash",session_id:$s,tool_input:{command:$c},tool_response:$r}'; }
  # Same payload, PowerShell tool. Separate helper rather than a parameter on vp() -- the six
  # Bash cases below predate it and there is no reason to churn them.
  vpp() { jq -nc --arg c "$1" --arg r "$2" --arg s "$PROBE_SID-vpn" '{tool_name:"PowerShell",session_id:$s,tool_input:{command:$c},tool_response:$r}'; }
  # Outage state for every block case: the control name does NOT resolve (seam, no live lookup).
  export VPN_DNS_CONTROL_RESOLVES=0
  # Control resolving = not the fault (2026-09-08 false positives on deliberate negative probes).
  VPN_DNS_CONTROL_RESOLVES=1 assert_block "control name resolves -> not the fault" "$G" pass "$(vp 'git push origin master' "$DNSERR")"
  assert_block "nslookup at an explicit server is a probe" "$G" pass "$(vp 'nslookup hs-prod-elasticsearch-external.<tenant domain> 1.1.1.1' 'Non-existent domain')"
  assert_block "push hitting a resolver failure"        "$G" block "$(vp 'git push origin master' "$DNSERR")"
  assert_block "curl hitting a resolver failure"        "$G" block "$(vp 'curl -sS https://example.com/' 'curl: (6) Could not resolve host: example.com')"
  # Windows wording. Every case above is Unix (curl/git/ssh/glibc), and that was the whole
  # bug: this hook is wired to `Bash|PowerShell` but knew none of PowerShell's or .NET's
  # resolver wording, so it sat silent through a confirmed live outage on 2026-09-01 while
  # `Resolve-DnsName ... -Server 10.1.0.4` was returning NXDOMAIN by hand. The first case is
  # that exact command and output, `try {`-wrapped as it really was -- which also pins the
  # regex separator class, since `Resolve-DnsName` shares its line with `try {` and grep -E
  # anchors ^ per line.
  PSDNS='10.1.0.4 FAILED: api.anthropic.com : DNS name does not exist.'
  assert_block "the 2026-09-01 miss, verbatim"          "$G" block "$(vpp 'try { Resolve-DnsName api.anthropic.com -Server 10.1.0.4 -ErrorAction Stop } catch { $_.Exception.Message }' "$PSDNS")"
  assert_block "bare Resolve-DnsName NXDOMAIN"          "$G" block "$(vpp 'Resolve-DnsName api.anthropic.com -Server 10.1.0.4' "$PSDNS")"
  assert_block "Test-NetConnection (capture battery)"   "$G" block "$(vpp 'Test-NetConnection bitbucket.org -Port 22' 'WARNING: DNS name does not exist')"
  assert_block ".NET/dotnet resolver wording"           "$G" block "$(vp 'dotnet run --project src/Api' 'System.Net.Sockets.SocketException: No such host is known.')"
  # The new signatures must not weaken the two-sided predicate -- reading about an outage
  # still must not trigger a reminder to document one. Mirrors the Unix-wording case below.
  assert_block "grep OF the Windows error text"         "$G" pass  "$(vp 'grep -rn "DNS name does not exist" ./logs' "$PSDNS")"
  # Two-sided on purpose: the error wording alone must never be enough, or every `cat` of a
  # chat log, transcript or the ticket itself would fire once an outage is written up anywhere.
  assert_block "grep OF the error text is not an outage" "$G" pass "$(vp 'grep -rn "Could not resolve hostname" ./logs' "$DNSERR")"
  assert_block "network command, no DNS error"           "$G" pass "$(vp 'git push origin master' 'Everything up-to-date')"
  # Documenting the outage must not trigger a reminder to document the outage.
  assert_block "reading the ticket itself"               "$G" pass "$(vp "cat $HOME/.claude/IT-Ticket-VPN-DNS/IT-TICKET-VPN-DNS-bitbucket.md" "$DNSERR")"
  # The parent dir is mixed-case while the file is uppercase -- a command naming only the
  # dir must hit the guard's mixed-case pattern, not slip through to a false positive.
  assert_block "ls of the ticket's mixed-case dir"       "$G" pass "$(vp 'ls ~/.claude/IT-Ticket-VPN-DNS/' "$PSDNS")"
  assert_block "editing this hook itself"                "$G" pass "$(vp 'vim hooks/vpn-dns-outage-logger.sh' "$DNSERR")"
  # PostToolUseFailure (2026-10-05): a FAILING command is the normal outage shape and PostToolUse
  # never sees it. The text arrives in `.error`, and the output must take that event's shape.
  vpf() { jq -nc --arg c "$1" --arg r "$2" --arg s "$PROBE_SID-vpn" '{tool_name:"Bash",hook_event_name:"PostToolUseFailure",session_id:$s,tool_input:{command:$c},error:$r}'; }
  vpf_raw="$(vpf 'git push origin master' "$DNSERR" | bash "$hooks/$G" 2>/dev/null)"
  if printf '%s' "$vpf_raw" | jq -e '.hookSpecificOutput.hookEventName == "PostToolUseFailure" and (.hookSpecificOutput.additionalContext | test("CLASSIFY FIRST"))' >/dev/null 2>&1; then pass=$((pass+1)); else
    fail=$((fail+1)); printf 'FAIL  %-46s got=%s\n' "failure event: additionalContext shape" "$(printf '%s' "$vpf_raw" | head -c 80)"; fi
  assert_block "failure event, no DNS error"             "$G" pass "$(vpf 'git push origin master' 'fatal: not a git repository')"
  # Dedupe, both directions -- an entry dated today silences it, an entry from any other day
  # must not. Only the second half can catch a date comparison that matches too loosely.
  printf '### Example 9 - %s, probe\n' "$(date '+%Y-%m-%d')" > "$VPN_DNS_TICKET_FILE"
  assert_block "already logged today"                    "$G" pass  "$(vp 'git push origin master' "$DNSERR")"
  printf '### Example 9 - 2020-01-01, probe\n' > "$VPN_DNS_TICKET_FILE"
  assert_block "only an entry from another day"          "$G" block "$(vp 'git push origin master' "$DNSERR")"
  unset VPN_DNS_TICKET_FILE
  rm -rf "$VBASE" 2>/dev/null || true
else
  skip_gate "$G"
fi

# --------------------------------------------------------------------- slack-draft-existing-reminder
# Context-only like audience-policy-gate: asserts on additionalContext, never a permissionDecision.
# Ledger seam FOLLOWUPS_FILE points at a temp row so no live state is read.
G=slack-draft-existing-reminder.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  DBASE="$(cgmktemp -d 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/sdraft-$$")"
  mkdir -p "$DBASE" 2>/dev/null
  printf 'row-x\t2026-01-01\tdeferred-draft-unsent\tU0DRAFT001\t%s\tnote draft_id Dr0TEST\n' PROJ-1 > "$DBASE/ledger"  # key as an arg: a `\t` glued to it dodges the public scrub
  sd() { jq -n --arg t "$1" --arg c "$2" '{tool_name:$t,tool_input:{channel_id:$c,message:"x"}}' | FOLLOWUPS_FILE="$DBASE/ledger" bash "$hooks/$G" 2>/dev/null; }
  sd_ctx() { sd "$1" "$2" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null | tr -d '\r'; }
  sd_assert() { # <desc> <want substring | SILENT> <tool> <channel>
    local got; got="$(sd_ctx "$3" "$4")"
    if [ "$2" = SILENT ]; then
      if [ -z "$got" ]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL  %-46s want=SILENT got=spoke\n' "$1"; fi
    else
      case "$got" in *"$2"*) pass=$((pass+1)) ;; *) fail=$((fail+1)); printf 'FAIL  %-46s want=%s got=%s\n' "$1" "$2" "${got:-<silent>}" ;; esac
    fi
  }
  sd_assert "draft call: generic caveat"                 "silently drops yours" mcp__claude_ai_Slack__slack_send_message_draft U0OTHER001
  sd_assert "draft call: ledger row named"               "row: row-x"           mcp__claude_ai_Slack__slack_send_message_draft U0DRAFT001
  sd_assert "false positive: plain send stays silent"    SILENT                 mcp__claude_ai_Slack__slack_send_message U0DRAFT001
  if sd mcp__claude_ai_Slack__slack_send_message_draft U0DRAFT001 | jq -e '.hookSpecificOutput.permissionDecision' >/dev/null 2>&1; then
    fail=$((fail+1)); printf 'FAIL  %-46s emitted a permissionDecision\n' "no permissionDecision"
  else pass=$((pass+1)); fi
  rm -rf "$DBASE" 2>/dev/null || true
else
  skip_gate "$G"
fi

# --------------------------------------------------------------------- audience-policy-gate
# This gate INJECTS context and deliberately emits NO permissionDecision, so decide() reports
# it as "pass" whether it spoke or stayed silent -- the standard helper cannot tell the two
# apart. Hence assert_ctx, which asserts on the additionalContext text instead. It also pins
# the no-permissionDecision property directly: an "allow" here would risk overriding
# client-mail-cc-gate.sh's ask on these same tool calls.
#
# Fixture people, never the real config: the suite points AUDIENCE_CONFIG at a temp file so
# these cases assert the RULE (min level wins, cc is ignored) without putting real names or
# addresses in a tracked file.
G=audience-policy-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  ABASE="$(cgmktemp -d 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/audience-$$")"
  mkdir -p "$ABASE" 2>/dev/null
  ACFG="$ABASE/harness-config.json"
  jq -n '{audiences:{defaultLevel:"business",people:[
    {name:"Biz One",  emails:["biz.one@example.com"],  slackUserIds:[],             level:"business",  avoid:[],                  notes:"business level only"},
    {name:"Tech One", emails:["tech.one@example.com"], slackUserIds:["U0TECH0001"], level:"<level>", avoid:["deep app detail"], notes:"<level>, but keep it short"}
  ]}}' > "$ACFG"
  export AUDIENCE_CONFIG="$ACFG"

  # ctx <gate> <payload> -> the injected additionalContext, or "" when the gate stayed silent.
  ctx() {
    local raw
    raw="$(printf '%s' "$2" | bash "$hooks/$1" 2>/dev/null)"
    [ -n "$raw" ] || return 0
    printf '%s' "$raw" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null
  }
  # assert_ctx <desc> <gate> <substring, or the literal SILENT> <payload>
  assert_ctx() {
    local desc="$1" gate="$2" want="$3" payload="$4" got
    got="$(ctx "$gate" "$payload")"
    if [ "$want" = "SILENT" ]; then
      if [ -z "$got" ]; then pass=$((pass+1)); return; fi
      fail=$((fail+1)); printf 'FAIL  %-46s want=%-8s got=spoke\n' "$desc" "$want"; return
    fi
    case "$got" in
      *"$want"*) pass=$((pass+1)) ;;
      *) fail=$((fail+1)); printf 'FAIL  %-46s want=%-8s got=%s\n' "$desc" "$want" "${got:-<silent>}" ;;
    esac
  }

  am() { jq -n --arg t "${2:-mcp__claude_ai_Gmail__create_draft}" --argjson to "$1" --argjson cc "${3:-[]}" \
    '{tool_name:$t,tool_input:{to:$to,cc:$cc,body:"hi"}}'; }
  asl() { jq -n --arg t "${3:-mcp__claude_ai_Slack__slack_send_message}" --arg ch "$1" --arg m "$2" \
    '{tool_name:$t,tool_input:{channel_id:$ch,message:$m}}'; }

  assert_ctx "business addressee resolves BUSINESS"  "$G" "Resolved level: BUSINESS"  "$(am '["biz.one@example.com"]')"
  assert_ctx "<level> addressee resolves TECHNICAL" "$G" "Resolved level: TECHNICAL" "$(am '["tech.one@example.com"]')"
  # The floor rule: the user's "a combination of all of the above -> business level".
  assert_ctx "mixed audience drops to the floor"    "$G" "Resolved level: BUSINESS"  "$(am '["biz.one@example.com","tech.one@example.com"]')"
  assert_ctx "mixed audience says it is mixed"      "$G" "genuinely mixed audience"   "$(am '["biz.one@example.com","tech.one@example.com"]')"
  # cc must NOT count. A standing rule cc's one person on every client mail, so counting cc
  # would make every such mail "mixed" and mute the per-person rule for its real addressee.
  # Explicit user decision 2026-08-20 -- do not "simplify" this into reading cc too.
  assert_ctx "a business cc does NOT drag it down"  "$G" "Resolved level: TECHNICAL" "$(am '["tech.one@example.com"]' mcp__claude_ai_Gmail__create_draft '["biz.one@example.com"]')"
  assert_ctx "per-person avoid list is carried"     "$G" "Do NOT include: deep app detail" "$(am '["tech.one@example.com"]')"
  assert_ctx "unknown recipient stays silent"       "$G" SILENT "$(am '["stranger@vendor.example"]')"
  assert_ctx "an unrelated Gmail tool"              "$G" SILENT "$(am '["biz.one@example.com"]' mcp__claude_ai_Gmail__list_drafts)"
  assert_ctx "mixed-case address still matches"     "$G" "Resolved level: BUSINESS" "$(am '["BIZ.One@Example.com"]')"
  # Slack resolves a person only from a DM channel id or an @-mention -- slack_send_message
  # carries no recipient list, so a plain channel post legitimately resolves to nobody.
  assert_ctx "slack DM by user id resolves"         "$G" "Resolved level: TECHNICAL" "$(asl 'U0TECH0001' 'hi')"
  assert_ctx "slack channel post, no mention"       "$G" SILENT "$(asl '<amaSupportChannelId>' 'deploy done')"
  assert_ctx "slack channel post with an @-mention" "$G" "Resolved level: TECHNICAL" "$(asl '<amaSupportChannelId>' '<@U0TECH0001> can you look')"
  assert_ctx "slack scheduled message too"          "$G" "Resolved level: TECHNICAL" "$(asl 'U0TECH0001' 'hi' mcp__claude_ai_Slack__slack_schedule_message)"

  # --- free-text matcher (audience-policy-check.sh's prompt-time path) ------------------
  # Hyphen is a word char, not a boundary: a name inside a kebab slug (a memory filename,
  # a branch) is a reference to a thing, not an addressee -- false-positived 2026-08-31 on
  # a prompt naming a memory file whose slug embeds a configured name.
  jq '.audiences.people += [{name:"Kebab", emails:["kebab@example.com"], slackUserIds:[], level:"<level>", avoid:[], notes:""}]' \
    "$ACFG" > "$ACFG.tmp" && mv "$ACFG.tmp" "$ACFG"
  mtx() { AUDIENCE_CONFIG="$ACFG" bash -c 'source "$0"; if audience_match_text "$1"; then printf hit; else printf silent; fi' "$hooks/lib-audience-policy.sh" "$1"; }
  mt_case() { local desc="$1" want="$2" got; got="$(mtx "$3")"
    if [ "$got" = "$want" ]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL  %-46s want=%-8s got=%s\n' "$desc" "$want" "$got"; fi; }
  mt_case "plain name in free text matches"          hit    "message Kebab about the deploy"
  mt_case "name inside a kebab slug does NOT match"  silent "review the clientcorp-cc-kebab memory file before sending mail"
  mt_case "email substring still matches"            hit    "send it to kebab@example.com please"

  # The gate must never emit a permissionDecision: client-mail-cc-gate.sh ASKS on these same
  # tool calls, and an "allow" from here could override it.
  araw="$(printf '%s' "$(am '["biz.one@example.com"]')" | bash "$hooks/$G" 2>/dev/null)"
  if printf '%s' "$araw" | jq -e '.hookSpecificOutput | has("permissionDecision") | not' >/dev/null 2>&1; then
    pass=$((pass+1))
  else
    fail=$((fail+1)); printf 'FAIL  %-46s want=%-8s got=%s\n' "context-only, no permissionDecision" "none" "a decision"
  fi

  # Inert without config data, rather than guessing a policy.
  jq -n '{user:{email:"x@example.com"}}' > "$ACFG"
  assert_ctx "no audiences block in config"         "$G" SILENT "$(am '["biz.one@example.com"]')"

  unset AUDIENCE_CONFIG
  rm -rf "$ABASE" 2>/dev/null || true
else
  skip_gate "$G"
fi

# ------------------------------------------------------- hotfix-number-comms-gate.sh
G=hotfix-number-comms-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  hfslack() { jq -n --arg t "$1" --arg m "$2" '{tool_name:$t,tool_input:{message:$m}}'; }
  hfmail()  { jq -n --arg s "$1" --arg b "$2" \
    '{tool_name:"mcp__claude_ai_Gmail__create_draft",tool_input:{subject:$s,body:$b}}'; }
  S=mcp__claude_ai_Slack__slack_send_message

  assert "slack names a hotfix version"     "$G" deny "$(hfslack "$S" "shipping hotfix 2.19.1 now")"
  assert "slack names the hotfix branch"    "$G" deny "$(hfslack "$S" "merged hotfix/3.4.0 to master")"
  assert "HF abbreviation + version"        "$G" deny "$(hfslack "$S" "HF 2.19.1 is out")"
  assert "filler word between the two"      "$G" deny "$(hfslack "$S" "hotfix release v1.2.3 deployed")"
  # Case: the payload pre-filter must agree with the case-INSENSITIVE pattern it guards. A
  # `case` glob there failed open on both of these (confirmed live), and every other case
  # here uses lowercase `hotfix` or uppercase `HF`, so nothing else would catch it.
  assert "lowercase hf + version"           "$G" deny "$(hfslack "$S" "hf 2.19.1 out")"
  assert "mixed-case hotFix branch"         "$G" deny "$(hfslack "$S" "hotFix/3.4.0 merged")"
  assert "version in the mail SUBJECT"      "$G" deny "$(hfmail "hotfix 2.19.1 to prod" "done")"
  assert "version in the mail body"         "$G" deny "$(hfmail "Prod fix" "Went out as hotfix/2.19.1 last night.")"

  # The pass cases are the point: the word alone must never fire, or every hotfix message
  # would be blocked. A dotted version ADJACENT to the word is the whole trigger.
  assert "says hotfix, no number"           "$G" pass "$(hfslack "$S" "shipping a hotfix now")"
  assert "plural, bare count"               "$G" pass "$(hfslack "$S" "two hotfixes today")"
  # A full stop is not a separator -- otherwise a following sentence's number is a hit.
  assert "sentence break before a number"   "$G" pass "$(hfslack "$S" "Out as a hotfix. 3.5 hours to verify.")"
  assert "mail says hotfix, no number"      "$G" pass "$(hfmail "Prod fix" "Shipped as a hotfix.")"
  # Out of scope by tool: Jira/Confluence/commits legitimately carry the version.
  assert "same text, non-comms tool"        "$G" pass "$(jq -n --arg m "shipping hotfix 2.19.1 now" \
    '{tool_name:"Write",tool_input:{message:$m}}')"
  assert "same text, Jira comment tool"     "$G" pass "$(jq -n --arg b "deployed hotfix 2.19.1" \
    '{tool_name:"mcp__claude_ai_Atlassian__addCommentToJiraIssue",tool_input:{commentBody:$b}}')"
else
  skip_gate "$G"
fi

# ------------------------------------------------- ready-to-test-regression-reminder.sh
# The SILENT cases carry the weight: a nudge on the regression comment itself would fire
# forever, and one on every Jira comment would train the reminder away.
G=ready-to-test-regression-reminder.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  jc() { jq -n --arg b "$1" \
    '{tool_name:"mcp__claude_ai_Atlassian__addCommentToJiraIssue",tool_input:{issueIdOrKey:"PROJ-1",commentBody:$b}}'; }

  assert_block "testing-steps comment nudges"    "$G" block "$(jc "Testing steps: open the report, expected column populates.")"
  # Self-suppression -- this IS comment 2.
  assert_block "regression comment stays silent" "$G" pass  "$(jc "Regression steps: confirm report X still loads.")"
  assert_block "unrelated Jira comment silent"   "$G" pass  "$(jc "Deployed to staging, FYI.")"
  assert_block "unrelated Bash silent"           "$G" pass  "$(bash_payload 'git status --short')"
  # Status-aware (2026-09-07): the vocabulary filter matched any long comment, so Open/Blocked
  # tickets with no diff got the nudge 4 times in a day. `curl` shimmed on PATH + config seam
  # so lib-jira-status.sh sees a status offline; the hooks read config via HR_CONFIG_FILE.
  JSHIM="$(cgmktemp -d "/tmp/gatefix-jstat.XXXXXX")"
  jstat() { printf '#!/usr/bin/env bash\nprintf %%s '"'"'{"fields":{"status":{"name":"%s"}}}'"'"'\n' "$1" > "$JSHIM/curl"; chmod +x "$JSHIM/curl"; }
  printf '{"atlassian":{"cloudId":"h"},"user":{"email":"e"}}' > "$JSHIM/cfg.json"
  J_OLDPATH="$PATH"; PATH="$JSHIM:$PATH"; export ATLASSIAN_API_TOKEN="${ATLASSIAN_API_TOKEN:-probe}" HR_CONFIG_FILE="$JSHIM/cfg.json"
  jstat "Open";           assert_block "steps-like comment on Open ticket silent"  "$G" pass  "$(jc "Testing steps: open the report, expected column populates.")"
  jstat "Blocked";        assert_block "steps-like comment on Blocked silent"      "$G" pass  "$(jc "Verified the ECS desired counts, expected 2.")"
  jstat "Ready to Test";  assert_block "steps-like comment at Ready to Test nudges" "$G" block "$(jc "Testing steps: open the report, expected column populates.")"
  jstat "In Progress";    assert_block "steps-like comment In Progress nudges"     "$G" block "$(jc "Testing steps: open the report, expected column populates.")"
  # In Progress with a cwd repo holding NO commit for the key = an investigation ticket's
  # findings comment (PROJ-15414 fired three times, 2026-09-16) -> silent. A commit -> nudge.
  JR="$(cgmktemp -d "/tmp/gatefix-jrepo.XXXXXX")"
  git -C "$JR" init -q -b develop 2>/dev/null
  git -C "$JR" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "PROJ-2: other work" 2>/dev/null
  jcw() { jq -n --arg b "$1" --arg d "$JR" '{tool_name:"mcp__claude_ai_Atlassian__addCommentToJiraIssue",cwd:$d,tool_input:{issueIdOrKey:"PROJ-1",commentBody:$b}}'; }
  assert_block "In Progress, no commit for the key: silent" "$G" pass  "$(jcw "Findings: verified the ECS desired counts, expected 2.")"
  git -C "$JR" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "PROJ-1: the fix" 2>/dev/null
  assert_block "In Progress, key has a commit: nudges"      "$G" block "$(jcw "Testing steps: open the report, expected column populates.")"
  PATH="$J_OLDPATH"; unset HR_CONFIG_FILE
  # Filename in a READ is not an invocation -- `sed -n 1,40p .../jira-add-comment.sh` fired
  # this twice on 2026-08-26 under the old substring match.
  assert_block "reading jira-add-comment.sh silent" "$G" pass "$(bash_payload 'sed -n 1,40p "$HOME/.claude/skills/ama-jira-api/scripts/jira-add-comment.sh"')"
  # Same class from the QUOTING side (harness-gaps.md, 2026-09-14): the anchored regex accepts
  # an invocation inside a single-quoted span or a heredoc body, and with no payload file
  # present force=1 nudges anyway -- so a test fixture merely CONTAINING the invocation got
  # nudged. lib-command-text.sh strips both spans before the match.
  assert_block "quoted fixture invocation silent" "$G" pass \
    "$(bash_payload 'T='"'"'bash scripts/jira-add-comment.sh PROJ-1'"'"'; echo "$T"')"
  assert_block "heredoc fixture invocation silent" "$G" pass \
    "$(bash_payload 'cat > t.sh <<SH
bash scripts/jira-add-comment.sh PROJ-1
SH')"
  # Transition trigger: the hook asks Jira for the ticket's CURRENT status rather than
  # pattern-matching a transition id (`10171` is the Ready to Test STATUS id; real transition
  # ids here are 2-3 digits and per-ticket, so an id match would never have fired). Only the
  # negative is assertable offline -- a ticket that is not at Ready to Test, and every
  # token-less/offline run, must stay silent. The positive was verified live 2026-08-21
  # against PROJ-15317 (at Ready to Test -> nudge; the harness epic -> silent); pinning
  # it here would mean depending on some ticket staying in that status forever. Both cases
  # DO make a live 3s Jira GET -- not dead code: they pass either way because the read fails
  # open to silent, which is also why a token-less/offline run still goes green.
  assert_block "non-Ready-to-Test transition"    "$G" pass  "$(bash_payload 'bash "$HOME/.claude/skills/ama-jira-api/scripts/jira-transition-issue.sh" <harnessEpicKey> 261')"
  assert_block "MCP transition, harness epic"    "$G" pass  "$(jq -n \
    '{tool_name:"mcp__claude_ai_Atlassian__transitionJiraIssue",tool_input:{issueIdOrKey:"<harnessEpicKey>",transition:{id:"261"}}}')"
  # jira-add-comment.sh keeps its text in a fixed payload file, not on the command line. When
  # that file is gone the hook must still nudge -- a missed reminder is the costlier direction,
  # and the placeholder must bypass the looks-like-testing-steps filter to get there.
  # Asserted only when that file really is absent: it is a REUSED fixed path, so a leftover
  # payload from real work would legitimately drive the other branch and make this flaky.
  if [ ! -f "$(hstate tickets .jira-write-payload.json)" ]; then
    assert_block "script comment, no payload file" "$G" block "$(bash_payload 'bash "$HOME/.claude/skills/ama-jira-api/scripts/jira-add-comment.sh" PROJ-1')"
  else
    skip=$((skip+1)); printf 'SKIP  %s payload-absent case (a real .jira-write-payload.json exists)\n' "$G"
  fi
else
  skip_gate "$G"
fi

# ------------------------------------------------- regression-comment-brevity-gate.sh
# TWO TIERS on a LONG regression comment (2026-09-04): ASKS over 800 chars/6 step lines, DENIES
# over 1200/10 -- every real firing was 1.7x the limit or worse and an ask produced no self-
# correction, so the grey band keeps the ask and everything past it self-corrects. Checked at
# BOTH the payload Write and the jira-add-comment.sh call. Length or topic alone is fine -- a
# long testing-steps comment and a short regression one both pass.
G=regression-comment-brevity-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  jc2() { jq -n --arg b "$1" \
    '{tool_name:"mcp__claude_ai_Atlassian__addCommentToJiraIssue",tool_input:{issueIdOrKey:"PROJ-1",commentBody:$b}}'; }
  long_reg="Regression check for this change. $(printf 'Lorem ipsum dolor sit amet, consectetur adipiscing elit. %.0s' $(seq 1 16))"
  many_steps="$(printf 'Regression steps:\n- step %s: open report, confirm column populates\n' 1 2 3 4 5 6 7)"
  assert "long regression comment asks"       "$G" ask  "$(jc2 "$long_reg")"
  assert ">6 regression steps asks"           "$G" ask  "$(jc2 "$many_steps")"
  assert "short regression comment passes"    "$G" pass "$(jc2 "Regression: checked report X and Y; nothing found.")"
  assert "long non-regression comment passes" "$G" pass "$(jc2 "Testing steps. $(printf 'Open page, expect value. %.0s' $(seq 1 60))")"
  assert "unrelated Bash passes"              "$G" pass "$(bash_payload 'git status --short')"
  assert "reading jira-add-comment.sh passes" "$G" pass "$(bash_payload 'sed -n 1,40p "$HOME/.claude/skills/ama-jira-api/scripts/jira-add-comment.sh"')"
  # Tier boundaries. "regression " is 11 chars, so the pad is (target - 11).
  reg800="regression $(printf 'x%.0s' $(seq 1 789))"
  reg801="regression $(printf 'x%.0s' $(seq 1 790))"
  reg1200="regression $(printf 'x%.0s' $(seq 1 1189))"
  reg1201="regression $(printf 'x%.0s' $(seq 1 1190))"
  steps6="$(printf 'Regression steps:\n- step %s\n' 1 2 3 4 5 6)"
  steps10="$(printf 'Regression steps:\n- step %s\n' 1 2 3 4 5 6 7 8 9 10)"
  steps11="$(printf 'Regression steps:\n- step %s\n' 1 2 3 4 5 6 7 8 9 10 11)"
  assert "800 chars exactly passes"           "$G" pass "$(jc2 "$reg800")"
  assert "801 chars asks"                     "$G" ask  "$(jc2 "$reg801")"
  assert "1200 chars asks"                    "$G" ask  "$(jc2 "$reg1200")"
  assert "1201 chars denies"                  "$G" deny "$(jc2 "$reg1201")"
  assert "6 regression steps passes"          "$G" pass "$(jc2 "$steps6")"
  assert "10 regression steps asks"           "$G" ask  "$(jc2 "$steps10")"
  assert "11 regression steps denies"         "$G" deny "$(jc2 "$steps11")"
  # Highest tier wins: over the char hard limit AND in the steps ask band -> deny.
  assert "over chars, ask-band steps denies"  "$G" deny "$(jc2 "$(printf '%s\n%s' "$reg1201" "$steps10")")"
  # Script path reads the shared fixed payload file; only assertable when nobody's real payload
  # is sitting there (same guard as ready-to-test-regression-reminder.sh above).
  PF="$(hstate tickets .jira-write-payload.json)"
  if [ ! -f "$PF" ]; then
    jq -n --arg b "$long_reg" '{body:$b}' > "$PF"
    assert "script path, long regression payload asks" "$G" ask "$(bash_payload 'bash "$HOME/.claude/skills/ama-jira-api/scripts/jira-add-comment.sh" PROJ-1')"
    rm -f "$PF"
    assert "script path, no payload file passes"       "$G" pass "$(bash_payload 'bash "$HOME/.claude/skills/ama-jira-api/scripts/jira-add-comment.sh" PROJ-1')"
  else
    skip=$((skip+1)); printf 'SKIP  %s script-path cases (a real .jira-write-payload.json exists)\n' "$G"
  fi
  # Per-call payload path (2026-08-28): JIRA_PAYLOAD_FILE=<path> on the command wins over the
  # shared default, so this case never collides with anyone's real payload.
  PFX="$(hstate tickets ".jira-write-payload-$PROBE_SID.json")"
  jq -n --arg b "$long_reg" '{body:$b}' > "$PFX"
  assert "JIRA_PAYLOAD_FILE-prefixed path is read" "$G" ask "$(bash_payload "JIRA_PAYLOAD_FILE=\"$PFX\" bash \"\$HOME/.claude/skills/ama-jira-api/scripts/jira-add-comment.sh\" PROJ-1")"
  rm -f "$PFX"
  # Write of the payload -- the earlier check point (2026-09-04). These describe an intent, so
  # nothing is written to disk; $PFX only has to LOOK like a payload path. Write only, not Edit.
  assert "Write of over-1200 payload denies" "$G" deny "$(write_payload "$PFX" "$(jq -n --arg b "$reg1201" '{body:$b}')")"
  assert "Write of ask-band payload asks"    "$G" ask  "$(write_payload "$PFX" "$(jq -n --arg b "$long_reg" '{body:$b}')")"
  assert "Write of short payload passes"     "$G" pass "$(write_payload "$PFX" "$(jq -n --arg b 'Regression: checked X and Y; nothing found.' '{body:$b}')")"
  assert "Write of a non-payload json passes" "$G" pass "$(write_payload "$(hstate tickets other.json)" "$(jq -n --arg b "$reg1201" '{body:$b}')")"
  assert "Write of non-JSON content passes"  "$G" pass "$(write_payload "$PFX" "$reg1201")"
  assert "Edit of an over-limit payload passes" "$G" pass "$(jq -n --arg p "$PFX" --arg s "$reg1201" '{tool_name:"Edit",tool_input:{file_path:$p,old_string:"x",new_string:$s}}')"
  # FALSE POSITIVE (2026-09-08, PROJ-15376): the gate denied the very shape its own deny
  # message prescribes. For a NON-UI-testable ticket the rule is ONE "Regression: ..." line
  # INSIDE the testing-steps comment -- a body that mentions regression and is legitimately
  # long -- so a 2253-char testing-steps comment carrying that line was denied at the Write
  # step. Exempt shape: a single line-anchored "^Regression:" sentence <=400 chars in a body
  # more than twice its length. Note the existing cases above deliberately do NOT match it --
  # "Regression check for this change" and "Regression steps:" have no colon straight after
  # the word, so they are still measured.
  inline_reg="$(printf 'Deployed to QA and verified in dry-run mode.\n%s\nRegression: checked the service boots and serves normally; nothing found.\nOutstanding: enable Staging.\n' "$(printf 'A line of genuine testing detail about what was observed. %.0s' $(seq 1 30))")"
  assert "inline Regression line in long comment passes" "$G" pass "$(jc2 "$inline_reg")"
  assert "inline Regression line, Write path passes"     "$G" pass "$(write_payload "$PFX" "$(jq -n --arg b "$inline_reg" '{body:$b}')")"
  # Leak check: one "Regression:" line that is itself over the 400-char inline budget is NOT
  # the prescribed shape, so it must still be measured.
  fat_reg="$(printf 'Regression: %s\ntail %s\n' "$(printf 'narrative prose that does not belong inline. %.0s' $(seq 1 12))" "$(printf 'padding. %.0s' $(seq 1 40))")"
  assert "over-long single Regression: line still asks"  "$G" ask  "$(jc2 "$fat_reg")"
else
  skip_gate "$G"
fi

# ------------------------------------------------- ready-to-test-readiness-gate.sh
# A ticket may not reach Ready to Test without a description carrying the template headings,
# a testing-steps comment, and regression notes (user instruction 2026-09-11, after
# PROJ-15288 reached the UI tester with none of the three and he passed on it two days
# later). `curl` is shimmed on PATH and branches on the URL: /transitions answers with the
# destination status per id (an id alone is per-ticket and says nothing), anything else answers
# with the issue's description + comments. FAILS CLOSED -- the token-less and unreachable cases
# below assert a DENY, deliberately unlike every other Jira-touching hook here.
G=ready-to-test-readiness-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  RSHIM="$(cgmktemp -d "/tmp/gatefix-rtt.XXXXXX")"
  printf '{"atlassian":{"cloudId":"h"},"user":{"email":"e"}}' > "$RSHIM/cfg.json"
  # $1 destination status for id 31, $2 description (JSON scalar), $3 comments (JSON array)
  rshim() {
    { printf '#!/usr/bin/env bash\nurl="${@: -1}"\ncase "$url" in\n'
      printf '  */transitions) printf %%s %s ;;\n' "'{\"transitions\":[{\"id\":\"31\",\"to\":{\"name\":\"$1\"}},{\"id\":\"21\",\"to\":{\"name\":\"In Progress\"}}]}'"
      printf '  *) printf %%s %s ;;\nesac\n' "'{\"fields\":{\"description\":$2,\"comment\":{\"comments\":$3}}}'"
    } > "$RSHIM/curl"
    chmod +x "$RSHIM/curl"
  }
  R_OLDPATH="$PATH"; PATH="$RSHIM:$PATH"
  R_OLDTOK="${ATLASSIAN_API_TOKEN:-}"; export ATLASSIAN_API_TOKEN="${ATLASSIAN_API_TOKEN:-probe}" HR_CONFIG_FILE="$RSHIM/cfg.json"
  # Export the ledger seam BEFORE the first assert, not just around the ledger cases below:
  # every fail-closed deny writes a record, so the token-less and unreachable asserts filed a
  # fake PROJ-9999 into the REAL ledger until this moved up here (caught 2026-09-11 by
  # the leftover entry nudging the next prompt about a ticket that does not exist).
  export RTT_PENDING_FILE="$RSHIM/pending" RTT_PENDING_NUDGED="$RSHIM/nudged"
  rtt_call='bash "$HOME/.claude/skills/ama-jira-api/scripts/jira-transition-issue.sh" PROJ-9999 31'
  good_desc='"h2. How to reproduce\n# x\n\nh2. Acceptance criteria\n* y\n\nh2. How to test\n* z"'
  steps_c='[{"body":"Testing steps (QA)\n1. Open the report.\n2. Expected: it renders."}]'
  both_c='[{"body":"Testing steps (QA)\n1. Open the report.\n2. Expected: it renders."},{"body":"Regression: risk low - nothing downstream consumes it."}]'

  rshim "In Progress" "$good_desc" '[]'
  assert "non-RTT transition passes"            "$G" pass "$(bash_payload "$rtt_call")"
  rshim "Ready to Test" 'null' '[]'
  assert "RTT bare ticket denies"               "$G" deny "$(bash_payload "$rtt_call")"
  rshim "Ready to Test" "$good_desc" '[]'
  assert "RTT with description only denies"     "$G" deny "$(bash_payload "$rtt_call")"
  rshim "Ready to Test" "$good_desc" "$steps_c"
  assert "RTT without regression notes denies"  "$G" deny "$(bash_payload "$rtt_call")"
  assert "RTT via MCP tool denies too"          "$G" deny "$(jq -n '{tool_name:"mcp__claude_ai_Atlassian__transitionJiraIssue",tool_input:{issueIdOrKey:"PROJ-9999",transition:{id:"31"}}}')"
  rshim "Ready to Test" 'null' "$both_c"
  assert "RTT without a description denies"     "$G" deny "$(bash_payload "$rtt_call")"
  rshim "Ready to Test" '"just prose, no headings"' "$both_c"
  assert "RTT, description lacking headings, denies" "$G" deny "$(bash_payload "$rtt_call")"
  rshim "Ready to Test" "$good_desc" "$both_c"
  assert "RTT with all four passes"             "$G" pass "$(bash_payload "$rtt_call")"
  # Where to test (user instruction 2026-09-26): steps + regression but no QA/Staging line
  # denies, naming the gap; a results line ("Verified on QA") is not an instruction to the tester.
  noenv_c='[{"body":"Testing steps\n1. Open the report.\n2. Expected: it renders."},{"body":"Verified on QA by Claude.\nRegression: risk low - nothing downstream consumes it."}]'
  rshim "Ready to Test" "$good_desc" "$noenv_c"
  assert "RTT without where-to-test denies"     "$G" deny "$(bash_payload "$rtt_call")"
  assert_reason "where-to-test deny names the gap" "$G" 'where to test.*Test on QA' "$(bash_payload "$rtt_call")"
  stg_c='[{"body":"* Test on Staging (release/130.0.0).\n1. Open the report.\n2. Expected: it renders.\nRegression: risk low."}]'
  rshim "Ready to Test" "$good_desc" "$stg_c"
  assert "RTT with 'Test on Staging' passes"    "$G" pass "$(bash_payload "$rtt_call")"
  # Wiki-markup numbered steps (`# step`), the form TICKET-TEMPLATE.md prescribes and
  # jira-add-comment.sh renders since 2026-10-05, were read as "no steps" (PROJ-15470).
  wiki_c='[{"body":"h3. Testing steps\nTest on Staging (release/130.0.0).\n# Open the report.\n# Expected: it renders."},{"body":"h3. Regression\n# Export a plain report; confirm unchanged."}]'
  rshim "Ready to Test" "$good_desc" "$wiki_c"
  assert "RTT with wiki-markup # steps passes"  "$G" pass "$(bash_payload "$rtt_call")"
  # Infra-only change live in prod, waiting on a third party (commit-ticket-jira's infra row): Production.
  prd_c='[{"body":"Test on Production: Dan confirms the mapping tool loads.\n1. Dan opens the tool.\n2. Expected: it loads.\nRegression: additive allowlist rules only."}]'
  rshim "Ready to Test" "$good_desc" "$prd_c"
  assert "RTT with 'Test on Production' passes" "$G" pass "$(bash_payload "$rtt_call")"
  assert "unrelated Bash passes"                "$G" pass "$(bash_payload 'git status --short')"
  # Filename in a READ is not an invocation -- same false positive the sibling gates hit.
  assert "reading the transition script passes" "$G" pass "$(bash_payload 'sed -n 1,40p "$HOME/.claude/skills/ama-jira-api/scripts/jira-transition-issue.sh"')"
  # An id the ticket does not offer: destination unresolvable, so Ready to Test cannot be ruled out.
  assert "unknown transition id denies"         "$G" deny "$(bash_payload 'bash "$HOME/.claude/skills/ama-jira-api/scripts/jira-transition-issue.sh" PROJ-9999 99')"
  # Both args come from the INVOCATION's own argument list. Scraping the whole command read
  # the key leftmost and the id leftmost-LONGEST (i.e. rightmost), so a compound command took
  # the redirect's `2` as the transition id and denied a valid move (PROJ-15392,
  # 2026-09-12). Ticket is ready here, so a correct parse of `31` passes; a parse of `2`
  # resolves to nothing and denies.
  assert "compound command parses its own args" "$G" pass "$(bash_payload 'bash "$HOME/.claude/skills/ama-jira-api/scripts/jira-transition-issue.sh" PROJ-9999 31 && bash "$HOME/.claude/skills/ama-jira-api/scripts/jira-add-comment.sh" PROJ-9999 2>/dev/null')"
  # `;`-chained: the id token came back as `31;`, failed the digit match, and a valid
  # transition was DENIED as "id <none> not offered" (PROJ-11854, 2026-09-18).
  assert "semicolon-chained parses its own args" "$G" pass "$(bash_payload 'bash "$HOME/.claude/skills/ama-jira-api/scripts/jira-transition-issue.sh" PROJ-9999 31; bash "$HOME/.claude/hooks/set-session-ticket.sh" "$PWD" "x Chat.md" PROJ-9999')"
  # Fail-closed arms. The deny reason must name the real cause, not claim the ticket is short
  # of the three items -- asserted live when the gate was written, 2026-09-11.
  unset ATLASSIAN_API_TOKEN
  assert "no token denies"                      "$G" deny "$(bash_payload "$rtt_call")"
  export ATLASSIAN_API_TOKEN="${R_OLDTOK:-probe}"
  printf '#!/usr/bin/env bash\nexit 7\n' > "$RSHIM/curl"; chmod +x "$RSHIM/curl"
  assert "unreachable Jira denies"              "$G" deny "$(bash_payload "$rtt_call")"

  # Pending-transition ledger (2026-09-11). A fail-closed deny leaves the ticket at its old
  # status with the comments already posted, so the owed transition is recorded and
  # pending-transition-check.sh surfaces it later. RTT_PENDING_FILE keeps these cases out of
  # the real ledger (seam exported at the top of this block, see the note there).
  rm -f "$RTT_PENDING_FILE" "$RTT_PENDING_NUDGED"
  printf '%s\0' "$(bash_payload "$rtt_call")" | bash "$hooks/$G" >/dev/null 2>&1
  if grep -q '^PROJ-9999	31	' "$RTT_PENDING_FILE" 2>/dev/null; then
    pass=$((pass+1)); printf 'ok    %s outage deny records the owed transition\n' "$G"
  else
    fail=$((fail+1)); printf 'FAIL  %s outage deny recorded nothing\n' "$G"
  fi
  # Repeat denies must not pile up duplicate lines for one ticket.
  printf '%s\0' "$(bash_payload "$rtt_call")" | bash "$hooks/$G" >/dev/null 2>&1
  if [ "$(grep -c '^PROJ-9999' "$RTT_PENDING_FILE" 2>/dev/null || echo 0)" = "1" ]; then
    pass=$((pass+1)); printf 'ok    %s repeat denies keep one line per ticket\n' "$G"
  else
    fail=$((fail+1)); printf 'FAIL  %s duplicate pending lines\n' "$G"
  fi
  # The nudge reads it back once per day.
  pending_transition_notice=""; . "$hooks/pending-transition-check.sh"
  case "$pending_transition_notice" in
    *"STILL OWED"*PROJ-9999*) pass=$((pass+1)); printf 'ok    %s the owed transition is surfaced\n' "$G" ;;
    *) fail=$((fail+1)); printf 'FAIL  %s owed transition not surfaced\n' "$G" ;;
  esac
  pending_transition_notice=""; . "$hooks/pending-transition-check.sh"
  if [ -z "$pending_transition_notice" ]; then
    pass=$((pass+1)); printf 'ok    %s the nudge is throttled to once a day\n' "$G"
  else
    fail=$((fail+1)); printf 'FAIL  %s nudge repeated same day\n' "$G"
  fi
  # A transition the gate CAN evaluate supersedes the record -- the retry, or a move elsewhere.
  rshim "Ready to Test" "$good_desc" "$both_c"
  printf '%s\0' "$(bash_payload "$rtt_call")" | bash "$hooks/$G" >/dev/null 2>&1
  if [ ! -s "$RTT_PENDING_FILE" ]; then
    pass=$((pass+1)); printf 'ok    %s a successful retry clears the record\n' "$G"
  else
    fail=$((fail+1)); printf 'FAIL  %s record survived the retry\n' "$G"
  fi
  # A readiness deny must NOT record -- the ticket is genuinely short and the agent is present.
  rm -f "$RTT_PENDING_FILE"
  rshim "Ready to Test" "$good_desc" '[]'
  printf '%s\0' "$(bash_payload "$rtt_call")" | bash "$hooks/$G" >/dev/null 2>&1
  if [ ! -s "$RTT_PENDING_FILE" ]; then
    pass=$((pass+1)); printf 'ok    %s a readiness deny records nothing\n' "$G"
  else
    fail=$((fail+1)); printf 'FAIL  %s readiness deny wrongly recorded\n' "$G"
  fi
  # Nor does an id the live /transitions list does not offer: the list came back, so the check
  # RAN -- that is a caller mistake, not an outage, and an IOU for a transition that never
  # existed nags on every later prompt (seen 2026-09-12 with the bogus `PROJ-15392 2 ?`).
  rm -f "$RTT_PENDING_FILE"
  printf '%s\0' "$(bash_payload 'bash "$HOME/.claude/skills/ama-jira-api/scripts/jira-transition-issue.sh" PROJ-9999 99')" | bash "$hooks/$G" >/dev/null 2>&1
  if [ ! -s "$RTT_PENDING_FILE" ]; then
    pass=$((pass+1)); printf 'ok    %s an unoffered id records nothing\n' "$G"
  else
    fail=$((fail+1)); printf 'FAIL  %s unoffered id wrongly recorded\n' "$G"
  fi
  unset RTT_PENDING_FILE RTT_PENDING_NUDGED pending_transition_notice

  PATH="$R_OLDPATH"; unset HR_CONFIG_FILE
  if [ -n "$R_OLDTOK" ]; then export ATLASSIAN_API_TOKEN="$R_OLDTOK"; else unset ATLASSIAN_API_TOKEN; fi
else
  skip_gate "$G"
fi

# -------------------------------------------------------------- scheduled-task-hidden-gate.sh
# `-WindowStyle Hidden` alone is deliberately in the DENY set here, not the allow set --
# confirmed live it still flashes a console for one frame (<harnessEpicKey>). Only
# run-hidden.vbs (or the pre-existing run-fleet-health-hidden.ps1) is a real escape hatch.
G=scheduled-task-hidden-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  assert "bare Register-ScheduledTask denied"          "$G" deny "$(bash_payload 'Register-ScheduledTask -TaskName "X" -Action (New-ScheduledTaskAction -Execute "bash.exe" -Argument "-lc foo")')"
  assert "Register-ScheduledTask with run-hidden.vbs allowed" "$G" pass "$(bash_payload 'Register-ScheduledTask -TaskName "X" -Action (New-ScheduledTaskAction -Execute "wscript.exe" -Argument "\"C:\\...\\run-hidden.vbs\" \"bash foo\"")')"
  assert "schtasks /query unaffected"                  "$G" pass "$(bash_payload 'schtasks.exe /query /tn "AMA-Foo"')"
  assert "schtasks /delete unaffected"                 "$G" pass "$(bash_payload 'schtasks.exe /delete /tn "AMA-Foo" /f')"
  assert "schtasks /create with no wrapper denied"     "$G" deny "$(bash_payload 'schtasks.exe /create /sc once /tn "X" /tr "bash foo" /f')"
  assert "schtasks /create with run-fleet-health-hidden allowed" "$G" pass "$(bash_payload 'schtasks.exe /create /sc daily /tn "X" /tr "powershell -File run-fleet-health-hidden.ps1" /f')"
  assert "Register-ScheduledTask with run-hidden-generic.vbs allowed" "$G" pass "$(bash_payload 'Register-ScheduledTask -TaskName "X" -Action (New-ScheduledTaskAction -Execute "wscript.exe" -Argument "\"C:\\...\\run-hidden-generic.vbs\" \"powershell.exe -File foo.ps1\"")')"
  # WindowStyle Hidden alone is NOT a valid escape hatch -- confirmed live it still flashes.
  assert "-WindowStyle Hidden alone still denied"      "$G" deny "$(bash_payload 'Register-ScheduledTask -TaskName "X" -Action (New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -File foo.ps1")')"
  assert "unrelated command untouched"                 "$G" pass "$(bash_payload "git status")"
  # /xml form (2026-08-24 false deny): the action lives in the FILE. Good file passes, bad denies.
  XD="$(cgmktemp -d "/tmp/gatefix-xml.XXXXXX")"
  printf '<Task><Actions><Exec><Command>wscript.exe</Command><Arguments>"C:\\x\\run-hidden.vbs" "bash foo"</Arguments></Exec></Actions></Task>\n' > "$XD/good.xml"
  printf '<Task><Actions><Exec><Command>bash.exe</Command><Arguments>-lc foo</Arguments></Exec></Actions></Task>\n' > "$XD/bad.xml"
  assert "schtasks /create /xml routed via run-hidden allowed" "$G" pass "$(bash_payload "schtasks.exe /create /tn X /xml \"$XD/good.xml\" /f")"
  assert "schtasks /create /xml bare bash.exe denied"          "$G" deny "$(bash_payload "schtasks.exe /create /tn X /xml \"$XD/bad.xml\" /f")"
  assert "schtasks /create /xml missing file denied"           "$G" deny "$(bash_payload "schtasks.exe /create /tn X /xml \"$XD/nope.xml\" /f")"
  rm -rf "$XD"
  # FALSE POSITIVES (2026-09-01): writing ABOUT a registration was denied exactly like
  # performing one. Both of these were hit for real -- the first while trying to log the
  # dead-task bug to harness-gaps.md, the second by a plain repo search.
  # The append target is written as a REPO path, not $HOME/.claude/harness-gaps.md, and must
  # stay that way. The meta-test at the end of this file source-greps this suite for
  # `>> $HOME/.claude/(harness-gaps|AGENTS|...)` to catch a case that mutates live state --
  # and it cannot tell an inert JSON payload string from a real append, so the realistic
  # form fails the suite (it did: 494/1). Exactly the same text-vs-act blindness this very
  # case exists to test for in the gate. The path is irrelevant to what is being asserted.
  assert "doc heredoc mentioning the cmdlet allowed"   "$G" pass "$(bash_payload 'cat >> /c/repo/ama-claude-harness/harness-gaps.md <<'"'"'EOF'"'"'
- Cause: stored Arguments escaped the path as \" where Windows needs "". A hand-built
  Register-ScheduledTask / New-ScheduledTaskAction reintroduces it.
EOF')"
  assert "read-only grep for the cmdlet allowed"       "$G" pass "$(bash_payload "grep -rn 'Register-ScheduledTask' \$HOME/.claude/hooks/")"
  assert "rg for the cmdlet allowed"                   "$G" pass "$(bash_payload "rg 'New-ScheduledTaskAction' --glob '*.sh'")"
  assert "piped Select-String over a doc allowed"      "$G" pass "$(bash_payload "Get-Content notes.md | Select-String 'Register-ScheduledTask'")"
  assert "echo mentioning the cmdlet allowed"          "$G" pass "$(bash_payload "echo 'use Register-ScheduledTask carefully' >> notes.txt")"
  # ...and the guard must not become a bypass: a text tool CHAINED into a real registration,
  # and a heredoc appended AFTER one, both still deny.
  assert "grep chained into a bare registration denied" "$G" deny "$(bash_payload 'grep -q x file && powershell.exe -Command "Register-ScheduledTask -TaskName T -Action (New-ScheduledTaskAction -Execute bash.exe)"')"
  assert "heredoc after a bare registration denied"     "$G" deny "$(bash_payload 'powershell.exe -Command "Register-ScheduledTask -TaskName T -Action (New-ScheduledTaskAction -Execute bash.exe)" <<'"'"'EOF'"'"'
run-hidden.vbs
EOF')"
else
  skip_gate "$G"
fi

# ---------------------------------------------- unattended-wrapper-allowlist (static)
# Narrow, mechanical: get_thread must be allowlisted in both note wrappers, or the
# get_thread-for-state fix (<harnessEpicKey>, 2026-08-26) silently degrades back to the
# search_threads truncation bug on the unattended path. Not a general allowlist checker --
# just the exact silent-Monday-degradation guard that bit team-meeting once already.
SU_SH="$harness/skills/ama-standup-notes/scripts/standup-unattended-run.sh"
TM_SH="$harness/skills/ama-team-meeting-notes/scripts/team-meeting-notes-unattended-run.sh"
for f in "$SU_SH" "$TM_SH"; do
  if [ -f "$f" ]; then
    if grep -q 'mcp__claude_ai_Gmail__get_thread' "$f"; then
      pass=$((pass+1))
    else
      fail=$((fail+1)); printf 'FAIL  %-46s get_thread missing from allowedTools\n' "$(basename "$f")"
    fi
  else
    skip=$((skip+1)); printf 'SKIP  %s not present\n' "$(basename "$f")"
  fi
done

# ------------------------------------------ harness-gaps weekly auto-review (runner + usage lib)
# Fixture usage JSON + fake clock + throwaway CLAUDE_STATE_DIR: exercises every schedule
# guard of harness-gaps-unattended-run.sh without a claude call, and the lib's
# account-wide weekly rule (a model-scoped cap is reported by `capped`, never the run gate).
HG_SH="$harness/skills/ama-harness-gaps/scripts/harness-gaps-unattended-run.sh"
HG_LIB="$hooks/lib-claude-usage.sh"
if [ -f "$HG_SH" ] && [ -f "$HG_LIB" ]; then
  HGT="$(cgmktemp -d "/tmp/gatefix-hg.XXXXXX")"
  hg_usage() { # pct2 reset_iso -> writes fixture, prints path
    # pct2 = the ACCOUNT-WIDE (scope null) weekly limit; optional $3 = Fable's scoped cap (default 30).
    printf '{"seven_day":{"utilization":19,"resets_at":"%s"},"limits":[{"group":"weekly","percent":19,"scope":null,"resets_at":"%s"},{"group":"weekly","percent":%s,"scope":null},{"group":"weekly","percent":%s,"scope":{"model":{"display_name":"Fable"}}},{"group":"session","percent":99}]}' \
      "$2" "$2" "$1" "${3:-30}" > "$HGT/u.json"; printf '%s' "$HGT/u.json"; }
  printf -- '- [session abc, 2026-09-01] a gap\n' > "$HGT/gaps.md"; : > "$HGT/nogaps.md"
  HG_NOW=1788782400   # 2026-09-07 12:00 UTC
  HG_TOMORROW="2026-09-08T06:00:00.092+00:00"; HG_LATER="2026-09-10T06:00:00+00:00"
  hg_run() { # usage-file gaps-file -> DECISION line
    CLAUDE_STATE_DIR="$HGT/state" CLAUDE_SCRATCH_DIR="$HGT/scratch" HARNESS_GAPS_DRY_RUN=1 \
      HARNESS_GAPS_NOW=$HG_NOW HARNESS_GAPS_FILE="$2" CLAUDE_USAGE_JSON="$1" bash "$HG_SH" 2>/dev/null; }
  hg_case() { # name expected-substring output
    if printf '%s' "$3" | grep -q "$2"; then pass=$((pass+1))
    else fail=$((fail+1)); printf 'FAIL  %-46s %s (got: %s)\n' "harness-gaps: $1" "expected '$2'" "$(printf '%s' "$3" | head -c 120)"; fi; }
  hg_case "lib picks max weekly-group pct"   "^23	1788847200" "$(CLAUDE_USAGE_JSON="$(hg_usage 23 "$HG_TOMORROW")" bash "$HG_LIB" weekly)"
  # 2026-10-12: Fable's own cap at 100% with the account at 70% postponed the run a week.
  hg_case "lib ignores model-scoped cap"     "^23	1788847200" "$(CLAUDE_USAGE_JSON="$(hg_usage 23 "$HG_TOMORROW" 100)" bash "$HG_LIB" weekly)"
  hg_case "lib lists capped model"           "^fable$" "$(CLAUDE_USAGE_JSON="$(hg_usage 23 "$HG_TOMORROW" 100)" bash "$HG_LIB" capped)"
  hg_case "capped fable falls back to opus"  "DECISION: would run: .*models opus$" "$(hg_run "$(hg_usage 23 "$HG_TOMORROW" 100)" "$HGT/gaps.md")"
  hg_case "all candidates capped postpones"  "every candidate model" "$(HARNESS_GAPS_MODELS=fable hg_run "$(hg_usage 23 "$HG_TOMORROW" 100)" "$HGT/gaps.md")"
  hg_case ">=90% postpones"                  "DECISION: postponed" "$(hg_run "$(hg_usage 95 "$HG_TOMORROW")" "$HGT/gaps.md")"
  hg_case "reset tomorrow runs"              "DECISION: would run: weekly 23%" "$(hg_run "$(hg_usage 23 "$HG_TOMORROW")" "$HGT/gaps.md")"
  hg_case "reset later skips"                "not the day before" "$(hg_run "$(hg_usage 23 "$HG_LATER")" "$HGT/gaps.md")"
  hg_case "no gaps stamps lastrun"           "DECISION: no gaps" "$(hg_run "$(hg_usage 23 "$HG_TOMORROW")" "$HGT/nogaps.md")"
  hg_case "lastrun stamped with reset date"  "2026-09-08" "$(cat "$HGT/state/harness/.harness-gaps-lastrun" 2>/dev/null)"
  hg_case "already ran skips"                "already ran" "$(hg_run "$(hg_usage 23 "$HG_TOMORROW")" "$HGT/gaps.md")"
  hg_case "usage unknown skips, never 0%"    "usage unknown" "$(hg_run "$HGT/missing.json" "$HGT/gaps.md")"
  hg_case "FORCE_RUN bypasses guards"        "DECISION: would run" "$(HARNESS_GAPS_FORCE_RUN=1 hg_run "$(hg_usage 95 "$HG_LATER")" "$HGT/gaps.md")"
  # Static: the two-leg plan-then-execute shape and the spend-limit signal must stay.
  for needle in '--permission-mode plan' '--resume "$SID"' '--model "$MODEL"' 'fable opus' 'unattended-blocked.txt' "never 'git add -A'"; do
    if grep -qF -- "$needle" "$HG_SH"; then pass=$((pass+1))
    else fail=$((fail+1)); printf 'FAIL  harness-gaps: runner lost %s\n' "$needle"; fi
  done
  hg_case "on-prompt relays the digest"      "^[1-9]" "$(grep -c 'harness-gaps-review.txt' "$hooks/on-prompt.sh")"
  hg_case "token never echoed by the lib"    "^0$" "$(grep -cE 'echo .*\$tok|log .*\$tok|printf .*\$tok' "$HG_LIB")"
  rm -rf "$HGT"
else
  skip=$((skip+1)); printf 'SKIP  harness-gaps runner/lib not present\n'
fi

# ------------------------------------------------------------ running-script-edit-gate.sh
# Test seam RUNNING_SCRIPT_CMDLINES stands in for the live process list.
G=running-script-edit-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  export RUNNING_SCRIPT_CMDLINES="bash /c/x/standup-unattended-run.sh --now
node C:\\Program Files\\claude\\cli.js"
  assert "edit of a script mid-run denied"       "$G" deny "$(edit_payload "$HOME/.claude/skills/ama-standup-notes/scripts/standup-unattended-run.sh" "x")"
  assert "write of a script mid-run denied"      "$G" deny "$(write_payload "/c/x/standup-unattended-run.sh" "x")"
  assert "sed -i on a script mid-run denied"     "$G" deny "$(bash_payload "sed -i 's/a/b/' /c/x/standup-unattended-run.sh")"
  assert "edit of an idle script passes"         "$G" pass "$(edit_payload "$HOME/.claude/hooks/on-prompt.sh" "x")"
  assert "edit of a non-script passes"           "$G" pass "$(edit_payload "$HOME/.claude/AGENTS.md" "standup-unattended-run.sh mentioned")"
  assert "running a script is not an edit"       "$G" pass "$(bash_payload "bash /c/x/standup-unattended-run.sh")"
  # 2026-09-22 false positive: `patch.sh` is a substring of the live `dispatch.sh` line.
  export RUNNING_SCRIPT_CMDLINES="bash C:/Users/x/.claude/hooks/dispatch.sh C:/Users/x/.claude/hooks/dispatch-pre-bash.manifest"
  assert "basename inside another script's name passes" "$G" pass "$(write_payload "/c/x/scratch/patch.sh" "x")"
  assert "exact basename still denied"            "$G" deny "$(write_payload "/c/x/dispatch.sh" "x")"
  # 2026-10-28: a worktree copy of a script the live install runs is a different file.
  _rs="$(cgmktemp -d "${TMPDIR:-/tmp}/gatefix-rs.XXXXXX")"; mkdir -p "$_rs/live" "$_rs/tree"
  printf 'x\n' > "$_rs/live/watch.sh"; printf 'x\n' > "$_rs/tree/watch.sh"
  export RUNNING_SCRIPT_CMDLINES="\"C:\\Program Files\\Git\\usr\\bin\\bash.exe\" $_rs/live/watch.sh repo 1"
  assert "same-named copy in another tree passes" "$G" pass "$(edit_payload "$_rs/tree/watch.sh" "x")"
  assert "the running file itself still denied"   "$G" deny "$(edit_payload "$_rs/live/watch.sh" "x")"
  export RUNNING_SCRIPT_CMDLINES="bash watch.sh"
  assert "bare running name still denies a copy"  "$G" deny "$(edit_payload "$_rs/tree/watch.sh" "x")"
  rm -rf "$_rs"
  export RUNNING_SCRIPT_CMDLINES="node cli.js"
  assert "nothing relevant running passes"       "$G" pass "$(edit_payload "/c/x/standup-unattended-run.sh" "x")"
  unset RUNNING_SCRIPT_CMDLINES
else
  skip_gate "$G"
fi

# ------------------------------------------------------------ develop-backmerge-reminder.sh
# Fixture repo with fake origin/develop, origin/master and origin/release/9.0.0 refs. The
# develop half had no section until 2026-10-05; the release half was added that day (a hotfix
# that never reached release/130.0.0 undid itself on Staging, 2026-09-26).
G=develop-backmerge-reminder.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  BM="$(cgmktemp -d "/tmp/gatefix-backmerge.XXXXXX")"
  git -C "$BM" init -q -b master 2>/dev/null
  git -C "$BM" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "PROJ-1: base" 2>/dev/null
  git -C "$BM" update-ref refs/remotes/origin/develop HEAD 2>/dev/null
  git -C "$BM" update-ref refs/remotes/origin/release/9.0.0 HEAD 2>/dev/null
  printf 'hotfix\n' > "$BM/fix.txt"; git -C "$BM" add fix.txt
  git -C "$BM" -c user.name=t -c user.email=t@t commit -q -m "PROJ-2: hotfix" 2>/dev/null
  git -C "$BM" update-ref refs/remotes/origin/master HEAD 2>/dev/null
  bmp() { jq -n --arg c "$1" --arg d "$2" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}'; }
  bm_raw="$(bmp "git -C $BM push origin master" "$BM" | bash "$hooks/$G" 2>/dev/null)"
  if printf '%s' "$bm_raw" | grep -q 'no equivalent patch on develop' && printf '%s' "$bm_raw" | grep -q 'release/9.0.0: 1 master patch'; then pass=$((pass+1)); else
    fail=$((fail+1)); printf 'FAIL  %-46s got=%s\n' "develop AND live release both stranded" "$(printf '%s' "$bm_raw" | head -c 80)"; fi
  # Release caught up, develop still behind -> develop text only, no release section.
  git -C "$BM" update-ref refs/remotes/origin/release/9.0.0 HEAD 2>/dev/null
  bm_raw="$(bmp "git -C $BM push origin master" "$BM" | bash "$hooks/$G" 2>/dev/null)"
  if printf '%s' "$bm_raw" | grep -q 'no equivalent patch on develop' && ! printf '%s' "$bm_raw" | grep -q 'release/9.0.0'; then pass=$((pass+1)); else
    fail=$((fail+1)); printf 'FAIL  %-46s got=%s\n' "release caught up -> develop-only reminder" "$(printf '%s' "$bm_raw" | head -c 80)"; fi
  # develop caught up, release behind -> release-only reminder.
  git -C "$BM" update-ref refs/remotes/origin/develop HEAD 2>/dev/null
  git -C "$BM" update-ref refs/remotes/origin/release/9.0.0 HEAD~1 2>/dev/null
  bm_raw="$(bmp "git -C $BM push origin master" "$BM" | bash "$hooks/$G" 2>/dev/null)"
  if printf '%s' "$bm_raw" | grep -q 'develop is up to date' && printf '%s' "$bm_raw" | grep -q 'release/9.0.0: 1 master patch'; then pass=$((pass+1)); else
    fail=$((fail+1)); printf 'FAIL  %-46s got=%s\n' "develop caught up -> release-only reminder" "$(printf '%s' "$bm_raw" | head -c 80)"; fi
  # Everything merged -> silent. Also a stale (old) release branch must not nag.
  git -C "$BM" update-ref refs/remotes/origin/release/9.0.0 HEAD 2>/dev/null
  assert_block "all three in sync is silent"             "$G" pass "$(bmp "git -C $BM push origin master" "$BM")"
  git -C "$BM" update-ref refs/remotes/origin/release/9.0.0 HEAD~1 2>/dev/null
  BACKMERGE_RELEASE_MAX_AGE_SECS=0 assert_block "stale release branch is ignored" "$G" pass "$(bmp "git -C $BM push origin master" "$BM")"
  # The hook keys on the CHECKED-OUT branch (a bare `git push` from develop is the common
  # shape), so HEAD on develop is silent whatever the refspec says.
  git -C "$BM" checkout -q -b develop 2>/dev/null
  assert_block "HEAD on develop is silent"               "$G" pass "$(bmp "git -C $BM push origin master" "$BM")"
  rm -rf "$BM"
else
  skip_gate "$G"
fi

# ------------------------------------------ git-push-ticket-reminder.sh (ticket enumeration)
# 2026-08-20: nudged the SESSION ticket, not the one in the pushed commit. Fixture repo with a
# fake origin/develop reflog so `origin/develop@{1}..HEAD` is exactly the pushed range.
G=git-push-ticket-reminder.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  # lib-git-target.sh git_push_rejected: shared by the four PostToolUse push nudges.
  ( . "$hooks/lib-git-target.sh"
    git_push_rejected '{"stderr":"To x\n ! [remote rejected] HEAD -> master (pre-receive hook declined)\nerror: failed to push some refs to x"}' ) \
    && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL  git_push_rejected: remote rejected push -> true"; }
  ( . "$hooks/lib-git-target.sh"
    git_push_rejected '{"stderr":"To x\n   1a2b3c4..5d6e7f8  master -> master"}' ) \
    && { fail=$((fail+1)); echo "FAIL  git_push_rejected: successful push -> false"; } || pass=$((pass+1))
  # git_target_dir verb arg: the commit's own -C, not the first -C (2026-10-20, main clone read).
  GTV='R=/main; W=/wt; git -C $R diff --stat; git -C $W commit -q -F m -- src/'
  r="$( . "$hooks/lib-git-target.sh"; git_target_dir "$GTV" /cwd commit )"
  [ "$r" = /wt ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL  git_target_dir verb=commit -> /wt (got '$r')"; }
  r="$( . "$hooks/lib-git-target.sh"; git_target_dir "$GTV" /cwd )"
  [ "$r" = /main ] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL  git_target_dir no verb -> first -C /main (got '$r')"; }
  PT="$(cgmktemp -d "/tmp/gatefix-push.XXXXXX")"
  git -C "$PT" init -q -b develop 2>/dev/null
  git -C "$PT" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "PROJ-1: base" 2>/dev/null
  git -C "$PT" update-ref refs/remotes/origin/develop HEAD 2>/dev/null
  git -C "$PT" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "PROJ-15330: real work" 2>/dev/null
  git -C "$PT" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "PROJ-15331: more work" 2>/dev/null
  git -C "$PT" update-ref -m push refs/remotes/origin/develop HEAD 2>/dev/null   # reflog: @{1} = base
  # Status-aware (2026-09-18): the hook now drops tickets already at/past the branch's target
  # via lib-jira-status.sh. Shim `curl` for the WHOLE block -- the fixture keys are real
  # tickets, and with a live token the older cases would otherwise read live Jira and
  # skip them. Same shim shape as ready-to-test-regression-reminder.sh's block above.
  PSHIM="$(cgmktemp -d "/tmp/gatefix-pstat.XXXXXX")"
  pstat() { printf '#!/usr/bin/env bash\nprintf %%s '"'"'%s'"'"'\n' "$1" > "$PSHIM/curl"; chmod +x "$PSHIM/curl"; }
  printf '{"atlassian":{"cloudId":"h"},"user":{"email":"e"}}' > "$PSHIM/cfg.json"
  P_OLDPATH="$PATH"; PATH="$PSHIM:$PATH"; export ATLASSIAN_API_TOKEN="${ATLASSIAN_API_TOKEN:-probe}" HR_CONFIG_FILE="$PSHIM/cfg.json"
  pstat '{"fields":{"status":{"name":"In Progress"}}}'
  printf 'PROJ-15317' > "$HOME/.claude/.session-chatfiles/$PROBE_SID-push.ticket"
  r="$(printf '%s' "$(bash_payload_sid "git -C $PT push origin develop" "$PT" "$PROBE_SID-push")" | bash "$hooks/$G" 2>/dev/null | jq -r '.reason // empty')"
  if printf '%s' "$r" | grep -q 'PROJ-15330' && printf '%s' "$r" | grep -q 'PROJ-15331' && ! printf '%s' "$r" | grep -q 'PROJ-15317'; then
    pass=$((pass+1))
  else
    fail=$((fail+1)); printf 'FAIL  %-46s reason=%s\n' "push nudges the PUSHED tickets, not session" "${r:0:120}"
  fi
  rm -f "$HOME/.claude/.session-chatfiles/$PROBE_SID-push.ticket"
  # 2026-08-28: with NO .ticket file the hook used to `exit 0` and stay silent -- which is
  # how PROJ-15330's nine develop pushes got no nudge at all (set-session-ticket.sh
  # had failed on a renamed chat log, so the file didn't exist yet). Commit subjects alone
  # must be enough.
  r="$(printf '%s' "$(bash_payload_sid "git -C $PT push origin develop" "$PT" "$PROBE_SID-push")" | bash "$hooks/$G" 2>/dev/null | jq -r '.reason // empty')"
  if printf '%s' "$r" | grep -q 'PROJ-15330' && printf '%s' "$r" | grep -q 'QA'; then
    pass=$((pass+1))
  else
    fail=$((fail+1)); printf 'FAIL  %-46s reason=%s\n' "push nudges with NO session .ticket file" "${r:0:120}"
  fi
  # PROJ-15226 shape: the repo path held in a shell variable. grep hands back the
  # literal `$W`; lib-git-target.sh falls back to the cwd instead of going silent. Pinned
  # here because the fix originally reached ONE of eleven copies of this resolution.
  r="$(printf '%s' "$(bash_payload_sid "W=\"$PT\"; git -C \"\$W\" push origin develop" "$PT" "$PROBE_SID-push")" | bash "$hooks/$G" 2>/dev/null | jq -r '.reason // empty')"
  if printf '%s' "$r" | grep -q 'PROJ-15330'; then
    pass=$((pass+1))
  else
    fail=$((fail+1)); printf 'FAIL  %-46s reason=%s\n' "push via \$W variable still nudges (cwd fallback)" "${r:0:120}"
  fi
  # Harness-epic-only push must still stay silent now that the .ticket gate is gone.
  HP="$(cgmktemp -d "/tmp/gatefix-hpush.XXXXXX")"
  git -C "$HP" init -q -b master 2>/dev/null
  git -C "$HP" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "<harnessEpicKey>: harness tweak" 2>/dev/null
  r="$(printf '%s' "$(bash_payload_sid "git -C $HP push origin master" "$HP" "$PROBE_SID-push")" | bash "$hooks/$G" 2>/dev/null | jq -r '.reason // empty')"
  if [ -z "$r" ]; then
    pass=$((pass+1))
  else
    fail=$((fail+1)); printf 'FAIL  %-46s reason=%s\n' "harness-epic-only push stays silent" "${r:0:120}"
  fi
  # Unresolvable `$W` path + a cwd whose last commit is harness work: the push was a harness
  # push, and the session-ticket fallback would have named a product ticket sitting in QA
  # (PROJ-15430, 2026-09-18). Silent.
  printf 'PROJ-15430' > "$HOME/.claude/.session-chatfiles/$PROBE_SID-push.ticket"
  r="$(printf '%s' "$(bash_payload_sid "W=\"$HP\"; git -C \"\$W\" push origin master" "$HP" "$PROBE_SID-push")" | bash "$hooks/$G" 2>/dev/null | jq -r '.reason // empty')"
  rm -f "$HOME/.claude/.session-chatfiles/$PROBE_SID-push.ticket"
  if [ -z "$r" ]; then
    pass=$((pass+1))
  else
    fail=$((fail+1)); printf 'FAIL  %-46s reason=%s\n' "harness push via \$W: no session-ticket nudge" "${r:0:120}"
  fi
  # Already at/past target -> silent. 15411 shape: every hoop cleared, then a pin bump on the
  # release branch re-nudged "hop through Review -> QA -> Ready to Test".
  pstat '{"fields":{"status":{"name":"Done"}}}'
  r="$(printf '%s' "$(bash_payload_sid "git -C $PT push origin develop" "$PT" "$PROBE_SID-push")" | bash "$hooks/$G" 2>/dev/null | jq -r '.reason // empty')"
  if [ -z "$r" ]; then pass=$((pass+1)); else
    fail=$((fail+1)); printf 'FAIL  %-46s reason=%s\n' "Done ticket: develop push stays silent" "${r:0:120}"; fi
  pstat '{"fields":{"status":{"name":"QA"}}}'
  r="$(printf '%s' "$(bash_payload_sid "git -C $PT push origin develop" "$PT" "$PROBE_SID-push")" | bash "$hooks/$G" 2>/dev/null | jq -r '.reason // empty')"
  if [ -z "$r" ]; then pass=$((pass+1)); else
    fail=$((fail+1)); printf 'FAIL  %-46s reason=%s\n' "QA ticket: develop push (target QA) silent" "${r:0:120}"; fi
  # Hotfix branch: Test Complete is past the Ready-to-Test target -> silent; In Progress nudges.
  git -C "$PT" checkout -q -b hotfix/1.0.1 2>/dev/null
  pstat '{"fields":{"status":{"name":"Test Complete"}}}'
  r="$(printf '%s' "$(bash_payload_sid "git -C $PT push origin hotfix/1.0.1" "$PT" "$PROBE_SID-push")" | bash "$hooks/$G" 2>/dev/null | jq -r '.reason // empty')"
  if [ -z "$r" ]; then pass=$((pass+1)); else
    fail=$((fail+1)); printf 'FAIL  %-46s reason=%s\n' "Test Complete ticket: hotfix push silent" "${r:0:120}"; fi
  pstat '{"fields":{"status":{"name":"In Progress"}}}'
  r="$(printf '%s' "$(bash_payload_sid "git -C $PT push origin hotfix/1.0.1" "$PT" "$PROBE_SID-push")" | bash "$hooks/$G" 2>/dev/null | jq -r '.reason // empty')"
  if printf '%s' "$r" | grep -q 'PROJ-15330' && printf '%s' "$r" | grep -q 'Ready to Test'; then pass=$((pass+1)); else
    fail=$((fail+1)); printf 'FAIL  %-46s reason=%s\n' "In Progress ticket: hotfix push nudges" "${r:0:120}"; fi
  # Lookup failure (empty body) fails OPEN -- the nudge is cheaper than a stale ticket.
  pstat '{}'
  r="$(printf '%s' "$(bash_payload_sid "git -C $PT push origin hotfix/1.0.1" "$PT" "$PROBE_SID-push")" | bash "$hooks/$G" 2>/dev/null | jq -r '.reason // empty')"
  if printf '%s' "$r" | grep -q 'PROJ-15330'; then pass=$((pass+1)); else
    fail=$((fail+1)); printf 'FAIL  %-46s reason=%s\n' "unknown status fails open (still nudges)" "${r:0:120}"; fi
  PATH="$P_OLDPATH"; unset HR_CONFIG_FILE; rm -rf "$PSHIM"
  rm -rf "$HP" "$PT"
else
  skip_gate "$G"
fi

# ------------------------------------------------------- set-session-ticket.sh shortid alias
# The harness itself hands the model a stale chat filename routinely (the log is auto-renamed
# mid-session; a brand-new session's statefile can be empty) -- the session shortid never goes
# stale, so it's accepted as an alternate key (2026-08-31, entry 74).
SST="$hooks/set-session-ticket.sh"
if [ -f "$SST" ]; then
  ALIAS_SID="a1b2c3d4-$PROBE_TAG"
  printf '%s' "/tmp/nowhere/Some Renamed Topic Chat.md" > "$HOME/.claude/.session-chatfiles/$ALIAS_SID"
  if bash "$SST" /tmp/nowhere "a1b2c3d4 Chat.md" PROJ-11111 >/dev/null 2>&1 \
     && [ "$(cat "$HOME/.claude/.session-chatfiles/$ALIAS_SID.ticket" 2>/dev/null)" = "PROJ-11111" ]; then
    pass=$((pass+1))
  else
    fail=$((fail+1)); printf 'FAIL  %-46s\n' "shortid alias resolves the session"
  fi
  if bash "$SST" /tmp/nowhere "zz-no-such-file Chat.md" PROJ-11111 >/dev/null 2>&1; then
    fail=$((fail+1)); printf 'FAIL  %-46s\n' "unknown chat name still exits 1"
  else
    pass=$((pass+1))
  fi
  rm -f "$HOME/.claude/.session-chatfiles/$ALIAS_SID" "$HOME/.claude/.session-chatfiles/$ALIAS_SID.ticket"
else
  skip=$((skip+1)); printf 'SKIP  set-session-ticket.sh not present\n'
fi

# ------------------------------------------------- ticket-in-progress-reminder.sh success gate
# Fires only when the recorded set-session-ticket.sh call actually SUCCEEDED (its "now tied to"
# line in tool_response) -- a nudge off a failed call once pushed toward a backward transition
# on a ticket already at QA (2026-08-28). No tool_response at all stays fail-open.
G=ticket-in-progress-reminder.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  tipr() { jq -cn --arg c "$1" --arg r "$2" \
    '{tool_input:{command:$c}, tool_response:(if $r=="" then null else {stdout:$r} end)}'; }
  TIPR_CMD='bash "$HOME/.claude/hooks/set-session-ticket.sh" /c/x "a Chat.md" PROJ-15999'
  assert_block "succeeded call nudges"        "$G" block "$(tipr "$TIPR_CMD" 'session abc now tied to PROJ-15999 (enables ...)')"
  assert_block "failed call stays silent"     "$G" pass  "$(tipr "$TIPR_CMD" 'no session state points at a file named: a Chat.md')"
  assert_block "no tool_response fails open"  "$G" block "$(tipr "$TIPR_CMD" '')"
  # Status-aware (2026-09-07): recording a ticket AFTER closing it is a legitimate order and
  # got told to go In Progress. Same shim as the regression section above.
  #
  # Built HERE when absent rather than inherited. The shim and `jstat` were created inside
  # the ready-to-test-regression-reminder.sh section, so any --gate filter that selected this
  # gate WITHOUT that one left $JSHIM unbound and `set -u` killed the whole run at this line
  # -- which is exactly what run-check-gates-full.sh does, since it sweeps only the sections
  # an edit touched. Hit live 2026-09-21: "JSHIM: unbound variable", run aborted, reminder
  # never cleared. A cross-section variable dependency is invisible in a full pass and only
  # ever fails under a filter.
  if [ -z "${JSHIM:-}" ]; then
    JSHIM="$(cgmktemp -d "/tmp/gatefix-jstat.XXXXXX")"
    jstat() { printf '#!/usr/bin/env bash\nprintf %%s '"'"'{"fields":{"status":{"name":"%s"}}}'"'"'\n' "$1" > "$JSHIM/curl"; chmod +x "$JSHIM/curl"; }
    printf '{"atlassian":{"cloudId":"h"},"user":{"email":"e"}}' > "$JSHIM/cfg.json"
    J_OLDPATH="$PATH"; export ATLASSIAN_API_TOKEN="${ATLASSIAN_API_TOKEN:-probe}"
  fi
  PATH="$JSHIM:$PATH"; export HR_CONFIG_FILE="$JSHIM/cfg.json"
  jstat "In Progress"; assert_block "already In Progress stays silent" "$G" pass  "$(tipr "$TIPR_CMD" 'session abc now tied to PROJ-15999 (enables ...)')"
  jstat "Done";        assert_block "already Done stays silent"        "$G" pass  "$(tipr "$TIPR_CMD" 'session abc now tied to PROJ-15999 (enables ...)')"
  jstat "Open";        assert_block "Open ticket still nudges"         "$G" block "$(tipr "$TIPR_CMD" 'session abc now tied to PROJ-15999 (enables ...)')"
  PATH="$J_OLDPATH"; unset HR_CONFIG_FILE; rm -rf "$JSHIM"
else
  skip_gate "$G"
fi

# ---------------------------------------------------- hstate absorb honours CLAUDE_STATE_DIR
# With CLAUDE_STATE_DIR overridden (test seam), the absorb branch must NOT mv a real
# ~/.claude leftover into the override dir -- that was a silent data-loss path for any test
# using the seam (entry 62 step-4 blocker). Runs against a snapshot HOME, never live.
HST="$(cgmktemp -d "/tmp/gatefix-hstate.XXXXXX")"
mkdir -p "$HST/home/.claude" "$HST/state"
cp "$hooks/lib-claude-paths.sh" "$HST/"
printf 'REAL' > "$HST/home/.claude/.probe-seen"
( HOME="$HST/home" CLAUDE_STATE_DIR="$HST/state" bash "$HST/lib-claude-paths.sh" hstate notices .probe-seen >/dev/null )
if [ -f "$HST/home/.claude/.probe-seen" ]; then pass=$((pass+1)); else
  fail=$((fail+1)); printf 'FAIL  %-46s\n' "overridden CLAUDE_STATE_DIR skips the absorb"; fi
( HOME="$HST/home" bash "$HST/lib-claude-paths.sh" hstate notices .probe-seen >/dev/null )
if [ -f "$HST/home/.claude/harness-state/notices/.probe-seen" ] && [ ! -e "$HST/home/.claude/.probe-seen" ]; then
  pass=$((pass+1)); else
  fail=$((fail+1)); printf 'FAIL  %-46s\n' "default CLAUDE_STATE_DIR still absorbs"; fi
rm -rf "$HST"

# ------------------------------------------------ develop-backmerge-reminder.sh (dead develop)
# Skip needs BOTH halves: zero develop-only patches AND develop older than the age bound. Each
# half alone must still nudge.
G=develop-backmerge-reminder.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  BM="$(cgmktemp -d "/tmp/gatefix-bm.XXXXXX")"
  # Real file changes, not --allow-empty: empty commits share one (empty) patch-id, so
  # `git cherry` reports them equivalent and the fixture proves nothing.
  git -C "$BM" init -q -b master 2>/dev/null
  printf 'base\n' > "$BM/f"; git -C "$BM" add f 2>/dev/null
  GIT_COMMITTER_DATE="2021-05-18T00:00:00" git -C "$BM" -c user.name=t -c user.email=t@t commit -q -m "old base" 2>/dev/null
  git -C "$BM" update-ref refs/remotes/origin/develop HEAD 2>/dev/null
  printf 'master\n' >> "$BM/f"; git -C "$BM" add f 2>/dev/null
  git -C "$BM" -c user.name=t -c user.email=t@t commit -q -m "master moved on" 2>/dev/null
  git -C "$BM" update-ref refs/remotes/origin/master HEAD 2>/dev/null
  assert_block "dead develop (stale + no own patches) silent" "$G" pass  "$(bash_payload_cwd "git -C $BM push origin master" "$BM")"
  BACKMERGE_DEAD_DEVELOP_SECS=999999999999 assert_block "same repo, develop inside age bound nudges" "$G" block "$(bash_payload_cwd "git -C $BM push origin master" "$BM")"
  # Give develop its own patch: stale but diverged -> still a real back-merge question.
  git -C "$BM" checkout -q -b tmpdev origin/develop 2>/dev/null
  printf 'develop\n' > "$BM/g"; git -C "$BM" add g 2>/dev/null
  GIT_COMMITTER_DATE="2021-05-19T00:00:00" git -C "$BM" -c user.name=t -c user.email=t@t commit -q -m "develop-only" 2>/dev/null
  git -C "$BM" update-ref refs/remotes/origin/develop HEAD 2>/dev/null
  git -C "$BM" checkout -q master 2>/dev/null
  assert_block "stale develop WITH own patches nudges"   "$G" block "$(bash_payload_cwd "git -C $BM push origin master" "$BM")"
  rm -rf "$BM"
else
  skip_gate "$G"
fi

# --------------------------------------------------- dev-server-teardown-reminder.sh
# Since 2026-10-12 this hook KILLS idle dev servers (any session's), so every case runs on a
# throwaway marker store (CLAUDE_STATE_DIR) with canned netstat (AMA_DEVSERVER_LISTEN_SRC)
# and dry-run kills -- the sweep would otherwise rewrite and delete LIVE markers, and a live
# session's sweep could race the fixtures. Asserts: RECORD (any free explicit port; a busy
# port is never claimed), the KILL rule (idle + no connection + our recorded PID), every
# guard that keeps it from killing the wrong thing (open connection, a command naming the
# port, a stranger's PID, a stale PID-less marker -- the shape that killed another session's
# in-use server on the hook's first live run), and that the hook is REGISTERED.
G=dev-server-teardown-reminder.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  DSBASE="$(cgmktemp -d "/tmp/gatefix-devsrv.XXXXXX")"
  DSSID="$PROBE_SID-devsrv"; DSOTHER="$PROBE_SID-other"
  DSSTATE="$DSBASE/state/sessions/.usage-state"; mkdir -p "$DSSTATE"
  printf '  TCP    [::1]:9999    [::]:0    LISTENING    1\n'      > "$DSBASE/free"
  printf '  TCP    [::1]:4200    [::]:0    LISTENING    12345\n'  > "$DSBASE/busy4200"
  printf '  TCP    [::1]:4210    [::]:0    LISTENING    777\n'    > "$DSBASE/up"
  printf '  TCP    [::1]:4210    [::]:0    LISTENING    888\n'    > "$DSBASE/up888"
  { cat "$DSBASE/up"; printf '  TCP    [::1]:4210    [::1]:53000    ESTABLISHED    777\n'; } > "$DSBASE/upconn"
  ds()  { jq -nc --arg s "${2:-$DSSID}" --arg c "$1" '{tool_name:"Bash",session_id:$s,tool_input:{command:$c},tool_response:{stdout:"ok"}}'; }
  dsr() { CLAUDE_STATE_DIR="$DSBASE/state" AMA_DEVSERVER_DRY_RUN=1 AMA_DEVSERVER_LISTEN_SRC="$1" bash "$hooks/$G" <<<"$2" 2>/dev/null; }
  dsold() { touch -d "@$(( $(date +%s) - 9000 ))" "$1" 2>/dev/null; }
  dsre() { rm -f "$DSSTATE"/devserver-probed-* 2>/dev/null; }
  dscase() { if [ "$2" = 1 ]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL  %-46s %s\n' "$1" "$3"; fi; }
  dsm="$DSSTATE/devserver-$DSSID-4210"

  # Record side.
  dsr "$DSBASE/free" "$(ds 'npx ng serve --configuration localqa --port 4210 --live-reload=false')" >/dev/null
  dscase "free explicit port is recorded" "$([ -f "$dsm" ] && echo 1)" "no marker"
  dsr "$DSBASE/busy4200" "$(ds 'npx ng serve --port 4200')" >/dev/null
  dscase "busy explicit port is never claimed" "$([ ! -f "$DSSTATE/devserver-$DSSID-4200" ] && echo 1)" "claimed the user port"
  dsr "$DSBASE/free" "$(ds 'python -m http.server 8791 --bind 127.0.0.1')" >/dev/null
  dscase "http.server positional port recorded" "$([ -f "$DSSTATE/devserver-$DSSID-8791" ] && echo 1)" "no marker"
  rm -f "$DSSTATE/devserver-$DSSID-8791"
  # npm start script, no --port: angular.json port, recorded only when FREE at launch.
  mkdir -p "$DSBASE/app" "$DSBASE/app-noport"
  printf '{"projects":{"a":{"architect":{"serve":{"options":{"port": 4201}}}}}}\n' > "$DSBASE/app/angular.json"
  printf '{"projects":{"a":{"architect":{"serve":{"options":{}}}}}}\n' > "$DSBASE/app-noport/angular.json"
  printf '  TCP    [::1]:4201    [::]:0    LISTENING    4242\n' > "$DSBASE/busy4201"
  dsr "$DSBASE/free" "$(ds "npm --prefix $DSBASE/app run start:staging")" >/dev/null
  dscase "npm start on a free angular.json port recorded" "$([ -f "$DSSTATE/devserver-$DSSID-4201" ] && echo 1)" "no marker"
  rm -f "$DSSTATE/devserver-$DSSID-4201"
  dsr "$DSBASE/busy4201" "$(ds "npm --prefix $DSBASE/app run start:staging")" >/dev/null
  dscase "npm start on a BUSY port is not recorded" "$([ ! -f "$DSSTATE/devserver-$DSSID-4201" ] && echo 1)" "claimed the user server"
  dsr "$DSBASE/free" "$(ds "npm --prefix $DSBASE/app-noport run start")" >/dev/null
  dscase "angular.json without port falls back to 4200" "$([ -f "$DSSTATE/devserver-$DSSID-4200" ] && echo 1)" "no marker"
  rm -f "$DSSTATE/devserver-$DSSID-4200"

  # Fresh: silent, and the first sweep records the listener PID.
  dsre; out="$(dsr "$DSBASE/up" "$(ds 'git status')")"
  dscase "fresh dev server stays silent" "$([ -z "$out" ] && echo 1)" "$out"
  dscase "first sight records the listener PID" "$([ "$(cat "$dsm" 2>/dev/null)" = 777 ] && echo 1)" "$(cat "$dsm" 2>/dev/null)"

  # Guards that must keep it alive.
  dsold "$dsm"; dsre; out="$(dsr "$DSBASE/upconn" "$(ds 'git status')")"
  dscase "open connection keeps an idle server alive" "$([ -z "$out" ] && [ -f "$dsm" ] && echo 1)" "$out"
  dsold "$dsm"; dsre; out="$(dsr "$DSBASE/up" "$(ds 'curl -s http://localhost:4210/x')")"
  dscase "a command naming :port counts as use" "$([ -z "$out" ] && [ -f "$dsm" ] && echo 1)" "$out"
  printf '777\n' > "$dsm"; dsold "$dsm"; dsre; out="$(dsr "$DSBASE/up888" "$(ds 'git status')")"
  dscase "a stranger on the reused port is never killed" "$([ -z "$out" ] && [ ! -f "$dsm" ] && echo 1)" "$out"
  : > "$DSSTATE/devserver-$DSOTHER-stale-4210"; dsold "$DSSTATE/devserver-$DSOTHER-stale-4210"; dsre
  out="$(dsr "$DSBASE/up" "$(ds 'git status')")"
  dscase "stale PID-less marker never adopts a stranger" "$([ -z "$out" ] && [ ! -f "$DSSTATE/devserver-$DSOTHER-stale-4210" ] && echo 1)" "$out"

  # The kill: idle, no connection, our PID -- own session and another session's.
  printf '777\n' > "$dsm"; dsold "$dsm"; dsre; out="$(dsr "$DSBASE/up" "$(ds 'git status')")"
  dscase "idle server is killed and reported" "$(case "$out" in *'port 4210 (PID 777, started by this session)'*) echo 1 ;; esac)" "$out"
  dscase "killed server's marker is dropped" "$([ ! -f "$dsm" ] && echo 1)" "marker survived"
  printf '777\n' > "$DSSTATE/devserver-$DSOTHER-4210"; dsold "$DSSTATE/devserver-$DSOTHER-4210"; dsre
  out="$(dsr "$DSBASE/up" "$(ds 'git status')")"
  dscase "another session's idle server is reaped" "$(case "$out" in *'port 4210 (PID 777, started by session'*) echo 1 ;; esac)" "$out"
  # Held for the user's sign-off (devserver-hold.sh): an unexpired hold keeps an idle server
  # alive and is never mistaken for a marker; an expired hold is dropped and the kill resumes.
  printf '777\n' > "$dsm"; dsold "$dsm"; printf '%s\n' "$(( $(date +%s) + 3600 ))" > "$DSSTATE/devserver-hold-4210"; dsre
  out="$(dsr "$DSBASE/up" "$(ds 'git status')")"
  dscase "held server survives the idle sweep" "$([ -z "$out" ] && [ -f "$dsm" ] && echo 1)" "$out"
  dscase "hold file is not adopted as a marker" "$(case "$(cat "$DSSTATE/devserver-hold-4210" 2>/dev/null)" in 777|'') ;; *) echo 1 ;; esac)" "hold overwritten"
  dsold "$dsm"; printf '%s\n' "$(( $(date +%s) - 60 ))" > "$DSSTATE/devserver-hold-4210"; dsre
  out="$(dsr "$DSBASE/up" "$(ds 'git status')")"
  dscase "expired hold no longer protects" "$(case "$out" in *'port 4210 (PID 777'*) echo 1 ;; esac)" "$out"
  dscase "expired hold file is dropped" "$([ ! -f "$DSSTATE/devserver-hold-4210" ] && echo 1)" "hold survived"

  # Torn down already (marker past the idle window): silent, marker dropped. No markers anywhere: silent.
  : > "$dsm"; dsold "$dsm"; dsre; out="$(dsr "$DSBASE/free" "$(ds 'git status')")"
  dscase "torn-down server: silent, marker dropped" "$([ -z "$out" ] && [ ! -f "$dsm" ] && echo 1)" "$out"
  # Not listening YET with a fresh marker = still compiling (2026-10-19: dropped, then the reaper killed it): kept.
  : > "$dsm"; dsre; out="$(dsr "$DSBASE/free" "$(ds 'git status')")"
  dscase "compiling server (fresh marker, no listener): kept" "$([ -z "$out" ] && [ -f "$dsm" ] && echo 1)" "$out"
  rm -f "$dsm"
  rm -f "$DSSTATE"/devserver-*; out="$(dsr "$DSBASE/up" "$(ds 'echo hi')")"
  dscase "no markers anywhere: silent" "$([ -z "$out" ] && echo 1)" "$out"

  # Registered = wired in the template OR dispatched by the PostToolUse manifest.
  if grep -q "$G" "$harness/settings.template.json" "$hooks/dispatch-post-bash.manifest" 2>/dev/null; then pass=$((pass+1)); else
    fail=$((fail+1)); printf 'FAIL  %-46s in neither settings.template.json nor dispatch-post-bash.manifest\n' "hook is registered"; fi
  rm -rf "$DSBASE"
else
  skip_gate "$G"
fi

# --------------------------------------------------- dev-server-tab-close-teardown.sh
# The "done" event for an interactive verify loop: closing the tab kills THIS session's
# recorded dev server(s) and says so; nothing listening = silent; another session's marker
# is never touched. Throwaway marker store + canned netstat + dry-run kills, as above.
G=dev-server-tab-close-teardown.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  TCBASE="$(cgmktemp -d "/tmp/gatefix-tabclose.XXXXXX")"
  TCSID="$PROBE_SID-tabclose"
  TCSTATE="$TCBASE/state/sessions/.usage-state"; mkdir -p "$TCSTATE"
  printf '  TCP    [::1]:4210    [::]:0    LISTENING    99999\n' > "$TCBASE/up"
  printf '  TCP    [::1]:4200    [::]:0    LISTENING    12345\n' > "$TCBASE/down"
  tc() { jq -nc --arg s "$1" '{tool_name:"mcp__claude-in-chrome__tabs_close_mcp",session_id:$s,tool_input:{},tool_response:{}}'; }
  tcr() { CLAUDE_STATE_DIR="$TCBASE/state" AMA_DEVSERVER_DRY_RUN=1 AMA_DEVSERVER_LISTEN_SRC="$1" bash "$hooks/$G" <<<"$2" 2>/dev/null; }

  : > "$TCSTATE/devserver-$TCSID-4210"
  _tc_out="$(tcr "$TCBASE/up" "$(tc "$TCSID")")"
  case "$_tc_out" in *"port 4210 (PID 99999)"*) pass=$((pass+1)) ;; *)
    fail=$((fail+1)); printf 'FAIL  %-46s got=%s\n' "tab close kills and names port and PID" "$_tc_out" ;; esac
  if [ ! -f "$TCSTATE/devserver-$TCSID-4210" ]; then pass=$((pass+1)); else
    fail=$((fail+1)); printf 'FAIL  %-46s marker survived the kill\n' "tab close drops the marker"; fi

  : > "$TCSTATE/devserver-$TCSID-4210"
  _tc_out="$(tcr "$TCBASE/down" "$(tc "$TCSID")")"
  if [ -z "$_tc_out" ] && [ ! -f "$TCSTATE/devserver-$TCSID-4210" ]; then pass=$((pass+1)); else
    fail=$((fail+1)); printf 'FAIL  %-46s got=%s\n' "nothing listening: silent, marker dropped" "$_tc_out"; fi

  # Foreign sid as a real one would differ: a whole other id, not a suffix on ours (the
  # marker glob is devserver-<sid>-*, and sids are UUIDs, never prefixes of each other).
  : > "$TCSTATE/devserver-other-$TCSID-4210"
  _tc_out="$(tcr "$TCBASE/up" "$(tc "$TCSID")")"
  if [ -z "$_tc_out" ] && [ -f "$TCSTATE/devserver-other-$TCSID-4210" ]; then pass=$((pass+1)); else
    fail=$((fail+1)); printf 'FAIL  %-46s got=%s\n' "another session's server is not ours" "$_tc_out"; fi

  if grep -q "$G" "$harness/settings.template.json" 2>/dev/null; then pass=$((pass+1)); else
    fail=$((fail+1)); printf 'FAIL  %-46s not registered in settings.template.json\n' "tab-close hook is registered"; fi
  rm -rf "$TCBASE"
else
  skip_gate "$G"
fi

# --------------------------------------------------- dotnet-build-server-shutdown.sh
# Fires only on a FOREGROUND dotnet build/test/publish at command position; a mention in a
# grep/cat, or a backgrounded build, must stay silent. Mode: full when nothing is in flight,
# --msbuild only when another build is. Dry-run seam reports on stderr and acts on nothing.
G=dotnet-build-server-shutdown.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  dbs() { jq -nc --arg s "$PROBE_SID" --arg c "$1" --arg r "$2" '{hook_event_name:"PostToolUse",tool_name:"Bash",session_id:$s,tool_input:{command:$c},tool_response:{stdout:$r}}'; }
  dbs_bg() { jq -nc --arg s "$PROBE_SID" --arg c "$1" '{hook_event_name:"PostToolUse",tool_name:"Bash",session_id:$s,tool_input:{command:$c},tool_response:{stdout:"",backgroundTaskId:"bk0000000"}}'; }
  dbs_run() { printf '%s' "$2" | AMA_DOTNET_SHUTDOWN_DRY_RUN=1 AMA_DOTNET_INFLIGHT="$1" bash "$hooks/$G" 2>&1; }
  dbs_case() {
    local desc="$1" want="$2" got="$3"
    if [ "$got" = "$want" ]; then pass=$((pass+1)); else
      fail=$((fail+1)); printf 'FAIL  %-46s want=%s got=%s\n' "$desc" "$want" "$got"; fi
  }
  dbs_case "dotnet test, none in flight -> full shutdown" "dry-run: mode=full inflight=0" \
    "$(dbs_run 0 "$(dbs 'dotnet test C:/x/y.csproj --no-restore' 'Passed!')")"
  dbs_case "dotnet build, another in flight -> msbuild only" "dry-run: mode=msbuild-only inflight=2" \
    "$(dbs_run 2 "$(dbs 'cd C:/x && dotnet build' '')")"
  dbs_case "quoted absolute dotnet.exe path" "dry-run: mode=full inflight=0" \
    "$(dbs_run 0 "$(dbs '"C:/Program Files/dotnet/dotnet.exe" publish x.csproj' '')")"
  dbs_case "mention in a grep is not a build" "" \
    "$(dbs_run 0 "$(dbs 'grep -n "dotnet test" skills/ama-api-tests/SKILL.md' '')")"
  dbs_case "mention in OUTPUT is not a build" "" \
    "$(dbs_run 0 "$(dbs 'cat notes.md' 'then run dotnet test')")"
  dbs_case "backgrounded build is still running" "" \
    "$(dbs_run 0 "$(dbs_bg 'dotnet test C:/x/y.csproj')")"
  dbs_case "dotnet --version is not a build" "" \
    "$(dbs_run 0 "$(dbs 'dotnet --version' '8.0.400')")"
  if grep -q "$G" "$hooks/dispatch-post-bash.manifest" 2>/dev/null; then pass=$((pass+1)); else
    fail=$((fail+1)); printf 'FAIL  %-46s not in dispatch-post-bash.manifest\n' "dotnet shutdown hook is dispatched"; fi
else
  skip_gate "$G"
fi

# ===================================================== PROJ-15361 hookability-audit hooks
# context_of: the warn-only nudges emit hookSpecificOutput.additionalContext (no
# permissionDecision -- an explicit allow would override a sibling deny gate), which
# reason_of deliberately doesn't read. Local helper rather than widening reason_of.
context_of() {
  local raw
  raw="$(printf '%s' "$2" | bash "$hooks/$1" 2>/dev/null)"
  [ -n "$raw" ] || { printf ''; return; }
  printf '%s' "$raw" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null
}
assert_context() {
  local desc="$1" gate="$2" want="$3" payload="$4" got
  got="$(context_of "$gate" "$payload")"
  if [ "$want" = "EMPTY" ]; then
    if [ -z "$got" ]; then pass=$((pass+1)); else
      fail=$((fail+1)); printf 'FAIL  %-46s want-no-context got=%s\n' "$desc" "$(printf '%s' "$got" | head -c 60)"; fi
  elif printf '%s' "$got" | grep -qiE "$want"; then pass=$((pass+1)); else
    fail=$((fail+1)); printf 'FAIL  %-46s want-context=/%s/ got=%s\n' "$desc" "$want" "$(printf '%s' "$got" | head -c 60)"
  fi
}

# ---------------------------------------------------------------- github-remote-gate.sh
# Harness repo must never gain a github.com remote / direct github push (public mirror is
# snapshot-only via publish-public.sh). ~/.claude (Claude-Config) pushes to GitHub
# legitimately -- different repo root, must stay silent.
G=github-remote-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  # $real_harness, not $harness: the gate resolves the REAL harness root itself, so a payload
  # naming the relocated copy legitimately doesn't match and the case proves nothing -- it went
  # red in every mutate-gates baseline. The documented $real_harness trap (see this file's head).
  assert "remote add github in harness"        "$G" deny "$(bash_payload_cwd 'git remote add github git@github.com:someone/mirror.git' "$real_harness")"
  assert "remote set-url to github in harness" "$G" deny "$(bash_payload_cwd 'git remote set-url origin https://github.com/someone/mirror.git' "$real_harness")"
  assert "push to github URL in harness"       "$G" deny "$(bash_payload_cwd 'git push https://github.com/someone/mirror.git master' "$real_harness")"
  assert "-C harness push from elsewhere"      "$G" deny "$(bash_payload_cwd "git -C $real_harness push https://github.com/someone/mirror.git master" "/tmp")"
  assert_reason "deny names publish-public.sh" "$G" 'publish-public\.sh' "$(bash_payload_cwd 'git push https://github.com/someone/mirror.git master' "$real_harness")"
  # False positives that must stay silent:
  assert "github push from the ~/.claude repo" "$G" pass "$(bash_payload_cwd 'git push https://github.com/someone/config.git master' "$HOME/.claude")"
  assert "bitbucket push in harness"           "$G" pass "$(bash_payload_cwd 'git push origin master' "$harness")"
  assert "commit msg merely mentions github"   "$G" pass "$(bash_payload_cwd 'git commit -m "never add a github.com remote here"' "$harness")"
  assert "clone of a github repo in harness"   "$G" pass "$(bash_payload_cwd 'git clone https://github.com/someone/tool.git /tmp/tool' "$harness")"
else
  skip_gate "$G"
fi

# ------------------------------------------------------------ msys-command-traps-nudge.sh
# Warn-only additionalContext for jq --slurpfile / jq|jq CRLF / schtasks single-slash.
G=msys-command-traps-nudge.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  assert_context "jq piped into jq, no tr"     "$G" 'CRLF' "$(bash_payload 'jq -r .a f.json | jq -r .b')"
  assert_context "jq --slurpfile"              "$G" 'slurpfile' "$(bash_payload 'jq --slurpfile d two.json .x one.json')"
  assert_context "schtasks single slash"       "$G" 'DOUBLED' "$(bash_payload 'schtasks.exe /query /tn "AMA-X"')"
  assert_context "jq|jq with tr -d stays quiet" "$G" EMPTY "$(bash_payload "jq -r .a f.json | tr -d '\r' | jq -r .b")"
  assert_context "schtasks doubled stays quiet" "$G" EMPTY "$(bash_payload 'schtasks.exe //query //tn "AMA-X"')"
  assert_context "plain jq stays quiet"        "$G" EMPTY "$(bash_payload 'jq -r .a f.json')"
  assert_context "aws arg with leading /"      "$G" 'MSYS_NO_PATHCONV' "$(bash_payload 'aws logs put-retention-policy --log-group-name /aws/vpc/flowlogs/x --retention-in-days 30')"
  assert_context "aws --opt=/path form"        "$G" 'MSYS_NO_PATHCONV' "$(bash_payload 'aws logs create-log-group --log-group-name=/aws/x')"
  assert_context "aws with MSYS_NO_PATHCONV"   "$G" EMPTY "$(bash_payload 'MSYS_NO_PATHCONV=1 aws logs create-log-group --log-group-name /aws/x')"
  assert_context "aws without leading / quiet" "$G" EMPTY "$(bash_payload 'aws ecs list-services --cluster production-v1-AMA')"
  assert_context "PowerShell tool stays quiet" "$G" EMPTY "$(jq -n '{tool_name:"PowerShell",tool_input:{command:"jq .a f | jq .b"}}')"
  assert "never denies"                        "$G" pass "$(bash_payload 'jq --slurpfile d two.json .x one.json')"
else
  skip_gate "$G"
fi

# --------------------------------------------------------- transcript-scan-bound-nudge.sh
# Warn-only: a hooks/*.sh edit reading the transcript with grep/jq and no tail/head bound
# in the new text (PROJ-15356 class).
G=transcript-scan-bound-nudge.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  TSB_UNBOUNDED='tr="$(printf %s "$payload" | jq -r .transcript_path)"; grep -c foo "$tr"'
  TSB_BOUNDED='tr="$(printf %s "$payload" | jq -r .transcript_path)"; tail -n 3000 "$tr" | grep -c foo'
  assert_context "unbounded transcript grep in a hook" "$G" 'PROJ-15356' "$(edit_payload "C:/x/hooks/foo.sh" "$TSB_UNBOUNDED")"
  assert_context "bounded read stays quiet"            "$G" EMPTY "$(edit_payload "C:/x/hooks/foo.sh" "$TSB_BOUNDED")"
  assert_context "non-hook file stays quiet"           "$G" EMPTY "$(edit_payload "C:/x/scripts/foo.sh" "$TSB_UNBOUNDED")"
  assert_context "hook edit with no transcript ref"    "$G" EMPTY "$(edit_payload "C:/x/hooks/foo.sh" 'grep -c foo "$somefile"')"
  assert "never denies"                                "$G" pass "$(edit_payload "C:/x/hooks/foo.sh" "$TSB_UNBOUNDED")"
else
  skip_gate "$G"
fi

# ------------------------------------------------------------- ama-skill-symlink-nudge.sh
# PostToolUse {decision:block}: a skills/ama-*/SKILL.md write with no skills/ama/ browsing
# symlink. First live run found 12 real missing links -- the prose rule had failed silently.
G=ama-skill-symlink-nudge.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  assert_reason "missing symlink nudges with ln -s" "$G" 'ln -s' "$(write_payload "$harness/skills/ama-zz-fake-probe/SKILL.md" "x")"
  assert_reason "nudge carries the MSYS symlink prefix" "$G" 'MSYS=winsymlinks:nativestrict ln -s' "$(write_payload "$harness/skills/ama-zz-fake-probe/SKILL.md" "x")"
  assert_block  "existing symlink stays quiet"      "$G" pass "$(edit_payload "$harness/skills/ama-jira-api/SKILL.md" "x")"
  assert_block  "non-ama skill stays quiet"         "$G" pass "$(edit_payload "$harness/skills/commit-ticket/SKILL.md" "x")"
else
  skip_gate "$G"
fi

# ----------------------------------------------------------------- jit-pointer-nudge.sh
# PROJ-15362: once-per-session-per-key additionalContext pointer to the on-demand
# reference doc for the file being edited. Session state under PROBE_SID so
# probe_state_clean sweeps it.
G=jit-pointer-nudge.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  probe_state_clean
  jitp() { jq -n --arg p "$1" --arg s "$2" '{tool_name:"Edit",session_id:$s,tool_input:{file_path:$p,new_string:"x"}}'; }
  assert_context "hook edit points at GATES-AND-HOOKS"  "$G" 'GATES-AND-HOOKS\.md' "$(jitp "C:/x/hooks/foo.sh" "$PROBE_SID-jit1")"
  assert_context "same key second time stays quiet"     "$G" EMPTY "$(jitp "C:/x/hooks/bar.sh" "$PROBE_SID-jit1")"
  assert_context "memory edit points at harness-memory" "$G" 'harness-memory' "$(jitp "C:/x/memory/foo.md" "$PROBE_SID-jit1")"
  assert_context "sched-task infra points at PORTABILITY" "$G" 'PORTABILITY\.md' "$(jitp "C:/x/scripts/register-hidden-task.ps1" "$PROBE_SID-jit2")"
  assert_context "unrelated file stays quiet"           "$G" EMPTY "$(jitp "C:/x/scripts/other.sh" "$PROBE_SID-jit3")"
  assert "never denies"                                 "$G" pass "$(jitp "C:/x/hooks/foo.sh" "$PROBE_SID-jit4")"
  probe_state_clean
else
  skip_gate "$G"
fi

# ---------------------------------------------------------- library-version-sync-reminder.sh
# Two shapes pinned (2026-09-18): a branch DELETION is not a push (misfired on the
# hotfix/129.0.17 cleanup), and a release/hotfix push on a package.sh repo nudges the
# pipeline-result check -- a push is not a published package there (PROJ-15418).
G=library-version-sync-reminder.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  LR="$(cgmktemp -d "/tmp/gatefix-libsync.XXXXXX")"
  git -C "$LR" init -q -b release/1.0.0 2>/dev/null
  printf 'pipelines:\n  default:\n    - step:\n        script:\n          - bash package.sh\n' > "$LR/bitbucket-pipelines.yml"
  git -C "$LR" add -A 2>/dev/null; git -C "$LR" -c user.name=t -c user.email=t@t commit -q -m "PROJ-1: x" 2>/dev/null
  assert_block "release push on a package.sh repo nudges"  "$G" block "$(bash_payload_sid "git -C $LR push origin release/1.0.0" "$LR" "$PROBE_SID-lib")"
  assert_block "branch deletion stays silent"              "$G" pass  "$(bash_payload_sid "git -C $LR push origin --delete release/1.0.0" "$LR" "$PROBE_SID-lib")"
  assert_block "refspec deletion stays silent"             "$G" pass  "$(bash_payload_sid "git -C $LR push origin :release/1.0.0" "$LR" "$PROBE_SID-lib")"
  printf 'pipelines:\n  default:\n    - step:\n        script:\n          - dotnet test\n' > "$LR/bitbucket-pipelines.yml"
  assert_block "release push, no package.sh: silent"       "$G" pass  "$(bash_payload_sid "git -C $LR push origin release/1.0.0" "$LR" "$PROBE_SID-lib")"
else
  skip_gate "$G"
fi

# ------------------------------------------------------------------ output-secret-leak-gate.sh
# Output-side (PROJ-15426): the command was an ordinary GET, the RESPONSE held live keys.
G=output-secret-leak-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  assert_block "AWS key id in stdout"            "$G" block "$(resp_payload 'curl -s "$BB/pipelines_config/variables/"' 'AWS_ACCESS_KEY_ID = AKIAIOSFODNN7EXAMPLE')"
  assert_block "Octopus API key in stdout"       "$G" block "$(resp_payload 'curl -s x' 'OCTOPUS_CLI_API_KEY = API-''ABCDEFGHIJKLMNOPQRSTUVWXYZ12')"  # split literal: GitHub push protection blocks the public mirror on a whole fake key
  assert_block "cleartext Password JSON body"    "$G" block "$(resp_payload 'node probe.mjs' '{"ClientId":"x","Password":"hunter2!","Username":"u"}')"
  assert_block "escaped Password key"            "$G" block "$(resp_payload 'node probe.mjs' 'postData: {\"ProposedPassword\":\"hunter2!\"}')"
  assert_block "key NAMES only are fine"         "$G" pass  "$(resp_payload 'curl -s x | jq .key' 'AWS_ACCESS_KEY_ID (secured)\nOCTOPUS_CLI_API_KEY (PLAINTEXT)')"
  assert_block "the word password in prose"      "$G" pass  "$(resp_payload 'git log -1' 'PROJ-1: never print the test-user password')"
  assert_block "no tool_response at all"         "$G" pass  "$(bash_payload 'echo AKIAIOSFODNN7EXAMPLE')"
  # 2026-10-12: a ~/.bashrc read printed four QUOTED credentials and this gate stayed silent
  # (quoted values arrive as =\"..., PASSPHRASE was not a recognised name). Fake values.
  assert_block "quoted _pw assignment"           "$G" block "$(resp_payload 'grep pw ~/.bashrc' 'export claude_qa_3500_pw="Fake9=x1"')"
  assert_block "quoted PASSPHRASE assignment"    "$G" block "$(resp_payload 'grep KEY ~/.bashrc' 'export MONGO_SSH_KEY_PASSPHRASE="FakePassABC"')"
  assert_block "quoted placeholder stays silent" "$G" pass  "$(resp_payload 'cat README.md' 'export PGPASSWORD="<cleartext>"')"
else
  skip_gate "$G"
fi

# ----------------------------------------------- worktree-junction-remove-gate.sh
# `git worktree remove` follows a junction and empties its target (exporterplus main-clone
# node_modules, twice on 2026-10-21). Real junction via mklink /J; skipped if that fails.
G=worktree-junction-remove-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  WJ="$(cgmktemp -d "/tmp/gatefix-wtjunc.XXXXXX")"; mkdir -p "$WJ/target" "$WJ/wt/src"
  if cmd //c "mklink /J $(cygpath -w "$WJ/wt/node_modules") $(cygpath -w "$WJ/target")" >/dev/null 2>&1; then
    assert "wt-junction: remove --force, abs path"   "$G" deny "$(bash_payload_cwd "git -C /c/repo worktree remove --force $WJ/wt" "$WJ")"
    assert "wt-junction: remove, path relative to -C" "$G" deny "$(bash_payload_cwd "git -C \"$WJ\" worktree remove -f wt && echo ok" "/c")"
    assert "wt-junction: remove, relative to cwd"     "$G" deny "$(bash_payload_cwd 'git worktree remove wt' "$WJ")"
    assert "wt-junction: worktree list passes"       "$G" pass "$(bash_payload_cwd 'git worktree list' "$WJ")"
    rm "$WJ/wt/node_modules"
    assert "wt-junction: link removed -> passes"     "$G" pass "$(bash_payload_cwd "git worktree remove $WJ/wt" "$WJ")"
    # A link resolving INSIDE the tree (the harness repo tracks skills/ama/* -> ../ama-*) can't
    # empty anything outside it, so removing such a worktree must pass; the outside link above
    # still denies (worktree-default session, 2026-10-22: harness worktree removal was blocked).
    if cmd //c "mklink /J $(cygpath -w "$WJ/wt/inner") $(cygpath -w "$WJ/wt/src")" >/dev/null 2>&1; then
      assert "wt-junction: link INSIDE the tree passes" "$G" pass "$(bash_payload_cwd "git worktree remove $WJ/wt" "$WJ")"
      rm "$WJ/wt/inner"
    fi
  else
    skip=$((skip+1))
  fi
else
  skip_gate "$G"
fi

# ----------------------------------------------- notify-sound.sh: which background tasks mute the Stop ding
# A reminder watcher runs for the session's life and a TaskStop'd task gets no <status>
# notification -- both used to count as live work and silenced every later ding (2026-10-21).
# A genuinely running task still mutes it. NOTIFY_SOUND_DRY: decide + log, never play.
G=notify-sound.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  NS="$(cgmktemp -d "/tmp/gatefix-notify.XXXXXX")"
  printf '%s\n' \
    '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_W1","name":"Bash","input":{"command":"bash ~/.claude/scripts/reminder-watch.sh abc"}}]}}' \
    '{"type":"user","message":{"content":[{"tool_use_id":"toolu_W1","type":"tool_result"}]},"toolUseResult":{"backgroundTaskId":"wwatch01"}}' \
    '{"type":"user","message":{"content":[{"tool_use_id":"toolu_S1","type":"tool_result"}]},"toolUseResult":{"backgroundTaskId":"sstop001"}}' \
    '{"type":"user","message":{"content":[{"tool_use_id":"toolu_T1","type":"tool_result","content":"{\"message\":\"Successfully stopped task: sstop001 (x)\"}"}]}}' > "$NS/idle.jsonl"
  cp "$NS/idle.jsonl" "$NS/busy.jsonl"
  printf '%s\n' '{"type":"user","message":{"content":[{"tool_use_id":"toolu_B1","type":"tool_result"}]},"toolUseResult":{"backgroundTaskId":"bbusy001"}}' >> "$NS/busy.jsonl"
  ns_run() { jq -cn --arg t "$NS/$1.jsonl" '{session_id:"nstest00-x",transcript_path:$t}' \
    | CLAUDE_STATE_DIR="$NS/state" NOTIFY_SOUND_DRY=1 bash "$hooks/$G" stop >/dev/null 2>&1; tail -n 1 "$NS/state/logs/notify-sound.log"; }
  ns_chk() { case "$3" in *"$2"*) fail=$((fail+1)); printf 'FAIL  %-46s got=%s\n' "$1" "$3" ;; *) pass=$((pass+1)) ;; esac; }
  mkdir -p "$NS/state/logs"
  ns_chk "notify: watcher + stopped task -> dings" "suppressed" "$(ns_run idle)"
  l="$(ns_run busy)"; case "$l" in *"[bg-live: bbusy001] [suppressed]"*) pass=$((pass+1)) ;; *) fail=$((fail+1)); printf 'FAIL  %-46s got=%s\n' "notify: live task -> muted (only it)" "$l" ;; esac
else
  skip_gate "$G"
fi

# ----------------------------------------------- feedback-notices-check.sh: feedback-next.sh + ledger
# "Pick up the next feedback task" offers UNCHECKED (pre-existing) mail inside
# unansweredMaxAgeDays before Jira tickets; `set` takes a row out (2026-10-21: 17 of 28
# install-seeded mails had no ticket and no reply and were invisible). Throwaway ledger, fixed now.
G=feedback-notices-check.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  FB="$(cgmktemp -d "/tmp/gatefix-fbnext.XXXXXX")"; mkdir -p "$FB/state/notices"
  fbs="$harness/skills/ama-feedback-notices/scripts"
  printf '%s\n' "aaaaaaaaaaaaaaaa	2026-09-03	7714808	pre-existing" "bbbbbbbbbbbbbbbb	2025-08-01	1111111	pre-existing" \
    "cccccccccccccccc	2026-10-09	7739223	PROJ-15834" "dddddddddddddddd	2026-09-16	3455076	replied" > "$FB/state/notices/.feedback-notices-seen"
  printf 'PROJ-9999\tRef:1 - thing\tOpen\t2026-10-20T10:00:00\n' > "$FB/rows"
  fbn() { CLAUDE_STATE_DIR="$FB/state" FEEDBACK_NEXT_ROWS="$FB/rows" FEEDBACK_NEXT_NOW=1792627200 bash "$fbs/feedback-next.sh" "$@" 2>&1; }
  fb_chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL  %-46s want=%s got=%s\n' "$1" "$2" "$3"; fi; }
  fb_chk "fb-next: unchecked in window first"   "AUDIT 7714808" "$(fbn --claim s1 | cut -f1)"
  fb_chk "fb-next: >365 days, ticketed, replied hidden" "REF-7714808 PROJ-9999" "$(fbn | cut -f1 | tr '\n' ' ' | sed 's/ $//')"
  CLAUDE_STATE_DIR="$FB/state" bash "$fbs/feedback-notices-record.sh" set 7714808 PROJ-1 >/dev/null
  fb_chk "fb-next: set -> ticket claimed next"  "CLAIMED PROJ-9999" "$(fbn --claim s1 | cut -f1)"
  fb_chk "fb-ledger: set on unknown ref fails"  "1" "$(CLAUDE_STATE_DIR="$FB/state" bash "$fbs/feedback-notices-record.sh" set 424242 replied >/dev/null 2>&1; echo $?)"
else
  skip_gate "$G"
fi

# ----------------------------------------------- redact-secret.sh (not a gate; a throwaway HOME)
# A short/all-digit secret matches only standing alone (2026-10-21: a 6-digit code rewrote a
# transcript UUID), but a JSON escape before it still counts as a boundary -- transcripts are
# JSONL, so a code at a line start follows the `n` of `\n`.
G=redact-secret.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  RS="$(cgmktemp -d "/tmp/gatefix-redact.XXXXXX")"; mkdir -p "$RS/.claude/projects"
  printf '%s\n' '{"uuid":"ab990698-1111","t":"<total_tokens>14990698","m":"code:\n990698\nok","x":"a\t990698","y":"is 990698."}' > "$RS/.claude/projects/s.jsonl"
  HOME="$RS" bash "$hooks/$G" 990698 >/dev/null 2>&1
  rs_got="$(cat "$RS/.claude/projects/s.jsonl")"
  rs_want='{"uuid":"ab990698-1111","t":"<total_tokens>14990698","m":"code:\n[REDACTED-CREDENTIAL]\nok","x":"a\t[REDACTED-CREDENTIAL]","y":"is [REDACTED-CREDENTIAL]."}'
  if [ "$rs_got" = "$rs_want" ]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL  %-46s got=%s\n' "redact: glued kept, standalone+\\n+\\t redacted" "$rs_got"; fi
else
  skip_gate "$G"
fi

# ----------------------------------------------- pr-created-reviewer-dm-reminder.sh + pr-merge-watch.sh
# Merge-on-approval (2026-10-14). The hook must (a) still nudge the reviewer DM, (b) spawn the
# watcher with the slug, id and ORIGIN session id, (c) spawn nothing when the create failed.
# The watcher's verdicts run against fixture PR JSON (PR_WATCH_FIXTURE) with the merge POST
# faked (PR_WATCH_DRY_RUN) and all state under a throwaway CLAUDE_STATE_DIR: never the live
# marker dir, never a live reminder.
G=pr-created-reviewer-dm-reminder.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  PW="$(cgmktemp -d "/tmp/gatefix-prwatch.XXXXXX")"
  mkdir -p "$PW/home/.claude/skills/ama-bitbucket-api/scripts"
  # Minimal config, not a copy of the live one: the hook only needs a reviewer to name, and the
  # mutation tree (mutate-gates.sh seed_harness) carries no harness-config.json.
  printf '{"bitbucket":{"defaultPrReviewers":[{"name":"Reviewer One","uuid":"{00000000-0000-0000-0000-000000000000}"}]},"audiences":{"people":[]}}' > "$PW/home/.claude/harness-config.json"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s/spawned.txt"\n' "$PW" > "$PW/home/.claude/skills/ama-bitbucket-api/scripts/pr-merge-watch.sh"
  pr_create_p() { jq -n --arg r "$1" '{tool_name:"Bash",hook_event_name:"PostToolUse",session_id:"probe-sid-77",tool_input:{command:"bash ~/.claude/skills/ama-library-version-sync/scripts/create-bitbucket-pr.sh yourproduct-backbone feature/x master t \"why why why why why why why why why why why why why why why why why\""},tool_response:{stdout:$r,stderr:""}}'; }
  # Under the REAL HOME the hook would spawn a real watcher for this fake PR (it did once,
  # 2026-10-14: 14 days of 404 polls). The seam is mandatory here; the spawn cases use a stub.
  export PR_WATCH_NO_SPAWN=1
  assert_block "PR created: still nudges the DM"   "$G" block "$(pr_create_p 'https://bitbucket.org/yourorg/yourproduct-backbone/pull-requests/77')"
  unset PR_WATCH_NO_SPAWN
  rm -f "$PW/spawned.txt"
  printf '%s' "$(pr_create_p 'https://bitbucket.org/yourorg/yourproduct-backbone/pull-requests/77')" | HOME="$PW/home" bash "$hooks/$G" >/dev/null 2>&1; sleep 1
  if [ "$(tr '\n' ' ' < "$PW/spawned.txt" 2>/dev/null)" = "yourproduct-backbone 77 --sid probe-sid-77 " ]; then pass=$((pass+1)); else
    fail=$((fail+1)); printf 'FAIL  %-46s got=%s\n' "watcher spawned with slug, id, origin sid" "$(tr '\n' ' ' < "$PW/spawned.txt" 2>/dev/null)"; fi
  rm -f "$PW/spawned.txt"
  printf '%s' "$(pr_create_p 'ERROR: {"message":"nope"}')" | HOME="$PW/home" bash "$hooks/$G" >/dev/null 2>&1; sleep 1
  if [ ! -f "$PW/spawned.txt" ]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL  %-46s\n' "failed create spawns no watcher"; fi
  W="$harness/skills/ama-bitbucket-api/scripts/pr-merge-watch.sh"
  pw_fx() { printf '%s' "$2" > "$PW/$1.json"; }
  pw_fx approved  '{"state":"OPEN","participants":[{"role":"REVIEWER","approved":true,"state":"approved","user":{"display_name":"A"}}]}'
  pw_fx pending   '{"state":"OPEN","participants":[{"role":"REVIEWER","approved":false,"state":null,"user":{"display_name":"A"}}]}'
  pw_fx changes   '{"state":"OPEN","participants":[{"role":"REVIEWER","approved":true,"state":"approved","user":{"display_name":"A"}},{"role":"REVIEWER","approved":false,"state":"changes_requested","user":{"display_name":"B"}}]}'
  pw_fx nonreview '{"state":"OPEN","participants":[{"role":"PARTICIPANT","approved":true,"state":"approved","user":{"display_name":"R"}}]}'
  pw_fx merged    '{"state":"MERGED","participants":[]}'
  pw_fx declined  '{"state":"DECLINED","participants":[]}'
  pw_fx error     '{"type":"error","error":{"message":"boom"}}'
  # Approved with a source tip: the commit-statuses read decides whether the merge is even
  # attempted (2026-10-21, spark-jobs PR #39 refused mid-build). INPROGRESS -> exit 5, no POST;
  # SUCCESSFUL / no statuses -> the merge proceeds; a stale INPROGRESS past the ceiling -> proceeds.
  pw_fx tipped    '{"state":"OPEN","source":{"commit":{"hash":"abc123def456"}},"participants":[{"role":"REVIEWER","approved":true,"state":"approved","user":{"display_name":"A"}}]}'
  pw_fx st_run    '{"values":[{"state":"SUCCESSFUL","key":"old"},{"state":"INPROGRESS","key":"default"}]}'
  pw_fx st_green  '{"values":[{"state":"SUCCESSFUL","key":"default"}]}'
  # Config pinned to a fixture: the live .fleetOwners would make yourproduct-backbone owner-gated.
  pw_fx cfg_none  '{"user":{"email":"gates@example.com"},"bitbucket":{"org":"yourorg","selfUuid":"{self}"}}'
  pw_fx cfg_owner '{"user":{"email":"gates@example.com"},"bitbucket":{"org":"yourorg","selfUuid":"{self}"},"fleetOwners":{"etl":{"name":"Reviewer One","bitbucketUuid":"{ali}"},"app":{"name":"Me","bitbucketUuid":"{self}"}}}'
  PW_CFG=cfg_none; PW_FLEETS=""
  pw_rc() { HR_CONFIG_FILE="$PW/$PW_CFG.json" FLEET_OWNER_FLEETS="$PW_FLEETS" CLAUDE_STATE_DIR="$PW/state" PR_WATCH_FIXTURE="$PW/$1.json" PR_WATCH_STATUS_FIXTURE="${2:+$PW/$2.json}" PR_WATCH_BUILD_MAX="${3:-7200}" PR_WATCH_DRY_RUN=1 bash "$W" yourproduct-backbone 999 --once --sid probe >/dev/null 2>&1; echo $?; }
  pw_case() { if [ "$(pw_rc "$1" "${3:-}" "${4:-}")" = "$2" ]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL  %-46s want=%s got=%s\n' "watch: $1${3:+ + $3} [$PW_CFG ${PW_FLEETS:-}]" "$2" "$(pw_rc "$1" "${3:-}" "${4:-}")"; fi; }
  pw_case approved 0; pw_case pending 3; pw_case changes 3; pw_case nonreview 3; pw_case merged 0; pw_case declined 2; pw_case error 4
  pw_case tipped 5 st_run; pw_case tipped 0 st_green; pw_case tipped 0; pw_case tipped 0 st_run 0
  # Fleet owner (2026-10-28): in a fleet the user does not own, only the OWNER's approval merges.
  pw_fx by_other '{"state":"OPEN","participants":[{"role":"REVIEWER","approved":true,"state":"approved","user":{"display_name":"Reviewer Two","uuid":"{ajay}"}}]}'
  pw_fx by_owner '{"state":"OPEN","participants":[{"role":"REVIEWER","approved":true,"state":"approved","user":{"display_name":"Reviewer One","uuid":"{ali}"}}]}'
  PW_CFG=cfg_owner; PW_FLEETS=etl
  pw_case by_other 3; pw_case by_owner 0
  PW_FLEETS=app; pw_case by_other 0
  PW_FLEETS="etl app"; pw_case by_other 3
  PW_CFG=cfg_none; PW_FLEETS=""
  if grep -q 'build still running' "$PW/state/prs/yourproduct-backbone-999.log" 2>/dev/null; then pass=$((pass+1)); else
    fail=$((fail+1)); printf 'FAIL  %-46s\n' "in-progress build is logged as a wait, not a refusal"; fi
  if grep -q 'MERGED on approval' "$PW/state/reminders/pending/"*.rem 2>/dev/null; then pass=$((pass+1)); else
    fail=$((fail+1)); printf 'FAIL  %-46s\n' "merge queues a durable reminder"; fi
  # --post-merge (user rule 2026-10-28): recorded work -> the merge reminder forbids the ticket
  # move and names the session + resume command; none recorded -> generic transition list.
  if grep -q 'ticket transition per commit-ticket rules' "$PW/state/reminders/pending/"*.rem 2>/dev/null; then pass=$((pass+1)); else
    fail=$((fail+1)); printf 'FAIL  %-46s\n' "no post-merge record -> generic transition list"; fi
  rm -f "$PW/state/reminders/pending/"*.rem
  printf 'edge-headers-session cd ~/Repos/AMA_APP && claude -r probe-pm-sid-1234\n' > "$PW/sessions.txt"
  CLAUDE_STATE_DIR="$PW/state" bash "$W" yourproduct-backbone 998 --post-merge "leave PROJ-1 In Progress" >/dev/null 2>&1
  if [ $? = 2 ] && [ ! -f "$PW/state/prs/post-merge/yourproduct-backbone-998" ]; then pass=$((pass+1)); else
    fail=$((fail+1)); printf 'FAIL  %-46s\n' "--post-merge without --sid refused"; fi
  HR_CONFIG_FILE="$PW/cfg_none.json" CLAUDE_STATE_DIR="$PW/state" PR_WATCH_SESSIONS_FILE="$PW/sessions.txt" PR_WATCH_FIXTURE="$PW/approved.json" PR_WATCH_DRY_RUN=1 \
    bash "$W" yourproduct-backbone 998 --once --sid probe-pm-sid-1234 --post-merge "leave PROJ-1 In Progress" >/dev/null 2>&1
  pm_rem="$(cat "$PW/state/reminders/pending/"*.rem 2>/dev/null)"
  case "$pm_rem" in *'do NOT transition'*'edge-headers-session'*'leave PROJ-1 In Progress'*'claude -r probe-pm-sid-1234'*) pass=$((pass+1)) ;;
    *) fail=$((fail+1)); printf 'FAIL  %-46s got=%s\n' "post-merge record -> no transition, names session" "${pm_rem:0:200}" ;; esac
  case "$pm_rem" in *'ticket transition per commit-ticket rules'*) fail=$((fail+1)); printf 'FAIL  %-46s\n' "post-merge record drops generic transition" ;;
    *) pass=$((pass+1)) ;; esac
  if [ ! -f "$PW/state/prs/post-merge/yourproduct-backbone-998" ]; then pass=$((pass+1)); else
    fail=$((fail+1)); printf 'FAIL  %-46s\n' "post-merge record removed after merge"; fi
  if grep -q 'pr-watch-check.sh' "$hooks/on-prompt.sh"; then pass=$((pass+1)); else
    fail=$((fail+1)); printf 'FAIL  %-46s\n' "on-prompt sources pr-watch-check.sh"; fi
  rm -rf "$PW"
else
  skip_gate "$G"
fi

# ----------------------------------------------------- it-ticket-paste-format-check.sh
# IT tickets are pasted into a rich-text box that makes every newline a paragraph and
# renders no Markdown (2026-10-13). Clean shape passes; each paste-breaking shape blocks;
# a file outside IT Tickets is never inspected.
G=it-ticket-paste-format-check.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  ITB="$(cgmktemp -d "/tmp/gatefix-itticket.XXXXXX")"; mkdir -p "$ITB/IT Tickets"
  itw() { printf '%s\n' "$2" > "$ITB/IT Tickets/$1"; jq -nc --arg f "$ITB/IT Tickets/$1" '{tool_name:"Write",hook_event_name:"PostToolUse",tool_input:{file_path:$f,content:"x"}}'; }
  assert_block "paste-ready ticket is silent"       "$G" pass  "$(itw ok.md "$(printf '1. WHAT WE NEED\n\nOne long paragraph on a single line.\n\nCertificate X\n- Expired: 2026-07-09\n- Status: only cert\n\nGet-MpPreference\n\nSent from Claude (AI).')")"
  assert_block "hard-wrapped paragraph blocks"      "$G" block "$(itw wrap.md "$(printf 'A paragraph that was\nwrapped at 80 columns.')")"
  assert_block "markdown heading blocks"            "$G" block "$(itw head.md "$(printf '## 2. Why it matters\n\nText.')")"
  assert_block "indented label lines block"         "$G" block "$(itw ind.md "$(printf 'Certificate X\n\n  Expired: 2026-07-09')")"
  assert_block "pipe table blocks"                  "$G" block "$(itw tbl.md "$(printf '| a | b |')")"
  assert_reason "reason names the line"             "$G" 'line 2: hard-wrapped' "$(itw wrap2.md "$(printf 'A paragraph that was\nwrapped at 80 columns.')")"
  assert_block "file outside IT Tickets ignored"    "$G" pass  "$(jq -nc --arg f "$ITB/README.md" '{tool_name:"Write",tool_input:{file_path:$f}}')"
  if grep -q "$G" "$harness/settings.template.json" 2>/dev/null; then pass=$((pass+1)); else
    fail=$((fail+1)); printf 'FAIL  %-46s not registered in settings.template.json\n' "it-ticket format check is registered"; fi
  rm -rf "$ITB"
else
  skip_gate "$G"
fi

# ----------------------------------------------------- harness-config-unsynced-stop-gate.sh
# Stop gate: an OWN unpushed harness-config.json edit blocks the turn ending. Seams: HCFG_FILE
# / HCFG_COPY; the marker is per probe session under harness-state/harness/.
G=harness-config-unsynced-stop-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  HC="$(cgmktemp -d "/tmp/gatefix-hcfg.XXXXXX")"
  printf '{"a":1}' > "$HC/live.json"; printf '{"a":1}' > "$HC/synced.json"
  HSID="$PROBE_SID-hcfg"
  HMARK="$(hstate harness ".harness-config-edited-$HSID")"; HDEFER="$(hstate harness ".harness-config-sync-deferred-$HSID")"
  rm -f "$HMARK" "$HDEFER"
  stop_p() { jq -n --arg s "$HSID" --argjson a "$1" '{hook_event_name:"Stop",session_id:$s,stop_hook_active:$a}'; }
  export HCFG_FILE="$HC/live.json" HCFG_COPY="$HC/synced.json"
  assert_block "no marker: silent"                    "$G" pass  "$(stop_p false)"
  : > "$HMARK"
  assert_block "marker but in sync: silent"           "$G" pass  "$(stop_p false)"
  : > "$HMARK"; printf '{"a":2}' > "$HC/live.json"
  assert_block "own edit, unpushed: blocks the stop"  "$G" block "$(stop_p false)"
  assert_block "stop_hook_active retry passes"        "$G" pass  "$(stop_p true)"
  printf 'no VPN this session\n' > "$HDEFER"
  assert_block "deferred with a reason: context only" "$G" pass  "$(stop_p false)"
  if printf '%s' "$(stop_p false)" | bash "$hooks/$G" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // ""' | grep -q 'no VPN this session'; then
    pass=$((pass+1))
  else
    fail=$((fail+1)); printf 'FAIL  %-46s\n' "deferral reason is echoed as context"
  fi
  rm -f "$HMARK" "$HDEFER"; unset HCFG_FILE HCFG_COPY
else
  skip_gate "$G"
fi

# ------------------------------------------------------------- alwaysloaded-size-gate.sh
# PROJ-15364: size counter-pressure on the always-loaded surfaces besides AGENTS.md.
# Real files, limits forced low via the env seams (same approach as the readme-currency
# size block above).
G=alwaysloaded-size-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  alsz() { jq -n --arg p "$1" '{tool_name:"Edit",tool_input:{file_path:$p,new_string:"x"}}'; }
  real_h="${real_harness:-$harness}"
  CLAUDEMD_SIZE_LIMIT=1 assert_reason "CLAUDE.md over limit nudges" "$G" 'injected whole' "$(alsz "$real_h/CLAUDE.md")"
  assert_block "CLAUDE.md under default limit quiet" "$G" pass "$(alsz "$real_h/CLAUDE.md")"
  MEMORY_COUNT_LIMIT=1 assert_reason "memory count over limit nudges" "$G" 'pointer line' "$(alsz "$real_h/memory/clientcorp-cc-contactone.md")"
  assert_block "memory under default count quiet"    "$G" pass "$(alsz "$real_h/memory/clientcorp-cc-contactone.md")"
  SKILL_DESC_LIMIT=10 assert_reason "long skill description nudges" "$G" 'trigger phrases' "$(alsz "$real_h/skills/commit-ticket/SKILL.md")"
  assert_block "description under default quiet"     "$G" pass "$(alsz "$real_h/skills/commit-ticket/SKILL.md")"
  assert_block "unrelated harness file quiet"        "$G" pass "$(alsz "$real_h/hooks/on-stop.sh")"
else
  skip_gate "$G"
fi

# --------------------------------------------------- dotnet-build-memory-wait.sh
# Waits ONLY when memory is tight AND another build client is running; both seams are
# canned so no case depends on the box. The wait case bounds itself at 2s so the suite
# stays fast; what it asserts is that the hook speaks after a wait and never before one.
G=dotnet-build-memory-wait.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  dbw() { jq -nc --arg s "$PROBE_SID" --arg c "$1" '{hook_event_name:"PreToolUse",tool_name:"Bash",session_id:$s,tool_input:{command:$c}}'; }
  AMA_BUILD_WAIT_FREE_MB=20000 AMA_DOTNET_INFLIGHT=3 AMA_BUILD_WAIT_MAX_SECS=2 AMA_BUILD_WAIT_POLL_SECS=1 \
    assert_context "plenty of memory: no wait despite other builds" "$G" EMPTY "$(dbw 'dotnet test C:/x/y.csproj')"
  AMA_BUILD_WAIT_FREE_MB=1000 AMA_DOTNET_INFLIGHT=0 AMA_BUILD_WAIT_MAX_SECS=2 AMA_BUILD_WAIT_POLL_SECS=1 \
    assert_context "tight memory but nothing to wait for" "$G" EMPTY "$(dbw 'dotnet build')"
  AMA_BUILD_WAIT_FREE_MB=1000 AMA_DOTNET_INFLIGHT=2 AMA_BUILD_WAIT_MAX_SECS=2 AMA_BUILD_WAIT_POLL_SECS=1 \
    assert_context "tight memory + other build: waits, then proceeds" "$G" 'waited [0-9]+s .* 1000 MB .* 2 other' "$(dbw 'cd C:/x && dotnet test')"
  AMA_BUILD_WAIT_FREE_MB=1000 AMA_DOTNET_INFLIGHT=2 AMA_BUILD_WAIT_MAX_SECS=2 AMA_BUILD_WAIT_POLL_SECS=1 \
    assert_context "a mention is not a build" "$G" EMPTY "$(dbw 'grep -n "dotnet test" skills/ama-api-tests/SKILL.md')"
  AMA_BUILD_WAIT_FREE_MB=1000 AMA_DOTNET_INFLIGHT=2 AMA_BUILD_WAIT_MAX_SECS=2 AMA_BUILD_WAIT_POLL_SECS=1 \
    assert_context "never denies" "$G" EMPTY "$(dbw 'dotnet --info')"
  if grep -q "$G" "$hooks/dispatch-pre-bash.manifest" 2>/dev/null; then pass=$((pass+1)); else
    fail=$((fail+1)); printf 'FAIL  %-46s not in dispatch-pre-bash.manifest\n' "memory-wait hook is dispatched"; fi
  # A wait that outlives the Pre block's timeout gets the whole block killed, every gate
  # failing open (hook header). Two pairings must hold: the hook's DEFAULT fits under the
  # 120s a session older than the timeout change still has; the env value shipped beside the
  # longer timeout fits under THAT. Worst-case overshoot is one poll + probe (~16s); 34s more
  # is headroom for the other gates in the block.
  _bw_def="$(grep -oE 'AMA_BUILD_WAIT_MAX_SECS:-[0-9]+' "$hooks/$G" | grep -oE '[0-9]+$')"
  _bw_env="$(jq -r '.env.AMA_BUILD_WAIT_MAX_SECS // empty' "$harness/settings.template.json" 2>/dev/null | tr -d '\r')"
  _bw_to="$(jq -r '.hooks.PreToolUse[] | select(.matcher=="Bash|PowerShell") | .hooks[0].timeout' "$harness/settings.template.json" 2>/dev/null | tr -d '\r')"
  if [ -n "$_bw_def" ] && [ $((_bw_def + 50)) -le 120 ]; then pass=$((pass+1)); else
    fail=$((fail+1)); printf 'FAIL  %-46s default=%s (+50 > 120)\n' "default wait fits a pre-change session" "$_bw_def"; fi
  if [ -n "$_bw_env" ] && [ -n "$_bw_to" ] && [ $((_bw_env + 50)) -le "$_bw_to" ]; then pass=$((pass+1)); else
    fail=$((fail+1)); printf 'FAIL  %-46s env=%s block=%s\n' "env wait fits the shipped block timeout" "$_bw_env" "$_bw_to"; fi
else
  skip_gate "$G"
fi

# ------------------------------------------------------------- test-complete-tester-gate.sh
# A ticket the TESTER moved out of Ready to Test is closed by the tester (user rule 2026-10-05,
# PROJ-15417). Deny a Test Complete transition when the changelog shows such a bounce by
# another account; a bounce by the user's own account, a ticket nobody bounced, or any other
# destination passes. Fails closed without a token. Jira is never reached: the transitions list
# and the changelog come in through TCG_TRANSITIONS_FILE / TCG_CHANGELOG_FILE.
G=test-complete-tester-gate.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  TCG="$(cgmktemp -d "/tmp/gatefix-tcg.XXXXXX")"
  printf '{"atlassian":{"cloudId":"h"},"user":{"email":"e","jiraAccountId":"me-1"}}' > "$TCG/cfg.json"
  printf '{"transitions":[{"id":"291","to":{"name":"Test Complete"}},{"id":"431","to":{"name":"Ready to Test"}}]}' > "$TCG/trs.json"
  tcg_log() { printf '{"values":[{"author":{"accountId":"%s","displayName":"%s"},"created":"2026-09-29T13:12:00.000+0000","items":[{"field":"status","fromString":"%s","toString":"%s"}]}]}' "$1" "$2" "$3" "$4" > "$TCG/log.json"; }
  T_OLDTOK="${ATLASSIAN_API_TOKEN:-}"; export ATLASSIAN_API_TOKEN="${ATLASSIAN_API_TOKEN:-probe}" HR_CONFIG_FILE="$TCG/cfg.json"
  export TCG_TRANSITIONS_FILE="$TCG/trs.json" TCG_CHANGELOG_FILE="$TCG/log.json"
  tc_call='bash "$HOME/.claude/skills/ama-jira-api/scripts/jira-transition-issue.sh" PROJ-9999 291'
  rtt_call2='bash "$HOME/.claude/skills/ama-jira-api/scripts/jira-transition-issue.sh" PROJ-9999 431'
  tcg_log tester-1 "<uiTesterName> Segers" "Ready to Test" "To Do"
  assert "tester bounce -> Test Complete denied"      "$G" deny "$(bash_payload "$tc_call")"
  assert_reason "deny names the tester and the bounce" "$G" '<uiTesterName> Segers: Ready to Test -> To Do.*Ready to Test instead' "$(bash_payload "$tc_call")"
  assert "tester bounce -> Ready to Test passes"      "$G" pass "$(bash_payload "$rtt_call2")"
  tcg_log tester-1 "<uiTesterName> Segers" "Ready to Test" "Test Complete"
  assert "tester's own Test Complete is not a bounce" "$G" pass "$(bash_payload "$tc_call")"
  tcg_log me-1 "Your Name" "Ready to Test" "In Progress"
  assert "own move out of RTT is not a bounce"        "$G" pass "$(bash_payload "$tc_call")"
  tcg_log tester-1 "<uiTesterName> Segers" "QA" "Ready to Test"
  assert "tester moving INTO RTT is not a bounce"     "$G" pass "$(bash_payload "$tc_call")"
  assert "prose mention of the script passes"        "$G" pass "$(bash_payload 'cat ~/.claude/skills/ama-jira-api/scripts/jira-transition-issue.sh')"
  tcg_log tester-1 "<uiTesterName> Segers" "Ready to Test" "Failed Test"
  assert "id not offered denies (fails closed)"      "$G" deny "$(bash_payload 'bash "$HOME/.claude/skills/ama-jira-api/scripts/jira-transition-issue.sh" PROJ-9999 999')"
  ATLASSIAN_API_TOKEN= assert "no token denies (fails closed)" "$G" deny "$(bash_payload "$tc_call")"
  export ATLASSIAN_API_TOKEN="$T_OLDTOK"; unset HR_CONFIG_FILE TCG_TRANSITIONS_FILE TCG_CHANGELOG_FILE
else
  skip_gate "$G"
fi

# ------------------------------------------------ octopus-staging-cache-update-reminder.sh
# PostToolUse nudge. Trigger B used to fire for hotfix/* pushes only; since 2026-10-05 the
# cache rule is environment-blind, so release/* (Staging) and develop (QA) pushes nudge too.
# With no reflog to diff (the fixture repo does not exist) the hook falls back to its
# decision-nudge, which is what names the environment -- the part asserted here.
G=octopus-staging-cache-update-reminder.sh
if want_gate "$G" && [ -f "$hooks/$G" ]; then
  # A real (empty) repo: the hook exits silently when `-C <path>` is not a directory, and an
  # initialised repo with no origin reflog is exactly the "could not diff" fallback case.
  CUR="$(cgmktemp -d "/tmp/gatefix-cu.XXXXXX")"; git -C "$CUR" init -q 2>/dev/null
  _cu() { jq -n --arg c "$1" --arg d "$CUR" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d,tool_response:{stdout:"",stderr:""}}'; }
  assert_reason "hotfix push nudges Staging"  "$G" 'against Staging' "$(_cu "git -C $CUR push origin hotfix/129.0.21")"
  assert_reason "release push nudges Staging" "$G" 'against Staging' "$(_cu "git -C $CUR push -q origin HEAD:release/130.0.0")"
  assert_reason "develop push nudges QA"      "$G" 'against QA'      "$(_cu "git -C $CUR push -q origin HEAD:develop")"
  assert "push of a feature branch is silent" "$G" pass "$(_cu "git -C $CUR push origin feature/x")"
  assert "a develop checkout is not a push"   "$G" pass "$(_cu "git -C $CUR checkout develop")"
  # The diff discriminator must name search's result post-processing and fieldtablemapper too
  # (user rule 2026-10-05): the cache stores the processed result, so a Services/Domain change
  # alters cached values with no builder diff. Static pin on the pattern line, which lives in
  # lib-sql-emitting-paths.sh since 2026-10-15 (shared with release-preflight's shape sweep).
  _cup="$(grep -E '^SQL_EMITTING_PATHS=' "$hooks/lib-sql-emitting-paths.sh")"
  for _need in 'Search\\.Domain' 'Services' 'FieldTableMapper'; do
    if printf '%s' "$_cup" | grep -q -- "$_need"; then pass=$((pass+1)); else
      fail=$((fail+1)); printf 'FAIL  %-46s PATTERN lacks %s\n' "cache pattern covers result code + mappings" "$_need"
    fi
  done
  # sql_emitting_diff: a builder path, AND a Search.Shared pin bump with no path match (a
  # consumer's hotfix ships new SQL that way -- PROJ-15801's resultsprocessor), but not a
  # change elsewhere in the same csproj.
  SED="$(cgmktemp -d "/tmp/gatefix-sed.XXXXXX")"
  _sg() { git -C "$SED" -c user.email=t@t -c user.name=t "$@" >/dev/null 2>&1; }
  _sg init -q; mkdir -p "$SED/YourCompany.Product.Search.Shared/Builders/Select"
  printf '<PackageReference Include="YourCompany.Product.Search.Shared" Version="19.2.0.207" />\n<PackageReference Include="Other" Version="1.0" />\n' > "$SED/a.csproj"
  echo x > "$SED/readme.md"; _sg add -A; _sg commit -qm base; _b0="$(git -C "$SED" rev-parse HEAD)"
  sed -i 's/Other" Version="1.0"/Other" Version="1.1"/' "$SED/a.csproj"; echo y >> "$SED/readme.md"; _sg commit -qam other; _b1="$(git -C "$SED" rev-parse HEAD)"
  sed -i 's/19.2.0.207/19.2.0.213/' "$SED/a.csproj"; _sg commit -qam pin; _b2="$(git -C "$SED" rev-parse HEAD)"
  echo c > "$SED/YourCompany.Product.Search.Shared/Builders/Select/SqlSelectBuilder.cs"; _sg add -A; _sg commit -qm builder; _b3="$(git -C "$SED" rev-parse HEAD)"
  _sed() { ( . "$hooks/lib-sql-emitting-paths.sh"; sql_emitting_diff "$SED" "$1" "$2" ); }
  mkdir -p "$SED/YourCompany.Product.Search.Shared.Tests/SqlParse/Fixtures"; echo '[]' > "$SED/YourCompany.Product.Search.Shared.Tests/SqlParse/Fixtures/sqltemplates-Loan.json"
  _sg add -A; _sg commit -qm testfixture; _b4="$(git -C "$SED" rev-parse HEAD)"
  _r0="$(_sed "$_b0" "$_b1")"; _r1="$(_sed "$_b1" "$_b2")"; _r2="$(_sed "$_b2" "$_b3")"; _r3="$(_sed "$_b3" "$_b4")"
  if [ -z "$_r3" ]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL  %-46s got=%s\n' "sql_emitting_diff: test-project fixture silent" "$_r3"; fi
  if [ -z "$_r0" ]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL  %-46s got=%s\n' "sql_emitting_diff: unrelated change silent" "$_r0"; fi
  case "$_r1" in *Search.Shared*package*) pass=$((pass+1)) ;; *) fail=$((fail+1)); printf 'FAIL  %-46s got=%s\n' "sql_emitting_diff: Search.Shared pin bump" "${_r1:-none}" ;; esac
  case "$_r2" in *Builders/Select/SqlSelectBuilder.cs*) pass=$((pass+1)) ;; *) fail=$((fail+1)); printf 'FAIL  %-46s got=%s\n' "sql_emitting_diff: builder path" "${_r2:-none}" ;; esac
else
  skip_gate "$G"
fi

# ------------------------------------------------------ meta: no live-$HOME mutation in here
# 2026-08-20: a case appended to the LIVE harness-gaps.md and `sed -i`'d it back, turning the
# ~/.claude symlink into a plain file. Source-grep this suite (the ORIGINAL, not the temp copy)
# for in-place edits / appends aimed at ~/.claude outside the scratch-HOME blocks.
_self="${CHECK_GATES_SRC:-${BASH_SOURCE[0]}}"
if grep -nE '(sed|perl) +-[a-zA-Z]*i[a-zA-Z]* .*\$HOME/\.claude/[A-Za-z]|>> *"?\$HOME/\.claude/(harness-gaps|AGENTS|CLAUDE|settings|harness-config)' "$_self" | grep -v 'grep -nE' >/dev/null; then
  fail=$((fail+1)); printf 'FAIL  %-46s see the meta-test at the end of this file\n' "suite mutates a live ~/.claude file"
else
  pass=$((pass+1))
fi

# ---- suite-level: live_session_count, the load check run-check-gates-full.sh refuses on ---
# The suite is fork-heavy and its cases fail spuriously under contention, yet nothing
# measured load until 2026-09-14 -- a full pass got launched while several sessions were
# live and the user was mid-/exit. CLAUDE_PROJECTS_DIR is the seam lib-session-liveness.sh
# already carries so liveness can be tested without touching real session state.
if [ -r "$real_harness/hooks/lib-session-liveness.sh" ]; then
  _lc_dir="$(cgmktemp -d "/tmp/gatefix-live.XXXXXX")"
  mkdir -p "$_lc_dir/projA" "$_lc_dir/projB/subagents" 2>/dev/null
  : > "$_lc_dir/projA/aaaaaaaa.jsonl"
  : > "$_lc_dir/projB/bbbbbbbb.jsonl"
  : > "$_lc_dir/projB/subagents/cccccccc.jsonl"   # subagent transcripts never count
  : > "$_lc_dir/projA/old.jsonl"; touch -d '2 hours ago' "$_lc_dir/projA/old.jsonl" 2>/dev/null
  _lc_got="$( . "$real_harness/hooks/lib-session-liveness.sh" >/dev/null 2>&1
              CLAUDE_PROJECTS_DIR="$_lc_dir" live_session_count 600 )"
  if [ "${_lc_got:-x}" = "2" ]; then pass=$((pass+1)); else
    fail=$((fail+1))
    printf 'FAIL  %-46s want=2 live got=%s\n' "live_session_count ignores stale+subagent" "${_lc_got:-none}"
  fi
fi

# ---- suite-level: mutate-gates.sh must seed every $harness/<file> this suite reads -------
# 2026-09-14: seed_harness never copied settings.template.json, so the "hook is registered"
# assertion failed for EVERY gate inside the mutation tree and its baseline could never be
# green -- mutate-gates.sh aborted on every invocation, silently useless, while THIS suite
# stayed green against the real tree that does have the file. Measured 619/1-failed there vs
# 637/0 here. Nothing forced the two trees to agree; this does. Suite-level on purpose: it is
# about the suite's own testability, so it must run under every filter.
_sp_missing=""
for _sp_f in $(grep -oE '\$harness/[A-Za-z0-9_.-]+' "$real_harness/scripts/check-gates.sh" 2>/dev/null \
               | sed 's|^\$harness/||' | sort -u); do
  grep -qF -- "$_sp_f" "$real_harness/scripts/mutate-gates.sh" 2>/dev/null \
    || _sp_missing="$_sp_missing $_sp_f"
done
if [ -z "$_sp_missing" ]; then
  pass=$((pass+1))
else
  fail=$((fail+1))
  printf 'FAIL  %-46s mutate-gates.sh seed_harness never copies:%s\n' \
    "suite reads files the mutation tree lacks" "$_sp_missing"
fi

# Timing verdicts were recorded from inside captures (gate_timing_check) -- count them here.
while IFS= read -r _g; do [ -n "$_g" ] && fail=$((fail+1)); done < "$_gt_file"
rm -f "$_gt_file"; unset _g

if [ -n "$ONLY" ]; then
  printf '\ncheck-gates: %d passed, %d failed, %d skipped  [--gate %s: %d matched, %d filtered out]\n' \
    "$pass" "$fail" "$skip" "$ONLY" "$gates_matched" "$gates_filtered"
  # ~23 assertions are suite-level rather than gate-scoped (the mutates-a-live-file
  # meta-test, the harness-gaps runner, set-session-ticket) and deliberately still run under
  # a filter -- they check the suite's own integrity, so silently skipping them would be
  # worse than the ~30s they cost. Said out loud because otherwise the pass count looks like
  # it belongs to the filtered gate.
  printf 'check-gates: some assertions are suite-level, not gate-scoped, and always run (~30s floor).\n'
  # A filter that matches nothing must never look like a green run -- that is the one way
  # this feature could make things worse than no filter at all.
  if [ "$gates_matched" -eq 0 ]; then
    printf 'check-gates: --gate %s matched NO gate -- nothing was asserted. Check the name against `grep -oE "^G=.*" %s`.\n' \
      "$ONLY" "$(basename "${CHECK_GATES_SRC:-check-gates.sh}")" >&2
    exit 1
  fi
else
  printf '\ncheck-gates: %d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
fi
[ "$fail" -eq 0 ]
