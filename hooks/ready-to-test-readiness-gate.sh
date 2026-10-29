#!/usr/bin/env bash
# PreToolUse gate: a ticket may not move to Ready to Test without all four of
#   1. a description carrying the template's required headings,
#   2. a comment with testing steps a human can follow from the UI,
#   3. regression notes,
#   4. where to test -- a testing-notes line naming QA or Staging (user instruction 2026-09-26).
#
# Why (user instruction, 2026-09-11). PROJ-15288 was created, fixed and moved QA ->
# Ready to Test by an agent session with none of the three. <uiTesterName> asked "what needs to be
# done here?" on 2026-09-09, got no answer, and on 2026-09-11 wrote "Dev suggested to pass on
# this ticket" -- two days of tester time and a shipped fix nobody verified. The existing
# ready-to-test-regression-reminder.sh is PostToolUse and can only nudge, which is exactly
# what failed here: nothing read the nudge, and the transition had already landed.
#
# Companion gates, deliberately not merged into this one: jira-ticket-description-gate.sh
# checks a description at CREATE time (this one re-checks at the transition, because a ticket
# can be created elsewhere or edited empty afterwards), and regression-comment-brevity-gate.sh
# checks a regression comment's LENGTH (this one only checks that one exists).
#
# FAILS CLOSED -- deliberate departure from lib-jira-status.sh's fail-open house pattern
# (user's explicit call, 2026-09-11). No successful readiness check -> no transition, including
# when the token is missing or Jira is unreachable, because an unresolvable target status
# cannot be ruled out as Ready to Test. Do not "fix" this back to fail-open. The escape hatch
# is the Jira UI, which no hook can intercept; there is deliberately no bypass env var, since
# that would reopen the hole the gate exists to close.
set -u

IFS= read -r -d '' payload || true
case "$payload" in
  *jira-transition-issue*|*transitionJiraIssue*) ;;
  *) exit 0 ;;
esac

. "$HOME/.claude/hooks/lib-claude-paths.sh"
# RTT_PENDING_FILE is a test seam (same role HR_CONFIG_FILE plays for the config) -- without it
# check-gates.sh's own assertions would write PROJ-9999 into the real ledger.
PENDING_FILE="${RTT_PENDING_FILE:-$(hstate tickets pending-transitions)}"

# A fail-closed deny leaves the ticket sitting where it was -- often with the testing-steps
# and regression comments already posted, so only the STATUS is stale. If the session then
# ends (an outage has run ~25h here, IT-7829), nothing remembers the transition was owed.
# Record it; pending-transition-check.sh surfaces it on a later prompt.
# KEY \t transition-id \t destination-or-? \t date \t cause
record_pending() {
  local k="$1" id="$2" tgt="$3" cause="$4" tmp
  # Every field is written as ONE tab-separated line, so a stray newline/CR in any of them
  # splits the record -- and a record whose key ends up on a line of its own can never be
  # matched by clear_pending's "^KEY<TAB>", i.e. it nags forever and its own reminder text
  # renders as "KEY -> (id , blocked :)". Seen live in the ledger 2026-09-21 on
  # PROJ-14695; the writer that produced it was never identified, so sanitize here
  # rather than trust every caller.
  k="$(printf '%s' "$k" | tr -d '\r\n')"
  id="$(printf '%s' "$id" | tr -d '\r\n')"
  tgt="$(printf '%s' "$tgt" | tr -d '\r\n')"
  cause="$(printf '%s' "$cause" | tr '\r\n' '  ')"
  [ -n "$k" ] || return 0
  tmp="${PENDING_FILE}.$$"
  { [ -f "$PENDING_FILE" ] && grep -v "^${k}	" "$PENDING_FILE" 2>/dev/null; true; } > "$tmp"
  printf '%s\t%s\t%s\t%s\t%s\n' "$k" "${id:-?}" "${tgt:-?}" "$(date +%F)" "$cause" >> "$tmp"
  mv -f "$tmp" "$PENDING_FILE" 2>/dev/null || rm -f "$tmp"
}

