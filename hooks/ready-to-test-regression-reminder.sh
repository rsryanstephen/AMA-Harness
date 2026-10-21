#!/usr/bin/env bash
# PostToolUse hook (Bash/PowerShell + the Jira MCP write tools). Nudges the REGRESSION step
# a Ready-to-Test ticket owes: Claude judges risk from the diff; high risk -> Claude checks it
# in session; a SEPARATE brief regression comment only if the UI tester can run it from the UI.
#
# Rule 2026-08-21, refined 2026-08-26 (memory/ready-to-test-regression-comment.md): the CHECK
# is Claude's job, the COMMENT is for the tester, both only when risk is high. Mechanics in
# ama-hotfix Step 2a. Hooked rather than left to prose for CLAUDE.md's mechanical-triggers
# reason -- "remember the regression step after the testing steps" is exactly the
# self-recognition that fails, same as slack-brevity-gate.sh.
#
# Two triggers, because either one alone has a hole:
#   1. the Ready-to-Test transition itself -- fires before either comment exists
#   2. a testing-steps comment landing -- fires at the moment comment 2 becomes due, and
#      catches the case where the transition happened in an earlier turn or by hand
#
# Trigger 1 asks Jira what the status now IS; it does NOT pattern-match the transition id.
# `10171` is the id of the Ready to Test STATUS, not of any transition -- real transition ids
# on this board are 2-3 digits (231 PR Review, 261 Done, ...) and are per-ticket besides, so a
# hook grepping the id argument for 10171 would have looked correct and never fired once.
# jira-transition-issue.sh passes only an opaque id, so the payload alone cannot say where the
# ticket landed -- one read-only GET (lib-jira-status.sh) can. Fails open (no token, curl
# error, timeout): silent, with trigger 2 still covering the comment moment.
#
# Trigger 2 ALSO reads the status (2026-09-07): the "reads like testing steps" vocabulary
# matched any long comment, so Open/Blocked/Done tickets with no diff in play got the nudge
# (PROJ-15335, 14687 -- 4 firings). A status where no diff can exist -> silent. Unreadable
# status -> nudge (fail open, the costlier miss is the silent one).
#
# Self-suppressing: comment text already mentioning "regress" produces nothing, so a
# regression comment (or a "Regression: checked..." line in comment 1) never re-nudges.
# Bash branch matches an INVOCATION of jira-add-comment.sh, not the filename anywhere in the
# command -- `sed -n 1,40p .../jira-add-comment.sh` fired it twice on 2026-08-26. Reminder only, never a permissionDecision -- no hook can judge whether the
# investigation was actually thorough, and a gate that cannot fail is worse than none
# (gmail-drafting's warning; audience-policy-gate.sh took the same call).
#
# This never confirms that comment 2 already exists -- it nudges, Claude checks.
set -u
. "$HOME/.claude/hooks/lib-claude-paths.sh"

IFS= read -r -d '' payload || true
# Cheap raw-payload pre-filter before any jq fork (precedent: aggregation-secret-gate.sh).
case "$payload" in
  *jira-add-comment*|*addCommentToJiraIssue*|*jira-transition-issue*|*transitionJiraIssue*) ;;
  *) exit 0 ;;
esac

. "$HOME/.claude/hooks/lib-jira-status.sh"
. "$HOME/.claude/hooks/lib-command-text.sh"
ready_to_test() { [ "$(jira_status "$1")" = "Ready to Test" ]; }
# Statuses where no diff is in play, so a comment there is never testing steps for a release.
no_diff_status() {
  case "$1" in Open|"To Do"|Blocked|Done|Canceled|Cancelled|"Test Complete") return 0 ;; esac
  return 1
}

tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty')"
command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"
# DATA IS NOT A COMMAND. Detect invocations against the text with heredoc bodies and
# single-quoted spans removed: this hook denied a Bash call whose only Jira content was a
# quoted fixture (`... jira-add-comment.sh PROJ-15392 ...` inside a variable assignment),
# and with no payload file present force=1 nudged anyway. Scan text is for the two greps only
# -- jira_payload_file() and the key extraction still read the ORIGINAL command.
command_scan="$(printf '%s\n' "$command" | command_text_stripped)"

