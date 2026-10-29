#!/usr/bin/env bash
# PreToolUse hook (Bash): deny a BACKGROUNDED command that pipes its output into tail/head/tr.
#
# Those filters buffer when stdout isn't a terminal, so a long background run shows NOTHING while
# it runs and loses EVERYTHING if it's killed or dies. Confirmed three times in one session
# (2026-08-18/19): a 20-minute mutation pass piped through `tail -20` died mid-flight leaving a
# 0-byte output file, twice; then a WSL probe piped through `tr -d '\0'` hung with an empty log and
# had to be killed blind. Cost ~40 minutes total.
#
# Rule now lives in [[bash-command-correctness]] (moved out of bash-command-style; see below).
# Why a hook and not the skill line. `bash-command-style` documented this trap the same morning I
# then broke it three times. Its retrieval description is about PERMISSION PROMPTS ("how to shape a
# command so it doesn't trigger an avoidable prompt"), so nothing surfaces it when the task is
# "run a long job in the background" -- and at 239 lines one trap competes with seventeen others.
# Same session, same agent: the four GATED command rules blocked me 5 times and I adapted every
# time; this ungated prose rule failed 3/3. That is CLAUDE.md's "mechanical triggers over
# self-recognition" measured, and the conclusion is a gate.
#
# Keys off the BACKGROUND FLAG, not the pipe. A foreground `| tail` is correct and extremely
# common (it's how you read the end of a file); denying pipes generally would be a constant false
# positive. Only `run_in_background: true` + a buffering filter is the broken combination.
set -u

IFS= read -r -d '' payload || true
# Cheap raw-payload prefilter before any jq fork (precedent: git-commit-ticket-gate.sh): the rule
# needs BOTH a background flag and a pipe, so a payload without "run_in_background" exits on zero
# forks. ~60ms/fork on this machine.
case "$payload" in *run_in_background*) ;; *) exit 0 ;; esac

bg="$(printf '%s' "$payload" | jq -r '.tool_input.run_in_background // false' 2>/dev/null)"
[ "$bg" = "true" ] || exit 0

command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' | tr -d '\r')"
[ -n "$command" ] || exit 0

# The buffering filters, as a real pipe stage: `| tail`, `| head`, `| tr`. Deliberately NOT `grep`
# -- `grep --line-buffered` is the documented correct way to stream a filtered background feed
# (see the Monitor tool's own guidance), so grep is a legitimate background pipe.
hit="$(printf '%s' "$command" | grep -oP '\|\s*\K(tail|head|tr)\b' | head -1)"
[ -n "$hit" ] || exit 0

jq -cn --arg f "$hit" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: ("Backgrounded command pipes into `" + $f + "`, which BUFFERS when stdout is not a terminal: nothing is readable while the job runs, and if it is killed or dies you lose every line it produced. Hit three times in one session -- a 20-minute mutation pass and a WSL probe both ended with 0-byte output. Redirect to a log instead and read the log: `<command> > scratch/x.log 2>&1` with run_in_background, then `cat`/`Read` that file (or a Monitor on it). If you genuinely need a streaming filter, `grep --line-buffered` flushes per line and is allowed here.")
  }
}'
