#!/usr/bin/env bash
# PreToolUse hook (mcp__*__createJiraIssue|editJiraIssue). Denies tagging a ticket with a
# release/* or hotfix/* Fix Version until that version has been confirmed to exist,
# recorded via hooks/confirm-jira-version.sh into harness-state/tickets/.confirmed-jira-versions.
#
# The original rationale said "there's no MCP tool or REST credential here to create one".
# The REST half was WRONG and was never tested: `POST /rest/api/3/version` works fine with
# ATLASSIAN_API_TOKEN (proven 2026-08-18 by a create/GET/release/delete round trip), and
# skills/ama-jira-api/scripts/jira-version.sh now does it. Claude creates the version
# itself; it no longer waits on the user.
#
# The gate still earns its place, for a different reason than it was built for: the real
# hazard is taking the WRONG number, not a missing version. Being able to create versions
# freely makes that easier, not harder -- hotfix/129.0.1 was nearly reused for a second
# unrelated fix on 2026-08-18. Confirming a version is the deliberate step that stops a
# guessed number being tagged onto tickets. See also hotfix-version-claimed-gate.sh, which
# checks the complementary question: whether the version is already SOMEONE ELSE'S.
#
# SECOND CHECK (2026-10-14, user decision "New linked ticket"): a regression goes to the
# causing ticket ONLY while that ticket is unreleased. Incident: PROJ-14911 shipped in
# release/123.0.0 (released 2026-01-30); on 2026-09-26 a session reopened it and tagged it
# release/130.0.0, so release-130 notes listed the old feature as new (session eab39211).
# Rule: DENY an EDIT that ADDS a release/* Fix Version to a ticket already carrying a
# DIFFERENT release/* version Jira marks released=true -- raise a new linked Bug instead.
# Allowed: removals / payloads keeping only present versions, all-unreleased tickets, creates,
# harnessEpicKey/regressionsTicketKey, and ANY hotfix/* addition (a hotfix absorbing release
# work, or a release absorbing a released hotfix, legitimately carries both -- ama-deploy-release
# Step 7a). Only `fields.fixVersions` (set) is read, not `update.fixVersions` add-ops.
# Fails OPEN when Jira is unreachable/no token (like every Jira hook but the RTT gate).
# Seam: JFVG_ISSUE_FILE = fixture file, one "name<TAB>released" line per version, replaces the Jira read.
set -u
. "$HOME/.claude/hooks/lib-claude-paths.sh"

# Also covers ama-jira-api's jira-edit-issue.sh/jira-create-issue.sh -- same
# fixed-payload-file read as jira-ticket-fields-gate.sh, never command-text parsing.
IFS= read -r -d '' payload || true
# Cheap raw-payload pre-filter before any jq fork (precedent:
# aggregation-secret-gate.sh) -- every arm below needs either an MCP *JiraIssue tool
# name or a jira-edit/create-issue.sh invocation in the command, all of which leave
# one of these literal substrings in the raw payload. ~60ms/fork on this machine.
case "$payload" in *JiraIssue*|*jira-edit-issue*|*jira-create-issue*) ;; *) exit 0 ;; esac
tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty')"
command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"