body=""
force=0
case "$tool" in
  mcp__*__addCommentToJiraIssue)
    body="$(printf '%s' "$payload" | jq -r '.tool_input.commentBody // .tool_input.body // empty')"
    key="$(printf '%s' "$payload" | jq -r '.tool_input.issueIdOrKey // empty')"
    ;;
  Bash|PowerShell)
    if printf '%s' "$command_scan" | grep -qE '(^|[;&|(] *)([A-Z_]+=[^[:space:]]+ +)*(bash +)?"?[^" ]*jira-add-comment\.sh"? +[A-Z]'; then
      # jira-add-comment.sh takes its text from this fixed file, never an argument (see its
      # header) -- so the payload file, not the command line, is where the comment text is.
      # `< missing-file` is a SHELL error, not jq's -- jq's own 2>/dev/null never sees it, so
      # guard with -f or the hook writes "No such file" to stderr on every payload-less call.
      PF="$(jira_payload_file "$command")"
      [ -f "$PF" ] && body="$(jq -r '.body // empty' < "$PF" 2>/dev/null || true)"
      key="$(printf '%s' "$command" | grep -oP '[A-Z][A-Z0-9]+-\d+' | tail -1)"
      # Payload unreadable (already overwritten, missing, unparseable) -> nudge anyway; a
      # missed reminder is the costlier direction. Must bypass the looks-like-testing-steps
      # filter below, or a placeholder string would silently read as "not testing steps".
      [ -n "$body" ] || { body="a comment"; force=1; }
    elif printf '%s' "$command_scan" | grep -q 'jira-transition-issue'; then
      key="$(printf '%s' "$command" | grep -oP '[A-Z][A-Z0-9]+-\d+' | head -1)"
      [ -n "$key" ] && ready_to_test "$key" && body="__transition__"
    fi
    ;;
  mcp__*__transitionJiraIssue)
    key="$(printf '%s' "$payload" | jq -r '.tool_input.issueIdOrKey // empty')"
    [ -n "$key" ] && ready_to_test "$key" && body="__transition__"
    ;;
esac
[ -n "$body" ] || exit 0

tester="$(jq -r '.ama.uiTesterName // "the UI tester"' < "$HOME/.claude/harness-config.json" 2>/dev/null)"
[ -n "$tester" ] || tester="the UI tester"
rule="Judge regression risk from the DIFF (git log -p; shared libs, changed signatures, shared queries/mappers, DI wiring). Low risk -> no check, but still one line 'Regression: risk low -- <why>'. High risk -> EXERCISE the affected surfaces yourself NOW (ama-ui-verify on Staging; Graylog/Postgres/Mongo for non-UI). Changed a SHARED point (builder, base class, library output, template) -> 'X routes through it, so it inherits the change' is a test case, never a finding: run every consumer SHAPE against the real engine and cite per-shape evidence (SQL: rs-explain-shapes.sh ok/fail/missing) -- ama-debugging-notes/SHARED-CHOKEPOINT-CHANGES.md; PROJ-15416's 'inherits ... nothing found' note shipped five follow-up defects. Then: ${tester} can test it from the UI (UI ticket, or API ticket with a visible UI effect) -> SEPARATE brief regression comment, max 5 one-line steps ('open X, confirm Y still works'), no narrative. Not UI-testable -> NO regression comment, just one line in the testing-steps comment: 'Regression: checked a, b; nothing found.' Mechanics: ama-hotfix Step 2a item 3. Rule: memory/ready-to-test-regression-comment.md."
if [ "$body" = "__transition__" ]; then
  reason="Just moved a ticket to Ready to Test. Post concrete testing steps, then the regression step: ${rule}"
else
  # Already about regressions -> this IS comment 2, stay quiet.
  printf '%s' "$body" | grep -qi 'regress' && exit 0
  # Only nudge on a comment that reads like testing steps; an unrelated status comment isn't
  # the trigger. $force=1 (comment text unreadable) skips the filter rather than guessing.
  [ "$force" -eq 1 ] || printf '%s' "$body" | grep -qiE 'test|verify|steps|expected|reproduce' || exit 0
  # Status says no diff can be in play -> not testing steps, whatever the words. Empty
  # (offline/no token) falls through to the nudge.
  st=""; [ -n "${key:-}" ] && st="$(jira_status "$key")"
  no_diff_status "$st" && exit 0
  # In Progress is where BOTH a real testing-steps comment (posted before the transition)
  # and a pure findings comment on an investigation ticket land, so status alone cannot
  # split them. The diff can: an investigation ticket has no commit anywhere in the
  # session's repo. Three fires on PROJ-15414 (zero commits) cost three read-and-
  # dismiss rounds (2026-09-16). Not a git repo, or the key has a commit -> nudge.
  if [ "$st" = "In Progress" ] && [ -n "${key:-}" ]; then
    cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty')"
    if [ -n "$cwd" ] && git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1 \
       && [ -z "$(git -C "$cwd" log --all -1 --format=%h --grep="$key" 2>/dev/null)" ]; then
      exit 0
    fi
  fi
  reason="That Jira comment reads like testing steps. If this ticket is going to (or sitting at) Ready to Test, the regression step is still owed: ${rule} (Not at Ready to Test and not heading there -- e.g. a Test Complete ticket with nothing downstream -- ignore this.)"
fi

jq -cn --arg reason "$reason" '{decision:"block", reason:$reason}'
