#!/usr/bin/env bash
# PreToolUse hook (Bash|PowerShell). Guards writes to Graylog pipeline rules --
# production alert-suppression config. <harnessEpicKey>, built alongside the harness's
# first Graylog write capability (graylog-rule-write.sh / graylog-pipeline-attach-rule.sh).
#
# Two denials:
#  (a) A hand-rolled curl PUT/POST/DELETE against /api/system/pipelines/... -- forces
#      the write through graylog-rule-write.sh, which backs up the current rule and
#      parse-validates the new source BEFORE writing (a raw curl skips both, and a typo'd
#      title silently detaches a rule from its pipeline -- stage refs are by title, see
#      PIPELINE-RULES.md). The validate-only .../rule/parse endpoint persists nothing, so
#      it's excluded -- denying it would make even non-destructive syntax-checking
#      inconvenient for no safety gain.
#  (b) ANY Graylog pipeline write from a headless `claude -p` run -- no unattended
#      monitor should ever mutate production alerting unsupervised. Same transcript
#      headless detection every other consumer uses, lib-session-kind.sh. Fails OPEN if
#      the transcript/entrypoint can't be read -- rule (a) above is the real backstop.
set -u

payload="$(cat)"

# Raw-PAYLOAD mirror of the `case "$command"` needle further down. Same three patterns, and
# the payload is a superset of the command, so this can only ever match more. It exists
# because dispatch.sh's needle extractor reads `case "$payload"` blocks only: without this
# the gate was @ALWAYS and forked on every single shell command (584ms measured) despite
# having had a perfectly good needle all along. Keep the two lists identical.
case "$payload" in
  *pipelines*|*graylog-rule-write.sh*|*graylog-pipeline-attach-rule.sh*) : ;;
  *) exit 0 ;;
esac

tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null)"
case "$tool" in
  Bash|PowerShell) : ;;
  *) exit 0 ;;
esac

command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
[ -n "$command" ] || exit 0

# Cheap needle check before any regex work -- neither a raw pipelines-API call nor a
# call to either sanctioned write script, nothing to guard. Both script names must be
# here too: rule (b) below has to catch `graylog-rule-write.sh` even though that
# command line never mentions "pipelines" literally.
case "$command" in
  *pipelines*|*graylog-rule-write.sh*|*graylog-pipeline-attach-rule.sh*) : ;;
  *) exit 0 ;;
esac

# Heredoc bodies are data, not commands -- same scoping as inplace-edit-gate.sh.
. "$HOME/.claude/hooks/lib-command-text.sh" 2>/dev/null || command_scan_region() { printf '%s' "$1"; }
head_region="$(command_scan_region "$command")"

# Rule (a): a raw curl write against the pipelines API, excluding the validate-only
# .../rule/parse endpoint (never persists anything).
if printf '%s' "$head_region" | grep -qE '(^|[|;&])[[:space:]]*curl[[:space:]]' \
   && printf '%s' "$head_region" | grep -qE '\-X[[:space:]]*(PUT|POST|DELETE)' \
   && printf '%s' "$head_region" | grep -qE '/api/system/pipelines' \
   && ! printf '%s' "$head_region" | grep -qE '/api/system/pipelines/rule/parse'; then
  jq -cn '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: "Hand-rolled curl write against the Graylog pipelines API. Use skills/ama-graylog-search/scripts/graylog-rule-write.sh (update|create) or graylog-pipeline-attach-rule.sh instead -- both back up the current rule/pipeline and parse-validate the new source before writing, which a raw curl skips. See PIPELINE-RULES.md."
    }
  }'
  exit 0
fi

# Rule (b): any Graylog pipeline write attempt at all, from a headless run.
tr_path="$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null)"
source "${BASH_SOURCE[0]%/*}/lib-session-kind.sh"
if session_is_headless "$tr_path"; then
  if printf '%s' "$head_region" | grep -qE 'graylog-rule-write\.sh|graylog-pipeline-attach-rule\.sh' \
     || { printf '%s' "$head_region" | grep -qE '/api/system/pipelines' \
          && printf '%s' "$head_region" | grep -qE '\-X[[:space:]]*(PUT|POST|DELETE)'; }; then
    jq -cn '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: "Graylog pipeline write from a headless claude -p run. No unattended monitor mutates production alert-suppression config unsupervised -- this needs an interactive session."
      }
    }'
    exit 0
  fi
fi

exit 0
