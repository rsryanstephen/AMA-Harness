#!/usr/bin/env bash
# PreToolUse hook (Bash/PowerShell). DENIES an unfiltered `check-gates.sh` run, and a bare
# argumentless `mutate-gates.sh` run.
#
# Why a gate and not a nudge: AGENTS.md:1125 and GATES-AND-HOOKS.md:37 BOTH already say in
# bold to run the suite filtered, and a session read both and ran it unfiltered anyway
# (2026-09-14, this gate's own origin) -- ten minutes backgrounded to test a one-gate edit.
# CLAUDE.md's "Mechanical Triggers Over Self-Recognition" is the governing rule. Costs:
#   filtered, one gate        ~10s  (`--gate` / CHECK_GATES_ONLY)
#   unfiltered full pass      ~10min  (70 gates, 390 assert sites, ~615 assertions)
#   mutate-gates, bare        ~35min  (re-runs the whole suite once PER gate)
# The full pass is also the shape that got killed by a low-memory supervisor once, and its
# cases fail spuriously under fork contention (GATES-AND-HOOKS.md:60-66) -- so an accidental
# one wastes the time AND proves nothing.
#
# MATCHES AN INVOCATION, NOT A MENTION. The naive "payload contains check-gates.sh" test
# denies `cat`, `git diff`, `sed -n` and `grep` against the suite file -- including the gate
# recount command GATES-AND-HOOKS.md:74 tells agents to run. So the command is split into
# segments and each is judged by its VERB: only `bash|sh <path>check-gates.sh` or a direct
# `<path>check-gates.sh` counts. A read verb in front of the same path falls through.
#
# NOT AIRTIGHT, on purpose: a wrapper script that runs the suite internally is invisible here
# (the Bash-tool command is the wrapper's own name), so scripts/run-check-gates-full.sh --
# the sanctioned full-pass path, which also clears the reminder marker -- and
# scripts/mutate-gates.sh's internal suite runs are unaffected without needing an allowlist
# entry. Neither name contains the literal `check-gates.sh`.
set -u

IFS= read -r -d '' payload || true

# Cheap raw-payload needle before any jq fork (GATES-AND-HOOKS.md fork budget). Both script
# names share no substring with ordinary commands, so the steady path is zero forks.
case "$payload" in *check-gates*|*mutate-gates*) ;; *) exit 0 ;; esac

cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"
[ -n "$cmd" ] || exit 0

# Sanctioned filtered forms -- checked on the WHOLE command so an env-var prefix, a flag
# after a redirect, or either ordering all count.
case "$cmd" in
  *--gate*|*CHECK_GATES_ONLY*|*CHECK_GATES_FULL=1*) exit 0 ;;
esac