versions=""
ekey=""
case "$tool" in
  mcp__*__editJiraIssue)
    versions="$(printf '%s' "$payload" | jq -r '.tool_input.fields.fixVersions[]?.name // empty')"
    ekey="$(printf '%s' "$payload" | jq -r '.tool_input.issueIdOrKey // .tool_input.issueKey // empty')"
    ;;
  mcp__*__createJiraIssue)
    versions="$(printf '%s' "$payload" | jq -r '.tool_input.additional_fields.fixVersions[]?.name // empty')"
    ;;
  *)
    PAYLOAD_FILE="$(jira_payload_file "$command")"
    if printf '%s' "$command" | grep -qP '(^|[;&|]\s*)([A-Z_]+=\S+\s+)*(bash|sh|pwsh|powershell(\.exe)?)\s+"?\S*jira-edit-issue\.sh|(^|[;&|]\s*)\.[/\\]\S*jira-edit-issue\.sh'; then
      [ -f "$PAYLOAD_FILE" ] || exit 0
      versions="$(jq -r '.fields.fixVersions[]?.name // empty' "$PAYLOAD_FILE" 2>/dev/null)"
      ekey="$(printf '%s' "$command" | grep -oP 'jira-edit-issue\.sh"?\s+\K[A-Za-z][A-Za-z0-9]*-[0-9]+' | head -1)"
    elif printf '%s' "$command" | grep -qP '(^|[;&|]\s*)([A-Z_]+=\S+\s+)*(bash|sh|pwsh|powershell(\.exe)?)\s+"?\S*jira-create-issue\.sh|(^|[;&|]\s*)\.[/\\]\S*jira-create-issue\.sh'; then
      [ -f "$PAYLOAD_FILE" ] || exit 0
      versions="$(jq -r '.additional_fields.fixVersions[]?.name // empty' "$PAYLOAD_FILE" 2>/dev/null)"
    else
      exit 0
    fi
    ;;
esac

[ -n "$versions" ] || exit 0

# --- released-version check (edit only; cheap string tests before any fork/curl) ---
case "$versions" in *release/*) [ -n "$ekey" ] && {
  . "$HOME/.claude/hooks/lib-jira-status.sh"
  cfg="${HR_CONFIG_FILE:-$HOME/.claude/harness-config.json}"
  skipkeys="$(jq -r '[.atlassian.harnessEpicKey, .atlassian.regressionsTicketKey] | map(select(. != null and . != "")) | .[]' "$cfg" 2>/dev/null | tr -d '')"
  if ! printf '%s
' "$skipkeys" | grep -qxF "$ekey"; then
    if [ -n "${JFVG_ISSUE_FILE:-}" ]; then current="$(tr -d '' < "$JFVG_ISSUE_FILE" 2>/dev/null)"
    else current="$(jira_fixversions "$ekey" 2>/dev/null)"; fi
    relreleased=""; added=""
    while IFS=$'	' read -r cn cr; do
      case "$cn" in release/*) [ "$cr" = "true" ] && relreleased="$relreleased $cn" ;; esac
    done <<< "$current"
    while IFS= read -r v; do
      v="${v%$''}"
      case "$v" in release/*) printf '%s
' "$current" | cut -f1 | grep -qxF "$v" || added="$added $v" ;; esac
    done <<< "$versions"
    if [ -n "$relreleased" ] && [ -n "$added" ]; then
      jq -cn --arg k "$ekey" --arg a "$added" --arg r "$relreleased" '{
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: "deny",
          permissionDecisionReason: ($k + " already shipped in released Fix Version(s)" + $r + "; adding" + $a + " would list its old work as new in that release (PROJ-14911 incident). A regression/follow-up on a RELEASED ticket gets a NEW Bug ticket linked to it (issue link \"relates to\"), not a reopen + new Fix Version. Create the new ticket and tag that one. See skills/commit-ticket/REGRESSIONS.md.")
        }
      }'
      exit 0
    fi
  fi
} ;; esac

CONFIRMED="$(hstate tickets .confirmed-jira-versions)"
unconfirmed=""
while IFS= read -r v; do
  v="${v%$'\r'}"
  [ -n "$v" ] || continue
  case "$v" in
    release/*|hotfix/*) : ;;
    *) continue ;;
  esac
  if [ ! -f "$CONFIRMED" ] || ! grep -qxF "$v" "$CONFIRMED"; then
    unconfirmed="$unconfirmed $v"
  fi
done <<< "$versions"

[ -n "$unconfirmed" ] || exit 0

jq -cn --arg v "$unconfirmed" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: ("Fix Version(s)" + $v + " not yet confirmed created in Jira for this harness. This gate reads only ~/.claude/harness-state/tickets/.confirmed-jira-versions, so the version may well already exist in Jira. Do NOT ask the user to create it by hand: run jira-version.sh show <version> (in ama-jira-api/scripts), create it with jira-version.sh create <version> \"<description>\" if missing, then run `bash ~/.claude/hooks/confirm-jira-version.sh <version>` and retry.")
  }
}'
