#!/usr/bin/env bash
# PROJ-15365: instruction-findability retrieval eval. Asks a fresh headless session,
# per sampled symptom, "where is the guidance?" and greps the answer for the doc/skill that
# actually holds it. A relocated rule nobody can find is write-only -- this is the only
# check that catches misfiling BEFORE it causes a rule-miss regression.
#
# Usage: findability-eval.sh [--self-test] [--model <m>]
#   --self-test  adds a control case whose expectation can never match, proving misses are
#                reported (a suite that can't fail is worse than no suite).
#   --model      headless model (default haiku -- pure retrieval, cheap tier per
#                resource-efficiency).
# Output: PASS/MISS per case + summary; exit 1 on any MISS. Log misses to harness-gaps.md
# yourself per its one-line convention -- the script never writes there (a scheduled/eval
# script appending to a reviewed ledger would bypass the session-attribution convention).
#
# Run cadence: on demand, and worth a pass during gap review after any doc restructure
# (AGENTS.md diet, section moves). ~9 haiku calls per run.
set -u

MODEL="haiku"
SELF_TEST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --self-test) SELF_TEST=1 ;;
    --model) shift; MODEL="${1:-haiku}" ;;
  esac
  shift
done

harness="$(git -C "$HOME/.claude/hooks" rev-parse --show-toplevel 2>/dev/null)"
[ -n "$harness" ] || { echo "cannot resolve harness root" >&2; exit 1; }

pass=0; miss=0

# ask <symptom> <expected-regex (grep -iE)>
ask() {
  local symptom="$1" want="$2" answer
  answer="$(cd "$harness" && claude -p --model "$MODEL" \
    "You are in the ama-claude-harness repo. A harness agent has hit this problem or need: \"$symptom\". Using AGENTS.md (start with its symptom index and routing note) and the repo's reference docs/skills, name the specific file(s) or skill you would read for the guidance. Answer with file/skill names only, no fix attempt." 2>/dev/null)"
  if printf '%s' "$answer" | grep -qiE "$want"; then
    pass=$((pass+1)); printf 'PASS  %s\n' "$symptom"
  else
    miss=$((miss+1)); printf 'MISS  %s\n      want=/%s/ got: %s\n' "$symptom" "$want" "$(printf '%s' "$answer" | tr '\n' ' ' | head -c 200)"
  fi
}

ask "notification tones stopped playing" 'notify-sound'
ask "a tool call has been frozen for minutes with no progress" 'frozen-tool-call|hook orphan'
ask "writing a new PreToolUse gate hook -- where are the authoring and testing conventions" 'GATES-AND-HOOKS'
ask "a scheduled task silently did not run today" 'PORTABILITY'
ask "installing the harness on a new machine -- which credentials are needed" 'INSTALL\.md'
ask "need to update a Jira ticket via REST, the Atlassian MCP is retired" 'ama-jira-api'
ask "where do durable memory rules go and in what format" 'harness-memory|memory/'
ask "the public-mirror publish aborted on a forbidden token" 'public-scrub-map|publish-public|Public GitHub mirror'
ask "a later data migration overwrote a field an earlier migration had just formatted" 'PERSISTED-DATA-REWRITES'

if [ "$SELF_TEST" -eq 1 ]; then
  ask "self-test control: this expectation must never match" 'ZZ-IMPOSSIBLE-EXPECTATION-ZZ'
fi

printf '\nfindability-eval: %d passed, %d missed\n' "$pass" "$miss"
[ "$miss" -eq 0 ]