# Any transition of this ticket that the gate could actually EVALUATE supersedes a pending
# record -- the retry landed, or it went somewhere else instead.
clear_pending() {
  local k="$1" tmp
  [ -n "$k" ] && [ -s "$PENDING_FILE" ] || return 0
  # Match "KEY<TAB>" (a well-formed record) OR a line that is JUST the key -- a record split
  # by a stray newline is otherwise unreapable, which is what kept PROJ-14695's entry
  # alive after the ticket had already been resolved by hand (2026-09-21).
  grep -qE "^${k}(	|$)" "$PENDING_FILE" 2>/dev/null || return 0
  tmp="${PENDING_FILE}.$$"
  # Dropping a bare-key line must take its orphaned payload line with it, or the leftover
  # "21<TAB>?<TAB>..." reads as a record whose key is "21" and the nag just changes shape.
  awk -v k="$k" '
    $0 == k { skip = 1; next }
    index($0, k "\t") == 1 { skip = 0; next }
    skip && $0 !~ /^[A-Z][A-Z0-9]+-[0-9]+\t/ { next }
    { skip = 0; print }
  ' "$PENDING_FILE" > "$tmp" 2>/dev/null
  mv -f "$tmp" "$PENDING_FILE" 2>/dev/null || rm -f "$tmp"
}

# deny <reason> [record-cause] -- a second arg means this is a fail-closed deny (the check
# could not run), not a readiness failure (the ticket is genuinely short of the three items,
# and the agent is right there to fix it).
deny() {
  [ $# -gt 1 ] && record_pending "${key:-}" "${tid:-}" "${target:-?}" "$2"
  jq -cn --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty')"
key=""
tid=""
case "$tool" in
  mcp__*__transitionJiraIssue)
    key="$(printf '%s' "$payload" | jq -r '.tool_input.issueIdOrKey // .tool_input.issueKey // empty')"
    tid="$(printf '%s' "$payload" | jq -r '.tool_input.transition.id // .tool_input.transitionId // empty')"
    ;;
  Bash|PowerShell)
    command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"
    # Invocation only, never the filename mentioned in a read (same shape as the sibling gates).
    printf '%s' "$command" | grep -qE '(^|[;&|(] *)([A-Z_]+=[^[:space:]]+ +)*(bash +|sh +|pwsh +|powershell(\.exe)? +)?"?[^" ]*jira-transition-issue\.sh"? +[A-Z]' || exit 0
    # Read BOTH args out of the invocation's own argument list, never out of the whole
    # command. Scraping the command scraped two different places: the key grep was leftmost
    # (head -1), the id sed leftmost-LONGEST, i.e. rightmost -- so a compound command
    # (`... transition KEY 11 && ... add-comment KEY 2>/dev/null`) read the redirect's `2`
    # as the transition id, denied a valid transition, and filed a bogus IOU
    # (PROJ-15392, 2026-09-12). Cut at the invocation first, then take positionals 1-2.
    # ...and cut the argument list at the first command separator: `... KEY 21; next-cmd`
    # left `21;` as the id token, which failed the digit match, resolved to nothing and
    # DENIED a valid transition (PROJ-11854, 2026-09-18).
    args="$(printf '%s' "$command" \
      | sed -E 's/.*[^[:alnum:]_-]jira-transition-issue\.sh"?[[:space:]]+//; s/^jira-transition-issue\.sh"?[[:space:]]+//; s/[;&|].*$//')"
    key="$(printf '%s' "$args" | awk '{gsub(/["\x27]/,"",$1); print $1}' | grep -oE '^[A-Z][A-Z0-9]+-[0-9]+$')"
    tid="$(printf '%s' "$args" | awk '{gsub(/["\x27]/,"",$2); print $2}' | grep -oE '^[0-9]+$')"
    ;;
  *) exit 0 ;;