# DATA IS NOT A COMMAND. Both of the following tripped this gate on its first two live
# calls, and both are the "fixture text is not an invocation" class the sibling gates already
# guard (see harness-gaps.md, ready-to-test-regression-reminder.sh):
#   - a HEREDOC BODY: writing a test script that contains `bash scripts/check-gates.sh` as a
#     fixture string is not running it. Bodies are cut precisely (opener to terminator), so
#     real commands after the terminator are still scanned.
#   - a SINGLE-QUOTED SPAN: `t deny 'bash scripts/check-gates.sh'` passes the text as one
#     literal argument. Double-quoted spans are KEPT, because the real invocation form
#     `bash "$R/scripts/check-gates.sh"` lives in one. Known, accepted escape: an invocation
#     whose path is single-quoted (`bash 'scripts/check-gates.sh'`) is not seen.
# The awk deliberately contains NO quote characters of its own -- the heredoc terminator is
# isolated positionally and then scrubbed to word chars, which sidesteps both the shell
# quoting mess and the `\"`-in-a-bracket-expression warning gawk prints to stderr (a hook
# must stay silent on stderr).
clean="$(printf '%s\n' "$cmd" | awk '
  BEGIN { term = "" }
  {
    line = $0
    if (term != "") {
      t2 = line; sub(/;[ \t]*$/, "", t2); gsub(/^[ \t]+|[ \t]+$/, "", t2)
      if (t2 == term) { term = "" }
      next
    }
    p = index(line, "<<")
    if (p > 0) {
      tok = substr(line, p + 2)
      sub(/^-/, "", tok); sub(/^[ \t]+/, "", tok); sub(/[ \t].*$/, "", tok)
      gsub(/[^A-Za-z0-9_]/, "", tok)
      if (tok != "") { term = tok }
    }
    print line
  }' | sed -e "s/'[^']*'//g" | tr -d '\042')"

# Split on ; && || | into one segment per line, strip leading whitespace, then drop leading
# env-var assignments.
#
# The assignment stripper MUST accept an assignment that ends the segment ([[:space:]]+|$),
# not just one followed by a command. Caught on this gate's first live call: `C=/path/to/
# check-gates.sh; grep ... "$C"` left the whole assignment standing, and `C=/path/...
# check-gates.sh` is a single token ending in check-gates.sh, so a read-only grep got denied.
# A segment that is ONLY assignments strips to empty and matches nothing, which is right --
# naming the path in a variable is not running it.
# `\|` is never a pipe (escaped, or grep's alternation inside a double-quoted pattern, whose
# quotes are already gone): `grep -n "a\|HOME=\$" .../check-gates.sh` split there, stripped
# `HOME=\$` as an assignment and left the path as a segment's first token -> a read denied
# (2026-10-15). Accepted escape: `\\|` (literal backslash, then a real pipe) is not split.
segs="$(printf '%s\n' "$clean" \
  | sed -e 's/\\|/ /g' -e 's/&&/\n/g' -e 's/||/\n/g' -e 's/[;|]/\n/g' \
  | sed -e 's/^[[:space:]]*//' \
  | sed -E 's/^([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*([[:space:]]+|$))+//')"

# An invocation = the segment's FIRST token is the script, or is bash/sh running it.
inv_re='^([^[:space:]]*check-gates\.sh|(bash|sh)[[:space:]]+[^[:space:]]*check-gates\.sh)'

if printf '%s\n' "$segs" | grep -qE "$inv_re"; then
  reason='Unfiltered `check-gates.sh` run -- DENIED, this is ~10min over 70 gates and under fork contention its cases fail spuriously and prove nothing (it has been supervisor-killed before). Touched ONE gate? `bash scripts/check-gates.sh --gate <gate.sh>` (~10s, and suite-level assertions still run under a filter, so cross-file pins are covered). Genuinely want the full pass? `bash scripts/run-check-gates-full.sh` when the machine is quiet -- it also clears the full-run-owed reminder on green. Need it inline anyway? Re-run with CHECK_GATES_FULL=1.'
  jq -cn --arg r "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
fi

# mutate-gates.sh with no gate argument re-runs the whole suite once per gate (~35min).
# AGENTS.md:1128 says run it targeted; one gate name self-filters both of its passes.
mut_re='^([^[:space:]]*mutate-gates\.sh|(bash|sh)[[:space:]]+[^[:space:]]*mutate-gates\.sh)'
mut_seg="$(printf '%s\n' "$segs" | grep -E "$mut_re" | head -1)"

if [ -n "$mut_seg" ]; then
  # Bare = nothing after the script path that looks like a gate name.
  tail_args="${mut_seg#*mutate-gates.sh}"
  if ! printf '%s' "$tail_args" | grep -qE '[A-Za-z0-9._-]+\.sh'; then
    reason='Bare `mutate-gates.sh` with no gate name -- DENIED, that mutates EVERY gate the suite names and re-runs the whole suite per gate (~35min). Name the gate you touched: `bash scripts/mutate-gates.sh <gate.sh>` -- one argument self-filters both of its passes (~70s), per AGENTS.md:1128.'
    jq -cn --arg r "$reason" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $r
      }
    }'
  fi
fi

exit 0