esac

[ -n "$key" ] || deny "Ready-to-Test readiness gate: could not read a ticket key out of this transition call, so it cannot check whether the ticket is ready. Re-issue the transition as 'jira-transition-issue.sh <KEY> <TRANSITION-ID>'."

cfg="${HR_CONFIG_FILE:-$HOME/.claude/harness-config.json}"
host="$(jq -r '.atlassian.cloudId // empty' < "$cfg" 2>/dev/null)"
email="$(jq -r '.user.email // empty' < "$cfg" 2>/dev/null)"
hatch="The transition can still be done by hand in the Jira UI, which no hook intercepts."

[ -n "${ATLASSIAN_API_TOKEN:-}" ] || deny "Ready-to-Test readiness gate: ATLASSIAN_API_TOKEN is not set, so ${key}'s readiness cannot be checked. This gate fails CLOSED by design -- it is not a claim that anything is missing from the ticket. Set the token and retry. ${hatch} The owed transition has been recorded, and a later prompt will remind you." "no ATLASSIAN_API_TOKEN"
[ -n "$host" ] && [ -n "$email" ] || deny "Ready-to-Test readiness gate: atlassian.cloudId / user.email missing from harness-config.json, so ${key}'s readiness cannot be checked. This gate fails CLOSED by design. ${hatch}" "harness-config.json missing atlassian.cloudId / user.email"

_get() { curl -s --max-time 10 -u "${email}:${ATLASSIAN_API_TOKEN}" "https://${host}$1" 2>/dev/null; }

# Transition IDs are per-ticket, so the id alone says nothing -- but /transitions carries the
# destination status name for each one, which is what makes this gate possible at all.
trs="$(_get "/rest/api/3/issue/${key}/transitions")"
[ -n "$trs" ] || deny "Ready-to-Test readiness gate: could not reach Jira to resolve where this transition takes ${key} (network error or timeout). This gate fails CLOSED by design -- it is not a claim that anything is missing from the ticket. ${hatch} The owed transition has been recorded, and a later prompt will remind you, so it is safe to leave it and come back once Jira is reachable -- check the ticket's existing comments before re-running the whole sequence, or you will post them twice." "Jira unreachable (network error or timeout)"

if [ -n "$tid" ]; then
  target="$(printf '%s' "$trs" | jq -r --arg id "$tid" '.transitions[]? | select(.id == $id) | .to.name // empty' 2>/dev/null)"
else
  target=""
fi
# No id, or an id this ticket does not offer: cannot rule out Ready to Test -> fail closed.
# NO pending record when the transitions list came back live, though: the list is proof the
# check RAN, so an unoffered id is a caller mistake, not an outage -- and an IOU for a
# transition that never existed nags on every later prompt (seen 2026-09-12 after the
# arg-parse bug above filed `PROJ-15392 2 ?`). Unparseable list -> still record.
if [ -z "$target" ]; then
  msg="Ready-to-Test readiness gate: transition id '${tid:-<none>}' is not one ${key} currently offers, so its destination status cannot be resolved. Run jira-get-transitions.sh ${key} for the live ids. This gate fails CLOSED by design. ${hatch}"
  if [ "$(printf '%s' "$trs" | jq -r '.transitions | length' 2>/dev/null || echo 0)" -gt 0 ] 2>/dev/null; then
    deny "$msg"
  else
    deny "$msg" "transition id ${tid:-<none>} not offered by the ticket"
  fi
fi

# Past this line the destination resolved, so any pending record for this ticket is spent --
# whether this transition is the delayed retry or a move somewhere else entirely.
clear_pending "$key"

printf '%s' "$target" | grep -qiE '^ready ?to ?test$' || exit 0

issue="$(_get "/rest/api/2/issue/${key}?fields=description,comment")"
[ -n "$issue" ] || deny "Ready-to-Test readiness gate: could not read ${key} back from Jira to check it. This gate fails CLOSED by design. ${hatch} The owed transition has been recorded, and a later prompt will remind you." "Jira unreachable reading the ticket back"

description="$(printf '%s' "$issue" | jq -r '.fields.description // empty' 2>/dev/null)"
comments="$(printf '%s' "$issue" | jq -r '.fields.comment.comments[]?.body // empty' 2>/dev/null)"

missing=""

if [ -z "$description" ]; then
  missing="a description (it is empty)"
else
  dmiss=""
  printf '%s' "$description" | grep -qiE 'acceptance criteria' || dmiss="${dmiss}acceptance criteria, "
  printf '%s' "$description" | grep -qiE 'how to test' || dmiss="${dmiss}how to test, "
  printf '%s' "$description" | grep -qiE 'how to reproduce|requirements' || dmiss="${dmiss}how to reproduce (Bug) / requirements (everything else), "
  [ -z "$dmiss" ] || missing="description sections: ${dmiss%, }"
fi

# Testing steps: a comment that both reads as testing AND actually has numbered/bulleted steps,
# so a paragraph merely containing the word "test" does not satisfy it. Wiki-markup lists
# count too: `#`/`##` numbered and `*`/`**` bulleted are what jira-add-comment.sh renders since
# 2026-10-05 and what TICKET-TEMPLATE.md prescribes (PROJ-15470's steps were denied).
if ! printf '%s' "$comments" | grep -qiE 'test|verify|steps|expected|reproduce' \
   || ! printf '%s' "$comments" | grep -qE '^[[:space:]]*([-*#]+|[0-9]+[.)])'; then
  missing="${missing:+$missing; }testing steps (a comment with numbered steps a human can follow)"
fi

# Regression notes: the NOUN, word-anchored -- same reasoning as regression-comment-brevity-gate.sh.
# Either route satisfies this: a standalone regression comment, or a "Regression: ..." line inside
# the testing-steps comment. When risk is low that line is a one-liner, but it is never absent
# (memory/ready-to-test-regression-comment.md, tightened 2026-09-11).
printf '%s' "$comments" | grep -qiE '\bregressions?\b' \
  || missing="${missing:+$missing; }regression notes (a regression comment, or a 'Regression: ...' line in the testing-steps comment -- one line is enough when the risk is low, but it must be there)"

# Where to test (user instruction 2026-09-26): the tester must be told QA or Staging -- a fix
# only on develop is NOT on Staging, and one on a release/hotfix branch is what Staging runs.
# Production is accepted too: an infra-only change live in prod waiting on a third party also
# lands in Ready to Test (commit-ticket-jira's infra row), and "QA" would be false there.
# A LINE that opens with test/testing/where to test/environment and names the env within
# ~25 chars ("Test on QA", "Testing steps (Staging)", "Environment: QA"). A results line like
# "Verified on QA" or "Tested on QA" does not count -- that says where Claude looked, not where
# the tester should.
printf '%s' "$comments" | grep -qiE '^[[:space:]]*(h[1-6]\.|[-*]|[0-9]+[.)])?[[:space:]]*(where to test|testing|test|environment|env)\b[^[:cntrl:]]{0,25}\b(QA|Staging|Prod(uction)?)\b' \
  || missing="${missing:+$missing; }where to test (a line in the testing notes such as 'Test on QA' for a fix only on develop, 'Test on Staging' for one on a release/hotfix branch, or 'Test on Production' for an infra-only change)"

[ -n "$missing" ] || exit 0

deny "${key} is not ready for Ready to Test -- missing ${missing}. A ticket reaching Ready to Test owes the tester all four: a description with the template's headings, testing steps from the UI, regression notes, and where to test (QA or Staging) (harness rule, user instructions 2026-09-11 after PROJ-15288 reached the tester with none of them, and 2026-09-26). See commit-ticket/TICKET-TEMPLATE.md and memory/ready-to-test-regression-comment.md. Add what is missing, then retry the transition."
